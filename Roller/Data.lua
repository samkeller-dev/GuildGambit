-- Roller/Data.lua: High Roller, a survivors game in the Arcade tab - every table of content.
--
-- Just for fun: "chips" are points inside one run. Nothing here touches gold, the ledger or
-- other players. Design: HIGHROLLER.md in the project folder.
local ADDON_NAME, ns = ...

local HR = {}
ns.Roller = HR

HR.VIEW_W, HR.VIEW_H = 600, 450      -- what you see of a room (the window draws it at 4:3, 800 x 600)
HR.ROOM_W, HR.ROOM_H = 1200, 900     -- a wave room: two screens each way
HR.STEP = 1 / 30                     -- fixed simulation step
-- Side bets before each room are written but switched off: they were one screen too many
-- between rooms. (The tests switch them on to keep the code exercised.)
HR.BETS_ON = false
HR.BOSS_GATE = 0.05                  -- the share of a boss's health that full damage can take in one second
HR.WAVE_TIME = 90                    -- seconds of waves before a room's boss
HR.MAX_WEAPONS, HR.MAX_CHARM_TYPES = 4, 5
HR.WEAPON_MAX = 5
HR.CAPS = { enemies = 100, shots = 120, eshots = 40, pickups = 100, special = 12, zones = 40, texts = 24 }

HR.SUITS = { "S", "H", "D", "C" }
HR.SUIT_NAME = { S = "Spades", H = "Hearts", D = "Diamonds", C = "Clubs", J = "Joker" }
HR.SUIT_COLOR = { S = "ffc8c8ff", H = "ffff5a5a", D = "ffffb040", C = "ff8fe08f", J = "ffe080ff" }
HR.SUIT_TINT = { S = { 0.62, 0.62, 1 }, H = { 1, 0.4, 0.4 }, D = { 1, 0.72, 0.25 }, C = { 0.5, 0.9, 0.5 } }

---------------------------------------------------------------------------
-- The player: one character, the same every run - what you pick up is the build.
-- (Still a list of one "class", so saved progress keeps the shape it always had.)
---------------------------------------------------------------------------
HR.HERO = "hero"
HR.CLASSES = {
    { id = "hero", name = "High Roller", suit = "S", sprite = "hero", weapon = "revolver" },
}
HR.CLASS = {}
for _, c in ipairs(HR.CLASSES) do HR.CLASS[c.id] = c end

HR.PLAYER = { hp = 100, speed = 112, r = 8, pickup = 46, iframes = 0.5, luckyChance = 0.05, luckyMult = 1.5 }

