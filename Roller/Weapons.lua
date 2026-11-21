-- Roller/Weapons.lua: what each High Roller weapon does when it fires (HR.FIRE) or every step
-- (HR.WSTEP). mult scales damage: 1 normally, less for the Wild Card's copy.
local ADDON_NAME, ns = ...
local HR = ns.Roller
local FIRE, WSTEP = HR.FIRE, HR.WSTEP
local sqrt, floor, min, max, cos, sin, atan2, pi = math.sqrt, math.floor, math.min, math.max, math.cos, math.sin, math.atan2, math.pi
local dist, clamp = HR.dist, HR.clamp

local function V(w, f) return HR.WVal(w, f) end

---------------------------------------------------------------------------
-- The revolver you start with
---------------------------------------------------------------------------
-- He holds it out at arm's length and it swings round him to point at what it shoots
-- (pl.aim, which the UI draws it by). Bullets leave from the muzzle, not from his middle.
HR.GUN_HOLD, HR.GUN_REACH, HR.GUN_BARREL = 15, 22, 3

--- Where the muzzle is for an aim angle: x, y.
function HR.Muzzle(g, a, reach)
    local pl = g.pl
    local side = cos(a) >= 0 and 1 or -1 -- (the barrel is the top edge of the gun, whichever way it points)
    reach = reach or HR.GUN_REACH
    return pl.x + cos(a) * reach - sin(a) * HR.GUN_BARREL * side, pl.y + sin(a) * reach + cos(a) * HR.GUN_BARREL * side
end

local function Volley(g, w, mult)
    local pl = g.pl
    local target = HR.Nearest(g, pl.x, pl.y)
    if not target then return false end
    local a = atan2(target.y - pl.y, target.x - pl.x)
    pl.aim = a
    -- (something right on top of him is shot from the hip, or the bullet would start past it)
    local room = dist(pl.x, pl.y, target.x, target.y) - (target.r or 0)
    local mx, my = pl.x, pl.y
    if room > HR.GUN_REACH then mx, my = HR.Muzzle(g, a) end
    local n = V(w, "n")
    for i = 1, n do
        local b = a + (i - (n + 1) / 2) * 0.13
        HR.Shoot(g, { x = mx, y = my, vx = cos(b) * 310, vy = sin(b) * 310, speed = 310, dmg = V(w, "dmg") * mult, wid = "revolver",
            sprite = "bullet", pierce = V(w, "pierce"), size = 13 })
    end
    return true
end

FIRE.revolver = function(g, w, mult)
    if not Volley(g, w, mult) then
        w.cd = 0.2
        return
    end
    -- Tommy Gun: two more volleys right behind the first, at 40% strength each
    if w.evo then w.burst, w.burstT, w.burstMult = 2, 0.09, mult * 0.4 end
end

WSTEP.revolver = function(g, w, dt)
    -- the gun follows the nearest enemy between shots
    local pl = g.pl
    local t = HR.Nearest(g, pl.x, pl.y)
    if t then pl.aim = atan2(t.y - pl.y, t.x - pl.x) end
    if (w.burst or 0) > 0 then
        w.burstT = (w.burstT or 0) - dt
        if w.burstT <= 0 then
            w.burst, w.burstT = w.burst - 1, 0.09
            Volley(g, w, w.burstMult or 1)
        end
    end
end

---------------------------------------------------------------------------
-- Bone Dice
---------------------------------------------------------------------------
local function FloorDie(g, s)
    if s.noFloor then return end
    local n = 0
    for _, p in ipairs(g.pickups) do if p.kind == "die" then n = n + 1 end end
    if n >= 6 then return end
    HR.DropPickup(g, { kind = "die", x = s.x, y = s.y, face = s.face, life = 5 })
end

