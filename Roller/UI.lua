-- Roller/UI.lua: High Roller on screen - its own window, the room, sprite pools, HUD, menus,
-- the talent screen, keys and sounds. It only ever reads the run table (g) and calls HR.Pick /
-- HR.Advance; every rule lives in Rules.lua, Engine.lua and Extras.lua.
--
-- Kept light: fixed pools of textures re-used every frame, nothing created while playing,
-- OnUpdate only while the window is showing. Nothing is drawn outside the canvas.
local ADDON_NAME, ns = ...
local HR = ns.Roller
local Art = ns.Art
local floor, ceil, min, max, sin, cos, sqrt, atan2, pi = math.floor, math.ceil, math.min, math.max, math.sin, math.cos, math.sqrt, math.atan2, math.pi
local VW, VH = HR.VIEW_W, HR.VIEW_H
local CW = 800                 -- the canvas, in screen pixels
local S = CW / VW              -- screen pixels per room unit
local CH = VH * S
local K = 1.45                 -- characters are drawn a little larger than their hit circles
local TILE = 160               -- one floor tile on screen
local TRIM = 32                -- the wall trim's thickness on screen
local WALL = 16 / S            -- how far the trim reaches inside the room's edge, in room units
local HP_W, XP_W, BOSS_W = 300, 640, 440

local UI = {}
HR.UI = UI