---------------------------------------------------------------------------
-- Weapons. Arrays are indexed by level 1-5. tags are what charms and relics look for.
-- evo: the Cash Out - its name, the charm it needs, and what it adds.
-- start = true: the one you begin with (never dealt). soon = true: written but not released -
-- never dealt (the tests switch the flag off to keep the code exercised).
---------------------------------------------------------------------------
HR.WEAPONS = {
    { id = "revolver", name = "Snub Nose", suit = "S", start = true, tags = { gun = true }, icon = "revolver",
      cd = { 0.7, 0.65, 0.6, 0.55, 0.5 }, dmg = { 12, 14, 17, 20, 25 }, n = { 1, 1, 2, 2, 3 }, pierce = { 1, 1, 1, 2, 2 },
      desc = "Your revolver: steady shots at the nearest enemy, through it and into the next.",
      lv = { "", "+damage, shoots faster", "+damage, a second bullet", "+damage, bullets go one enemy deeper", "+damage, a third bullet" },
      evo = { name = "Tommy Gun", need = "glove", desc = "Every shot is followed by two quick, lighter ones." } },
    -- three with a game of their own: dice to pick up, a poker hand, a coin to flip
    { id = "bonedice", name = "Bone Dice", suit = "S", tags = { roll = true, bounce = true }, icon = "die6", dmgLabel = "Damage per pip",
      cd = { 1.2, 1.2, 1.0, 1.0, 0.9 }, dmg = { 2.2, 2.8, 3.2, 3.6, 4.2 }, n = { 2, 2, 2, 3, 3 }, bounce = { 1, 2, 2, 2, 2 },
      chain = { 3, 3, 3, 3, 4 },
      desc = "Throws dice; damage is the face. Doubles throw again. Walk over a good die to keep it for your next throw.",
      lv = { "", "+damage, +1 bounce", "+damage, throws faster", "+damage, a third die", "+damage, longer chains" },
      evo = { name = "Natural Roller", need = "weighted", desc = "Sixes explode and are rolled again." } },
    { id = "flick", name = "Flick", suit = "C", soon = true, tags = { card = true }, icon = "card",
      cd = { 1.0, 0.95, 0.9, 0.85, 0.8 }, dmg = { 7, 9, 11, 13, 16 }, n = { 2, 3, 3, 4, 5 }, pierce = { 0, 0, 0, 1, 1 },
      drop = { 6, 6, 5, 5, 5 }, hand = { 1, 1, 1, 1, 1.25 },
      desc = "Throws a fan of cards. Kills drop playing cards for your hand.",
      lv = { "", "+damage, +1 card", "+damage, more card drops", "+damage, +1 card, pierce", "+damage, hands hit 25% harder" },
      evo = { name = "52 Pickup", need = "nail", desc = "Every hand played also rains cards across the room." } },
    { id = "trickcoin", name = "Trick Coin", suit = "D", soon = true, tags = { bounce = true, streak = true }, icon = "tcoin",
      cd = { 1.1, 1.0, 1.0, 0.9, 0.9 }, dmg = { 8, 10, 12, 14, 17 }, n = { 1, 2, 2, 2, 2 }, bounce = { 2, 2, 3, 3, 3 },
      step = { 1, 1, 1, 1.3, 1.3 }, drop = { 15, 15, 15, 15, 12 },
      desc = "Coins ricochet between enemies. Heads or Tails changes how you fight.",
      lv = { "", "+damage, a second coin", "+damage, +1 ricochet", "+damage, stronger streaks", "+damage, more flip coins" },
      evo = { name = "Double-Sided", need = "luckycoin", desc = "A won flip adds 2 streak." } },
    -- Spades
    { id = "ace", name = "Ace of Spades", suit = "S", tags = { card = true }, icon = "ace", ach = "boss3",
      cd = { 2.6, 2.4, 2.2, 2.0, 1.8 }, dmg = { 22, 30, 38, 48, 60 },
      desc = "One slow card that pierces everything.",
      lv = { "", "+damage, faster", "+damage, faster", "+damage, faster", "+damage, faster" },
      evo = { name = "Death Card", need = "glove", desc = "A kill makes it fire again at once." } },
    { id = "tower", name = "Chip Tower", suit = "S", tags = { zone = true }, icon = "tower",
      cd = { 3.0, 2.8, 2.6, 2.4, 2.2 }, dmg = { 12, 15, 18, 22, 26 }, n = { 1, 1, 2, 2, 3 }, r = 52,
      desc = "Lobs a stack that topples into rings of damage.",
      lv = { "", "+damage", "+damage, a second ring", "+damage", "+damage, a third ring" },
      evo = { name = "High Stakes", need = "pokerface", desc = "The tower stays and keeps toppling." } },
    { id = "streak", name = "Lucky Streak", suit = "S", tags = { streak = true }, icon = "bolt", ach = "triple",
      cd = { 0.9, 0.85, 0.8, 0.75, 0.7 }, dmg = { 5, 6, 7, 8, 10 }, cap = { 10, 15, 20, 25, 30 },
      desc = "A bolt whose damage climbs 4% per kill, until you're hit.",
      lv = { "", "+damage, higher cap", "+damage, higher cap", "+damage, higher cap", "+damage, higher cap" },
      evo = { name = "Hot Hand", need = "gambler", desc = "A hit halves the streak instead of ending it." } },
    -- Clubs
    { id = "cat", name = "Black Cat", suit = "C", tags = { jinx = true, summon = true, bounce = true }, icon = "cat",
      cd = { 2.4, 2.2, 2.0, 1.8, 1.6 }, dmg = { 9, 11, 14, 17, 21 }, n = { 1, 1, 2, 2, 3 }, pounce = { 3, 4, 4, 5, 6 },
      desc = "A cat leaps from enemy to enemy, clawing each one and jinxing it: a jinxed enemy takes 25% more damage from everything.",
      lv = { "", "+damage, faster, one more leap", "+damage, a second cat", "+damage, faster, one more leap", "+damage, a third cat, one more leap" },
      evo = { name = "Nine Lives", need = "rabbit", desc = "The cat saves you from one death each room." } },
    { id = "ball8", name = "Magic 8-Ball", suit = "C", tags = { orbit = true, roll = true, jinx = true }, icon = "ball8",
      cd = { 0.6, 0.6, 0.55, 0.55, 0.5 }, dmg = { 8, 10, 12, 14, 17 }, n = { 1, 2, 2, 3, 3 },
      desc = "Orbits you and answers on hit: Yes (hit), Ask Again (twice), Outlook Not So Good (jinx).",
      lv = { "", "+damage, a second ball", "+damage", "+damage, a third ball", "+damage" },
      evo = { name = "Oracle", need = "watch", desc = "Every answer is all three at once." } },
    { id = "rball", name = "Roulette Ball", suit = "C", tags = { bounce = true }, icon = "rball", ach = "boss1",
      cd = { 3.0, 2.7, 2.4, 2.1, 1.8 }, dmg = { 14, 18, 22, 27, 33 }, n = { 1, 1, 2, 2, 3 },
      desc = "Drops onto a random enemy and stuns it.",
      lv = { "", "+damage, faster", "+damage, a second ball", "+damage, faster", "+damage, a third ball" },
      evo = { name = "Double Zero", need = "chalk", desc = "Stunned enemies explode." } },
    -- Diamonds
    { id = "slots", name = "Slot Machine", suit = "D", tags = { roll = true }, icon = "seven",
      cd = { 4.0, 3.7, 3.4, 3.1, 2.8 }, dmg = { 10, 13, 16, 20, 24 },
      desc = "Three reels: cherries heal, bells stun the room, sevens blast it.",
      lv = { "", "+damage, faster", "+damage, faster", "+damage, faster", "+damage, faster" },
      evo = { name = "Progressive Jackpot", need = "luckycoin", desc = "Every miss makes the next win bigger and likelier." } },
    { id = "well", name = "Wishing Well", suit = "D", tags = { chip = true }, icon = "chip",
      dmg = { 8, 10, 12, 15, 18 }, per = { 6, 5, 5, 4, 3 },
      desc = "Chips you collect are thrown back as coins.",
      lv = { "", "+damage, more coins", "+damage", "+damage, more coins", "+damage, more coins" },
      evo = { name = "Make a Wish", need = "penny", desc = "A coin can grant a 10-second buff." } },
    { id = "shoe", name = "Horseshoe", suit = "D", tags = { bounce = true }, icon = "horseshoe", ach = "boss4",
      cd = { 2.2, 2.0, 1.9, 1.8, 1.6 }, dmg = { 9, 12, 15, 18, 22 }, n = { 1, 1, 2, 2, 3 },
      desc = "Flies out through everything and comes back.",
      lv = { "", "+damage, faster", "+damage, a second shoe", "+damage, faster", "+damage, a third shoe" },
      evo = { name = "Ringer", need = "marbles", desc = "It circles the first enemy it hits." } },
    -- Hearts
    { id = "edge", name = "House Edge", suit = "H", tags = { zone = true }, icon = "suit_h",
      cd = { 0.5, 0.5, 0.5, 0.5, 0.5 }, dmg = { 3, 4, 5, 6.5, 8 }, r = { 60, 68, 76, 84, 95 },
      desc = "An aura that drains every enemy near you.",
      lv = { "", "+damage, wider", "+damage, wider", "+damage, wider", "+damage, wider" },
      evo = { name = "The Rake", need = "helping", desc = "Kills inside the aura heal you." } },
    { id = "clover", name = "Lucky Clover", suit = "H", tags = { orbit = true }, icon = "leaf",
      cd = { 0.6, 0.6, 0.6, 0.6, 0.6 }, dmg = { 5, 6, 8, 10, 12 }, n = { 2, 3, 3, 4, 5 },
      desc = "Leaves orbit you, hit enemies and block their shots.",
      lv = { "", "+damage, a third leaf", "+damage", "+damage, a fourth leaf", "+damage, a fifth leaf" },
      evo = { name = "Four-Leaf Storm", need = "fourleaf", desc = "A blocked shot heals you." } },
    { id = "piggy", name = "Piggy Bank", suit = "H", tags = { chip = true, summon = true }, icon = "pig", ach = "boss2",
      dmg = { 30, 40, 50, 65, 80 }, per = { 25, 22, 20, 18, 15 }, r = 80,
      desc = "A pig follows you eating chips for you. Full, it bursts in a blast.",
      lv = { "", "+damage, fills faster", "+damage, fills faster", "+damage, fills faster", "+damage, fills faster" },
      evo = { name = "Golden Goose", need = "insurance", desc = "Each burst also drops a heart." } },
    { id = "blade", name = "Switchblade", suit = "H", tags = { bleed = true }, icon = "knife",
      cd = { 1.4, 1.3, 1.2, 1.1, 1.0 }, dmg = { 6, 7, 9, 11, 13 }, n = { 1, 1, 1, 2, 2 }, bleed = { 4, 5, 6, 8, 10 }, stacks = { 3, 3, 4, 4, 5 },
      desc = "Throws a knife that leaves a bleed: damage every half second for 4 seconds. Bleeds stack 3 times on one enemy.",
      lv = { "", "+damage, faster, a deeper bleed", "+damage, bleeds stack 4 times", "+damage, a second knife", "+damage, bleeds stack 5 times" },
      evo = { name = "Bloodbath", need = "vig", desc = "An enemy that dies bleeding passes its bleed to three more." } },
    -- (more Clubs)
    { id = "molotov", name = "Molotov", suit = "C", tags = { zone = true, burn = true }, icon = "molotov",
      cd = { 3.6, 3.4, 3.2, 3.0, 2.8 }, dmg = { 5, 6, 8, 10, 12 }, n = { 1, 1, 1, 2, 2 }, r = { 38, 42, 46, 50, 56 }, dur = { 3, 3, 3.5, 3.5, 4 },
      desc = "Sets the floor on fire under an enemy for 3 seconds. Everything standing in the flames burns.",
      lv = { "", "+damage, a wider fire", "+damage, wider, burns longer", "+damage, wider, a second bottle", "+damage, wider, burns longer" },
      evo = { name = "Wildfire", need = "chalk", desc = "Enemies keep burning for 3 seconds after they leave the flames." } },
    -- Joker
    { id = "wild", name = "Wild Card", suit = "J", tags = { card = true }, icon = "suit_j", ach = "sevens",
      mult = { 0.5, 0.55, 0.6, 0.65, 0.75 },
      desc = "Copies your highest-level weapon at half strength. Counts as your best suit.",
      lv = { "", "a stronger copy", "a stronger copy", "a stronger copy", "a stronger copy" },
      evo = { name = "Joker's Wild", need = "flush", desc = "Copies at full strength." } },
}
HR.WEAPON = {}
for _, w in ipairs(HR.WEAPONS) do HR.WEAPON[w.id] = w end

