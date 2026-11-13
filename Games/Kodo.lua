-- Games/Kodo.lua: Kodo Crossing duels (replaced Slots in 1.7.0).
--
-- The challenger picks a wager and a random seed. Once accepted, each player gets ONE run of
-- Kodo Crossing (UI/Arcade.lua) on exactly the same lanes, generated from that seed. Each
-- addon tells the other its score as it climbs and when its run ends; when both runs are
-- over, the higher score wins the wager (a tie is a push).
--
-- Unlike the dice games, a score can't be checked against a server roll: each player's own
-- addon reports it. It's a game between guildies, on trust.
local ADDON_NAME, ns = ...
local Games, Comm = ns.Games, ns.Comm

local KD = {}
ns.Kodo = KD

KD.MIN_VERSION = "1.7.0"    -- older addons don't know this game
KD.INVITE_TIMEOUT = 60
KD.ACCEPT_RETRY, KD.ACCEPT_RETRIES = 5, 6
KD.RESEND = 8               -- resend my final score until they confirm it
KD.RESULT_TIMEOUT = 900     -- give up waiting for their run after 15 minutes
KD.PROGRESS_EVERY = 1       -- at most one progress update a second
KD.done = {}                -- id -> { score, opponent }: finished duels, to answer late requests

local function MySide(game) return ns.IsMe(game.a) and "a" or "b" end
local function Other(s) return s == "a" and "b" or "a" end

local function NewGame(fields)
    fields.kind, fields.title = "kodo", "Kodo Crossing"
    fields.verified = true
    fields.scores, fields.finishedRun = { a = 0, b = 0 }, {}
    return Games.Add(fields)
end

