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

function Games.Busy()
    return Games.Mine() ~= nil
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
    ns.Ledger.Record({
        id = game.id, game = game.kind, opponent = game.opponent, net = net, result = outcome,
        wager = game.wagered or game.bet or game.stake or 0,
        drop = game.drop, -- deathroll: the range I rolled a 1 from
        verified = game.verified ~= false, practice = practice,
    })
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