---------------------------------------------------------------------------
-- Charms: stacking passives. What each does lives in Rules.Recalc and the engine.
-- needs: only dealt while you hold that weapon.
---------------------------------------------------------------------------
HR.CHARMS = {
    { id = "weighted", name = "Weighted Die", suit = "S", max = 3, desc = "Your lowest possible roll +1.", top = "Rolls can't land in the bottom half." },
    { id = "glove", name = "Sharp's Glove", suit = "S", max = 4, desc = "+8% attack speed.", top = "Every 10th attack is doubled." },
    { id = "pokerface", name = "Poker Face", suit = "S", max = 4, desc = "+10% damage at full health.", top = "Also while shielded." },
    { id = "gambler", name = "Gambler's Charm", suit = "S", max = 4, desc = "Crits deal +25% damage.", top = "Crits can't be dodged." },
    { id = "nail", name = "Lucky Nail", suit = "C", max = 3, desc = "Your shots pierce one more enemy.", top = "Pierced enemies are knocked back." },
    { id = "snakeoil", name = "Snake Oil", suit = "C", max = 3, desc = "A jinxed enemy's death jinxes one more.", top = "Spread jinxes are stronger." },
    { id = "chalk", name = "Chalk", suit = "C", max = 4, desc = "Zones and auras 12% bigger.", top = "They slow." },
    { id = "watch", name = "Pocket Watch", suit = "C", max = 3, desc = "+0.2s of safety after a hit.", top = "Enemies slow briefly when you're low." },
    { id = "fourleaf", name = "Four-Leaf Clover", suit = "D", max = 4, desc = "+4 Luck.", top = "One roll in five is made twice." },
    { id = "luckycoin", name = "Lucky Coin", suit = "D", max = 4, desc = "+10% chip value.", top = "A chip can be lucky: double." },
    { id = "penny", name = "Silver Penny", suit = "D", max = 4, desc = "+15% pickup range.", top = "Collecting chips heals a little." },
    { id = "marbles", name = "Marble Bag", suit = "D", max = 3, desc = "Bounces +1.", top = "Each bounce adds 10% damage." },
    { id = "rabbit", name = "Rabbit's Foot", suit = "H", max = 2, desc = "Survive one killing blow per run.", top = "Each save heals you to half." },
    { id = "insurance", name = "Insurance", suit = "H", max = 3, desc = "15% of a big hit is refunded over 5s.", top = "A full refund leaves a shield." },
    { id = "helping", name = "Second Helping", suit = "H", max = 4, desc = "Healing 15% stronger.", top = "Healing at full health boosts damage." },
    { id = "vig", name = "The Vig", suit = "H", max = 4, desc = "Lifesteal: heal for 0.5% of the damage you deal.", top = "Crits steal twice as much." },
    { id = "shoes", name = "Comfy Shoes", suit = "H", max = 4, desc = "+6% move speed.", top = "Standing still gives a small shield." },
    { id = "shaved", name = "Shaved Dice", suit = "S", max = 4, needs = "bonedice", desc = "+5% Loaded: more doubles.", top = "A triple can chain." },
    { id = "joker", name = "Extra Joker", suit = "C", max = 3, needs = "flick", desc = "More Jokers among the card drops.", top = "A Joker pair hits twice." },
    { id = "thumb", name = "Lucky Thumb", suit = "D", max = 3, needs = "trickcoin", desc = "Coin +4% your way.", top = "A lost flip keeps one streak." },
}
HR.CHARM = {}