--- Opens the arcade tab and starts my run.
local function Begin(game)
    game.state = "play"
    game.status = "Your run - hop as far as you can!"
    ns.Log("Kodo Crossing vs %s for %s: one run each on the same lanes - the higher score wins.",
        ns.Short(game.opponent), ns.Stake(game.bet))
    ns.UI.SetAction("Play your run", function()
        ns.UI.SetShown(true)
        ns.UI.SelectTab("arcade")
    end)
    ns.Arcade.StartDuel(game)
    ns.Arcade.ShowOpponent(game)
    -- ask for their run (and ask again if it doesn't arrive - a message may get lost)
    local function ask()
        if Games.Get(game.id) ~= game or game.oppRun then return end
        Comm.Send("WATCH", { id = game.id, v = 2 }, game.opponent)
        C_Timer.After(5, ask)
    end
    ask()
    ns.UI.Refresh()
end

--- Challenge target (or "practice" for a solo run).
function KD.Challenge(target, wager)
    if not target or target == "" or target:lower() == "practice" or ns.IsMe(target) then
        ns.UI.SetShown(true)
        ns.UI.SelectTab("arcade")
        return nil
    end
    if Games.Busy() then
        ns.Print("Finish your current game first (or |cffffff00/gg cancel|r).")
        return nil
    end
    local bet = ns.GoldToCopper(wager)
    if not bet then ns.Print("Usage: /gg kodo <wager> <player|practice>  (wager like 10 or 1g 50s)") return nil end
    local cant = ns.CantCover(bet)
    if cant then ns.Print("Can't bet %s: you %s.", ns.Stake(bet), cant) return nil end
    target = ns.Full(target)
    if ns.House.CheckOpponent(target) then return nil end
    local peer = ns.House.peers[target]
    if not peer or not peer.version or ns.House.IsNewer(KD.MIN_VERSION, peer.version) then
        ns.Print("%s needs GuildGambit %s or newer for Kodo Crossing duels.", ns.Short(target), KD.MIN_VERSION)
        return nil
    end
    local game = NewGame({
        id = ns.NewId(), a = ns.Me(), b = target, opponent = target, bet = bet,
        seed = math.random(1, 2147483646), state = "invite",
    })
    game.status = ("Waiting for %s to accept..."):format(ns.Short(target))
    Comm.Send("KD_INV", { id = game.id, s = bet, z = game.seed }, target)
    ns.Log("Challenged %s to Kodo Crossing for %s.", ns.Short(target), ns.Stake(bet))
    C_Timer.After(KD.INVITE_TIMEOUT, function()
        if Games.Get(game.id) == game and game.state == "invite" then Games.Cancel(game, "no answer") end
    end)
    ns.UI.Refresh()
    return game
end

local function Resolve(game)
    local me, them = MySide(game), Other(MySide(game))
    if not (game.finishedRun[me] and game.finishedRun[them]) or game.finished then return end
    local mine, theirs = game.scores[me], game.scores[them]
    local outcome = mine > theirs and 1 or (mine < theirs and -1 or 0)
    KD.done[game.id] = { score = mine, opponent = game.opponent }
    KD.finishedRuns = KD.finishedRuns or {}
    KD.finishedRuns[game.id] = game
    local summary = ("you %d vs %s %d"):format(mine, ns.Short(game.opponent), theirs)
    Games.Finish(game, game.bet * outcome, summary, outcome)
    local text = outcome > 0 and ("|cff20ff20You beat %s's %d - %s!|r"):format(ns.Short(game.opponent), theirs,
        game.bet > 0 and ("you win " .. ns.Money(game.bet)) or "just for fun")
        or outcome < 0 and ("|cffff4040%s scored %d and beat you%s.|r"):format(ns.Short(game.opponent), theirs,
            game.bet > 0 and (" - you lose " .. ns.Money(game.bet)) or "")
        or ("|cffffd100%s also scored %d - a push.|r"):format(ns.Short(game.opponent), theirs)
    ns.Arcade.DuelOver(game, text)
end

local function SendScore(game)
    Comm.Send("KD_SCORE", { id = game.id, sc = game.scores[MySide(game)] }, game.opponent)
end

--- My score went up (from the arcade).
function KD.Progress(game, score)
    local me = MySide(game)
    game.scores[me] = score
    local now = GetTime()
    if now - (game.progressAt or 0) >= KD.PROGRESS_EVERY then
        game.progressAt = now
        Comm.Send("KD_PROG", { id = game.id, sc = score }, game.opponent)
    elseif not game.progressQueued then
        game.progressQueued = true
        C_Timer.After(KD.PROGRESS_EVERY, function()
            game.progressQueued = false
            if Games.Get(game.id) == game and not game.finishedRun[MySide(game)] then
                game.progressAt = GetTime()
                Comm.Send("KD_PROG", { id = game.id, sc = game.scores[MySide(game)] }, game.opponent)
            end
        end)
    end
    ns.UI.Refresh()
end

--- My run ended (from the arcade): send my final score until they confirm it.
function KD.RunOver(game, score)
    local me = MySide(game)
    if game.finishedRun[me] then return end
    game.scores[me], game.finishedRun[me] = score, true
    game.runEndAt = GetTime()
    if KD.FlushRun then KD.FlushRun(game) end -- spectators see the end straight away
    ns.UI.SetRollPrompt(nil)
    game.status = ("Your run: %d. Waiting for %s..."):format(score, ns.Short(game.opponent))
    ns.Log("Your Kodo Crossing run: %d.", score)
    local function send()
        if Games.Get(game.id) ~= game or game.scoreConfirmed then return end
        SendScore(game)
        C_Timer.After(KD.RESEND, send)
    end
    send()
    C_Timer.After(KD.RESULT_TIMEOUT, function()
        if Games.Get(game.id) == game and not game.finished then
            ns.Log("%s never finished their Kodo Crossing run - nothing recorded.", ns.Short(game.opponent))
            Games.Remove(game)
        end
    end)
    Resolve(game)
    ns.UI.Refresh()
end

--- /gg cancel: before it starts, a normal cancel; during my run, my run ends where it is
--- (the score so far counts); after it, a second /gg cancel stops waiting (nothing recorded).
function KD.Leave(game, why, silent)
    if game.state == "invite" then
        if not silent then Comm.Send("CANCEL", { id = game.id }, game.opponent) end
        ns.Log("Kodo Crossing vs %s cancelled%s.", ns.Short(game.opponent), why and (" (" .. why .. ")") or "")
        Games.Remove(game)
        return true
    end
    if not game.finishedRun[MySide(game)] then
        ns.Arcade.Forfeit(game)
        return true
    end
    if not game.leaveArmed then
        game.leaveArmed = true
        ns.Print("Waiting for %s's run. |cffffff00/gg cancel|r again to stop waiting (nothing is recorded then).", ns.Short(game.opponent))
        return true
    end
    ns.Log("Stopped waiting for %s - nothing recorded.", ns.Short(game.opponent))
    Games.Remove(game)
    return true
end

---------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------
local function Mine(f, sender)
    local game = Games.Get(f.id)
    if game and game.kind == "kodo" and ns.SameName(game.opponent, sender) then return game end
end

Comm.On("KD_INV", function(f, sender)
    local bet, seed = tonumber(f.s), tonumber(f.z)
    if not f.id or not bet or bet < 0 or not seed then return end
    local function no(reason) Comm.Send("KD_NO", { id = f.id, r = reason }, sender) end
    if Games.Busy() then return no("busy") end
    if not ns.Guild.Allowed(sender) then return no("not in my guild") end
    local why = ns.House.CheckOpponent(sender)
    if why then return no(why) end
    local cant = ns.CantCover(bet)
    if cant then return no("can't cover " .. ns.Stake(bet) .. " - " .. cant) end
    local text = ("%s challenges you to Kodo Crossing for %s. You each get one run on the same lanes - the higher score wins."):format(
        ns.Short(sender), ns.Stake(bet))
    ns.UI.ShowInvite(text, function()
        if Games.Busy() then return no("busy") end
        if ns.CantCover(bet) then return no("can't cover the bet") end
        local game = NewGame({ id = f.id, a = sender, b = ns.Me(), opponent = sender, bet = bet, seed = seed })
        Comm.Send("KD_ACC", { id = f.id }, sender)
        Begin(game)
        -- if our "accepted" got lost they never start: resend until we hear from their run
        local tries = 0
        local function retry()
            if Games.Get(game.id) ~= game or game.heard then return end
            tries = tries + 1
            if tries > KD.ACCEPT_RETRIES then return end
            Comm.Send("KD_ACC", { id = f.id }, sender)
            C_Timer.After(KD.ACCEPT_RETRY, retry)
        end
        C_Timer.After(KD.ACCEPT_RETRY, retry)
    end, function()
        no("declined")
    end)
end)

Comm.On("KD_ACC", function(f, sender)
    local game = Mine(f, sender)
    if game then
        game.heard = true
        if game.state == "invite" then Begin(game) end
        return
    end
    Comm.Send("KD_GONE", { id = f.id }, sender)
end)

Comm.On("KD_NO", function(f, sender)
    local game = Mine(f, sender)
    if game and game.state == "invite" then
        ns.Log("%s declined Kodo Crossing (%s).", ns.Short(sender), f.r or "no reason")
        Games.Remove(game)
    end
end)

Comm.On("KD_GONE", function(f, sender)
    local game = Mine(f, sender)
    if game and not game.finished then
        ns.Log("Kodo Crossing vs %s: the challenge had expired - nothing recorded.", ns.Short(sender))
        Games.Remove(game)
    end
end)

Comm.On("KD_PROG", function(f, sender)
    local game = Mine(f, sender)
    if not game then return end
    game.heard = true
    local them = Other(MySide(game))
    local sc = tonumber(f.sc) or 0
    if not game.finishedRun[them] and sc > game.scores[them] then game.scores[them] = sc end
    ns.UI.Refresh()
end)

Comm.On("KD_SCORE", function(f, sender)
    local game = Mine(f, sender)
    if not game then
        -- we finished already and they missed our score: send it again
        local done = KD.done[f.id or ""]
        if done and ns.SameName(done.opponent, sender) then
            Comm.Send("KD_GOT", { id = f.id }, sender)
            Comm.Send("KD_SCORE", { id = f.id, sc = done.score }, sender)
        end
        return
    end
    game.heard = true
    local them = Other(MySide(game))
    game.scores[them], game.finishedRun[them] = tonumber(f.sc) or 0, true
    Comm.Send("KD_GOT", { id = f.id }, sender)
    if not game.finishedRun[MySide(game)] then
        ns.Log("%s finished their run: %d. Your turn to beat it!", ns.Short(sender), game.scores[them])
    end
    Resolve(game)
    ns.UI.Refresh()
end)

Comm.On("KD_GOT", function(f, sender)
    local game = Mine(f, sender)
    if game then game.scoreConfirmed = true end
end)

---------------------------------------------------------------------------
-- Live replay for spectators: each player's addon sends its own run's hops (batched, about
-- once a second, well inside WoW's addon-message limits). A spectator's addon rebuilds the
-- same lanes from the seed and replays the hops a moment behind - the run as the player sees it.
---------------------------------------------------------------------------
KD.RUN_BATCH = 1.0
KD.RUN_CHUNK = 200 -- characters of events per message

--- A hop ({k="h", t, x, r}) or the end of the run ({k="d", t, c, s}), from the arcade.
function KD.RunEvent(game, ev)
    game.runLog = game.runLog or {}
    game.runLog[#game.runLog + 1] = ev
end

local function EncodeEvent(ev)
    if ev.k == "h" then return ("h%.2f:%d:%d"):format(ev.t, ev.x, ev.r) end
    return ("d%.2f:%s:%d"):format(ev.t, ev.c or "quit", ev.s or 0)
end

function KD.DecodeEvents(text)
    local out = {}
    for item in tostring(text or ""):gmatch("[^;]+") do
        local k, t, a, b = item:match("^(%a)([%d%.]+):([^:]+):(%-?%d+)$")
        t = tonumber(t)
        if k == "h" and t then out[#out + 1] = { k = "h", t = t, x = tonumber(a), r = tonumber(b) }
        elseif k == "d" and t then out[#out + 1] = { k = "d", t = t, c = a, s = tonumber(b) } end
    end
    return out
end

--- Events from index i on, as RUN messages (several if there are many).
local function SendRun(game, i, target)
    local log = game.runLog or {}
    local snap = ns.Arcade.Snapshot(game)
    local k = ("%.2f"):format(snap and snap.t or 0)
    repeat
        local parts, size, first = {}, 0, i
        while i <= #log and size < KD.RUN_CHUNK do
            local s = EncodeEvent(log[i])
            parts[#parts + 1] = s
            size = size + #s + 1
            i = i + 1
        end
        -- (never merged: each batch carries different hops)
        Comm.Send("RUN", { id = game.id, p = MySide(game), i = first, n = #log, k = k, e = table.concat(parts, ";") }, target)
    until i > #log
    return i
end

--- Once a batch: one broadcast with my new hops (however many are watching), plus how far
--- my run has got, so replays keep moving even while I stand still.
local function FlushRun(game)
    if not game.runWatchers or not next(game.runWatchers) then return end
    game.runSent = SendRun(game, game.runSent or 1, nil)
end

-- after my run ends, keep saying where it ended for a while: anyone who lost the last
-- batches sees they're missing hops and asks for them
KD.RUN_LINGER = 20

local function RunTicker(game)
    FlushRun(game)
    local active = Games.Get(game.id) == game and not game.runEndAt
    if active or GetTime() - (game.runEndAt or 0) < KD.RUN_LINGER then
        C_Timer.After(KD.RUN_BATCH, function() RunTicker(game) end)
    end
end
KD.FlushRun = FlushRun

--- Someone wants to watch this duel (a spectator, or my opponent): send them where my run is
--- now; my broadcasts carry on from there.
function KD.AddRunWatcher(game, name)
    game.runWatchers = game.runWatchers or {}
    game.runLog = game.runLog or {}
    if next(game.runWatchers) == nil then
        game.runSent = #game.runLog + 1
        C_Timer.After(KD.RUN_BATCH, function() RunTicker(game) end)
    end
    game.runWatchers[name] = true
    local snap = ns.Arcade.Snapshot(game) or { t = 0, x = 4, r = 0, cam = -1, score = 0, seed = game.seed, char = "gnome" }
    Comm.Send("RUNS", { id = game.id, p = MySide(game), z = snap.seed or game.seed, c = snap.char,
        t = ("%.2f"):format(snap.t), x = snap.x, r = snap.r, m = ("%.2f"):format(snap.cam), sc = snap.score,
        o = snap.over or "", n = #game.runLog }, name)
end

--- A watcher missed some hops: send them again from index i.
Comm.On("RUNREQ", function(f, sender)
    local game = Games.Get(f.id) or (KD.finishedRuns and KD.finishedRuns[f.id or ""])
    local i = tonumber(f.i)
    if not game or not i or not game.runLog then return end
    SendRun(game, math.max(1, i), sender)
end)

function KD.RemoveRunWatcher(game, name)
    if game.runWatchers then game.runWatchers[name] = nil end
end

--- My duel opponent's run (RUNS / RUN), for the side panel. True if it was theirs.
function KD.OpponentRun(f, sender)
    local game = Games.Get(f.id or "") or (KD.finishedRuns and KD.finishedRuns[f.id or ""])
    if not game or game.kind ~= "kodo" or not ns.SameName(game.opponent, sender) then return false end
    game.oppRun = { from = sender, next = (tonumber(f.n) or 0) + 1 }
    ns.Arcade.FollowOpponent(tonumber(f.z), f.c, { t = tonumber(f.t) or 0, x = tonumber(f.x) or 4,
        r = tonumber(f.r) or 0, cam = tonumber(f.m), score = tonumber(f.sc) or 0,
        over = (f.o and f.o ~= "") and f.o or nil })
    return true
end

function KD.OpponentRunBatch(f, sender)
    local game = Games.Get(f.id or "") or (KD.finishedRuns and KD.finishedRuns[f.id or ""])
    if not game or game.kind ~= "kodo" or not ns.SameName(game.opponent, sender) then return false end
    if game.oppRun then
        ns.Live.TakeRun(game.oppRun, f, sender, function(events, k) ns.Arcade.FeedOpponent(events, k) end)
    end
    return true
end
