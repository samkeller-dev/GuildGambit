-- Wealth.lua: the guild wealth chart's data. Every client shares its OWN character's numbers
-- (nobody can read anyone else's bags): gold on hand, its peak and 7-day change, level/class,
-- lifetime PvP kills, and a few GuildGambit records worked out from its own ledger.
-- One WEALTH message on the guild channel; each alt is its own entry.
local ADDON_NAME, ns = ...
local Comm, Compat = ns.Comm, ns.Compat

local Wealth = {}
ns.Wealth = Wealth

Wealth.SEND_DELAY = 20   -- seconds: gold changes all the time (loot, vendors) - batch them
Wealth.ASK_EVERY = 120   -- opening the chart asks the guild for fresh numbers at most this often
Wealth.ANSWER_EVERY = 60 -- and we answer such a request at most this often
Wealth.DAYS = 30         -- daily gold snapshots kept, for the 7-day change

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if ok then return Compat.Safe(a), Compat.Safe(b), Compat.Safe(c) end
end

local function GuildKey()
    local name = IsInGuild and IsInGuild() and Compat.Safe((GetGuildInfo("player")))
    return name or "_noguild"
end

--- Everyone's last known numbers in this guild: name -> record.
function Wealth.Table()
    ns.db.wealth = ns.db.wealth or {}
    local key = GuildKey()
    ns.db.wealth[key] = ns.db.wealth[key] or {}
    return ns.db.wealth[key]
end

---------------------------------------------------------------------------
-- My gold history: one snapshot per day (the day's latest balance), plus the peak.
---------------------------------------------------------------------------
local function Today() return tonumber(date("%Y%m%d")) end

local function Money() return tonumber((Call(GetMoney))) end

function Wealth.Snapshot()
    local money = Money()
    if not money then return end
    local c = ns.charDB
    c.goldDays = c.goldDays or {}
    c.goldDays[Today()] = money
    if money > (c.goldPeak or 0) then c.goldPeak = money end
    -- forget old days
    local cutoff = tonumber(date("%Y%m%d", time() - Wealth.DAYS * 86400))
    for day in pairs(c.goldDays) do
        if day < cutoff then c.goldDays[day] = nil end
    end
end

--- Gold change over the last 7 days (or since the oldest snapshot): change, days covered.
function Wealth.Change()
    local money, days = Money(), ns.charDB.goldDays
    if not money or not days then return 0, 0 end
    local now = time()
    local best, bestAge
    for back = 7, 1, -1 do -- the snapshot from 7 days ago, or the oldest one we have
        local v = days[tonumber(date("%Y%m%d", now - back * 86400))]
        if v then best, bestAge = v, back break end
    end
    if not best then return 0, 0 end
    return money - best, bestAge
end

---------------------------------------------------------------------------
-- GuildGambit records from my own ledger (this season's real games, like the leaderboard).
---------------------------------------------------------------------------
function Wealth.Records()
    local r = { bestWin = 0, bestWinAt = 0, worstLoss = 0, worstLossAt = 0, longest = 0 }
    local season = ns.Board and ns.Board.Season()
    local since = season and season.localStart or 0
    local byGame, order, vs = {}, {}, {}
    for _, e in ipairs(ns.charDB.ledger) do
        if not e.practice and (e.kind or "game") == "game" and (e.time or 0) >= since then
            -- one game can be several entries (a group deathroll win: one per loser)
            local id = e.id or tostring(e)
            local g = byGame[id]
            if not g then
                g = { net = 0, time = e.time or 0, result = 0 }
                byGame[id] = g
                order[#order + 1] = g
            end
            g.net = g.net + (e.net or 0)
            if not e.extra then g.result = e.result or e.net or 0 end
            if e.opponent then vs[e.opponent] = (vs[e.opponent] or 0) + (e.net or 0) end
        end
    end
    local run = 0
    for _, g in ipairs(order) do
        if g.net > r.bestWin then r.bestWin, r.bestWinAt = g.net, g.time end
        if g.net < r.worstLoss then r.worstLoss, r.worstLossAt = g.net, g.time end
        -- longest win streak (pushes don't break it)
        if g.result > 0 then run = run + 1 elseif g.result < 0 then run = 0 end
        if run > r.longest then r.longest = run end
    end
    -- nemesis: who has taken the most gold off me; victim: who I've taken the most from
    local nemesis, nemesisNet, victim, victimNet = nil, 0, nil, 0
    for name, net in pairs(vs) do
        if net < nemesisNet then nemesis, nemesisNet = name, net end
        if net > victimNet then victim, victimNet = name, net end
    end
    r.nemesis, r.nemesisNet = nemesis, -nemesisNet
    r.victim, r.victimNet = victim, victimNet
    return r
end

---------------------------------------------------------------------------
-- What my client shares
---------------------------------------------------------------------------
function Wealth.Mine()
    Wealth.Snapshot()
    local s = { gold = Money() or 0, peak = ns.charDB.goldPeak or 0 }
    s.change, s.days = Wealth.Change()
    s.level = tonumber((Call(UnitLevel, "player"))) or 0
    local _, classFile = Call(UnitClass, "player")
    s.class = classFile
    local _, raceFile = Call(UnitRace, "player")
    s.race = raceFile
    -- lifetime honorable / dishonorable kills
    local hk, dk = Call(GetPVPLifetimeStats)
    s.hk, s.dk = tonumber(hk) or 0, tonumber(dk) or 0
    local r = Wealth.Records()
    for k, v in pairs(r) do s[k] = v end
    return s
end

local function Fields(s)
    return {
        g = s.gold, pk = s.peak, ch = s.change, cd = s.days, lv = s.level, cl = s.class or "",
        rc = s.race or "", hk = s.hk, dk = s.dk,
        bw = s.bestWin, bwt = s.bestWinAt, bl = -s.worstLoss, blt = s.worstLossAt, ls = s.longest,
        nm = s.nemesis or "", nma = s.nemesisNet, vi = s.victim or "", via = s.victimNet,
    }
end

local function Store(name, s)
    local t = Wealth.Table()
    if ns.IsMe(name) then
        name = ns.Me()
        for other in pairs(t) do -- older spellings of my own name
            if other ~= name and ns.IsMe(other) then t[other] = nil end
        end
    end
    s.seen = time()
    t[name] = s
end

local function FromFields(f)
    local function n(v) return tonumber(v) or 0 end
    local function str(v) return (v and v ~= "") and v or nil end
    return {
        gold = n(f.g), peak = n(f.pk), change = n(f.ch), days = n(f.cd), level = n(f.lv),
        class = str(f.cl), race = str(f.rc), hk = n(f.hk), dk = n(f.dk),
        bestWin = n(f.bw), bestWinAt = n(f.bwt), worstLoss = -n(f.bl), worstLossAt = n(f.blt),
        longest = n(f.ls), nemesis = str(f.nm) and ns.Full(f.nm), nemesisNet = n(f.nma),
        victim = str(f.vi) and ns.Full(f.vi), victimNet = n(f.via),
    }
end

local lastSent
--- Shares my numbers with the guild (or one player). Skips a guild broadcast that would
--- repeat the last one exactly, unless forced.
function Wealth.Send(target, force)
    local s = Wealth.Mine()
    Store(ns.Me(), s)
    local f = Fields(s)
    local text = Comm.Encode("WEALTH", f)
    if not target and not force and text == lastSent then return end
    if not target then lastSent = text end
    Comm.Send("WEALTH", f, target, { key = "WEALTH" .. (target or "") })
end

local pending = false
--- Something changed (gold, level...): broadcast once, a little later.
function Wealth.Changed()
    if pending then return end
    pending = true
    C_Timer.After(Wealth.SEND_DELAY, function()
        pending = false
        Wealth.Send(nil)
        if ns.WealthUI then ns.WealthUI.Refresh() end
    end)
end

local lastAsked = 0
--- The chart was opened: ask every guildie's addon for fresh numbers (rate-limited).
function Wealth.Ask()
    Store(ns.Me(), Wealth.Mine())
    if time() - lastAsked < Wealth.ASK_EVERY then return false end
    lastAsked = time()
    Comm.Send("WREQ", {}, nil)
    return true
end

local lastAnswered = 0
Comm.On("WREQ", function(f, sender)
    if time() - lastAnswered < Wealth.ANSWER_EVERY then return end
    lastAnswered = time()
    -- spread the answers out, so a whole guild doesn't answer in the same instant
    C_Timer.After(0.5 + math.random() * 4, function() Wealth.Send(nil, true) end)
end)

Comm.On("WEALTH", function(f, sender)
    Store(sender, FromFields(f))
    if ns.WealthUI then ns.WealthUI.Refresh() end
end)

--- Current guild members' entries, richest first: { { name, ...record } }.
function Wealth.List()
    Store(ns.Me(), Wealth.Mine())
    local list = {}
    for name, s in pairs(Wealth.Table()) do
        local member = ns.IsMe(name) or not ns.Guild.rosterKnown or ns.Guild.IsMember(name)
        if member then
            local e = { name = name }
            for k, v in pairs(s) do e[k] = v end
            list[#list + 1] = e
        end
    end
    table.sort(list, function(a, b)
        if a.gold ~= b.gold then return a.gold > b.gold end
        return a.name < b.name
    end)
    return list
end