-- Boosts: small upgrades that stack without limit for the rest of the run. They fill a level-up's
-- empty places once there's nothing else to deal, so a finished build still grows.
HR.BOOSTS = {
    { id = "dmg", name = "Hollow Points", icon = "bullet", desc = "+4% damage.", dmg = 0.04 },
    { id = "atk", name = "Hair Trigger", icon = "revolver", desc = "+3% attack speed.", atk = 0.03 },
    { id = "hp", name = "Thick Hide", icon = "heart", desc = "+8 maximum health, and heal 8.", hp = 8 },
    { id = "luck", name = "Lucky Break", icon = "leaf", desc = "+2 Luck.", luck = 2 },
    { id = "leech", name = "Skim", icon = "chip", desc = "+0.25% lifesteal.", lifesteal = 0.0025 },
}
HR.BOOST = {}
for _, b in ipairs(HR.BOOSTS) do HR.BOOST[b.id] = b end
for _, c in ipairs(HR.CHARMS) do HR.CHARM[c.id] = c end

---------------------------------------------------------------------------
-- Relics: one of three from each boss chest. Cursed ones add Heat.
---------------------------------------------------------------------------
HR.RELICS = {
    { id = "marked", name = "Marked Deck", desc = "Level-ups deal four cards.", ach = "dealerclean" },
    { id = "whistle", name = "Pit Boss's Whistle", desc = "An elite that would die fights for you for 10 seconds first." },
    { id = "shoe6", name = "Dealer's Shoe", desc = "Every sixth attack is a crit." },
    { id = "hotdice", name = "Hot Dice", desc = "A maximum roll adds a bounce to that shot." },
    { id = "chair", name = "The Good Chair", desc = "Standing still doubles attack speed; moving halves it." },
    { id = "seven", name = "Lucky Seven", desc = "Every seventh kill drops a pile of chips." },
    { id = "suite", name = "Comp Suite", desc = "Start each room at full health." },
    { id = "aces", name = "Pocket Aces", desc = "Your two highest weapons gain a sixth level.", ach = "house" },
    { id = "martingale", name = "Martingale System", cursed = true, desc = "A miss doubles your next hit; a hit you take doubles the next one." },
    { id = "mirror", name = "Broken Mirror", cursed = true, desc = "+60% damage; your Luck is locked at 0." },
    { id = "loanmark", name = "Loan Shark's Mark", cursed = true, desc = "Double chips; lose 2 health a second until the room's boss dies." },
    { id = "glass", name = "Glass Cannon", cursed = true, desc = "Double damage; your maximum health is halved.", ach = "heat6" },
    { id = "badpenny", name = "Bad Penny", cursed = true, desc = "+15 Luck; one chip in twenty bites when collected." },
    { id = "allin", name = "All In", cursed = true, desc = "Double damage and chips at 1 health; you're set to 1 now and can't heal this room." },
}
HR.RELIC = {}
for _, r in ipairs(HR.RELICS) do HR.RELIC[r.id] = r end

