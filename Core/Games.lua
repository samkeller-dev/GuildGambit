-- Games.lua: registry of games in progress and shared helpers.
local ADDON_NAME, ns = ...

local Games = {}
ns.Games = Games

Games.active = {} -- id -> game

function Games.Add(game)
    Games.active[game.id] = game
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
        Games.Remember(game.id, { game.opponent }, { { "GG_DONE", { id = game.id, g = game.kind, net = net,
            o = outcome, w = wager, v = game.verified ~= false and 1 or 0 } } })
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
    if not f.id then return end
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
    rec.here(f, sender)
end)

-- coinflips and blackjack can't be picked up again
Games.recovery.coinflip = { answer = Games.CancelForReload }
Games.recovery.blackjack = { answer = function(game, asker)
    if game.mode == "duel" then Games.CancelForReload(game, asker) end
end }