local ui = { held = {}, shake = 0 } -- ui.g: the run; ui.menu: a lobby menu (when there's no run menu)
UI.state = ui

local function Tex(name) return Art.Tex("roller/" .. name) end

--- A sprite as inline text, for menus and the HUD.
local function Icon(name, size)
    size = size or 16
    return ("|T%s:%d:%d|t"):format(Tex(name), size, size)
end
UI.Icon = Icon

-- Sprites with a second walking frame (<name>_2).
local ANIM = {}
for _, n in ipairs({ "hero", "slime", "slime_s", "imp", "goldimp", "bouncer", "soldier", "joker", "pickpocket", "enforcer", "mimic", "shark",
    "golem", "spinner", "croupier", "teller", "devil", "cat", "pig" }) do ANIM[n] = n .. "_2" end
-- Shots that tumble as they fly.
-- Shots that point the way they fly.
local AIM = { bullet = true, knife = true }
local SPIN = { die1 = 9, die2 = 9, die3 = 9, die4 = 9, die5 = 9, die6 = 9, tcoin = 12, tower = 5, horseshoe = 14, chip = 10, rball = 8 }

-- Everything this file draws that isn't named in the content tables (the tests check the files exist).
UI.SPRITES = { "disc", "circle", "square", "ring_thin", "glow", "shadow", "puff", "spark", "arrow_w", "vignette", "wall_h", "wall_v", "wall_corner",
    "torch", "vignette_w", "ui_bar", "ui_barfill", "ui_xp", "ui_plate", "ui_button", "ui_panel", "ui_card", "ui_cardglow", "eshot", "chip", "heart", "cardface",
    "flip_h", "flip_t", "chest", "crate", "star", "gun_f", "flame" }
for _, n in pairs(ANIM) do UI.SPRITES[#UI.SPRITES + 1] = n end

local SUIT_ICON = { S = "suit_s", H = "suit_h", D = "suit_d", C = "suit_c", J = "suit_j" }
local function SuitText(s, size) return s and SUIT_ICON[s] and Icon(SUIT_ICON[s], size or 14) or "" end

local function SetSprite(t, name)
    if t._name == name then return end
    t._name = name
    t:SetTexture(Tex(name))
end

--- A texture that repeats (the floor, the wall trim).
local function SetTiled(t, name)
    if t._name == name then return end
    t._name = name
    if not pcall(t.SetTexture, t, Tex(name), "REPEAT", "REPEAT") then t:SetTexture(Tex(name)) end
end

---------------------------------------------------------------------------
-- Pools
---------------------------------------------------------------------------
local function Pool(parent, layer, n, sprite, blend)
    local p = { n = 0 }
    for i = 1, n do
        local t = parent:CreateTexture(nil, layer)
        if sprite then SetSprite(t, sprite) end
        if blend then pcall(t.SetBlendMode, t, blend) end
        t:Hide()
        p[i] = t
    end
    return p
end

--- Straight lines of any angle, for the lanes. Empty on a client without them (dots are drawn instead).
local function LinePool(parent, layer, n)
    local p = { n = 0 }
    local ok = pcall(function()
        for i = 1, n do
            local l = parent:CreateLine(nil, layer)
            l:SetColorTexture(1, 1, 1, 1)
            l:SetThickness(2)
            l:Hide()
            p[i] = l
        end
    end)
    if not ok then
        for i = #p, 1, -1 do pcall(p[i].Hide, p[i]) p[i] = nil end
    end
    return p
end

local function Take(p)
    if p.n >= #p then return nil end
    p.n = p.n + 1
    return p[p.n]
end

local function Finish(p)
    for i = p.n + 1, (p.last or #p) do p[i]:Hide() end
    p.last, p.n = p.n, 0
end

-- room position -> canvas pixels
local function PX(g, x) return (x - g.camX) * S + (ui.ox or 0) end
local function PY(g, y) return (y - g.camY) * S + (ui.oy or 0) end

--- Puts a texture at a room position (centre); w and h are in room units.
local function Place(t, g, x, y, w, h)
    t:ClearAllPoints()
    t:SetPoint("CENTER", ui.field, "BOTTOMLEFT", PX(g, x), PY(g, y))
    t:SetSize(w * S, (h or w) * S)
    t:Show()
end

local function Spin(t, rot)
    if rot then
        pcall(t.SetRotation, t, rot)
        t._rot = true
    elseif t._rot then
        pcall(t.SetRotation, t, 0)
        t._rot = nil
    end
end

local function OnScreen(g, x, y, m)
    m = m or 24
    return x > g.camX - m and x < g.camX + VW + m and y > g.camY - m and y < g.camY + VH + m
end

---------------------------------------------------------------------------
-- Drawing helpers
---------------------------------------------------------------------------
local RED = { 1, 0.13, 0.08 }

local function DrawCircle(g, x, y, r, cr, cg, cb, a, sprite)
    local t = Take(ui.zonePool)
    if not t then return end
    SetSprite(t, sprite or "circle")
    t:SetVertexColor(cr, cg, cb, a)
    Place(t, g, x, y, r * 2)
end

local function Line(g, x1, y1, x2, y2, thick, cr, cg, cb, a)
    local l = Take(ui.linePool)
    if not l then return false end
    l:SetStartPoint("BOTTOMLEFT", ui.field, PX(g, x1), PY(g, y1))
    l:SetEndPoint("BOTTOMLEFT", ui.field, PX(g, x2), PY(g, y2))
    l:SetThickness(thick)
    l:SetVertexColor(cr, cg, cb, a)
    l:Show()
    return true
end

local function DrawLane(g, z, cr, cg, cb, a)
    local dx, dy = z.x2 - z.x1, z.y2 - z.y1
    local len = sqrt(dx * dx + dy * dy)
    if len < 1 then return end
    if #ui.linePool - ui.linePool.n >= 3 then
        -- a band with a bright line down each side
        local nx, ny = -dy / len * z.w, dx / len * z.w
        Line(g, z.x1, z.y1, z.x2, z.y2, z.w * 2 * S, cr, cg, cb, a)
        local ea = min(1, a * 1.6 + 0.25)
        Line(g, z.x1 + nx, z.y1 + ny, z.x2 + nx, z.y2 + ny, 2, min(1, cr + 0.25), min(1, cg + 0.35), min(1, cb + 0.3), ea)
        Line(g, z.x1 - nx, z.y1 - ny, z.x2 - nx, z.y2 - ny, 2, min(1, cr + 0.25), min(1, cg + 0.35), min(1, cb + 0.3), ea)
        return
    end
    -- no lines on this client: a row of dots (they overlap, so each is fainter)
    local stepLen = max(8, z.w * 0.8)
    local n = min(60, floor(len / stepLen) + 1)
    for i = 0, n do
        local f = n > 0 and i / n or 0
        local x, y = z.x1 + dx * f, z.y1 + dy * f
        if OnScreen(g, x, y, 30) then DrawCircle(g, x, y, z.w, cr, cg, cb, a * 0.5) end
    end
end

local function DrawRect(g, x1, y1, x2, y2, cr, cg, cb, a)
    local t = Take(ui.zonePool)
    if not t then return end
    SetSprite(t, "square")
    t:SetVertexColor(cr, cg, cb, a)
    Place(t, g, (x1 + x2) / 2, (y1 + y2) / 2, x2 - x1, y2 - y1)
end

local function DrawShape(g, z, cr, cg, cb, a)
    local s = z.shape
    if s == "circle" then DrawCircle(g, z.x, z.y, z.r, cr, cg, cb, a)
    elseif s == "ring" then
        DrawCircle(g, z.x, z.y, z.r2, cr, cg, cb, a)
        DrawCircle(g, z.x, z.y, z.r1, 0.04, 0.08, 0.05, 0.8)
        DrawCircle(g, z.x, z.y, z.r2, min(1, cr + 0.2), min(1, cg + 0.3), min(1, cb + 0.25), 0.9, "ring_thin")
        DrawCircle(g, z.x, z.y, z.r1, min(1, cr + 0.2), min(1, cg + 0.3), min(1, cb + 0.25), 0.9, "ring_thin")
    elseif s == "lane" then DrawLane(g, z, cr, cg, cb, a)
    elseif s == "rect" then DrawRect(g, z.x1, z.y1, z.x2, z.y2, cr, cg, cb, a)
    elseif s == "circles" then
        for _, c in ipairs(z.list) do DrawCircle(g, c.x, c.y, c.r, cr, cg, cb, a) end
    end
end

--- A danger circle: a dim disc, a brighter one that grows to fill it as the hit gets close, and a hard edge.
local function DangerCircle(g, x, y, r, f, a)
    DrawCircle(g, x, y, r, RED[1], RED[2], RED[3], a * 0.75, "disc")
    if f > 0.03 then DrawCircle(g, x, y, r * f, 1, 0.3, 0.18, min(1, a + 0.15), "disc") end
    DrawCircle(g, x, y, r, 1, 0.5, 0.38, 1, "ring_thin")
end

--- A soft light, drawn additively: under pickups worth walking to, elites, the boss, torches.
local function Glow(g, x, y, size, cr, cg, cb, a)
    local t = Take(ui.glowPool)
    if not t then return end
    t:SetVertexColor(cr, cg, cb, a)
    Place(t, g, x, y, size)
end

local function Shadow(g, x, y, size)
    local t = Take(ui.shadowPool)
    if not t then return end
    Place(t, g, x, y - size * 0.4, size * 0.95, size * 0.42)
end

local function DrawZones(g)
    local now = g.clock
    for _, z in ipairs(g.zones) do
        if z.side == "e" then
            local a, f = 0.5, 1
            if z.warn > 0 then
                -- fills in as it gets closer, with a quick pulse
                f = 1 - z.warn / max(0.01, z.total or 1)
                a = 0.2 + 0.32 * f + 0.06 * sin(now * 14)
            else
                a = z.spent and 0.8 * max(0, z.dur / 0.25) or 0.55
            end
            if z.invert then
                -- danger everywhere: the whole view goes red and the safe shape shows green
                DrawRect(g, g.camX, g.camY, g.camX + VW, g.camY + VH, RED[1], RED[2], RED[3], a * 0.8)
                if z.shape == "ring" then
                    DrawCircle(g, z.x, z.y, z.r2, 0.2, 0.9, 0.3, 0.55)
                    DrawCircle(g, z.x, z.y, z.r1, RED[1], RED[2], RED[3], 0.6)
                    DrawCircle(g, z.x, z.y, z.r2, 0.5, 1, 0.6, 1, "ring_thin")
                else
                    DrawShape(g, z, 0.2, 0.9, 0.3, 0.55)
                    if z.shape == "circle" then DrawCircle(g, z.x, z.y, z.r, 0.5, 1, 0.6, 1, "ring_thin")
                    elseif z.shape == "circles" then
                        for _, c in ipairs(z.list) do DrawCircle(g, c.x, c.y, c.r, 0.5, 1, 0.6, 1, "ring_thin") end
                    end
                end
            elseif z.shape == "circle" then
                DangerCircle(g, z.x, z.y, z.r, f, a)
            elseif z.shape == "circles" then
                for _, c in ipairs(z.list) do DangerCircle(g, c.x, c.y, c.r, f, a) end
            else
                DrawShape(g, z, RED[1], RED[2], RED[3], a)
            end
        elseif z.side == "fx" then
            local k = max(0, min(1, 1 - z.dur / 0.22)) -- 0 at the start, 1 at the end
            if z.shape == "circle" then
                -- a burst: grows out and fades
                DrawCircle(g, z.x, z.y, z.r * (0.5 + 0.5 * k), 1, 0.85, 0.45, 0.5 * (1 - k), "disc")
                DrawCircle(g, z.x, z.y, z.r * (0.55 + 0.45 * k), 1, 0.95, 0.7, 0.9 * (1 - k), "ring_thin")
                Glow(g, z.x, z.y, z.r * 2.6, 1, 0.75, 0.3, 0.45 * (1 - k))
            else
                DrawShape(g, z, 1, 0.9, 0.5, 0.5 * (1 - k))
            end
        elseif z.side == "p" then
            if z.sprite then
                local t = Take(ui.shotPool)
                if t then
                    SetSprite(t, z.sprite)
                    t:SetVertexColor(1, 1, 1, 1)
                    t:SetTexCoord(0, 1, 0, 1)
                    Spin(t, nil)
                    Place(t, g, z.x, z.y, 26)
                end
            elseif z.fire then
                -- a fire of yours: flames, not a filled disc (red discs are the ones to stay out of)
                local fade = min(1, z.dur / 0.5)
                DrawCircle(g, z.x, z.y, z.r, 1, 0.75, 0.25, 0.4 * fade, "ring_thin")
                Glow(g, z.x, z.y, z.r * 2.4, 1, 0.5, 0.1, 0.3 * fade)
                for k = 0, 4 do
                    local t = Take(ui.shotPool)
                    if not t then break end
                    local a = k * 2.513 + z.x * 0.01
                    local d = k == 0 and 0 or z.r * 0.55
                    SetSprite(t, "flame")
                    t:SetVertexColor(1, 1, 1, fade)
                    if (floor(g.clock * 7 + k) % 2) == 0 then t:SetTexCoord(0, 1, 0, 1) else t:SetTexCoord(1, 0, 0, 1) end
                    Spin(t, nil)
                    local size = z.r * (0.62 + 0.08 * sin(g.clock * 9 + k * 1.7))
                    Place(t, g, z.x + cos(a) * d, z.y + sin(a) * d + size * 0.18, size)
                end
            elseif z.r > 0 then
                DrawCircle(g, z.x, z.y, z.r, 0.5, 0.75, 1, 0.2, "disc")
                DrawCircle(g, z.x, z.y, z.r, 0.6, 0.85, 1, 0.5, "ring_thin")
            end
        elseif z.side == "deco" then
            if z.tint == "hit" then DrawShape(g, z, 0.2, 0.8, 0.3, 0.06)
            elseif z.tint == "stand" then DrawShape(g, z, 0.3, 0.5, 1, 0.08)
            elseif z.tint == "safe" then DrawShape(g, z, 0.2, 1, 0.3, 0.5)
            elseif z.tint == "line" then DrawShape(g, z, 0.95, 0.78, 0.35, 0.8)
            elseif z.tint == "table" then
                local t = g.table
                local f = t and min(1, t.have / t.need) or 0
                DrawCircle(g, z.x, z.y, z.r, 0.2, 0.9, 0.3, 0.16 + 0.06 * sin(now * 5), "disc")
                DrawCircle(g, z.x, z.y, z.r * f, 0.3, 1, 0.4, 0.4, "disc")
                DrawCircle(g, z.x, z.y, z.r, 0.4, 1, 0.5, 0.9, "ring_thin")
            else
                DrawShape(g, z, 0.4, 0.7, 1, 0.16)
                if z.shape == "circle" then DrawCircle(g, z.x, z.y, z.r, 0.5, 0.8, 1, 0.8, "ring_thin") end
            end
        end
    end
    if g.auraR and HR.FindWeapon(g, "edge") then
        DrawCircle(g, g.pl.x, g.pl.y, g.auraR, 1, 0.4, 0.5, 0.1 + 0.03 * sin(now * 4), "disc")
        DrawCircle(g, g.pl.x, g.pl.y, g.auraR, 1, 0.55, 0.65, 0.45, "ring_thin")
    end
end

--- The room's walls: carved trim with a gold edge wherever a wall is in view, dark beyond it,
--- torches along the top wall, and their light on the floor.
local function DrawWalls(g)
    local b, w = g.bounds, ui.walls
    local ox, oy = ui.ox or 0, ui.oy or 0
    local now = g.clock
    local u0 = ((g.camX * S) % 256) / 256
    local v0 = ((-g.camY * S) % 256) / 256
    local top = (b[4] - WALL - g.camY) * S     -- the trim's inner edges, in canvas pixels
    local bottom = (b[2] + WALL - g.camY) * S
    local left = (b[1] + WALL - g.camX) * S
    local right = (b[3] - WALL - g.camX) * S
    local seeTop, seeBottom, seeLeft, seeRight = top < CH + 8, bottom > -8, left > -8, right < CW + 8
    local function hband(t, fill, on, y, flip)
        t:SetShown(on)
        fill:SetShown(on)
        if not on then return end
        t:ClearAllPoints()
        fill:ClearAllPoints()
        if flip then
            t:SetPoint("TOPLEFT", ui.field, "BOTTOMLEFT", -8 + ox, y + oy)
            t:SetTexCoord(u0, u0 + (CW + 16) / 256, 1, 0)
            fill:SetPoint("TOPLEFT", ui.field, "BOTTOMLEFT", -8, y - TRIM + 1 + oy)
        else
            t:SetPoint("BOTTOMLEFT", ui.field, "BOTTOMLEFT", -8 + ox, y + oy)
            t:SetTexCoord(u0, u0 + (CW + 16) / 256, 0, 1)
            fill:SetPoint("BOTTOMLEFT", ui.field, "BOTTOMLEFT", -8, y + TRIM - 1 + oy)
        end
    end
    local function vband(t, fill, on, x, flip)
        t:SetShown(on)
        fill:SetShown(on)
        if not on then return end
        t:ClearAllPoints()
        fill:ClearAllPoints()
        if flip then
            t:SetPoint("BOTTOMLEFT", ui.field, "BOTTOMLEFT", x + ox, -8 + oy)
            t:SetTexCoord(1, 0, v0, v0 + (CH + 16) / 256)
            fill:SetPoint("BOTTOMLEFT", ui.field, "BOTTOMLEFT", x + TRIM - 1 + ox, -8)
        else
            t:SetPoint("BOTTOMRIGHT", ui.field, "BOTTOMLEFT", x + ox, -8 + oy)
            t:SetTexCoord(0, 1, v0, v0 + (CH + 16) / 256)
            fill:SetPoint("BOTTOMRIGHT", ui.field, "BOTTOMLEFT", x - TRIM + 1 + ox, -8)
        end
    end
    hband(w.top, w.topFill, seeTop, top, false)
    hband(w.bottom, w.bottomFill, seeBottom, bottom, true)
    vband(w.left, w.leftFill, seeLeft, left, false)
    vband(w.right, w.rightFill, seeRight, right, true)
    -- corner pieces where two walls meet
    local function corner(t, on, x, y, fx, fy)
        t:SetShown(on)
        if not on then return end
        t:ClearAllPoints()
        t:SetPoint("CENTER", ui.field, "BOTTOMLEFT", x + ox, y + oy)
        t:SetTexCoord(fx and 1 or 0, fx and 0 or 1, fy and 1 or 0, fy and 0 or 1)
    end
    local h = TRIM / 2
    corner(w.corners[1], seeTop and seeLeft, left - h, top + h, false, false)
    corner(w.corners[2], seeTop and seeRight, right + h, top + h, true, false)
    corner(w.corners[3], seeBottom and seeLeft, left - h, bottom - h, false, true)
    corner(w.corners[4], seeBottom and seeRight, right + h, bottom - h, true, true)
    -- torches every 300 units along the top wall, each lighting the floor under it
    local n = 0
    for x = b[1] + 150, b[3] - 100, 300 do
        if x > g.camX - 120 and x < g.camX + VW + 120 then
            local flick = 0.5 + 0.5 * sin(now * 11 + x) * sin(now * 7.3 + x * 0.5)
            Glow(g, x, b[4] - 36, 250 + 14 * flick, 1, 0.62, 0.25, 0.17 + 0.05 * flick)
            if seeTop and n < #w.torches then
                n = n + 1
                local t = w.torches[n]
                t:ClearAllPoints()
                t:SetPoint("CENTER", ui.field, "BOTTOMLEFT", PX(g, x), top + 14 + oy)
                t:Show()
            end
        end
    end
    for i = n + 1, #w.torches do w.torches[i]:Hide() end
end

local TRAIT_TINT = { shielded = { 0.7, 0.8, 1 }, splitting = { 0.8, 1, 0.7 }, lucky = { 0.6, 1, 0.6 }, magnetic = { 1, 0.9, 0.5 } }

--- The second walking frame every third of a second, each creature out of step with the next.
local function Frame(name, now, phase)
    local two = ANIM[name]
    if two and floor(now * 5 + phase) % 2 == 1 then return two end
    return name
end

local function DrawEnemies(g)
    local bars, small = 0, 0
    local now = g.clock
    for _, e in ipairs(g.enemies) do
        if not e.dead and OnScreen(g, e.x, e.y, e.size) then
            local t = Take(ui.enemyPool)
            if not t then break end
            local phase = (e.maxhp or 0) * 0.37 + (e.t or 0) * 0
            local still = e.obj or (e.stun or 0) > 0
            SetSprite(t, still and e.sprite or Frame(e.sprite, now, phase))
            local r, gg, b, a = 1, 1, 1, 1
            if e.suit then
                -- (half-strength: the painted sprite keeps its shading under the suit's colour)
                local c = HR.SUIT_TINT[e.suit]
                r, gg, b = 0.5 + 0.5 * c[1], 0.5 + 0.5 * c[2], 0.5 + 0.5 * c[3]
            elseif e.elite and e.trait then
                local c = TRAIT_TINT[e.trait] or TRAIT_TINT.magnetic
                r, gg, b = c[1], c[2], c[3]
            end
            if (e.jinx or 0) > 0 then r, gg, b = r * 0.75, gg * 0.55, b end
            if e.dots then gg, b = gg * 0.55, b * 0.55 end -- (bleeding or burning: reddened)
            if (e.stun or 0) > 0 and not e.boss then r, gg, b = r * 0.6, gg * 0.6, b * 0.75 end
            if e.ally then r, gg, b = 0.5, 1, 0.5 end
            if e.down then a = 0.35 elseif e.immune and e.boss then a = 0.85 end
            if e.spinning then a = 0.7 + 0.3 * sin(now * 30) end
            t:SetVertexColor(r, gg, b, a)
            Spin(t, e.rot)
            local flip = e.x > g.pl.x and not e.obj
            if flip then t:SetTexCoord(1, 0, 0, 1) else t:SetTexCoord(0, 1, 0, 1) end
            -- a little bounce as they walk, each out of step with the next; a pop when hit;
            -- bosses breathe
            local size = e.size * (e.boss and 1.5 or (e.obj and 1.15 or 1.3))
            local w, hgt, lift = size, size, 0
            if e.boss then
                local br = sin(now * 2.2)
                w, hgt = w * (1 - 0.012 * br), hgt * (1 + 0.02 * br)
            elseif not still then
                local bob = sin(now * 10 + phase)
                w, hgt = w * (1 - 0.03 * bob), hgt * (1 + 0.05 * bob)
                lift = max(0, bob) * 1.2
            end
            local hit = e.flashAt and (now - e.flashAt) < 0.1
            if hit then w, hgt = w * 1.14, hgt * 1.14 end
            Place(t, g, e.x, e.y + lift, w, hgt)
            if e.obj ~= "wheel" then Shadow(g, e.x, e.y, size) end
            if hit then Glow(g, e.x, e.y, size * 1.6, 1, 1, 0.8, 0.55) end
            if e.boss and not e.down then
                Glow(g, e.x, e.y, size * 2.2, 1, 0.25, 0.15, 0.3 + 0.08 * sin(now * 3))
            elseif e.elite then
                Glow(g, e.x, e.y, size * 2, 0.8, 0.5, 1, 0.45)
            elseif e.special then
                Glow(g, e.x, e.y, size * 2.2, 1, 0.85, 0.2, 0.5 + 0.15 * sin(now * 8))
            end
            if e.boss and bars < 2 then
                bars = bars + 1
                local bar = ui.bossBars[bars]
                local frac = max(0, min(1, e.hp / e.maxhp))
                bar.fill:SetWidth(max(1, BOSS_W * (e.down and 0 or frac)))
                bar.fill:SetVertexColor(e.immune and 0.55 or 0.92, e.immune and 0.55 or 0.16, e.immune and 0.6 or 0.14, 1)
                bar:Show()
            elseif (e.elite or e.obj == "pillar") and small < #ui.smallBars and e.hp < e.maxhp then
                -- elites and pillars: a small bar over their heads once they're hurt
                small = small + 1
                local bar = ui.smallBars[small]
                bar.fill:SetWidth(max(1, 40 * max(0, min(1, e.hp / e.maxhp))))
                bar:ClearAllPoints()
                bar:SetPoint("CENTER", ui.field, "BOTTOMLEFT", PX(g, e.x), PY(g, e.y + size * 0.6 + 4))
                bar:Show()
            end
        end
    end
    ui.bosses = bars
    for i = bars + 1, 2 do ui.bossBars[i]:Hide() end
    for i = small + 1, #ui.smallBars do ui.smallBars[i]:Hide() end
end

local function DrawShots(g)
    local now = g.clock
    for i, s in ipairs(g.shots) do
        local t = Take(ui.shotPool)
        if not t then break end
        local name = s.sprite or "bolt"
        local size = (s.size or 16) * 1.25
        SetSprite(t, name)
        t:SetVertexColor(1, 1, 1, 1)
        local spin = SPIN[name]
        if spin then
            t:SetTexCoord(0, 1, 0, 1)
            Spin(t, now * spin + i)
        elseif AIM[name] then
            t:SetTexCoord(0, 1, 0, 1)
            Spin(t, math.atan2(s.vy or 0, s.vx or 1))
        else
            Spin(t, nil)
            if s.flip or (s.vx or 0) < 0 then t:SetTexCoord(1, 0, 0, 1) else t:SetTexCoord(0, 1, 0, 1) end
        end
        Place(t, g, s.x, s.y, size)
        -- two fading copies behind it
        local vx, vy = s.vx or 0, s.vy or 0
        if vx * vx + vy * vy > 3600 then
            for k = 1, 2 do
                local tr = Take(ui.trailPool)
                if not tr then break end
                SetSprite(tr, name)
                tr:SetVertexColor(1, 0.95, 0.8, 0.34 / k)
                if spin then
                    tr:SetTexCoord(0, 1, 0, 1)
                    Spin(tr, now * spin + i - k * 0.5)
                elseif AIM[name] then
                    tr:SetTexCoord(0, 1, 0, 1)
                    Spin(tr, math.atan2(vy, vx))
                else
                    Spin(tr, nil)
                    if s.flip or vx < 0 then tr:SetTexCoord(1, 0, 0, 1) else tr:SetTexCoord(0, 1, 0, 1) end
                end
                Place(tr, g, s.x - vx * 0.035 * k, s.y - vy * 0.035 * k, size * (1 - 0.12 * k))
            end
        end
    end
    for _, s in ipairs(g.eshots) do
        local t = Take(ui.shotPool)
        if not t then break end
        SetSprite(t, "eshot")
        t:SetVertexColor(1, 1, 1, 1)
        t:SetTexCoord(0, 1, 0, 1)
        Spin(t, nil)
        Place(t, g, s.x, s.y, 17 + sin(now * 18) * 1.2)
        Glow(g, s.x, s.y, 34, 1, 0.2, 0.1, 0.55)
    end
    -- orbiters, the pig, held dice
    local sprites = { ball8 = "ball8", clover = "leaf", tails = "tcoin" }
    for key, o in pairs(g.orbit or {}) do
        for i = 1, (o.n or 0) do
            local p = o.pos[i]
            local t = p and Take(ui.shotPool)
            if t then
                SetSprite(t, sprites[key] or "bolt")
                t:SetVertexColor(1, 1, 1, 1)
                t:SetTexCoord(0, 1, 0, 1)
                Spin(t, nil)
                Place(t, g, p.x, p.y, 20)
            end
        end
    end
    if g.pig and HR.FindWeapon(g, "piggy") then
        local t = Take(ui.shotPool)
        if t then
            SetSprite(t, Frame("pig", now, 0))
            t:SetVertexColor(1, 1, 1, 1)
            Spin(t, nil)
            if g.pig.x > g.pl.x then t:SetTexCoord(1, 0, 0, 1) else t:SetTexCoord(0, 1, 0, 1) end
            Place(t, g, g.pig.x, g.pig.y, 26)
            Shadow(g, g.pig.x, g.pig.y, 26)
        end
    end
    for i, f in ipairs(g.heldDice or {}) do
        local t = Take(ui.shotPool)
        if t then
            SetSprite(t, "die" .. f)
            t:SetVertexColor(1, 1, 1, 0.95)
            t:SetTexCoord(0, 1, 0, 1)
            Spin(t, nil)
            Place(t, g, g.pl.x + (i == 1 and -10 or 10), g.pl.y + 27 + sin(now * 4 + i) * 1.5, 13)
        end
    end
end

local function DrawPickups(g)
    local cards = 0
    local now = g.clock
    for _, p in ipairs(g.pickups) do
        if OnScreen(g, p.x, p.y) then
            local t = Take(ui.pickPool)
            if not t then break end
            local size, a, lift = 12, 1, 0
            local kind = p.kind
            if kind == "die" then
                SetSprite(t, "die" .. p.face)
                size = 18 + sin(now * 6) * 1.5
                if p.face == 6 then Glow(g, p.x, p.y, 36, 1, 0.8, 0.2, 0.55) end
            elseif kind == "card" then
                SetSprite(t, "cardface")
                size = 22
                if p.glow then Glow(g, p.x, p.y, 42, 1, 0.9, 0.3, 0.6) end
            elseif kind == "flip" then
                SetSprite(t, (floor(now * 4) % 2 == 0) and "flip_h" or "flip_t")
                size = 20 + sin(now * 6) * 2
                Glow(g, p.x, p.y, 40, 1, 0.85, 0.2, 0.45)
            elseif kind == "power" then
                local def = HR.POWER[p.id]
                SetSprite(t, def.sprite)
                size = 25 + sin(now * 5) * 2
                lift = 2 + sin(now * 3) * 2
                if def.legendary then Glow(g, p.x, p.y, 58, 1, 0.55, 0.05, 0.75)
                else Glow(g, p.x, p.y, 50, 0.4, 0.85, 1, 0.6) end
            elseif kind == "crate" then
                SetSprite(t, "crate")
                size = 32 + sin(now * 4) * 1.5
                Glow(g, p.x, p.y, 70, 1, 0.7, 0.25, 0.65 + 0.15 * sin(now * 6))
            elseif kind == "chest" then
                SetSprite(t, "chest")
                size = 30 + sin(now * 4) * 1.5
                Glow(g, p.x, p.y, 64, 1, 0.8, 0.2, 0.6 + 0.15 * sin(now * 6))
            elseif kind == "heart" then
                SetSprite(t, "heart")
                size = 16 + sin(now * 5) * 1
            else
                SetSprite(t, "chip")
                size = (p.v or 1) >= 8 and 17 or 13
            end
            -- about to vanish: blink
            if p.life and p.life - p.age < 2 and floor(now * 8) % 2 == 0 then a = 0.35 end
            t:SetVertexColor(1, 1, 1, a)
            Place(t, g, p.x, p.y + lift, size)
            if kind == "card" and cards < #ui.cardText then
                cards = cards + 1
                local fs = ui.cardText[cards]
                local c = p.card
                fs:SetText(c.joker and "|cffe080ff*|r" or ("|c%s%s|r"):format(HR.SUIT_COLOR[c.s], HR.CardText(c)) .. SuitText(c.s))
                fs:ClearAllPoints()
                fs:SetPoint("CENTER", ui.field, "BOTTOMLEFT", PX(g, p.x), PY(g, p.y + 17))
                fs:Show()
            end
        end
    end
    for i = cards + 1, #ui.cardText do ui.cardText[i]:Hide() end
end

local function DrawFx(g)
    for _, f in ipairs(g.fx or {}) do
        local t = Take(ui.fxPool)
        if not t then break end
        local k = 1 - f.life / f.total -- 0 at the start, 1 at the end
        if f.kind == "puff" then
            SetSprite(t, "puff")
            t:SetVertexColor(1, 1, 1, 0.8 * (1 - k))
            Place(t, g, f.x, f.y + k * 8, (f.size or 22) * (0.7 + 0.8 * k))
        elseif f.kind == "spark" then
            SetSprite(t, "spark")
            t:SetVertexColor(1, 0.9, 0.4, 1 - k)
            Place(t, g, f.x, f.y + k * 10, 16 + 14 * k)
            Glow(g, f.x, f.y, 30, 1, 0.8, 0.3, 0.5 * (1 - k))
        else
            SetSprite(t, "ring_thin")
            t:SetVertexColor(1, 0.9, 0.5, 0.9 * (1 - k))
            Place(t, g, f.x, f.y, (f.r or 30) * 2 * (0.3 + 0.7 * k))
        end
    end
end

--- Arrows at the edge of the view toward things worth walking to.
local function DrawArrows(g)
    local n = 0
    local cx, cy = g.camX + VW / 2, g.camY + VH / 2
    local function point(x, y, r, gg, b)
        if n >= #ui.arrows or OnScreen(g, x, y, -6) then return end
        n = n + 1
        local t = ui.arrows[n]
        local a = atan2(y - cy, x - cx)
        local ex = max(g.camX + 22, min(g.camX + VW - 22, x))
        local ey = max(g.camY + 50, min(g.camY + VH - 30, y))
        t:SetVertexColor(r, gg, b, 0.75 + 0.25 * sin(g.clock * 8))
        pcall(t.SetRotation, t, a)
        t:ClearAllPoints()
        t:SetPoint("CENTER", ui.field, "BOTTOMLEFT", PX(g, ex), PY(g, ey))
        t:Show()
    end
    for _, p in ipairs(g.pickups) do
        if p.kind == "chest" or p.kind == "crate" then point(p.x, p.y, 1, 0.85, 0.2)
        elseif p.kind == "power" then point(p.x, p.y, 0.4, 0.9, 1) end
    end
    if g.table then point(g.table.x, g.table.y, 0.3, 1, 0.4) end
    for _, e in ipairs(g.enemies) do
        if e.special and not e.dead then point(e.x, e.y, 1, 0.85, 0.2) end
    end
    for i = n + 1, #ui.arrows do ui.arrows[i]:Hide() end
end

local function DrawTexts(g)
    local showNumbers = HR.DB().opts.numbers ~= false
    local n = 0
    for _, t in ipairs(g.texts) do
        if n >= #ui.texts then break end
        if showNumbers or not tonumber(t.text) then
            n = n + 1
            local fs = ui.texts[n]
            fs:SetText(("|c%s%s|r"):format(t.color, t.text))
            fs:ClearAllPoints()
            fs:SetPoint("CENTER", ui.field, "BOTTOMLEFT", PX(g, t.x), PY(g, t.y))
            fs:SetAlpha(min(1, t.life * 2.5))
            -- numbers pop: big for an instant, then settle
            if ui.textScale ~= false then
                local age = 0.9 - t.life
                local k = 1 + 0.6 * max(0, 1 - age / 0.14)
                ui.textScale = pcall(function() fs:SetTextScale(k) end)
            end
            fs:Show()
        end
    end
    for i = n + 1, #ui.texts do ui.texts[i]:Hide() end
    for i, fs in ipairs(ui.labels) do
        local l = g.labels[i]
        if l then
            fs:SetText(l.text)
            fs:ClearAllPoints()
            fs:SetPoint("CENTER", ui.field, "BOTTOMLEFT", PX(g, l.x), PY(g, l.y))
            fs:Show()
        else
            fs:Hide()
        end
    end
end

local function Clock(t) return ("%d:%02d"):format(floor(t / 60), floor(t % 60)) end

local function HandLine(g)
    local parts = {}
    if HR.FindWeapon(g, "bonedice") then
        local held = {}
        for _, f in ipairs(g.heldDice) do held[#held + 1] = Icon("die" .. f, 16) end
        parts[#parts + 1] = ("Held dice: %s   doubles |cffffd100%d%%|r%s"):format(#held > 0 and table.concat(held, " ") or "-",
            floor(HR.DoublesChance(g) * 100 + 0.5), (g.diceChain or 0) > 0 and ("   chain x" .. g.diceChain) or "")
    end
    if HR.FindWeapon(g, "flick") then
        local cards = {}
        for _, c in ipairs(g.hand) do
            cards[#cards + 1] = c.joker and "|cffe080ff*|r" or (("|c%s%s|r"):format(HR.SUIT_COLOR[c.s], HR.CardText(c)) .. SuitText(c.s))
        end
        parts[#parts + 1] = ("Hand: %s   |cffaaaaaa%s|r"):format(#cards > 0 and table.concat(cards, " ") or "-", HR.HandText(g.hand))
    end
    local c = g.coin
    if c and HR.FindWeapon(g, "trickcoin") then
        parts[#parts + 1] = ("%s  %s   streak |cffffd100%d|r   coin %d%% your way"):format(Icon(c.side == "H" and "flip_h" or "flip_t", 16),
            c.side == "H" and "|cffffd100HEADS|r (damage)" or "|cff80c0ffTAILS|r (defense)", c.streak, floor(HR.FlipOdds(g) * 100 + 0.5))
    end
    return table.concat(parts, "      ")
end

local function DrawHud(g)
    local pl, st = g.pl, g.st
    local boss = (ui.bosses or 0) > 0
    local heat = HR.Feature("heat") and ("   Heat |cffff8040%d|r"):format(g.heat) or ""
    if boss then
        -- (the boss's bar takes the middle of the top edge)
        ui.line1:SetText(("%s |cffffd100%d|r"):format(Icon("chip", 18), floor(g.chips)))
        ui.line2:SetText("")
        ui.plate1:SetWidth(112)
        ui.plate2:Hide()
        ui.bossName:SetText("|cffffffff" .. (g.bossName or "") .. "|r")
    else
        ui.line1:SetText(("%s |cffffd100%d|r    Luck |cff80ff80%d|r%s    Lv |cffd0a0ff%d|r"):format(Icon("chip", 18), floor(g.chips), floor(g.luckNow or 0), heat, g.level))
        local where = HR.ROOMS[g.roomIdx].name
        if g.phase == "waves" then where = where .. "   |cffffd100" .. Clock(max(0, HR.WAVE_TIME - g.roomTime)) .. "|r" end
        ui.line2:SetText(where)
        ui.plate1:SetWidth(HR.Feature("heat") and 330 or 262)
        ui.plate2:Show()
    end
    local hpFrac = max(0, min(1, pl.hp / st.maxhp))
    ui.hpFill:SetWidth(max(1, HP_W * hpFrac))
    ui.hpFill:SetVertexColor(hpFrac < 0.3 and 0.95 or 0.2, hpFrac < 0.3 and 0.18 or 0.82, 0.2, 1)
    ui.shieldFill:SetWidth(max(1, HP_W * min(1, (pl.shield or 0) / st.maxhp)))
    ui.shieldFill:SetShown((pl.shield or 0) > 0)
    ui.hpText:SetText(("%d / %d"):format(max(0, floor(pl.hp + 0.5)), floor(st.maxhp)))
    ui.xpFill:SetWidth(max(1, XP_W * min(1, g.xp / HR.XpNeed(g.level))))
    -- weapons with their levels, then any power-ups still running
    local parts = {}
    for _, w in ipairs(g.weapons) do
        local def = HR.WEAPON[w.id]
        parts[#parts + 1] = Icon(def.icon, 18) .. (w.evo and "|cffffd100*|r" or ("|cffffffff" .. w.lvl .. "|r"))
    end
    ui.weapons:SetText(table.concat(parts, " "))
    -- on the right: power-ups still running, then the suits held, as counts (the set bonuses
    -- come from these)
    local suits = {}
    for id, till in pairs(g.powers or {}) do
        if till > g.time then suits[#suits + 1] = ("%s|cff80e0ff%ds|r "):format(Icon(HR.POWER[id].sprite, 18), ceil(till - g.time)) end
    end
    for _, s in ipairs(HR.SUITS) do
        local n = g.suits and g.suits.n[s] or 0
        if n > 0 then suits[#suits + 1] = SuitText(s, 18) .. ((g.suits[s] or 0) > 0 and "|cff20ff20" or "|cffcccccc") .. n .. "|r" end
    end
    local special = g.suits and ((g.suits.fullDeck and "Full Deck") or (g.suits.fullHouse and "Full House")) or nil
    ui.suits:SetText(table.concat(suits, " ") .. (special and ("  |cff20ff20" .. special .. "|r") or ""))
    ui.hand:SetText(HandLine(g))
    local info = g.bossText or (g.bet and ("Side bet: |cffffd100" .. HR.BET[g.bet.id].name .. "|r - " .. HR.BET[g.bet.id].desc)) or ""
    ui.info:SetText(info)
    ui.info:ClearAllPoints()
    -- (in a boss fight the top belongs to the boss, so what to do is written at the bottom)
    if boss then ui.info:SetPoint("BOTTOM", ui.hudFrame, "BOTTOM", 0, 78) else ui.info:SetPoint("TOP", ui.hudFrame, "TOP", 0, -42) end
    if g.banner and g.banner.till > g.clock then
        ui.banner:SetText(g.banner.text)
        ui.banner:SetAlpha(min(1, g.banner.till - g.clock))
        ui.banner:Show()
    else
        ui.banner:Hide()
    end
    if g.phase == "bossintro" then
        ui.title:SetText(("|cffffd100%s|r\n|cffffffff\"%s\"|r"):format(g.bossName or "", g.bossLine or ""))
        ui.title:Show()
        ui.titleShade:Show()
    else
        ui.title:Hide()
        ui.titleShade:Hide()
    end
end

local POOLS = { "zonePool", "linePool", "enemyPool", "trailPool", "shotPool", "pickPool", "glowPool", "shadowPool", "fxPool" }

local function PlaceFloor(name, camX, camY)
    SetTiled(ui.floor, name)
    ui.floor:ClearAllPoints()
    ui.floor:SetPoint("BOTTOMLEFT", ui.field, "BOTTOMLEFT", -((camX * S) % TILE) - TILE + (ui.ox or 0), -((camY * S) % TILE) - TILE + (ui.oy or 0))
end

function UI.Render()
    local g = ui.g
    if not ui.canvas then return end
    ui.hudFrame:SetShown(g ~= nil)
    ui.wallFrame:SetShown(g ~= nil)
    if not g then
        -- no run: the first room's floor, dimmed, behind the menu
        ui.ox, ui.oy = 0, 0
        PlaceFloor("floor_dice", 0, 0)
        for _, name in ipairs(POOLS) do Finish(ui[name]) end
        ui.player:Hide()
        ui.gun:Hide()
        ui.shield:Hide()
        ui.flash:Hide()
        ui.hurtEdge:Hide()
        ui.hurtFill:Hide()
        for _, t in ipairs(ui.arrows) do t:Hide() end
        for _, fs in ipairs(ui.texts) do fs:Hide() end
        for _, fs in ipairs(ui.cardText) do fs:Hide() end
        for _, fs in ipairs(ui.labels) do fs:Hide() end
        for _, b in ipairs(ui.smallBars) do b:Hide() end
        return
    end
    if not g.camX then HR.Camera(g) end
    -- a short shake when hit
    ui.ox, ui.oy = 0, 0
    if ui.shake > 0 then
        ui.ox, ui.oy = (math.random() - 0.5) * 8, (math.random() - 0.5) * 8
    end
    -- the floor scrolls with the view
    PlaceFloor(HR.ROOMS[g.roomIdx].floor, g.camX, g.camY)
    DrawZones(g)
    DrawWalls(g)
    DrawPickups(g)
    DrawEnemies(g)
    DrawShots(g)
    DrawFx(g)
    DrawArrows(g)
    -- the player
    local pl = g.pl
    local moving = (pl.vx or 0) ~= 0 or (pl.vy or 0) ~= 0
    local hero = HR.CLASS[g.class].sprite
    SetSprite(ui.player, moving and Frame(hero, g.clock * 1.6, 0) or hero)
    if pl.face < 0 then ui.player:SetTexCoord(1, 0, 0, 1) else ui.player:SetTexCoord(0, 1, 0, 1) end
    ui.player:SetAlpha((pl.iframes > 0 and floor(g.clock * 16) % 2 == 0) and 0.4 or 1)
    local bob = moving and sin(g.clock * 16) or sin(g.clock * 2.5) * 0.3
    local size = 30 * K
    Place(ui.player, g, pl.x, pl.y + (moving and max(0, bob) * 2 or 0), size * (1 - 0.03 * bob), size * (1 + 0.05 * bob))
    local alive = g.phase ~= "over" or (g.summary and g.summary.how ~= "dead")
    ui.player:SetShown(alive)
    -- the gun in his hand: it swings round him to point where it shoots
    local aim = alive and HR.FindWeapon(g, "revolver") and pl.aim
    if aim then
        local have = ui.gunAim or aim
        local d = (aim - have + math.pi) % (2 * math.pi) - math.pi
        have = have + d * 0.35
        ui.gunAim = have
        -- (two paintings, so the grip hangs down whichever way it points)
        SetSprite(ui.gun, cos(have) >= 0 and "revolver" or "gun_f")
        ui.gun:SetTexCoord(0, 1, 0, 1)
        Spin(ui.gun, have)
        ui.gun:SetAlpha(ui.player:GetAlpha())
        Place(ui.gun, g, pl.x + cos(have) * HR.GUN_HOLD, pl.y + sin(have) * HR.GUN_HOLD - 2, 17 * K)
    end
    ui.gun:SetShown(aim ~= nil and aim ~= false)
    if alive then
        Shadow(g, pl.x, pl.y, size)
        -- you carry a little light of your own
        Glow(g, pl.x, pl.y, 230, 1, 0.85, 0.6, 0.09)
        -- a speed or attack boost shows as a light around you
        local boots, hand = (g.powers.boots or 0) > g.time, (g.powers.hand or 0) > g.time
        if boots or hand then Glow(g, pl.x, pl.y, 70, hand and 1 or 0.4, hand and 0.5 or 0.9, hand and 0.2 or 1, 0.5 + 0.1 * sin(g.clock * 10)) end
    end
    if (pl.shield or 0) > 0 and alive then
        ui.shield:SetVertexColor(0.5, 0.8, 1, 0.85)
        Place(ui.shield, g, pl.x, pl.y, 50)
    else
        ui.shield:Hide()
    end
    for _, name in ipairs(POOLS) do Finish(ui[name]) end
    -- hit: red edges and a brief red wash; low on health: the edges pulse
    local hurt = max(0, min(1, (ui.hurt or 0) / 0.45))
    local low = (alive and pl.hp < g.st.maxhp * 0.3) and (0.3 + 0.2 * sin(g.clock * 6)) or 0
    local edge = max(hurt, low)
    ui.hurtEdge:SetShown(edge > 0.01)
    ui.hurtEdge:SetAlpha(min(1, edge))
    ui.hurtFill:SetShown(hurt > 0.5)
    ui.hurtFill:SetAlpha(max(0, hurt - 0.5) * 0.5)
    local k = 1 - 0.75 * hurt
    ui.player:SetVertexColor(1, k, k, 1)
    -- a flash for the big moments
    if (g.flash or 0) > 0 then
        ui.flash:SetAlpha(min(0.6, g.flash * 2))
        ui.flash:Show()
    else
        ui.flash:Hide()
    end
    DrawTexts(g)
    DrawHud(g)
end

---------------------------------------------------------------------------
-- Menus: one overlay draws whatever menu is up - a run's (g.menu) or the lobby's (ui.menu).
-- Level-up cards and relics are dealt as cards side by side; everything else is a list.
---------------------------------------------------------------------------
local MAX_OPTIONS, MAX_CARDS = 10, 4
local OPTION_GAP = 4
local ROW_W, CARD_W, CARD_H = 470, 176, 246
local CARD_KINDS = { level = true, relic = true }

local function CurrentMenu()
    local g = ui.g
    if g and g.menu then return g.menu, true end
    return ui.menu, false
end
UI.CurrentMenu = CurrentMenu

local function OptionHeight(opt) return opt.small and 37 or (opt.medium and 41 or 52) end

local function RarityColor(opt)
    local rar = opt.rar and HR.RARITY[opt.rar]
    if rar and opt.rar > 1 then
        return tonumber(rar.color:sub(3, 4), 16) / 255, tonumber(rar.color:sub(5, 6), 16) / 255, tonumber(rar.color:sub(7, 8), 16) / 255, rar.color
    elseif opt.cursed then
        return 0.75, 0.38, 1, "ffc060ff"
    end
    return nil, nil, nil, "ffffffff"
end

function UI.RefreshMenu()
    local o = ui.overlay
    if not o then return end
    local m = CurrentMenu()
    ui.dim:SetShown(m ~= nil)
    if not m then
        o:Hide()
        return
    end
    o.title:SetText("|cffffd100" .. (m.title or "") .. "|r")
    o.sub:SetText(m.sub or "")
    -- which options are dealt as cards
    local cards, rows = {}, {}
    for _, opt in ipairs(m.options) do
        if CARD_KINDS[m.kind] and not opt.small and tonumber(opt.key) and #cards < MAX_CARDS then cards[#cards + 1] = opt
        elseif #rows < MAX_OPTIONS then rows[#rows + 1] = opt end
    end
    local width = max(ROW_W + 40, #cards * (CARD_W + 10) + 34)
    o:SetWidth(width)
    o.sub:SetWidth(width - 48)
    -- the buttons always fit: the text above them gets whatever room is left
    local buttons = #cards > 0 and (CARD_H + 10) or 0
    for _, opt in ipairs(rows) do buttons = buttons + OptionHeight(opt) + OPTION_GAP end
    local textH = (m.subLines or ((m.sub and m.sub ~= "") and 1 or 0)) * 14
    local ok, real = pcall(function() return o.sub:GetStringHeight() end)
    if ok and type(real) == "number" and real > 0 then textH = real + 2 end
    local room = CH - 30 - 62 - buttons
    if textH > room then textH = max(0, room) end
    pcall(function() o.sub:SetHeight(max(1, textH)) end)
    local y = -(50 + textH + (textH > 0 and 8 or 0))
    for i = 1, MAX_CARDS do
        local c = o.cards[i]
        local opt = cards[i]
        if opt then
            local r, gg, b, hex = RarityColor(opt)
            c.key = opt.key
            c.icon:SetTexture(Tex(opt.icon or (m.kind == "relic" and "chest" or "star")))
            c.title:SetText(("|c%s%s|r"):format(hex, opt.title or ""))
            c.sub:SetText((opt.suit and (SuitText(opt.suit) .. " ") or "") .. "|cffbbbbbb" .. (opt.sub or "") .. "|r" .. (opt.link and "\n|cff40c0ffcombo|r" or ""))
            c.desc:SetText((opt.desc or "") .. (opt.hint and ("\n|cff999999" .. opt.hint .. "|r") or ""))
            c.keyText:SetText(("|cffffd100[ %s ]|r"):format(opt.key))
            if r then
                c.glow:SetVertexColor(r, gg, b, 0.9)
                c.glow:Show()
            else
                c.glow:Hide()
            end
            c:ClearAllPoints()
            c:SetPoint("TOPLEFT", o, "TOP", -(#cards * (CARD_W + 10) - 10) / 2 + (i - 1) * (CARD_W + 10), y)
            c:SetAlpha(opt.enabled == false and 0.45 or 1)
            c:Show()
        else
            c:Hide()
        end
    end
    if #cards > 0 then y = y - CARD_H - 10 end
    for i = 1, MAX_OPTIONS do
        local b = o.buttons[i]
        local opt = rows[i]
        if opt then
            local keyText = opt.key == "E" and "Enter" or opt.key
            local r, gg, bb, hex = RarityColor(opt)
            local head = ("|cffffd100[%s]|r  %s%s|c%s%s|r%s%s"):format(keyText, opt.suit and (SuitText(opt.suit) .. " ") or "",
                opt.icon and (Icon(opt.icon, opt.medium and 22 or 16) .. " ") or "", hex, opt.title or "",
                opt.selected and "  |cff20ff20(selected)|r" or "", opt.link and "  |cff40c0ff(combo)|r" or "")
            if opt.sub then head = head .. "   |cffaaaaaa" .. opt.sub .. "|r" end
            b.head:SetText(head)
            local desc = opt.desc or ""
            if opt.hint then desc = desc .. "  |cff888888" .. opt.hint .. "|r" end
            b.desc:SetText(desc)
            local hgt = OptionHeight(opt)
            b:SetHeight(hgt)
            b:ClearAllPoints()
            b:SetPoint("TOP", o, "TOP", 0, y)
            y = y - hgt - OPTION_GAP
            b.key = opt.key
            -- the edge light says how good it is, or that it's the one chosen
            if r then b.bg:SetVertexColor(0.6 + 0.4 * r, 0.6 + 0.4 * gg, 0.6 + 0.4 * bb, 1)
            elseif opt.selected then b.bg:SetVertexColor(0.7, 1, 0.7, 1)
            else b.bg:SetVertexColor(1, 1, 1, 1) end
            b:SetAlpha(opt.enabled == false and 0.45 or 1)
            b:Show()
        else
            b:Hide()
        end
    end
    o:SetHeight(-y + 14)
    o:Show()
end

--- Picks an option of the menu on screen by its key. Returns true if it did something.
function UI.Pick(key)
    local m, inRun = CurrentMenu()
    if not m then return false end
    local ok
    if inRun then
        ok = HR.Pick(ui.g, key)
    else
        for _, o in ipairs(m.options) do
            if o.key == key and o.enabled ~= false then
                o.pick()
                ok = true
                break
            end
        end
    end
    if ok then
        ns.Sound("card")
        UI.AfterChange()
    end
    return ok
end

---------------------------------------------------------------------------
-- The main menu: play, talents, mode, records
---------------------------------------------------------------------------
local function BestsLine(db)
    local key = db.mode .. ":" .. db.stakes
    local b = db.bests[key] and db.bests[key].all
    if not b or (b.runs or 0) == 0 then return "No runs yet." end
    return ("Best |cffffd100%d|r   furthest: room %d, %d boss%s%s"):format(b.score or 0, b.room or 1, b.bosses or 0, (b.bosses or 0) == 1 and "" or "es",
        b.fastest and ("   fastest win " .. Clock(b.fastest)) or "")
end

function UI.Lobby()
    local db = HR.DB()
    ui.g = nil
    if HR.Feature("rules") and not ui.rule then
        ui.rule, ui.redraws = HR.RULES[math.random(1, #HR.RULES)].id, 1
    end
    local rule = HR.RULE[ui.rule or "none"]
    local lines = { "|cffaaaaaaA casual arcade game. Chips are points - no gold, ever.|r", BestsLine(db) }
    if HR.Feature("rules") then lines[#lines + 1] = ("House Rule: |cffffd100%s|r - %s"):format(rule.name, rule.desc) end
    local m = { kind = "lobby", title = "High Roller", sub = table.concat(lines, "\n"), subLines = #lines, options = {} }
    local n = 0
    local function add(o)
        if not o.key then
            n = n + 1
            o.key = tostring(n)
        end
        m.options[#m.options + 1] = o
    end
    if db.save then
        add({ key = "E", title = "Continue your run", desc = ("Back at the start of room %d, as you entered it."):format(db.save.roomPos or 1), medium = true,
            pick = function() UI.StartRun(nil, true) end })
    else
        add({ key = "E", title = "Play", medium = true, icon = "hero",
            desc = "WASD or the arrow keys to move. Your gun fires on its own; pick up the rest.",
            pick = function() UI.StartRun() end })
    end
    local cdb = HR.ClassDB(HR.HERO)
    local free = HR.TalentPoints(HR.HERO) - HR.TalentsSpent(HR.HERO)
    add({ title = "Talents", small = true, pick = function() UI.ShowTalents(true) end,
        desc = ("Permanent upgrades. Level %d%s"):format(cdb.level, free > 0 and ("  |cff20ff20%d point%s to spend|r"):format(free, free == 1 and "" or "s") or "") })
    if db.save then
        add({ title = "New run", desc = "Abandons the saved run.", small = true, pick = function() UI.StartRun() end })
    end
    if HR.Feature("quick") then
        add({ title = "Mode: " .. (db.mode == "quick" and "Quick Hand (3 rooms)" or "Full Table (5 rooms)"), desc = "Change the length of a run.", small = true,
            pick = function() db.mode = db.mode == "quick" and "full" or "quick" UI.Lobby() end })
    end
    if HR.MaxStakes() > 0 then
        add({ title = "Stakes: " .. db.stakes, desc = db.stakes == 0 and "The normal game." or (db.stakes == 1 and "Elites from the first room." or "Elites, and bosses gain a third phase."),
            small = true, pick = function() db.stakes = (db.stakes + 1) % (HR.MaxStakes() + 1) UI.Lobby() end })
    end
    if HR.Feature("rules") and (ui.redraws or 0) > 0 then
        add({ title = "Redraw the House Rule", desc = "Once per run.", small = true, pick = function()
            ui.redraws = 0
            local old = ui.rule
            repeat ui.rule = HR.RULES[math.random(1, #HR.RULES)].id until ui.rule ~= old
            UI.Lobby()
        end })
    end
    add({ title = "Records", desc = "Your bests, achievements and builds. Only you see these.", small = true, pick = function() UI.Records() end })
    ui.menu = m
    UI.AfterChange()
end

function UI.Records()
    local db = HR.DB()
    local key = db.mode .. ":" .. db.stakes
    local lines = { ("|cffaaaaaa%s, Stakes %d  -  runs %d: won %d, walked away %d, died %d|r"):format(db.mode == "quick" and "Quick Hand" or "Full Table",
        db.stakes, db.stats.runs or 0, db.stats.won or 0, db.stats.walked or 0, db.stats.died or 0) }
    for _, who in ipairs({ "all", "dice", "cards", "coin" }) do
        local b = db.bests[key] and db.bests[key][who]
        if b and (b.runs or 0) > 0 and who == "all" then
            lines[#lines + 1] = ("|cffffd100%s|r  best %d, room %d, %d bosses%s%s"):format("Overall", b.score or 0,
                b.room or 1, b.bosses or 0, b.fastest and (", win in " .. Clock(b.fastest)) or "", (b.heat or 0) > 0 and (", Heat " .. b.heat) or "")
            if who == "all" then
                local extra = {}
                if b.bigHit then extra[#extra + 1] = "biggest hit " .. b.bigHit end
                if b.chain then extra[#extra + 1] = "doubles chain " .. b.chain end
                if b.hand then extra[#extra + 1] = "best hand " .. HR.HANDS[b.hand] end
                if b.streak then extra[#extra + 1] = "coin streak " .. b.streak end
                if #extra > 0 then lines[#lines + 1] = "   " .. table.concat(extra, ", ") end
                if b.build then lines[#lines + 1] = "   " .. table.concat(b.build.weapons or {}, ", ") end
            end
        end
    end
    local list, got = HR.OpenAchievements(), 0
    for _, a in ipairs(list) do if db.ach[a.id] then got = got + 1 end end
    lines[#lines + 1] = ("|cffffd100Achievements|r  %d of %d"):format(got, #list)
    local todo = {}
    for _, a in ipairs(list) do
        if not db.ach[a.id] and a.gives and #todo < 3 then todo[#todo + 1] = ("   %s - unlocks %s"):format(a.desc, a.gives) end
    end
    for _, t in ipairs(todo) do lines[#lines + 1] = t end
    local found = {}
    for name in pairs(db.journal) do found[#found + 1] = name end
    table.sort(found)
    lines[#lines + 1] = ("|cffffd100Builds found|r  %d of %d%s"):format(#found, #HR.BUILDS, #found > 0 and (": " .. table.concat(found, ", ")) or "")
    ui.menu = { kind = "records", title = "Records", sub = table.concat(lines, "\n"), subLines = #lines + 2, options = {
        { key = "E", title = "Main menu", medium = true, desc = "Back to the start.", pick = function() UI.Lobby() end } } }
    UI.AfterChange()
end

local function BuildText(g)
    local lines = {}
    for _, w in ipairs(g.weapons) do
        local def = HR.WEAPON[w.id]
        lines[#lines + 1] = ("%s |cffffffff%s|r %s"):format(SuitText(def.suit), w.evo and def.evo.name or def.name, w.evo and "(Cash Out)" or ("lv " .. w.lvl))
    end
    local charms = {}
    for _, def in ipairs(HR.CHARMS) do
        local n = g.charms[def.id] or 0
        if n > 0 then charms[#charms + 1] = ("%s x%d"):format(def.name, n) end
    end
    if #charms > 0 then lines[#lines + 1] = "|cffaaaaaaCharms:|r " .. table.concat(charms, ", ") end
    local relics = {}
    for _, def in ipairs(HR.RELICS) do
        if g.relics[def.id] then relics[#relics + 1] = (def.cursed and "|cffc060ff" or (def.legendary and "|cffff8a00" or "|cffffd100")) .. def.name .. "|r" end
    end
    if #relics > 0 then lines[#lines + 1] = "|cffaaaaaaRelics:|r " .. table.concat(relics, ", ") end
    return lines
end

function UI.Pause(why)
    local g = ui.g
    if not g or g.phase == "over" then return end
    -- (a card pick or the Cashier already holds the game still)
    if g.menu then return UI.AfterChange() end
    g.paused = true
    local lines = BuildText(g)
    table.insert(lines, 1, ("|cffaaaaaa%s  -  %s|r"):format(why or "Paused", g.suits and g.suits.name or ""))
    ui.menu = { kind = "pause", title = "Paused", sub = table.concat(lines, "\n"), subLines = #lines + 2, options = {
        { key = "E", title = "Carry on", medium = true, desc = "Or press P.", pick = function() UI.Resume() end },
        { key = "9", title = "Give up and go to the main menu", desc = "Ends this run with a score of 0. You keep the experience.", medium = true, pick = function()
            ui.menu = nil
            g.paused = nil
            HR.Die(g)
            UI.Lobby()
        end },
    } }
    UI.AfterChange()
end

function UI.Resume()
    local g = ui.g
    if not g then return end
    if InCombatLockdown and InCombatLockdown() then return end
    g.paused = nil
    if ui.menu and ui.menu.kind == "pause" then ui.menu = nil end
    UI.Keyboard(true)
    UI.AfterChange()
end

local HOW = { dead = "|cffff4040The House wins.|r", walk = "|cff20ff20You walked away.|r", win = "|cffffd100You broke the bank!|r" }

local function Summary(g)
    local s = g.summary
    local lines = {
        ("Score |cffffd100%d|r      room %d, %d boss%s      %s      level %d, %d kills"):format(s.score, s.room, s.bosses, s.bosses == 1 and "" or "es",
            Clock(s.time), s.level, s.kills),
        ("+%d experience%s"):format(s.xp, s.levels > 0 and ("  |cff20ff20+" .. s.levels .. " talent point" .. (s.levels == 1 and "" or "s") .. "!|r") or ""),
    }
    for i, n in ipairs(s.new) do
        if i <= 4 then lines[#lines + 1] = "|cff20ff20" .. n .. "|r" end
    end
    -- damage by weapon
    local list = {}
    for wid, d in pairs(s.damage) do list[#list + 1] = { wid = wid, d = d } end
    table.sort(list, function(a, b) return a.d > b.d end)
    local parts = {}
    for i = 1, min(4, #list) do
        local def = HR.WEAPON[list[i].wid]
        parts[#parts + 1] = ("%s %dk"):format(def and def.name or list[i].wid, floor(list[i].d / 1000 + 0.5))
    end
    if #parts > 0 then lines[#lines + 1] = "|cffaaaaaaDamage: " .. table.concat(parts, ", ") .. "|r" end
    lines[#lines + 1] = "|cffaaaaaa" .. s.build.hand .. "|r"
    ui.menu = { kind = "summary", title = HOW[s.how], sub = table.concat(lines, "\n"), subLines = #lines + 1, options = {
        { key = "E", title = "Play again", medium = true, desc = "A new run.", pick = function() UI.StartRun() end },
        { key = "0", title = "Main menu", medium = true, desc = "Talents and records.", pick = function() UI.Lobby() end },
    } }
    ui.rule, ui.redraws = nil, nil
end

--- Starts (or continues) a run with the main menu's choices.
function UI.StartRun(opts, continue)
    local db = HR.DB()
    local g
    if continue and db.save then g = HR.Restore(db.save) end
    if not g then
        opts = opts or {}
        opts.mode, opts.stakes = opts.mode or db.mode, opts.stakes or db.stakes
        opts.rule = opts.rule or ui.rule
        g = HR.NewRun(opts)
    end
    ui.g, ui.menu = g, nil
    ui.held = {}
    ui.rule, ui.redraws = nil, nil
    UI.ShowTalents(false)
    UI.Keyboard(true)
    UI.AfterChange()
    return g
end

--- After anything changed outside the normal frame loop: show the right menu and redraw.
function UI.AfterChange()
    local g = ui.g
    if g and g.phase == "over" and g.summary and not (ui.menu and ui.menu.kind == "summary") then Summary(g) end
    UI.RefreshMenu()
    UI.Render()
end

---------------------------------------------------------------------------
-- Talents
---------------------------------------------------------------------------
function UI.ShowTalents(show)
    local t = ui.talents
    if not t then return end
    if not show then
        t:Hide()
        return
    end
    local db = HR.DB()
    local id = db.class
    local trees = HR.TALENTS[id]
    local cdb = HR.ClassDB(id)
    local free = HR.TalentPoints(id) - HR.TalentsSpent(id)
    t.head:SetText(("|cffffd100Talents|r   level %d   |cff20ff20%d|r point%s to spend  (of %d earned; %d at most)"):format(
        cdb.level, free, free == 1 and "" or "s", HR.TalentPoints(id), HR.TALENT_CAP))
    for ti = 1, 3 do
        local tree = trees[ti]
        t.names[ti]:SetText(("|cffffd100%s|r  |cffaaaaaa%d|r"):format(tree.name, HR.TalentsSpent(id, ti)))
        t.tips[ti].name, t.tips[ti].tip = tree.name, tree.tip
        for ri = 1, 5 do
            local row = tree.rows[ri]
            local b = t.cells[ti][ri]
            local rank = cdb.talents[row.id] or 0
            local can = HR.CanLearn(id, row.id)
            local color = rank >= row.max and "|cffffd100" or (rank > 0 and "|cff20ff20" or (can and "|cffffffff" or "|cff777777"))
            b.text:SetText(("%s%s%s|r\n|cffaaaaaa%d / %d|r"):format(color, row.name and (row.name .. ": ") or "", row.desc, rank, row.max))
            b.talent = row.id
            b:SetAlpha((can or rank > 0) and 1 or 0.6)
        end
    end
    ui.overlay:Hide()
    ui.dim:Show()
    t:Show()
end

local function BuildTalents(canvas)
    local t = CreateFrame("Frame", nil, canvas)
    t:SetAllPoints()
    t:SetFrameLevel(canvas:GetFrameLevel() + 30)
    UI._Panel(t)
    t:EnableMouse(true)
    t.head = t:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    t.head:SetPoint("TOP", 0, -20)
    t.head:SetWidth(CW - 60)
    t.names, t.cells, t.tips = {}, {}, {}
    local cw, ch = 240, 84
    for ti = 1, 3 do
        local x = 28 + (ti - 1) * (cw + 12)
        t.names[ti] = t:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        t.names[ti]:SetPoint("TOPLEFT", x + 6, -52)
        -- hover the tree's name to read what its stat does
        local tip = CreateFrame("Frame", nil, t)
        tip:SetSize(cw, 20)
        tip:SetPoint("TOPLEFT", x, -48)
        tip:EnableMouse(true)
        tip:SetScript("OnEnter", function(self)
            if not self.tip or not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(self.name or "")
            GameTooltip:AddLine(self.tip, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        tip:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        t.tips[ti] = tip
        t.cells[ti] = {}
        for ri = 1, 5 do
            local b = CreateFrame("Button", nil, t, "BackdropTemplate")
            b:SetSize(cw, ch)
            b:SetPoint("TOPLEFT", x, -72 - (ri - 1) * (ch + 6))
            b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10,
                insets = { left = 2, right = 2, top = 2, bottom = 2 } })
            b:SetBackdropColor(0.07, 0.09, 0.08, 0.95)
            b:SetBackdropBorderColor(0.6, 0.5, 0.25, 1)
            b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            b.text:SetPoint("TOPLEFT", 10, -9)
            b.text:SetWidth(cw - 20)
            b.text:SetJustifyH("LEFT")
            b:SetScript("OnClick", function(self)
                if HR.Learn(HR.DB().class, self.talent) then ns.Sound("card") end
                UI.ShowTalents(true)
            end)
            t.cells[ti][ri] = b
        end
    end
    local back = CreateFrame("Button", nil, t, "UIPanelButtonTemplate")
    back:SetSize(100, 22)
    back:SetPoint("BOTTOMRIGHT", -24, 20)
    back:SetText("Main menu")
    back:SetScript("OnClick", function() UI.ShowTalents(false) UI.Lobby() end)
    local reset = CreateFrame("Button", nil, t, "UIPanelButtonTemplate")
    reset:SetSize(110, 22)
    reset:SetPoint("BOTTOMLEFT", 24, 20)
    reset:SetText("Reset (free)")
    reset:SetScript("OnClick", function() HR.ResetTalents(HR.DB().class) UI.ShowTalents(true) end)
    t.note = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t.note:SetPoint("BOTTOM", 0, 26)
    t.note:SetText("|cffaaaaaaFill a talent to open the one below it. Hover a tree's name to see what it does.|r")
    t.back, t.reset = back, reset
    t:Hide()
    return t
end

---------------------------------------------------------------------------
-- Keys
---------------------------------------------------------------------------
local MOVE = { W = { 0, 1 }, UP = { 0, 1 }, S = { 0, -1 }, DOWN = { 0, -1 }, A = { -1, 0 }, LEFT = { -1, 0 }, D = { 1, 0 }, RIGHT = { 1, 0 } }
local MENU_KEYS = { ["1"] = "1", ["2"] = "2", ["3"] = "3", ["4"] = "4", ["5"] = "5", ["6"] = "6", ["7"] = "7", ["8"] = "8", ["9"] = "9", ["0"] = "0",
    F = "F", R = "R", ENTER = "E", SPACE = "E" }

function UI.Keyboard(on)
    if not ui.canvas then return end
    if on and InCombatLockdown and InCombatLockdown() then on = false end
    pcall(ui.canvas.EnableKeyboard, ui.canvas, on)
    if not on then ui.held = {} end
end

local function ApplyMove()
    local g = ui.g
    if not g then return end
    local dx, dy = 0, 0
    for key in pairs(ui.held) do
        local m = MOVE[key]
        if m then dx, dy = dx + m[1], dy + m[2] end
    end
    g.input.dx, g.input.dy = dx, dy
end

--- A key went down (or up). Returns true if the game used it.
function UI.Key(key, down)
    if MOVE[key] then
        ui.held[key] = down or nil
        ApplyMove()
        return true
    end
    if not down then return false end
    local g = ui.g
    if key == "P" or key == "ESCAPE" then
        if g and g.phase ~= "over" then
            if g.paused then
                if key == "P" then UI.Resume() end
            else
                UI.Pause()
            end
        end
        return key == "P"
    end
    local mk = MENU_KEYS[key]
    if mk and CurrentMenu() then
        UI.Pick(mk)
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- Sounds for what happened this frame (short, and never stacked)
---------------------------------------------------------------------------
local SOUND = { levelup = "hr_level", bigwin = "bigwin", jackpot = "bigwin", win = "win", death = "death", boss = "hr_boss", card = "card",
    roll = "roll", coin = "coin", lose = "push", push = "push", hurt = "hr_hurt", pick = "hr_power", chip = "hr_chip", kill = "hr_kill",
    heal = "hr_heal", warn = "hr_warn", chest = "hr_chest" }
-- The least time between two plays of the same sound (the frequent ones are spaced out more).
local SOUND_GAP = { hr_kill = 0.18, hr_chip = 0.3, hr_warn = 1.2 }
local lastSound = {}

local function DrainEvents(g)
    local now = GetTime()
    for _, name in ipairs(g.events) do
        if name == "hurt" then
            -- a hit shows: the screen's edges go red, you flash red, the view shakes
            ui.hurt = 0.45
            if HR.DB().opts.shake ~= false then ui.shake = 0.22 end
        end
        local s = SOUND[name]
        if s and now - (lastSound[s] or 0) > (SOUND_GAP[s] or 0.25) then
            lastSound[s] = now
            ns.Sound(s)
        end
    end
    g.events = {}
end

---------------------------------------------------------------------------
-- Building the window
---------------------------------------------------------------------------
local WHITE = "Interface\\Buttons\\WHITE8X8"
-- How much of each frame texture is its see-through window: { across, down }.
local BAR_FRAME = { ui_bar = { 464 / 512, 32 / 64 }, ui_xp = { 500 / 512, 8 / 16 } }

--- A menu panel: the dark middle of the panel art, a gold edge of fixed thickness and a corner
--- piece at each corner (one stretched texture would smear its frame).
local function Panel(f)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetTexture(Tex("ui_panel"))
    f.bg:SetTexCoord(0.3, 0.7, 0.3, 0.7)
    f.bg:SetAllPoints()
    local function edge(r, g, b, inset, thick)
        for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
            local t = f:CreateTexture(nil, "BORDER")
            t:SetTexture(WHITE)
            t:SetVertexColor(r, g, b, 1)
            local sy = (side == "TOP" and -1 or 1) * inset
            local sx = (side == "LEFT" and 1 or -1) * inset
            if side == "TOP" or side == "BOTTOM" then
                t:SetPoint(side .. "LEFT", inset, sy)
                t:SetPoint(side .. "RIGHT", -inset, sy)
                t:SetHeight(thick)
            else
                t:SetPoint("TOP" .. side, sx, -inset)
                t:SetPoint("BOTTOM" .. side, sx, inset)
                t:SetWidth(thick)
            end
        end
    end
    edge(0.12, 0.07, 0.03, 0, 6)
    edge(0.86, 0.66, 0.26, 1, 3)
    edge(1, 0.93, 0.62, 2, 1)
    for i, c in ipairs({ { "TOPLEFT", false, false }, { "TOPRIGHT", true, false }, { "BOTTOMLEFT", false, true }, { "BOTTOMRIGHT", true, true } }) do
        local t = f:CreateTexture(nil, "ARTWORK")
        t:SetTexture(Tex("wall_corner"))
        t:SetSize(26, 26)
        t:SetPoint("CENTER", f, c[1], c[2] and -8 or 8, c[3] and 8 or -8)
        t:SetTexCoord(c[2] and 1 or 0, c[2] and 0 or 1, c[3] and 1 or 0, c[3] and 0 or 1)
    end
end

--- A bar: a dark backing, a glossy fill that's tinted, and (for the big ones) a gold frame over it.
local function Bar(parent, w, hgt, r, g, b, frame)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, hgt)
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetTexture(WHITE)
    f.bg:SetVertexColor(0.03, 0.02, 0.02, 0.85)
    f.bg:SetAllPoints()
    f.fill = f:CreateTexture(nil, "BORDER")
    f.fill:SetTexture(frame and Tex("ui_barfill") or WHITE)
    f.fill:SetVertexColor(r, g, b, 1)
    f.fill:SetPoint("LEFT")
    f.fill:SetSize(w, hgt)
    if frame then
        local win = BAR_FRAME[frame]
        f.frame = f:CreateTexture(nil, "OVERLAY")
        f.frame:SetTexture(Tex(frame))
        f.frame:SetPoint("CENTER")
        f.frame:SetSize(w / win[1], hgt / win[2])
    end
    return f
end

UI._Panel = Panel

local function Layer(canvas, level)
    local f = CreateFrame("Frame", nil, canvas)
    f:SetAllPoints()
    f:SetFrameLevel(canvas:GetFrameLevel() + level)
    return f
end

local function BuildRoom(canvas)
    -- everything in the room is drawn on child frames, so the canvas clips it. From the floor up:
    -- floor and danger areas; lights and pickups; enemies and shots; the player and effects;
    -- the walls; the vignette; numbers.
    local field = Layer(canvas, 1)
    ui.field = field
    ui.floor = field:CreateTexture(nil, "BACKGROUND")
    ui.floor:SetSize(CW + 2 * TILE, CH + 2 * TILE)
    ui.floor:SetTexCoord(0, (CW + 2 * TILE) / TILE, 0, (CH + 2 * TILE) / TILE)
    SetTiled(ui.floor, "floor_dice")
    ui.floor:SetPoint("BOTTOMLEFT", field, "BOTTOMLEFT", -TILE, -TILE)
    ui.zonePool = Pool(field, "BORDER", 300)
    ui.linePool = LinePool(field, "ARTWORK", 60)
    ui.shadowPool = Pool(field, "OVERLAY", HR.CAPS.enemies + 16, "shadow")
    ui.labels = {}
    for i = 1, 3 do
        local fs = field:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        pcall(function() fs:SetTextScale(2.4) end)
        pcall(function() fs:SetTextColor(0.9, 0.78, 0.55) end)
        fs:SetAlpha(0.3)
        fs:Hide()
        ui.labels[i] = fs
    end
    local low = Layer(canvas, 2)
    ui.glowPool = Pool(low, "BORDER", 110, "glow", "ADD")
    ui.pickPool = Pool(low, "ARTWORK", HR.CAPS.pickups + HR.CAPS.special)
    local mid = Layer(canvas, 4)
    ui.trailPool = Pool(mid, "BORDER", 160)
    ui.enemyPool = Pool(mid, "ARTWORK", HR.CAPS.enemies + 16)
    ui.shotPool = Pool(mid, "OVERLAY", HR.CAPS.shots + HR.CAPS.eshots + 24)
    local top = Layer(canvas, 6)
    ui.fxPool = Pool(top, "BORDER", HR.CAPS.fx)
    ui.player = top:CreateTexture(nil, "ARTWORK")
    ui.gun = top:CreateTexture(nil, "OVERLAY")
    SetSprite(ui.gun, "revolver")
    ui.shield = top:CreateTexture(nil, "BORDER")
    SetSprite(ui.shield, "ring_thin")
    ui.arrows = {}
    for i = 1, 5 do
        local t = top:CreateTexture(nil, "OVERLAY")
        SetSprite(t, "arrow_w")
        t:SetSize(22, 22)
        t:Hide()
        ui.arrows[i] = t
    end

    -- the walls
    local wf = Layer(canvas, 8)
    ui.wallFrame = wf
    local w = { corners = {}, torches = {} }
    ui.walls = w
    local function fill(wd, ht)
        local t = wf:CreateTexture(nil, "BACKGROUND")
        t:SetTexture(WHITE)
        t:SetVertexColor(0.05, 0.03, 0.02, 1)
        t:SetSize(wd, ht)
        return t
    end
    for _, side in ipairs({ "top", "bottom" }) do
        local t = wf:CreateTexture(nil, "BORDER")
        SetTiled(t, "wall_h")
        t:SetSize(CW + 16, TRIM)
        w[side], w[side .. "Fill"] = t, fill(CW + 16, CH)
    end
    for _, side in ipairs({ "left", "right" }) do
        local t = wf:CreateTexture(nil, "BORDER")
        SetTiled(t, "wall_v")
        t:SetSize(TRIM, CH + 16)
        w[side], w[side .. "Fill"] = t, fill(CW, CH + 16)
    end
    for i = 1, 4 do
        local t = wf:CreateTexture(nil, "ARTWORK")
        SetSprite(t, "wall_corner")
        t:SetSize(TRIM + 8, TRIM + 8)
        w.corners[i] = t
    end
    for i = 1, 5 do
        local t = wf:CreateTexture(nil, "OVERLAY")
        SetSprite(t, "torch")
        t:SetSize(26, 52)
        t:Hide()
        w.torches[i] = t
    end

    -- dark corners over the whole view, and the white flash for the big moments
    local light = Layer(canvas, 9)
    ui.vignette = light:CreateTexture(nil, "ARTWORK")
    SetSprite(ui.vignette, "vignette")
    ui.vignette:SetAllPoints()
    -- red around the edges when you're hit, and a slow pulse while your health is low
    ui.hurtEdge = light:CreateTexture(nil, "OVERLAY")
    SetSprite(ui.hurtEdge, "vignette_w")
    ui.hurtEdge:SetVertexColor(1, 0.05, 0.02, 1)
    ui.hurtEdge:SetAllPoints()
    ui.hurtEdge:Hide()
    ui.hurtFill = light:CreateTexture(nil, "OVERLAY")
    ui.hurtFill:SetTexture(WHITE)
    ui.hurtFill:SetVertexColor(1, 0.05, 0.02, 1)
    ui.hurtFill:SetAllPoints()
    ui.hurtFill:Hide()
    ui.flash = light:CreateTexture(nil, "OVERLAY")
    ui.flash:SetTexture(WHITE)
    ui.flash:SetVertexColor(1, 0.95, 0.8, 1)
    ui.flash:SetAllPoints()
    ui.flash:Hide()

    local text = Layer(canvas, 10)
    ui.texts, ui.cardText, ui.smallBars = {}, {}, {}
    for i = 1, HR.CAPS.texts do
        ui.texts[i] = text:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        ui.texts[i]:Hide()
    end
    for i = 1, HR.CAPS.special do
        ui.cardText[i] = text:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        ui.cardText[i]:Hide()
    end
    for i = 1, 8 do
        local bar = Bar(text, 40, 4, 0.85, 0.4, 1)
        bar:Hide()
        ui.smallBars[i] = bar
    end
end

local function BuildHud(canvas)
    local hud = Layer(canvas, 12)
    ui.hudFrame = hud
    local function plate(point, x, y, wd)
        local t = hud:CreateTexture(nil, "BACKGROUND")
        SetSprite(t, "ui_plate")
        t:SetSize(wd, 30)
        t:SetPoint(point, x, y)
        return t
    end
    ui.plate1 = plate("TOPLEFT", 8, -8, 262)
    ui.line1 = hud:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ui.line1:SetPoint("LEFT", ui.plate1, "LEFT", 10, 0)
    ui.plate2 = plate("TOPRIGHT", -8, -8, 232)
    ui.line2 = hud:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ui.line2:SetPoint("RIGHT", ui.plate2, "RIGHT", -12, 0)

    -- the boss: name, then one bar (two for the twins) across the top
    ui.bossBars = {}
    for i = 1, 2 do
        local bar = Bar(hud, BOSS_W, 14, 0.92, 0.16, 0.14, "ui_bar")
        bar:SetPoint("TOP", 0, -(12 + (i - 1) * 24))
        bar:Hide()
        ui.bossBars[i] = bar
    end
    local nameTop = CreateFrame("Frame", nil, ui.bossBars[1])
    nameTop:SetAllPoints()
    nameTop:SetFrameLevel(ui.bossBars[1]:GetFrameLevel() + 2)
    ui.bossName = nameTop:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.bossName:SetPoint("CENTER", 0, 0)
    ui.info = hud:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ui.info:SetPoint("TOP", 0, -42)
    ui.info:SetWidth(CW - 240)
    ui.banner = hud:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    ui.banner:SetPoint("TOP", 0, -100)
    ui.banner:SetWidth(CW - 80)
    ui.banner:Hide()
    ui.titleShade = hud:CreateTexture(nil, "BACKGROUND")
    ui.titleShade:SetTexture(WHITE)
    ui.titleShade:SetVertexColor(0, 0, 0, 0.6)
    ui.titleShade:SetSize(CW, 96)
    ui.titleShade:SetPoint("CENTER", 0, 60)
    ui.titleShade:Hide()
    ui.title = hud:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    ui.title:SetPoint("CENTER", 0, 60)
    ui.title:SetWidth(CW - 60)
    ui.title:Hide()

    -- health and experience sit bottom centre, as they do in WoW
    local xp = Bar(hud, XP_W, 7, 0.62, 0.36, 0.95, "ui_xp")
    xp:SetPoint("BOTTOM", 0, 42)
    ui.xpFill = xp.fill
    local hp = Bar(hud, HP_W, 17, 0.2, 0.82, 0.2, "ui_bar")
    hp:SetPoint("BOTTOM", 0, 14)
    ui.hpFill = hp.fill
    ui.shieldFill = hp:CreateTexture(nil, "ARTWORK")
    ui.shieldFill:SetTexture(WHITE)
    ui.shieldFill:SetVertexColor(0.5, 0.8, 1, 0.85)
    ui.shieldFill:SetPoint("TOPLEFT")
    ui.shieldFill:SetSize(1, 5)
    local hpTop = CreateFrame("Frame", nil, hp)
    hpTop:SetAllPoints()
    hpTop:SetFrameLevel(hp:GetFrameLevel() + 2)
    ui.hpText = hpTop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    ui.hpText:SetPoint("CENTER", hp, "CENTER", 0, 0)
    -- over the bars: what the class is holding; to the sides: weapons, and suits held
    ui.hand = hud:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    ui.hand:SetPoint("BOTTOM", 0, 58)
    ui.weapons = hud:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.weapons:SetPoint("BOTTOMLEFT", 14, 14)
    ui.suits = hud:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ui.suits:SetPoint("BOTTOMRIGHT", -14, 14)
end

local function BuildMenus(canvas)
    -- the room goes dim behind a menu
    local dim = Layer(canvas, 18)
    ui.dim = dim
    local shade = dim:CreateTexture(nil, "BACKGROUND")
    shade:SetTexture(WHITE)
    shade:SetVertexColor(0, 0, 0, 0.55)
    shade:SetAllPoints()
    dim:Hide()

    local o = CreateFrame("Frame", nil, canvas)
    ui.overlay = o
    o:SetPoint("CENTER", 0, 0)
    o:SetSize(ROW_W + 40, 200)
    o:SetFrameLevel(canvas:GetFrameLevel() + 20)
    o:EnableMouse(true)
    Panel(o)
    o.title = o:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    o.title:SetPoint("TOP", 0, -18)
    o.sub = o:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    o.sub:SetPoint("TOP", 0, -48)
    o.sub:SetWidth(ROW_W - 8)
    o.sub:SetJustifyH("LEFT")
    pcall(function() o.sub:SetJustifyV("TOP") end)
    local function hover(b)
        b.hl = b:CreateTexture(nil, "ARTWORK")
        b.hl:SetTexture(WHITE)
        b.hl:SetVertexColor(1, 0.9, 0.6, 0.1)
        pcall(b.hl.SetBlendMode, b.hl, "ADD")
        b.hl:SetPoint("TOPLEFT", 3, -3)
        b.hl:SetPoint("BOTTOMRIGHT", -3, 3)
        b.hl:Hide()
        b:SetScript("OnClick", function(self) UI.Pick(self.key) end)
        b:SetScript("OnEnter", function(self) self.hl:Show() end)
        b:SetScript("OnLeave", function(self) self.hl:Hide() end)
    end
    o.buttons, o.cards = {}, {}
    for i = 1, MAX_OPTIONS do
        local b = CreateFrame("Button", nil, o)
        b:SetSize(ROW_W, 46)
        b.bg = b:CreateTexture(nil, "BACKGROUND")
        b.bg:SetTexture(Tex("ui_button"))
        b.bg:SetAllPoints()
        b.head = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        b.head:SetPoint("TOPLEFT", 14, -6)
        b.head:SetWidth(ROW_W - 28)
        b.head:SetJustifyH("LEFT")
        b.head:SetWordWrap(false)
        b.desc = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.desc:SetPoint("TOPLEFT", 14, -22)
        b.desc:SetWidth(ROW_W - 28)
        b.desc:SetJustifyH("LEFT")
        hover(b)
        b:Hide()
        o.buttons[i] = b
    end
    for i = 1, MAX_CARDS do
        local c = CreateFrame("Button", nil, o)
        c:SetSize(CARD_W, CARD_H)
        -- a light behind the card says how rare it is
        c.glow = c:CreateTexture(nil, "BACKGROUND")
        c.glow:SetTexture(Tex("ui_cardglow"))
        pcall(c.glow.SetBlendMode, c.glow, "ADD")
        c.glow:SetPoint("CENTER")
        c.glow:SetSize(CARD_W + 40, CARD_H + 46)
        c.bg = c:CreateTexture(nil, "BORDER")
        c.bg:SetTexture(Tex("ui_card"))
        c.bg:SetAllPoints()
        c.icon = c:CreateTexture(nil, "ARTWORK")
        c.icon:SetSize(56, 56)
        c.icon:SetPoint("CENTER", c, "TOP", 0, -CARD_H * 70 / 280)
        c.title = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        c.title:SetPoint("CENTER", c, "TOP", 0, -CARD_H * 137 / 280)
        c.title:SetWidth(CARD_W - 18)
        c.title:SetWordWrap(false)
        c.sub = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        c.sub:SetPoint("TOP", c, "TOP", 0, -CARD_H * 158 / 280)
        c.sub:SetWidth(CARD_W - 22)
        c.desc = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        c.desc:SetPoint("TOP", c.sub, "BOTTOM", 0, -5)
        c.desc:SetWidth(CARD_W - 26)
        c.keyText = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        c.keyText:SetPoint("BOTTOM", 0, 13)
        hover(c)
        c:Hide()
        o.cards[i] = c
    end
    ui.talents = BuildTalents(canvas)
end

--- The game's own window: 800 x 600, movable, closed with its X or Escape.
function UI.BuildWindow()
    if ui.win then return ui.win end
    local opts = HR.DB().opts
    local win = CreateFrame("Frame", "GuildGambitHighRoller", UIParent, "BackdropTemplate")
    ui.win, ui.panel = win, win
    win:SetSize(CW + 16, CH + 40)
    win:SetFrameStrata("HIGH")
    win:SetToplevel(true)
    win:SetClampedToScreen(true)
    win:SetBackdrop({ bgFile = WHITE, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    win:SetBackdropColor(0.06, 0.035, 0.02, 1)
    win:SetBackdropBorderColor(0.9, 0.72, 0.3, 1)
    local pos = opts.pos
    if type(pos) == "table" and pos[1] then win:SetPoint(pos[1], UIParent, pos[1], pos[2] or 0, pos[3] or 0) else win:SetPoint("CENTER") end
    win:SetScale(max(0.6, min(1.4, opts.scale or 1)))
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", function(self) self:StartMoving() end)
    win:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint(1)
        if point then opts.pos = { point, x, y } end
    end)
    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -9)
    title:SetText("High Roller  |cff888888beta|r")
    local hint = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPRIGHT", -36, -12)
    hint:SetText("|cff999999WASD to move   P pause|r")
    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 1, 1)
    close:SetScript("OnClick", function() win:Hide() end)
    -- smaller / larger
    local function size(text, x, step)
        local b = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        b:SetSize(22, 20)
        b:SetPoint("TOPLEFT", x, -7)
        b:SetText(text)
        b:SetScript("OnClick", function()
            opts.scale = max(0.6, min(1.4, (opts.scale or 1) + step))
            win:SetScale(opts.scale)
        end)
    end
    size("-", 8, -0.1)
    size("+", 32, 0.1)
    if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "GuildGambitHighRoller") end

    local canvas = CreateFrame("Frame", nil, win)
    ui.canvas = canvas
    canvas:SetSize(CW, CH)
    canvas:SetPoint("BOTTOM", 0, 8)
    pcall(canvas.SetClipsChildren, canvas, true)
    BuildRoom(canvas)
    BuildHud(canvas)
    BuildMenus(canvas)

    canvas:SetScript("OnKeyDown", function(self, key)
        local ours = not (InCombatLockdown and InCombatLockdown()) and (MOVE[key] ~= nil or key == "P" or (MENU_KEYS[key] ~= nil and CurrentMenu() ~= nil))
        pcall(self.SetPropagateKeyboardInput, self, not ours)
        UI.Key(key, true)
    end)
    canvas:SetScript("OnKeyUp", function(_, key) UI.Key(key, false) end)
    canvas:SetScript("OnUpdate", function(_, elapsed)
        local g = ui.g
        if ui.shake > 0 then ui.shake = ui.shake - elapsed end
        if (ui.hurt or 0) > 0 then ui.hurt = ui.hurt - elapsed end
        if not g then return end
        local hadMenu = g.menu
        HR.Advance(g, min(elapsed, 0.25))
        DrainEvents(g)
        if g.menu ~= hadMenu or (g.phase == "over" and not ui.menu) then UI.AfterChange() else UI.Render() end
    end)
    canvas:SetScript("OnShow", function()
        UI.Keyboard(true)
        if not ui.g and (not ui.menu or ui.menu.kind == "lobby") then UI.Lobby() end
        UI.AfterChange()
    end)
    canvas:SetScript("OnHide", function()
        UI.Pause("Paused while the window was closed")
        UI.Keyboard(false)
    end)

    -- combat and landing from a flight: pause and hand the keys back
    local ev = CreateFrame("Frame")
    for _, e in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_CONTROL_GAINED" }) do pcall(ev.RegisterEvent, ev, e) end
    ev:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then
            UI.Pause("In combat - your keys are back to normal")
            pcall(canvas.EnableKeyboard, canvas, false)
            ui.held = {}
        elseif event == "PLAYER_REGEN_ENABLED" then
            if canvas:IsVisible() then UI.Keyboard(true) end
        elseif event == "PLAYER_CONTROL_GAINED" then
            -- (the end of a flight path)
            if ui.g and not ui.g.paused and canvas:IsVisible() then UI.Pause("You've landed") end
        end
    end)

    win:Hide()
    UI.Lobby()
    return win
end

--- Opens the game's window (building it the first time).
function UI.Open()
    local win = UI.BuildWindow()
    win:Show()
    return win
end

--- The Arcade tab's page for the game: how to play, in five pictures, and a button that opens
--- its window.
local TUTORIAL = {
    { head = "Just walk", text = "Move with |cffffd100W A S D|r. That's the only control: your gun fires itself.", pic = "move" },
    { head = "Stay out of the red", text = "Red on the floor is about to hit. Step out before it fills in. |cffff6a5aA boss's red kills in one hit.|r", pic = "red" },
    { head = "Walk over the loot", text = "|cffffd100Chips|r are your score. A |cffffd100crate|r is a new weapon; chests and power-ups make you stronger.", pic = "loot" },
    { head = "Level up, pick a card", text = "The game pauses and deals three cards. Press |cffffd1001|r, |cffffd1002|r or |cffffd1003|r for a new weapon or an upgrade.", pic = "cards" },
    { head = "A boss every 2 minutes", tall = true, pic = "boss",
      text = "Beat it and take a relic. Then choose: |cffffd100go on|r to the next room, or |cffffd100walk away|r and keep your chips.\n|cffff6a5aDie and you keep nothing.|r" },
}

local function TutorialPicture(pic, kind, h)
    local function sprite(name, x, y, size, layer)
        local t = pic:CreateTexture(nil, layer or "ARTWORK")
        t:SetTexture(Tex(name))
        t:SetSize(size, size)
        t:SetPoint("CENTER", pic, "TOPLEFT", x, -y)
        return t
    end
    local function tint(t, r, g, b, a)
        t:SetVertexColor(r, g, b, a or 1)
        return t
    end
    local floor = pic:CreateTexture(nil, "BACKGROUND")
    if kind == "cards" then
        floor:SetTexture(WHITE)
        floor:SetVertexColor(0.1, 0.06, 0.09, 1)
    else
        local name = kind == "boss" and "floor_cards" or "floor_dice"
        if not pcall(floor.SetTexture, floor, Tex(name), "REPEAT", "REPEAT") then floor:SetTexture(Tex(name)) end
        floor:SetTexCoord(0, 140 / 110, 0, h / 110)
    end
    floor:SetAllPoints()
    if kind == "move" then
        for _, k in ipairs({ { "W", 36, 20 }, { "A", 14, 44 }, { "S", 36, 44 }, { "D", 58, 44 } }) do
            local cap = pic:CreateTexture(nil, "BORDER")
            cap:SetTexture(WHITE)
            cap:SetVertexColor(0.9, 0.87, 0.78, 1)
            cap:SetSize(19, 19)
            cap:SetPoint("CENTER", pic, "TOPLEFT", k[2], -k[3])
            local fs = pic:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            fs:SetPoint("CENTER", cap, "CENTER", 0, 0)
            fs:SetText("|cff221a10" .. k[1] .. "|r")
        end
        sprite("hero", 100, 34, 52)
        sprite("arrow_w", 130, 36, 14, "OVERLAY")
    elseif kind == "red" then
        tint(sprite("disc", 36, 34, 56, "BORDER"), 1, 0.13, 0.08, 0.8)
        tint(sprite("disc", 36, 34, 30, "BORDER"), 1, 0.3, 0.18, 0.9)
        tint(sprite("ring_thin", 36, 34, 56), 1, 0.5, 0.38, 1)
        sprite("arrow_w", 76, 36, 14, "OVERLAY")
        sprite("hero", 108, 34, 50)
    elseif kind == "loot" then
        sprite("chip", 18, 48, 24)
        sprite("chip", 34, 22, 20)
        sprite("crate", 62, 44, 34)
        sprite("chest", 98, 24, 40)
        sprite("pu_boots", 120, 52, 32)
    elseif kind == "cards" then
        for i, icon in ipairs({ "revolver", "ball8", "die6" }) do
            local x = 26 + (i - 1) * 44
            local card = pic:CreateTexture(nil, "BORDER")
            card:SetTexture(Tex("ui_card"))
            card:SetSize(38, 54)
            card:SetPoint("CENTER", pic, "TOPLEFT", x, -h / 2)
            sprite(icon, x, h / 2 - 12, 15)
            local fs = pic:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            fs:SetPoint("CENTER", pic, "TOPLEFT", x, -(h / 2 + 14))
            fs:SetText(tostring(i))
        end
    elseif kind == "boss" then
        sprite("boss_dealer", 50, h / 2, 88)
        sprite("chest", 116, h - 26, 40)
    end
end

function UI.Build(p)
    local W = 420
    local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -26)
    title:SetText("High Roller  |cff888888beta|r")
    local sub = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -4)
    sub:SetText("|cffaaaaaaA casual game for flight paths. Just for fun - no gold, ever.|r")
    local y = -64
    for i, step in ipairs(TUTORIAL) do
        local h = step.tall and 96 or 76
        local f = CreateFrame("Frame", nil, p, "BackdropTemplate")
        f:SetSize(W, h)
        f:SetPoint("TOP", 0, y)
        f:SetBackdrop({ bgFile = WHITE, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
        f:SetBackdropColor(0.07, 0.12, 0.09, 0.95)
        f:SetBackdropBorderColor(0.78, 0.6, 0.24, 1)
        local num = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        num:SetPoint("LEFT", 9, 0)
        num:SetText(tostring(i))
        local pic = CreateFrame("Frame", nil, f)
        pic:SetSize(140, h - 12)
        pic:SetPoint("LEFT", 28, 0)
        pcall(pic.SetClipsChildren, pic, true)
        TutorialPicture(pic, step.pic, h - 12)
        local head = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        head:SetPoint("TOPLEFT", 180, -9)
        head:SetText(step.head)
        local text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -4)
        text:SetWidth(W - 192)
        text:SetJustifyH("LEFT")
        text:SetText(step.text)
        y = y - h - 5
    end
    local open = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
    open:SetSize(190, 28)
    open:SetPoint("TOP", 0, y - 5)
    open:SetText("Play High Roller")
    open:SetScript("OnClick", function() UI.Open() end)
    local hint = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOP", open, "BOTTOM", 0, -5)
    hint:SetText("|cff999999It opens in its own window. Or type /gg roller.|r")
    ui.tutorial = p
    UI.BuildWindow()
end

-- for the mock-client tests
function UI._Run() return ui.g end
function UI._Frame(elapsed)
    local f = ui.canvas and ui.canvas:GetScript("OnUpdate")
    if f then f(ui.canvas, elapsed or HR.STEP) end
end
