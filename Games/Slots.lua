-- Games/Slots.lua: slots, 1v1. The challenger picks how many spins (1-10); you each spin that
-- many times (a server roll 1-1000 decides all three reels of a spin). The higher total
-- payout wins the bet; equal totals go to the higher total of the rolls themselves;
-- identical totals are a push. Practice is a solo spin paid by the paytable.
local ADDON_NAME, ns = ...
local Games, Rolls, Comm = ns.Games, ns.Rolls, ns.Comm
local Rules = ns.Rules.Slots

local SL = {}
ns.Slots = SL

SL.INVITE_TIMEOUT = 60
SL.ACCEPT_RETRY = 5
SL.ACCEPT_RETRIES = 6
SL.PRACTICE = "Practice"
SL.DEFAULT_SPINS = 3
SL.MAX_SPINS = 10

---------------------------------------------------------------------------
-- Practice: a solo spin against the paytable (no gold changes hands)
---------------------------------------------------------------------------
local function Practice(bet)
    local game = Games.Add({
        kind = "slots", title = "Slots", id = ns.NewId(), opponent = SL.PRACTICE, bet = bet,
        practice = true, verified = true, state = "spin",
    })
    game.status = "Spin! (practice)"
    Rolls.Watch({
        player = ns.Me(), min = Rules.ROLL_MIN, max = Rules.ROLL_MAX, key = game.id .. ":1",
        onRoll = function(v, verified)
            Games.NoteRoll(game, verified)
            local result = Rules.Spin(v)
            game.result = result
            if result.mult >= 25 then game.bigWin = true end
            ns.Sound("roll")
            local m = result.mult - 1
            Games.Finish(game, Rules.Net(game.bet, result), Rules.Describe(result), m > 0 and 1 or m < 0 and -1 or 0)
        end,
    })
    ns.UI.SetRollPrompt(Rules.ROLL_MIN, Rules.ROLL_MAX, "Spin!")
    ns.UI.Refresh()
    return game
end

---------------------------------------------------------------------------
-- 1v1
---------------------------------------------------------------------------
local function MySide(game) return ns.IsMe(game.a) and "a" or "b" end
local function OtherSide(s) return s == "a" and "b" or "a" end

--- "Triple Cherry x8 - spin 2/3, total x10"
function SL.Line(game, s)
    local sp = game.spins[s]
    if sp.count == 0 then return nil end
    local r = sp.last
    return ("%s%s  -  spin %d/%d, total x%d"):format(r.name, r.mult > 0 and (" x" .. r.mult) or "",
        sp.count, game.n, sp.total)
end

local function Resolve(game)
    local mine, theirs = game.spins[MySide(game)], game.spins[OtherSide(MySide(game))]
    local won
    if mine.total ~= theirs.total then won = mine.total > theirs.total
    elseif mine.rollSum ~= theirs.rollSum then won = mine.rollSum > theirs.rollSum end
    local net = won == true and game.bet or (won == false and -game.bet or 0)
    if won and mine.best >= 25 then game.bigWin = true end
    local tie = mine.total == theirs.total and (won ~= nil and " (tie broken by the rolls)" or " (tie)") or ""
    Games.Finish(game, net, ("you x%d vs %s x%d over %d spin%s%s"):format(
        mine.total, ns.Short(game.opponent), theirs.total, game.n, game.n == 1 and "" or "s", tie),
        won == true and 1 or (won == false and -1 or 0))
end

local function Update(game)
    if Games.Get(game.id) ~= game or game.state ~= "play" then return end
    local mine, theirs = game.spins[MySide(game)], game.spins[OtherSide(MySide(game))]
    if mine.count >= game.n and theirs.count >= game.n then return Resolve(game) end
    if mine.count < game.n then
        game.status = ("Your spin %d of %d"):format(mine.count + 1, game.n)
        ns.UI.SetRollPrompt(Rules.ROLL_MIN, Rules.ROLL_MAX, ("Spin! (%d/%d)"):format(mine.count + 1, game.n))
    else
        game.status = ("Done (total x%d) - waiting for %s"):format(mine.total, ns.Short(game.opponent))
        ns.UI.SetRollPrompt(nil)
    end
    ns.UI.Refresh()
end

local function WatchSpin(game, s)
    local sp = game.spins[s]
    if sp.count >= game.n then return end
    local i = sp.count + 1
    local player = s == "a" and game.a or game.b
    Rolls.Watch({
        player = player, min = Rules.ROLL_MIN, max = Rules.ROLL_MAX, key = game.id .. ":" .. s .. i,
        relayTo = ns.IsMe(player) and { game.opponent } or nil,
        onRoll = function(v, verified)
            if sp.count ~= i - 1 then return end
            Games.NoteRoll(game, verified)
            local result = Rules.Spin(v)
            sp.count, sp.last = i, result
            sp.total, sp.rollSum = sp.total + result.mult, sp.rollSum + v
            if result.mult > sp.best then sp.best = result.mult end
            -- the table shows your latest reels and theirs
            if s == MySide(game) then game.result = result else game.theirResult = result end
            ns.Sound("roll")
            WatchSpin(game, s)
            Update(game)
        end,
    })
end

