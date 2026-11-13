-- Games/Deathroll.lua: two players take turns: /roll 1-N, then 1-(previous roll).
-- Whoever rolls a 1 loses the stake. The challenger rolls first.
local ADDON_NAME, ns = ...
local Games, Rolls, Comm = ns.Games, ns.Rolls, ns.Comm

local DR = {}
ns.Deathroll = DR

DR.DEFAULT_START = 1000
DR.MAX_START = 1000000
DR.INVITE_TIMEOUT = 60
DR.ACCEPT_RETRY = 5     -- seconds between resending "accepted" until the first roll
DR.ACCEPT_RETRIES = 6   -- then give up and cancel (about 30 seconds)
DR.PRACTICE = "Practice"

local OnRoll

local function Other(game, who)
    return who == game.a and game.b or game.a
end

local function NextTurn(game)
    game.n = game.n + 1
    local roller, max = game.turn, game.max
    local key = game.id .. ":" .. game.n
    if game.practice and roller == DR.PRACTICE then
        game.status = ("Practice bot rolls 1-%d..."):format(max)
        ns.UI.SetRollPrompt(nil)
        C_Timer.After(1, function()
            if Games.Get(game.id) == game then OnRoll(game, roller, math.random(1, max), true) end
        end)
        ns.UI.Refresh()
        return
    end
    Rolls.Watch({
        player = roller, min = 1, max = max, key = key,
        relayTo = (ns.IsMe(roller) and not game.practice) and { game.opponent } or nil,
        onRoll = function(v, verified) OnRoll(game, roller, v, verified) end,
    })
    if ns.IsMe(roller) then
        ns.Sound("turn")
        game.status = ("Your roll: 1-%d"):format(max)
        ns.UI.SetRollPrompt(1, max, "Roll 1-" .. max)
    else
        game.status = ("Waiting for %s to roll 1-%d"):format(ns.Short(roller), max)
        ns.UI.SetRollPrompt(nil)
    end
    ns.UI.Refresh()
end