---------------------------------------------------------------------------
-- Enemies. hp, dmg and xp are at room-1 strength; ROOM_HP / ROOM_DMG scale them.
---------------------------------------------------------------------------
HR.ROOM_HP = { 1, 1.8, 3.0, 4.6, 6.5 }
HR.ROOM_DMG = { 11, 14, 17, 21, 27 }
HR.ENEMIES = {
    slime      = { name = "Pip Slime", sprite = "slime", hp = 14, speed = 54, r = 9, xp = 1, split = 2 },
    slime_s    = { name = "Pip Slime", sprite = "slime_s", hp = 6, speed = 60, r = 6, xp = 0.5, split = 1, size = 19 },
    slime_t    = { name = "Pip Slime", sprite = "slime_s", hp = 3, speed = 66, r = 5, xp = 0.25, size = 14 },
    imp        = { name = "Chip Imp", sprite = "imp", hp = 5, speed = 90, r = 7, xp = 0.5, pack = 4 },
    bouncer    = { name = "Bouncer", sprite = "bouncer", hp = 30, speed = 45, r = 10, xp = 2, shield = true },
    soldier    = { name = "Card Soldier", sprite = "soldier", hp = 20, speed = 60, r = 9, xp = 1, suited = true },
    joker      = { name = "Joker", sprite = "joker", hp = 16, speed = 58, r = 8, xp = 1.5, blink = 5 },
    pickpocket = { name = "Pickpocket", sprite = "pickpocket", hp = 11, speed = 84, r = 8, xp = 1, thief = true },
    mimic      = { name = "Mimic", sprite = "chippile", hp = 26, speed = 96, r = 9, xp = 2, mimic = true },
    shark      = { name = "Loan Shark", sprite = "shark", hp = 9, speed = 67, r = 8, xp = 1, dive = true },
    golem      = { name = "Vault Golem", sprite = "golem", hp = 100, speed = 31, r = 12, xp = 5, heavy = true, size = 34 },
    spinner    = { name = "Spinner", sprite = "spinner", hp = 24, speed = 56, r = 9, xp = 1.5, spin = true },
    croupier   = { name = "Croupier", sprite = "croupier", hp = 20, speed = 46, r = 9, xp = 1.5, rake = true },
    teller     = { name = "Fortune Teller", sprite = "teller", hp = 18, speed = 42, r = 9, xp = 1.5, mark = true },
    devil      = { name = "Lucky Devil", sprite = "devil", hp = 22, speed = 70, r = 8, xp = 1.5, lucky = true },
}