local function ThrowDie(g, w, face, target, mult, spread, extra)
    local pl = g.pl
    local s = { dmg = face * V(w, "dmg") * mult, wid = "bonedice", exact = true, face = face, sprite = "die" .. face,
        bounce = V(w, "bounce"), canBounce = true,
        perBounce = HR.CharmMax(g, "marbles") and 0.1 or 0, maxRoll = face == 6, onEnd = FloorDie }
    if extra then for k, v in pairs(extra) do s[k] = v end end
    -- Natural Roller: a six explodes and is rolled again
    if w.evo and face == 6 then
        s.onHit = function(gg, shot, e)
            HR.Blast(gg, e.x, e.y, 34 * gg.st.area, shot.dmg * 0.6, "bonedice", { exact = true, quiet = true })
            if (shot.rerolls or 0) < 2 then
                local f2 = HR.RollDie(gg)
                ThrowDie(gg, w, f2, HR.Nearest(gg, e.x, e.y, shot.seen), mult, 0,
                    { x0 = e.x, y0 = e.y, rerolls = (shot.rerolls or 0) + 1, noFloor = true })
            end
        end
    end
    return HR.ShootAt(g, s.x0 or pl.x, s.y0 or pl.y, target, 210, s, spread)
end

FIRE.bonedice = function(g, w, mult)
    local pl = g.pl
    local target = HR.Nearest(g, pl.x, pl.y)
    if not target then
        w.cd = 0.2
        return
    end
    local faces, kind = HR.ThrowDice(g, V(w, "n"), g.heldDice)
    g.heldDice = {}
    if kind == "snake" then
        if HR.Relic(g, "martingale") then g.mgHit = true end
        HR.Text(g, pl.x, pl.y + 20, "Snake eyes", "ffaaaaaa")
        g.diceChain = 0
        return
    end
    for i, f in ipairs(faces) do
        ThrowDie(g, w, f, target, mult, (i - (#faces + 1) / 2) * 0.16)
    end
    if kind == "triple" then
        HR.Blast(g, target.x, target.y, 70 * g.st.area, faces[1] * V(w, "dmg") * 4 * mult, "bonedice", { exact = true })
        HR.Text(g, pl.x, pl.y + 22, "TRIPLE " .. faces[1] .. "s!", "ffffd100")
        HR.Earned(g, "triple")
        HR.Event(g, "jackpot")
        if faces[1] == 6 then HR.Taunt(g, "jackpot") end
    end
    local chains = kind == "double" or (kind == "triple" and HR.CharmMax(g, "shaved"))
    local cap = V(w, "chain")
    if chains and (g.diceChain or 0) < cap and mult >= 1 then
        g.diceChain = (g.diceChain or 0) + 1
        g.bestChain = max(g.bestChain or 0, g.diceChain)
        HR.Text(g, pl.x, pl.y + 20, kind == "double" and ("Doubles! x" .. g.diceChain) or "Again!", "ffffd100")
        HR.Event(g, "roll")
        -- a free throw, a moment later
        g.freeThrows = (g.freeThrows or 0) + 1
        g.freeT = 0.28
    elseif not chains then
        g.diceChain = 0
    end
end

WSTEP.bonedice = function(g, w, dt)
    if (g.freeThrows or 0) > 0 then
        g.freeT = (g.freeT or 0) - dt
        if g.freeT <= 0 then
            g.freeThrows = g.freeThrows - 1
            g.freeT = 0.28
            FIRE.bonedice(g, w, 1)
        end
    end
end

---------------------------------------------------------------------------
-- Flick
---------------------------------------------------------------------------
FIRE.flick = function(g, w, mult)
    local pl = g.pl
    local target = HR.Nearest(g, pl.x, pl.y)
    if not target then
        w.cd = 0.2
        return
    end
    local n = V(w, "n")
    for i = 1, n do
        HR.ShootAt(g, pl.x, pl.y, target, 230, { dmg = V(w, "dmg") * mult, wid = "flick", sprite = "card", pierce = V(w, "pierce") },
            (i - (n + 1) / 2) * 0.2)
    end
end

---------------------------------------------------------------------------
-- Trick Coin
---------------------------------------------------------------------------
FIRE.trickcoin = function(g, w, mult)
    local pl, c = g.pl, g.coin
    local target = HR.Nearest(g, pl.x, pl.y)
    if not target then
        w.cd = 0.2
        return
    end
    local heads = c and c.side == "H"
    local skip = {}
    for i = 1, V(w, "n") do
        local t = HR.Nearest(g, pl.x, pl.y, skip) or target
        skip[t] = true
        HR.ShootAt(g, pl.x, pl.y, t, 240, { dmg = V(w, "dmg") * mult, wid = "trickcoin", sprite = "tcoin", canBounce = true,
            bounce = V(w, "bounce") + (heads and 1 or 0),
            perBounce = HR.CharmMax(g, "marbles") and 0.1 or 0 })
    end
end

---------------------------------------------------------------------------
-- Orbiting weapons (8-Ball, Lucky Clover, the Trick Coin's Tails coins)
---------------------------------------------------------------------------
local function Orbit(g, key, n, radius, speed, dt, onTouch, block)
    local pl = g.pl
    g.orbit = g.orbit or {}
    local o = g.orbit[key]
    if not o then
        o = { a = 0, pos = {} }
        g.orbit[key] = o
    end
    o.a = o.a + speed * dt
    o.n = n
    for i = 1, n do
        local a = o.a + (i - 1) * 2 * pi / n
        local x, y = pl.x + cos(a) * radius, pl.y + sin(a) * radius
        o.pos[i] = o.pos[i] or {}
        o.pos[i].x, o.pos[i].y = x, y
        for _, e in ipairs(g.enemies) do
            if not e.dead and not e.untarget and dist(x, y, e.x, e.y) <= 8 + e.r and (e.oh[key] or 0) <= g.time then
                onTouch(e)
            end
        end
        if block then
            for j = #g.eshots, 1, -1 do
                local s = g.eshots[j]
                if dist(x, y, s.x, s.y) <= 9 + s.r then
                    table.remove(g.eshots, j)
                    block(s)
                end
            end
        end
    end
    for i = n + 1, #o.pos do o.pos[i] = nil end
end

WSTEP.ball8 = function(g, w, dt, mult)
    mult = mult or 1
    local cd, dmg = V(w, "cd"), V(w, "dmg") * mult
    Orbit(g, "ball8", V(w, "n"), 46 * g.st.area, 3.2, dt, function(e)
        e.oh.ball8 = g.time + cd
        local r = HR.Roll(g)
        if w.evo then
            HR.Hit(g, e, dmg * 2, "ball8")
            HR.Jinx(g, e)
        elseif r < 0.34 then
            HR.Hit(g, e, dmg * 0.6, "ball8")
            HR.Jinx(g, e)
        elseif r < 0.67 then
            HR.Hit(g, e, dmg, "ball8")
        else
            HR.Hit(g, e, dmg, "ball8")
            HR.Hit(g, e, dmg, "ball8")
        end
    end)
end

WSTEP.clover = function(g, w, dt, mult)
    mult = mult or 1
    local cd, dmg = V(w, "cd"), V(w, "dmg") * mult
    Orbit(g, "clover", V(w, "n"), 30 * g.st.area, -2.6, dt, function(e)
        e.oh.clover = g.time + cd
        HR.Hit(g, e, dmg, "clover")
    end, function()
        if w.evo then HR.Heal(g, 1) end
    end)
end

WSTEP.trickcoin = function(g, w, dt)
    local c = g.coin
    if c and c.side == "T" then
        local dmg = V(w, "dmg") * 0.5
        Orbit(g, "tails", 2, 24, 4, dt, function(e)
            e.oh.tails = g.time + 0.5
            HR.Hit(g, e, dmg, "trickcoin")
        end)
    elseif g.orbit and g.orbit.tails then
        g.orbit.tails = nil
    end
end

---------------------------------------------------------------------------
-- Spades
---------------------------------------------------------------------------
FIRE.ace = function(g, w, mult)
    local pl = g.pl
    local target = HR.Nearest(g, pl.x, pl.y)
    if not target then
        w.cd = 0.2
        return
    end
    HR.ShootAt(g, pl.x, pl.y, target, 170, { dmg = V(w, "dmg") * mult, wid = "ace", sprite = "ace", pierce = 99, r = 9, size = 20, life = 3 })
end

FIRE.tower = function(g, w, mult)
    local pl, st = g.pl, g.st
    local target = HR.Nearest(g, pl.x, pl.y, nil, 240)
    if not target then
        w.cd = 0.3
        return
    end
    local x, y, dmg, rings = target.x, target.y, V(w, "dmg") * mult, V(w, "n")
    local r0 = HR.WEAPON.tower.r * st.area
    local function topple()
        for i = 1, rings do HR.Blast(g, x, y, r0 * (0.6 + 0.6 * i), dmg, "tower", { quiet = i > 1 }) end
    end
    -- the stack lands after a moment, then topples (High Stakes: it stays and topples again)
    g.zones[#g.zones + 1] = { side = "p", shape = "circle", x = x, y = y, r = 0, dmg = 0, wid = "tower", warn = 0,
        dur = w.evo and 4.2 or 0.5, every = w.evo and 1.2 or 9, tick = 0.4, sprite = "tower", onTick = topple }
end

FIRE.streak = function(g, w, mult)
    local pl = g.pl
    local target = HR.Nearest(g, pl.x, pl.y)
    if not target then
        w.cd = 0.2
        return
    end
    local stacks = min(V(w, "cap"), g.streakKills or 0)
    HR.ShootAt(g, pl.x, pl.y, target, 260, { dmg = V(w, "dmg") * (1 + 0.04 * stacks) * mult, wid = "streak", sprite = "bolt" })
end

---------------------------------------------------------------------------
-- Clubs
---------------------------------------------------------------------------
FIRE.cat = function(g, w, mult)
    -- each cat springs at a different enemy near you, then leaps on from one to the next
    local pl = g.pl
    local skip, any = {}, false
    for _ = 1, V(w, "n") do
        local t = HR.Nearest(g, pl.x, pl.y, skip, 320)
        if not t then break end
        skip[t], any = true, true
        HR.ShootAt(g, pl.x, pl.y, t, 300, { dmg = V(w, "dmg") * mult, wid = "cat", sprite = "cat", r = 10, size = 22, life = 1.6,
            canBounce = true, bounce = V(w, "pounce"), perBounce = HR.CharmMax(g, "marbles") and 0.1 or 0,
            onHit = function(gg, s, e) HR.Jinx(gg, e) end })
    end
    if not any then w.cd = 0.3 end
end

FIRE.rball = function(g, w, mult)
    local vis = HR.Visible(g)
    if #vis == 0 then
        w.cd = 0.3
        return
    end
    for _ = 1, V(w, "n") do
        local e = vis[g.rand.i(1, #vis)]
        if not e.dead then
            HR.Hit(g, e, V(w, "dmg") * mult, "rball")
            HR.Stun(g, e, 1.2)
            if w.evo then HR.Blast(g, e.x, e.y, 40 * g.st.area, V(w, "dmg") * 0.6 * mult, "rball")
            else g.zones[#g.zones + 1] = { side = "fx", shape = "circle", x = e.x, y = e.y, r = 14, dur = 0.2, warn = 0 } end
        end
    end
end

---------------------------------------------------------------------------
-- Diamonds
---------------------------------------------------------------------------
local REEL = { "cherry", "bell", "seven", "blank" }

FIRE.slots = function(g, w, mult)
    local pl, st = g.pl, g.st
    local misses = w.evo and (w.prog or 0) or 0
    local weights = { 3, 3, 2 + (g.luckNow or 0) * 0.03 + misses * 0.5, 4 }
    local reel = {}
    for i = 1, 3 do reel[i] = REEL[g.rand.weighted(weights)] end
    -- "rolled twice": one reel that doesn't match gets another go
    if st.advantage and (st.advantage >= 1 or g.rand.chance(st.advantage)) and not (reel[1] == reel[2] and reel[2] == reel[3]) then
        local odd = (reel[1] == reel[2]) and 3 or ((reel[1] == reel[3]) and 2 or 1)
        reel[odd] = REEL[g.rand.weighted(weights)]
    end
    local dmg = V(w, "dmg") * mult * (1 + 0.1 * misses)
    local a, b, c = reel[1], reel[2], reel[3]
    g.lastReels = { a, b, c, at = g.clock }
    if a == b and b == c and a ~= "blank" then
        w.prog = 0
        if a == "cherry" then
            HR.Heal(g, 10)
            HR.Text(g, pl.x, pl.y + 22, "Cherries! +10", "ff20ff20")
        elseif a == "bell" then
            for _, e in ipairs(HR.Visible(g)) do
                HR.Hit(g, e, dmg, "slots")
                HR.Stun(g, e, 1.5)
            end
            HR.Text(g, pl.x, pl.y + 22, "Bells!", "ffffd100")
        else
            for _, e in ipairs(HR.Visible(g)) do HR.Hit(g, e, dmg * 6, "slots") end
            HR.Text(g, pl.x, pl.y + 22, "7 7 7  JACKPOT!", "ffffd100")
            HR.AddChips(g, 50 * g.diff)
            HR.Earned(g, "sevens")
            HR.Taunt(g, "jackpot")
            HR.Event(g, "jackpot")
        end
        return
    end
    w.prog = (w.prog or 0) + 1
    local pair = (a == b or b == c or a == c)
    local skip = {}
    for _ = 1, pair and 3 or 1 do
        local e = HR.Nearest(g, pl.x, pl.y, skip)
        if not e then break end
        skip[e] = true
        HR.Hit(g, e, dmg * (pair and 1.5 or 1), "slots")
        g.zones[#g.zones + 1] = { side = "fx", shape = "circle", x = e.x, y = e.y, r = 12, dur = 0.18, warn = 0 }
    end
end

local WISHES = { { dmg = 0.25 }, { atk = 0.25 }, { speed = 0.2 }, { luck = 10 } }

WSTEP.well = function(g, w, dt, mult)
    mult = mult or 1
    local per = V(w, "per")
    local n = 0
    while (g.wellCount or 0) >= per and n < 3 do
        g.wellCount = g.wellCount - per
        n = n + 1
        local e = HR.Nearest(g, g.pl.x, g.pl.y)
        if e then
            HR.ShootAt(g, g.pl.x, g.pl.y, e, 250, { dmg = V(w, "dmg") * mult, wid = "well", sprite = "chip", size = 12 }, (n - 2) * 0.15)
        end
        if w.evo and g.rand.chance(0.1) then
            local wish = WISHES[g.rand.i(1, #WISHES)]
            g.buffs[#g.buffs + 1] = { dmg = wish.dmg, atk = wish.atk, speed = wish.speed, luck = wish.luck, till = g.time + 10 }
            HR.Text(g, g.pl.x, g.pl.y + 22, "Wish granted!", "ff80c0ff")
        end
    end
    if (g.wellCount or 0) > per * 6 then g.wellCount = per * 6 end
end

FIRE.shoe = function(g, w, mult)
    local pl = g.pl
    local target = HR.Nearest(g, pl.x, pl.y)
    if not target then
        w.cd = 0.3
        return
    end
    for i = 1, V(w, "n") do
        HR.ShootAt(g, pl.x, pl.y, target, 210, { dmg = V(w, "dmg") * mult, wid = "shoe", sprite = "horseshoe", pierce = 99, life = 1.7, r = 8,
            step = function(gg, s, dt)
                s.age = (s.age or 0) + dt
                if s.age > 0.65 and not s.back then
                    s.back = true
                    s.seen = {}
                end
                if s.back then
                    local a = atan2(gg.pl.y - s.y, gg.pl.x - s.x)
                    s.vx, s.vy = cos(a) * 250, sin(a) * 250
                    if dist(s.x, s.y, gg.pl.x, gg.pl.y) < 12 then s.life = 0 end
                end
            end,
            onHit = w.evo and function(gg, s, e)
                if not s.ringed then
                    s.ringed = true
                    gg.zones[#gg.zones + 1] = { side = "p", shape = "circle", x = e.x, y = e.y, r = 24 * gg.st.area, dmg = s.dmg * 0.4,
                        wid = "shoe", warn = 0, dur = 2, every = 0.3, follow = e }
                end
            end or nil }, (i - (V(w, "n") + 1) / 2) * 0.35)
    end
end

---------------------------------------------------------------------------
-- Damage over time: bleeds and burns. Each weapon keeps its own stacks on an enemy.
---------------------------------------------------------------------------
HR.DOT_EVERY = 0.5

--- Adds a stack of `dps` from weapon wid to e (up to cap stacks) and restarts its clock.
function HR.Dot(g, e, wid, dps, secs, cap, stacks)
    if e.dead or e.obj or e.immune or e.untarget then return end
    e.dots = e.dots or {}
    local d = e.dots[wid]
    if not d then
        d = { n = 0 }
        e.dots[wid] = d
    end
    d.n = min(cap or 1, d.n + (stacks or 1))
    d.dps, d.till = dps, g.time + secs
end

--- Every half second each stack does its damage (never a crit; it's the weapon's damage in the tally).
function HR.StepDots(g, dt)
    g.dotT = (g.dotT or HR.DOT_EVERY) - dt
    if g.dotT > 0 then return end
    g.dotT = HR.DOT_EVERY
    local list = g.enemies
    for i = #list, 1, -1 do
        local e = list[i]
        if g.enemies ~= list then return end -- (a kill ended the fight and cleared the room)
        if e and e.dots and not e.dead then
            for wid, d in pairs(e.dots) do
                if d.till <= g.time then
                    e.dots[wid] = nil
                else
                    HR.Hit(g, e, d.dps * d.n * HR.DOT_EVERY, wid, { exact = true, noLucky = true })
                    if e.dead or g.enemies ~= list then break end
                end
            end
            if not e.dead and next(e.dots) == nil then e.dots = nil end
        end
    end
end

--- Called when an enemy dies. Bloodbath: a bleeding one passes its bleed to three more.
function HR.DotDeath(g, e)
    local d = e.dots and e.dots.blade
    local w = d and d.till > g.time and HR.FindWeapon(g, "blade")
    if not (w and w.evo) then return end
    local skip = { [e] = true }
    for _ = 1, 3 do
        local o = HR.Nearest(g, e.x, e.y, skip, 90)
        if not o then break end
        skip[o] = true
        HR.Dot(g, o, "blade", d.dps, 4, V(w, "stacks"), d.n)
    end
end

FIRE.blade = function(g, w, mult)
    local pl = g.pl
    local skip, any = {}, false
    local dps, cap = V(w, "bleed") * mult, V(w, "stacks")
    for _ = 1, V(w, "n") do
        local t = HR.Nearest(g, pl.x, pl.y, skip)
        if not t then break end
        skip[t], any = true, true
        HR.ShootAt(g, pl.x, pl.y, t, 280, { dmg = V(w, "dmg") * mult, wid = "blade", sprite = "knife", size = 15,
            onHit = function(gg, s, e) HR.Dot(gg, e, "blade", dps, 4, cap) end })
    end
    if not any then w.cd = 0.2 end
end

FIRE.molotov = function(g, w, mult)
    local pl, st = g.pl, g.st
    local skip, any = {}, false
    local slow = HR.CharmMax(g, "chalk")
    for _ = 1, V(w, "n") do
        local t = HR.Nearest(g, pl.x, pl.y, skip, 260)
        if not t then break end
        skip[t], any = true, true
        g.zones[#g.zones + 1] = { side = "p", shape = "circle", x = t.x, y = t.y, r = V(w, "r") * st.area, dmg = V(w, "dmg") * mult,
            wid = "molotov", warn = 0, dur = V(w, "dur"), every = 0.4, tick = 0, fire = true, slow = slow or nil,
            -- Wildfire: they keep burning once they're out of it
            dot = w.evo and V(w, "dmg") * mult * 2 or nil }
    end
    if not any then w.cd = 0.3 end
end

---------------------------------------------------------------------------
-- Hearts
---------------------------------------------------------------------------
FIRE.edge = function(g, w, mult)
    local pl, st = g.pl, g.st
    local r = V(w, "r") * st.area
    local slow = HR.CharmMax(g, "chalk")
    for _, e in ipairs(g.enemies) do
        if not e.dead and not e.untarget and dist(pl.x, pl.y, e.x, e.y) <= r + e.r then
            HR.Hit(g, e, V(w, "dmg") * mult, "edge", { noLucky = true })
            if slow and not e.boss then e.slow = max(e.slow or 0, 0.7) end
        end
    end
    g.auraR = r
end

WSTEP.piggy = function(g, w, dt, mult)
    mult = mult or 1
    local pl = g.pl
    local pig = g.pig
    if not pig then
        pig = { x = pl.x - 20, y = pl.y, full = 0 }
        g.pig = pig
    end
    -- trots after you
    local d = dist(pig.x, pig.y, pl.x, pl.y)
    if d > 34 then
        local sp = min(d * 3, 200)
        pig.x, pig.y = pig.x + (pl.x - pig.x) / d * sp * dt, pig.y + (pl.y - pig.y) / d * sp * dt
    end
    for _, p in ipairs(g.pickups) do
        if p.kind == "chip" and not p.gone and dist(pig.x, pig.y, p.x, p.y) <= 38 then
            p.gone = true
            pig.full = pig.full + p.v
            HR.AddChips(g, p.v, true)
            g.wellCount = (g.wellCount or 0) + p.v
        end
    end
    if pig.full >= V(w, "per") then
        pig.full = 0
        HR.Blast(g, pig.x, pig.y, HR.WEAPON.piggy.r * g.st.area, V(w, "dmg") * mult, "piggy")
        if w.evo then HR.DropPickup(g, { kind = "heart", x = pig.x, y = pig.y, v = 8 }) end
        HR.Event(g, "coin")
    end
end

---------------------------------------------------------------------------
-- The Wild Card: your best other weapon again, weaker
---------------------------------------------------------------------------
local function WildSource(g)
    local best
    for _, w in ipairs(g.weapons) do
        if w.id ~= "wild" and (not best or w.lvl > best.lvl) then best = w end
    end
    return best
end

--- What the Wild Card is copying, and whether that weapon has an attack to copy (the orbiting,
--- aura and chip weapons don't: it throws a plain card in their name instead).
function HR.WildSource(g)
    local src = WildSource(g)
    if not src then return nil end
    return src, FIRE[src.id] ~= nil and src.id ~= "edge"
end

WSTEP.wild = function(g, w, dt)
    local src = WildSource(g)
    if not src then return end
    local mult = w.evo and 1 or V(w, "mult")
    w.wcd = (w.wcd or 0.6) - dt
    if w.wcd > 0 then return end
    local fire = FIRE[src.id]
    w.wcd = (HR.WVal(src, "cd") or 1.2) / max(0.2, g.st.atk)
    if fire and src.id ~= "edge" then
        fire(g, src, mult)
    else
        -- orbit, aura and chip weapons have nothing to "fire": a plain card in their name
        local e = HR.Nearest(g, g.pl.x, g.pl.y)
        w.wcd = 1.0 / max(0.2, g.st.atk)
        if e then
            HR.ShootAt(g, g.pl.x, g.pl.y, e, 230, { dmg = (HR.WVal(src, "dmg") or 8) * mult * 1.5, wid = "wild", sprite = "suit_j" })
        end
    end
end
