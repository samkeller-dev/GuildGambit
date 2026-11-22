-- Games.lua: registry of games in progress and shared helpers.
local ADDON_NAME, ns = ...

local Games = {}
ns.Games = Games

Games.active = {} -- id -> game

function Games.Add(game)
    Games.active[game.id] = game
    Games.Note(game) -- (saved: see "Results that reach everyone" below)
    return game
end

function Games.Get(id)
    return id and Games.active[id]
end

--- The game this player is personally playing (not house games run for others).
function Games.Mine()
    for _, g in pairs(Games.active) do
        if not g.asHouse then return g end
    end
end

--- True if name is the other side of any game we're in (so their rolls aren't ours).
function Games.IsParticipant(name)
    for _, g in pairs(Games.active) do
        for _, field in ipairs({ "opponent", "a", "b", "player", "dealer" }) do
            local n = g[field]
            if n and not ns.IsMe(n) and ns.SameName(n, name) then return true end
        end
        for _, n in ipairs(g.players or {}) do
            if not ns.IsMe(n) and ns.SameName(n, name) then return true end
        end
    end
    return false
end

--- In a game - or just logged in / reloaded and still asking whether we were in one (see
--- "Catching up after a reload" below), so no new game can start on top of one we're about to
--- get back.
function Games.Busy()
    return Games.Mine() ~= nil or Games.recovering == true
end

--- Why we can't start a game right now.
function Games.BusyText()
    if not Games.Mine() and Games.recovering then
        return "Checking whether you were in a game before the reload - try again in a few seconds."
    end
    return "Finish your current game first (or |cffffff00/gg cancel|r)."
end

function Games.Remove(game)
    Games.active[game.id] = nil
    if game.live and ns.Live then ns.Live.End(game) end
    ns.Rolls.UnwatchPrefix(game.id .. ":")
    if ns.UI then
        -- a house game ending must not clear the Roll button of my own game
        if not game.asHouse or not Games.Mine() then ns.UI.SetRollPrompt(nil) end
        ns.UI.Refresh()
    end
end

local WON_TEXT = {
    deathroll = "won a deathroll", blackjack = "won at blackjack", coinflip = "won a coinflip",
}