local function NewDuel(fields)
    fields.kind, fields.mode, fields.title = "slots", "duel", "Slots duel"
    fields.verified = true
    fields.spins = {
        a = { count = 0, total = 0, rollSum = 0, best = 0 },
        b = { count = 0, total = 0, rollSum = 0, best = 0 },
    }
    return Games.Add(fields)
end

local function Begin(game)
    game.state = "play"
    ns.Log("Slots vs %s for %s: %d spin%s each, the higher total payout wins.", ns.Short(game.opponent),
        ns.Stake(game.bet), game.n, game.n == 1 and "" or "s")
    WatchSpin(game, "a")
    WatchSpin(game, "b")
    Update(game)
end

local function ValidSpins(n)
    n = math.floor(tonumber(n) or SL.DEFAULT_SPINS)
    if n < 1 then n = 1 elseif n > SL.MAX_SPINS then n = SL.MAX_SPINS end
    return n
end

--- Slots against a guildie (spins: how many each, 1-10), or a solo practice spin.
function SL.Spin(opponent, betGold, spins)
    if Games.Busy() then
        ns.Print("Finish your current game first (or |cffffff00/gg cancel|r).")
        return nil
    end
    local bet = ns.GoldToCopper(betGold)
    if not bet then ns.Print("Usage: /gg slots <wager> <player|practice> [spins]") return nil end
    if not opponent or opponent == "" then
        ns.Print("Pick an opponent (or Practice) first.")
        return nil
    end
    if opponent:lower() == "practice" or ns.IsMe(opponent) then return Practice(bet) end

    local cant = ns.CantCover(bet)
    if cant then ns.Print("Can't bet %s: you %s.", ns.Stake(bet), cant) return nil end
    local n = ValidSpins(spins)
    local target = ns.Full(opponent)
    if ns.House.CheckOpponent(target) then return nil end
    local game = NewDuel({ id = ns.NewId(), a = ns.Me(), b = target, opponent = target, bet = bet, n = n, state = "invite" })
    game.status = ("Waiting for %s to accept..."):format(ns.Short(target))
    Comm.Send("SLD_INV", { id = game.id, s = bet, n = n }, target)
    ns.Log("Challenged %s to slots for %s (%d spin%s each).", ns.Short(target), ns.Stake(bet), n, n == 1 and "" or "s")
    C_Timer.After(SL.INVITE_TIMEOUT, function()
        if Games.Get(game.id) == game and game.state == "invite" then Games.Cancel(game, "no answer") end
    end)
    ns.UI.Refresh()
    return game
end

---------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------
local function TheirGame(f, sender)
    local game = Games.Get(f.id)
    if game and game.kind == "slots" and game.mode == "duel" and ns.SameName(game.opponent, sender) then return game end
end

Comm.On("SLD_INV", function(f, sender)
    local bet, n = tonumber(f.s), tonumber(f.n) or 1
    if not f.id or not bet or bet < 0 or n < 1 or n > SL.MAX_SPINS or n % 1 ~= 0 then return end
    local function no(reason) Comm.Send("SLD_NO", { id = f.id, r = reason }, sender) end
    do return no("Slots was retired in GuildGambit 1.7.0 - challenge them to Kodo Crossing instead") end
    if Games.Busy() then return no("busy") end
    if not ns.Guild.Allowed(sender) then return no("not in my guild") end
    local why = ns.House.CheckOpponent(sender) -- e.g. their GuildGambit is outdated (shown in chat)
    if why then return no(why) end
    local cant = ns.CantCover(bet)
    if cant then return no("can't cover " .. ns.Stake(bet) .. " - " .. cant) end
    local text = ("%s challenges you to slots for %s: %d spin%s each, the higher total payout wins."):format(
        ns.Short(sender), ns.Stake(bet), n, n == 1 and "" or "s")
    ns.UI.ShowInvite(text, function()
        if Games.Busy() then return no("busy") end
        if ns.CantCover(bet) then return no("can't cover the bet") end
        local game = NewDuel({ id = f.id, a = sender, b = ns.Me(), opponent = sender, bet = bet, n = n })
        Comm.Send("SLD_ACC", { id = f.id }, sender)
        Begin(game)
        -- if our "accepted" got lost, resend it until they spin (then give up)
        local tries = 0
        local function retry()
            if Games.Get(game.id) ~= game or game.spins.a.count > 0 then return end
            tries = tries + 1
            if tries > SL.ACCEPT_RETRIES then return Games.Cancel(game, ns.Short(sender) .. " never started") end
            Comm.Send("SLD_ACC", { id = f.id }, sender)
            C_Timer.After(SL.ACCEPT_RETRY, retry)
        end
        C_Timer.After(SL.ACCEPT_RETRY, retry)
    end, function() no("declined") end)
end)

Comm.On("SLD_ACC", function(f, sender)
    local game = TheirGame(f, sender)
    if game then
        if game.state == "invite" then Begin(game) end
        return
    end
    Comm.Send("SLD_GONE", { id = f.id }, sender)
end)

Comm.On("SLD_NO", function(f, sender)
    local game = TheirGame(f, sender)
    if game and game.state == "invite" then
        ns.Log("%s declined slots (%s).", ns.Short(sender), f.r or "no reason")
        Games.Remove(game)
    end
end)

Comm.On("SLD_GONE", function(f, sender)
    local game = TheirGame(f, sender)
    if game and game.spins.a.count == 0 then Games.Cancel(game, "the challenge had expired", true) end
end)
