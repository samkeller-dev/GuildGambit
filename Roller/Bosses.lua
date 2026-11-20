-- Roller/Bosses.lua: High Roller's five bosses. Each has one mechanic solved by where you
-- stand, and attacks that are drawn on the floor before they land (HR.Danger).
--
-- A boss is an entry in g.enemies (boss = true) plus g.boss = { update = fn, ... } for the
-- fight's own state. The arena is exactly one screen: (0,0) to (VIEW_W, VIEW_H).
local ADDON_NAME, ns = ...
local HR = ns.Roller
local BOSS = HR.BOSS
local sqrt, floor, min, max, cos, sin, atan2, pi = math.sqrt, math.floor, math.min, math.max, math.cos, math.sin, math.atan2, math.pi
local dist, clamp = HR.dist, HR.clamp
local W, H = HR.VIEW_W, HR.VIEW_H

local function BossDmg(g) return HR.ROOM_DMG[g.diff] * 1.4 end

--- Adds the boss itself.
local function AddBoss(g, id, x, y, hp, extra)
    local def = HR.BOSSES[id]
    local e = { kind = id, boss = true, x = x, y = y, r = 22, size = 64, sprite = def.sprite, hp = hp, maxhp = hp,
        dmg = BossDmg(g), xp = 0, t = 0, stun = 0, slow = 0, jinx = 0, oh = {}, def = { name = def.name, heavy = true },
        step = function() end }
    if extra then for k, v in pairs(extra) do e[k] = v end end
    g.enemies[#g.enemies + 1] = e
    return e
end

local function AddPart(g, sprite, x, y, extra)
    local e = { kind = sprite, obj = sprite, x = x, y = y, r = 10, size = 26, sprite = sprite, hp = 1, maxhp = 1, dmg = 0, xp = 0,
        t = 0, stun = 0, slow = 0, jinx = 0, oh = {}, def = { name = sprite, heavy = true }, step = function() end }
    if extra then for k, v in pairs(extra) do e[k] = v end end
    g.enemies[#g.enemies + 1] = e
    return e
end

--- How much faster a boss attacks: phase 2 at half health, impatience after 45 seconds, and a
--- third phase at Stakes 2.
local function Tempo(g, frac)
    local t = 1
    if frac < 0.5 then t = t * 0.8 end
    if (g.bossTime or 0) > 45 then t = t * 0.7 end
    if (g.stakes or 0) >= 2 and frac < 0.25 then t = t * 0.7 end
    return t
end

local function Rings(g, x, y, dmg, first, gap)
    HR.Danger(g, { shape = "circle", x = x, y = y, r = 70, warn = first, dmg = dmg, name = "a slam" })
    HR.Danger(g, { shape = "ring", x = x, y = y, r1 = 70, r2 = 145, warn = first + gap, dmg = dmg, name = "a slam" })
    HR.Danger(g, { shape = "ring", x = x, y = y, r1 = 145, r2 = 240, warn = first + gap * 2, dmg = dmg, name = "a slam" })
end

local function RandomCircles(g, n, r, warn, dmg, aimed)
    for i = 1, n do
        local x, y = g.rand.i(30, W - 30), g.rand.i(30, H - 60)
        if i <= (aimed or 0) then x, y = g.pl.x + g.rand.i(-18, 18), g.pl.y + g.rand.i(-18, 18) end
        HR.Danger(g, { shape = "circle", x = x, y = y, r = r, warn = warn + i * 0.08, dmg = dmg })
    end
end

---------------------------------------------------------------------------
-- 1. The Pit Boss: only his own charge breaks the rope posts that protect him
---------------------------------------------------------------------------
BOSS.pit = { start = function(g)
    local b = AddBoss(g, "pit", W / 2, 330, HR.BossHp(g, "pit"), { immune = true })
    local posts = {}
    for i, p in ipairs({ { 80, 215 }, { W - 80, 215 }, { W / 2, 130 } }) do
        posts[i] = AddPart(g, "post", p[1], p[2], { untarget = true })
    end
    local st = { b = b, posts = posts, cd = 1.6, left = 3 }
    g.bossText = "Rope posts: 3  -  make him charge into them"
    local function breakPost(p)
        if p.dead then return end
        p.dead = true
        st.left = st.left - 1
        HR.Text(g, p.x, p.y + 14, "CRACK!", "ffffd100")
        HR.Event(g, "roll")
        if st.left <= 0 then
            b.immune = nil
            b.stun = 4
            g.bossText = "The rope is down - he's open!"
            HR.Banner(g, "|cff20ff20The rope is down!|r", 2.5)
        else
            g.bossText = ("Rope posts: %d  -  make him charge into them"):format(st.left)
        end
    end
    st.update = function(gg, s, dt)
        if b.dead then return end
        local frac = b.hp / b.maxhp
        -- a fight that drags: the posts give way on their own, one at a time
        if st.left > 0 and gg.bossTime > 55 then
            st.fray = (st.fray or 8) - dt
            if st.fray <= 0 then
                st.fray = 8
                for _, p in ipairs(posts) do if not p.dead then breakPost(p) break end end
            end
        end
        if (b.stun or 0) > 0 then return end
        st.cd = st.cd - dt
        if st.cd > 0 then return end
        st.cd = 2.7 * Tempo(gg, frac)
        local pl = gg.pl
        local roll = gg.rand.f()
        if frac < 0.5 and roll < 0.25 then
            -- Last Call: everywhere but the gold tiles
            local safe = {}
            for i = 1, 3 do safe[i] = { x = gg.rand.i(50, W - 50), y = gg.rand.i(50, H - 110), r = 36 } end
            HR.Danger(gg, { shape = "circles", list = safe, invert = true, warn = 2.0, dmg = BossDmg(gg) * 1.4, name = "Last Call" })
            st.cd = st.cd + 1.2
        elseif roll < 0.68 or st.left > 0 and roll < 0.8 then
            -- Charge: a lane through you to the wall; he ends up at the far end
            local a = atan2(pl.y - b.y, pl.x - b.x)
            -- (where that line meets the wall, so the lane keeps its direction)
            local ca, sa, far = cos(a), sin(a), 2000
            if ca > 0.001 then far = min(far, (W - 24 - b.x) / ca) elseif ca < -0.001 then far = min(far, (24 - b.x) / ca) end
            if sa > 0.001 then far = min(far, (H - 24 - b.y) / sa) elseif sa < -0.001 then far = min(far, (24 - b.y) / sa) end
            far = max(0, far)
            local x2, y2 = clamp(b.x + ca * far, 24, W - 24), clamp(b.y + sa * far, 24, H - 24)
            HR.Danger(gg, { shape = "lane", x1 = b.x, y1 = b.y, x2 = x2, y2 = y2, w = 24, warn = 1.0, dmg = BossDmg(gg) * 1.3, name = "a charge",
                onFire = function(g2, z)
                    for _, p in ipairs(posts) do
                        if not p.dead and HR.InShape({ shape = "lane", x1 = z.x1, y1 = z.y1, x2 = z.x2, y2 = z.y2, w = z.w + 12 }, p.x, p.y) then
                            breakPost(p)
                        end
                    end
                    b.x, b.y = z.x2, z.y2
                end })
        else
            Rings(gg, b.x, b.y, BossDmg(gg), 0.9, 0.5)
        end
    end
    b.onDeath = function(gg) HR.BossDown(gg) end
    g.boss = st
end }

---------------------------------------------------------------------------
-- 2. The Dealer: blackjack by where you stand. Left half deals you cards, right half stands.
---------------------------------------------------------------------------
local function DealerTotal(g)
    return ({ 17, 17, 17, 18, 18, 18, 19, 19, 19, 20, 20, 21 })[g.rand.i(1, 12)]
end

BOSS.dealer = { start = function(g)
    local b = AddBoss(g, "dealer", W / 2, 370, HR.BossHp(g, "dealer"), { dr = 0.8 })
    local st = { b = b, cd = 2.2, dealer = DealerTotal(g), total = 0, cards = 0, aces = 0, drawT = 1.5, standT = 0 }
    g.zones[#g.zones + 1] = { side = "deco", shape = "rect", x1 = 0, y1 = 0, x2 = W / 2, y2 = H, warn = 0, dur = 9999, tint = "hit" }
    g.zones[#g.zones + 1] = { side = "deco", shape = "rect", x1 = W / 2, y1 = 0, x2 = W, y2 = H, warn = 0, dur = 9999, tint = "stand" }
    g.zones[#g.zones + 1] = { side = "deco", shape = "rect", x1 = W / 2 - 1, y1 = 0, x2 = W / 2 + 1, y2 = H, warn = 0, dur = 9999, tint = "line" }
    g.labels = { { x = W * 0.25, y = 150, text = "HIT" }, { x = W * 0.75, y = 150, text = "STAND" } }
    local function show()
        g.bossText = ("You: |cffffffff%d|r     Dealer: |cffffffff%d|r     left = hit, right = stand"):format(st.total, st.dealer)
    end
    local function newRound()
        st.dealer, st.total, st.cards, st.aces, st.drawT, st.standT = DealerTotal(g), 0, 0, 0, 1.5, 0
        show()
    end
    show()
    st.update = function(gg, s, dt)
        if b.dead then return end
        local pl = gg.pl
        local frac = b.hp / b.maxhp
        if st.open then
            -- she lost the hand: wide open for a few seconds
            st.open = st.open - dt
            if st.open <= 0 then
                st.open, b.dr = nil, 0.8
                newRound()
            end
            return
        end
        if pl.x < W / 2 then
            st.standT = 0
            st.drawT = st.drawT - dt
            if st.drawT <= 0 then
                st.drawT = 2
                local r = gg.rand.i(2, 14)
                local v = r >= 14 and 11 or (r >= 11 and 10 or r)
                if v == 11 then st.aces = st.aces + 1 end
                st.total, st.cards = st.total + v, st.cards + 1
                while st.total > 21 and st.aces > 0 do st.total, st.aces = st.total - 10, st.aces - 1 end
                HR.Text(gg, pl.x, pl.y + 20, (HR.RANK_TEXT[r] or tostring(r)) .. "  = " .. st.total, "ffffffff")
                HR.Event(gg, "card")
                show()
                if st.total > 21 then
                    gg.bjBust = true
                    HR.Banner(gg, "|cffff4040Bust!|r", 2)
                    HR.Danger(gg, { shape = "rect", x1 = 0, y1 = 0, x2 = W / 2, y2 = H, warn = 1.0, dmg = BossDmg(gg) * 1.6, name = "a bust" })
                    newRound()
                end
            end
        elseif st.cards > 0 then
            st.standT = st.standT + dt
            if st.standT >= 1.2 then
                if st.total > st.dealer then
                    st.open, b.dr, b.stun = 6, 0, 6
                    gg.bossText = "|cff20ff20You win the hand - she's open!|r"
                    HR.Banner(gg, ("|cff20ff20%d beats %d!|r"):format(st.total, st.dealer), 2.5)
                    HR.Event(gg, "win")
                else
                    HR.Banner(gg, ("|cffff8040%d doesn't beat %d.|r"):format(st.total, st.dealer), 2)
                    HR.Danger(gg, { shape = "rect", x1 = W / 2, y1 = 0, x2 = W, y2 = H, warn = 1.0, dmg = BossDmg(gg) * 1.4, name = "the house hand" })
                    newRound()
                end
            end
        end
        st.cd = st.cd - dt
        if st.cd > 0 then return end
        st.cd = 3.1 * Tempo(gg, frac)
        if gg.rand.chance(0.5) then
            -- Shuffle: card lines across the table; step between them
            local y0 = gg.rand.i(60, 140)
            for i = 0, 2 do
                local y = y0 + i * 105
                HR.Danger(gg, { shape = "lane", x1 = 0, y1 = y, x2 = W, y2 = y, w = 15, warn = 1.0 + i * 0.25, dmg = BossDmg(gg), name = "the shuffle" })
            end
        else
            -- 52 Pickup: shadows where the cards will land (in phase 2, more of them on the Hit half)
            local n = frac < 0.5 and 7 or 5
            for i = 1, n do
                local x, y = gg.rand.i(30, W - 30), gg.rand.i(30, H - 90)
                if i <= 2 then x, y = pl.x + gg.rand.i(-16, 16), pl.y + gg.rand.i(-16, 16)
                elseif frac < 0.5 and i <= 5 then x = gg.rand.i(30, W / 2 - 20) end
                HR.Danger(gg, { shape = "circle", x = x, y = y, r = 30, warn = 1.1 + i * 0.07, dmg = BossDmg(gg), name = "52 Pickup" })
            end
        end
    end
    b.onDeath = function(gg) HR.BossDown(gg) end
    g.boss = st
end }

---------------------------------------------------------------------------
-- 3. Snake Eyes: two serpents; one alone revives the other
---------------------------------------------------------------------------
BOSS.snakes = { start = function(g)
    local hp = HR.BossHp(g, "snakes") / 2
    local st = { cd = 2.0, a = 0, beamT = 9 }
    local cx, cy, rad = W / 2, 250, 125
    local snakes = {}
    for i = 1, 2 do
        local e = AddBoss(g, "snakes", cx, cy, hp, { size = 52, r = 18 })
        e.onZero = function(gg, me)
            local other = snakes[3 - i]
            if other.down then
                -- both down together: that's the kill
                me.dead, other.dead = true, true
                HR.BossDown(gg)
                return true
            end
            me.down, me.immune, me.hp, me.untarget = 5, true, 1, true
            HR.Text(gg, me.x, me.y + 24, "Down! 5s to drop the other", "ffffd100")
            return true
        end
        snakes[i] = e
    end
    st.snakes = snakes
    g.bossText = "Bring both down within 5 seconds of each other"
    st.update = function(gg, s, dt)
        st.a = st.a + 0.45 * dt
        local total, maxTotal = 0, 0
        for i, e in ipairs(snakes) do
            local a = st.a + (i - 1) * pi
            e.x, e.y = cx + cos(a) * rad, cy + sin(a) * rad * 0.8
            maxTotal = maxTotal + e.maxhp
            if e.down then
                e.down = e.down - dt
                if e.down <= 0 then
                    -- the other one outlived the window: back it comes
                    e.down, e.immune, e.untarget = nil, nil, nil
                    e.hp = e.maxhp * 0.4
                    HR.Text(gg, e.x, e.y + 24, "Revived!", "ffff8040")
                end
            else
                total = total + e.hp
            end
        end
        local frac = total / maxTotal
        local up = {}
        for _, e in ipairs(snakes) do if not e.down and (e.stun or 0) <= 0 then up[#up + 1] = e end end
        if #up == 0 then return end
        local pl = gg.pl
        st.cd = st.cd - dt
        if st.cd <= 0 then
            st.cd = 2.8 * Tempo(gg, frac)
            local e = up[gg.rand.i(1, #up)]
            if gg.rand.chance(0.55) then
                -- Tail Sweep: a wide area on the side facing you
                local a = atan2(pl.y - e.y, pl.x - e.x)
                HR.Danger(gg, { shape = "circle", x = e.x + cos(a) * 62, y = e.y + sin(a) * 62, r = 78, warn = 0.9, dmg = BossDmg(gg) * 1.2, name = "a tail sweep" })
            else
                -- Venom: a pool where you stand, and it stays
                HR.Danger(gg, { shape = "circle", x = pl.x, y = pl.y, r = 32, warn = 0.8, dur = 10, dmg = BossDmg(gg) * 0.7, name = "venom" })
            end
        end
        if frac < 0.5 then
            -- Snake Eyes: two beams through the middle that turn; move with the gap
            st.beamT = st.beamT - dt
            if st.beamT <= 0 then
                st.beamT = 13
                local a0 = gg.rand.f() * pi
                for k = 0, 1 do
                    local z = { shape = "lane", w = 13, warn = 1.5, dur = 6, dmg = BossDmg(gg), name = "the beams", ang = a0 + k * pi / 2 }
                    z.step = function(g2, zz, d)
                        if zz.warn <= 0 then zz.ang = zz.ang + 0.42 * d end
                        zz.x1, zz.y1 = cx - cos(zz.ang) * 420, cy - sin(zz.ang) * 420
                        zz.x2, zz.y2 = cx + cos(zz.ang) * 420, cy + sin(zz.ang) * 420
                    end
                    z.step(gg, z, 0)
                    HR.Danger(gg, z)
                end
            end
        end
    end
    g.boss = st
end }

---------------------------------------------------------------------------
-- 4. Madame Fortune: her wheel shows what's coming; standing near it lets your weapons nudge it
---------------------------------------------------------------------------
local SLOTS = { "ring", "prophecy", "circles", "bankrupt", "ring", "prophecy", "circles", "jackpot" }
local SLOT_NAME = { ring = "Fortune's Ring", prophecy = "Prophecy", circles = "Falling Stars", bankrupt = "|cffff4040BANKRUPT|r", jackpot = "|cff20ff20JACKPOT|r" }

BOSS.fortune = { start = function(g)
    local b = AddBoss(g, "fortune", W / 2, 385, HR.BossHp(g, "fortune"))
    local st = { b = b, spin = 4, idx = 1, want = 1, pause = 0, nudgeAt = -9 }
    local wheel = AddPart(g, "wheel", W / 2, 245, { size = 54, r = 22 })
    local function pickWant()
        if g.rand.chance(0.3) then st.want = 4
        else st.want = ({ 1, 2, 3, 5, 6, 7 })[g.rand.i(1, 6)] end
        st.idx, st.spin = st.want, 4
    end
    local function show()
        g.bossText = ("The wheel is heading for %s  -  stand by it to nudge it on"):format(SLOT_NAME[SLOTS[st.idx]])
    end
    wheel.onHit = function(gg, me)
        -- hits on the wheel move it one slot (at most twice a second); they do no damage
        if st.spin > 0 and gg.time - st.nudgeAt >= 0.5 and dist(gg.pl.x, gg.pl.y, me.x, me.y) < 110 then
            st.nudgeAt = gg.time
            st.idx = st.idx % #SLOTS + 1
            show()
            HR.Event(gg, "roll")
        end
        return true
    end
    st.wheel = wheel
    pickWant()
    show()
    st.update = function(gg, s, dt)
        if b.dead then return end
        local frac = b.hp / b.maxhp
        local pl = gg.pl
        wheel.rot = (wheel.rot or 0) + dt * (st.spin > 0 and (0.5 + st.spin) or 0)
        if (b.stun or 0) > 0 then return end
        if st.pause > 0 then
            st.pause = st.pause - dt
            if st.pause <= 0 then pickWant() show() end
            return
        end
        st.spin = st.spin - dt * (1 / Tempo(gg, frac))
        if st.spin > 0 then return end
        local slot = SLOTS[st.idx]
        local dmg = BossDmg(gg)
        if slot == "ring" then
            HR.Danger(gg, { shape = "ring", x = W / 2, y = 215, r1 = 62, r2 = 125, invert = true, warn = 1.6, dmg = dmg * 1.3, name = "Fortune's Ring" })
        elseif slot == "prophecy" then
            for i = 0, 2 do
                HR.Danger(gg, { shape = "circle", x = clamp(pl.x + (pl.vx or 0) * (1.0 + i * 0.5), 20, W - 20),
                    y = clamp(pl.y + (pl.vy or 0) * (1.0 + i * 0.5), 20, H - 20), r = 40, warn = 1.2 + i * 0.5, dmg = dmg, name = "a prophecy" })
            end
        elseif slot == "circles" then
            RandomCircles(gg, 6, 34, 1.1, dmg, 2)
        elseif slot == "bankrupt" then
            HR.Danger(gg, { shape = "circle", x = b.x, y = b.y - 55, r = 62, invert = true, warn = 2.1, dmg = dmg * 1.8, name = "Bankrupt" })
        else
            b.stun = 5
            HR.AddChips(gg, 100)
            HR.Banner(gg, "|cff20ff20JACKPOT! She's stunned.|r", 3)
            HR.Event(gg, "bigwin")
        end
        -- Evil Eye: the wheel landed where she wanted it
        if frac < 0.5 and st.idx == st.want and slot ~= "jackpot" then
            local took = HR.Relic(gg, "ladyluck") and 0 or min(5, gg.luck)
            if took > 0 then
                gg.luck = gg.luck - took
                HR.Text(gg, pl.x, pl.y + 22, ("-%d Luck"):format(took), "ffc060ff")
                HR.Recalc(gg)
            end
        end
        st.pause = 2.4
        g.bossText = SLOT_NAME[slot] .. "!"
    end
    b.onDeath = function(gg) HR.BossDown(gg) end
    g.boss = st
end }

---------------------------------------------------------------------------
-- 5. The House: drains your Luck until you break its pillars, and plays your best weapon back
---------------------------------------------------------------------------
BOSS.house = { start = function(g)
    local hp = HR.BossHp(g, "house")
    local b = AddBoss(g, "house", W / 2, 388, hp)
    local st = { b = b, cd = 2.0, t = 0, pillars = 4, shrinkT = 8, shrunk = 0 }
    local spots = { { 46, 70, "S" }, { W - 46, 70, "H" }, { 46, 300, "D" }, { W - 46, 300, "C" } }
    for _, p in ipairs(spots) do
        local e = AddPart(g, "pillar", p[1], p[2], { hp = hp * 0.07, maxhp = hp * 0.07, suit = p[3], r = 12, size = 30 })
        e.onDeath = function(gg)
            st.pillars = st.pillars - 1
            HR.Text(gg, e.x, e.y + 20, "Luck returns!", "ff20ff20")
            HR.Event(gg, "win")
        end
    end
    local function topWeapon()
        local best
        for _, w in ipairs(g.weapons) do if not best or w.lvl > best.lvl then best = w end end
        return best
    end
    st.update = function(gg, s, dt)
        if b.dead then return end
        local frac = b.hp / b.maxhp
        local pl = gg.pl
        st.t = st.t + dt
        -- House Rules: your Luck drains away; each pillar broken gives a quarter back
        gg.luckDrain = min(1, st.t / 25) * (st.pillars / 4)
        gg.bossText = st.pillars > 0 and ("The House has %d%% of your Luck  -  break the pillars"):format(floor(gg.luckDrain * 100 + 0.5))
            or "Your Luck is yours again"
        -- Table Collapse: the edges fall away
        if frac < 0.5 and st.shrunk < 3 then
            st.shrinkT = st.shrinkT - dt
            if st.shrinkT <= 0 then
                st.shrinkT, st.shrunk = 9, st.shrunk + 1
                local m = 22 * st.shrunk
                gg.bounds = { m, m, W - m, H - m * 0.5 }
                HR.Banner(gg, "|cffff8040The table is collapsing.|r", 2)
            end
        end
        -- Final Hand, once: five cards fall and one spot is safe
        if frac < 0.25 and not st.final then
            st.final = true
            local safe = gg.rand.i(1, 5)
            local known = st.pillars <= 2
            local list = {}
            for i = 1, 5 do
                local x, y = 40 + (i - 1) * (W - 80) / 4, 190
                if i ~= safe then list[#list + 1] = { x = x, y = y, r = 44 }
                else gg.zones[#gg.zones + 1] = { side = "deco", shape = "circle", x = x, y = y, r = 30, warn = 0, dur = known and 2.4 or 1.0, tint = "safe" } end
            end
            -- everywhere on the table except the safe spot
            HR.Danger(gg, { shape = "circle", x = 40 + (safe - 1) * (W - 80) / 4, y = 190, r = 32, invert = true, warn = known and 2.4 or 1.5,
                dmg = BossDmg(gg) * 2, name = "the Final Hand" })
            HR.Banner(gg, "|cffffd100The Final Hand.|r Find the safe spot.", 2.5)
            st.cd = 3
            return
        end
        if (b.stun or 0) > 0 then return end
        st.cd = st.cd - dt
        if st.cd > 0 then return end
        st.cd = 2.6 * Tempo(gg, frac)
        local roll = gg.rand.f()
        local dmg = BossDmg(gg)
        if roll < 0.35 then
            Rings(gg, W / 2, 300, dmg, 0.8, 0.4)
        elseif roll < 0.7 then
            -- The House matches: your best weapon, played back at you
            local w = topWeapon()
            local name = w and (w.evo and HR.WEAPON[w.id].evo.name or HR.WEAPON[w.id].name) or "hand"
            HR.Banner(gg, "The House plays your |cffffd100" .. name .. "|r.", 2)
            local n = 4 + (w and w.lvl or 1)
            local a0 = atan2(pl.y - b.y, pl.x - b.x)
            HR.Danger(gg, { shape = "lane", x1 = b.x, y1 = b.y, x2 = b.x + cos(a0) * 760, y2 = b.y + sin(a0) * 760, w = 10, warn = 0.8, dmg = dmg,
                onFire = function(g2)
                    for i = 1, n do
                        if #g2.eshots < HR.CAPS.eshots then
                            local a = a0 + (i - (n + 1) / 2) * 0.16
                            g2.eshots[#g2.eshots + 1] = { x = b.x, y = b.y - 20, vx = cos(a) * 150, vy = sin(a) * 150, r = 5, dmg = dmg * 0.8, life = 4.5 }
                        end
                    end
                end })
        else
            RandomCircles(gg, 6, 32, 1.0, dmg, 2)
        end
    end
    b.onDeath = function(gg) HR.BossDown(gg) end
    g.boss = st
end }