--- Records the result for this client and ends the game.
--- net is from this client's point of view (+ = I won). outcome (1 win, -1 loss, 0 push)
--- says who won when the bet was 0g; it defaults to the sign of net.
function Games.Finish(game, net, summary, outcome)
    local practice = game.practice
    outcome = outcome or (net > 0 and 1 or net < 0 and -1 or 0)
    game.outcome = outcome
    -- the double-or-nothing run: a double or nothing adds to the run it came from; anything else
    -- (a first game, a plain rematch) starts a new run with its own result
    local tag = game.rematch or Games.invites[game.id]
    Games.invites[game.id] = nil
    local prev = Games.last
    if tag == "d" and prev and prev.finished and prev.runNet and prev.kind == game.kind
        and ns.SameName(prev.opponent or "", game.opponent or "") then
        game.runNet = prev.runNet + net
    else
        game.runNet = net
    end
    local wager = game.wagered or game.bet or game.stake or 0
    ns.Ledger.Record({
        id = game.id, game = game.kind, opponent = game.opponent, net = net, result = outcome,
        wager = wager,
        drop = game.drop, -- deathroll: the range I rolled a 1 from
        verified = game.verified ~= false, practice = practice,
    })
    -- kept a while, so an opponent who reloaded before the end still gets the same result
    if not practice and not game.asHouse then
        local fields = { id = game.id, g = game.kind, net = net, o = outcome, w = wager,
            v = game.verified ~= false and 1 or 0 }
        Games.Remember(game.id, { game.opponent }, { { "GG_DONE", fields } })
        -- and sent to them until their addon says it has it (they may have missed the end)
        Games.Unnote(game.id)
        Games.Owe(game.id, game.kind, { game.opponent }, { { "GG_RES", fields } })
    end
    local tag = practice and " |cff888888(practice)|r" or
        (game.verified == false and " |cffff8800(unverified rolls)|r" or "")
    local result = ns.ResultText(net, outcome)
    game.finished, game.net, game.summary = true, net, summary
    if not game.asHouse then Games.last = game end -- the table keeps showing the final hand
    -- the result itself: in chat, as a sound and in guild chat. A coinflip holds it back until
    -- the coin has stopped spinning, so you can't hear (or read) the result before you see it.
    local function Reveal()
        ns.Log("%s vs %s: %s - %s%s", game.title, ns.Short(game.opponent), summary, result, tag)
        if not game.asHouse then
            local event = outcome > 0 and (game.bigWin and "bigwin" or "win")
                or outcome < 0 and (game.bust and "bust" or "lose") or "push"
            -- the loser of a deathroll already heard the death cry; nothing on top of it.
            -- Any win: a short coin jingle; beating another player or a jackpot adds a cheer.
            -- Any loss: the crying emote.
            if not game.deathCry then
                ns.Sound(event)
                if outcome > 0 and (game.kind == "deathroll" or game.kind == "coinflip" or game.mode == "duel" or game.bigWin) then
                    C_Timer.After(0.3, function() ns.Sound("cheer") end)
                end
            end
        end
        -- every 1v1 game: the winner's addon posts it in guild chat (so it's posted once)
        if outcome > 0 and not practice and not game.asHouse then
            local what = WON_TEXT[game.kind] or ("won " .. (game.title or "a game"))
            ns.GuildAnnounce(("[GuildGambit] %s %s against %s %s!"):format(ns.Short(ns.Me()), what,
                ns.Short(game.opponent), net > 0 and ("for " .. ns.Money(net)) or "just for fun"))
        end
    end
    if game.revealDelay then C_Timer.After(game.revealDelay, Reveal) else Reveal() end
    Games.Remove(game)
    if not practice and ns.Board then ns.Board.Changed() end
end

--- Cancels my current game (no result recorded) and tells the other side.
function Games.Cancel(game, why, silent)
    if not game then return false end
    if game.kind == "groupdr" then return ns.GroupDeathroll.Leave(game, why) end
    if not silent and not game.practice then
        ns.Comm.Send("CANCEL", { id = game.id }, game.opponent)
    end
    ns.Log("%s vs %s cancelled%s.", game.title, ns.Short(game.opponent), why and (" (" .. why .. ")") or "")
    if game.OnCancel then game:OnCancel() end
    Games.Remove(game)
    return true
end

---------------------------------------------------------------------------
-- Rematch / double or nothing: the same game against the same player, at the same stake or
-- twice it. Either player can offer it from the finished table; the invite says it's a rematch.
---------------------------------------------------------------------------
Games.rematchTag = nil -- "r" or "d" while a rematch challenge is being sent (read by the *_INV senders)

--- "Rematch! " / "Double or nothing! " for an invite's text.
function ns.RematchText(tag)
    if tag == "d" then return "|cffffd100Double or nothing!|r " end
    if tag == "r" then return "|cffffd100Rematch!|r " end
    return ""
end

local REMATCH = { deathroll = true, coinflip = true, blackjack = true, groupdr = true }

--- The finished game a rematch would repeat, or nil.
function Games.RematchOf()
    local g = Games.last
    if not g or not g.finished or Games.Busy() or not REMATCH[g.kind] then return nil end
    if g.kind == "blackjack" and g.mode ~= "duel" and not g.practice then return nil end
    if g.kind == "groupdr" and not ns.IsMe(g.host) then return nil end -- the host reopens the room
    return g
end

local function Stake(g) return g.bet or g.stake or 0 end

