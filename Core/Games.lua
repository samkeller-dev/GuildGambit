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
    ns.Rolls.UnwatchPrefix(game.id .. ":")
    if ns.UI then
        -- a house game ending must not clear the Roll button of my own game
        if not game.asHouse or not Games.Mine() then ns.UI.SetRollPrompt(nil) end
        ns.UI.Refresh()
    end
end

--- Records the result for this client and ends the game.
--- net is from this client's point of view (+ = I won). outcome (1 win, -1 loss, 0 push)
--- says who won when the bet was 0g; it defaults to the sign of net.
function Games.Finish(game, net, summary, outcome)
    local practice = game.practice
    outcome = outcome or (net > 0 and 1 or net < 0 and -1 or 0)
    game.outcome = outcome
    ns.Ledger.Record({
        id = game.id, game = game.kind, opponent = game.opponent, net = net, result = outcome,
        wager = game.wagered or game.bet or game.stake or 0,
        verified = game.verified ~= false, practice = practice,
    })
    local tag = practice and " |cff888888(practice)|r" or
        (game.verified == false and " |cffff8800(unverified rolls)|r" or "")
    local result = ns.ResultText(net, outcome)
    ns.Log("%s vs %s: %s - %s%s", game.title, ns.Short(game.opponent), summary, result, tag)
    game.finished, game.net, game.summary = true, net, summary
    if not game.asHouse then
        Games.last = game -- the table keeps showing the final hand
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

--- Marks a game unverified if any roll in it came from a relay.
function Games.NoteRoll(game, verified)
    if not verified then game.verified = false end
end
