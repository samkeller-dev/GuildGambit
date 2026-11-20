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
        ns.Print(Games.BusyText())
        return nil
    end
    local stake = ns.GoldToCopper(stakeGold)
    if not stake then ns.Print("Usage: /gg dr <player|practice> <wager> [start]  (wager like 10 or 1g 50s)") return nil end
    local cant, cantYou = ns.CantCover(stake)
    if cant then ns.Print("Can't bet %s: %s.", ns.Stake(stake), cantYou) return nil end
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
        Comm.Send("DR_INV", { id = game.id, s = stake, n = start, rm = Games.rematchTag }, target)
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
    if ns.db.dnd then return no("do not disturb") end
    if not ns.Guild.Allowed(sender) then return no("not in my guild") end
    local why = ns.House.CheckOpponent(sender) -- e.g. their GuildGambit is outdated (shown in chat)
    if why then return no(why) end
    local cant = ns.CantCover(stake)
    if cant then return no("can't cover " .. ns.Stake(stake) .. " - " .. cant) end

    local text = ("%s%s challenges you to a deathroll for %s (1-%d). They roll first."):format(
        ns.RematchText(f.rm), ns.Short(sender), ns.Stake(stake), start)
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
-- After a reload (see Games.lua): the opponent's addon tells ours where the game stands.
---------------------------------------------------------------------------
local function LastRollFields(game, fields, nameOf)
    local lr = game.lastRoll
    if lr then fields.lv, fields.lm, fields.lw = lr.value, lr.max, nameOf(lr.who) end
    return fields
end

--- Picks the game up at step k (k is the step whose roll is awaited).
local function ResumeAt(game, k, turn, max)
    Rolls.UnwatchPrefix(game.id .. ":")
    game.n, game.turn, game.max = k - 1, turn, max
    NextTurn(game)
end