function OnRoll(game, roller, v, verified)
    Games.NoteRoll(game, verified)
    ns.Sound("roll")
    game.history[#game.history + 1] = ("%s %d"):format(ns.IsMe(roller) and "You" or ns.Short(roller), v)
    -- the table shows this big in the middle: who rolled what, out of what
    game.lastRoll = { who = roller, value = v, max = game.max, seq = #game.history }
    if v == 1 then
        local iLost = ns.IsMe(roller)
        -- only the player who rolled the 1 hears the death cry; the winner gets the fanfare
        if iLost then
            game.deathCry = true
            game.drop = game.max -- for the leaderboard's "biggest drop to 1"
            ns.Sound("death")
        end
        Games.Finish(game, iLost and -game.stake or game.stake,
            ("%s rolled a 1 after %d rolls"):format(iLost and "you" or ns.Short(roller), #game.history),
            iLost and -1 or 1)
        return
    end
    game.max = v
    game.turn = Other(game, roller)
    NextTurn(game)
end

local function Start(game)
    game.state = "play"
    ns.Log("Deathroll vs %s for %s: 1-%d, %s first.", ns.Short(game.opponent), ns.Stake(game.stake),
        game.start, ns.IsMe(game.a) and "you roll" or (ns.Short(game.a) .. " rolls"))
    NextTurn(game)
end

local function NewGame(fields)
    fields.kind, fields.title = "deathroll", "Deathroll"
    fields.n, fields.verified, fields.history = 0, true, {}
    fields.max, fields.turn = fields.start, fields.a
    return Games.Add(fields)
end

--- Challenge target (nil or "practice" for a solo game against a bot).
function DR.Challenge(target, stakeGold, start)
    if Games.Busy() then
        ns.Print("Finish your current game first (or |cffffff00/gg cancel|r).")
        return nil
    end
    local stake = ns.GoldToCopper(stakeGold)
    if not stake then ns.Print("Usage: /gg dr <player|practice> <wager> [start]  (wager like 10 or 1g 50s)") return nil end
    local cant = ns.CantCover(stake)
    if cant then ns.Print("Can't bet %s: you %s.", ns.Stake(stake), cant) return nil end
    start = math.floor(tonumber(start) or DR.DEFAULT_START)
    if start < 2 or start > DR.MAX_START then ns.Print("Start must be 2-%d.", DR.MAX_START) return nil end

    local practice = not target or target == "" or target:lower() == "practice" or ns.IsMe(target)
    target = practice and DR.PRACTICE or ns.Full(target)
    if not practice and ns.House.CheckOpponent(target) then return nil end
    local game = NewGame({
        id = ns.NewId(), a = ns.Me(), b = target, opponent = target,
        stake = stake, start = start, practice = practice, state = "invite",
    })
    if practice then
        Start(game)
    else
        game.status = ("Waiting for %s to accept..."):format(ns.Short(target))
        Comm.Send("DR_INV", { id = game.id, s = stake, n = start }, target)
        ns.Log("Challenged %s to a deathroll for %s (1-%d).", ns.Short(target), ns.Stake(stake), start)
        C_Timer.After(DR.INVITE_TIMEOUT, function()
            if Games.Get(game.id) == game and game.state == "invite" then Games.Cancel(game, "no answer") end
        end)
    end
    ns.UI.Refresh()
    return game
end

---------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------
Comm.On("DR_INV", function(f, sender)
    local stake, start = tonumber(f.s), tonumber(f.n)
    if not f.id or not stake or stake < 0 or not start or start < 2 or start > DR.MAX_START then return end
    local function no(reason) Comm.Send("DR_NO", { id = f.id, r = reason }, sender) end
    if Games.Busy() then return no("busy") end
    if not ns.Guild.Allowed(sender) then return no("not in my guild") end
    local why = ns.House.CheckOpponent(sender) -- e.g. their GuildGambit is outdated (shown in chat)
    if why then return no(why) end
    local cant = ns.CantCover(stake)
    if cant then return no("can't cover " .. ns.Stake(stake) .. " - " .. cant) end

    local text = ("%s challenges you to a deathroll for %s (1-%d). They roll first."):format(
        ns.Short(sender), ns.Stake(stake), start)
    ns.UI.ShowInvite(text, function()
        if Games.Busy() then return no("busy") end
        if ns.CantCover(stake) then return no("can't cover the bet") end
        local game = NewGame({
            id = f.id, a = sender, b = ns.Me(), opponent = sender, stake = stake, start = start,
        })
        Comm.Send("DR_ACC", { id = f.id }, sender)
        Start(game)
        -- If our "accepted" got lost, the challenger never starts and we'd wait forever:
        -- resend it until their first roll shows up (or give up and cancel).
        local tries = 0
        local function retry()
            if Games.Get(game.id) ~= game or #game.history > 0 then return end
            tries = tries + 1
            if tries > DR.ACCEPT_RETRIES then
                Games.Cancel(game, ns.Short(sender) .. " never started")
                return
            end
            Comm.Send("DR_ACC", { id = f.id }, sender)
            C_Timer.After(DR.ACCEPT_RETRY, retry)
        end
        C_Timer.After(DR.ACCEPT_RETRY, retry)
    end, function()
        no("declined")
    end)
end)

Comm.On("DR_ACC", function(f, sender)
    local game = Games.Get(f.id)
    if game and game.kind == "deathroll" and ns.SameName(game.opponent, sender) then
        if game.state == "invite" then Start(game) end
        return -- a repeat while already playing: nothing to do
    end
    -- we no longer have this challenge (it expired or was cancelled): say so
    Comm.Send("DR_GONE", { id = f.id }, sender)
end)

Comm.On("DR_GONE", function(f, sender)
    local game = Games.Get(f.id)
    if game and game.kind == "deathroll" and ns.SameName(game.opponent, sender) and #game.history == 0 then
        Games.Cancel(game, "the challenge had expired", true)
    end
end)

Comm.On("DR_NO", function(f, sender)
    local game = Games.Get(f.id)
    if game and game.kind == "deathroll" and ns.SameName(game.opponent, sender) and game.state == "invite" then
        ns.Log("%s declined the deathroll (%s).", ns.Short(sender), f.r or "no reason")
        Games.Remove(game)
    end
end)

---------------------------------------------------------------------------
-- Coinflip (kept in this file so it loads without changing the addon's file list).
-- Heads is Alliance, tails is Horde. The challenger calls a side (their own faction unless
-- they say otherwise) and the opponent gets the other. One server /roll 1-2 by the
-- challenger decides it: 1 = heads (Alliance), 2 = tails (Horde). Winner takes the pot.
---------------------------------------------------------------------------
local CF = {}
ns.Coinflip = CF

CF.INVITE_TIMEOUT = 60
CF.ACCEPT_RETRY = 5
CF.ACCEPT_RETRIES = 6
CF.FLIP_DELAY = 3.0 -- a moment of suspense (and time for spectators to tune in)
CF.PRACTICE = "Practice"
CF.SIDES = {
    A = { faction = "Alliance", face = "Heads", roll = 1, icon = "Interface\\Icons\\INV_BannerPVP_02" },
    H = { faction = "Horde", face = "Tails", roll = 2, icon = "Interface\\Icons\\INV_BannerPVP_01" },
}

local function OtherSide(c) return c == "A" and "H" or "A" end

local function MyFaction()
    local ok, faction = pcall(UnitFactionGroup, "player")
    return (ok and faction == "Horde") and "H" or "A"
end

--- "A" / "H" from words like alliance, horde, heads, tails.
function CF.ParseCall(word)
    word = (word or ""):lower()
    if word == "alliance" or word == "heads" or word == "a" then return "A" end
    if word == "horde" or word == "tails" or word == "h" then return "H" end
end

--- The side a player is on in this game.
function CF.SideOf(game, who)
    return ns.SameName(who, game.a) and game.call or OtherSide(game.call)
end

function CF.Label(c)
    local s = CF.SIDES[c]
    return ("%s (%s)"):format(s.face, s.faction)
end

local function Land(game, v, verified)
    Games.NoteRoll(game, verified)
    local landed = v == 1 and "A" or "H"
    game.landed = landed
    local mine = game.practice and game.call or CF.SideOf(game, ns.Me())
    local won = landed == mine
    Games.Finish(game, won and game.bet or -game.bet, ("the coin landed %s"):format(CF.Label(landed)), won and 1 or -1)
end

local function Begin(game)
    game.state = "play"
    local mine = game.practice and game.call or CF.SideOf(game, ns.Me())
    ns.Log("Coinflip vs %s for %s: you're %s.", ns.Short(game.opponent), ns.Stake(game.bet), CF.Label(mine))
    ns.Sound("coin")
    local key = game.id .. ":flip"
    Rolls.Watch({
        player = game.a, min = 1, max = 2, key = key,
        relayTo = (ns.IsMe(game.a) and not game.practice) and { game.opponent } or nil,
        onRoll = function(v, verified) Land(game, v, verified) end,
    })
    if ns.IsMe(game.a) then
        game.status = "Flipping..."
        C_Timer.After(CF.FLIP_DELAY, function()
            if Games.Get(game.id) == game and Rolls.IsWatching(key) and not Rolls.Roll(1, 2) then
                game.status = "Flip the coin!"
                ns.UI.SetRollPrompt(1, 2, "Flip!") -- RandomRoll unavailable: flip by hand
            end
        end)
    else
        game.status = ("%s is flipping..."):format(ns.Short(game.a))
    end
    ns.UI.Refresh()
end

--- Coinflip against a guildie, or practice. call: "A"/"H" or a word (default: your faction).
function CF.Challenge(target, betGold, call)
    if Games.Busy() then
        ns.Print("Finish your current game first (or |cffffff00/gg cancel|r).")
        return nil
    end
    local bet = ns.GoldToCopper(betGold)
    if not bet then ns.Print("Usage: /gg flip <wager> <player|practice> [alliance|horde]") return nil end
    if not target or target == "" then ns.Print("Pick an opponent (or Practice) first.") return nil end
    call = CF.SIDES[call or ""] and call or CF.ParseCall(call) or MyFaction()
    local practice = target:lower() == "practice" or ns.IsMe(target)
    if not practice then
        local cant = ns.CantCover(bet)
        if cant then ns.Print("Can't bet %s: you %s.", ns.Stake(bet), cant) return nil end
    end
    target = practice and CF.PRACTICE or ns.Full(target)
    if not practice and ns.House.CheckOpponent(target) then return nil end
    local game = Games.Add({
        kind = "coinflip", title = "Coinflip", id = ns.NewId(), a = ns.Me(), b = target, opponent = target,
        bet = bet, call = call, practice = practice, verified = true, state = "invite",
    })
    if practice then
        Begin(game)
        return game
    end
    game.status = ("Waiting for %s to accept..."):format(ns.Short(target))
    Comm.Send("CF_INV", { id = game.id, s = bet, c = call }, target)
    ns.Log("Challenged %s to a coinflip for %s - you call %s.", ns.Short(target), ns.Stake(bet), CF.Label(call))
    C_Timer.After(CF.INVITE_TIMEOUT, function()
        if Games.Get(game.id) == game and game.state == "invite" then Games.Cancel(game, "no answer") end
    end)
    ns.UI.Refresh()
    return game
end

local function TheirFlip(f, sender)
    local game = Games.Get(f.id)
    if game and game.kind == "coinflip" and ns.SameName(game.opponent, sender) then return game end
end

Comm.On("CF_INV", function(f, sender)
    local bet = tonumber(f.s)
    if not f.id or not bet or bet < 0 or not CF.SIDES[f.c or ""] then return end
    local function no(reason) Comm.Send("CF_NO", { id = f.id, r = reason }, sender) end
    if Games.Busy() then return no("busy") end
    if not ns.Guild.Allowed(sender) then return no("not in my guild") end
    local why = ns.House.CheckOpponent(sender) -- e.g. their GuildGambit is outdated (shown in chat)
    if why then return no(why) end
    local cant = ns.CantCover(bet)
    if cant then return no("can't cover " .. ns.Stake(bet) .. " - " .. cant) end
    local text = ("%s flips a coin for %s and calls %s - you're %s. Winner takes the pot."):format(
        ns.Short(sender), ns.Stake(bet), CF.Label(f.c), CF.Label(OtherSide(f.c)))
    ns.UI.ShowInvite(text, function()
        if Games.Busy() then return no("busy") end
        if ns.CantCover(bet) then return no("can't cover the bet") end
        local game = Games.Add({
            kind = "coinflip", title = "Coinflip", id = f.id, a = sender, b = ns.Me(), opponent = sender,
            bet = bet, call = f.c, verified = true, state = "invite",
        })
        Comm.Send("CF_ACC", { id = f.id }, sender)
        Begin(game)
        local tries = 0
        local function retry()
            if Games.Get(game.id) ~= game then return end
            tries = tries + 1
            if tries > CF.ACCEPT_RETRIES then return Games.Cancel(game, ns.Short(sender) .. " never flipped") end
            Comm.Send("CF_ACC", { id = f.id }, sender)
            C_Timer.After(CF.ACCEPT_RETRY, retry)
        end
        C_Timer.After(CF.ACCEPT_RETRY, retry)
    end, function() no("declined") end)
end)

Comm.On("CF_ACC", function(f, sender)
    local game = TheirFlip(f, sender)
    if game then
        if game.state == "invite" then Begin(game) end
        return
    end
    Comm.Send("CF_GONE", { id = f.id }, sender)
end)

Comm.On("CF_NO", function(f, sender)
    local game = TheirFlip(f, sender)
    if game and game.state == "invite" then
        ns.Log("%s declined the coinflip (%s).", ns.Short(sender), f.r or "no reason")
        Games.Remove(game)
    end
end)

Comm.On("CF_GONE", function(f, sender)
    local game = TheirFlip(f, sender)
    if game and not game.landed then Games.Cancel(game, "the challenge had expired", true) end
end)

---------------------------------------------------------------------------
-- Group deathroll (kept in this file so it loads without changing the addon's file list).
-- A host opens a room for the guild with a wager and a start; guildies join from a popup and
-- the host presses Start. Players take turns in join order: /roll 1-N, then 1-(previous
-- roll). Rolling a 1 knocks you out and the next player starts again from 1-N. The last one
-- standing wins, and every other player owes them the wager.
--
-- Every client runs the same turn order from the same rolls (seen in chat, or relayed by the
-- roller's addon). A player who doesn't roll in time is knocked out by the first other player
-- still in, whose addon tells the rest; leaving mid-game is a forfeit.
---------------------------------------------------------------------------
local GDR = {}
ns.GroupDeathroll = GDR

GDR.MIN_PLAYERS = 2
GDR.MAX_PLAYERS = 10
GDR.LOBBY_TIMEOUT = 300 -- an unstarted room closes after 5 minutes
GDR.TURN_TIMEOUT = 90   -- not rolling for this long knocks you out
GDR.START_RESEND = 3    -- the host repeats "started" a couple of times in case one is lost

local GroupTurn

local function Names(list)
    local out = {}
    for _, n in ipairs(list) do out[#out + 1] = ns.Full(n) end
    return table.concat(out, ",")
end

local function ParseNames(text)
    local out = {}
    for n in tostring(text or ""):gmatch("[^,]+") do out[#out + 1] = ns.Full(n) end
    return out
end

--- The host's addon may list itself under another spelling of its name (UnitName vs the
--- server's "Eoka Pistol"); the sender of its messages is how the server spells it, and that
--- is what its roll lines will say. The host is always first in the list.
local function HostFirst(list, host)
    list[1] = ns.Full(host)
    return list
end

local function IndexOf(list, name)
    for i, n in ipairs(list) do
        if ns.SameName(n, name) or (ns.IsMe(n) and ns.IsMe(name)) then return i end
    end
end
GDR.IndexOf = IndexOf

--- Sends to every other player in the room.
local function SendAll(game, msgType, fields)
    for _, n in ipairs(game.players) do
        if not ns.IsMe(n) then Comm.Send(msgType, fields, n) end
    end
end

local function IsHost(game) return ns.IsMe(game.host) end
GDR.IsHost = IsHost

local function NamesText(list)
    local out = {}
    for _, n in ipairs(list) do out[#out + 1] = ns.IsMe(n) and "you" or ns.Short(n) end
    return table.concat(out, ", ")
end

local function UpdateLobbyStatus(game)
    local n = #game.players
    if IsHost(game) then
        game.status = n < GDR.MIN_PLAYERS and "Waiting for guildies to join..."
            or ("%d players in - press Start when everyone's in"):format(n)
        ns.UI.SetAction(("Start (%d player%s)"):format(n, n == 1 and "" or "s"), function() GDR.Start() end)
    else
        game.status = ("Waiting for %s to start (%d players)"):format(ns.Short(game.host), n)
        ns.UI.SetRollPrompt(nil)
    end
    ns.UI.Refresh()
end

local function NewRoom(fields)
    fields.kind, fields.title = "groupdr", "Group Deathroll"
    fields.state, fields.verified, fields.history, fields.n = "lobby", true, {}, 0
    fields.opponent = fields.host -- for the log and name learning; results go per player
    fields.out = {}
    return Games.Add(fields)
end

--- Opens a room for the guild. bet may be 0 (just for fun).
function GDR.Open(betText, start)
    if Games.Busy() then
        ns.Print("Finish your current game first (or |cffffff00/gg cancel|r).")
        return nil
    end
    if not (IsInGuild and IsInGuild()) then ns.Print("Group deathrolls are for your guild - you're not in one.") return nil end
    local bet = ns.GoldToCopper(betText)
    if not bet then ns.Print("Usage: /gg group <wager> [start]  (wager like 10 or 1g50s)") return nil end
    local cant = ns.CantCover(bet)
    if cant then ns.Print("Can't bet %s: you %s.", ns.Stake(bet), cant) return nil end
    start = math.floor(tonumber(start) or DR.DEFAULT_START)
    if start < 2 or start > DR.MAX_START then ns.Print("Start must be 2-%d.", DR.MAX_START) return nil end

    local game = NewRoom({ id = ns.NewId(), host = ns.Me(), bet = bet, start = start, players = { ns.Me() } })
    Comm.Send("GDR_OPEN", { id = game.id, s = bet, n = start }, nil)
    ns.Log("You opened a group deathroll for %s each (1-%d). Press Start once guildies have joined.",
        ns.Stake(bet), start)
    UpdateLobbyStatus(game)
    C_Timer.After(GDR.LOBBY_TIMEOUT, function()
        if Games.Get(game.id) == game and game.state == "lobby" then Games.Cancel(game, "nobody started it") end
    end)
    return game
end

local function BeginPlay(game)
    game.state = "play"
    game.alive = {}
    for i, n in ipairs(game.players) do game.alive[i] = n end
    game.turnIdx, game.max = 1, game.start
    ns.Log("Group deathroll for %s each: %s. %s first.", ns.Stake(game.bet), NamesText(game.players),
        ns.IsMe(game.alive[1]) and "You roll" or (ns.Short(game.alive[1]) .. " rolls"))
    GroupTurn(game)
end

--- Host: start the room with whoever has joined.
function GDR.Start()
    local game = Games.Mine()
    if not game or game.kind ~= "groupdr" or game.state ~= "lobby" then ns.Print("You have no group deathroll waiting to start.") return false end
    if not IsHost(game) then ns.Print("Only %s can start this room.", ns.Short(game.host)) return false end
    if #game.players < GDR.MIN_PLAYERS then ns.Print("Wait for at least one guildie to join first.") return false end
    local fields = { id = game.id, p = Names(game.players) }
    SendAll(game, "GDR_START", fields)
    for i = 1, 2 do
        C_Timer.After(GDR.START_RESEND * i, function()
            if Games.Get(game.id) == game and #game.history == 0 then SendAll(game, "GDR_START", fields) end
        end)
    end
    BeginPlay(game)
    return true
end

local function Finish(game, winner)
    if not winner then
        ns.Log("Group deathroll ended with nobody left - no result recorded.")
        Games.Remove(game)
        return
    end
    -- tell the room, so anyone whose addon missed a roll still records the same result
    SendAll(game, "GDR_END", { id = game.id, w = ns.Full(winner) })
    Rolls.UnwatchPrefix(game.id .. ":")
    game.state, game.winner, game.turn = "done", winner, nil
    ns.UI.SetRollPrompt(nil)
    local iWon = ns.IsMe(winner)
    local verified = game.verified ~= false
    local net, outcome
    if iWon then
        -- one ledger entry per loser (each owes me the wager); only the first counts as the game
        local first = true
        for _, p in ipairs(game.players) do
            if not ns.IsMe(p) then
                ns.Ledger.Record({ id = game.id, game = "groupdr", opponent = p, net = game.bet,
                    result = first and 1 or 0, wager = first and game.bet or 0, extra = (not first) or nil,
                    verified = verified })
                first = false
            end
        end
        net, outcome = game.bet * (#game.players - 1), 1
    else
        ns.Ledger.Record({ id = game.id, game = "groupdr", opponent = winner, net = -game.bet,
            result = -1, wager = game.bet, verified = verified, drop = game.drop })
        net, outcome = -game.bet, -1
    end
    game.finished, game.net, game.outcome = true, net, outcome
    game.summary = ("%s %s the last one standing of %d"):format(iWon and "you" or ns.Short(winner),
        iWon and "are" or "is", #game.players)
    ns.Log("Group Deathroll: %s - %s%s", game.summary, ns.ResultText(net, outcome),
        verified and "" or " |cffff8800(unverified rolls)|r")
    Games.last = game
    if iWon then
        local beaten = {}
        for _, p in ipairs(game.players) do if not ns.IsMe(p) then beaten[#beaten + 1] = p end end
        ns.GuildAnnounce(("[GuildGambit] %s won a group deathroll against %s %s!"):format(ns.Short(ns.Me()),
            ns.NameList(beaten), game.bet > 0 and ("for " .. ns.Money(game.bet) .. " each (" .. ns.Money(net) .. " pot)")
                or "just for fun"))
        ns.Sound("bigwin")
        C_Timer.After(0.3, function() ns.Sound("cheer") end)
    elseif not game.deathCry then
        ns.Sound("lose")
    end
    Games.Remove(game)
    if ns.Board then ns.Board.Changed() end
end

--- Knocks a player out. reset: the next player starts again from the top (after a 1).
local function KnockOut(game, who, why, reset)
    local idx = IndexOf(game.alive or {}, who)
    if not idx or game.state ~= "play" then return end
    local wasTurn = idx == game.turnIdx
    local name = game.alive[idx]
    table.remove(game.alive, idx)
    game.out[#game.out + 1] = name
    local me = ns.IsMe(name)
    ns.Log("%s %s - out! %d left.", me and "You" or ns.Short(name), why, #game.alive)
    if me then
        game.iAmOut = true
        if reset then
            game.deathCry = true
            game.drop = game.lastRoll and game.lastRoll.max or nil -- the range I rolled a 1 from
            ns.Sound("death")
        end
        ns.UI.SetRollPrompt(nil)
    end
    if #game.alive <= 1 then return Finish(game, game.alive[1]) end
    if wasTurn then
        Rolls.Unwatch(game.id .. ":" .. game.n)
        if idx > #game.alive then idx = 1 end
        game.turnIdx = idx
        if reset then game.max = game.start end
        GroupTurn(game)
    else
        if idx < game.turnIdx then game.turnIdx = game.turnIdx - 1 end
        ns.UI.Refresh()
    end
end

local function OnGroupRoll(game, roller, v, verified)
    if game.state ~= "play" then return end
    Games.NoteRoll(game, verified)
    ns.Sound("roll")
    game.history[#game.history + 1] = ("%s %d"):format(ns.IsMe(roller) and "You" or ns.Short(roller), v)
    game.lastRoll = { who = roller, value = v, max = game.max, seq = #game.history }
    if v == 1 then
        return KnockOut(game, roller, ("rolled a 1 (1-%d)"):format(game.max), true)
    end
    game.max = v
    game.turnIdx = game.turnIdx % #game.alive + 1
    GroupTurn(game)
end

function GroupTurn(game)
    game.n = game.n + 1
    local roller, max, step = game.alive[game.turnIdx], game.max, game.n
    game.turn = roller
    local others = {}
    for _, p in ipairs(game.players) do if not ns.IsMe(p) then others[#others + 1] = p end end
    Rolls.Watch({
        player = roller, min = 1, max = max, key = game.id .. ":" .. step,
        relayTo = ns.IsMe(roller) and others or nil,
        onRoll = function(v, verified) OnGroupRoll(game, roller, v, verified) end,
    })
    if ns.IsMe(roller) then
        ns.Sound("turn")
        game.status = ("Your roll: 1-%d"):format(max)
        ns.UI.SetRollPrompt(1, max, "Roll 1-" .. max)
    else
        game.status = ("Waiting for %s to roll 1-%d"):format(ns.Short(roller), max)
        ns.UI.SetRollPrompt(nil)
    end
    ns.UI.Refresh()
    -- too slow: the first other player still in knocks them out and tells everyone
    C_Timer.After(GDR.TURN_TIMEOUT, function()
        if Games.Get(game.id) ~= game or game.n ~= step or game.state ~= "play" then return end
        local judge
        for _, p in ipairs(game.alive) do
            if not ns.SameName(p, roller) then judge = p break end
        end
        if not (judge and ns.IsMe(judge)) then return end
        SendAll(game, "GDR_KICK", { id = game.id, w = ns.Full(roller), k = step })
        KnockOut(game, roller, "took too long to roll", false)
    end)
end

--- /gg cancel in a group game: close or leave the room, or forfeit mid-game.
function GDR.Leave(game, why)
    if game.state == "lobby" then
        if IsHost(game) then
            SendAll(game, "GDR_CLOSE", { id = game.id })
            ns.Log("Group deathroll room closed%s.", why and (" (" .. why .. ")") or "")
        else
            Comm.Send("GDR_LEAVE", { id = game.id }, game.host)
            ns.Log("You left %s's group deathroll.", ns.Short(game.host))
        end
        Games.Remove(game)
        return true
    end
    if not game.iAmOut then
        SendAll(game, "GDR_LEAVE", { id = game.id, k = game.n })
        KnockOut(game, ns.Me(), "forfeited", false)
        if Games.Get(game.id) == game then
            ns.Print("You forfeited. GuildGambit keeps watching so your wager goes to whoever wins - |cffffff00/gg cancel|r again to stop watching (nothing is recorded then).")
        end
        return true
    end
    if not game.leaveArmed then
        game.leaveArmed = true
        ns.Print("You're out, waiting to see who wins so your debt goes to the right player. |cffffff00/gg cancel|r again to stop watching (nothing is recorded then).")
        return true
    end
    ns.Log("Stopped watching the group deathroll - no result recorded.")
    Games.Remove(game)
    return true
end

---------------------------------------------------------------------------
-- Group deathroll messages
---------------------------------------------------------------------------
local function MyRoom(id, host)
    local game = Games.Get(id)
    if game and game.kind == "groupdr" and (not host or ns.SameName(game.host, host)) then return game end
end

Comm.On("GDR_OPEN", function(f, sender)
    local bet, start = tonumber(f.s), tonumber(f.n)
    if not f.id or not bet or bet < 0 or not start or start < 2 or start > DR.MAX_START then return end
    if Games.Busy() or not ns.Guild.Allowed(sender) then return end
    if ns.House.CheckOpponent(sender) then return end -- versions don't match (shown in chat)
    if ns.CantCover(bet) then
        ns.Log("%s opened a group deathroll for %s each - more than you can cover.", ns.Short(sender), ns.Stake(bet))
        return
    end
    local text = ("%s opened a group deathroll for %s each (1-%d). Last one standing takes the pot. Join?"):format(
        ns.Short(sender), ns.Stake(bet), start)
    ns.UI.ShowInvite(text, function()
        if Games.Busy() then ns.Print("Finish your current game first.") return end
        if ns.CantCover(bet) then ns.Print("You can't cover %s.", ns.Stake(bet)) return end
        local game = NewRoom({ id = f.id, host = sender, bet = bet, start = start, players = { sender, ns.Me() } })
        Comm.Send("GDR_JOIN", { id = f.id }, sender)
        ns.Log("Joined %s's group deathroll - waiting for them to start.", ns.Short(sender))
        UpdateLobbyStatus(game)
        C_Timer.After(GDR.LOBBY_TIMEOUT + 30, function()
            if Games.Get(game.id) == game and game.state == "lobby" then
                Games.Remove(game)
                ns.Log("%s's group deathroll never started.", ns.Short(sender))
            end
        end)
    end, function() end)
end)

Comm.On("GDR_JOIN", function(f, sender)
    local game = MyRoom(f.id)
    local function no(reason) Comm.Send("GDR_NO", { id = f.id, r = reason }, sender) end
    if not game or not IsHost(game) then return no("the room is closed") end
    if game.state ~= "lobby" then return no("it already started") end
    if not ns.Guild.Allowed(sender) then return no("not in my guild") end
    local why = ns.House.CheckOpponent(sender)
    if why then return no(why) end
    if not IndexOf(game.players, sender) then
        if #game.players >= GDR.MAX_PLAYERS then return no("the room is full") end
        game.players[#game.players + 1] = sender
        ns.Log("%s joined your group deathroll (%d players).", ns.Short(sender), #game.players)
        ns.Sound("invite")
    end
    SendAll(game, "GDR_LOBBY", { id = game.id, p = Names(game.players) })
    UpdateLobbyStatus(game)
end)

Comm.On("GDR_NO", function(f, sender)
    local game = MyRoom(f.id, sender)
    if game and game.state == "lobby" then
        ns.Log("Couldn't join %s's group deathroll (%s).", ns.Short(sender), f.r or "no reason")
        Games.Remove(game)
    end
end)

Comm.On("GDR_LOBBY", function(f, sender)
    local game = MyRoom(f.id, sender)
    if game and game.state == "lobby" and not IsHost(game) then
        game.players = HostFirst(ParseNames(f.p), sender)
        UpdateLobbyStatus(game)
    end
end)

Comm.On("GDR_START", function(f, sender)
    local game = MyRoom(f.id, sender)
    if not game or game.state ~= "lobby" or IsHost(game) then return end
    game.players = HostFirst(ParseNames(f.p), sender)
    if not IndexOf(game.players, ns.Me()) then
        ns.Log("%s started the group deathroll without you.", ns.Short(sender))
        Games.Remove(game)
        return
    end
    BeginPlay(game)
end)

Comm.On("GDR_CLOSE", function(f, sender)
    local game = MyRoom(f.id, sender)
    if game and game.state == "lobby" then
        ns.Log("%s closed the group deathroll.", ns.Short(sender))
        Games.Remove(game)
    end
end)

Comm.On("GDR_LEAVE", function(f, sender)
    local game = MyRoom(f.id)
    if not game then return end
    if game.state == "lobby" and IsHost(game) then
        local i = IndexOf(game.players, sender)
        if i then
            table.remove(game.players, i)
            ns.Log("%s left your group deathroll (%d players).", ns.Short(sender), #game.players)
            SendAll(game, "GDR_LOBBY", { id = game.id, p = Names(game.players) })
            UpdateLobbyStatus(game)
        end
    elseif game.state == "play" then
        KnockOut(game, sender, "forfeited", false)
    end
end)

Comm.On("GDR_KICK", function(f, sender)
    local game = MyRoom(f.id)
    if not game or game.state ~= "play" or not IndexOf(game.players, sender) then return end
    if tonumber(f.k) == game.n and game.turn and ns.SameName(game.turn, f.w) then
        KnockOut(game, f.w, "took too long to roll", false)
    end
end)

Comm.On("GDR_END", function(f, sender)
    local game = MyRoom(f.id)
    if not game or game.state ~= "play" or not IndexOf(game.players, sender) then return end
    local i = IndexOf(game.players, f.w)
    if not i then return end
    local winner = game.players[i]
    ns.Log("%s's addon saw the end of the group deathroll first - catching up.", ns.Short(sender))
    game.alive = { winner }
    Finish(game, winner)
end)
