-- SideBets.lua: spectators betting on a live game, against each other (no house).
--
-- Watchers back a player with some gold. The game's announcing addon (the challenger's, or the
-- group host's) keeps the list of bets - it already sends the table to watchers - and shows the
-- pools on that table. Bets close BET_WINDOW seconds into the game (a coinflip: when the coin
-- is flipped; a group deathroll: also while the room is still open). When the game ends the
-- announcer sends the final list to the guild, and each bettor's addon settles its own share:
-- the losing bets are split between the winning bettors in proportion to what they bet.
-- Nobody backed the winner (or everyone did), a push or a cancelled game: nobody owes anything.
local ADDON_NAME, ns = ...
local Comm = ns.Comm

local SB = {}
ns.SideBets = SB

SB.WINDOW = 20        -- seconds after the game starts that bets stay open
SB.KEEP = 300         -- the announcer keeps a finished game's bet list this long (for resends)
SB.ASK_AFTER = 8      -- a bettor with no (complete) result this long after the game asks again
SB.mine = {}          -- id -> { on, s, host, state = "pending" | "placed" | "settled" }
SB.finals = {}        -- id -> { w, parts, at } (announcer: finished games' bet lists)
local incoming = {}   -- id -> { w, n, parts = {} } (bettor: SB_END pieces)

---------------------------------------------------------------------------
-- Announcer side
---------------------------------------------------------------------------
--- The players a bet can back (names).
local function Players(game)
    if game.kind == "groupdr" then return game.players or {} end
    return { game.a, game.b }
end

local function IsPlayer(game, name)
    for _, n in ipairs(Players(game)) do if ns.SameName(n, name) then return true end end
    return false
end

local function Started(game)
    if game.kind == "groupdr" then return game.state ~= "lobby" end
    if game.kind == "coinflip" then return game.state == "play" or game.state == "done" end
    return game.state ~= "invite"
end

--- Seconds left to bet, "u" (until the game starts) or nil (closed).
function SB.Left(game)
    if game.finished then return nil end
    if game.kind == "coinflip" then return Started(game) and nil or "u" end
    if not Started(game) then return "u" end
    local now = GetTime()
    game.betsCloseAt = game.betsCloseAt or (now + SB.WINDOW)
    local left = math.ceil(game.betsCloseAt - now)
    return left > 0 and left or nil
end

--- Called every Live tick for my announced game, so the betting clock starts on time.
function SB.Touch(game) SB.Left(game) end

--- name -> { s = total copper, n = bettors } for a game's bets.
local function Pools(bets)
    local pools = {}
    for _, b in pairs(bets or {}) do
        local p = pools[b.on] or { s = 0, n = 0 }
        p.s, p.n = p.s + b.s, p.n + 1
        pools[b.on] = p
    end
    return pools
end

--- Adds the betting fields to a Live STATE message.
function SB.AddToState(game, f)
    local left = SB.Left(game)
    if left then f.bo = left end
    local parts = {}
    for name, p in pairs(Pools(game.bets)) do parts[#parts + 1] = ("%s:%d:%d"):format(name, p.s, p.n) end
    table.sort(parts)
    if #parts > 0 then f.bp = table.concat(parts, ";") end
end

--- Reads them back on the watcher's side (onto the mirror game).
function SB.FromState(m, f)
    m.betsLeft = f.bo
    local pools = {}
    for name, s, n in (f.bp or ""):gmatch("([^:;]+):(%d+):(%d+)") do
        pools[name] = { s = tonumber(s), n = tonumber(n) }
    end
    m.pools = pools
end

--- Everyone who bet on one of my games, in total (for the players' status line).
function SB.Total(game)
    local total, n = 0, 0
    for _, b in pairs(game and game.bets or {}) do total, n = total + b.s, n + 1 end
    return total, n
end

Comm.On("SB_BET", function(f, sender)
    local function no(why) Comm.Send("SB_NO", { id = f.id, r = why }, sender) end
    local game = ns.Games.Get(f.id)
    if not game or not ns.Live.IsAnnouncer(game) then return no("that game is over") end
    if not ns.Guild.Allowed(sender) then return no("not in the guild") end
    if IsPlayer(game, sender) then return no("players can't bet on their own game") end
    if not SB.Left(game) then return no("bets are closed") end
    local s = tonumber(f.s)
    if not s or s <= 0 or s > ns.MAX_BET_GOLD * ns.COPPER_PER_GOLD then return no("bad amount") end
    if not f.o or not IsPlayer(game, f.o) then return no("that player isn't in this game") end
    game.bets = game.bets or {}
    local on
    for _, n in ipairs(Players(game)) do if ns.SameName(n, f.o) then on = n end end
    game.bets[sender] = { on = on, s = s }
    if game.live then game.live.lastState = nil end -- watchers see the new pools at once
    Comm.Send("SB_OK", { id = f.id, o = on, s = s }, sender)
    if ns.UI then ns.UI.Refresh() end
end)

--- The winner's name, or nil for a push / cancelled game.
local function Winner(game)
    if game.kind == "groupdr" then return game.winner end
    if not game.finished or (game.outcome or 0) == 0 then return nil end
    return game.outcome > 0 and ns.Me() or game.opponent
end

local function SendFinal(id, final, target)
    for i, part in ipairs(final.parts) do
        Comm.Send("SB_END", { id = id, w = final.w, i = i, n = #final.parts, b = part }, target)
    end
end

--- My announced game ended: send everyone the final bet list (from Live.End).
function SB.Close(game)
    if not game.bets or not next(game.bets) then return end
    local entries = {}
    for name, b in pairs(game.bets) do
        -- (someone who bet on a group deathroll and then joined it can't bet on their own game)
        if not IsPlayer(game, name) then entries[#entries + 1] = ("%s:%s:%d"):format(name, b.on, b.s) end
    end
    if #entries == 0 then return end
    table.sort(entries)
    local parts, cur = {}, ""
    for _, e in ipairs(entries) do
        if #cur + #e + 1 > 180 then parts[#parts + 1] = cur cur = "" end
        cur = cur == "" and e or (cur .. ";" .. e)
    end
    if cur ~= "" then parts[#parts + 1] = cur end
    local final = { w = Winner(game) or "", parts = parts, at = GetTime() }
    SB.finals[game.id] = final
    SendFinal(game.id, final, nil)
    C_Timer.After(SB.KEEP, function() SB.finals[game.id] = nil end)
end

Comm.On("SB_REQ", function(f, sender)
    local final = SB.finals[f.id or ""]
    if final then SendFinal(f.id, final, sender) end
end)

---------------------------------------------------------------------------
-- Bettor side
---------------------------------------------------------------------------
--- Places (or changes) my bet on the game I'm watching: copper on player `on`.
function SB.Place(id, on, copper)
    local entry = ns.Live.games[id or ""]
    if not entry or entry.ended then ns.Print("That game is over.") return false end
    if not copper or copper <= 0 then ns.Print("Enter an amount to bet.") return false end
    local cant = ns.CantCover(copper)
    if cant then ns.Print("Can't bet %s: you %s.", ns.Money(copper), cant) return false end
    SB.mine[id] = { on = on, s = copper, host = entry.host, state = "pending" }
    Comm.Send("SB_BET", { id = id, o = on, s = copper }, entry.host)
    if ns.UI then ns.UI.Refresh() end
    return true
end

Comm.On("SB_OK", function(f, sender)
    local b = SB.mine[f.id or ""]
    if not b or not ns.SameName(b.host, sender) then return end
    b.state, b.on, b.s = "placed", f.o or b.on, tonumber(f.s) or b.s
    ns.Log("Side bet placed: %s on %s.", ns.Money(b.s), ns.Short(b.on))
    if ns.UI then ns.UI.Refresh() end
end)

Comm.On("SB_NO", function(f, sender)
    local b = SB.mine[f.id or ""]
    if not b or not ns.SameName(b.host, sender) then return end
    if b.state == "pending" then SB.mine[f.id] = nil end
    ns.Log("|cffff8040Side bet not taken: %s.|r", f.r or "no reason")
    if ns.UI then ns.UI.Refresh() end
end)

--- Works out what I'm owed / owe from the final bet list.
function SB.Settle(id, winner, list)
    local mine = SB.mine[id]
    if not mine or mine.state == "settled" then return end
    mine.state = "settled"
    local me = ns.Me()
    local bets, my = {}, nil
    for name, on, s in list:gmatch("([^:;]+):([^:;]+):(%d+)") do
        local b = { name = name, on = on, s = tonumber(s) }
        bets[#bets + 1] = b
        if ns.IsMe(name) then my = b end
    end
    if not my then
        ns.Log("Your side bet didn't reach the game in time - nothing owed.")
        return
    end
    local winners, losers, wTotal = {}, {}, 0
    if winner ~= "" then
        for _, b in ipairs(bets) do
            if ns.SameName(b.on, winner) then winners[#winners + 1] = b wTotal = wTotal + b.s
            else losers[#losers + 1] = b end
        end
    end
    if winner == "" or #winners == 0 or #losers == 0 then
        ns.Log("Side bets on that game are off (%s) - nobody owes anything.",
            winner == "" and "no winner" or (#winners == 0 and "nobody backed the winner" or "nobody took the other side"))
        return
    end
    local won = ns.SameName(my.on, winner)
    -- each losing bet is shared between the winning bettors, in proportion to their bets
    local deals = {}
    if won then
        for _, l in ipairs(losers) do deals[#deals + 1] = { who = l.name, net = math.floor(l.s * my.s / wTotal) } end
    else
        for _, w in ipairs(winners) do deals[#deals + 1] = { who = w.name, net = -math.floor(my.s * w.s / wTotal) } end
    end
    local first, total, lines = true, 0, {}
    for _, d in ipairs(deals) do
        if d.net ~= 0 then
            ns.Ledger.Record({ id = id .. ":sb", game = "sidebet", opponent = ns.Full(d.who), net = d.net,
                result = first and (won and 1 or -1) or nil, extra = (not first) or nil,
                wager = first and my.s or 0, verified = true })
            first = false
            total = total + d.net
            lines[#lines + 1] = won and ("%s owes you %s"):format(ns.Short(d.who), ns.Money(d.net))
                or ("%s %s"):format(ns.Short(d.who), ns.Money(-d.net))
        end
    end
    if won then
        ns.Log("|cff20ff20Side bet won!|r You backed %s: +%s (%s).", ns.Short(winner), ns.Money(total),
            table.concat(lines, ", "))
        ns.Sound("win")
    else
        ns.Log("|cffff4040Side bet lost.|r You backed %s: you owe %s.", ns.Short(my.on), table.concat(lines, ", "))
        ns.Sound("lose")
    end
    if ns.Board then ns.Board.Changed() end
    if ns.UI then ns.UI.Refresh() end
end

local function Ask(id)
    local b = SB.mine[id]
    if b and b.state ~= "settled" then Comm.Send("SB_REQ", { id = id }, b.host) end
end

Comm.On("SB_END", function(f, sender)
    local id = f.id or ""
    local b = SB.mine[id]
    if not b or b.state == "settled" or not ns.SameName(b.host, sender) then return end
    local inc = incoming[id] or { parts = {} }
    incoming[id] = inc
    inc.w, inc.n = f.w or "", tonumber(f.n) or 1
    inc.parts[tonumber(f.i) or 1] = f.b or ""
    for i = 1, inc.n do if not inc.parts[i] then
        C_Timer.After(SB.ASK_AFTER, function() Ask(id) end)
        return
    end end
    incoming[id] = nil
    SB.Settle(id, inc.w, table.concat(inc.parts, ";"))
end)

--- The game I bet on ended (LIVE_END): if no result follows, ask for it.
function SB.GameEnded(id)
    if SB.mine[id] then C_Timer.After(SB.ASK_AFTER, function() Ask(id) end) end
end
