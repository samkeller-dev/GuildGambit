-- Roller/Weapons.lua: what each High Roller weapon does when it fires (HR.FIRE) or every step
-- (HR.WSTEP). mult scales damage: 1 normally, less for the Wild Card's copy.
local ADDON_NAME, ns = ...
local HR = ns.Roller
local FIRE, WSTEP = HR.FIRE, HR.WSTEP
local sqrt, floor, min, max, cos, sin, atan2, pi = math.sqrt, math.floor, math.min, math.max, math.cos, math.sin, math.atan2, math.pi
local dist, clamp = HR.dist, HR.clamp

local function V(w, f) return HR.WVal(w, f) end

---------------------------------------------------------------------------
-- Dicemaster: Bone Dice
---------------------------------------------------------------------------
local function FloorDie(g, s)
    if g.class ~= "dice" or s.noFloor then return end
    local n = 0
    for _, p in ipairs(g.pickups) do if p.kind == "die" then n = n + 1 end end
    if n >= 6 then return end
    HR.DropPickup(g, { kind = "die", x = s.x, y = s.y, face = s.face, life = 4 + 2 * HR.T(g, "dr3") })
end

local function ThrowDie(g, w, face, target, mult, spread, extra)
    local pl = g.pl
    local s = { dmg = face * V(w, "dmg") * mult, wid = "bonedice", exact = true, face = face, sprite = "die" .. face,
        bounce = V(w, "bounce"), canBounce = true, seekAll = HR.T(g, "dr2") > 0,
        perBounce = 0.08 * HR.T(g, "dr4") + (HR.CharmMax(g, "marbles") and 0.1 or 0), maxRoll = face == 6, onEnd = FloorDie }
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
    -- Avalanche: splits in two on the last bounce
    if HR.T(g, "dr5") > 0 and not (extra and extra.child) then
        s.onLast = function(gg, shot)
            local e = HR.Nearest(gg, shot.x, shot.y, shot.seen, 160)
            if e then
                ThrowDie(gg, w, shot.face, e, mult * 0.6, 0, { x0 = shot.x, y0 = shot.y, child = true, noFloor = true, bounce = 0, canBounce = false })
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
    local bonus = 1
    if kind == "double" or kind == "triple" then bonus = 1 + 0.15 * HR.T(g, "dl2") end
    if kind == "snake" then
        if HR.Relic(g, "martingale") then g.mgHit = true end
        if HR.T(g, "dl4") > 0 then
            HR.Blast(g, pl.x, pl.y, 44 * g.st.area, 8 * V(w, "dmg") * mult, "bonedice")
            HR.Text(g, pl.x, pl.y + 20, "Snake eyes - boom", "ffff8040")
        else
            HR.Text(g, pl.x, pl.y + 20, "Snake eyes", "ffaaaaaa")
        end
        g.diceChain = 0
        return
    end
    for i, f in ipairs(faces) do
        ThrowDie(g, w, f, target, mult * bonus, (i - (#faces + 1) / 2) * 0.16)
    end
    if kind == "triple" then
        HR.Blast(g, target.x, target.y, 70 * g.st.area, faces[1] * V(w, "dmg") * 4 * mult, "bonedice", { exact = true })
        HR.Text(g, pl.x, pl.y + 22, "TRIPLE " .. faces[1] .. "s!", "ffffd100")
        HR.Earned(g, "triple")
        HR.Event(g, "jackpot")
        if faces[1] == 6 then HR.Taunt(g, "jackpot") end
    end
    local chains = kind == "double" or (kind == "triple" and HR.CharmMax(g, "shaved"))
    local cap = V(w, "chain") + HR.T(g, "dl3")
    if chains and (g.diceChain or 0) < cap and mult >= 1 then
        g.diceChain = (g.diceChain or 0) + 1
        g.bestChain = max(g.bestChain or 0, g.diceChain)
        HR.Text(g, pl.x, pl.y + 20, kind == "double" and ("Doubles! x" .. g.diceChain) or "Again!", "ffffd100")
        HR.Event(g, "roll")
        -- a free throw, a moment later (double sixes with Sixes Wild: two)
        g.freeThrows = (g.freeThrows or 0) + ((faces[1] == 6 and faces[2] == 6 and HR.T(g, "dl5") > 0) and 2 or 1)
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
-- Card Sharp: Flick
---------------------------------------------------------------------------
FIRE.flick = function(g, w, mult)
    local pl = g.pl
    local target = HR.Nearest(g, pl.x, pl.y)
    if not target then
        w.cd = 0.2
        return
    end
    local n = V(w, "n")
    local slow = HR.T(g, "cs2")
    for i = 1, n do
        HR.ShootAt(g, pl.x, pl.y, target, 230, { dmg = V(w, "dmg") * mult, wid = "flick", sprite = "card", pierce = V(w, "pierce"),
            onHit = slow > 0 and function(gg, s, e) if not e.boss then e.slow = max(e.slow or 0, 0.75 * slow) end end or nil },
            (i - (n + 1) / 2) * 0.2)
    end
end

---------------------------------------------------------------------------
-- Coin Flipper: Trick Coin
---------------------------------------------------------------------------
FIRE.trickcoin = function(g, w, mult)
    local pl, c = g.pl, g.coin
    local target = HR.Nearest(g, pl.x, pl.y)
    if not target then
        w.cd = 0.2
        return
    end
    local heads = c and c.side == "H"
    local boom = (heads and c.streak >= 5) and HR.T(g, "oh4") or 0
    local skip = {}
    for i = 1, V(w, "n") do
        local t = HR.Nearest(g, pl.x, pl.y, skip) or target
        skip[t] = true
        HR.ShootAt(g, pl.x, pl.y, t, 240, { dmg = V(w, "dmg") * mult, wid = "trickcoin", sprite = "tcoin", canBounce = true,
            bounce = V(w, "bounce") + (heads and (1 + HR.T(g, "oh2")) or 0),
            perBounce = HR.CharmMax(g, "marbles") and 0.1 or 0,
            onHit = boom > 0 and function(gg, s, e) HR.Blast(gg, e.x, e.y, (15 + 15 * boom) * gg.st.area, s.dmg * 0.5, "trickcoin", { quiet = true }) end or nil })
    end
end

---------------------------------------------------------------------------
-- Orbiting weapons (8-Ball, Lucky Clover, the Coin Flipper's Tails coins)
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
        end, HR.T(g, "ot2") > 0 and function() end or nil)
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
    local pl = g.pl
    for i = 1, V(w, "n") do
        local fromLeft = g.rand.chance(0.5)
        local y = pl.y + g.rand.i(-90, 90)
        HR.Shoot(g, { x = fromLeft and (g.camX - 10) or (g.camX + HR.VIEW_W + 10), y = y, vx = fromLeft and 230 or -230, vy = 0,
            dmg = V(w, "dmg") * mult, wid = "cat", sprite = "cat", pierce = 99, r = 12, size = 22, life = 2.2, flip = not fromLeft,
            onHit = function(gg, s, e) HR.Jinx(gg, e) end })
    end
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