--- Rooms: floor, name, enemy mix as { type, weight, from second }, and boss.
HR.ROOMS = {
    { name = "The Dice Den", floor = "floor_dice", boss = "pit",
      mix = { { "slime", 5, 0 }, { "imp", 4, 12 }, { "bouncer", 2, 40 } } },
    { name = "The Card Hall", floor = "floor_cards", boss = "dealer",
      mix = { { "soldier", 6, 0 }, { "imp", 2, 0 }, { "pickpocket", 2, 15 }, { "joker", 2, 35 } } },
    { name = "The Coin Vault", floor = "floor_vault", boss = "snakes",
      mix = { { "shark", 4, 0 }, { "soldier", 3, 0 }, { "mimic", 2, 15 }, { "golem", 1, 40 } } },
    { name = "The Wheel Room", floor = "floor_wheel", boss = "fortune",
      mix = { { "spinner", 3, 0 }, { "devil", 3, 0 }, { "croupier", 2, 15 }, { "teller", 2, 30 }, { "shark", 2, 30 } } },
    { name = "The House", floor = "floor_house", boss = "house",
      mix = { { "soldier", 3, 0 }, { "shark", 3, 0 }, { "devil", 2, 0 }, { "spinner", 2, 10 }, { "bouncer", 2, 10 },
              { "teller", 1, 30 }, { "golem", 1, 40 }, { "mimic", 1, 20 } } },
}

