-- UI/Arcade.lua: "Kodo Crossing", a small lane-crossing hopper in the Arcade tab.
--
-- Hop forward across grass, roads full of charging kodos and raptors, stampede lanes, and
-- rivers you cross on drifting logs or lily pads. The screen creeps forward, so dawdling
-- gets you caught. Score = how far you got. Coins on the lanes unlock more characters.
-- Every 40 rows you enter a new zone: Elwynn, the Barrens, Winterspring.
--
-- Determinism: the lanes come from a seeded random generator, and everything that moves is a
-- pure function of the run's clock (position = start + speed x time, stampedes on a seeded
-- timetable). So a Kodo Crossing duel (Games/Kodo.lua) gives both players exactly the same
-- world, and a spectator's addon can redraw a run from just the seed and the player's hops.
--
-- The game is an "engine" object, so several can exist: the player's own (Arcade tab) and
-- replay engines in the Live tab that follow someone else's run from their hops.
--
-- Kept light: a fixed pool of row widgets per engine, re-used as the world scrolls; plain math
-- for collisions; OnUpdate only while visible. Art: 16 px sprites in Media/arcade, NEAREST.
local ADDON_NAME, ns = ...
local Art = ns.Art

local Arcade = {}
ns.Arcade = Arcade

local COLS, VIEW_ROWS, TILE = 9, 10, 44
Arcade.COLS, Arcade.VIEW_ROWS, Arcade.TILE = COLS, VIEW_ROWS, TILE
local POOL = VIEW_ROWS + 3          -- row widgets, re-used as the world scrolls
local MAX_MOVERS, MAX_DECO = 4, 4   -- per row
local HOP_TIME = 0.11               -- seconds per hop
local MIN_SPAN = COLS + 8           -- a lane's movers loop over at least this many tiles
local SAFE_ROWS = 4                 -- open grass at the start
local ZONE_ROWS = 40                -- a new zone every this many rows
local CHIME_EVERY = 25
local STAMPEDE_SPEED, STAMPEDE_WARN, STAMPEDE_GAP = 13, 1.1, 2.4

local KEYS = {
    UP = "up", W = "up", DOWN = "down", S = "down", LEFT = "left", A = "left", RIGHT = "right", D = "right",
    SPACE = "start", ENTER = "start", P = "pause",
}
local DIRS = { up = { 0, 1 }, down = { 0, -1 }, left = { -1, 0 }, right = { 1, 0 } }

-- characters, unlocked with coins
Arcade.CHARS = {
    { key = "gnome", name = "Gnome", cost = 0 },
    { key = "orc", name = "Orc", cost = 25 },
    { key = "nelf", name = "Night Elf", cost = 50 },
    { key = "tauren", name = "Tauren", cost = 100 },
    { key = "undead", name = "Forsaken", cost = 200 },
}

-- zones: ground and tree sprites, tree tint, and the banner
local ZONES = {
    { name = "Elwynn Forest", grass = "grass", tree = "tree", tint = { 1, 1, 1 } },
    { name = "the Barrens", grass = "grass_barrens", tree = "tree", tint = { 0.85, 0.75, 0.35 } },
    { name = "Winterspring", grass = "snow", tree = "pine", tint = { 1, 1, 1 } },
}

local DEATHS = {
    road = "Trampled!", stampede = "Caught in the stampede!", water = "Splash!", swept = "Swept away!",
    slow = "Too slow - the herd caught up!", quit = "Run ended.",
}

---------------------------------------------------------------------------
-- Seeded random numbers (Park-Miller): the same seed gives the same lanes on every client
---------------------------------------------------------------------------
local function NewRand(seed)
    local state = math.floor(seed or 1) % 2147483647
    if state <= 0 then state = state + 2147483646 end
    local function rand()
        state = (state * 16807) % 2147483647
        return state / 2147483647
    end
    local function int(a, b) return a + math.floor(rand() * (b - a + 1)) end
    return rand, int
end

---------------------------------------------------------------------------
-- Saved progress (per character): best score, coins, unlocked characters
---------------------------------------------------------------------------
local function Save()
    local db = ns.charDB
    db.arcadeOwned = db.arcadeOwned or { gnome = true }
    db.arcadeCoins = db.arcadeCoins or 0
    db.arcadeChar = db.arcadeChar or "gnome"
    return db
end

local function CharInfo(key)
    for _, c in ipairs(Arcade.CHARS) do if c.key == key then return c end end
    return Arcade.CHARS[1]
end

--- The character a run uses: the chosen one if unlocked, else the gnome.
local function PlayingAs()
    local db = Save()
    return db.arcadeOwned[db.arcadeChar] and db.arcadeChar or "gnome"
end

function Arcade.Best() return ns.charDB.arcadeBest or 0 end
function Arcade.Character() return PlayingAs() end

---------------------------------------------------------------------------
-- Textures
---------------------------------------------------------------------------
local function SetSprite(t, name, wrap)
    local path = Art.Tex("arcade/" .. name)
    -- NEAREST keeps the pixel art sharp; older clients just ignore the extra arguments
    if not pcall(t.SetTexture, t, path, wrap, wrap, "NEAREST") then t:SetTexture(path) end
end
Arcade.SetSprite = SetSprite

local function Sprite(parent, layer, name, wrap)
    local t = parent:CreateTexture(nil, layer)
    SetSprite(t, name, wrap)
    return t
end

