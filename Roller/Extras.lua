-- Roller/Extras.lua: what happens on the floor between the enemies - weapon crates, power-up pickups,
-- breakable casino furniture, room events, a mini-boss, chests from elites, card rarities,
-- legendary relics, the bosses' rapid barrages, and the little effects the UI draws.
-- Loaded after Engine.lua, which calls the HR.On... / HR.Step... hooks defined here.
local ADDON_NAME, ns = ...
local HR = ns.Roller
local sqrt, floor, min, max, cos, sin, atan2, pi = math.sqrt, math.floor, math.min, math.max, math.cos, math.sin, math.atan2, math.pi
local dist, clamp = HR.dist, HR.clamp
local W, H = HR.VIEW_W, HR.VIEW_H

HR.CAPS.special = 20
HR.CAPS.fx = 48

---------------------------------------------------------------------------
-- Effects for the UI (puffs, sparks, rings) and things that happen a moment later
---------------------------------------------------------------------------
function HR.Fx(g, kind, x, y, life, extra)
    local fx = g.fx
    if #fx >= HR.CAPS.fx then table.remove(fx, 1) end
    local f = { kind = kind, x = x, y = y, life = life or 0.35, total = life or 0.35 }
    if extra then for k, v in pairs(extra) do f[k] = v end end
    fx[#fx + 1] = f
end

--- Runs fn(g) after `delay` seconds of game time - dropped if the room or phase changes first.
function HR.After(g, delay, fn)
    g.sched = g.sched or {}
    g.sched[#g.sched + 1] = { t = g.time + delay, fn = fn, room = g.roomPos, phase = g.phase }
end

function HR.StepSched(g)
    local list = g.sched
    if not list or #list == 0 then return end
    for i = #list, 1, -1 do
        local s = list[i]
        if s and (s.room ~= g.roomPos or s.phase ~= g.phase) then
            table.remove(list, i)
        elseif s and s.t <= g.time then
            table.remove(list, i)
            s.fn(g)
            if g.sched ~= list then return end
        end
    end
end

---------------------------------------------------------------------------
-- Rarities: a level-up card (or a chest prize) can be worth more than one step
---------------------------------------------------------------------------
HR.RARITY = {
    { id = "common", name = "", color = "ffffffff", amount = 1 },
    { id = "rare", name = "Rare", color = "ff4da6ff", amount = 2 },
    { id = "epic", name = "Epic", color = "ffc070ff", amount = 3 },
    { id = "legendary", name = "Legendary", color = "ffff8a00", amount = 99 },
}

--- 1-4. Luck and the Diamonds set make the better ones likelier; bump adds tiers (chests, tickets).
function HR.RollRarity(g, bump)
    local luck = g.luckNow or 0
    local mult = g.st.rare and 2 or 1
    local weights = { 70, (22 + luck * 0.4) * mult, (7 + luck * 0.15) * mult, (1 + luck * 0.04) * mult }
    local r = g.rand.weighted(weights)
    if HR.Relic(g, "loadeddeck") then r = max(2, r) end
    return min(4, r + (bump or 0))
end

--- "Damage 10 > 12" for a weapon card, so a pick shows what it buys. from 0: a new weapon.
local function StatLine(def, from, to)
    local a = def.dmg
    if type(a) ~= "table" then return nil end
    local label = def.dmgLabel or "Damage"
    local function v(l) return ("%g"):format(a[min(l, HR.WEAPON_MAX)]) end
    if from < 1 then return ("%s %s"):format(label, v(to)) end
    if v(from) == v(to) then return nil end
    return ("%s %s > %s"):format(label, v(from), v(to))
end

local function AddStat(g, c)
    if c.kind ~= "weapon" then return end
    local w = HR.FindWeapon(g, c.id)
    local from = w and w.lvl or 0
    local line = StatLine(HR.WEAPON[c.id], from, from + (c.amount or 1))
    if line then c.desc = (c.desc or "") .. "\n|cff20ff20" .. line .. "|r" end
end

--- What a card does for your suits, and what the Wild Card would copy - written on the card.
local function AddSuitNote(g, c)
    if c.kind ~= "weapon" and c.kind ~= "charm" then return end
    if c.id == "wild" then
        local src, fires = HR.WildSource(g)
        if src then
            c.desc = (c.desc or "") .. "\n|cffffd100Copying now:|r " .. HR.WEAPON[src.id].name
                .. (fires and "" or " |cffff8040(it has no attack to copy: a plain card is thrown instead)|r")
        end
        return
    end
    if not c.new or not c.suit then return end
    local tier = HR.SuitGain(g, c.suit)
    if tier then
        c.desc = (c.desc or "") .. ("\n|cffffd100%d %s:|r %s"):format(HR.SUIT_NEED[tier], HR.SUIT_NAME[c.suit], HR.SUIT_BONUS[c.suit][tier])
        c.suitTier = tier
    end
end

local baseOffer = HR.Offer
--- Level-up cards, now with a rarity each. A card is only marked rare if it really gives more.
function HR.Offer(g, n, bump)
    local cards = baseOffer(g, n)
    for _, c in ipairs(cards) do
        local r = HR.RollRarity(g, bump)
        local want = HR.RARITY[r].amount
        local amount, text = 1, nil
        if c.kind == "weapon" and c.new then
            amount = ({ 1, 2, 3, 5 })[r]
            if amount > 1 then text = ("starts at level %d"):format(amount) end
        elseif c.kind == "weapon" then
            local w = HR.FindWeapon(g, c.id)
            amount = min(want, HR.WEAPON_MAX - w.lvl)
            if amount > 1 then text = ("+%d levels"):format(amount) end
        elseif c.kind == "charm" then
            amount = min(want, HR.CHARM[c.id].max - HR.Charm(g, c.id))
            if amount > 1 then text = ("%d copies"):format(amount) end
        elseif c.kind == "evo" then
            c.rar = 4
        end
        if amount > 1 then
            -- the tier that matches what it actually gives
            local shown = r
            while shown > 2 and HR.RARITY[shown].amount > amount and HR.RARITY[shown - 1].amount >= amount do shown = shown - 1 end
            c.rar, c.amount = shown, amount
            c.sub = HR.RARITY[shown].name .. " - " .. text
        else
            c.amount = 1
        end
        AddStat(g, c)
        AddSuitNote(g, c)
    end
    return cards
end

---------------------------------------------------------------------------
-- Weapon crates: one lands near you early in every room. Walk over it and pick one of three
-- weapons you don't have (or, with every slot full, two levels for one you do).
---------------------------------------------------------------------------
HR.CRATE_AT = 12

function HR.CrateCards(g)
    local pool = {}
    if #g.weapons < HR.MAX_WEAPONS then
        for _, def in ipairs(HR.WEAPONS) do
            if not def.start and not def.soon and not HR.FindWeapon(g, def.id) and HR.WeaponUnlocked(def) then
                pool[#pool + 1] = { kind = "weapon", id = def.id, new = true, amount = 1, title = def.name, sub = "New weapon", desc = def.desc,
                    suit = def.suit, icon = def.icon,
                    hint = def.evo and ("Cash Out needs " .. (def.evo.need == "flush" and "a Flush" or HR.CHARM[def.evo.need].name)) }
            end
        end
    end
    if #pool == 0 then
        for _, w in ipairs(g.weapons) do
            local def = HR.WEAPON[w.id]
            if w.lvl < HR.WEAPON_MAX then
                local amount = min(2, HR.WEAPON_MAX - w.lvl)
                pool[#pool + 1] = { kind = "weapon", id = w.id, amount = amount, owned = true, title = def.name,
                    sub = amount > 1 and "+2 levels" or ("Level " .. (w.lvl + 1)), desc = def.lv[w.lvl + amount], suit = def.suit, icon = def.icon }
            end
        end
    end
    local out = {}
    while #out < 3 and #pool > 0 do out[#out + 1] = table.remove(pool, g.rand.i(1, #pool)) end
    for _, c in ipairs(out) do
        AddStat(g, c)
        AddSuitNote(g, c)
    end
    return out
end

function HR.OpenCrate(g)
    local cards = HR.CrateCards(g)
    g.cratesOpened = (g.cratesOpened or 0) + 1
    -- every weapon held and at its top level: it's a chest instead
    if #cards == 0 then return HR.OpenChest(g) end
    local m = { kind = "level", title = "A weapon crate", sub = "Pick one", options = {} }
    for i, c in ipairs(cards) do
        m.options[i] = { key = tostring(i), title = c.title, sub = c.sub, desc = c.desc, hint = c.hint, suit = c.suit, icon = c.icon,
            card = c, pick = function() HR.TakeCard(g, c) end }
    end
    g.menu = m
    HR.Event(g, "chest")
end

function HR.DropCrate(g, x, y)
    return HR.DropPickup(g, { kind = "crate", x = x, y = y })
end

---------------------------------------------------------------------------
-- Legendary relics
---------------------------------------------------------------------------
for _, r in ipairs({
    { id = "loadeddeck", name = "Loaded Deck", legendary = true, desc = "Every level-up card is Rare or better." },
    { id = "masterkey", name = "Master Key", legendary = true, desc = "Chests always hold at least three prizes." },
    { id = "ladyluck", name = "Lady Luck", legendary = true, desc = "+20 Luck, and no boss can take your Luck from you." },
    { id = "highroller", name = "High Roller's Ring", legendary = true, desc = "Power-ups last twice as long and drop twice as often." },
}) do
    HR.RELICS[#HR.RELICS + 1] = r
    HR.RELIC[r.id] = r
end

---------------------------------------------------------------------------
-- Power-ups: walk over one. They never fly to you.
---------------------------------------------------------------------------
HR.POWERS = {
    { id = "boots", name = "Lucky Boots", sprite = "pu_boots", text = "+50% speed", secs = 8, w = 5 },
    { id = "magnet", name = "Magnet", sprite = "pu_magnet", text = "every chip flies to you", secs = 3, w = 4 },
    { id = "alarm", name = "Fire Alarm", sprite = "pu_alarm", text = "clears the floor", w = 2 },
    { id = "watch", name = "Stopwatch", sprite = "pu_watch", text = "enemies frozen", secs = 4, w = 3 },
    { id = "drink", name = "Free Drink", sprite = "pu_drink", text = "+30 health", w = 4 },
    { id = "hand", name = "Hot Hand", sprite = "pu_hand", text = "double attack speed", secs = 8, w = 4 },
    { id = "guard", name = "Bodyguard", sprite = "pu_guard", text = "a shield", w = 3 },
    { id = "ticket", name = "Golden Ticket", sprite = "pu_ticket", text = "a free level-up, one tier better", w = 0.4, legendary = true },
}
HR.POWER = {}
for _, p in ipairs(HR.POWERS) do HR.POWER[p.id] = p end

function HR.DropPower(g, x, y, id)
    if not id then
        local weights = {}
        for i, p in ipairs(HR.POWERS) do weights[i] = p.w end
        id = HR.POWERS[g.rand.weighted(weights)].id
    end
    return HR.DropPickup(g, { kind = "power", id = id, x = x, y = y, life = 15 })
end

function HR.UsePower(g, id)
    local p = HR.POWER[id]
    local pl = g.pl
    local secs = (p.secs or 0) * (HR.Relic(g, "highroller") and 2 or 1)
    if id == "boots" then
        g.buffs[#g.buffs + 1] = { speed = 0.5, till = g.time + secs }
    elseif id == "hand" then
        g.buffs[#g.buffs + 1] = { atk = 1, till = g.time + secs }
    elseif id == "magnet" then
        g.vacuumTill = g.time + secs
    elseif id == "watch" then
        for _, e in ipairs(g.enemies) do
            if not e.dead and not e.obj then e.stun = max(e.stun or 0, e.boss and 1 or secs) end
        end
    elseif id == "alarm" then
        for _, e in ipairs(HR.Visible(g)) do
            if e.boss or e.obj or e.mini then HR.Hit(g, e, 40 * g.diff, "alarm") -- (the Enforcer shrugs it off like a boss)
            elseif e.elite then HR.Hit(g, e, e.maxhp * 0.5, "alarm", { exact = true, noLucky = true })
            else HR.Hit(g, e, 99999, "alarm", { exact = true, noLucky = true }) end
        end
        g.flash = 0.35
    elseif id == "drink" then
        HR.Heal(g, 30)
    elseif id == "guard" then
        pl.shield = min(60, (pl.shield or 0) + 25)
    elseif id == "ticket" then
        g.ticket = (g.ticket or 0) + 1
        g.xp = g.xp + HR.XpNeed(g.level)
    end
    if secs > 0 then
        g.powers = g.powers or {}
        g.powers[id] = g.time + secs
    end
    HR.Text(g, pl.x, pl.y + 24, p.name .. "!  " .. p.text, p.legendary and "ffff8a00" or "ff80e0ff")
    HR.Fx(g, "ring", pl.x, pl.y, 0.4, { r = 46 })
    HR.Event(g, p.legendary and "bigwin" or "pick")
    HR.Recalc(g)
end

---------------------------------------------------------------------------
-- Chests: elites and the mini-boss drop them. One, three or five prizes, a tier better.
---------------------------------------------------------------------------
function HR.OpenChest(g)
    local luck = g.luckNow or 0
    local n = ({ 1, 3, 5 })[g.rand.weighted({ 65, 28 + luck * 0.4, 7 + luck * 0.2 })]
    if HR.Relic(g, "masterkey") or (HR.T(g, "df5") > 0 and (g.chestsOpened or 0) == 0) then n = max(3, n) end
    local lines = {}
    for i = 1, n do
        local cards = HR.Offer(g, 3, 1)
        local card
        for _, c in ipairs(cards) do if c.kind ~= "bonus" then card = card or c end end
        card = card or cards[1]
        HR.TakeCard(g, card)
        local rar = HR.RARITY[card.rar or 1]
        lines[i] = ("|c%s%s|r  |cffaaaaaa%s|r"):format(rar.color, card.title, card.sub or "")
    end
    local chips = floor(HR.AddChips(g, 20 * g.diff * n))
    lines[#lines + 1] = ("|cffffd100+%d chips|r"):format(chips)
    g.chestsOpened = (g.chestsOpened or 0) + 1
    HR.Event(g, "chest")
    g.menu = { kind = "chest", title = n >= 5 and "JACKPOT CHEST!" or (n >= 3 and "A big chest!" or "A chest"),
        sub = table.concat(lines, "\n"), subLines = #lines, options = {
            { key = "E", title = "Take it", small = true, pick = function() end } } }
    if n >= 5 then
        g.flash = 0.35
        HR.Event(g, "jackpot")
        HR.Taunt(g, "jackpot")
    else
        HR.Event(g, "bigwin")
    end
end

--- Pickups the engine doesn't know: power-ups, chests and weapon crates.
function HR.CollectExtra(g, p)
    if p.kind == "power" then HR.UsePower(g, p.id)
    elseif p.kind == "crate" then HR.OpenCrate(g)
    elseif p.kind == "chest" then HR.OpenChest(g) end
end

---------------------------------------------------------------------------
-- Furniture you can smash: weapons hit it in passing, and walking into it breaks it
---------------------------------------------------------------------------
local PROPS = { "prop_slot", "prop_table", "prop_cart", "prop_crate" }

local function PropStep(g, e, dt)
    if dist(e.x, e.y, g.pl.x, g.pl.y) <= e.r + 9 then HR.Kill(g, e) end
end

local function PropBreak(g, e)
    for i = 1, g.rand.i(2, 4) do
        HR.DropPickup(g, { kind = "chip", x = e.x + g.rand.i(-12, 12), y = e.y + g.rand.i(-12, 12), v = g.rand.i(1, 2) * g.diff })
    end
    local chance = 0.22 * (HR.Relic(g, "highroller") and 2 or 1)
    if g.rand.chance(chance) then HR.DropPower(g, e.x, e.y)
    elseif g.rand.chance(0.12) then HR.DropPickup(g, { kind = "heart", x = e.x, y = e.y, v = 10 }) end
    HR.Fx(g, "puff", e.x, e.y, 0.4, { size = 30 })
    HR.Event(g, "roll")
    g.propsBroken = (g.propsBroken or 0) + 1
end

function HR.SpawnProp(g, x, y, sprite)
    local e = { kind = "prop", obj = "prop", soft = true, x = x, y = y, r = 12, size = 30, sprite = sprite or PROPS[g.rand.i(1, #PROPS)],
        hp = 7 * HR.ROOM_HP[g.diff], dmg = 0, xp = 0, t = 0, stun = 0, slow = 0, jinx = 0, oh = {}, def = { name = "furniture", heavy = true },
        step = PropStep, onDeath = PropBreak }
    e.maxhp = e.hp
    g.enemies[#g.enemies + 1] = e
    return e
end

---------------------------------------------------------------------------
-- Room events and the mini-boss
---------------------------------------------------------------------------
HR.ENEMIES.goldimp = { name = "Golden Imp", sprite = "goldimp", hp = 34, speed = 100, r = 8, xp = 3 }
HR.ENEMIES.enforcer = { name = "The Enforcer", sprite = "enforcer", hp = 200, speed = 40, r = 15, xp = 12, size = 46, heavy = true }

local function NearPlayer(g, lo, hi)
    local a, r = g.rand.f() * 2 * pi, lo + g.rand.f() * (hi - lo)
    local b = g.bounds
    return clamp(g.pl.x + cos(a) * r, b[1] + 24, b[3] - 24), clamp(g.pl.y + sin(a) * r, b[2] + 24, b[4] - 24)
end

local function ImpStep(g, e, dt)
    local pl, b = g.pl, g.bounds
    e.life = (e.life or 13) - dt
    if e.life <= 0 then
        e.dead = true
        HR.Text(g, e.x, e.y + 12, "It got away!", "ffaaaaaa")
        return
    end
    -- runs from you; along a wall when cornered
    local a = atan2(e.y - pl.y, e.x - pl.x)
    local vx, vy = cos(a), sin(a)
    if (e.x <= b[1] + 14 and vx < 0) or (e.x >= b[3] - 14 and vx > 0) then vx, vy = 0, (vy >= 0 and 1 or -1) end
    if (e.y <= b[2] + 14 and vy < 0) or (e.y >= b[4] - 14 and vy > 0) then vy, vx = 0, (vx >= 0 and 1 or -1) end
    local sp = e.speed * ((e.slow or 0) > 0 and 0.6 or 1)
    e.x, e.y = clamp(e.x + vx * sp * dt, b[1] + 10, b[3] - 10), clamp(e.y + vy * sp * dt, b[2] + 10, b[4] - 10)
end

local function EnforcerStep(g, e, dt)
    local pl = g.pl
    local d = dist(e.x, e.y, pl.x, pl.y)
    local sp = e.speed * ((e.slow or 0) > 0 and 0.6 or 1)
    if d > 1 and not e.winding then e.x, e.y = e.x + (pl.x - e.x) / d * sp * dt, e.y + (pl.y - e.y) / d * sp * dt end
    if d <= e.r + HR.PLAYER.r - 2 then HR.Hurt(g, e.dmg * 0.8, "the Enforcer") end
    e.slamT = (e.slamT or 2.5) - dt
    if e.winding then
        e.winding = e.winding - dt
        if e.winding <= 0 then e.winding = nil end
    elseif e.slamT <= 0 and d < 170 then
        -- a slam where he stands, then a ring further out
        e.slamT, e.winding = 3.4, 1.0
        HR.Danger(g, { shape = "circle", x = e.x, y = e.y, r = 72, warn = 1.1, dmg = e.dmg, name = "a slam" })
        HR.Danger(g, { shape = "ring", x = e.x, y = e.y, r1 = 72, r2 = 128, warn = 1.6, dmg = e.dmg * 0.8, name = "a slam" })
    end
end

local EVENTS = {
    function(g) -- a golden imp to chase
        local x, y = NearPlayer(g, 110, 160)
        local e = HR.Spawn(g, "goldimp", x, y, { force = true, step = ImpStep, special = true })
        e.onDeath = function(gg, me)
            for i = 1, 10 do
                HR.DropPickup(gg, { kind = "chip", x = me.x + gg.rand.i(-22, 22), y = me.y + gg.rand.i(-22, 22), v = 3 * gg.diff })
            end
            HR.DropPower(gg, me.x, me.y)
            HR.Fx(gg, "ring", me.x, me.y, 0.4, { r = 40 })
        end
        HR.Banner(g, "|cffffd100A golden imp!|r Catch it before it gets away.", 3)
    end,
    function(g) -- a ring of enemies closing in
        local kind = HR.ROOMS[g.roomIdx].mix[1][1]
        local b = g.bounds
        for i = 1, 10 do
            local a = i / 10 * 2 * pi
            HR.Spawn(g, kind, clamp(g.pl.x + cos(a) * 215, b[1] + 10, b[3] - 10), clamp(g.pl.y + sin(a) * 230, b[2] + 10, b[4] - 10))
        end
        HR.Banner(g, "|cffff8040They're closing in!|r", 2.5)
    end,
    function(g) -- a lucky table: stand at it for a buff
        local x, y = NearPlayer(g, 130, 210)
        local z = { side = "deco", shape = "circle", x = x, y = y, r = 46, warn = 0, dur = 16, tint = "table" }
        g.zones[#g.zones + 1] = z
        g.table = { x = x, y = y, r = 46, have = 0, need = 4, zone = z }
        HR.Banner(g, "|cff20ff20A lucky table.|r Stand at it for four seconds.", 3.5)
    end,
    function(g) -- a high roller and his guards
        local mix = HR.ROOMS[g.roomIdx].mix
        local kind = mix[g.rand.i(1, #mix)][1]
        if HR.ENEMIES[kind].mimic then kind = mix[1][1] end
        local x, y = NearPlayer(g, 230, 260)
        HR.Spawn(g, kind, x, y, { elite = true, force = true })
        for i = 1, 4 do HR.Spawn(g, kind, x + g.rand.i(-26, 26), y + g.rand.i(-26, 26)) end
        HR.Banner(g, "|cffc070ffA high roller has walked in.|r", 2.5)
    end,
}
HR.EVENTS = EVENTS

--- Called at the start of each room: furniture, and the timers for events and the mini-boss.
function HR.RoomExtras(g)
    g.eventT, g.miniDone, g.table, g.crateDone = (22 + g.rand.f() * 6) * HR.WAVE_PACE, nil, nil, nil
    g.sched = {}
    local b = g.bounds
    local cx, cy = (b[1] + b[3]) / 2, (b[2] + b[4]) / 2
    local placed = {}
    for _ = 1, 11 do
        for _try = 1, 8 do
            local x, y = g.rand.i(b[1] + 40, b[3] - 40), g.rand.i(b[2] + 40, b[4] - 40)
            local ok = dist(x, y, cx, cy) > 110
            for _, p in ipairs(placed) do if dist(x, y, p[1], p[2]) < 90 then ok = false end end
            if ok then
                placed[#placed + 1] = { x, y }
                HR.SpawnProp(g, x, y)
                break
            end
        end
    end
end

--- Every step of the waves.
function HR.StepEvents(g, dt)
    if not g.crateDone and g.roomTime >= HR.CRATE_AT then
        g.crateDone = true
        local x, y = NearPlayer(g, 80, 120)
        if HR.DropCrate(g, x, y) then
            HR.Fx(g, "ring", x, y, 0.5, { r = 50 })
            HR.Banner(g, "|cffffd100A weapon crate!|r Walk over it.", 3)
        end
    end
    -- the mini-boss, halfway through
    if not g.miniDone and g.roomTime >= HR.WAVE_TIME * 0.5 then
        g.miniDone = true
        local x, y = NearPlayer(g, 240, 270)
        local e = HR.Spawn(g, "enforcer", x, y, { force = true, step = EnforcerStep, mini = true, elite = true })
        e.trait = nil
        HR.Banner(g, "|cffff8040The Enforcer|r wants a word. Beat him to bring out the boss.", 3.5)
        HR.Event(g, "boss")
    end
    g.eventT = (g.eventT or 15) - dt
    if g.eventT <= 0 and g.roomTime < HR.WAVE_TIME - 10 then
        g.eventT = (20 + g.rand.f() * 6) * HR.WAVE_PACE
        local i = g.rand.i(1, #EVENTS)
        if i == 3 and g.table then i = 1 end
        EVENTS[i](g)
        g.eventsSeen = (g.eventsSeen or 0) + 1
    end
    local t = g.table
    if t then
        if t.zone.dur <= 0 then
            g.table = nil
        elseif dist(g.pl.x, g.pl.y, t.x, t.y) <= t.r then
            t.have = t.have + dt
            if t.have >= t.need then
                g.table = nil
                t.zone.dur = 0
                g.luck = g.luck + 3
                HR.UsePower(g, ({ "boots", "hand", "guard" })[g.rand.i(1, 3)])
                HR.Banner(g, "|cff20ff20The table pays out:|r +3 Luck and a boost.", 3)
            end
        end
    end
end

--- Everything Extras adds when an enemy dies.
function HR.OnKill(g, e, wid)
    if e.obj then return end
    HR.Fx(g, "puff", e.x, e.y, 0.3, { size = e.size })
    if e.boss then return end
    -- the Enforcer is down: the boss is on his way
    if e.mini and g.phase == "waves" and not g.bossAt then
        g.bossAt = g.roomTime + HR.BOSS_DELAY
        HR.Banner(g, "|cffff8040The Enforcer is down.|r The boss is on his way - grab the chest.", HR.BOSS_DELAY)
    end
    if e.mini or (e.elite and g.rand.chance(0.35)) then
        HR.DropPickup(g, { kind = "chest", x = e.x, y = e.y })
    end
    local chance = 0.006 * (HR.Relic(g, "highroller") and 2 or 1) * (1 + (g.luckNow or 0) * 0.02)
    if g.rand.chance(chance) then HR.DropPower(g, e.x, e.y) end
end

---------------------------------------------------------------------------
-- Boss barrages: bursts of quick, small attacks to weave through. Every one is drawn first.
---------------------------------------------------------------------------
local BARRAGES = {
    function(g, dmg) -- circles that follow where you are
        for i = 0, 7 do
            HR.After(g, i * 0.27, function(gg)
                HR.Danger(gg, { shape = "circle", x = gg.pl.x, y = gg.pl.y, r = 26, warn = 0.75, dmg = dmg, name = "a barrage" })
            end)
        end
    end,
    function(g, dmg) -- lanes sweeping across the room
        local fromLeft = g.rand.chance(0.5)
        for i = 0, 6 do
            local x = fromLeft and (28 + i * 57) or (W - 28 - i * 57)
            HR.After(g, i * 0.2, function(gg)
                HR.Danger(gg, { shape = "lane", x1 = x, y1 = 0, x2 = x, y2 = H, w = 20, warn = 0.8, dmg = dmg, name = "a sweep" })
            end)
        end
    end,
    function(g, dmg) -- a rain of circles, a few aimed
        for i = 0, 11 do
            HR.After(g, i * 0.17, function(gg)
                local x, y = gg.rand.i(26, W - 26), gg.rand.i(26, H - 80)
                if i % 4 == 0 then x, y = gg.pl.x, gg.pl.y end
                HR.Danger(gg, { shape = "circle", x = x, y = y, r = 30, warn = 0.85, dmg = dmg, name = "a barrage" })
            end)
        end
    end,
    function(g, dmg) -- a cross through where you stand, then the diagonals
        local x, y = g.pl.x, g.pl.y
        HR.Danger(g, { shape = "lane", x1 = 0, y1 = y, x2 = W, y2 = y, w = 16, warn = 0.85, dmg = dmg, name = "a cross" })
        HR.Danger(g, { shape = "lane", x1 = x, y1 = 0, x2 = x, y2 = H, w = 16, warn = 0.85, dmg = dmg, name = "a cross" })
        HR.After(g, 0.7, function(gg)
            HR.Danger(gg, { shape = "lane", x1 = x - 400, y1 = y - 400, x2 = x + 400, y2 = y + 400, w = 16, warn = 0.85, dmg = dmg, name = "a cross" })
            HR.Danger(gg, { shape = "lane", x1 = x - 400, y1 = y + 400, x2 = x + 400, y2 = y - 400, w = 16, warn = 0.85, dmg = dmg, name = "a cross" })
        end)
    end,
}
HR.BARRAGES = BARRAGES

--- Called every step of a boss fight.
function HR.StepBarrage(g, dt)
    g.barrageT = (g.barrageT or 6) - dt
    if g.barrageT > 0 then return end
    local t = g.bossTime or 0
    g.barrageT = (t > 45 and 5 or 7.5) * ((g.stakes or 0) >= 2 and 0.85 or 1)
    BARRAGES[g.rand.i(1, #BARRAGES)](g, HR.ROOM_DMG[g.diff])
    g.barrages = (g.barrages or 0) + 1
end