HR.BOSSES = {
    pit     = { name = "The Pit Boss", line = "No winners on my floor.", sprite = "boss_pit", hp = 2000, bounty = 500, ach = "boss1" },
    dealer  = { name = "The Dealer", line = "Hit, or stand?", sprite = "boss_dealer", hp = 4500, bounty = 1000, ach = "boss2" },
    snakes  = { name = "Snake Eyes", line = "Two for one.", sprite = "boss_serpent", hp = 9000, bounty = 1500, ach = "boss3" },
    fortune = { name = "Madame Fortune", line = "I've seen how this ends.", sprite = "boss_fortune", hp = 14000, bounty = 2000, ach = "boss4" },
    house   = { name = "The House", line = "The House always wins.", sprite = "boss_house", hp = 22000, bounty = 5000, ach = "house" },
}

HR.ELITE_TRAITS = { "shielded", "splitting", "lucky", "magnetic" }

---------------------------------------------------------------------------
-- Side bets, House Rules
---------------------------------------------------------------------------
HR.BETS = {
    { id = "clean", name = "Clean Hands", desc = "Take 2 hits or fewer this room.", pay = 250 },
    { id = "body", name = "Body Count", desc = "150 kills before the boss.", pay = 250 },
    { id = "tight", name = "Tightwad", desc = "Pick up no chips for the first 30 seconds.", pay = 200 },
    { id = "stand", name = "Stand Your Ground", desc = "Spend 25 seconds inside the marked circle.", pay = 300 },
    { id = "speed", name = "Speed Run", desc = "Kill the boss in under 20 seconds.", pay = 400 },
    { id = "big", name = "Big Game", desc = "Kill 3 elites.", pay = 300, heat = 4 },
    { id = "short", name = "Short Stack", desc = "End the room at half health or less.", pay = 250 },
    { id = "nofold", name = "No Fold", desc = "Take a card at every level-up this room.", pay = 150 },
    { id = "greedy", name = "Greedy", desc = "Collect 100 chips' worth within any 20 seconds.", pay = 250 },
    { id = "wall", name = "Wallflower", desc = "Spend 30 seconds near the walls.", pay = 250 },
    { id = "weather", name = "All Weather", desc = "Deal damage with four different weapons.", pay = 200 },
    { id = "counter", name = "Card Counter", desc = "A coin toss on the boss's first move. Even money.", pay = 300 },
}
HR.BET = {}
for _, b in ipairs(HR.BETS) do HR.BET[b.id] = b end

HR.RULES = {
    { id = "none", name = "No Rule", desc = "A plain run." },
    { id = "happy", name = "Happy Hour", desc = "Double chips, and 50% more enemies." },
    { id = "dry", name = "Dry Spell", desc = "No healing from any source. +50% chips." },
    { id = "loose", name = "Loose Slots", desc = "Every roll is made twice, keeping the better." },
    { id = "cursed", name = "Cursed Table", desc = "Every relic chest is cursed." },
    { id = "fast", name = "Fast Hands", desc = "Everything attacks 30% faster. Enemies too." },
    { id = "lucky", name = "Lucky Day", desc = "Start with 15 Luck." },
}
HR.RULE = {}
for _, r in ipairs(HR.RULES) do HR.RULE[r.id] = r end

---------------------------------------------------------------------------
-- Talents: three trees of five rows. A row opens once the row above it is full.
---------------------------------------------------------------------------
HR.TALENT_CAP = 20
HR.MAX_CLASS_LEVEL = 15
HR.TALENTS = {
    hero = {
        { name = "Muscle", tip = "Hitting harder. Everything here works with every weapon you pick up, from your first shot.", rows = {
            { id = "hm1", max = 3, desc = "+4% damage." },
            { id = "hm2", max = 3, desc = "+3% attack speed." },
            { id = "hm3", max = 2, desc = "Crits deal +15% damage." },
            { id = "hm4", max = 2, desc = "Blasts, auras and orbits are 6% bigger." },
            { id = "hm5", max = 1, name = "Packing Heat", desc = "Your revolver starts each run at level 2." } } },
        { name = "Grit", tip = "Staying alive: more health, quicker feet, and a longer moment of safety after a hit. None of it saves you from a boss's red.", rows = {
            { id = "hg1", max = 3, desc = "+6 maximum health." },
            { id = "hg2", max = 2, desc = "+4% move speed." },
            { id = "hg3", max = 2, desc = "+0.1s of safety after a hit." },
            { id = "hg4", max = 2, desc = "Every hit hurts 1 less." },
            { id = "hg5", max = 1, name = "Tough Guy", desc = "Start each room with a 20-point shield." } } },
        { name = "Fortune", tip = "Luck. Each point of Luck is +1% crit chance (a crit deals 50% more damage). Luck also makes rare cards, legendary relics and big chests turn up more often.", rows = {
            { id = "df1", max = 3, desc = "+3 Luck." },
            { id = "df2", max = 2, desc = "Folding gives 1 more Luck." },
            { id = "df3", max = 2, desc = "One more reroll token each room." },
            { id = "df4", max = 2, desc = "Chips are worth 5% more." },
            { id = "df5", max = 1, name = "Friends Upstairs", desc = "The first chest of a run always holds three prizes or more." } } },
    },
}

