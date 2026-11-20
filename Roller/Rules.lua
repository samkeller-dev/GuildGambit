-- Roller/Rules.lua: High Roller's rules with no drawing in them - random numbers, saved
-- progress, talents, stats, suits, dice, poker hands, the coin, level-up cards, scoring.
-- Everything here runs the same in the game and in the mock-client tests.
local ADDON_NAME, ns = ...
local HR = ns.Roller

---------------------------------------------------------------------------
-- Seeded random numbers (Park-Miller, like Kodo Crossing)
---------------------------------------------------------------------------
function HR.NewRand(seed)
    local state = math.floor(seed or 1) % 2147483647
    if state <= 0 then state = state + 2147483646 end
    local R = {}
    function R.f()
        state = (state * 16807) % 2147483647
        return state / 2147483647
    end
    function R.i(a, b) return a + math.floor(R.f() * (b - a + 1)) end
    function R.chance(p) return R.f() < p end
    function R.pick(list) return list[R.i(1, #list)] end
    --- Picks an index by weight; weights is a list of numbers.
    function R.weighted(weights)
        local total = 0
        for _, w in ipairs(weights) do total = total + w end
        if total <= 0 then return nil end
        local x = R.f() * total
        for i, w in ipairs(weights) do
            x = x - w
            if x < 0 then return i end
        end
        return #weights
    end
    return R
end

local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end
HR.clamp = clamp

---------------------------------------------------------------------------
-- Saved progress: account-wide, never sent anywhere
---------------------------------------------------------------------------
function HR.DB()
    ns.db = ns.db or {}
    local db = ns.db.roller
    if not db then
        db = {}
        ns.db.roller = db
    end
    db.cls = db.cls or {}
    db.ach = db.ach or {}
    db.bests = db.bests or {}
    db.journal = db.journal or {}
    db.stats = db.stats or { runs = 0, died = 0, walked = 0, won = 0 }
    db.opts = db.opts or { shake = true, numbers = true }
    db.class = db.class or "dice"
    db.mode = db.mode or "full"
    db.stakes = db.stakes or 0
    return db
end

function HR.ClassDB(id)
    local db = HR.DB()
    local c = db.cls[id]
    if not c then
        c = { xp = 0, level = 1, talents = {}, firsts = {} }
        db.cls[id] = c
    end
    c.talents, c.firsts = c.talents or {}, c.firsts or {}
    return c
end

function HR.Has(ach) return HR.DB().ach[ach] ~= nil end

--- Marks an achievement; returns true the first time.
function HR.Earn(ach)
    local db = HR.DB()
    if db.ach[ach] or not HR.ACH[ach] then return false end
    db.ach[ach] = time and time() or 1
    return true
end

function HR.ClassUnlocked(id)
    local c = HR.CLASS[id]
    return c ~= nil and not c.soon and (not c.need or HR.Has(c.need))
end

--- Achievements that can be earned with the classes that are out (the list the player sees).
function HR.OpenAchievements()
    local out = {}
    for _, a in ipairs(HR.ACHIEVEMENTS) do
        if (not a.class or not HR.CLASS[a.class].soon) and (not a.bets or HR.BETS_ON) then out[#out + 1] = a end
    end
    return out
end

function HR.WeaponUnlocked(w) return not w.ach or HR.Has(w.ach) end
function HR.RelicUnlocked(r) return not r.ach or HR.Has(r.ach) end

--- Systems a new player meets one at a time.
function HR.Feature(name)
    local db = HR.DB()
    if name == "bets" then return HR.BETS_ON and HR.Has("boss1") end
    if name == "heat" then return HR.Has("boss1") end
    if name == "cursed" then return HR.Has("boss2") end
    if name == "rules" or name == "quick" then return (db.stats.runs or 0) >= 2 end
    if name == "stakes1" then return HR.Has("house") end
    if name == "stakes2" then return db.stakes1Won == true end
    return true
end

function HR.MaxStakes()
    return HR.Feature("stakes2") and 2 or (HR.Feature("stakes1") and 1 or 0)
end

---------------------------------------------------------------------------
-- Class levels and talents
---------------------------------------------------------------------------
function HR.ClassXpNeed(level) return 60 + 40 * level end

--- Adds class experience; returns how many levels were gained.
function HR.AddClassXp(id, xp)
    local c = HR.ClassDB(id)
    local gained = 0
    c.xp = c.xp + math.max(0, math.floor(xp))
    while c.level < HR.MAX_CLASS_LEVEL + 1 and c.xp >= HR.ClassXpNeed(c.level) do
        c.xp = c.xp - HR.ClassXpNeed(c.level)
        c.level = c.level + 1
        gained = gained + 1
    end
    if c.level >= HR.MAX_CLASS_LEVEL + 1 then c.xp = 0 end
    return gained
end

local function FindTalent(classId, talentId)
    for ti, tree in ipairs(HR.TALENTS[classId] or {}) do
        for ri, row in ipairs(tree.rows) do
            if row.id == talentId then return row, ti, ri end
        end
    end
end
HR.FindTalent = FindTalent

function HR.TalentPoints(id)
    local c = HR.ClassDB(id)
    local firsts = 0
    for _ in pairs(c.firsts) do firsts = firsts + 1 end
    return math.min(HR.TALENT_CAP, math.min(HR.MAX_CLASS_LEVEL, c.level - 1) + math.min(5, firsts))
end

function HR.TalentsSpent(id, tree)
    local c = HR.ClassDB(id)
    local n = 0
    for ti, t in ipairs(HR.TALENTS[id] or {}) do
        if not tree or tree == ti then
            for _, row in ipairs(t.rows) do n = n + (c.talents[row.id] or 0) end
        end
    end
    return n
end

function HR.CanLearn(id, talentId)
    local row, ti, ri = FindTalent(id, talentId)
    if not row then return false end
    local c = HR.ClassDB(id)
    if (c.talents[talentId] or 0) >= row.max then return false end
    if HR.TalentsSpent(id) >= HR.TalentPoints(id) then return false end
    return HR.TalentsSpent(id, ti) >= (ri - 1) * HR.TALENT_ROW
end

function HR.Learn(id, talentId)
    if not HR.CanLearn(id, talentId) then return false end
    local c = HR.ClassDB(id)
    c.talents[talentId] = (c.talents[talentId] or 0) + 1
    return true
end

function HR.ResetTalents(id) HR.ClassDB(id).talents = {} end

---------------------------------------------------------------------------
-- A run's build: helpers on the run table g
---------------------------------------------------------------------------
--- Talent rank in this run (copied from the class at the start, so a respec can't change a run).
function HR.T(g, talentId) return g.talents[talentId] or 0 end
function HR.Charm(g, id) return g.charms[id] or 0 end
function HR.CharmMax(g, id) return (g.charms[id] or 0) >= HR.CHARM[id].max end
function HR.Relic(g, id) return g.relics[id] == true end

function HR.FindWeapon(g, id)
    for _, w in ipairs(g.weapons) do if w.id == id then return w end end
end

--- A weapon's value at its level: arrays stop at 5; Pocket Aces' sixth level adds 25% damage.
function HR.WVal(w, field)
    local def = HR.WEAPON[w.id]
    local a = def[field]
    if type(a) ~= "table" then return a end
    local v = a[math.min(w.lvl, HR.WEAPON_MAX)]
    if field == "dmg" and w.lvl > HR.WEAPON_MAX then v = v * 1.25 end
    return v
end

function HR.CharmTypes(g)
    local n = 0
    for _, c in pairs(g.charms) do if c > 0 then n = n + 1 end end
    return n
end

---------------------------------------------------------------------------
-- Suits: count the pieces, name the hand, set the bonuses
---------------------------------------------------------------------------
--- Returns counts by suit and a table of bonus flags, and stores both on g.
function HR.Suits(g)
    local n = { S = 0, H = 0, D = 0, C = 0 }
    local wild = 0
    for _, w in ipairs(g.weapons) do
        local s = HR.WEAPON[w.id].suit
        if s == "J" then wild = wild + 1 else n[s] = n[s] + 1 end
    end
    for id, c in pairs(g.charms) do
        if c > 0 then n[HR.CHARM[id].suit] = n[HR.CHARM[id].suit] + 1 end
    end
    for s, extra in pairs(g.lentSuit or {}) do
        if extra.till > g.time then n[s] = n[s] + extra.n end
    end
    -- the Wild Card joins your biggest suit (your class's suit on a tie)
    if wild > 0 then
        local best, bn = HR.CLASS[g.class].suit, -1
        for _, s in ipairs(HR.SUITS) do
            if n[s] > bn or (n[s] == bn and s == HR.CLASS[g.class].suit) then best, bn = s, n[s] end
        end
        n[best] = n[best] + wild
    end
    local b = { n = n }
    local names, three, pair = {}, nil, nil
    local full = true
    for _, s in ipairs(HR.SUITS) do
        local c = n[s]
        if c < 2 then full = false end
        if c >= 5 then b[s] = 3 names[#names + 1] = "Flush " .. HR.SUIT_NAME[s]
        elseif c >= 3 then b[s] = 2 names[#names + 1] = "Three of a Kind " .. HR.SUIT_NAME[s]
        elseif c >= 2 then b[s] = 1 names[#names + 1] = "Pair " .. HR.SUIT_NAME[s]
        else b[s] = 0 end
        if c >= 3 and not three then three = s elseif c >= 2 and c < 3 and not pair then pair = s end
    end
    -- three (or more) of one suit and exactly a pair of another: the pair's bonus is doubled
    if three and pair then b.fullHouse = pair names[#names + 1] = "Full House" end
    if full then b.fullDeck = true names[#names + 1] = "Full Deck" end
    b.name = #names > 0 and table.concat(names, ", ") or "No hand yet"
    g.suits = b
    return n, b
end

---------------------------------------------------------------------------
-- Luck and stats
---------------------------------------------------------------------------
--- Luck as the game uses it: locked by Broken Mirror, drained by The House, worth half past 25.
function HR.Luck(g)
    if HR.Relic(g, "mirror") then return 0 end
    local raw = (g.luck or 0) + (g.st and g.st.luck or 0)
    if not HR.Relic(g, "ladyluck") then raw = raw * (1 - (g.luckDrain or 0)) end
    if raw > 25 then raw = 25 + (raw - 25) * 0.5 end
    return math.max(0, raw)
end

--- Rebuilds g.st from the class, talents, charms, relics, suits, the House Rule and buffs.
function HR.Recalc(g)
    local P = HR.PLAYER
    local T, C, R = function(id) return HR.T(g, id) end, function(id) return HR.Charm(g, id) end, function(id) return HR.Relic(g, id) end
    local _, sb = HR.Suits(g)
    local st = { dmg = 1, atk = 1, area = 1, speed = P.speed, pickup = P.pickup, armor = 0, luck = 0,
        luckyMult = P.luckyMult, bounce = 0, pierce = 0, minRoll = 0, chip = 1, heal = 1, maxhp = P.hp,
        loaded = 0, iframes = P.iframes, jinxDur = 5, jinxAmp = 0.25 }
    local pl = g.pl
    -- charms
    st.minRoll = C("weighted")
    st.atk = st.atk + 0.08 * C("glove")
    local calm = pl and (pl.hp >= (g.st and g.st.maxhp or P.hp) or (HR.CharmMax(g, "pokerface") and (pl.shield or 0) > 0))
    if calm then st.dmg = st.dmg + 0.10 * C("pokerface") end
    st.luckyMult = st.luckyMult + 0.25 * C("gambler")
    st.pierce = C("nail")
    st.area = st.area + 0.12 * C("chalk")
    st.iframes = st.iframes + 0.2 * C("watch")
    st.luck = st.luck + 4 * C("fourleaf")
    st.chip = st.chip + 0.10 * C("luckycoin") + 0.05 * HR.T(g, "df4")
    st.pickup = st.pickup * (1 + 0.15 * C("penny"))
    st.bounce = C("marbles")
    st.heal = st.heal + 0.15 * C("helping")
    st.speed = st.speed * (1 + 0.06 * C("shoes"))
    st.loaded = 0.05 * C("shaved") + 0.03 * T("dl1")
    -- talents
    st.luck = st.luck + 3 * T("df1")
    st.bounce = st.bounce + T("dr1")
    st.jinxDur = st.jinxDur * (1 + 0.2 * T("cs1"))
    if g.handsPlayed and T("cq4") > 0 then st.atk = st.atk + math.min(0.3, g.handsPlayed * 0.015 * T("cq4")) end
    -- suits
    local function tier(s) return sb[s] or 0 end
    local function doubled(s) return sb.fullHouse == s and 2 or 1 end
    if tier("S") >= 1 then st.dmg = st.dmg + 0.15 * doubled("S") end
    if tier("D") >= 1 then st.luck = st.luck + 5 * doubled("D") end
    st.luckyTwice = tier("S") >= 2
    st.execute = tier("S") >= 3
    st.healPerKills = tier("H") >= 1 and (sb.fullHouse == "H" and 5 or 10) or nil
    st.overheal = tier("H") >= 2
    st.pulse = tier("H") >= 3
    st.rare = tier("D") >= 2
    st.magnet = tier("D") >= 3
    st.knock = tier("C") >= 1 and (sb.fullHouse == "C" and 2 or 1) or 0
    st.punish = tier("C") >= 2
    st.lockdown = tier("C") >= 3
    st.fullDeck = sb.fullDeck
    if sb.fullDeck then st.minRoll = math.max(st.minRoll, 3) end
    -- relics
    if R("mirror") then st.dmg = st.dmg + 0.6 end
    if R("glass") then st.dmg = st.dmg * 2 st.maxhp = st.maxhp * 0.5 end
    if R("badpenny") then st.luck = st.luck + 15 end
    if R("ladyluck") then st.luck = st.luck + 20 end
    if R("loanmark") then st.chip = st.chip + 1 end
    if R("allin") and pl and pl.hp <= 1 then st.dmg = st.dmg * 2 st.chip = st.chip + 1 end
    if R("chair") and pl then st.atk = st.atk * ((pl.still or 0) > 0.3 and 2 or 0.5) end
    -- the House Rule
    local rule = g.rule
    if rule == "happy" then st.chip = st.chip + 1 end
    if rule == "dry" then st.heal = 0 st.chip = st.chip + 0.5 end
    if rule == "fast" then st.atk = st.atk * 1.3 end
    if rule == "loose" then st.advantage = 1 end
    if HR.CharmMax(g, "fourleaf") then st.advantage = math.max(st.advantage or 0, 0.2) end
    -- the Coin Flipper's side
    if g.class == "coin" and g.coin then
        local s = g.coin.streak
        local w = HR.FindWeapon(g, "trickcoin")
        local step = w and HR.WVal(w, "step") or 1
        if g.coin.side == "H" then
            st.dmg = st.dmg + 0.10 + s * (0.06 + 0.02 * T("oh1")) * step
        else
            st.armor = st.armor + 2 + s * (1 + T("ot1")) * step
            st.speed = st.speed * (1.08 + 0.01 * s)
        end
    end
    -- short buffs (Make a Wish, the damage boost of Second Helping...)
    for i = #(g.buffs or {}), 1, -1 do
        local b = g.buffs[i]
        if b.till <= g.time then table.remove(g.buffs, i)
        else
            st.dmg = st.dmg + (b.dmg or 0)
            st.atk = st.atk + (b.atk or 0)
            st.speed = st.speed * (1 + (b.speed or 0))
            st.luck = st.luck + (b.luck or 0)
        end
    end
    -- chip boosts only ever double the drops
    st.chip = math.min(st.chip, HR.Relic(g, "allin") and 3 or 2)
    g.st = st
    g.luckNow = HR.Luck(g)
    st.luckyChance = clamp(P.luckyChance + g.luckNow * 0.01, 0, 0.6)
    if pl and pl.hp > st.maxhp then pl.hp = st.maxhp end
    return st
end

---------------------------------------------------------------------------
-- Rolls
---------------------------------------------------------------------------
--- A fraction 0-1 for anything that "rolls" (damage spread, reels...), raised by Weighted Die.
function HR.Roll(g)
    local r = g.rand.f()
    local st = g.st
    if st.advantage and (st.advantage >= 1 or g.rand.chance(st.advantage)) then r = math.max(r, g.rand.f()) end
    local floor = st.minRoll / 6
    if r < floor then r = floor + g.rand.f() * (1 - floor) end
    return r
end

--- One die face. Luck gives a second try at a better face; Weighted Die removes low faces.
function HR.RollDie(g, sides)
    sides = sides or 6
    local lo = math.min(sides - 2, 1 + g.st.minRoll)
    local v = g.rand.i(lo, sides)
    local again = math.min(0.5, (g.luckNow or 0) * 0.01)
    if g.st.advantage and (g.st.advantage >= 1 or g.rand.chance(g.st.advantage)) then again = 1 end
    if again > 0 and g.rand.chance(again) then v = math.max(v, g.rand.i(lo, sides)) end
    return v
end

--- The chance of doubles on two dice with this build (never above 60%).
function HR.DoublesChance(g)
    local faces = 6 - math.min(4, g.st.minRoll)
    local base = 1 / faces
    return math.min(0.6, base + g.st.loaded * (1 - base))
end

--- Throws n dice. held: faces picked up off the floor (used if they beat a die).
--- Returns the faces and "triple", "double", "snake" or nil.
function HR.ThrowDice(g, n, held)
    local faces = {}
    faces[1] = HR.RollDie(g)
    local faceCount = 6 - math.min(4, g.st.minRoll)
    local base = 1 / faceCount
    -- Loaded: the second die copies the first often enough to hit the build's doubles chance
    local want = HR.DoublesChance(g)
    local copy = (want - base) / (1 - base)
    for i = 2, n do
        if i == 2 and copy > 0 and g.rand.chance(copy) then faces[i] = faces[1]
        else faces[i] = HR.RollDie(g) end
    end
    -- dice picked up off the floor replace the worst dice they beat
    if held and #held > 0 then
        table.sort(held, function(a, b) return a > b end)
        for _, h in ipairs(held) do
            local worst = 1
            for i = 2, n do if faces[i] < faces[worst] then worst = i end end
            if h > faces[worst] then faces[worst] = h end
        end
        -- two held dice with the same face: a guaranteed double
        if #held >= 2 and held[1] == held[2] and n >= 2 then faces[1], faces[2] = held[1], held[2] end
    end
    local count, top = {}, 0
    for _, f in ipairs(faces) do
        count[f] = (count[f] or 0) + 1
        if count[f] > top then top = count[f] end
    end
    local kind
    if top >= 3 then kind = "triple"
    elseif top >= 2 then
        kind = (faces[1] == 1 and faces[2] == 1 and n == 2) and "snake" or "double"
    end
    -- never two fizzles running
    if kind == "snake" then
        if g.lastSnake then
            faces[2] = HR.RollDie(g)
            if faces[2] == 1 then faces[2] = 2 end
            kind = nil
        end
    end
    g.lastSnake = kind == "snake"
    return faces, kind
end

--- The coin's chance of landing your way.
function HR.FlipOdds(g)
    local p = 0.5 + (g.luckNow or 0) * 0.005 + 0.04 * HR.Charm(g, "thumb") + 0.02 * HR.T(g, "oe1")
    return clamp(p, 0.3, 0.7)
end

function HR.StreakCap(g) return 8 + HR.T(g, "oe4") end

--- Flips. Returns true if it landed on your side. Applies the streak.
function HR.Flip(g)
    local c = g.coin
    local won
    if c.free then won, c.free = true, nil
    elseif (c.lost or 0) >= 2 then won = true -- never three lost flips running
    else won = g.rand.chance(HR.FlipOdds(g)) end
    if won then
        c.lost = 0
        local w = HR.FindWeapon(g, "trickcoin")
        c.streak = math.min(HR.StreakCap(g), c.streak + ((w and w.evo) and 2 or 1))
        c.best = math.max(c.best or 0, c.streak)
    else
        c.lost = (c.lost or 0) + 1
        c.side = c.side == "H" and "T" or "H"
        c.streak = HR.CharmMax(g, "thumb") and math.min(1, c.streak) or 0
    end
    return won
end

---------------------------------------------------------------------------
-- Poker hands. A card is { r = 2..14, s = "S"/"H"/"D"/"C" } or { joker = true }.
---------------------------------------------------------------------------
local function Eval5(cards)
    local count, suits, ranks = {}, {}, {}
    for _, c in ipairs(cards) do
        count[c.r] = (count[c.r] or 0) + 1
        suits[c.s] = (suits[c.s] or 0) + 1
        ranks[#ranks + 1] = c.r
    end
    local flushSuit
    for s, n in pairs(suits) do if n == 5 then flushSuit = s end end
    table.sort(ranks)
    local straight = true
    for i = 2, 5 do if ranks[i] ~= ranks[i - 1] + 1 then straight = false end end
    -- the wheel: A-2-3-4-5
    if not straight and ranks[1] == 2 and ranks[2] == 3 and ranks[3] == 4 and ranks[4] == 5 and ranks[5] == 14 then straight = true end
    local groups = {}
    for r, n in pairs(count) do groups[#groups + 1] = { r = r, n = n } end
    table.sort(groups, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.r > b.r end)
    local a, b = groups[1].n, groups[2] and groups[2].n or 0
    local rank
    if straight and flushSuit then rank = 9
    elseif a == 4 then rank = 8
    elseif a == 3 and b == 2 then rank = 7
    elseif flushSuit then rank = 6
    elseif straight then rank = 5
    elseif a == 3 then rank = 4
    elseif a == 2 and b == 2 then rank = 3
    elseif a == 2 then rank = 2
    else rank = 1 end
    -- a tie-break number so "best of six" and Jokers pick the stronger version of a rank
    local tie = groups[1].r * 15 + (groups[2] and groups[2].r or 0)
    return rank, flushSuit, tie
end

local ALL_CARDS
local function AllCards()
    if not ALL_CARDS then
        ALL_CARDS = {}
        for _, s in ipairs(HR.SUITS) do
            for r = 2, 14 do ALL_CARDS[#ALL_CARDS + 1] = { r = r, s = s } end
        end
    end
    return ALL_CARDS
end

--- Best reading of exactly five cards, Jokers counting as anything.
local function EvalJokers(cards)
    local plain, jokers = {}, 0
    for _, c in ipairs(cards) do
        if c.joker then jokers = jokers + 1 else plain[#plain + 1] = c end
    end
    if jokers == 0 then return Eval5(plain) end
    -- more than two Jokers: the extras become aces of the suit we hold most (keeps this quick)
    while jokers > 2 do
        local suit, sn, seen = "S", 0, {}
        for _, c in ipairs(plain) do seen[c.s] = (seen[c.s] or 0) + 1 if seen[c.s] > sn then suit, sn = c.s, seen[c.s] end end
        plain[#plain + 1] = { r = 14, s = suit }
        jokers = jokers - 1
    end
    local best, bestSuit, bestTie = 0, nil, -1
    local all = AllCards()
    local function try(hand)
        local rank, suit, tie = Eval5(hand)
        if rank > best or (rank == best and tie > bestTie) then best, bestSuit, bestTie = rank, suit, tie end
    end
    local n = #plain
    if jokers == 1 then
        for _, x in ipairs(all) do plain[n + 1] = x try(plain) end
    else
        for _, x in ipairs(all) do
            plain[n + 1] = x
            for _, y in ipairs(all) do plain[n + 2] = y try(plain) end
        end
    end
    return best, bestSuit, bestTie
end

--- Rank 1-9 (HR.HANDS), the flush suit if any, and which five played. Takes five or six cards.
function HR.EvalHand(cards)
    if #cards <= 5 then
        local rank, suit, tie = EvalJokers(cards)
        return rank, suit, cards, tie
    end
    local best, bestSuit, bestSet, bestTie = 0, nil, nil, -1
    for skip = 1, #cards do
        local five = {}
        for i, c in ipairs(cards) do if i ~= skip then five[#five + 1] = c end end
        local rank, suit, tie = EvalJokers(five)
        if rank > best or (rank == best and tie > bestTie) then best, bestSuit, bestSet, bestTie = rank, suit, five, tie end
    end
    return best, bestSuit, bestSet, bestTie
end

--- How promising a part-built hand is: matching ranks count most, then one suit.
function HR.HandPromise(cards)
    local count, suits, top, topSuit, jokers = {}, {}, 0, 0, 0
    for _, c in ipairs(cards) do
        if c.joker then jokers = jokers + 1
        else
            count[c.r] = (count[c.r] or 0) + 1
            suits[c.s] = (suits[c.s] or 0) + 1
            if count[c.r] > top then top = count[c.r] end
            if suits[c.s] > topSuit then topSuit = suits[c.s] end
        end
    end
    local pairsN = 0
    for _, n in pairs(count) do if n >= 2 then pairsN = pairsN + 1 end end
    return (top + jokers) * 10 + pairsN * 4 + topSuit + jokers, top + jokers, topSuit + jokers
end

--- A few words for the HUD about the hand so far.
function HR.HandText(cards)
    if #cards == 0 then return "no cards" end
    if #cards >= 5 then return HR.HANDS[(HR.EvalHand(cards))] end
    local _, same, suited = HR.HandPromise(cards)
    local parts = {}
    if same >= 4 then parts[#parts + 1] = "four alike"
    elseif same == 3 then parts[#parts + 1] = "three alike"
    elseif same == 2 then parts[#parts + 1] = "a pair" end
    if suited >= 3 then parts[#parts + 1] = suited .. " of a suit" end
    if #parts == 0 then parts[1] = #cards .. (#cards == 1 and " card" or " cards") end
    return table.concat(parts, ", ")
end

--- A random card drop for the Card Sharp, shaped by talents, charms and Luck.
function HR.DrawCard(g)
    local jokerChance = 0.02 + 0.03 * HR.Charm(g, "joker") + (g.luckNow or 0) * 0.001
    if HR.FindWeapon(g, "wild") then jokerChance = jokerChance + 0.04 end
    if g.rand.chance(jokerChance) then return { joker = true } end
    local lo = (HR.T(g, "ch2") > 0) and 4 or 2
    lo = math.min(10, lo + 2 * g.st.minRoll) -- Weighted Die: no low cards
    local r = g.rand.i(lo, 14)
    -- Luck: a second try at a face card
    if r < 11 and g.rand.chance(math.min(0.4, (g.luckNow or 0) * 0.01)) then r = math.max(r, g.rand.i(lo, 14)) end
    local s = HR.SUITS[g.rand.i(1, 4)]
    local lean = 0.2 * HR.T(g, "cs4")
    if lean > 0 and g.hand and #g.hand > 0 and g.rand.chance(lean) then
        local seen, best, bn = {}, s, 0
        for _, c in ipairs(g.hand) do
            if c.s then seen[c.s] = (seen[c.s] or 0) + 1 if seen[c.s] > bn then best, bn = c.s, seen[c.s] end end
        end
        s = best
    end
    return { r = r, s = s }
end

function HR.CardText(c)
    if c.joker then return "*" end
    return (HR.RANK_TEXT[c.r] or tostring(c.r))
end

---------------------------------------------------------------------------
-- Level-ups
---------------------------------------------------------------------------
function HR.XpNeed(level) return 4 + 3 * level + math.floor(0.45 * level * level) end

local function Tagged(def, tag) return def.tags and def.tags[tag] end

--- True if a Cash Out's need is met.
function HR.EvoReady(g, w)
    local def = HR.WEAPON[w.id]
    if w.evo or w.lvl < HR.WEAPON_MAX or not def.evo then return false end
    if def.evo.need == "flush" then
        local _, sb = HR.Suits(g)
        for _, s in ipairs(HR.SUITS) do if sb[s] == 3 then return true end end
        return false
    end
    return HR.Charm(g, def.evo.need) > 0
end

--- Does this card combine with what the player already holds?
local function Linked(g, card)
    if card.kind == "evo" then return true end
    if card.kind == "charm" then
        for _, w in ipairs(g.weapons) do
            local evo = HR.WEAPON[w.id].evo
            if evo and evo.need == card.id and not w.evo then return true end
        end
        local id = card.id
        local function has(tag) for _, w in ipairs(g.weapons) do if Tagged(HR.WEAPON[w.id], tag) then return true end end end
        if (id == "marbles" and has("bounce")) or (id == "chalk" and has("zone")) or (id == "snakeoil" and has("jinx"))
            or (id == "weighted" and has("roll")) or (id == "luckycoin" and has("chip")) then return true end
        return false
    end
    if card.kind == "weapon" and card.new then
        local evo = HR.WEAPON[card.id].evo
        return evo ~= nil and HR.Charm(g, evo.need) > 0
    end
    return false
end

--- Deals n level-up cards (three, or four with Marked Deck). Never an empty or useless deal.
function HR.Offer(g, n)
    n = n or (HR.Relic(g, "marked") and 4 or 3)
    local pool, weights = {}, {}
    local rare = g.st.rare and 2 or 1
    local function add(card, w)
        card.link = Linked(g, card)
        if card.link then w = w * 1.5 end
        pool[#pool + 1], weights[#weights + 1] = card, w
    end
    for _, w in ipairs(g.weapons) do
        local def = HR.WEAPON[w.id]
        if w.lvl < HR.WEAPON_MAX then
            add({ kind = "weapon", id = w.id, title = def.name, sub = "Level " .. (w.lvl + 1), desc = def.lv[w.lvl + 1],
                suit = def.suit, icon = def.icon, owned = true }, 4)
        elseif HR.EvoReady(g, w) then
            add({ kind = "evo", id = w.id, title = def.evo.name, sub = "Cash Out", desc = def.evo.desc,
                suit = def.suit, icon = def.icon, owned = true }, 8 * rare)
        end
    end
    if #g.weapons < HR.MAX_WEAPONS then
        for _, def in ipairs(HR.WEAPONS) do
            if not def.class and not HR.FindWeapon(g, def.id) and HR.WeaponUnlocked(def) then
                add({ kind = "weapon", id = def.id, new = true, title = def.name, sub = "New weapon", desc = def.desc,
                    suit = def.suit, icon = def.icon, hint = def.evo and ("Cash Out needs " .. (def.evo.need == "flush" and "a Flush" or HR.CHARM[def.evo.need].name)) }, 3 * rare)
            end
        end
    end
    local types = HR.CharmTypes(g)
    for _, def in ipairs(HR.CHARMS) do
        if not def.class or def.class == g.class then
            local have = HR.Charm(g, def.id)
            if have > 0 and have < def.max then
                add({ kind = "charm", id = def.id, title = def.name, sub = ("Charm %d of %d"):format(have + 1, def.max),
                    desc = (have + 1 == def.max) and (def.desc .. " At max: " .. def.top) or def.desc, suit = def.suit, owned = true }, 3)
            elseif have == 0 and types < HR.MAX_CHARM_TYPES then
                add({ kind = "charm", id = def.id, new = true, title = def.name, sub = "New charm", desc = def.desc, suit = def.suit },
                    def.class and 3 or 2)
            end
        end
    end
    local out, anyOwned = {}, false
    for _ = 1, n do
        local i = g.rand.weighted(weights)
        if not i then break end
        out[#out + 1] = pool[i]
        if pool[i].owned then anyOwned = true end
        table.remove(pool, i)
        table.remove(weights, i)
    end
    -- at least one card always improves something you hold
    if not anyOwned and #out > 0 then
        local owned = {}
        for _, c in ipairs(pool) do if c.owned then owned[#owned + 1] = c end end
        if #owned > 0 then out[#out] = g.rand.pick(owned) end
    end
    -- nothing left to offer: chips and a breather
    while #out < math.min(n, 3) do
        if #out % 2 == 0 or g.st.heal <= 0 or g.noHeal then out[#out + 1] = { kind = "bonus", id = "chips", title = "Tip", sub = "Bonus", desc = "+60 chips." }
        else out[#out + 1] = { kind = "bonus", id = "heal", title = "Breather", sub = "Bonus", desc = "Heal 25." } end
    end
    return out
end

---------------------------------------------------------------------------
-- Named builds (the Build Journal)
---------------------------------------------------------------------------
local function TreeRanks(g, prefix)
    local n = 0
    for id, r in pairs(g.talents) do if id:sub(1, 2) == prefix then n = n + r end end
    return n
end

HR.BUILDS = {
    { name = "Loaded", test = function(g, C, R, W) return g.class == "dice" and C("weighted") >= 1 and (C("shaved") >= 2 or TreeRanks(g, "dl") >= 4) end },
    { name = "Avalanche", test = function(g, C, R, W) return g.class == "dice" and C("marbles") >= 2 and (R("hotdice") or HR.T(g, "dr5") > 0) end },
    { name = "Royal Hunt", test = function(g, C, R, W) return g.class == "cards" and (C("joker") >= 2 or TreeRanks(g, "ch") >= 6) end },
    { name = "Rapid Fire", test = function(g, C, R, W) return g.class == "cards" and C("glove") >= 2 and TreeRanks(g, "cq") >= 4 end },
    { name = "Lockdown", test = function(g, C, R, W) return g.suits.n.C >= 5 end },
    { name = "Hot Streak", test = function(g, C, R, W) return g.class == "coin" and W("streak") and C("gambler") >= 1 end },
    { name = "The Wall", test = function(g, C, R, W) return g.class == "coin" and W("clover") and g.suits.n.H >= 3 end },
    { name = "The Bank", test = function(g, C, R, W) return W("well") and C("luckycoin") >= 2 and g.suits.n.D >= 3 end },
    { name = "Jackpot", test = function(g, C, R, W) return W("slots") and C("fourleaf") >= 2 end },
    { name = "Jinx Plague", test = function(g, C, R, W) return W("cat") and W("ball8") and C("snakeoil") >= 1 end },
    { name = "Bad Luck Charm", test = function(g, C, R, W) return R("mirror") and C("weighted") >= 2 end },
    { name = "Martingale's Folly", test = function(g, C, R, W) return R("martingale") and C("rabbit") >= 1 end },
    { name = "Glass Cannon", test = function(g, C, R, W) return R("glass") and (W("ace") or C("pokerface") >= 2) end },
    { name = "The Good Chair", test = function(g, C, R, W) return R("chair") and (W("edge") or W("tower")) end },
    { name = "Full Deck", test = function(g, C, R, W) return g.suits.fullDeck == true end },
}

--- Names of the builds this run currently matches.
function HR.DetectBuilds(g)
    HR.Suits(g)
    local out = {}
    local C, R = function(id) return HR.Charm(g, id) end, function(id) return HR.Relic(g, id) end
    local W = function(id) return HR.FindWeapon(g, id) ~= nil end
    for _, b in ipairs(HR.BUILDS) do
        local ok, hit = pcall(b.test, g, C, R, W)
        if ok and hit then out[#out + 1] = b.name end
    end
    return out
end

---------------------------------------------------------------------------
-- The end of a run: score, bests, class experience, achievements, journal
---------------------------------------------------------------------------
--- A short description of the build, for the bests and the summary.
function HR.BuildSummary(g)
    HR.Suits(g)
    local ws, rs = {}, {}
    for _, w in ipairs(g.weapons) do
        local def = HR.WEAPON[w.id]
        ws[#ws + 1] = (w.evo and def.evo.name or def.name) .. " " .. w.lvl
    end
    for _, r in ipairs(HR.RELICS) do if g.relics[r.id] then rs[#rs + 1] = r.name end end
    return { hand = g.suits.name, weapons = ws, relics = rs, class = g.class }
end

local function Best(tbl, key, value, extra)
    if value and value > (tbl[key] or 0) then
        tbl[key] = value
        if extra then for k, v in pairs(extra) do tbl[k] = v end end
        return true
    end
    return false
end

--- how: "dead", "walk" or "win". Returns a summary table for the end screen.
function HR.FinishRun(g, how)
    local db = HR.DB()
    local score = (how == "dead") and 0 or math.floor(g.chips)
    local sum = { how = how, score = score, room = g.roomIdx, bosses = g.bossesBeaten or 0, time = g.time,
        heat = g.heat, kills = g.kills, level = g.level, build = HR.BuildSummary(g), new = {}, damage = g.dmgBy or {} }
    db.stats.runs = (db.stats.runs or 0) + 1
    local slot = how == "dead" and "died" or (how == "walk" and "walked" or "won")
    db.stats[slot] = (db.stats[slot] or 0) + 1
    -- class experience: kept however the run ended
    local xp = (g.kills or 0) / 10 + (g.bossesBeaten or 0) * 60 + (how == "win" and 60 or 0)
    sum.levels = HR.AddClassXp(g.class, xp)
    sum.xp = math.floor(xp)
    -- personal bests, per mode and stakes; "all" and one per class
    local key = (g.mode or "full") .. ":" .. (g.stakes or 0)
    db.bests[key] = db.bests[key] or {}
    for _, who in ipairs({ "all", g.class }) do
        local b = db.bests[key][who] or {}
        db.bests[key][who] = b
        if Best(b, "score", score, { build = sum.build }) and who == "all" then sum.new[#sum.new + 1] = "Best score" end
        local reached = (g.bossesBeaten or 0) * 10 + g.roomIdx
        if Best(b, "reached", reached, { room = g.roomIdx, bosses = g.bossesBeaten or 0 }) and who == "all" then sum.new[#sum.new + 1] = "Furthest yet" end
        if how == "win" and (not b.fastest or g.time < b.fastest) then
            b.fastest = g.time
            if who == "all" then sum.new[#sum.new + 1] = "Fastest win" end
        end
        if how ~= "dead" then Best(b, "heat", g.heat) end
        Best(b, "bigHit", g.bigHit)
        Best(b, "chain", g.bestChain)
        Best(b, "hand", g.bestHand)
        Best(b, "streak", g.coin and g.coin.best)
        b.runs = (b.runs or 0) + 1
    end
    if how == "walk" and score >= 3000 and HR.Earn("walk3000") then sum.new[#sum.new + 1] = "Achievement: Quit While Ahead" end
    if how == "win" and (g.stakes or 0) >= 1 then db.stakes1Won = true end
    -- the Build Journal
    for _, name in ipairs(HR.DetectBuilds(g)) do
        local j = db.journal[name]
        if not j then
            j = { best = 0 }
            db.journal[name] = j
            sum.new[#sum.new + 1] = "Build found: " .. name
        end
        if score > (j.best or 0) then j.best = score end
    end
    for _, a in ipairs(g.earned or {}) do sum.new[#sum.new + 1] = "Achievement: " .. HR.ACH[a].name end
    db.save = nil
    db.last = sum
    return sum
end
