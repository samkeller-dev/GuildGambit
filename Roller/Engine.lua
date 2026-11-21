-- Roller/Engine.lua: High Roller's simulation - the run, the player, enemies, shots, zones,
-- pickups, level-ups, rooms, side bets and the Cashier. No drawing: Roller/UI.lua shows the
-- run table (g), and the tests drive it directly.
--
-- Positions are pixels with (0,0) at the room's bottom-left. Wave rooms are two screens each
-- way and the view follows the player; boss arenas are exactly one screen.
local ADDON_NAME, ns = ...
local HR = ns.Roller
local clamp = HR.clamp
local sqrt, floor, min, max, cos, sin, atan2, pi = math.sqrt, math.floor, math.min, math.max, math.cos, math.sin, math.atan2, math.pi

HR.FIRE, HR.WSTEP, HR.BOSS = {}, {}, {}

local function dist(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    return sqrt(dx * dx + dy * dy)
end
HR.dist = dist

---------------------------------------------------------------------------
-- Small helpers: text, banner, events (sounds and shake, for the UI)
---------------------------------------------------------------------------
function HR.Event(g, name)
    local e = g.events
    if #e < 40 then e[#e + 1] = name end
end

function HR.Text(g, x, y, text, color)
    local t = g.texts
    if #t >= HR.CAPS.texts then table.remove(t, 1) end
    t[#t + 1] = { x = x, y = y, text = text, color = color or "ffffffff", life = 0.9 }
end

function HR.Banner(g, text, secs)
    g.banner = { text = text, till = g.clock + (secs or 3) }
end

function HR.Taunt(g, kind)
    local list = HR.TAUNTS[kind]
    if list and (g.clock - (g.lastTaunt or -99) > 6 or kind == "win" or kind == "dead" or kind == "boss") then
        g.lastTaunt = g.clock
        HR.Banner(g, "|cffd0b070\"" .. list[g.rand.i(1, #list)] .. "\"|r", 3.5)
    end
end

function HR.Earned(g, ach)
    if HR.Earn(ach) then
        g.earned[#g.earned + 1] = ach
        local a = HR.ACH[ach]
        HR.Banner(g, "|cff20ff20Achievement: " .. a.name .. "|r" .. (a.gives and ("  -  unlocks " .. a.gives) or ""), 4)
        HR.Event(g, "win")
    end
end

---------------------------------------------------------------------------
-- A new run
---------------------------------------------------------------------------
--- opts: mode ("full"/"quick"), stakes, rule, seed; weapon (the tests start with another one).
function HR.NewRun(opts)
    opts = opts or {}
    local db = HR.DB()
    local class = HR.HERO
    local seed = opts.seed or math.random(1, 2147483646)
    local g = {
        seed = seed, rand = HR.NewRand(seed), class = class, mode = opts.mode or "full", stakes = opts.stakes or 0,
        time = 0, clock = 0, phase = "start", roomPos = 0, roomIdx = 1, diff = 1,
        level = 1, xp = 0, chips = 0, luck = 0, heat = 0, kills = 0, bossesBeaten = 0, betsWon = 0,
        weapons = {}, charms = {}, relics = {}, talents = {}, buffs = {}, lentSuit = {},
        enemies = {}, shots = {}, eshots = {}, zones = {}, pickups = {}, texts = {}, events = {}, labels = {},
        dmgBy = {}, earned = {}, input = { dx = 0, dy = 0 }, bounds = { 0, 0, HR.ROOM_W, HR.ROOM_H },
        pl = { x = 0, y = 0, hp = HR.PLAYER.hp, shield = 0, iframes = 0, still = 0, face = 1 },
        rerolls = 0, rabbitsUsed = 0, hand = {}, heldDice = {}, streakKills = 0, handsPlayed = 0,
        fx = {}, powers = {}, sched = {},
    }
    for id, r in pairs(HR.ClassDB(class).talents) do g.talents[id] = r end
    -- the House Rule
    if opts.rule then g.rule = opts.rule
    elseif HR.Feature("rules") then g.rule = HR.RULES[g.rand.i(1, #HR.RULES)].id
    else g.rule = "none" end
    -- room order: all five, or two of the first four and then The House
    if g.mode == "quick" then
        local a = g.rand.i(1, 4)
        local b = g.rand.i(1, 3)
        if b >= a then b = b + 1 end
        g.order = { min(a, b), max(a, b), 5 }
    else
        g.order = { 1, 2, 3, 4, 5 }
    end
    local start = HR.WEAPON[opts.weapon or ""] and opts.weapon or HR.CLASS[class].weapon
    g.weapons[1] = { id = start, lvl = 1 + (start == "revolver" and HR.T(g, "hm5") or 0), cd = 0.5 }
    if g.rule == "lucky" then g.luck = 15 end
    if (g.stakes or 0) >= 1 then g.heat = 0 end
    HR.Recalc(g)
    g.pl.hp = g.st.maxhp
    g.noSave, g.noBets, g.noExtras = opts.noSave, opts.noBets, opts.noExtras
    -- a first-timer gets a few one-line tips
    if (db.stats.runs or 0) == 0 and not opts.noTips then
        g.tips = {}
        for i, text in ipairs(HR.TIPS) do g.tips[i] = { t = ({ 1, 9, 22, 36 })[i] or (i * 12), text = text } end
    end
    HR.StartRoom(g, 1)
    if not g.tips then HR.Taunt(g, "start") end
    return g
end

---------------------------------------------------------------------------
-- Saving at the start of a room, and coming back after a reload
---------------------------------------------------------------------------
local SAVE_FIELDS = { "seed", "class", "mode", "stakes", "rule", "time", "roomPos", "level", "xp", "chips", "luck", "heat",
    "kills", "bossesBeaten", "betsWon", "rabbitsUsed", "handsPlayed", "bigHit", "bestChain", "bestHand", "twohead", "bjBust",
    "streakKills" }

function HR.Snapshot(g)
    local s = { order = g.order, weapons = {}, charms = {}, relics = {}, talents = {}, dmgBy = {}, hp = g.pl.hp }
    for _, k in ipairs(SAVE_FIELDS) do s[k] = g[k] end
    for i, w in ipairs(g.weapons) do s.weapons[i] = { id = w.id, lvl = w.lvl, evo = w.evo, aces = w.aces } end
    for k, v in pairs(g.charms) do s.charms[k] = v end
    for k, v in pairs(g.relics) do s.relics[k] = v end
    for k, v in pairs(g.talents) do s.talents[k] = v end
    for k, v in pairs(g.dmgBy) do s.dmgBy[k] = v end
    if g.coin then s.coin = { side = g.coin.side, streak = g.coin.streak, best = g.coin.best } end
    if g.boosts then
        s.boosts = {}
        for k, v in pairs(g.boosts) do s.boosts[k] = v end
    end
    return s
end

--- Rebuilds a run at the start of the room it was saved in. Returns nil if the save is no good.
function HR.Restore(s)
    if type(s) ~= "table" or s.class ~= HR.HERO or type(s.order) ~= "table" or type(s.weapons) ~= "table" then return nil end
    local g = HR.NewRun({ mode = s.mode, stakes = s.stakes, rule = s.rule or "none", seed = (s.seed or 1) + (s.roomPos or 1),
        noSave = true, noBets = true, noTips = true })
    g.noSave, g.noBets, g.menu = nil, nil, nil
    for _, k in ipairs(SAVE_FIELDS) do if s[k] ~= nil and k ~= "seed" then g[k] = s[k] end end
    g.order, g.weapons, g.charms, g.relics, g.talents, g.dmgBy = s.order, {}, {}, {}, {}, {}
    for i, w in ipairs(s.weapons) do
        if HR.WEAPON[w.id] then g.weapons[#g.weapons + 1] = { id = w.id, lvl = w.lvl or 1, evo = w.evo, aces = w.aces, cd = 0.5 } end
    end
    if #g.weapons == 0 then return nil end
    for k, v in pairs(s.charms or {}) do if HR.CHARM[k] then g.charms[k] = v end end
    for k, v in pairs(s.relics or {}) do if HR.RELIC[k] then g.relics[k] = v end end
    for k, v in pairs(s.talents or {}) do g.talents[k] = v end
    for k, v in pairs(s.dmgBy or {}) do g.dmgBy[k] = v end
    if type(s.boosts) == "table" then
        g.boosts = {}
        for k, v in pairs(s.boosts) do if HR.BOOST[k] and type(v) == "number" then g.boosts[k] = v end end
    end
    if type(s.coin) == "table" then
        local c = s.coin
        g.coin = { side = c.side == "T" and "T" or "H", streak = c.streak or 0, lost = 0, best = c.best or 0 }
    end
    HR.Recalc(g)
    g.pl.hp = clamp(s.hp or g.st.maxhp, 1, g.st.maxhp)
    g.restored = true
    HR.StartRoom(g, max(1, s.roomPos or 1), true)
    HR.Banner(g, "Back at the start of " .. HR.ROOMS[g.roomIdx].name .. ".", 4)
    return g
end

---------------------------------------------------------------------------
-- Chips, healing, damage to the player
---------------------------------------------------------------------------
function HR.HeatMult(g) return 1 + 0.1 * (g.heat or 0) end

--- fromDrop: an enemy drop (chip items apply). Returns what was added.
function HR.AddChips(g, n, fromDrop)
    n = n * HR.HeatMult(g)
    if fromDrop then
        n = n * g.st.chip
        if HR.CharmMax(g, "luckycoin") and g.rand.chance(0.1) then n = n * 2 end
    end
    g.chips = g.chips + n
    return n
end

function HR.Heal(g, n)
    local st, pl = g.st, g.pl
    if st.heal <= 0 or g.noHeal then
        -- (a real heal that did nothing: say why, so it doesn't look broken)
        if n >= 5 then HR.Text(g, pl.x, pl.y + 22, g.rule == "dry" and "No healing (Dry Spell)" or "No healing this room", "ffff8040") end
        return 0
    end
    n = n * st.heal
    local room = st.maxhp - pl.hp
    if n > room then
        if st.overheal then pl.shield = min(30, (pl.shield or 0) + (n - room)) end
        if HR.CharmMax(g, "helping") then g.buffs[#g.buffs + 1] = { dmg = 0.15, till = g.time + 5 } end
        n = room
    end
    pl.hp = pl.hp + n
    if n >= 5 then
        HR.Text(g, pl.x, pl.y + 22, ("+%d"):format(floor(n + 0.5)), "ff40ff60")
        HR.Event(g, "heal")
    end
    return n
end

function HR.Die(g)
    if g.phase == "over" then return end
    g.phase, g.menu = "over", nil
    g.summary = HR.FinishRun(g, "dead")
    HR.Taunt(g, "dead")
    HR.Event(g, "death")
end

--- Damage to the player. Returns true if it landed.
function HR.Hurt(g, dmg, why)
    local pl, st = g.pl, g.st
    if g.phase == "over" or pl.iframes > 0 or g.god then return false end
    if g.mgTaken then dmg, g.mgTaken = dmg * 2, nil end
    if HR.Relic(g, "martingale") then g.mgTaken = true end
    local blocked = min(dmg - 1, st.armor)
    if blocked > 0 then dmg = dmg - blocked end
    if (pl.shield or 0) > 0 then
        local a = min(pl.shield, dmg)
        pl.shield, dmg = pl.shield - a, dmg - a
    end
    pl.hp = pl.hp - dmg
    pl.iframes = st.iframes
    g.roomHits = (g.roomHits or 0) + 1
    g.bossHits = (g.bossHits or 0) + 1
    -- Lucky Streak ends (Hot Hand: halves)
    local sw = HR.FindWeapon(g, "streak")
    g.streakKills = (sw and sw.evo) and floor((g.streakKills or 0) / 2) or 0
    if dmg >= 15 and HR.Charm(g, "insurance") > 0 then
        g.refund = (g.refund or 0) + dmg * 0.15 * HR.Charm(g, "insurance")
    end
    HR.Text(g, pl.x, pl.y + 14, dmg >= HR.LETHAL / 2 and "CRUSHED!" or ("-%d"):format(floor(dmg + 0.5)), "ffff4040")
    HR.Event(g, "hurt")
    if pl.hp <= 0 then
        -- one save in a run, however many feet you hold (the second only makes the save heal more)
        local feet = min(1, HR.Charm(g, "rabbit")) - (g.rabbitsUsed or 0)
        local cat = HR.FindWeapon(g, "cat")
        if feet > 0 then
            g.rabbitsUsed = (g.rabbitsUsed or 0) + 1
            pl.hp = HR.CharmMax(g, "rabbit") and st.maxhp * 0.5 or 1
            pl.iframes = 2
            HR.Banner(g, "|cff20ff20Rabbit's Foot!|r You're still standing.", 3)
        elseif cat and cat.evo and not g.catLifeUsed then
            g.catLifeUsed = true
            pl.hp, pl.iframes = st.maxhp * 0.3, 2
            HR.Banner(g, "|cff20ff20Nine Lives!|r The cat took that one.", 3)
        else
            pl.hp = 0
            HR.Die(g)
            return true
        end
    elseif pl.hp < st.maxhp * 0.3 then
        HR.Taunt(g, "low")
    end
    return true
end

---------------------------------------------------------------------------
-- Enemies
---------------------------------------------------------------------------
function HR.Spawn(g, kind, x, y, extra)
    if #g.enemies >= HR.CAPS.enemies and not (extra and extra.force) then return nil end
    local def = HR.ENEMIES[kind]
    local d = g.diff
    local heat = 1 + 0.06 * (g.heat or 0)
    local e = { kind = kind, def = def, x = x, y = y, r = def.r, sprite = def.sprite, size = def.size or 26,
        hp = def.hp * 0.75 * HR.ROOM_HP[d] * heat * (1 + 0.5 * min(1, (g.roomTime or 0) / HR.WAVE_TIME)),
        -- (they hurry up as the room's clock runs down)
        speed = def.speed * (1 + 0.03 * (g.heat or 0)) * (g.rule == "fast" and 1.15 or 1) * (1 + 0.15 * min(1, (g.roomTime or 0) / HR.WAVE_TIME)),
        dmg = HR.ROOM_DMG[d], xp = def.xp * d * 0.6, t = g.rand.f() * 2, stun = 0, slow = 0, jinx = 0, oh = {} }
    if def.suited then e.suit = HR.SUITS[g.rand.i(1, 4)] end
    if def.mimic then e.asleep = true end
    if extra then for k, v in pairs(extra) do e[k] = v end end
    if e.elite then
        e.hp, e.size, e.r, e.xp, e.dmg = e.hp * 4, e.size * 1.4, e.r * 1.3, e.xp * 5, e.dmg * 1.3
        e.trait = HR.ELITE_TRAITS[g.rand.i(1, #HR.ELITE_TRAITS)]
    end
    e.maxhp = e.hp
    g.enemies[#g.enemies + 1] = e
    return e
end

--- Nearest living, hittable enemy to a point (optionally skipping some, or within a range).
function HR.Nearest(g, x, y, skip, range)
    local best, bd, soft, sd
    for _, e in ipairs(g.enemies) do
        if not e.dead and not e.untarget and not e.asleep and not (skip and skip[e]) then
            local d = dist(x, y, e.x, e.y)
            if e.soft then
                -- furniture: only a target when there's nothing else, and only close by
                if d <= 150 and (not sd or d < sd) then soft, sd = e, d end
            elseif (not range or d <= range) and (not bd or d < bd) then best, bd = e, d end
        end
    end
    if best then return best, bd end
    return soft, sd
end

function HR.InView(g, e, margin)
    margin = margin or 0
    return e.x >= g.camX - margin and e.x <= g.camX + HR.VIEW_W + margin
        and e.y >= g.camY - margin and e.y <= g.camY + HR.VIEW_H + margin
end

--- Living, hittable enemies on screen.
function HR.Visible(g)
    local out = {}
    for _, e in ipairs(g.enemies) do
        if not e.dead and not e.untarget and not e.asleep and not e.soft and HR.InView(g, e) then out[#out + 1] = e end
    end
    return out
end

function HR.Stun(g, e, secs)
    if e.dead or e.obj then return end
    if e.boss then secs = secs * 0.25
    elseif e.elite and not g.st.lockdown then return end
    if g.st.lockdown then secs = secs * 2 end
    e.stun = max(e.stun or 0, secs)
end

function HR.Jinx(g, e, strong)
    if e.dead or e.def and e.def.lucky or e.obj then return end
    e.jinx = g.st.jinxDur
    e.jinxStrong = strong or e.jinxStrong
end

function HR.DropPickup(g, p)
    local n, special = 0, 0
    for _, q in ipairs(g.pickups) do
        if q.kind == "chip" then n = n + 1 else special = special + 1 end
    end
    if p.kind == "chip" then
        if n >= HR.CAPS.pickups then
            -- too many on the floor: fold this one into the oldest chip
            for _, q in ipairs(g.pickups) do if q.kind == "chip" then q.v = q.v + p.v return q end end
        end
    elseif special >= HR.CAPS.special then
        return nil
    end
    p.age = 0
    g.pickups[#g.pickups + 1] = p
    return p
end

--- The enemy is dead: experience, drops and everything that triggers on a kill.
function HR.Kill(g, e, wid)
    if e.dead then return end
    if e.onZero then
        if e.onZero(g, e) then return end -- (a boss part that goes down instead of dying)
    end
    -- Pit Boss's Whistle: an elite fights for you first
    if e.elite and HR.Relic(g, "whistle") and not e.turned then
        e.turned, e.hp, e.ally = true, e.maxhp * 0.5, 10
        HR.Text(g, e.x, e.y + 16, "Whistle!", "ff20ff20")
        return
    end
    e.dead = true
    if not e.obj then HR.Event(g, "kill") end
    local st, pl = g.st, g.pl
    if HR.OnKill then HR.OnKill(g, e, wid) end
    if not e.obj then
        g.kills = g.kills + 1
        g.roomKills = (g.roomKills or 0) + 1
        g.streakKills = (g.streakKills or 0) + 1
        if e.elite then g.roomElites = (g.roomElites or 0) + 1 end
        -- experience
        g.xp = g.xp + (e.xp or 0)
        -- chips
        if not e.boss and (e.elite or g.rand.chance(0.4)) then
            local v = (e.elite and 10 or g.rand.i(1, 2)) * g.diff
            HR.DropPickup(g, { kind = "chip", x = e.x, y = e.y, v = v })
        end
        if e.loot and e.loot > 0 then HR.DropPickup(g, { kind = "chip", x = e.x, y = e.y, v = e.loot }) end
        if e.elite and g.rand.chance(0.35) then HR.DropPickup(g, { kind = "heart", x = e.x + 8, y = e.y, v = 15 }) end
        -- Lucky Seven
        if HR.Relic(g, "seven") and g.kills % 7 == 0 then HR.DropPickup(g, { kind = "chip", x = e.x, y = e.y + 6, v = 5 * g.diff }) end
        -- Hearts: a little health every so many kills
        if st.healPerKills and g.kills % st.healPerKills == 0 then HR.Heal(g, 1) end
        -- The Rake: kills inside the aura heal
        local edge = HR.FindWeapon(g, "edge")
        if edge and edge.evo and dist(pl.x, pl.y, e.x, e.y) <= HR.WVal(edge, "r") * st.area + e.r then HR.Heal(g, 1) end
        -- Snake Oil: the jinx moves on
        if (e.jinx or 0) > 0 and HR.Charm(g, "snakeoil") > 0 and (e.spread or 0) < 3 then
            local n, skip = HR.Charm(g, "snakeoil"), { [e] = true }
            for _ = 1, n do
                local o = HR.Nearest(g, e.x, e.y, skip, 90)
                if not o then break end
                skip[o] = true
                HR.Jinx(g, o, HR.CharmMax(g, "snakeoil"))
                o.spread = (e.spread or 0) + 1
            end
        end
        -- Death Card: a kill reloads the Ace
        if wid == "ace" then
            local ace = HR.FindWeapon(g, "ace")
            if ace and ace.evo and (g.time - (ace.lastFree or -1)) > 0.3 then ace.cd, ace.lastFree = 0, g.time end
        end
        if e.dots then HR.DotDeath(g, e) end
        -- pickups for the weapons that have a game of their own
        local flick, tcoin = HR.FindWeapon(g, "flick"), HR.FindWeapon(g, "trickcoin")
        if flick and not e.boss then
            local every = HR.WVal(flick, "drop") or 6
            g.cardKills = (g.cardKills or 0) + 1
            if g.cardKills >= every then
                g.cardKills = 0
                HR.DropCard(g, e.x, e.y)
            end
        end
        if tcoin and not e.boss then
            local every = HR.WVal(tcoin, "drop") or 15
            g.flipKills = (g.flipKills or 0) + 1
            if e.elite or g.flipKills >= every then
                g.flipKills = 0
                HR.DropPickup(g, { kind = "flip", x = e.x, y = e.y, life = 8 })
            end
        end
        -- splitting
        local into = e.def and e.def.split and (e.kind == "slime" and "slime_s" or "slime_t")
        if e.trait == "splitting" and not e.def.split then into = e.kind end
        if into then
            for i = 1, 2 do
                local c = HR.Spawn(g, into, e.x + (i == 1 and -8 or 8), e.y, { force = true })
                if c and e.trait == "splitting" then c.hp, c.maxhp = e.maxhp * 0.2, e.maxhp * 0.2 end
            end
        end
    end
    if e.onDeath then e.onDeath(g, e) end
end

--- Damage to an enemy. opts: exact (no spread), vx/vy (a shot's direction), noLucky, shot.
--- Returns true if it landed.
function HR.Hit(g, e, dmg, wid, opts)
    if e.dead or g.phase == "over" then return false end
    opts = opts or {}
    local st, def = g.st, e.def
    if e.onHit and e.onHit(g, e, wid) then return true end -- (the wheel: a nudge, not damage)
    if e.immune or e.ally then
        if (g.time - (e.immuneText or -9)) > 1 and e.immune then
            e.immuneText = g.time
            HR.Text(g, e.x, e.y + e.size * 0.5, "immune", "ffaaaaaa")
        end
        return false
    end
    if e.asleep then e.asleep, e.sprite = nil, "mimic" end
    -- a lucky hit?
    g.attacks = (g.attacks or 0) + 1
    local lucky = not opts.noLucky and (g.rand.chance(st.luckyChance)
        or (HR.Relic(g, "shoe6") and g.attacks % 6 == 0))
    -- dodges and shields
    if ((def and def.lucky) or e.trait == "lucky") and g.rand.chance(0.33) and not (lucky and HR.CharmMax(g, "gambler")) then
        HR.Text(g, e.x, e.y + 12, "dodge", "ffaaaaaa")
        if HR.Relic(g, "martingale") then g.mgHit = true end
        return false
    end
    if opts.vx and ((def and def.shield) or e.trait == "shielded") then
        -- a shot coming at its front is mostly stopped (the shield faces the player)
        local fx, fy = g.pl.x - e.x, g.pl.y - e.y
        local fl = sqrt(fx * fx + fy * fy)
        local vl = sqrt(opts.vx * opts.vx + opts.vy * opts.vy)
        if fl > 0 and vl > 0 and (-(opts.vx * fx + opts.vy * fy) / (fl * vl)) > 0.3 then dmg = dmg * 0.25 end
    end
    if opts.vx and def and def.spin and e.spinning then
        -- a spinning Spinner sends shots back
        if #g.eshots < HR.CAPS.eshots then
            local a = atan2(g.pl.y - e.y, g.pl.x - e.x)
            g.eshots[#g.eshots + 1] = { x = e.x, y = e.y, vx = cos(a) * 130, vy = sin(a) * 130, r = 5, dmg = e.dmg * 0.7, life = 4 }
        end
        return false
    end
    if not opts.exact then dmg = dmg * (0.85 + 0.3 * HR.Roll(g)) end
    dmg = dmg * st.dmg
    if lucky then
        dmg = dmg * st.luckyMult * (st.luckyTwice and 2 or 1)
    end
    if g.mgHit then dmg, g.mgHit = dmg * 2, nil end
    if (e.jinx or 0) > 0 then dmg = dmg * (1 + st.jinxAmp + (e.jinxStrong and 0.1 or 0)) end
    if st.punish and ((e.stun or 0) > 0 or (e.slow or 0) > 0) then dmg = dmg * 1.4 end
    if e.suit and wid and HR.WEAPON[wid] and HR.WEAPON[wid].suit == e.suit then dmg = dmg * 0.5 end
    if e.dr then dmg = dmg * (1 - e.dr) end
    -- bosses and the Enforcer can't be burst down: past 5% of their health in any one second,
    -- only a quarter of the damage gets through (so a strong build is still faster, not instant)
    if (e.boss or e.mini) and not opts.raw then
        if g.time - (e.gateT or -9) >= 1 then e.gateT, e.gateD = g.time, 0 end
        local allow = max(0, e.maxhp * HR.BOSS_GATE - e.gateD)
        if dmg > allow then dmg = allow + (dmg - allow) * 0.25 end
        e.gateD = e.gateD + dmg
    end
    -- lifesteal: a share of the damage dealt, paid out as a trickle in StepPlayer
    if st.lifesteal > 0 and not e.obj then
        g.leech = (g.leech or 0) + min(dmg, max(0, e.hp)) * st.lifesteal * ((lucky and HR.CharmMax(g, "vig")) and 2 or 1)
    end
    e.hp = e.hp - dmg
    e.flashAt = g.clock
    if lucky and HR.Fx then HR.Fx(g, "spark", e.x, e.y + 4, 0.3) end
    g.dmgBy[wid or "other"] = (g.dmgBy[wid or "other"] or 0) + dmg
    if wid then
        g.roomWeapons = g.roomWeapons or {}
        g.roomWeapons[wid] = true
    end
    if dmg > (g.bigHit or 0) then g.bigHit = floor(dmg) end
    if lucky or dmg >= 20 or e.boss then
        HR.Text(g, e.x, e.y + e.size * 0.5, tostring(floor(dmg + 0.5)), lucky and "ffffd100" or "ffffffff")
    end
    if st.execute and not e.boss and not e.mini and not e.obj and e.hp > 0 and e.hp < e.maxhp * 0.2 then e.hp = 0 end
    if st.knock > 0 and not e.boss and not e.obj and not (def and def.heavy) then
        local a = atan2(e.y - g.pl.y, e.x - g.pl.x)
        e.x, e.y = e.x + cos(a) * 5 * st.knock, e.y + sin(a) * 5 * st.knock
    end
    if e.hp <= 0 then HR.Kill(g, e, wid) end
    return true
end

--- Hits everything within r of a point. Returns how many were hit.
function HR.Blast(g, x, y, r, dmg, wid, opts)
    local n = 0
    for _, e in ipairs(g.enemies) do
        if not e.dead and not e.untarget and dist(x, y, e.x, e.y) <= r + e.r then
            if HR.Hit(g, e, dmg, wid, opts) then
                n = n + 1
                if opts and opts.each then opts.each(e) end
            end
        end
    end
    if not (opts and opts.quiet) then
        g.zones[#g.zones + 1] = { side = "fx", shape = "circle", x = x, y = y, r = r, dur = 0.22, warn = 0 }
    end
    return n
end

---------------------------------------------------------------------------
-- Shots (the player's)
---------------------------------------------------------------------------
--- s: x, y, vx, vy, dmg, wid, and optionally r, pierce, bounce, life, sprite, size, exact, onHit, onEnd...
function HR.Shoot(g, s)
    if #g.shots >= HR.CAPS.shots then
        if s.onEnd then s.onEnd(g, s, true) end
        return nil
    end
    s.r, s.life, s.size = s.r or 6, s.life or 2.2, s.size or 16
    s.pierce = (s.pierce or 0) + g.st.pierce
    s.bounce = s.bounce or 0
    if s.bounce > 0 or s.canBounce then s.bounce = s.bounce + g.st.bounce end
    if HR.Relic(g, "hotdice") and (s.maxRoll or g.rand.chance(0.12)) then s.bounce = s.bounce + 1 end
    s.seen = {}
    g.shots[#g.shots + 1] = s
    return s
end

--- Aims a new shot from (x,y) at an enemy (or straight up if there's none).
function HR.ShootAt(g, x, y, target, speed, s, spread)
    local a = target and atan2(target.y - y, target.x - x) or (pi / 2)
    a = a + (spread or 0)
    s.x, s.y, s.vx, s.vy = x, y, cos(a) * speed, sin(a) * speed
    s.speed = speed
    return HR.Shoot(g, s)
end

local function StepShots(g, dt)
    local shots = g.shots
    for i = #shots, 1, -1 do
        local s = shots[i]
        if g.shots ~= shots or not s then return end
        s.life = s.life - dt
        if s.step then s.step(g, s, dt) end
        s.x, s.y = s.x + s.vx * dt, s.y + s.vy * dt
        local done = s.life <= 0
        if not done then
            for _, e in ipairs(g.enemies) do
                if not e.dead and not e.untarget and not s.seen[e] and dist(s.x, s.y, e.x, e.y) <= s.r + e.r then
                    s.seen[e] = true
                    local dmg = s.dmg * (1 + (s.bounces or 0) * (s.perBounce or 0))
                    local landed = HR.Hit(g, e, dmg, s.wid, { exact = s.exact, vx = s.vx, vy = s.vy })
                    if not landed and HR.Relic(g, "martingale") then g.mgHit = true end
                    if landed and s.onHit then s.onHit(g, s, e) end
                    if s.bounce > 0 then
                        s.bounce, s.bounces = s.bounce - 1, (s.bounces or 0) + 1
                        local nextE = HR.Nearest(g, s.x, s.y, s.seen, s.seekAll and nil or 150)
                        if nextE then
                            local a = atan2(nextE.y - s.y, nextE.x - s.x)
                            local sp = s.speed or 200
                            s.vx, s.vy = cos(a) * sp, sin(a) * sp
                            s.life = max(s.life, 0.8)
                            if s.bounce == 0 and s.onLast then s.onLast(g, s) end
                        else
                            done = true
                        end
                    elseif s.pierce > 0 then
                        s.pierce = s.pierce - 1
                        if HR.CharmMax(g, "nail") and not e.boss and not e.obj and not (e.def and e.def.heavy) then
                            e.x, e.y = e.x + s.vx * 0.04, e.y + s.vy * 0.04
                        end
                    else
                        done = true
                    end
                    if done then break end
                end
            end
        end
        if done then
            if s.onEnd then s.onEnd(g, s) end
            -- (a shot's own hit may have added shots behind it: remove this one, wherever it now is)
            for k = min(i, #shots), 1, -1 do
                if shots[k] == s then table.remove(shots, k) break end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Zones: danger areas (enemy), lasting areas (player), flashes (fx) and floor markings (deco).
-- Shapes: circle {x,y,r}, ring {x,y,r1,r2}, lane {x1,y1,x2,y2,w}, rect {x1,y1,x2,y2},
-- circles {list}. invert: the danger is everywhere EXCEPT the shape.
---------------------------------------------------------------------------
function HR.InShape(z, x, y)
    local inside
    local s = z.shape
    if s == "circle" then inside = dist(z.x, z.y, x, y) <= z.r
    elseif s == "ring" then
        local d = dist(z.x, z.y, x, y)
        inside = d >= z.r1 and d <= z.r2
    elseif s == "lane" then
        local vx, vy = z.x2 - z.x1, z.y2 - z.y1
        local len2 = vx * vx + vy * vy
        local t = len2 > 0 and clamp(((x - z.x1) * vx + (y - z.y1) * vy) / len2, 0, 1) or 0
        inside = dist(z.x1 + vx * t, z.y1 + vy * t, x, y) <= z.w
    elseif s == "rect" then inside = x >= z.x1 and x <= z.x2 and y >= z.y1 and y <= z.y2
    elseif s == "circles" then
        inside = false
        for _, c in ipairs(z.list) do if dist(c.x, c.y, x, y) <= c.r then inside = true break end end
    end
    if z.invert then return not inside end
    return inside
end

--- An enemy attack: drawn on the floor for `warn` seconds, then it lands. dur > 0: it stays.
-- In a boss fight every one of them kills outright (z.lethal): they're always drawn first, so
-- being caught is a mistake you could see coming. Shields and the Rabbit's Foot still save you.
HR.LETHAL = 99999

function HR.Danger(g, z)
    z.side, z.total = "e", z.warn
    if g.phase == "boss" then z.lethal = true end
    z.dur = z.dur or 0
    g.zones[#g.zones + 1] = z
    HR.Event(g, "warn")
    return z
end

local function StepZones(g, dt)
    local pl = g.pl
    -- (a hit in here can end the boss fight, which replaces g.zones: work on the list we started with)
    local zones = g.zones
    for i = #zones, 1, -1 do
        local z = zones[i]
        if g.zones ~= zones or not z then return end
        if z.step then z.step(g, z, dt) end
        if z.follow and not z.follow.dead then z.x, z.y = z.follow.x, z.follow.y end
        if z.warn > 0 then
            z.warn = z.warn - dt
            if z.warn <= 0 then
                if z.side == "e" then
                    if HR.InShape(z, pl.x, pl.y) then HR.Hurt(g, z.lethal and HR.LETHAL or z.dmg or 10, z.name) end
                    if z.onFire then z.onFire(g, z) end
                    z.flash = 0.25
                end
                if z.dur <= 0 and z.side ~= "p" then z.dur = 0.25 z.spent = true end
            end
        else
            z.dur = z.dur - dt
            if z.side == "e" and not z.spent then
                z.tick = (z.tick or 0) - dt
                if z.tick <= 0 and HR.InShape(z, pl.x, pl.y) then
                    z.tick = 0.5
                    HR.Hurt(g, z.lethal and HR.LETHAL or z.dmg or 10, z.name)
                end
            elseif z.side == "p" then
                z.tick = (z.tick or 0) - dt
                if z.tick <= 0 then
                    z.tick = z.every or 0.4
                    for _, e in ipairs(g.enemies) do
                        if not e.dead and not e.untarget and dist(z.x, z.y, e.x, e.y) <= z.r + e.r then
                            HR.Hit(g, e, z.dmg, z.wid)
                            if z.slow and not e.boss then e.slow = max(e.slow or 0, 0.6) end
                            if z.dot and not e.dead then HR.Dot(g, e, z.wid, z.dot, 3, 1) end
                        end
                    end
                    if z.onTick then z.onTick(g, z) end
                end
            end
            if z.dur <= 0 or (z.follow and z.follow.dead) then
                for k = min(i, #zones), 1, -1 do
                    if zones[k] == z then table.remove(zones, k) break end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Enemy behaviour
---------------------------------------------------------------------------
local function MoveToward(e, tx, ty, speed, dt)
    local dx, dy = tx - e.x, ty - e.y
    local d = sqrt(dx * dx + dy * dy)
    if d > 0.5 then
        e.x, e.y = e.x + dx / d * speed * dt, e.y + dy / d * speed * dt
    end
    return d
end

local function StepEnemies(g, dt)
    local pl = g.pl
    local b = g.bounds
    local lowSlow = HR.CharmMax(g, "watch") and pl.hp < g.st.maxhp * 0.3 and 0.7 or 1
    local list = g.enemies
    for i = #list, 1, -1 do
        local e = list[i]
        if g.enemies ~= list or not e then return end
        if e.dead then
            table.remove(list, i)
        else
            local def = e.def or {}
            e.t = e.t + dt
            if (e.jinx or 0) > 0 then e.jinx = e.jinx - dt end
            if (e.slow or 0) > 0 then e.slow = e.slow - dt end
            if e.ally then
                -- a whistled elite: charges the nearest enemy, then goes
                e.ally = e.ally - dt
                local o
                local bd
                for _, x in ipairs(g.enemies) do
                    if x ~= e and not x.dead and not x.ally and not x.untarget then
                        local d = dist(e.x, e.y, x.x, x.y)
                        if not bd or d < bd then o, bd = x, d end
                    end
                end
                if o then
                    if MoveToward(e, o.x, o.y, e.speed * 1.5, dt) < e.r + o.r + 2 and e.t > 0.4 then
                        e.t = 0
                        HR.Hit(g, o, e.dmg * 3, "whistle", { noLucky = true })
                    end
                end
                if e.ally <= 0 then e.dead = true end
            elseif (e.stun or 0) > 0 then
                e.stun = e.stun - dt
            elseif e.step then
                e.step(g, e, dt) -- bosses and their parts
            elseif not e.obj then
                local speed = e.speed * ((e.slow or 0) > 0 and 0.6 or 1) * lowSlow
                local d = dist(e.x, e.y, pl.x, pl.y)
                if e.asleep then
                    if d < 70 then e.asleep, e.sprite, e.t = nil, "mimic", 0 end
                elseif def.dive then
                    -- Loan Shark: closes in, stops, then dives in a straight line
                    if e.mode == "dash" then
                        e.x, e.y = e.x + e.dvx * dt, e.y + e.dvy * dt
                        if e.t > 0.55 then e.mode, e.t = "rest", 0 end
                    elseif e.mode == "wind" then
                        if e.t > 0.5 then
                            local a = atan2(pl.y - e.y, pl.x - e.x)
                            e.dvx, e.dvy, e.mode, e.t = cos(a) * speed * 4.2, sin(a) * speed * 4.2, "dash", 0
                        end
                    elseif e.mode == "rest" then
                        if e.t > 1.1 then e.mode = nil end
                    else
                        MoveToward(e, pl.x, pl.y, speed, dt)
                        if d < 130 then e.mode, e.t = "wind", 0 end
                    end
                elseif def.blink then
                    MoveToward(e, pl.x, pl.y, speed, dt)
                    if e.t > def.blink and d > 60 then
                        e.t = 0
                        local a = atan2(g.input.dy, g.input.dx) + pi
                        if g.input.dx == 0 and g.input.dy == 0 then a = g.rand.f() * 2 * pi end
                        e.x, e.y = pl.x + cos(a) * 58, pl.y + sin(a) * 58
                        e.stun = 0.5
                    end
                elseif def.thief then
                    -- Pickpocket: goes for chips on the floor, then runs with them
                    local chip, cd
                    if (e.loot or 0) < 12 * g.diff then
                        for _, p in ipairs(g.pickups) do
                            if p.kind == "chip" then
                                local pd = dist(e.x, e.y, p.x, p.y)
                                if not cd or pd < cd then chip, cd = p, pd end
                            end
                        end
                    end
                    if chip then
                        if MoveToward(e, chip.x, chip.y, speed, dt) < 10 then
                            e.loot = (e.loot or 0) + chip.v
                            chip.gone = true
                        end
                    elseif (e.loot or 0) > 0 then
                        MoveToward(e, e.x * 2 - pl.x, e.y * 2 - pl.y, speed * 0.8, dt)
                    else
                        MoveToward(e, pl.x, pl.y, speed, dt)
                    end
                elseif def.spin then
                    e.spinning = (e.t % 5) < 2
                    MoveToward(e, pl.x, pl.y, speed * (e.spinning and 1.3 or 1), dt)
                elseif def.rake then
                    -- Croupier: keeps its distance and rakes your chips in
                    if d < 120 then MoveToward(e, e.x * 2 - pl.x, e.y * 2 - pl.y, speed, dt)
                    elseif d > 180 then MoveToward(e, pl.x, pl.y, speed, dt) end
                    for _, p in ipairs(g.pickups) do
                        if p.kind == "chip" and dist(e.x, e.y, p.x, p.y) < 200 then
                            if MoveToward(p, e.x, e.y, 70, dt) < 10 then p.gone = true end
                            p.raked = true
                        end
                    end
                elseif def.mark then
                    -- Fortune Teller: marks where you're heading
                    if d < 110 then MoveToward(e, e.x * 2 - pl.x, e.y * 2 - pl.y, speed, dt)
                    elseif d > 190 then MoveToward(e, pl.x, pl.y, speed, dt) end
                    if e.t > 4 and d < 260 then
                        e.t = 0
                        HR.Danger(g, { shape = "circle", x = pl.x + (pl.vx or 0) * 1.1, y = pl.y + (pl.vy or 0) * 1.1, r = 32,
                            warn = 1.2, dmg = e.dmg * 1.2, name = "a prophecy" })
                    end
                else
                    MoveToward(e, pl.x, pl.y, speed, dt)
                end
                if e.trait == "magnetic" then
                    for _, p in ipairs(g.pickups) do
                        if p.kind == "chip" and dist(e.x, e.y, p.x, p.y) < 120 then MoveToward(p, e.x, e.y, 50, dt) p.raked = true end
                    end
                end
                e.x, e.y = clamp(e.x, b[1] - 40, b[3] + 40), clamp(e.y, b[2] - 40, b[4] + 40)
                -- touching the player hurts
                if not e.asleep and dist(e.x, e.y, pl.x, pl.y) <= e.r + HR.PLAYER.r - 2 then
                    HR.Hurt(g, e.dmg, def.name)
                end
            end
        end
    end
end

local function StepEnemyShots(g, dt)
    local pl = g.pl
    local list = g.eshots
    for i = #list, 1, -1 do
        local s = list[i]
        if g.eshots ~= list or not s then return end
        s.x, s.y, s.life = s.x + s.vx * dt, s.y + s.vy * dt, s.life - dt
        local gone = s.life <= 0
        if not gone and dist(s.x, s.y, pl.x, pl.y) <= s.r + HR.PLAYER.r - 1 then
            HR.Hurt(g, s.dmg, "a shot")
            gone = true
        end
        if gone then table.remove(list, i) end
    end
end

---------------------------------------------------------------------------
-- Pickups: chips fly to you; everything else (dice, cards, flip coins, crates) must be walked over
---------------------------------------------------------------------------
function HR.DropCard(g, x, y)
    local c = HR.DrawCard(g)
    return HR.DropPickup(g, { kind = "card", x = x, y = y, card = c, life = 6 })
end

local function Collect(g, p)
    local pl = g.pl
    if p.kind == "chip" then
        if HR.Relic(g, "badpenny") and g.rand.chance(0.05) then HR.Hurt(g, 6, "a bad penny") end
        local got = HR.AddChips(g, p.v, true)
        g.roomChipLog = g.roomChipLog or {}
        g.roomChipLog[#g.roomChipLog + 1] = { t = g.roomTime, v = got }
        if g.roomTime < 30 and g.phase == "waves" then g.pickedEarly = true end
        g.wellCount = (g.wellCount or 0) + p.v
        if HR.CharmMax(g, "penny") then
            g.pennyHeal = (g.pennyHeal or 0) + got
            if g.pennyHeal >= 50 then g.pennyHeal = g.pennyHeal - 50 HR.Heal(g, 1) end
        end
        HR.Event(g, "chip")
    elseif p.kind == "heart" then
        HR.Heal(g, p.v)
        HR.Text(g, pl.x, pl.y + 14, "+" .. p.v, "ff20ff20")
    elseif p.kind == "die" then
        local held = g.heldDice
        if #held < 2 then held[#held + 1] = p.face
        else
            local lo = held[1] <= held[2] and 1 or 2
            if p.face > held[lo] then held[lo] = p.face end
        end
        HR.Event(g, "pick")
    elseif p.kind == "card" then
        g.hand[#g.hand + 1] = p.card
        HR.Event(g, "card")
        if #g.hand >= 5 then HR.PlayHand(g) end
    elseif p.kind == "flip" then
        local c = g.coin
        if c then
            local won = HR.Flip(g)
            HR.Text(g, pl.x, pl.y + 18, (c.side == "H" and "HEADS" or "TAILS") .. (c.streak > 0 and (" x" .. c.streak) or ""),
                won and "ffffd100" or "ffff8040")
            HR.Event(g, won and "win" or "push")
            if c.streak >= 6 then HR.Earned(g, "streak6") end
            HR.Recalc(g)
        end
    elseif HR.CollectExtra then
        HR.CollectExtra(g, p)
    end
end

local function StepPickups(g, dt)
    local pl, st = g.pl, g.st
    local range = st.pickup
    for i = #g.pickups, 1, -1 do
        local p = g.pickups[i]
        p.age = p.age + dt
        local d = dist(p.x, p.y, pl.x, pl.y)
        local gone = p.gone
        if not gone then
            if p.kind == "chip" or p.kind == "heart" then
                if (d <= range or (st.magnet and p.kind == "chip") or g.vacuum or (g.vacuumTill or 0) > g.time) and not (p.raked and d > range) then
                    p.pull = true
                end
                p.raked = nil
                if p.pull then
                    -- it speeds up from the moment it's caught (not from how long it has lain there),
                    -- and never steps past you: a chip that overshot used to dart back and forth
                    p.pullT = (p.pullT or 0) + dt
                    local step = (220 + p.pullT * 900) * dt
                    if step >= d - 8 then
                        p.x, p.y, d = pl.x, pl.y, 0
                    else
                        p.x, p.y = p.x + (pl.x - p.x) / d * step, p.y + (pl.y - p.y) / d * step
                        d = d - step
                    end
                end
                if d <= 10 then Collect(g, p) gone = true end
            else
                if p.life and p.age >= p.life then gone = true
                elseif d <= 15 then Collect(g, p) gone = true end
            end
        end
        if gone then table.remove(g.pickups, i) end
    end
end

---------------------------------------------------------------------------
-- The Card Sharp's hand
---------------------------------------------------------------------------
function HR.PlayHand(g)
    local pl, st = g.pl, g.st
    local rank, suit, used = HR.EvalHand(g.hand)
    local hadJoker = false
    for _, c in ipairs(g.hand) do if c.joker then hadJoker = true end end
    if g.nuts then
        g.nuts = nil
        rank = min(9, rank + 1)
    end
    if rank == 6 or rank == 9 then
        if not suit then
            local seen, bn = {}, 0
            for _, c in ipairs(g.hand) do
                if c.s then seen[c.s] = (seen[c.s] or 0) + 1 if seen[c.s] > bn then suit, bn = c.s, seen[c.s] end end
            end
            suit = suit or "S"
        end
    end
    local w = HR.FindWeapon(g, "flick")
    local power = w and HR.WVal(w, "hand") or 1
    local B = 18 * (1 + 0.6 * (g.diff - 1)) * power
    local wid = "flick"
    local function volley(n, dmg)
        for i = 1, n do
            local a = (i / n) * 2 * pi
            HR.Shoot(g, { x = pl.x, y = pl.y, vx = cos(a) * 150, vy = sin(a) * 150, dmg = dmg, wid = wid, sprite = "card", life = 2.5,
                step = function(gg, s, dt)
                    local e = HR.Nearest(gg, s.x, s.y, s.seen)
                    if e then
                        local ta = atan2(e.y - s.y, e.x - s.x)
                        s.vx, s.vy = s.vx + cos(ta) * 600 * dt, s.vy + sin(ta) * 600 * dt
                        local sp = sqrt(s.vx * s.vx + s.vy * s.vy)
                        if sp > 220 then s.vx, s.vy = s.vx / sp * 220, s.vy / sp * 220 end
                    end
                end })
        end
    end
    if rank == 1 then
        HR.Blast(g, pl.x, pl.y, 60 * st.area, B, wid)
    elseif rank == 2 then
        HR.Blast(g, pl.x, pl.y, 85 * st.area, 1.6 * B, wid)
        if hadJoker and HR.CharmMax(g, "joker") then HR.Blast(g, pl.x, pl.y, 85 * st.area, 1.6 * B, wid) end
    elseif rank == 3 then
        HR.Blast(g, pl.x, pl.y, 85 * st.area, 1.6 * B, wid)
        HR.Blast(g, pl.x, pl.y, 115 * st.area, 1.6 * B, wid)
        pl.shield = min(40, (pl.shield or 0) + 10)
    elseif rank == 4 then
        volley(8, 1.5 * B)
    elseif rank == 5 then
        -- a beam through the nearest enemy, right across the room
        local e = HR.Nearest(g, pl.x, pl.y)
        local a = e and atan2(e.y - pl.y, e.x - pl.x) or pi / 2
        local z = { shape = "lane", x1 = pl.x, y1 = pl.y, x2 = pl.x + cos(a) * 700, y2 = pl.y + sin(a) * 700, w = 16 }
        for _, x in ipairs(g.enemies) do
            if not x.dead and not x.untarget and HR.InShape({ shape = "lane", x1 = z.x1, y1 = z.y1, x2 = z.x2, y2 = z.y2, w = z.w + x.r }, x.x, x.y) then
                HR.Hit(g, x, 6 * B, wid)
            end
        end
        z.side, z.warn, z.dur = "fx", 0, 0.3
        g.zones[#g.zones + 1] = z
    elseif rank == 6 then
        if suit == "S" then
            for _, e in ipairs(HR.Visible(g)) do HR.Hit(g, e, 6 * B, wid) end
        elseif suit == "H" then
            HR.Heal(g, st.maxhp)
            pl.shield = min(40, (pl.shield or 0) + 20)
        elseif suit == "D" then
            for i = 1, 25 do
                local a, r = g.rand.f() * 2 * pi, 20 + g.rand.f() * 70
                HR.DropPickup(g, { kind = "chip", x = pl.x + cos(a) * r, y = pl.y + sin(a) * r, v = g.diff })
            end
            HR.Blast(g, pl.x, pl.y, 90 * st.area, 2 * B, wid)
        else
            for _, e in ipairs(HR.Visible(g)) do
                HR.Hit(g, e, 2 * B, wid)
                if e.boss then e.stun = max(e.stun or 0, 1.5) elseif not e.obj then e.stun = max(e.stun or 0, 4) end
            end
        end
        g.lentSuit[suit] = { n = 2, till = g.time + 15 }
        HR.Earned(g, "flush")
    elseif rank == 7 then
        HR.Blast(g, pl.x, pl.y, 115 * st.area, 3.2 * B, wid)
        volley(16, 1.5 * B)
    elseif rank == 8 then
        g.buffs[#g.buffs + 1] = { dmg = 2, till = g.time + 5 }
    else
        for _, e in ipairs(HR.Visible(g)) do
            if e.boss then HR.Hit(g, e, 15 * B, wid) elseif not e.obj then HR.Hit(g, e, 99999, wid, { exact = true }) end
        end
        HR.AddChips(g, 300)
        HR.Taunt(g, "jackpot")
        HR.Event(g, "jackpot")
    end
    -- 52 Pickup: cards rain on up to twelve enemies
    if w and w.evo then
        local vis = HR.Visible(g)
        for i = 1, min(12, #vis) do
            local e = vis[g.rand.i(1, #vis)]
            if not e.dead then HR.Blast(g, e.x, e.y, 22, B, wid, { quiet = i > 4 }) end
        end
    end
    local ace = HR.FindWeapon(g, "ace")
    if ace then ace.cd = 0 end
    g.handsPlayed = (g.handsPlayed or 0) + 1
    g.bestHand = max(g.bestHand or 0, rank)
    g.lastHand = { rank = rank, at = g.clock }
    g.hand = {}
    local name = HR.HANDS[rank]
    HR.Text(g, pl.x, pl.y + 26, name .. "!", rank >= 6 and "ffffd100" or "ffffffff")
    HR.Event(g, rank >= 6 and "bigwin" or "card")
    HR.Recalc(g)
    return rank
end

---------------------------------------------------------------------------
-- Level-ups and cards
---------------------------------------------------------------------------
function HR.TakeCard(g, card)
    if card.kind == "weapon" then
        local w = HR.FindWeapon(g, card.id)
        local amount = card.amount or 1
        if w then w.lvl = min(HR.WEAPON_MAX + (w.aces and 1 or 0), w.lvl + amount)
        else g.weapons[#g.weapons + 1] = { id = card.id, lvl = min(HR.WEAPON_MAX, amount), cd = 0.3 } end
    elseif card.kind == "evo" then
        local w = HR.FindWeapon(g, card.id)
        if w then w.evo = true end
        HR.Banner(g, "|cffffd100Cash Out: " .. card.title .. "!|r", 3)
        HR.Event(g, "bigwin")
    elseif card.kind == "charm" then
        g.charms[card.id] = min(HR.CHARM[card.id].max, (g.charms[card.id] or 0) + (card.amount or 1))
    elseif card.kind == "boost" then
        g.boosts = g.boosts or {}
        g.boosts[card.id] = (g.boosts[card.id] or 0) + 1
        HR.Recalc(g)
        if HR.BOOST[card.id].hp then HR.Heal(g, HR.BOOST[card.id].hp) end
    elseif card.id == "chips" then
        HR.AddChips(g, 60)
    elseif card.id == "heal" then
        HR.Heal(g, 25)
    end
    HR.ApplyAces(g)
    HR.Recalc(g)
end

--- Pocket Aces: the two highest weapons may go to level six.
function HR.ApplyAces(g)
    if not HR.Relic(g, "aces") then return end
    local n = 0
    for _, w in ipairs(g.weapons) do if w.aces then n = n + 1 end end
    local list = {}
    for _, w in ipairs(g.weapons) do if not w.aces then list[#list + 1] = w end end
    table.sort(list, function(a, b) return a.lvl > b.lvl end)
    for _, w in ipairs(list) do
        if n >= 2 then break end
        if w.lvl >= HR.WEAPON_MAX then
            w.aces, w.lvl = true, HR.WEAPON_MAX + 1
            n = n + 1
        end
    end
end

local function LevelMenu(g)
    -- a Golden Ticket's level-up deals cards one tier better
    local bump = 0
    if (g.ticket or 0) > 0 then bump, g.ticket = 1, g.ticket - 1 end
    local cards = HR.Offer(g, nil, bump)
    local m = { kind = "level", title = ("Level %d"):format(g.level), sub = "Pick a card", options = {} }
    for i, c in ipairs(cards) do
        m.options[i] = { key = tostring(i), title = c.title, sub = c.sub, desc = c.desc, hint = c.hint, suit = c.suit, icon = c.icon,
            link = c.link, card = c, rar = c.rar, pick = function() HR.TakeCard(g, c) end }
    end
    m.options[#m.options + 1] = { key = "F", title = "Fold", desc = ("Take no card. +%d Luck."):format(2 + HR.T(g, "df2")), small = true,
        pick = function()
            g.luck = g.luck + 2 + HR.T(g, "df2")
            g.folded = true
            HR.Recalc(g)
        end }
    if g.rerolls > 0 then
        m.options[#m.options + 1] = { key = "R", title = ("Reroll (%d left)"):format(g.rerolls), desc = "Deal three new cards.", small = true,
            keep = true, pick = function()
                g.rerolls = g.rerolls - 1
                g.menu = nil
                LevelMenu(g)
            end }
    end
    g.menu = m
    HR.Event(g, "levelup")
end

local function CheckLevel(g)
    if g.menu or g.phase == "over" then return end
    local need = HR.XpNeed(g.level)
    if g.xp >= need then
        g.xp = g.xp - need
        g.level = g.level + 1
        LevelMenu(g)
        if g.level % 4 == 0 then HR.Taunt(g, "levelup") end
    end
end

--- Picks a menu option by its key ("1", "2", "F"...). Returns true if something was picked.
function HR.Pick(g, key)
    local m = g.menu
    if not m then return false end
    for _, o in ipairs(m.options) do
        if o.key == key and o.enabled ~= false then
            if not o.keep then g.menu = nil end
            o.pick()
            if m.after and not g.menu and not o.keep then m.after() end
            return true
        end
    end
    return false
end

---------------------------------------------------------------------------
-- Side bets
---------------------------------------------------------------------------
local function BetPay(g, bet) return floor(bet.pay * (0.6 + 0.4 * g.diff) * (1 + 0.2 * HR.T(g, "df4"))) end

local function BetMenu(g, after)
    local pool = {}
    for _, b in ipairs(HR.BETS) do pool[#pool + 1] = b end
    local m = { kind = "bets", title = HR.ROOMS[g.roomIdx].name, sub = "The House offers a side bet (+1 Heat if you take one)", options = {}, after = after }
    for i = 1, 3 do
        local b = table.remove(pool, g.rand.i(1, #pool))
        m.options[i] = { key = tostring(i), title = b.name, desc = b.desc, sub = ("Pays %d chips and 3 Luck"):format(BetPay(g, b)),
            pick = function()
                g.bet = { id = b.id, pay = BetPay(g, b), inside = 0, wall = 0 }
                g.heat = min(8, g.heat + 1)
                if b.id == "stand" then
                    local bx, by = g.bounds[3] * 0.5 + g.rand.i(-150, 150), g.bounds[4] * 0.5 + g.rand.i(-150, 150)
                    g.bet.x, g.bet.y, g.bet.r = bx, by, 62
                    g.zones[#g.zones + 1] = { side = "deco", shape = "circle", x = bx, y = by, r = 62, warn = 0, dur = 9999, tint = "bet" }
                end
                HR.Recalc(g)
            end }
    end
    m.options[#m.options + 1] = { key = "0", title = "No bet", desc = "Play the room as it comes.", small = true, pick = function() end }
    g.menu = m
end

--- Settles the room's side bet when its boss dies. Returns "won", "lost" or nil.
function HR.SettleBet(g, bossTime)
    local b = g.bet
    if not b then return nil end
    g.bet = nil
    local id, won = b.id, false
    if id == "clean" then won = (g.roomHits or 0) <= 2
    elseif id == "body" then won = (g.waveKills or 0) >= 150
    elseif id == "tight" then won = not g.pickedEarly
    elseif id == "stand" then won = b.inside >= 25
    elseif id == "speed" then won = bossTime < 20
    elseif id == "big" then won = (g.roomElites or 0) >= 3
    elseif id == "short" then won = g.pl.hp <= g.st.maxhp * 0.5
    elseif id == "nofold" then won = not g.folded
    elseif id == "greedy" then
        local log = g.roomChipLog or {}
        local j, sum = 1, 0
        for i = 1, #log do
            sum = sum + log[i].v
            while log[i].t - log[j].t > 20 do sum = sum - log[j].v j = j + 1 end
            if sum >= 100 then won = true break end
        end
    elseif id == "wall" then won = b.wall >= 30
    elseif id == "weather" then
        local n = 0
        for _ in pairs(g.roomWeapons or {}) do n = n + 1 end
        won = n >= 4
    elseif id == "counter" then won = g.rand.chance(clamp(0.5 + (g.luckNow or 0) * 0.005, 0.5, 0.65))
    end
    local name = HR.BET[id].name
    if won then
        local got = HR.AddChips(g, b.pay)
        g.luck = g.luck + 3
        g.betsWon = (g.betsWon or 0) + 1
        g.betResult = ("|cff20ff20Side bet won: %s|r  +%d chips, +3 Luck"):format(name, floor(got))
        if g.betsWon >= 3 then HR.Earned(g, "bets3") end
    else
        local cost = min(g.chips, floor(b.pay / 2))
        g.chips = g.chips - cost
        g.betResult = ("|cffff8040Side bet lost: %s|r  -%d chips"):format(name, cost)
    end
    HR.Recalc(g)
    return won and "won" or "lost"
end

---------------------------------------------------------------------------
-- Rooms
---------------------------------------------------------------------------
local function ClearField(g)
    g.enemies, g.shots, g.eshots, g.zones, g.pickups, g.labels = {}, {}, {}, {}, {}, {}
end

function HR.StartRoom(g, pos, restoring)
    g.roomPos = pos
    g.roomIdx = g.order[pos]
    g.diff = (g.mode == "quick") and pos or g.roomIdx
    ClearField(g)
    g.bounds = { 0, 0, HR.ROOM_W, HR.ROOM_H }
    g.pl.x, g.pl.y = HR.ROOM_W / 2, HR.ROOM_H / 2
    g.roomTime, g.spawnT, g.phase = 0, 0.5, "waves"
    g.roomHits, g.roomKills, g.roomElites, g.waveKills = 0, 0, 0, nil
    g.roomWeapons, g.roomChipLog, g.pickedEarly, g.folded = {}, {}, nil, nil
    g.bet, g.betResult, g.boss, g.bossText, g.luckDrain = nil, nil, nil, nil, nil
    g.rerolls = 1 + HR.T(g, "df3") + (g.rerollBank or 0)
    g.rerollBank = 0
    g.catLifeUsed, g.vacuum = nil, nil
    g.noHeal = g.noHealNext
    g.noHealNext = nil
    if HR.Relic(g, "suite") then g.pl.hp = g.st.maxhp end
    if HR.T(g, "hg5") > 0 then g.pl.shield = max(g.pl.shield or 0, 20) end
    g.loanActive = HR.Relic(g, "loanmark")
    HR.Recalc(g)
    -- saved here, so a reload brings you back to the start of this room
    if not restoring and not g.noSave then HR.DB().save = HR.Snapshot(g) end
    HR.Camera(g)
    if HR.RoomExtras and not g.noExtras then HR.RoomExtras(g) end
    -- (the room's name, and the run's House Rule so it's never a surprise)
    local rule = g.rule and g.rule ~= "none" and HR.RULE[g.rule]
    HR.Banner(g, "|cffffd100" .. HR.ROOMS[g.roomIdx].name .. "|r" .. (rule and ("\n|cffffffffHouse Rule: " .. rule.name .. " - " .. rule.desc .. "|r") or ""), rule and 4.5 or 2.5)
    if HR.BETS_ON and HR.Feature("bets") and not restoring and not g.noBets then BetMenu(g) end
end

local function SpawnWave(g)
    local room = HR.ROOMS[g.roomIdx]
    local kinds, weights = {}, {}
    for _, m in ipairs(room.mix) do
        if g.roomTime >= m[3] then kinds[#kinds + 1], weights[#weights + 1] = m[1], m[2] end
    end
    local kind = kinds[g.rand.weighted(weights) or 1]
    local def = HR.ENEMIES[kind]
    local pl, b = g.pl, g.bounds
    -- just off screen, on a random side; pulled back inside the room
    local a = g.rand.f() * 2 * pi
    local rx, ry = HR.VIEW_W / 2 + 40, HR.VIEW_H / 2 + 40
    local x, y = pl.x + cos(a) * rx, pl.y + sin(a) * ry
    x, y = clamp(x, b[1] + 12, b[3] - 12), clamp(y, b[2] + 12, b[4] - 12)
    if dist(x, y, pl.x, pl.y) < 170 then
        x, y = clamp(pl.x - cos(a) * rx, b[1] + 12, b[3] - 12), clamp(pl.y - sin(a) * ry, b[2] + 12, b[4] - 12)
    end
    local eliteChance = 0
    if g.heat >= 4 then eliteChance = 0.03 + 0.02 * (g.heat - 4) end
    if (g.stakes or 0) >= 1 then eliteChance = max(eliteChance, 0.04) end
    if g.bet and g.bet.id == "big" then eliteChance = max(eliteChance, 0.07) end
    for i = 1, (def.pack or 1) do
        HR.Spawn(g, kind, x + g.rand.i(-14, 14), y + g.rand.i(-14, 14), (i == 1 and g.rand.chance(eliteChance)) and { elite = true } or nil)
    end
end

function HR.StartBoss(g)
    local room = HR.ROOMS[g.roomIdx]
    local def = HR.BOSSES[room.boss]
    g.waveKills = g.roomKills
    -- sweep the floor: chips fly to you, everything else goes
    g.enemies, g.shots, g.eshots, g.zones, g.labels = {}, {}, {}, {}, {}
    for i = #g.pickups, 1, -1 do
        local p = g.pickups[i]
        if p.kind == "chip" or p.kind == "heart" then
            local got = p.kind == "chip" and HR.AddChips(g, p.v, true)
            if p.kind == "heart" then HR.Heal(g, p.v) end
        end
        table.remove(g.pickups, i)
    end
    g.bounds = { 0, 0, HR.VIEW_W, HR.VIEW_H }
    g.pl.x, g.pl.y = HR.VIEW_W / 2, 60
    g.phase, g.phaseT = "bossintro", 1.5
    g.bossHits, g.bossTime = 0, 0
    g.barrageT, g.table, g.sched = 6, nil, {}
    g.bossName, g.bossLine = def.name, def.line
    HR.Taunt(g, "boss")
    HR.Event(g, "boss")
end

--- Boss hit points for this run (quick mode meets bosses earlier, so they're lighter).
function HR.BossHp(g, id)
    local def = HR.BOSSES[id]
    local scale = HR.ROOM_HP[g.diff] / HR.ROOM_HP[g.roomIdx]
    return def.hp * scale * (1 + 0.06 * g.heat) * ((g.stakes or 0) >= 1 and 1.15 or 1)
end

local function OpenCashier(g) HR.Cashier(g) end

--- The room's boss is beaten.
function HR.BossDown(g)
    if g.phase ~= "boss" then return end
    local room = HR.ROOMS[g.roomIdx]
    local def = HR.BOSSES[room.boss]
    local t = g.bossTime or 0
    local bounty = def.bounty
    local speed = clamp((45 - t) / 25, 0, 1) * 0.5
    local clean = (g.bossHits or 0) == 0 and 0.25 or 0
    local total = bounty * (1 + speed + clean)
    g.lastBounty = floor(HR.AddChips(g, total))
    g.bossesBeaten = g.bossesBeaten + 1
    g.loanActive = nil
    g.enemies, g.eshots, g.zones, g.labels, g.sched = {}, {}, {}, {}, {}
    g.bossText, g.luckDrain, g.boss = nil, nil, nil
    HR.ClassDB(g.class).firsts[room.boss] = true
    HR.Earned(g, def.ach)
    if room.boss == "dealer" and not g.bjBust then HR.Earned(g, "dealerclean") end
    HR.SettleBet(g, t)
    if g.heat >= 6 then HR.Earned(g, "heat6") end
    HR.Text(g, g.pl.x, g.pl.y + 30, ("+%d chips"):format(g.lastBounty), "ffffd100")
    HR.Event(g, "bigwin")
    HR.Recalc(g)
    if g.roomPos >= #g.order then
        g.phase = "over"
        g.summary = HR.FinishRun(g, "win")
        HR.Taunt(g, "win")
        return
    end
    HR.Taunt(g, "bosswin")
    g.phase, g.phaseT = "bossdown", 1.6
end

---------------------------------------------------------------------------
-- The Cashier: after a boss, a relic chest - then go on, or walk away
---------------------------------------------------------------------------
function HR.TakeRelic(g, id)
    local def = HR.RELIC[id]
    g.relics[id] = true
    if def.cursed then g.heat = min(8, g.heat + 1) end
    if id == "allin" then
        g.pl.hp = 1
        g.noHealNext = true
    end
    HR.ApplyAces(g)
    HR.Recalc(g)
    if id == "glass" then g.pl.hp = min(g.pl.hp, g.st.maxhp) end
end

-- After a boss there is one screen: three relics. Taking one (or none) goes straight on to the
-- next room; the other choice is to walk away with the chips.
local function RelicMenu(g)
    local pool, weights = {}, {}
    local cursedOnly = g.rule == "cursed"
    for _, r in ipairs(HR.RELICS) do
        if not g.relics[r.id] and HR.RelicUnlocked(r) then
            local ok = r.cursed and (HR.Feature("cursed") or cursedOnly) or (not r.cursed and not cursedOnly)
            if ok then pool[#pool + 1], weights[#weights + 1] = r, (r.cursed and 1.2) or (r.legendary and (0.5 + (g.luckNow or 0) * 0.02)) or 3 end
        end
    end
    local nextRoom = HR.ROOMS[g.order[g.roomPos + 1]]
    local function goOn() HR.StartRoom(g, g.roomPos + 1) end
    local lines = {}
    if g.betResult then lines[#lines + 1] = g.betResult end
    lines[#lines + 1] = ("Take a relic and go on to |cffffd100%s|r, or walk away with your |cffffd100%d|r chips. Dying loses them all."):format(
        nextRoom.name, floor(g.chips))
    local m = { kind = "relic", title = "The chest", sub = table.concat(lines, "\n"), subLines = #lines + 1, options = {} }
    for i = 1, 3 do
        local k = g.rand.weighted(weights)
        if not k then break end
        local r = pool[k]
        table.remove(pool, k)
        table.remove(weights, k)
        m.options[i] = { key = tostring(i), title = r.name, desc = r.desc, cursed = r.cursed, rar = r.legendary and 4 or nil,
            sub = (r.cursed and "|cffc060ffCursed relic  (+1 Heat)|r") or (r.legendary and "|cffff8a00Legendary relic|r") or "Relic",
            pick = function()
                HR.TakeRelic(g, r.id)
                goOn()
            end }
    end
    -- (only if every relic is already yours)
    if #m.options == 0 then
        m.options[1] = { key = "E", title = "Go on", desc = "Next: " .. nextRoom.name .. ".", small = true, pick = goOn }
    end
    m.options[#m.options + 1] = { key = "0", title = "Walk away", desc = ("End the run and keep %d chips as your score."):format(floor(g.chips)), small = true,
        pick = function()
            g.phase = "over"
            g.summary = HR.FinishRun(g, "walk")
            HR.Taunt(g, "walk")
        end }
    g.menu = m
end

function HR.Cashier(g)
    g.phase = "cashier"
    g.rerolls = 0
    RelicMenu(g)
end

---------------------------------------------------------------------------
-- The player and the main step
---------------------------------------------------------------------------
local function StepPlayer(g, dt)
    local pl, st, inp, b = g.pl, g.st, g.input, g.bounds
    local dx, dy = inp.dx or 0, inp.dy or 0
    local len = sqrt(dx * dx + dy * dy)
    if len > 0 then
        dx, dy = dx / len, dy / len
        pl.vx, pl.vy = dx * st.speed, dy * st.speed
        pl.x, pl.y = pl.x + pl.vx * dt, pl.y + pl.vy * dt
        pl.still = 0
        if dx ~= 0 then pl.face = dx > 0 and 1 or -1 end
    else
        pl.vx, pl.vy = 0, 0
        pl.still = (pl.still or 0) + dt
        if HR.CharmMax(g, "shoes") and pl.still > 1 and (pl.shield or 0) < 8 then pl.shield = 8 end
    end
    pl.x, pl.y = clamp(pl.x, b[1] + 8, b[3] - 8), clamp(pl.y, b[2] + 8, b[4] - 8)
    if pl.iframes > 0 then pl.iframes = pl.iframes - dt end
    -- small trickles
    if (g.refund or 0) > 0 then
        local r = min(g.refund, dt * 3)
        g.refund = g.refund - r
        local before = pl.hp
        HR.Heal(g, r / max(0.01, st.heal))
        if HR.CharmMax(g, "insurance") and g.refund <= 0 and pl.hp >= before then pl.shield = max(pl.shield or 0, 6) end
    end
    -- lifesteal: at most 4% of your health a second, and none of it is saved up for later
    if (g.leech or 0) > 0 then
        local r = min(g.leech, st.maxhp * 0.04 * dt, max(0, st.maxhp - pl.hp))
        g.leech = min(g.leech - r, st.maxhp * 0.04)
        if pl.hp >= st.maxhp then g.leech = 0 end
        if r > 0 and st.heal > 0 and not g.noHeal then
            pl.hp = pl.hp + r
            g.leeched = (g.leeched or 0) + r
            -- (a green number now and then, so you can see it working)
            g.leechShown = (g.leechShown or 0) + r
            if g.leechShown >= 5 then
                HR.Text(g, pl.x, pl.y + 22, ("+%d"):format(floor(g.leechShown + 0.5)), "ff40ff60")
                g.leechShown = 0
            end
        end
    end
    if g.loanActive and not g.god then
        pl.hp = pl.hp - 2 * dt
        if pl.hp <= 0 then pl.hp = 0 HR.Die(g) return end
    end
    -- Hearts flush: a full shield pulses
    if st.pulse and (pl.shield or 0) >= 28 then
        g.pulseT = (g.pulseT or 0) + dt
        if g.pulseT >= 2 then g.pulseT = 0 HR.Blast(g, pl.x, pl.y, 90 * st.area, 20 * g.diff, "hearts") end
    end
    -- side bets that watch where you stand
    local bet = g.bet
    if bet and g.phase == "waves" then
        if bet.id == "stand" and dist(pl.x, pl.y, bet.x, bet.y) <= bet.r then bet.inside = bet.inside + dt end
        if bet.id == "wall" and (pl.x < b[1] + 60 or pl.x > b[3] - 60 or pl.y < b[2] + 60 or pl.y > b[4] - 60) then bet.wall = bet.wall + dt end
    end
end

local function StepWeapons(g, dt)
    local st = g.st
    HR.StepDots(g, dt)
    for _, w in ipairs(g.weapons) do
        local stepper = HR.WSTEP[w.id]
        if stepper then stepper(g, w, dt) end
        local fire = HR.FIRE[w.id]
        if fire then
            w.cd = (w.cd or 0) - dt
            if w.cd <= 0 then
                local cd = HR.WVal(w, "cd") or 1
                w.cd = cd / max(0.2, st.atk)
                w.shots = (w.shots or 0) + 1
                fire(g, w, 1)
                -- Sharp's Glove at max: every tenth attack is doubled
                if HR.CharmMax(g, "glove") and w.shots % 10 == 0 then fire(g, w, 1) end
            end
        end
    end
end

local function Camera(g)
    local b = g.bounds
    g.camX = clamp(g.pl.x - HR.VIEW_W / 2, b[1], max(b[1], b[3] - HR.VIEW_W))
    g.camY = clamp(g.pl.y - HR.VIEW_H / 2, b[2], max(b[2], b[4] - HR.VIEW_H))
end
HR.Camera = Camera

--- One fixed step of the run. Does nothing while a menu is open, or when paused or over.
function HR.Step(g, dt)
    dt = dt or HR.STEP
    g.clock = g.clock + dt
    for i = #g.texts, 1, -1 do
        local t = g.texts[i]
        t.life, t.y = t.life - dt, t.y + 26 * dt
        if t.life <= 0 then table.remove(g.texts, i) end
    end
    for i = #g.fx, 1, -1 do
        local f = g.fx[i]
        f.life = f.life - dt
        if f.life <= 0 then table.remove(g.fx, i) end
    end
    if (g.flash or 0) > 0 then g.flash = g.flash - dt end
    if g.menu or g.paused or g.phase == "over" or g.phase == "cashier" then
        Camera(g)
        return
    end
    g.time = g.time + dt
    g.recalcT = (g.recalcT or 0) - dt
    if g.recalcT <= 0 then
        g.recalcT = 0.2
        HR.Recalc(g)
    end
    if g.phase == "bossintro" then
        g.phaseT = g.phaseT - dt
        Camera(g)
        if g.phaseT <= 0 then
            g.phase = "boss"
            HR.BOSS[HR.ROOMS[g.roomIdx].boss].start(g)
        end
        return
    elseif g.phase == "bossdown" then
        g.phaseT = g.phaseT - dt
        g.vacuum = true
        StepPlayer(g, dt)
        StepPickups(g, dt)
        Camera(g)
        if g.phaseT <= 0 then OpenCashier(g) end
        return
    end
    StepPlayer(g, dt)
    if g.phase == "over" then return end
    if g.phase == "waves" then
        g.roomTime = g.roomTime + dt
        g.spawnT = g.spawnT - dt
        if g.spawnT <= 0 then
            local f = min(1, g.roomTime / HR.WAVE_TIME)
            g.spawnT = (0.68 - 0.40 * f) / (g.rule == "happy" and 1.5 or 1)
            SpawnWave(g)
        end
        if g.roomTime >= HR.WAVE_TIME then
            HR.StartBoss(g)
            Camera(g)
            return
        end
        if HR.StepEvents and not g.noExtras then HR.StepEvents(g, dt) end
        -- a new player's first tips
        if g.tips and g.tips[1] and g.roomTime >= g.tips[1].t then
            HR.Banner(g, g.tips[1].text, 5)
            table.remove(g.tips, 1)
        end
    elseif g.phase == "boss" then
        g.bossTime = (g.bossTime or 0) + dt
        -- Flick is dealt cards in a boss fight, where there's little to kill
        if HR.FindWeapon(g, "flick") then
            g.bossCardT = (g.bossCardT or 3) - dt
            if g.bossCardT <= 0 then
                g.bossCardT = 3
                local a = g.rand.f() * 2 * pi
                HR.DropCard(g, clamp(g.pl.x + cos(a) * 80, 20, HR.VIEW_W - 20), clamp(g.pl.y + sin(a) * 80, 20, HR.VIEW_H - 20))
            end
        end
        local boss = g.boss
        if boss and boss.update then boss.update(g, boss, dt) end
        if HR.StepBarrage and g.phase == "boss" and not g.noExtras then HR.StepBarrage(g, dt) end
    end
    if HR.StepSched then HR.StepSched(g) end
    StepWeapons(g, dt)
    StepShots(g, dt)
    StepZones(g, dt)
    StepEnemies(g, dt)
    StepEnemyShots(g, dt)
    StepPickups(g, dt)
    Camera(g)
    if g.phase ~= "over" then CheckLevel(g) end
end

--- Runs the game for some real seconds in fixed steps (the UI's OnUpdate and the tests).
function HR.Advance(g, seconds)
    g.acc = (g.acc or 0) + seconds
    local n = 0
    while g.acc >= HR.STEP and n < 8 do
        g.acc = g.acc - HR.STEP
        HR.Step(g, HR.STEP)
        n = n + 1
    end
    if n >= 8 then g.acc = 0 end
    return n
end