---------------------------------------------------------------------------
-- World generation (all from the run's seeded generator; g = the run)
---------------------------------------------------------------------------
local function Difficulty(r) return math.min(1, r / 160) end
local function ZoneOf(r) return ZONES[(math.floor(math.max(0, r) / ZONE_ROWS) % #ZONES) + 1] end

--- Lanes come in runs: a few roads, a river or two, some grass in between.
local function NextRun(g, r)
    local d = Difficulty(r)
    local roll = g.rand()
    if roll < 0.36 - d * 0.1 then return "grass", g.int(1, 2) end
    if roll < 0.70 then return "road", g.int(1, 2 + math.floor(d * 2)) end
    return "water", g.int(1, 2 + math.floor(d + 0.5))
end

--- Lays out a lane's traffic or logs. Movers are packed at fixed gaps along a loop a little
--- longer than the screen, so a lane is never empty; neighbouring lanes of the same kind
--- always run opposite ways, so their logs line up every few seconds.
local function MakeMovers(g, row, r, kind, prev)
    local d = Difficulty(r)
    local lenMin, lenMax, gapMin, gapMax
    if kind == "road" then
        row.speed = 1.3 + g.rand() * (1.2 + d * 2.4)
        lenMin, lenMax = 1, 2                               -- raptors 1, kodos 2
        gapMin, gapMax = 3.2 - d * 1.2, 5.5 - d * 2.0       -- room to slip between them
    else
        row.speed = 0.6 + g.rand() * (0.5 + d * 1.2)
        lenMin, lenMax = 2, 3
        if d > 0.6 and g.rand() < 0.5 then lenMax = 2 end
        gapMin, gapMax = 1.0 + d * 0.8, 2.0 + d * 1.5       -- never far to the next log
    end
    if prev and prev.kind == kind and prev.dir then row.dir = -prev.dir
    else row.dir = g.rand() < 0.5 and -1 or 1 end
    local laid, pos = {}, 0
    while #laid < MAX_MOVERS do
        local len = g.int(lenMin, lenMax)
        laid[#laid + 1] = { off = pos, len = len }
        pos = pos + len + gapMin + g.rand() * (gapMax - gapMin)
        if pos >= MIN_SPAN then break end
    end
    if pos < MIN_SPAN then -- out of movers before the loop was long enough: widen every gap a bit
        local extra = (MIN_SPAN - pos) / #laid
        for i, m in ipairs(laid) do m.off = m.off + (i - 1) * extra end
        pos = MIN_SPAN
    end
    row.span = pos
    local start = g.rand() * row.span
    row.movers = {}
    for i, m in ipairs(laid) do
        row.movers[i] = { x0 = start + m.off, x = 0, len = m.len,
            sprite = kind == "road" and (m.len == 2 and "kodo" or "raptor") or "log" }
    end
end

local function GenRow(g, r)
    local row = { kind = "grass", blocks = {}, deco = {}, zone = ZoneOf(r) }
    if r >= SAFE_ROWS then
        if g.runLeft <= 0 then
            -- never two rivers or roads back to back without a breather of grass
            local kind, n = NextRun(g, r)
            if kind == g.runKind and kind ~= "grass" then kind, n = "grass", 1 end
            g.runKind, g.runLeft = kind, n
        end
        row.kind = g.runKind
        g.runLeft = g.runLeft - 1
    end
    local prev = g.rows[r - 1]
    local d = Difficulty(r)
    if row.kind == "grass" then
        -- a few trees and rocks, always leaving plenty of gaps
        local n = r < SAFE_ROWS and 0 or g.int(0, 3)
        for _ = 1, n do
            local c = g.int(0, COLS - 1)
            if not row.blocks[c] then
                row.blocks[c] = true
                row.deco[#row.deco + 1] = { col = c, sprite = g.rand() < 0.6 and row.zone.tree or "rock" }
            end
        end
    elseif row.kind == "road" and r > 20 and g.rand() < 0.12 + d * 0.1 then
        -- a stampede lane: empty, then a warning, then a fast herd thunders through, on a
        -- timetable from its own seeded generator
        local rand = NewRand(g.seed * 31 + r * 7919)
        row.stampede = { rand = rand, cycles = {}, at = 1 }
        row.dir = g.rand() < 0.5 and -1 or 1
        row.movers, row.speed = {}, STAMPEDE_SPEED
    elseif row.kind == "water" and not (prev and prev.pads) and g.rand() < 0.22 then
        -- lily pads: stepping stones that stay put
        row.pads = {}
        local n = g.int(3, 4)
        local tries = 0
        while tries < 20 and #row.deco < n do
            tries = tries + 1
            local c = g.int(0, COLS - 1)
            if not row.pads[c] then
                row.pads[c] = true
                row.deco[#row.deco + 1] = { col = c, sprite = "pad" }
            end
        end
        -- a pad row after a grass row: make sure the pads aren't all behind trees
        if prev and prev.kind == "grass" then
            local reachable = false
            for c in pairs(row.pads) do if not prev.blocks[c] then reachable = true end end
            if not reachable then
                for c in pairs(row.pads) do prev.blocks[c] = nil end
                local keep = {}
                for _, dd in ipairs(prev.deco) do if not row.pads[dd.col] then keep[#keep + 1] = dd end end
                prev.deco, prev.dirty = keep, true
            end
        end
    else
        MakeMovers(g, row, r, row.kind, prev)
    end
    -- a coin now and then, on open ground
    if r >= SAFE_ROWS and (row.kind == "grass" or (row.kind == "road" and not row.stampede)) and g.rand() < 0.3 then
        local c = g.int(0, COLS - 1)
        if not row.blocks[c] then row.coin = c end
    end
    return row
end

local function Row(g, r)
    local row = g.rows[r]
    if not row then
        for i = g.genTo + 1, r do g.rows[i] = GenRow(g, i) end
        g.genTo = math.max(g.genTo, r)
        row = g.rows[r]
        if not row then -- far behind and already forgotten: plain grass
            row = { kind = "grass", blocks = {}, deco = {}, zone = ZoneOf(r) }
            g.rows[r] = row
        end
    end
    return row
end

---------------------------------------------------------------------------
-- Movement as a function of the run's clock
---------------------------------------------------------------------------
--- A stampede lane's state at time t: "wait", "warn" or "charge", and seconds into it.
local function StampedeAt(row, t)
    local s = row.stampede
    local c = s.cycles
    -- extend the timetable as far as t
    while #c == 0 or c[#c].stop <= t do
        local start = #c == 0 and 0 or c[#c].stop
        local wait = #c == 0 and (1 + s.rand() * 3) or (2.5 + s.rand() * 3)
        local warn = start + wait
        local charge = warn + STAMPEDE_WARN
        local stop = charge + (COLS + 6 + STAMPEDE_GAP * 2) / STAMPEDE_SPEED
        c[#c + 1] = { start = start, warn = warn, charge = charge, stop = stop }
    end
    while c[s.at].stop <= t do s.at = s.at + 1 end
    local cy = c[s.at]
    if t >= cy.charge then return "charge", t - cy.charge end
    if t >= cy.warn then return "warn", t - cy.warn end
    return "wait", t - cy.start
end

--- Puts every mover in a row where it is at time t.
local function PlaceMovers(row, t)
    if row.stampede then
        local phase, since = StampedeAt(row, t)
        local charging = phase == "charge"
        if charging ~= (row.charging or false) then
            row.charging = charging
            row.movers = {}
            if charging then for i = 1, 3 do row.movers[i] = { x = 0, len = 2, sprite = "kodo" } end end
            row.dirty = true
        end
        row.phase, row.phaseT = phase, since
        if charging then
            for i, m in ipairs(row.movers) do
                local back = (i - 1) * STAMPEDE_GAP + 2
                m.x = row.dir > 0 and (-back + STAMPEDE_SPEED * since) or (COLS + back - 2 - STAMPEDE_SPEED * since)
            end
        end
        return
    end
    if not row.movers then return end
    local lo = COLS + 2 - row.span
    for _, m in ipairs(row.movers) do
        local raw = m.x0 + row.dir * row.speed * t
        m.x = (raw - lo) % row.span + lo
    end
end

---------------------------------------------------------------------------
-- Rules
---------------------------------------------------------------------------
local function MoverAt(row, x0, x1)
    for _, m in ipairs(row.movers or {}) do
        if x1 > m.x and x0 < m.x + m.len then return m end
    end
end

--- Is the player safe standing in this water row at x?
local function Afloat(row, x)
    if row.pads then return row.pads[math.floor(x + 0.5)] == true end
    return MoverAt(row, x + 0.3, x + 0.7) ~= nil
end

---------------------------------------------------------------------------
-- The engine
---------------------------------------------------------------------------
local Engine = {}
Engine.__index = Engine

--- opts.spectator: a replay engine (no input, no saving; driven by Feed).
function Arcade.NewEngine(opts)
    local e = setmetatable({ spectator = opts and opts.spectator or false }, Engine)
    return e
end

function Engine:Die(how, score)
    local g = self.g
    if g.state == "over" then return end
    g.state, g.death, g.diedAt = "over", how, GetTime()
    if score then g.score = score end
    if self.spectator then self:Render() return end
    g.newBest = g.score > Arcade.Best()
    if g.newBest then
        ns.charDB.arcadeBest = g.score
        if ns.Board then ns.Board.Changed() end -- the guild's high-score list
    end
    ns.Sound(g.newBest and g.score > 0 and "win" or "bust")
    if g.duel and ns.Kodo then
        ns.Kodo.RunEvent(g.duel, { k = "d", t = g.time, c = how, s = g.score })
        ns.Kodo.RunOver(g.duel, g.score)
    end
    self:Render()
end

function Engine:Land()
    local g = self.g
    local h = g.hop
    g.hop = nil
    g.x, g.r = h.toX, h.toR
    if g.r > g.score then
        g.score = g.r
        if not self.spectator then
            if g.score % CHIME_EVERY == 0 then ns.Sound("win") end
            if g.duel and ns.Kodo then ns.Kodo.Progress(g.duel, g.score) end
        end
    end
    local row = Row(g, g.r)
    if row.zone ~= g.zone then -- a new zone
        g.zone = row.zone
        if g.r > 0 then g.banner = { text = "Entering " .. row.zone.name, at = GetTime() } end
    end
    if row.coin and row.coin == math.floor(g.x + 0.5) then
        row.coin, row.dirty = nil, true
        g.coins = g.coins + 1
        if not self.spectator then
            local db = Save()
            db.arcadeCoins = db.arcadeCoins + 1
            ns.Sound("coin")
        end
    end
    if not self.spectator and row.kind == "water" and not Afloat(row, g.x) then return self:Die("water") end
    if g.queued then
        local q = g.queued
        g.queued = nil
        self:Hop(q)
    end
end

--- Starts a hop to (toX, toR).
function Engine:StartHop(toX, toR)
    local g = self.g
    if g.hop then self:Land() end
    g.started = true
    if toX ~= math.floor(g.x + 0.5) then g.facing = toX > g.x and 1 or -1 end
    g.hop = { fromX = g.x, fromR = g.r, toX = toX, toR = toR, t = 0 }
end

function Engine:Hop(dir)
    local g = self.g
    if not g or g.state ~= "play" then return end
    if g.hop then g.queued = dir return end
    local d = DIRS[dir]
    if not d then return end
    local toX = math.floor(g.x + 0.5) + d[1]
    local toR = g.r + d[2]
    if toX < 0 or toX > COLS - 1 then return end
    local row = Row(g, toR)
    if row.kind == "grass" and row.blocks[toX] then return end -- a tree or rock in the way
    self:StartHop(toX, toR)
    if d[1] ~= 0 then g.facing = d[1] end
    -- a duel run's hops go to spectators
    if g.duel and ns.Kodo then ns.Kodo.RunEvent(g.duel, { k = "h", t = g.time, x = toX, r = toR }) end
end

function Engine:Step(dt)
    local g = self.g
    if g.state ~= "play" then return end
    dt = math.min(dt, 0.05)
    g.time = g.time + dt

    -- everything in view (and a little beyond) is where the clock says
    local lo, hi = math.floor(g.cam) - 1, math.floor(g.cam) + VIEW_ROWS + 1
    for r = lo, hi do PlaceMovers(Row(g, r), g.time) end

    -- the hop in progress
    local px, pr = g.x, g.r
    if g.hop then
        local h = g.hop
        h.t = h.t + dt / HOP_TIME
        if h.t >= 1 then
            self:Land()
            if g.state ~= "play" then return end
        else
            px = h.fromX + (h.toX - h.fromX) * h.t
            pr = h.t < 0.5 and h.fromR or h.toR
        end
    end
    if not g.hop then px, pr = g.x, g.r end

    local row = Row(g, pr)
    if not self.spectator and row.kind == "road" and MoverAt(row, px + 0.22, px + 0.78) then
        return self:Die(row.stampede and "stampede" or "road")
    end
    if row.kind == "water" and not g.hop and not row.pads then
        if not self.spectator and not Afloat(row, g.x) then return self:Die("water") end
        g.x = g.x + row.dir * row.speed * dt -- ride the log
        if not self.spectator and (g.x < -0.45 or g.x > COLS - 0.55) then return self:Die("swept") end
    end

    -- the view creeps forward once you've started, and keeps you in the lower half
    if g.started then g.cam = g.cam + (0.32 + math.min(0.55, g.score / 220)) * dt end
    local want = (g.hop and g.hop.toR or g.r) - 3
    if want > g.cam then g.cam = g.cam + (want - g.cam) * math.min(1, dt * 8) end
    if not self.spectator and g.r < g.cam - 0.7 and not g.hop then return self:Die("slow") end
    if self.spectator and g.cam > g.r + 0.5 then g.cam = g.r + 0.5 end

    -- forget rows far behind
    for r in pairs(g.rows) do if r < lo - 2 then g.rows[r] = nil end end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
function Engine:BindRow(w, r)
    local g = self.g
    local row = Row(g, r)
    w.r, row.dirty = r, nil
    local ground = row.kind == "grass" and row.zone.grass or row.kind
    SetSprite(w.ground, ground, "REPEAT")
    w.ground:SetTexCoord(0, COLS, 0, 1)
    -- a slightly darker shade on alternate grass rows, like mown stripes
    if row.kind == "grass" and r % 2 == 0 then w.ground:SetVertexColor(0.9, 0.93, 0.9) else w.ground:SetVertexColor(1, 1, 1) end
    for i = 1, MAX_DECO do
        local d = row.deco[i]
        local t = w.deco[i]
        t:SetShown(d ~= nil)
        if d then
            SetSprite(t, d.sprite)
            local tint = d.sprite == "tree" and row.zone.tint or nil
            if tint then t:SetVertexColor(tint[1], tint[2], tint[3]) else t:SetVertexColor(1, 1, 1) end
            t:ClearAllPoints()
            t:SetPoint("BOTTOMLEFT", d.col * TILE, 0)
        end
    end
    -- stampede warnings use the spare decoration slots
    if row.stampede then
        for i = 1, 2 do
            local t = w.deco[i]
            SetSprite(t, "warn")
            t:SetVertexColor(1, 1, 1)
            t:ClearAllPoints()
            t:SetPoint("BOTTOMLEFT", (i == 1 and 0 or COLS - 1) * TILE, 0)
            t:Hide()
        end
    end
    w.coin:SetShown(row.coin ~= nil)
    if row.coin then
        w.coin:ClearAllPoints()
        w.coin:SetPoint("BOTTOMLEFT", row.coin * TILE, 0)
    end
    for i = 1, MAX_MOVERS do
        local m = row.movers and row.movers[i]
        local parts = w.movers[i]
        for p = 1, 3 do parts[p]:Hide() end
        if m then
            if m.sprite == "log" then
                for p = 1, m.len do
                    local name = p == 1 and "log_l" or (p == m.len and "log_r" or "log_m")
                    SetSprite(parts[p], name)
                    parts[p]:SetSize(TILE, TILE)
                    parts[p]:SetTexCoord(0, 1, 0, 1)
                    parts[p]:Show()
                end
            else
                SetSprite(parts[1], m.sprite)
                parts[1]:SetSize(TILE * m.len, TILE)
                -- sprites face right; flip for traffic going left
                if row.dir < 0 then parts[1]:SetTexCoord(1, 0, 0, 1) else parts[1]:SetTexCoord(0, 1, 0, 1) end
                parts[1]:Show()
            end
        end
    end
end

function Engine:OverlayText()
    local g = self.g
    if self.spectator then
        if g.state == "over" then
            return ("|cffff4040%s|r\nScore |cffffffff%d|r"):format(DEATHS[g.death] or "Run over", g.score)
        elseif not g.synced then
            return "|cff888888Tuning in...|r"
        end
        return nil
    end
    local duel = g.duel
    if g.state == "ready" then
        if duel then
            return ("|cffffd100Kodo Crossing duel|r\nvs |cffffffff%s|r for %s\n\nYou get |cffffffffone run|r on the same lanes they get.\nThe higher score wins.\n\n|cffffd100Press an arrow key to start|r"):format(
                ns.Short(duel.opponent), ns.Stake(duel.bet or 0))
        end
        return "|cffffd100Kodo Crossing|r\n\nHop as far as you can. Dodge kodos and raptors,\nride logs and lily pads over rivers, grab coins,\nand don't dawdle - the herd is coming.\n\n|cffffffffArrow keys / WASD|r, |cffffffffP|r to pause\n\n|cffffd100Press an arrow key to start|r"
    elseif g.state == "paused" then
        return g.pauseWhy or "|cffffd100Paused|r\n\nPress an arrow key to carry on"
    elseif g.state == "over" then
        local head = ("|cffff4040%s|r\n\nScore |cffffffff%d|r%s%s"):format(DEATHS[g.death] or "Ouch!", g.score,
            g.newBest and g.score > 0 and "  -  |cff20ff20new best!|r" or ("   (best " .. Arcade.Best() .. ")"),
            g.coins > 0 and ("\n+%d coin%s"):format(g.coins, g.coins == 1 and "" or "s") or "")
        if duel then
            if g.duelResult then
                return head .. "\n\n" .. g.duelResult .. "\n\n|cffffd100Press Space for a practice run|r"
            end
            return head .. ("\n\n|cffbbbbbbWaiting for %s to finish their run...|r"):format(ns.Short(duel.opponent))
        end
        return head .. "\n\n|cffffd100Press Space or click to play again|r"
    end
end

function Engine:Render()
    local g = self.g
    if not self.canvas or not g then return end
    local now = GetTime()
    local base = math.floor(g.cam) - 1
    for i = 0, POOL - 1 do
        local r = base + i
        local w = self.rowsUI[(r % POOL) + 1]
        local row = Row(g, r)
        PlaceMovers(row, g.time)
        if w.r ~= r or row.dirty then self:BindRow(w, r) end
        w:ClearAllPoints()
        w:SetPoint("BOTTOMLEFT", self.canvas, "BOTTOMLEFT", 0, (r - g.cam) * TILE)
        for mi = 1, MAX_MOVERS do
            local m = row.movers and row.movers[mi]
            if m then
                local parts = w.movers[mi]
                if m.sprite == "log" then
                    for p = 1, m.len do
                        parts[p]:ClearAllPoints()
                        parts[p]:SetPoint("BOTTOMLEFT", w, "BOTTOMLEFT", (m.x + p - 1) * TILE, 0)
                    end
                else
                    parts[1]:ClearAllPoints()
                    parts[1]:SetPoint("BOTTOMLEFT", w, "BOTTOMLEFT", m.x * TILE, 0)
                end
            end
        end
        if row.stampede then -- blink the warning signs
            local on = row.phase == "warn" and (math.floor((row.phaseT or 0) * 6) % 2 == 0)
            w.deco[1]:SetShown(on)
            w.deco[2]:SetShown(on)
        end
    end

    -- the hopper: hops in a little arc, faces the way it last moved; its ghost floats up
    local px, pr, lift = g.x, g.r, 0
    if g.hop then
        local t = g.hop.t
        px = g.hop.fromX + (g.hop.toX - g.hop.fromX) * t
        pr = g.hop.fromR + (g.hop.toR - g.hop.fromR) * t
        lift = math.sin(math.pi * math.min(1, t)) * TILE * 0.28
    end
    local dead = g.state == "over"
    if dead then lift = math.min(1.5, now - (g.diedAt or now)) * TILE * 0.7 end
    self.player:SetShown(not dead)
    self.ghost:SetShown(dead)
    if dead then self.ghost:SetAlpha(math.max(0.35, 1 - (now - (g.diedAt or now)) * 0.4)) end
    local who = dead and self.ghost or self.player
    who:ClearAllPoints()
    who:SetPoint("BOTTOMLEFT", self.canvas, "BOTTOMLEFT", px * TILE, (pr - g.cam) * TILE + lift)
    if g.char ~= self.shownChar then SetSprite(self.player, g.char) self.shownChar = g.char end
    if g.facing < 0 then self.player:SetTexCoord(1, 0, 0, 1) else self.player:SetTexCoord(0, 1, 0, 1) end

    if g.banner and now - g.banner.at < 2.5 then
        self.banner:SetText(g.banner.text)
        self.banner:SetAlpha(math.min(1, 2.5 - (now - g.banner.at)))
        self.banner:Show()
    else
        self.banner:Hide()
    end

    local text = self:OverlayText()
    self.overlay.text:SetText(text or "")
    self.overlay:SetShown(text ~= nil)
    if self.OnRender then self:OnRender() end
end

--- Builds the canvas (and its row widgets) inside parent, anchored by the caller.
function Engine:BuildCanvas(parent)
    local canvas = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    self.canvas = canvas
    canvas:SetSize(COLS * TILE, VIEW_ROWS * TILE)
    pcall(canvas.SetClipsChildren, canvas, true)
    self.rowsUI = {}
    for i = 1, POOL do
        local w = CreateFrame("Frame", nil, canvas)
        w:SetSize(COLS * TILE, TILE)
        w.r = false -- which world row it's showing
        w.ground = Sprite(w, "BACKGROUND", "grass", "REPEAT")
        w.ground:SetAllPoints()
        w.deco = {}
        for d = 1, MAX_DECO do
            local t = Sprite(w, "ARTWORK", "tree")
            t:SetSize(TILE, TILE)
            w.deco[d] = t
        end
        w.coin = Sprite(w, "ARTWORK", "coin")
        w.coin:SetSize(TILE, TILE)
        w.coin:Hide()
        w.movers = {}
        for m = 1, MAX_MOVERS do
            local parts = {}
            for k = 1, 3 do
                parts[k] = Sprite(w, "BORDER", "log_m")
                parts[k]:SetSize(TILE, TILE)
                parts[k]:Hide()
            end
            w.movers[m] = parts
        end
        self.rowsUI[i] = w
    end
    -- the rows are child frames, which draw over the canvas's own textures: put the hopper on
    -- a frame above them
    local top = CreateFrame("Frame", nil, canvas)
    top:SetAllPoints()
    top:SetFrameLevel(canvas:GetFrameLevel() + 10)
    self.player = Sprite(top, "OVERLAY", "gnome")
    self.player:SetSize(TILE, TILE)
    self.ghost = Sprite(top, "OVERLAY", "ghost")
    self.ghost:SetSize(TILE, TILE)
    self.ghost:Hide()
    self.banner = top:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    self.banner:SetPoint("TOP", 0, -18)
    self.banner:Hide()

    local overlay = CreateFrame("Frame", nil, canvas, "BackdropTemplate")
    self.overlay = overlay
    overlay:SetPoint("CENTER")
    overlay:SetSize(COLS * TILE - 30, self.spectator and 110 or 200)
    overlay:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    overlay:SetBackdropColor(0, 0, 0, 0.72)
    overlay:SetBackdropBorderColor(0.9, 0.72, 0.3, 1)
    overlay:SetFrameLevel(canvas:GetFrameLevel() + 20)
    overlay.text = overlay:CreateFontString(nil, "OVERLAY", self.spectator and "GameFontNormalHuge" or "GameFontHighlight")
    overlay.text:SetPoint("CENTER")
    overlay.text:SetWidth(COLS * TILE - 50)
    overlay.text:SetJustifyH("CENTER")
    return canvas
end

--- A new run. opts.seed: the lanes (random if not given); opts.duel: the Kodo duel it's for;
--- opts.char: the character to show (spectators).
function Engine:New(opts)
    opts = opts or {}
    local seed = opts.seed or math.random(1, 2147483646)
    local rand, int = NewRand(seed)
    self.g = { rows = {}, genTo = -3, runKind = "grass", runLeft = 0, x = math.floor(COLS / 2), r = 0, cam = -1,
        score = 0, time = 0, facing = 1, state = "ready", started = false, coins = 0, seed = seed,
        rand = rand, int = int, duel = opts.duel, char = opts.char or PlayingAs() }
    local g = self.g
    for r = -2, VIEW_ROWS + 2 do Row(g, r) end
    g.zone = Row(g, 0).zone
    if self.rowsUI then for _, w in ipairs(self.rowsUI) do w.r = false end end
    self:Render()
end

---------------------------------------------------------------------------
-- Replay (spectators): follow someone's run from its seed and hops
---------------------------------------------------------------------------
-- How far behind the player a replay runs, so a batch of hops always arrives in time.
local REPLAY_DELAY = 1.5

--- Starts following a run: seed, character, and where they are now (s = snapshot).
function Engine:Follow(seed, char, s)
    self:New({ seed = seed, char = char })
    local g = self.g
    g.state, g.started, g.synced = "play", s.t > 0, true
    g.time = s.t
    g.x, g.r, g.cam, g.score = s.x, s.r, s.cam or (s.r - 3), s.score or 0
    g.zone = Row(g, g.r).zone
    g.queue, g.known = {}, s.t
    g.clock = s.t -- where the player was when we last heard
    if s.over then self:Die(s.over, s.score) end
    self:Render()
end

--- Hops ({k="h", t, x, r}) and the end ({k="d", t, c, s}) as they arrive.
function Engine:Feed(events, knownTime)
    local g = self.g
    if not g or not g.queue then return end
    for _, ev in ipairs(events) do
        g.queue[#g.queue + 1] = ev
        -- the run is over: nothing more is coming, so let the replay play right up to the end
        if ev.k == "d" then g.known = math.max(g.known, ev.t + REPLAY_DELAY + 0.01) end
    end
    if knownTime and knownTime > g.known then g.known = knownTime end
end

--- Advances a replay, never past what we've heard about (minus a small cushion).
function Engine:Replay(dt)
    local g = self.g
    if not g or not g.queue or g.state ~= "play" then return end
    local limit = g.known - REPLAY_DELAY
    -- if we fall far behind (e.g. the window was closed), catch up at once
    if limit - g.time > 4 then dt = limit - g.time - 1 end
    local target = math.min(g.time + dt, limit)
    local guard = 0 -- never let a replay hold up the game: at worst it pauses for a frame
    while g.state == "play" do
        local ev = g.queue[1]
        local stop = ev and math.min(ev.t, target) or target
        -- a long quiet stretch: everything that moves is a function of the clock, so jump
        -- straight there instead of simulating every frame (just carry a log-rider along)
        if stop - g.time > 1 and not g.hop then
            local jump = stop - g.time - 0.5
            local row = Row(g, g.r)
            if row.kind == "water" and not row.pads and row.speed then
                g.x = math.max(-0.4, math.min(COLS - 0.6, g.x + row.dir * row.speed * jump))
            end
            if g.started then g.cam = math.min(g.r + 0.5, g.cam + (0.32 + math.min(0.55, g.score / 220)) * jump) end
            g.time = g.time + jump
        end
        while g.time < stop - 1e-6 do
            local before = g.time
            self:Step(math.min(0.05, stop - g.time))
            guard = guard + 1
            if g.time <= before or guard > 2000 then return end
        end
        if not ev or ev.t > target then break end
        table.remove(g.queue, 1)
        if ev.k == "h" then
            self:StartHop(ev.x, ev.r)
        elseif ev.k == "d" then
            self:Die(ev.c, ev.s)
        end
    end
end

---------------------------------------------------------------------------
-- The player's own engine (Arcade tab)
---------------------------------------------------------------------------
local main = Arcade.NewEngine()
Arcade.main = main

local function KeyboardOn(on)
    if not main.canvas then return end
    -- taking keys from the action bars isn't allowed in combat; we pause instead
    if on and InCombatLockdown and InCombatLockdown() then on = false end
    pcall(main.canvas.EnableKeyboard, main.canvas, on)
end

local function Pause(why)
    local g = main.g
    if g and g.state == "play" then g.state, g.pauseWhy = "paused", why end
    main:Render()
end

function Arcade.Render() main:Render() end
function Arcade.New(opts) main:New(opts) end

--- Starts this player's run in a Kodo Crossing duel (same seed on both sides).
function Arcade.StartDuel(game)
    main:New({ seed = game.seed, duel = game })
    if ns.UI then
        ns.UI.SetShown(true)
        ns.UI.SelectTab("arcade")
    end
end

--- Ends the current duel run now (e.g. /gg cancel mid-run): the score so far counts.
function Arcade.Forfeit(game)
    local g = main.g
    if g and g.duel == game then
        if g.state == "ready" then g.state = "play" end
        main:Die("quit")
        return true
    end
    return false
end

--- The duel's result, shown on the run's end screen.
function Arcade.DuelOver(game, text)
    local g = main.g
    if g and g.duel == game then
        g.duelResult = text
        main:Render()
    end
end

--- Where my duel run is right now, for a spectator who just tuned in.
function Arcade.Snapshot(game)
    local g = main.g
    if not g or g.duel ~= game then return nil end
    return { t = g.time, x = g.hop and g.hop.toX or g.x, r = g.hop and g.hop.toR or g.r, cam = g.cam,
        score = g.score, over = g.state == "over" and (g.death or "quit") or nil, char = g.char, seed = g.seed }
end

--- What a key or button does: arrows hop (and start or resume), P pauses, Space restarts.
function Arcade.Input(action)
    if not main.g then main:New() end
    local g = main.g
    if g.state == "over" then
        -- a duel run can't be re-run; once it's settled, Space starts a practice run
        if (action == "start" or action == "click") and (not g.duel or g.duelResult) then
            main:New()
        end
        return
    end
    if action == "pause" then
        if g.state == "play" then Pause() elseif g.state == "paused" then g.state, g.pauseWhy = "play", nil main:Render() end
        return
    end
    if g.state == "ready" or g.state == "paused" then
        if InCombatLockdown and InCombatLockdown() then return end
        if DIRS[action] or action == "start" or action == "click" then
            g.state, g.pauseWhy = "play", nil
            KeyboardOn(true)
        end
    end
    if DIRS[action] then main:Hop(action) end
    main:Render()
end

---------------------------------------------------------------------------
-- Character chooser (bottom of the tab)
---------------------------------------------------------------------------
local panel

local function RefreshChooser()
    if not panel or not panel.charBtn then return end
    local db = Save()
    local c = CharInfo(db.arcadeChar)
    local owned = db.arcadeOwned[c.key]
    panel.charBtn:SetText(c.name .. "  >")
    SetSprite(panel.charIcon, c.key)
    panel.charIcon:SetDesaturated(not owned)
    if owned then
        panel.buy:Hide()
    else
        panel.buy:Show()
        panel.buy:SetText(("Unlock (%d)"):format(c.cost))
        if db.arcadeCoins >= c.cost then panel.buy:Enable() else panel.buy:Disable() end
    end
    local g = main.g
    local busy = g and (g.state == "play" or g.state == "paused")
    if busy then panel.charBtn:Disable() else panel.charBtn:Enable() end
    local duel = g and g.duel
    if duel then
        -- a duel: make it obvious who you're up against, and the score between you
        local mine = ns.IsMe(duel.a) and "a" or "b"
        local theirs = mine == "a" and "b" or "a"
        local theirScore = duel.scores and duel.scores[theirs] or 0
        local theyDone = duel.finishedRun and duel.finishedRun[theirs]
        panel.score:SetText(("|cffff4040DUEL|r vs |cffffd100%s|r  -  %s      You |cffffffff%d|r : |cffffffff%d|r %s"):format(
            ns.Short(duel.opponent), ns.Stake(duel.bet or 0), duel.scores and duel.scores[mine] or g.score,
            theirScore, ns.Short(duel.opponent)))
        -- and on the game screen itself, top right: who you're up against and how they're doing
        panel.vs.name:SetText(("vs |cffffd100%s|r"):format(ns.Short(duel.opponent)))
        panel.vs.score:SetText(("%d%s"):format(theirScore, theyDone and "  |cffbbbbbbfinal|r" or ""))
        panel.vs:Show()
    else
        panel.score:SetText(("Score  |cffffffff%d|r      Best  |cffffd100%d|r      Coins  |cffffd100%d|r"):format(
            g and g.score or 0, Arcade.Best(), db.arcadeCoins))
        panel.vs:Hide()
    end
end

function Arcade.NextChar()
    local db = Save()
    local i = 1
    for n, c in ipairs(Arcade.CHARS) do if c.key == db.arcadeChar then i = n end end
    db.arcadeChar = Arcade.CHARS[i % #Arcade.CHARS + 1].key
    local g = main.g
    if g and g.state ~= "play" and g.state ~= "paused" then g.char = PlayingAs() end
    main:Render()
end

function Arcade.Buy()
    local db = Save()
    local c = CharInfo(db.arcadeChar)
    if db.arcadeOwned[c.key] or db.arcadeCoins < c.cost then return false end
    db.arcadeCoins = db.arcadeCoins - c.cost
    db.arcadeOwned[c.key] = true
    ns.Sound("bigwin")
    local g = main.g
    if g and g.state ~= "play" and g.state ~= "paused" then g.char = PlayingAs() end
    main:Render()
    return true
end

function Arcade.Build(p)
    panel = p
    p.score = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    p.score:SetPoint("TOP", 0, -2)
    local canvas = main:BuildCanvas(p)
    canvas:SetPoint("TOP", 0, -26)
    canvas:EnableMouse(true)
    canvas:SetScript("OnMouseDown", function() Arcade.Input("click") end)
    main.OnRender = RefreshChooser

    -- in a duel: the opponent and their score, in a box on the game screen
    local vs = CreateFrame("Frame", nil, canvas, "BackdropTemplate")
    vs:SetPoint("TOPRIGHT", -6, -6)
    vs:SetSize(150, 52)
    vs:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    vs:SetBackdropColor(0, 0, 0, 0.7)
    vs:SetBackdropBorderColor(1, 0.25, 0.25, 1)
    vs:SetFrameLevel(canvas:GetFrameLevel() + 15)
    vs.name = vs:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    vs.name:SetPoint("TOP", 0, -8)
    vs.score = vs:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    vs.score:SetPoint("TOP", vs.name, "BOTTOM", 0, -2)
    vs:Hide()
    p.vs = vs

    -- buttons, for playing with the mouse
    local function Btn(label, action, x)
        local b = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
        b:SetSize(40, 26)
        b:SetText(label)
        b:SetPoint("BOTTOM", x, 4)
        b:SetScript("OnClick", function() Arcade.Input(action) end)
        return b
    end
    Btn("<", "left", -66)
    Btn("^", "up", -22)
    Btn("v", "down", 22)
    Btn(">", "right", 66)

    -- character chooser: bottom left; unlock button: bottom right
    p.charIcon = Sprite(p, "ARTWORK", "gnome")
    p.charIcon:SetSize(26, 26)
    p.charIcon:SetPoint("BOTTOMLEFT", 0, 4)
    p.charBtn = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    p.charBtn:SetSize(96, 26)
    p.charBtn:SetPoint("LEFT", p.charIcon, "RIGHT", 4, 0)
    p.charBtn:SetScript("OnClick", function() Arcade.NextChar() end)
    p.buy = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    p.buy:SetSize(96, 26)
    p.buy:SetPoint("BOTTOMRIGHT", 0, 4)
    p.buy:SetScript("OnClick", function() Arcade.Buy() end)

    -- keys: arrows / WASD / Space / P go to the game while it runs; every other key passes through
    canvas:SetScript("OnKeyDown", function(self, key)
        local action = KEYS[key]
        local ours = action ~= nil and not (InCombatLockdown and InCombatLockdown())
        pcall(self.SetPropagateKeyboardInput, self, not ours)
        if ours then Arcade.Input(action) end
        if key == "ESCAPE" then Pause() end
    end)
    canvas:SetScript("OnUpdate", function(_, elapsed)
        local g = main.g
        if not g then return end
        if g.state == "play" then
            main:Step(elapsed)
            main:Render()
        elseif (g.state == "over" and GetTime() - (g.diedAt or 0) < 1.6) or (g.banner and GetTime() - g.banner.at < 2.6) then
            main:Render() -- the ghost floating up, the zone banner fading
        end
    end)
    canvas:SetScript("OnShow", function()
        KeyboardOn(true)
        main:Render()
    end)
    canvas:SetScript("OnHide", function()
        Pause()
        KeyboardOn(false)
    end)

    -- combat: pause and hand the keys back
    local ev = CreateFrame("Frame")
    pcall(ev.RegisterEvent, ev, "PLAYER_REGEN_DISABLED")
    pcall(ev.RegisterEvent, ev, "PLAYER_REGEN_ENABLED")
    ev:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then
            Pause("|cffff4040In combat|r\n\nPaused - your keys are back to normal.\nCome back when the fight's over.")
            pcall(canvas.EnableKeyboard, canvas, false)
        elseif canvas:IsVisible() then
            KeyboardOn(true)
            local g = main.g
            if g and g.state == "paused" then g.pauseWhy = nil main:Render() end
        end
    end)

    main:New()
end

-- for the mock-client tests
function Arcade._Step(dt) if main.g then main:Step(dt) main:Render() end end
function Arcade._State() return main.g end
function Arcade._Canvas() return main.canvas end
function Arcade._Row(r) return main.g and Row(main.g, r) end
function Arcade._PlaceMovers(row, t) PlaceMovers(row, t) end