---------------------------------------------------------------------------
-- Achievements (each unlocks something), poker hands, taunts
---------------------------------------------------------------------------
HR.ACHIEVEMENTS = {
    { id = "boss1", name = "Shown the Door", desc = "Beat the Pit Boss.", gives = "Roulette Ball" },
    { id = "boss2", name = "Twenty-One", desc = "Beat The Dealer.", gives = "Piggy Bank, cursed relics" },
    { id = "boss3", name = "Boxcars", desc = "Beat Snake Eyes.", gives = "Ace of Spades" },
    { id = "boss4", name = "Unforeseen", desc = "Beat Madame Fortune.", gives = "Horseshoe" },
    { id = "house", name = "Broke the Bank", desc = "Beat The House.", gives = "Pocket Aces, higher Stakes" },
    { id = "triple", name = "Three of a Kind", desc = "Roll a triple.", gives = "Lucky Streak" },
    { id = "flush", name = "All One Colour", desc = "Play a flush.", needs = "flick" },
    { id = "streak6", name = "On a Roll", desc = "Reach a 6-streak.", needs = "trickcoin" },
    { id = "bets3", name = "Sure Thing", desc = "Win three side bets in one run.", bets = true },
    { id = "sevens", name = "Jackpot", desc = "Hit triple sevens.", gives = "Wild Card" },
    { id = "walk3000", name = "Quit While Ahead", desc = "Walk away with 3,000 chips.", gives = "Counterfeit Plates" },
    { id = "dealerclean", name = "Card Counter", desc = "Beat The Dealer without going over 21.", gives = "Marked Deck" },
    { id = "heat6", name = "Too Hot", desc = "Finish a room at Heat 6.", gives = "Glass Cannon" },
}
HR.ACH = {}
for _, a in ipairs(HR.ACHIEVEMENTS) do HR.ACH[a.id] = a end

HR.HANDS = { "High Card", "Pair", "Two Pair", "Three of a Kind", "Straight", "Flush", "Full House", "Four of a Kind", "Royal Flush" }
HR.RANK_TEXT = { [11] = "J", [12] = "Q", [13] = "K", [14] = "A", [15] = "*" }

HR.TAUNTS = {
    start = { "Welcome. Try not to win too much.", "New face. We like new faces.", "The tables are warm tonight." },
    levelup = { "Beginner's luck.", "Enjoy it while it lasts.", "Lucky. For now." },
    boss = { "Someone would like a word.", "Management has noticed you.", "You've been asked to step aside." },
    bosswin = { "...That was an expensive employee.", "Fine. Take it. Go on.", "The Dealer's been asking about you." },
    heat = { "You're being watched.", "Security is on the floor.", "Walk away. I'm asking nicely." },
    low = { "You look tired.", "Shall I call you a carriage?", "Nearly there. Nearly." },
    jackpot = { "That machine is BROKEN.", "Impossible.", "Check that one. Check it twice." },
    walk = { "Leaving so soon? Wise.", "Come back any time. Please.", "A cautious one." },
    dead = { "The House always wins.", "Thank you for playing.", "Better luck next time." },
    win = { "...You broke the bank.", "Get out. And come back tomorrow.", "Nobody does that. Nobody." },
}

HR.TIPS = {
    "Move with WASD or the arrow keys. Your weapons fire on their own.",
    "Gold chips are your score. Enemies drop them; walk away after a boss to keep them.",
    "A boss's red floor markings kill in one hit. Step out before they fill in.",
    "A weapon crate holds a new weapon. Walk over it.",
    "A level-up deals you cards: press 1, 2 or 3. F folds for Luck.",
}