--- Double or nothing: bet what the run of back-to-back games stands at (+/- from my side), so
--- the run ends up either doubled or at nothing. Debts from other games aren't part of it.
--- Returns the stake in copper, or nil when there's nothing to double (the run is at nothing).
function Games.DoubleStake()
    local g = Games.RematchOf()
    -- a group deathroll has a different total for every player: no double or nothing there
    if not g or g.kind == "groupdr" then return nil end
    local stake = math.abs(g.runNet or g.net or 0)
    if stake <= 0 or stake > ns.MAX_BET_GOLD * ns.COPPER_PER_GOLD then return nil end
    return stake
end

Games.invites = {} -- game id -> rematch tag ("r" / "d") from invites we received

-- Kodo Crossing duels were retired in 2.4.0 (it's in the Arcade, just for fun): an older
-- addon's duel invite gets a polite no instead of waiting for an answer
ns.Comm.On("KD_INV", function(f, sender)
    if f.id then ns.Comm.Send("KD_NO", { id = f.id, r = "Kodo Crossing duels were retired in GuildGambit 2.4.0 - it's played in the Arcade now" }, sender) end
end)

--- True if double or nothing makes sense (the run isn't at nothing).
function Games.CanDouble()
    return Games.DoubleStake() ~= nil
end

function Games.Rematch(double)
    local g = Games.RematchOf()
    if not g then return nil end
    if double and not Games.DoubleStake() then return nil end
    local stake = double and Games.DoubleStake() or Stake(g)
    local money = stake .. "c"
    local target = g.practice and "practice" or g.opponent
    Games.rematchTag = (not g.practice) and (double and "d" or "r") or nil
    local ok, game = pcall(function()
        if g.kind == "deathroll" then return ns.Deathroll.Challenge(target, money, g.start)
        elseif g.kind == "coinflip" then
            -- keep your side of the coin
            return ns.Coinflip.Challenge(target, money, g.practice and g.call or ns.Coinflip.SideOf(g, ns.Me()))
        elseif g.kind == "blackjack" then return ns.Blackjack.Deal(target, money)
        elseif g.kind == "groupdr" then return ns.GroupDeathroll.Open(money, g.start)
        end
    end)
    Games.rematchTag = nil
    if not ok then ns.Print("|cffff4040rematch failed: %s|r", tostring(game)) return nil end
    if type(game) == "table" then game.rematch = double and "d" or "r" end -- (practice too)
    return game
end

--- Marks a game unverified if any roll in it came from a relay.
function Games.NoteRoll(game, verified)
    if not verified then game.verified = false end
end

---------------------------------------------------------------------------
-- Catching up after a reload. A /reload (or a disconnect) wipes the games this addon was
-- tracking, while the other players' addons carry on. So after every login we ask the guild
-- "is anyone in a game with me?" (GG_WHERE, a few times, as messages right after a loading
-- screen are often lost). Every addon still in a game with us answers:
--   * a game that can carry on (deathroll, group deathroll, a group lobby): its state (GG_HERE)
--     and we pick the game back up, with the time left on the turn;
--   * a game that can't (coinflip, blackjack - our own hidden card is gone): they cancel their
--     side, with no result for either, and say so (GG_DONE with x=1);
--   * a game that ended meanwhile (kept for RECENT_KEEP): its result (GG_DONE), so our ledger
--     shows exactly what theirs does. A result already on the ledger is never added twice.
-- Answers are only taken while we're asking (or about a game we already have), so nobody can
-- put a made-up result on someone's ledger at any other time. Older addons don't answer: then
-- the normal turn updates and end-of-game messages still catch us up once a game we got back
-- moves on.
---------------------------------------------------------------------------
Games.RECOVER_ASKS = { 5, 10, 15 } -- seconds after login
Games.RECOVER_WINDOW = 20          -- answers are taken (and new games wait) this long after login
Games.RECENT_KEEP = 600            -- finished games are kept this long to tell a reloaded player
Games.recovering = false
Games.recent = {}                  -- id -> { with = { names }, at, messages = { { type, fields } } }
Games.recovery = {}                -- kind -> { answer = fn(game, asker), here = fn(f, sender) }

--- Keeps a finished game's result for players who weren't there to see the end.
function Games.Remember(id, with, messages)
    if not id then return end
    Games.recent[id] = { with = with, at = GetTime(), messages = messages }
end

local function Involves(list, name)
    for _, n in ipairs(list or {}) do
        if ns.SameName(n, name) then return true end
    end
    return false
end
Games.Involves = Involves

--- Called once at login: ask the guild whether we were in a game.
function Games.StartRecovery()
    Games.Prune()
    -- (no IsInGuild check: right after a fresh login it can still say no; a guild message
    -- simply isn't sent when we aren't in one)
    Games.recovering = true
    for _, t in ipairs(Games.RECOVER_ASKS) do
        C_Timer.After(t, function()
            if Games.recovering then ns.Comm.Send("GG_WHERE", {}, nil) end
        end)
    end
    C_Timer.After(Games.RECOVER_WINDOW, function()
        Games.recovering = false
        if ns.UI then ns.UI.Refresh() end
    end)
end

-- someone just logged in or reloaded: tell them about every game they were in with us
ns.Comm.On("GG_WHERE", function(f, sender)
    if not ns.Guild.Allowed(sender) then return end
    local now = GetTime()
    for id, r in pairs(Games.recent) do
        if now - r.at > Games.RECENT_KEEP then
            Games.recent[id] = nil
        elseif Involves(r.with, sender) then
            for _, m in ipairs(r.messages) do ns.Comm.Send(m[1], m[2], sender) end
        end
    end
    local list = {}
    for _, g in pairs(Games.active) do list[#list + 1] = g end
    for _, g in ipairs(list) do
        local rec = Games.recovery[g.kind]
        if rec and rec.answer and not g.practice and Games.Get(g.id) == g then
            local ok, err = pcall(rec.answer, g, sender)
            if not ok then ns.Debug("recovery answer failed: %s", tostring(err)) end
        end
    end
end)

--- A 1v1 game that can't be picked up again: cancel our side (no result) and tell them.
function Games.CancelForReload(game, asker)
    if game.state == "invite" or not ns.SameName(game.opponent or "", asker) then return end
    ns.Comm.Send("GG_DONE", { id = game.id, g = game.kind, x = 1 }, asker)
    Games.Cancel(game, ns.Short(asker) .. " reloaded - no result for either of you", true)
end

local ONE_V_ONE = { deathroll = "Deathroll", coinflip = "Coinflip", blackjack = "Blackjack" }

-- a game that ended (or was cancelled) while we were away
ns.Comm.On("GG_DONE", function(f, sender)
    if not f.id or Games.IsVoided(f.id) then return end
    local kind = f.g
    local rec = Games.recovery[kind]
    if rec and rec.done then return rec.done(f, sender) end
    if not ONE_V_ONE[kind] then return end
    local game = Games.Get(f.id)
    local ours = game and game.kind == kind and ns.SameName(game.opponent or "", sender)
    if not (Games.recovering or ours) then return end
    if game and not ours then return end
    if f.x then
        if game then Games.Remove(game) end
        ns.Log("Your %s with %s was cancelled because of the reload - nothing recorded.", ONE_V_ONE[kind]:lower(),
            ns.Short(sender))
        return
    end
    local net, outcome, wager = tonumber(f.net), tonumber(f.o), tonumber(f.w) or 0
    if not net or not outcome or math.abs(net) > 2 * ns.MAX_BET_GOLD * ns.COPPER_PER_GOLD then return end
    if game then Games.Remove(game) end
    -- their result, from our side
    net, outcome = -net, -outcome
    local _, new = ns.Ledger.Record({ id = f.id, game = kind, opponent = sender, net = net, result = outcome,
        wager = wager, verified = f.v ~= "0" })
    if not new then return end
    ns.Log("%s vs %s ended while you were reloading: %s", ONE_V_ONE[kind], ns.Short(sender), ns.ResultText(net, outcome))
    if outcome > 0 then
        -- the winner's addon posts it, and that's us - nobody has yet
        local what = ({ deathroll = "won a deathroll", coinflip = "won a coinflip", blackjack = "won at blackjack" })[kind]
        ns.GuildAnnounce(("[GuildGambit] %s %s against %s %s!"):format(ns.Short(ns.Me()), what,
            ns.Short(sender), net > 0 and ("for " .. ns.Money(net)) or "just for fun"))
    end
    if ns.Board then ns.Board.Changed() end
end)

ns.Comm.On("GG_HERE", function(f, sender)
    local rec = f.id and Games.recovery[f.g or ""]
    if not rec or not rec.here then return end
    if not (Games.recovering or Games.Get(f.id)) then return end
    if not ns.Guild.Allowed(sender) then return end
    -- a game we've already recorded (or undone) is over for us: never played out again. Their
    -- addon gets our result the normal way (GG_RES below).
    if not Games.Get(f.id) and (Games.IsVoided(f.id) or ns.Ledger.HasGameId(f.id)) then return end
    rec.here(f, sender)
end)

-- coinflips and blackjack can't be picked up again
Games.recovery.coinflip = { answer = Games.CancelForReload }
Games.recovery.blackjack = { answer = function(game, asker)
    if game.mode == "duel" then Games.CancelForReload(game, asker) end
end }

---------------------------------------------------------------------------
-- Results that reach everyone. A game's end used to reach the other player as one message (the
-- last roll, the last card); if it was lost, one addon recorded the game and the other never
-- did. So:
--   * every real game an addon takes part in is noted in its saved variables (Games.Note), so
--     it still knows "I agreed to game X for this stake" after a cancel, a /reload or a logout;
--   * the addon that records a result sends it to the other player(s) (GG_RES) and keeps
--     sending - at once, and then whenever it hears from them, across reloads and logouts -
--     until their addon answers (GG_ACK);
--   * an addon takes a result for a game it still has open, or has a note of, and records the
--     mirror image. One already on its ledger is never recorded twice; if the two results
--     differ, or it knows nothing of the game, it says so and both players are told to compare.
-- Older addons don't answer and are left alone (the reload catch-up above still covers them).
---------------------------------------------------------------------------
Games.NOTE_KEEP = 7 * 86400      -- notes, unconfirmed results and undone ids are kept this long
Games.RESULT_FIRST = { 2, 10, 60 } -- seconds after the end: the first sends (if they look online)
Games.RESULT_EVERY = 60          -- then at most this often, whenever we hear from them
Games.RESULT_TRIES = 12          -- give up after this many sends without an answer
Games.RESULT_MIN_VERSION = "2.6.3" -- (2.6.3 was never released: the first version out with this is later)
Games.results = {}               -- kind -> fn(f, sender) -> "ok" | "u" (unknown game) | "d" (differs) | nil

local function Saved(key)
    if not ns.charDB then return {} end
    ns.charDB[key] = ns.charDB[key] or {}
    return ns.charDB[key]
end

--- Notes a real game we're in (called for every game; practice and house games aren't noted).
function Games.Note(game)
    if not ns.charDB or not game or not game.id or game.practice or game.asHouse then return end
    Saved("openGames")[game.id] = { g = game.kind, s = game.stake or game.bet or 0, t = ns.Ledger.Now() }
end

function Games.Noted(id, kind)
    local n = id and ns.charDB and ns.charDB.openGames and ns.charDB.openGames[id]
    if n and n.g == kind then return n end
end

function Games.Unnote(id)
    if id and ns.charDB and ns.charDB.openGames then ns.charDB.openGames[id] = nil end
end

--- /gg undo: the game is gone for good on this addon - nothing brings it back.
function Games.Void(id)
    if not id then return end
    Saved("voided")[id] = ns.Ledger.Now()
    Games.recent[id] = nil
    Saved("results")[id] = nil
    Games.Unnote(id)
end

function Games.IsVoided(id)
    return id ~= nil and ns.charDB ~= nil and ns.charDB.voided ~= nil and ns.charDB.voided[id] ~= nil
end

--- Forgets what's too old to matter (at login).
function Games.Prune()
    if not ns.charDB then return end
    local now = ns.Ledger.Now()
    for id, n in pairs(Saved("openGames")) do
        if type(n) ~= "table" or now - (n.t or 0) > Games.NOTE_KEEP then ns.charDB.openGames[id] = nil end
    end
    for id, r in pairs(Saved("results")) do
        if type(r) ~= "table" or type(r.to) ~= "table" or type(r.m) ~= "table" or now - (r.t or 0) > Games.NOTE_KEEP then
            ns.charDB.results[id] = nil
        end
    end
    for id, t in pairs(Saved("voided")) do
        if now - (tonumber(t) or 0) > Games.NOTE_KEEP then ns.charDB.voided[id] = nil end
    end
end

-- can their addon answer? (an older one can't; one we haven't heard a version from might)
local function CanTake(name)
    local p = ns.House and ns.House.peers and ns.House.peers[name]
    local v = p and p.version
    return not v or not ns.House.IsNewer(Games.RESULT_MIN_VERSION, v)
end

local sentAt = {} -- id|name -> GetTime() of the last send

--- Sends result `id` to everyone still owed it (only: just that player, who we've just heard from).
function Games.SendResults(id, only)
    local r = ns.charDB and ns.charDB.results and ns.charDB.results[id]
    if type(r) ~= "table" or type(r.to) ~= "table" or type(r.m) ~= "table" then return end
    local now = GetTime()
    for name, tries in pairs(r.to) do
        if not only or ns.SameName(name, only) then
            local key = tostring(id) .. "|" .. name
            if (tonumber(tries) or 0) >= Games.RESULT_TRIES or not CanTake(name) then
                r.to[name] = nil
            elseif (only or ns.Guild.IsOnline(name) ~= false)
                and now - (sentAt[key] or -1e9) >= (only and Games.RESULT_EVERY or 1) then
                sentAt[key] = now
                r.to[name] = (tonumber(tries) or 0) + 1
                for _, m in ipairs(r.m) do ns.Comm.Send(m[1], m[2], name) end
            end
        end
    end
    if not next(r.to) then ns.charDB.results[id] = nil end
end

--- We've recorded game `id`: these players are owed the result until their addons have it.
function Games.Owe(id, kind, names, messages)
    if not ns.charDB or not id then return end
    local to = {}
    for _, n in ipairs(names) do
        if n and not ns.IsMe(n) then to[ns.Full(n) or n] = 0 end
    end
    if not next(to) then return end
    Saved("results")[id] = { g = kind, t = ns.Ledger.Now(), to = to, m = messages }
    for _, d in ipairs(Games.RESULT_FIRST) do
        C_Timer.After(d, function() Games.SendResults(id) end)
    end
end

--- That player evidently has result `id` (they answered, or sent us the same one).
local function Settled(id, name)
    local r = ns.charDB and ns.charDB.results and ns.charDB.results[id]
    if type(r) ~= "table" or type(r.to) ~= "table" then return false end
    local hit = false
    for n in pairs(r.to) do
        if ns.SameName(n, name) then r.to[n] = nil hit = true end
    end
    if not next(r.to) then ns.charDB.results[id] = nil end
    return hit
end

--- We heard from name (any addon message): send them any result they haven't confirmed.
function Games.Seen(name)
    local out = ns.charDB and ns.charDB.results
    if not out or not next(out) then return end
    local ids = {}
    for id, r in pairs(out) do
        if type(r) == "table" and type(r.to) == "table" then
            for n in pairs(r.to) do
                if ns.SameName(n, name) then ids[#ids + 1] = id break end
            end
        end
    end
    for _, id in ipairs(ids) do Games.SendResults(id, name) end
end

local KIND_TEXT = { deathroll = "deathroll", coinflip = "coinflip", blackjack = "blackjack", groupdr = "group deathroll" }
local warned = {}
--- Our ledger and theirs disagree about a game: say so, once.
function Games.WarnDiffers(id, kind, name)
    if warned[id] then return end
    warned[id] = true
    ns.Log("|cffff8040Your ledger and %s's don't agree on your last %s together|r - compare them (the Ledger tab) and fix it by hand with |cffffff00/gg undo|r or a payment.",
        ns.Short(name), KIND_TEXT[kind] or "game")
end

-- a 1v1 result from the other player's addon
local function TakeOneVOne(f, sender)
    local kind = f.g
    local net, outcome, wager = tonumber(f.net), tonumber(f.o), tonumber(f.w) or 0
    if not net or not outcome or math.abs(net) > 2 * ns.MAX_BET_GOLD * ns.COPPER_PER_GOLD then return nil end
    net, outcome = -net, -outcome -- their result, from our side
    local have = ns.Ledger.FindGame(f.id, sender, Games.NOTE_KEEP + 86400)
    if have then
        if have.net == net then return "ok" end
        Games.WarnDiffers(f.id, kind, sender)
        return "d"
    end
    local game = Games.Get(f.id)
    local ours = game and game.kind == kind and ns.SameName(game.opponent or "", sender)
    if game and not ours then return "u" end
    local note = Games.Noted(f.id, kind)
    if not (ours or note) then return "u" end
    -- the stake we agreed to bounds what they can tell us (blackjack: each side may double)
    local stake = game and (game.stake or game.bet) or (note and note.s) or 0
    if math.abs(net) > stake * (kind == "blackjack" and 4 or 1) then return "u" end
    if game then Games.Remove(game) end
    -- (on their addon's word, not from rolls we saw: marked unverified, like a relayed roll)
    local _, new = ns.Ledger.Record({ id = f.id, game = kind, opponent = sender, net = net, result = outcome,
        wager = wager, verified = false })
    Games.Unnote(f.id)
    if new then
        ns.Log("%s vs %s: your addon missed the end - recorded from theirs: %s", ONE_V_ONE[kind], ns.Short(sender),
            ns.ResultText(net, outcome))
        if outcome > 0 then
            -- the winner's addon posts it, and that's us - nobody has yet
            ns.GuildAnnounce(("[GuildGambit] %s %s against %s %s!"):format(ns.Short(ns.Me()), WON_TEXT[kind] or "won a game",
                ns.Short(sender), net > 0 and ("for " .. ns.Money(net)) or "just for fun"))
        end
        if ns.Board then ns.Board.Changed() end
        if ns.UI then ns.UI.Refresh() end
    end
    return "ok"
end

ns.Comm.On("GG_RES", function(f, sender)
    if not f.id or not ns.charDB or not ns.Guild.Allowed(sender) then return end
    local answer
    if Games.IsVoided(f.id) then
        answer = "ok" -- (undone here: nothing to record, and nothing more to send)
    else
        local fn = Games.results[f.g or ""] or (ONE_V_ONE[f.g or ""] and TakeOneVOne)
        if not fn then return end
        answer = fn(f, sender)
    end
    if not answer then return end
    if answer == "ok" then Settled(f.id, sender) end -- they have it: ours needn't go to them any more
    ns.Comm.Send("GG_ACK", { id = f.id, x = answer ~= "ok" and answer or nil }, sender)
end)

ns.Comm.On("GG_ACK", function(f, sender)
    local r = f.id and ns.charDB and ns.charDB.results and ns.charDB.results[f.id]
    local kind = type(r) == "table" and r.g or nil
    if not Settled(f.id, sender) then return end
    if f.x == "u" then
        ns.Log("|cffff8040%s's addon has no record of your %s together, so it didn't take the result|r - your ledgers may not match. Check with them.",
            ns.Short(sender), KIND_TEXT[kind] or "game")
    elseif f.x == "d" then
        Games.WarnDiffers(f.id, kind, sender)
    end
end)