Games.recovery.deathroll = {
    answer = function(game, asker)
        if game.state ~= "play" or not ns.SameName(game.opponent, asker) then return end
        Comm.Send("GG_HERE", LastRollFields(game, {
            id = game.id, g = "deathroll", A = ns.Full(game.a), B = ns.Full(game.b), s = game.stake,
            n = game.start, k = game.n, tu = game.turn == game.a and "a" or "b", m = game.max,
            v = game.verified ~= false and 1 or 0,
        }, function(who) return who == game.a and "a" or "b" end), asker)
        ns.Log("%s reloaded mid-deathroll - their addon is catching up.", ns.Short(asker))
    end,
    here = function(f, sender)
        local stake, start, k, m = tonumber(f.s), tonumber(f.n), tonumber(f.k), tonumber(f.m)
        if not (stake and start and k and m) or stake < 0 or k < 1 or m < 2 or m > start or start > DR.MAX_START then return end
        if f.tu ~= "a" and f.tu ~= "b" then return end
        -- one of the two must be us and the other the player telling us
        local iAmA = ns.IsMe(f.A or "")
        if iAmA == ns.IsMe(f.B or "") then return end
        if not ns.SameName(iAmA and f.B or f.A, sender) then return end
        local game = Games.Get(f.id)
        if game then
            -- a second answer (we asked more than once): only a later step moves us on
            if game.kind == "deathroll" and game.state == "play" and ns.SameName(game.opponent, sender) and k > game.n then
                ResumeAt(game, k, f.tu == "a" and game.a or game.b, m)
            end
            return
        end
        if Games.Mine() then return end
        local a = iAmA and ns.Me() or sender
        local b = iAmA and sender or ns.Me()
        game = NewGame({ id = f.id, a = a, b = b, opponent = sender, stake = stake, start = start })
        game.state, game.verified = "play", f.v ~= "0"
        if k > 1 then game.history[1] = "(before your reload)" end
        local lv, lm = tonumber(f.lv), tonumber(f.lm)
        if lv and lm and (f.lw == "a" or f.lw == "b") then
            game.lastRoll = { who = f.lw == "a" and a or b, value = lv, max = lm, seq = #game.history }
        end
        ns.Log("Back in your deathroll vs %s after the reload - caught up from their addon.", ns.Short(sender))
        ResumeAt(game, k, f.tu == "a" and a or b, m)
    end,
}

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
CF.COUNTDOWN = 3       -- seconds from "both ready" to the flip
CF.LOBBY_TIMEOUT = 90  -- both must click Ready within this long
CF.SPIN = 1.2          -- the coin spins this long on screen before the result is revealed
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
    game.state = "done"
    local mine = game.practice and game.call or CF.SideOf(game, ns.Me())
    local won = landed == mine
    -- the result (sound, chat line, guild post) waits for the coin to stop spinning
    game.revealDelay = CF.SPIN
    Games.Finish(game, won and game.bet or -game.bet, ("the coin landed on %s"):format(CF.Label(landed)), won and 1 or -1)
end

--- Both players are in: watch for the challenger's roll, which comes after the countdown.
local function Begin(game)
    local mine = game.practice and game.call or CF.SideOf(game, ns.Me())
    ns.Log("Coinflip vs %s for %s: you're %s.", ns.Short(game.opponent), ns.Stake(game.bet), CF.Label(mine))
    local key = game.id .. ":flip"
    Rolls.Watch({
        player = game.a, min = 1, max = 2, key = key,
        relayTo = (ns.IsMe(game.a) and not game.practice) and { game.opponent } or nil,
        onRoll = function(v, verified) Land(game, v, verified) end,
    })
    return key
end

--- 3, 2, 1... then the challenger flips. Both sides count down (the opponent's from CF_GO).
local function Countdown(game)
    if game.state ~= "lobby" then return end
    game.state = "countdown"
    ns.UI.SetRollPrompt(nil)
    local key = Begin(game)
    local left = CF.COUNTDOWN
    local function tick()
        if Games.Get(game.id) ~= game or game.state ~= "countdown" then return end
        if left > 0 then
            game.status = ("Flipping in %d..."):format(left)
            game.specStatus = game.status
            ns.Sound("card")
            left = left - 1
            ns.UI.Refresh()
            C_Timer.After(1, tick)
            return
        end
        game.state = "play"
        ns.Sound("coin")
        if ns.IsMe(game.a) or game.practice then
            game.status, game.specStatus = "Flipping...", "Flipping..."
            if Rolls.IsWatching(key) and not Rolls.Roll(1, 2) then
                game.status = "Flip the coin!"
                ns.UI.SetRollPrompt(1, 2, "Flip!") -- RandomRoll unavailable: flip by hand
            end
        else
            game.status = ("%s is flipping..."):format(ns.Short(game.a))
            game.specStatus = "Flipping..."
        end
        ns.UI.Refresh()
    end
    tick()
end

--- The challenger: both ready - tell the opponent and start counting.
local function Go(game)
    if not game.practice then Comm.Send("CF_GO", { id = game.id }, game.opponent) end
    Countdown(game)
end

local function LobbyStatus(game)
    local them = ns.Short(game.opponent)
    if game.ready.me then
        game.status = ("Ready - waiting for %s..."):format(them)
    else
        game.status = game.ready.them and ("%s is ready - click Ready!"):format(them) or "Click Ready when you are."
    end
    local iAmA = ns.IsMe(game.a)
    local readyA = iAmA and game.ready.me or (not iAmA and game.ready.them)
    local readyB = iAmA and game.ready.them or (not iAmA and game.ready.me)
    game.specStatus = ("Waiting for both to ready up (%s%s, %s%s)"):format(ns.Short(game.a), readyA and " ready" or "",
        ns.Short(game.b), readyB and " ready" or "")
end

--- Accepted: both players wait in the lobby until each clicks Ready.
local function Lobby(game)
    game.state = "lobby"
    game.ready = { me = false, them = false }
    LobbyStatus(game)
    ns.UI.SetAction("Ready", function() CF.Ready(game) end)
    ns.UI.Refresh()
    C_Timer.After(CF.LOBBY_TIMEOUT, function()
        if Games.Get(game.id) == game and game.state == "lobby" then Games.Cancel(game, "nobody readied up in time") end
    end)
end

function CF.Ready(game)
    if not game or Games.Get(game.id) ~= game or game.state ~= "lobby" or game.ready.me then return false end
    game.ready.me = true
    ns.UI.SetRollPrompt(nil)
    if game.practice then Go(game) return true end
    if ns.IsMe(game.a) then
        if game.ready.them then Go(game) return true end
    else
        -- tell the challenger, and keep telling them until the countdown starts
        local function send()
            if Games.Get(game.id) ~= game or game.state ~= "lobby" then return end
            Comm.Send("CF_READY", { id = game.id }, game.opponent)
            C_Timer.After(CF.ACCEPT_RETRY, send)
        end
        send()
    end
    LobbyStatus(game)
    ns.UI.Refresh()
    return true
end

--- Coinflip against a guildie, or practice. call: "A"/"H" or a word (default: your faction).
function CF.Challenge(target, betGold, call)
    if Games.Busy() then
        ns.Print(Games.BusyText())
        return nil
    end
    local bet = ns.GoldToCopper(betGold)
    if not bet then ns.Print("Usage: /gg flip <wager> <player|practice> [alliance|horde]") return nil end
    if not target or target == "" then ns.Print("Pick an opponent (or Practice) first.") return nil end
    call = CF.SIDES[call or ""] and call or CF.ParseCall(call) or MyFaction()
    local practice = target:lower() == "practice" or ns.IsMe(target)
    if not practice then
        local cant, cantYou = ns.CantCover(bet)
        if cant then ns.Print("Can't bet %s: %s.", ns.Stake(bet), cantYou) return nil end
    end
    target = practice and CF.PRACTICE or ns.Full(target)
    if not practice and ns.House.CheckOpponent(target) then return nil end
    local game = Games.Add({
        kind = "coinflip", title = "Coinflip", id = ns.NewId(), a = ns.Me(), b = target, opponent = target,
        bet = bet, call = call, practice = practice, verified = true, state = "invite",
    })
    if practice then
        Lobby(game)
        return game
    end
    game.status = ("Waiting for %s to accept..."):format(ns.Short(target))
    Comm.Send("CF_INV", { id = game.id, s = bet, c = call, rm = Games.rematchTag }, target)
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
    if ns.db.dnd then return no("do not disturb") end
    if not ns.Guild.Allowed(sender) then return no("not in my guild") end
    local why = ns.House.CheckOpponent(sender) -- e.g. their GuildGambit is outdated (shown in chat)
    if why then return no(why) end
    local cant = ns.CantCover(bet)
    if cant then return no("can't cover " .. ns.Stake(bet) .. " - " .. cant) end
    local text = ("%s%s flips a coin for %s and calls %s - you're %s. Winner takes the pot."):format(
        ns.RematchText(f.rm), ns.Short(sender), ns.Stake(bet), CF.Label(f.c), CF.Label(OtherSide(f.c)))
    ns.UI.ShowInvite(text, function()
        if Games.Busy() then return no("busy") end
        if ns.CantCover(bet) then return no("can't cover the bet") end
        local game = Games.Add({
            kind = "coinflip", title = "Coinflip", id = f.id, a = sender, b = ns.Me(), opponent = sender,
            bet = bet, call = f.c, verified = true, state = "invite",
        })
        Comm.Send("CF_ACC", { id = f.id }, sender)
        Lobby(game)
        -- if our "accepted" got lost the challenger never joins the lobby: resend until they answer
        local tries = 0
        local function retry()
            if Games.Get(game.id) ~= game or game.heard then return end
            tries = tries + 1
            if tries > CF.ACCEPT_RETRIES then return Games.Cancel(game, ns.Short(sender) .. " never answered") end
            Comm.Send("CF_ACC", { id = f.id }, sender)
            C_Timer.After(CF.ACCEPT_RETRY, retry)
        end
        C_Timer.After(CF.ACCEPT_RETRY, retry)
    end, function() no("declined") end)
end)

Comm.On("CF_ACC", function(f, sender)
    local game = TheirFlip(f, sender)
    if game then
        if game.state == "invite" then Lobby(game) end
        Comm.Send("CF_HI", { id = f.id }, sender) -- "I'm in the lobby too"
        return
    end
    Comm.Send("CF_GONE", { id = f.id }, sender)
end)

Comm.On("CF_HI", function(f, sender)
    local game = TheirFlip(f, sender)
    if game then game.heard = true end
end)

-- the opponent is ready (challenger's side)
Comm.On("CF_READY", function(f, sender)
    local game = TheirFlip(f, sender)
    if not game then return end
    game.heard = true
    if game.state == "lobby" then
        game.ready.them = true
        if game.ready.me then return Go(game) end
        LobbyStatus(game)
        ns.Sound("card")
        ns.UI.Refresh()
    elseif game.state == "countdown" or game.state == "play" then
        Comm.Send("CF_GO", { id = game.id }, sender) -- our "go" got lost
    end
end)

-- both ready: count down (opponent's side)
Comm.On("CF_GO", function(f, sender)
    local game = TheirFlip(f, sender)
    if not game then return end
    game.heard = true
    if game.state == "lobby" then
        game.ready.them = true
        Countdown(game)
    end
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
GDR.WARN_AT = 30        -- seconds left when the roller gets a loud last warning
GDR.KICK_GRACE = 5      -- the judge waits a little past the countdown (the roller may have seen the turn late)
GDR.JUDGE_BACKUP = 10  -- if the judge's addon is gone, the next player kicks this much later
GDR.START_RESEND = 3   -- the host repeats "started" a couple of times in case one is lost
GDR.SYNC_WAIT = 4       -- seconds before trusting someone else's view of the game over ours
GDR.STALE = 300         -- nothing happening for this long: our addon has lost the game, drop it

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

--- Tells the room where the game stands after a turn change, so an addon that missed a roll
--- (or a kick) catches up instead of waiting forever for a roll that already happened.
local function SyncState(game)
    if game.state ~= "play" then return end
    SendAll(game, "GDR_TURN", { id = game.id, k = game.n, i = game.turnIdx, m = game.max, a = Names(game.alive) })
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
        ns.Print(Games.BusyText())
        return nil
    end
    if not (IsInGuild and IsInGuild()) then ns.Print("Group deathrolls are for your guild - you're not in one.") return nil end
    local bet = ns.GoldToCopper(betText)
    if not bet then ns.Print("Usage: /gg group <wager> [start]  (wager like 10 or 1g50s)") return nil end
    local cant, cantYou = ns.CantCover(bet)
    if cant then ns.Print("Can't bet %s: %s.", ns.Stake(bet), cantYou) return nil end
    start = math.floor(tonumber(start) or DR.DEFAULT_START)
    if start < 2 or start > DR.MAX_START then ns.Print("Start must be 2-%d.", DR.MAX_START) return nil end

    local game = NewRoom({ id = ns.NewId(), host = ns.Me(), bet = bet, start = start, players = { ns.Me() } })
    Comm.Send("GDR_OPEN", { id = game.id, s = bet, n = start, rm = Games.rematchTag }, nil)
    ns.Log("You opened a group deathroll for %s (1-%d). Press Start once guildies have joined.",
        ns.StakeEach(bet), start)
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
    ns.Log("Group deathroll for %s: %s. %s first.", ns.StakeEach(game.bet), NamesText(game.players),
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
    -- kept a while, for a player whose addon reloaded before the end
    Games.Remember(game.id, game.players, {
        { "GG_PLY", { id = game.id, p = Names(game.players) } },
        { "GG_DONE", { id = game.id, g = "groupdr", w = IndexOf(game.players, winner), s = game.bet, n = game.start,
            v = verified and 1 or 0 } },
    })
    game.finished, game.net, game.outcome = true, net, outcome
    game.summary = ("%s %s the last one standing out of %d"):format(iWon and "you" or ns.Short(winner),
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

--- Our own roll was counted: tell the room the new state (the roller's addon always saw it).
local function AfterMyRoll(game)
    if Games.Get(game.id) == game then SyncState(game) end
end

local function Clock(secs)
    return ("%d:%02d"):format(math.floor(secs / 60), secs % 60)
end

--- The turn line, with the time left to roll.
local function TurnStatus(game, roller, max)
    local left = math.max(0, math.ceil((game.turnEnds or 0) - GetTime()))
    local timeText = left <= GDR.WARN_AT and ("|cffff4040%s left|r"):format(Clock(left)) or (Clock(left) .. " left")
    if ns.IsMe(roller) then return ("Your roll: 1-%d (%s)"):format(max, timeText), left end
    return ("Waiting for %s to roll 1-%d (%s)"):format(ns.Short(roller), max, timeText), left
end


--- Counts the turn down once a second on the status line, until the turn changes.
local function TickTurn(game, step, roller, max)
    C_Timer.After(1, function()
        if Games.Get(game.id) ~= game or game.n ~= step or game.state ~= "play" then return end
        local left
        game.status, left = TurnStatus(game, roller, max)
        ns.UI.Refresh()
        if left > 0 then TickTurn(game, step, roller, max) end
    end)
end

--- The next turn. left: seconds the roller has (default the full TURN_TIMEOUT; less when we
--- pick a game back up after a reload).
function GroupTurn(game, left)
    left = math.max(0, math.min(GDR.TURN_TIMEOUT, left or GDR.TURN_TIMEOUT))
    game.n = game.n + 1
    local roller, max, step = game.alive[game.turnIdx], game.max, game.n
    game.turn = roller
    local others = {}
    for _, p in ipairs(game.players) do if not ns.IsMe(p) then others[#others + 1] = p end end
    Rolls.Watch({
        player = roller, min = 1, max = max, key = game.id .. ":" .. step,
        relayTo = ns.IsMe(roller) and others or nil,
        onRoll = function(v, verified)
            OnGroupRoll(game, roller, v, verified)
            if ns.IsMe(roller) then AfterMyRoll(game) end
        end,
    })
    game.turnEnds = GetTime() + left
    game.status = TurnStatus(game, roller, max)
    if ns.IsMe(roller) then
        ns.Sound("turn")
        ns.UI.SetRollPrompt(1, max, "Roll 1-" .. max)
        -- said in chat too, so it's seen with the window closed
        ns.Print("|cffffff00Your turn in the group deathroll: /roll %d|r - %d seconds or you're out.", max, left)
    else
        ns.UI.SetRollPrompt(nil)
    end
    ns.UI.Refresh()
    TickTurn(game, step, roller, max)
    -- last warning
    if left > GDR.WARN_AT then
        C_Timer.After(left - GDR.WARN_AT, function()
            if Games.Get(game.id) ~= game or game.n ~= step or game.state ~= "play" then return end
            if ns.IsMe(roller) then
                ns.Sound("hurry")
                ns.Print("|cffff4040%d seconds left to /roll %d in the group deathroll, or you're out!|r", GDR.WARN_AT, max)
            else
                ns.Log("%s has %d seconds left to roll.", ns.Short(roller), GDR.WARN_AT)
            end
        end)
    end
    -- too slow: the first other player still in knocks them out and tells everyone. If that
    -- player's addon is gone (reloading, disconnected), the next one does it a little later,
    -- and so on - a kick that already happened moves the step on, so only one ever counts.
    local judges = {}
    for _, p in ipairs(game.alive) do
        if not ns.SameName(p, roller) then judges[#judges + 1] = p end
    end
    for j, judge in ipairs(judges) do
        if ns.IsMe(judge) then
            C_Timer.After(left + GDR.KICK_GRACE + (j - 1) * GDR.JUDGE_BACKUP, function()
                if Games.Get(game.id) ~= game or game.n ~= step or game.state ~= "play" then return end
                SendAll(game, "GDR_KICK", { id = game.id, w = ns.Full(roller), k = step })
                KnockOut(game, roller, "took too long to roll", false)
                if Games.Get(game.id) == game then SyncState(game) end
            end)
        end
    end
    -- nothing at all for minutes (everyone's addon gone quiet, or ours lost track): let go,
    -- so the addon isn't stuck in a game that's over
    C_Timer.After(GDR.STALE, function()
        if Games.Get(game.id) ~= game or game.n ~= step or game.state ~= "play" then return end
        ns.Log("|cffff8040Lost track of the group deathroll|r - nothing happened for %d minutes, so it's been dropped (no result recorded). Check the result with the others.",
            GDR.STALE / 60)
        Games.Remove(game)
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
    if ns.db.dnd then return end -- do not disturb: not even the invite
    if ns.House.CheckOpponent(sender) then return end -- versions don't match (shown in chat)
    if ns.CantCover(bet) then
        ns.Log("%s opened a group deathroll for %s - more than you can cover.", ns.Short(sender), ns.StakeEach(bet))
        return
    end
    local text = ("%s%s opened a group deathroll for %s (1-%d). The last one standing takes the pot. Join?"):format(
        ns.RematchText(f.rm), ns.Short(sender), ns.StakeEach(bet), start)
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

-- someone's view of the game after a turn change: if ours is behind (or disagrees at the same
-- step), we missed something - take theirs
local function TakeTurnState(f, sender)
    local game = MyRoom(f.id)
    if not game or game.state ~= "play" or not IndexOf(game.players, sender) then return end
    local k, i, m = tonumber(f.k), tonumber(f.i), tonumber(f.m)
    local alive = ParseNames(f.a)
    if not k or not i or not m or k < game.n or #alive < 2 or i < 1 or i > #alive or m < 2 or m > game.start then return end
    for _, n in ipairs(alive) do if not IndexOf(game.players, n) then return end end
    local same = k == game.n and game.max == m and #alive == #(game.alive or {})
        and ns.SameName(game.alive[game.turnIdx] or "", alive[i])
    if same then return end
    Rolls.UnwatchPrefix(game.id .. ":")
    -- keep our own spelling of our name in the list
    for j, n in ipairs(alive) do
        local mine = IndexOf(game.players, n)
        alive[j] = game.players[mine]
    end
    for _, n in ipairs(game.alive or {}) do
        if not IndexOf(alive, n) and not IndexOf(game.out, n) then game.out[#game.out + 1] = n end
    end
    game.alive, game.turnIdx, game.max, game.n = alive, i, m, k - 1
    if not IndexOf(alive, ns.Me()) and not game.iAmOut then
        game.iAmOut = true
        ns.UI.SetRollPrompt(nil)
    end
    ns.Log("Your addon missed part of the group deathroll - caught up from %s.", ns.Short(sender))
    GroupTurn(game)
end

Comm.On("GDR_TURN", function(f, sender)
    -- (give the roll itself a moment to arrive the normal way first)
    C_Timer.After(GDR.SYNC_WAIT, function() TakeTurnState(f, sender) end)
end)

Comm.On("GDR_END", function(f, sender)
    local game = MyRoom(f.id)
    if not game or (game.state ~= "play" and game.state ~= "lobby") or not IndexOf(game.players, sender) then return end
    local i = IndexOf(game.players, f.w)
    if not i then return end
    local winner = game.players[i]
    ns.Log("%s's addon saw the end of the group deathroll first - catching up.", ns.Short(sender))
    game.alive = { winner }
    Finish(game, winner)
end)

---------------------------------------------------------------------------
-- Group deathroll after a reload (see Games.lua). Every player still in the room answers with
-- the player list (GG_PLY, sent first) and where the game stands (GG_HERE), or with the
-- result if it ended meanwhile (GG_DONE). Several answers can disagree if one addon missed a
-- roll: the latest step wins, and at the same step the host's - the same rule on every client,
-- whatever order the answers arrive in. The normal turn updates fix anything left over.
---------------------------------------------------------------------------
local recoverPlayers = {} -- id -> { from = name, list = { names } } (the list a GG_HERE/GG_DONE refers to)

Comm.On("GG_PLY", function(f, sender)
    if not f.id or not (Games.recovering or Games.Get(f.id)) then return end
    local list = ParseNames(f.p)
    if #list < GDR.MIN_PLAYERS or #list > GDR.MAX_PLAYERS then return end
    recoverPlayers[f.id] = { from = sender, list = list }
end)

--- The player list the sender just sent for this room, if it has us and them in it.
local function SentPlayers(f, sender)
    local p = recoverPlayers[f.id]
    if not p or not ns.SameName(p.from, sender) then return nil end
    local list = {}
    for i, n in ipairs(p.list) do list[i] = ns.IsMe(n) and ns.Me() or n end
    if not IndexOf(list, ns.Me()) or not IndexOf(list, sender) then return nil end
    return list
end

local function ArmLobbyTimeout(game)
    if IsHost(game) then
        C_Timer.After(GDR.LOBBY_TIMEOUT, function()
            if Games.Get(game.id) == game and game.state == "lobby" then Games.Cancel(game, "nobody started it") end
        end)
    else
        C_Timer.After(GDR.LOBBY_TIMEOUT + 30, function()
            if Games.Get(game.id) == game and game.state == "lobby" then
                Games.Remove(game)
                ns.Log("%s's group deathroll never started.", ns.Short(game.host))
            end
        end)
    end
end

--- Rebuilds a running game at step k from an answer: alive = names, i = whose turn, m = range.
local function ResumeGroup(game, k, alive, i, m, left)
    Rolls.UnwatchPrefix(game.id .. ":")
    game.state = "play"
    game.alive, game.turnIdx, game.max, game.n = alive, i, m, k - 1
    game.out = {}
    for _, n in ipairs(game.players) do
        if not IndexOf(alive, n) then game.out[#game.out + 1] = n end
    end
    game.iAmOut = not IndexOf(alive, ns.Me()) or nil
    if game.iAmOut then ns.UI.SetRollPrompt(nil) end
    GroupTurn(game, left)
end

GDR.recovery = {
    answer = function(game, asker)
        if not IndexOf(game.players, asker) then return end
        if game.state == "lobby" then
            -- the host's list is the real one: only the host answers a player, and every player
            -- answers the host (who merges what they say)
            local askerIsHost = ns.SameName(game.host, asker)
            if not (IsHost(game) or askerIsHost) then return end
            Comm.Send("GG_PLY", { id = game.id, p = Names(game.players) }, asker)
            Comm.Send("GG_HERE", { id = game.id, g = "groupdr", st = "lobby", s = game.bet, n = game.start }, asker)
            return
        end
        if game.state ~= "play" then return end
        local alive = {}
        for _, n in ipairs(game.alive) do alive[#alive + 1] = IndexOf(game.players, n) end
        local fields = {
            id = game.id, g = "groupdr", st = "play", s = game.bet, n = game.start, k = game.n,
            i = game.turnIdx, m = game.max, a = table.concat(alive, "."),
            t = math.max(0, math.floor((game.turnEnds or GetTime()) - GetTime())),
            v = game.verified ~= false and 1 or 0,
        }
        local lr = game.lastRoll
        if lr then fields.lv, fields.lm, fields.lw = lr.value, lr.max, IndexOf(game.players, lr.who) end
        Comm.Send("GG_PLY", { id = game.id, p = Names(game.players) }, asker)
        Comm.Send("GG_HERE", fields, asker)
    end,

    here = function(f, sender)
        local list = SentPlayers(f, sender)
        local bet, start = tonumber(f.s), tonumber(f.n)
        if not list or not bet or bet < 0 or not start or start < 2 or start > DR.MAX_START then return end
        local game = Games.Get(f.id)
        if game and game.kind ~= "groupdr" then return end
        if not game and Games.Mine() then return end -- (in another game by now)

        if f.st == "lobby" then
            if not game then
                game = NewRoom({ id = f.id, host = list[1], bet = bet, start = start, players = list })
                ns.Log("Back in the group deathroll lobby after the reload.")
                ArmLobbyTimeout(game)
            elseif game.state == "lobby" and IsHost(game) then
                -- the host hears from every player: anyone in any list is in
                for _, n in ipairs(list) do
                    if not IndexOf(game.players, n) and #game.players < GDR.MAX_PLAYERS then game.players[#game.players + 1] = n end
                end
            else
                return
            end
            if IsHost(game) then SendAll(game, "GDR_LOBBY", { id = game.id, p = Names(game.players) }) end
            UpdateLobbyStatus(game)
            return
        end

        if f.st ~= "play" then return end
        local k, i, m, left = tonumber(f.k), tonumber(f.i), tonumber(f.m), tonumber(f.t) or GDR.TURN_TIMEOUT
        local alive = {}
        for idx in tostring(f.a or ""):gmatch("%d+") do
            local n = list[tonumber(idx)]
            if not n or IndexOf(alive, n) then return end
            alive[#alive + 1] = n
        end
        if not k or k < 1 or #alive < 2 or not i or i < 1 or i > #alive or not m or m < 2 or m > start then return end

        if game and game.state == "play" then
            -- another answer: a later step wins; at the same step, the host's view wins
            local fromHost = ns.SameName(list[1], sender)
            local same = k == game.n and game.max == m and #alive == #game.alive
                and ns.SameName(game.alive[game.turnIdx] or "", alive[i])
            if k > game.n or (k == game.n and fromHost and not same) then
                for j, n in ipairs(alive) do alive[j] = game.players[IndexOf(game.players, n) or 0] or n end
                ResumeGroup(game, k, alive, i, m, left)
            end
            return
        end
        if not game then
            game = NewRoom({ id = f.id, host = list[1], bet = bet, start = start, players = list })
        else
            game.players = list -- (our lobby, which started while we were away)
        end
        game.verified = f.v ~= "0"
        if k > 1 then game.history[1] = "(before your reload)" end
        local lv, lm, lw = tonumber(f.lv), tonumber(f.lm), list[tonumber(f.lw) or 0]
        if lv and lm and lw then game.lastRoll = { who = lw, value = lv, max = lm, seq = #game.history } end
        local iAmIn = IndexOf(alive, ns.Me())
        ns.Log("Back in the group deathroll after the reload - caught up from %s.%s", ns.Short(sender),
            iAmIn and "" or " You're already out; the result is recorded when it ends.")
        ResumeGroup(game, k, alive, i, m, left)
    end,

    done = function(f, sender)
        local list = SentPlayers(f, sender)
        local bet, start, w = tonumber(f.s), tonumber(f.n), tonumber(f.w)
        local winner = list and w and list[w]
        if not winner or not bet or bet < 0 or not start then return end
        local game = Games.Get(f.id)
        if game and (game.kind ~= "groupdr" or not IndexOf(game.players, sender)) then return end
        if not game and not Games.recovering then return end
        if not game then
            -- already on our ledger (we saw the end ourselves before reloading)? nothing to do
            if ns.IsMe(winner) then
                for _, p in ipairs(list) do
                    if not ns.IsMe(p) and ns.Ledger.FindGame(f.id, p) then return end
                end
            elseif ns.Ledger.FindGame(f.id, winner) then
                return
            end
            if Games.Mine() then return end
            game = NewRoom({ id = f.id, host = list[1], bet = bet, start = start, players = list })
            game.verified = f.v ~= "0"
            ns.Log("The group deathroll ended while you were reloading.")
        end
        game.state = "play"
        game.alive = { winner }
        Finish(game, winner)
    end,
}
Games.recovery.groupdr = GDR.recovery
