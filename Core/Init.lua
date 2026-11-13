-- Init.lua: namespace, saved variables, names, money formatting and the shared log.
local ADDON_NAME, ns = ...

local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata
ns.version = (GetMeta and GetMeta(ADDON_NAME, "Version")) or "dev"

local DEFAULTS = {
    debug = false,
    guildOnly = true,       -- only accept games from guild members
    whisperRolls = true,    -- whisper our rolls to opponents outside our group
    sound = true,           -- in-game sound effects
    announce = true,        -- post deathroll wins in guild chat
    maxLedger = 500,        -- ledger entries kept
    window = { shown = false, point = "CENTER", x = 0, y = 0, tab = "play" },
    house = { maxBet = 100 }, -- gold
}

local CHAR_DEFAULTS = {
    ledger = {},            -- { id, game, opponent, net (copper), verified, practice, time, settled }
}

local function ApplyDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            ApplyDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

function ns.InitDB()
    GuildGambitDB = ApplyDefaults(GuildGambitDB or {}, DEFAULTS)
    GuildGambitCharDB = ApplyDefaults(GuildGambitCharDB or {}, CHAR_DEFAULTS)
    ns.db = GuildGambitDB
    ns.charDB = GuildGambitCharDB
end

---------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------
local PREFIX = "|cffffd100GuildGambit|r: "

function ns.Print(fmt, ...)
    local text = select("#", ...) > 0 and fmt:format(...) or fmt
    print(PREFIX .. text)
end

function ns.Debug(fmt, ...)
    if ns.db and ns.db.debug then ns.Print("|cff888888" .. fmt .. "|r", ...) end
end

-- The log shows in the window and in chat, so the addon is usable even if the UI isn't.
ns.logLines = {}
function ns.Log(fmt, ...)
    local text = select("#", ...) > 0 and fmt:format(...) or fmt
    local lines = ns.logLines
    lines[#lines + 1] = text
    if #lines > 50 then table.remove(lines, 1) end
    ns.Print(text)
    if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
end

---------------------------------------------------------------------------
-- Names. Every player is identified by character name alone, without a realm.
--
-- Forever puts everyone on a mega-realm, and the realm part is not consistent: addon
-- messages arrive from "Name-CAMWOWAU1Realm2PvP" while GetNormalizedRealmName() reports
-- something else, and whispering "Name-CAMWOWAU1Realm2PvP" fails with "No player named...".
-- Character names are unique on a mega-realm, so the bare name is both a reliable identity
-- and the form that whispers reach. (WoW names can't contain "-", so stripping is safe.)
---------------------------------------------------------------------------
--- Canonical player name: realm stripped, and capitalised the way the server spells it when
--- we know the player (us, the guild roster, or a guildie whose addon has said hello).
--- Typed names like "bob" must match the "Bob" that addon messages arrive from.
function ns.Full(name)
    if type(name) ~= "string" or name == "" then return nil end
    local base = name:gsub("%-.*$", "")
    local key = base:lower()
    if ns.me and ns.me:lower() == key then return ns.me end
    local known = ns.Guild and ns.Guild.byLower and ns.Guild.byLower[key]
    if known then return known end
    if ns.House and ns.House.peers then
        for peer in pairs(ns.House.peers) do
            if peer:lower() == key then return peer end
        end
    end
    return base
end

--- True if two names are the same player (case-insensitive, realm ignored).
function ns.SameName(a, b)
    return a ~= nil and b ~= nil and ns.Full(a):lower() == ns.Full(b):lower()
end

function ns.Short(name)
    return ns.Full(name) or "?"
end

---------------------------------------------------------------------------
-- Who am I? On Forever, UnitName("player") has not matched the name the server writes
-- in roll lines ("Eoka Pistol rolls 419 (1-1000)") - so the addon ignored its own rolls
-- (seen in-game 2026-11-14). We therefore keep every spelling we learn for ourselves:
--   * UnitName("player")
--   * the sender of our own guild HELLO echoing back (tagged with a per-session nonce)
--   * the roller in the first roll line after we asked the server for a roll
-- and prefer the server's spelling once we've seen it.
---------------------------------------------------------------------------
ns.myNames = {}   -- lowercase -> spelling
ns.nonce = tostring(math.random(100000, 999999))

local function base(name) return (name:gsub("%-.*$", "")) end

--- Records another spelling of our own name (fromServer: as the server writes it).
function ns.AddMyName(name, fromServer)
    if type(name) ~= "string" or name == "" then return end
    local b = base(name)
    local key = b:lower()
    local new = not ns.myNames[key]
    ns.myNames[key] = b
    if fromServer and ns.me ~= b then
        if ns.me and ns.Debug then ns.Debug("learned our server name: %s (was %s)", b, ns.me) end
        ns.me = b
        -- move my leaderboard row to the new spelling
        if ns.Board and ns.db then ns.Board.Changed() end
    end
    return new
end

function ns.Me()
    if not ns.me then
        local name = UnitName("player")
        if type(name) == "string" and name ~= "" then
            ns.me = base(name)
            ns.myNames[ns.me:lower()] = ns.me
        end
    end
    return ns.me
end

function ns.IsMe(name)
    if type(name) ~= "string" or name == "" then return false end
    ns.Me()
    return ns.myNames[base(name):lower()] ~= nil
end

---------------------------------------------------------------------------
-- Money. Amounts are copper internally, gold in the UI.
---------------------------------------------------------------------------
ns.COPPER_PER_GOLD = 10000

-- Sanity cap on any single bet. A Bet box that kept keyboard focus once turned action-bar
-- presses into a 1,111,111,111g bet (seen in-game 2026-11-14).
ns.MAX_BET_GOLD = 100000

--- A wager typed by the player, in copper: "10" or "1.5" (gold), or "1g50s25c" / "50s" / "3c"
--- (spaces allowed). 0 is allowed: a game just for fun. nil if it isn't money.
function ns.GoldToCopper(text)
    if type(text) == "number" then text = tostring(text) end
    if type(text) ~= "string" then return nil end
    text = text:lower():gsub("%s+", "")
    if text == "" then return nil end
    local g = tonumber(text)
    if g then
        if g < 0 then return nil end
        return math.floor(g * ns.COPPER_PER_GOLD + 0.5)
    end
    if text:gsub("%d+[gsc]", "") ~= "" then return nil end
    local total, seen = 0, {}
    for num, unit in text:gmatch("(%d+)([gsc])") do
        if seen[unit] then return nil end
        seen[unit] = true
        total = total + tonumber(num) * (unit == "g" and ns.COPPER_PER_GOLD or unit == "s" and 100 or 1)
    end
    return total
end
ns.ParseMoney = ns.GoldToCopper

--- A bet for messages: "fun (0g)" for a 0g game, otherwise the amount.
function ns.Stake(copper)
    if copper == 0 then return "fun (0g)" end
    return ns.Money(copper)
end

--- Win / loss / push text for a finished game. outcome (1, -1, 0) tells a 0g game's winner.
function ns.ResultText(net, outcome)
    outcome = outcome or (net > 0 and 1 or net < 0 and -1 or 0)
    if outcome > 0 then
        return net > 0 and ("|cff20ff20won " .. ns.Money(net) .. "|r") or "|cff20ff20won|r (for fun)"
    elseif outcome < 0 then
        return net < 0 and ("|cffff4040lost " .. ns.Money(-net) .. "|r") or "|cffff4040lost|r (for fun)"
    end
    return "push"
end

--- nil if we can put up `copper` (as a bet we might lose), otherwise why not.
function ns.CantCover(copper)
    if copper > ns.MAX_BET_GOLD * ns.COPPER_PER_GOLD then
        return ("bets are capped at %s"):format(ns.Money(ns.MAX_BET_GOLD * ns.COPPER_PER_GOLD))
    end
    local ok, money = pcall(GetMoney)
    if ok and type(money) == "number" and money < copper then
        return ("only has %s"):format(ns.Money(money))
    end
    return nil
end

--- A normal chat whisper (the player sees it in chat), for opponents outside our group.
function ns.Whisper(target, text)
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or _G.SendChatMessage
    if not send or not target then return false end
    return (pcall(send, text, "WHISPER", nil, target))
end

--- Posts a line in guild chat (plain text: no colour codes) if announcements are on.
function ns.GuildAnnounce(text)
    if not ns.db.announce or not (IsInGuild and IsInGuild()) then return false end
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or _G.SendChatMessage
    if not send then return false end
    if #text > 255 then text = text:sub(1, 252) .. "..." end
    return (pcall(send, text, "GUILD"))
end

--- "Bob", "Bob and Cee", "Bob, Cee and Dan"
function ns.NameList(names)
    local out = {}
    for _, n in ipairs(names) do out[#out + 1] = ns.Short(n) end
    if #out <= 1 then return out[1] or "" end
    return table.concat(out, ", ", 1, #out - 1) .. " and " .. out[#out]
end

--- True if name is in our party or raid (so they see our /rolls themselves).
function ns.InGroupWith(name)
    if not name then return false end
    local function check(fn)
        if type(fn) ~= "function" then return false end
        local ok, res = pcall(fn, name)
        return ok and res and true or false
    end
    return check(UnitInParty) or check(UnitInRaid)
end

--- "12g", "-3g 50s", "+1g".
function ns.Money(copper, signed)
    copper = math.floor(copper or 0)
    if copper == 0 then return "0g" end
    local sign = copper < 0 and "-" or (signed and copper > 0 and "+" or "")
    copper = math.abs(copper)
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
    return sign .. table.concat(parts, " ")
end

---------------------------------------------------------------------------
-- Ids
---------------------------------------------------------------------------
local counter = 0
function ns.NewId()
    counter = counter + 1
    return ("%d%03d%d"):format(time() % 100000, math.random(0, 999), counter)
end

---------------------------------------------------------------------------
-- SHA-256 (FIPS 180-4), for commit-reveal: a player locks in a secret by sending its hash,
-- and reveals it later; nobody can change the secret after seeing a roll. Uses the client's
-- `bit` library (as Questie does). Results of bit ops are normalised to unsigned 32-bit.
---------------------------------------------------------------------------
do
    local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
    local rshift, lshift = bit.rshift, bit.lshift
    local MOD = 4294967296
    local function u(x) return x % MOD end
    local function rotr(x, n) return u(bor(rshift(x, n), lshift(x, 32 - n))) end

    local K = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    }

    function ns.SHA256(msg)
        msg = tostring(msg)
        local bits = #msg * 8
        msg = msg .. "\128" .. string.rep("\0", (55 - #msg) % 64)
        msg = msg .. string.char(0, 0, 0, 0,
            math.floor(bits / 16777216) % 256, math.floor(bits / 65536) % 256,
            math.floor(bits / 256) % 256, bits % 256)
        local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
        local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        local w = {}
        for chunk = 1, #msg, 64 do
            for i = 0, 15 do
                local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
                w[i] = ((a * 256 + b) * 256 + c) * 256 + d
            end
            for i = 16, 63 do
                local x, y = w[i - 15], w[i - 2]
                local s0 = u(bxor(rotr(x, 7), rotr(x, 18), rshift(x, 3)))
                local s1 = u(bxor(rotr(y, 17), rotr(y, 19), rshift(y, 10)))
                w[i] = u(w[i - 16] + s0 + w[i - 7] + s1)
            end
            local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
            for i = 0, 63 do
                local S1 = u(bxor(rotr(e, 6), rotr(e, 11), rotr(e, 25)))
                local ch = u(bxor(band(e, f), band(bnot(e), g)))
                local t1 = u(h + S1 + ch + K[i + 1] + w[i])
                local S0 = u(bxor(rotr(a, 2), rotr(a, 13), rotr(a, 22)))
                local maj = u(bxor(band(a, b), band(a, c), band(b, c)))
                local t2 = u(S0 + maj)
                h, g, f, e = g, f, e, u(d + t1)
                d, c, b, a = c, b, a, u(t1 + t2)
            end
            h0, h1, h2, h3 = u(h0 + a), u(h1 + b), u(h2 + c), u(h3 + d)
            h4, h5, h6, h7 = u(h4 + e), u(h5 + f), u(h6 + g), u(h7 + h)
        end
        return ("%08x%08x%08x%08x%08x%08x%08x%08x"):format(h0, h1, h2, h3, h4, h5, h6, h7)
    end
end

---------------------------------------------------------------------------
-- Sounds: the game's own sound kits, played by name (no audio files ship with the addon).
-- Each event lists sound kits best-first; the first one this client has is played. The last
-- entry of every list is one the working Forever addons already play, so a sound always works.
---------------------------------------------------------------------------
ns.SOUNDS = {
    card    = { "IG_ABILITY_PAGE_TURN" },                                  -- a card is dealt / you hit
    roll    = { "UI_BONUS_LOOT_ROLL_START", "U_CHAT_SCROLL_BUTTON" },      -- a deathroll / slot roll lands
    turn    = { "MAP_PING" },                                              -- your turn to roll
    invite  = { "IG_PLAYER_INVITE", "IG_MAINMENU_OPEN" },                  -- someone challenges you
    -- short stings only: no music fanfares (they were too loud over the game)
    win     = { "LOOT_WINDOW_COIN_SOUND", "IG_QUEST_LIST_COMPLETE" },      -- you won: coin jingle
    bigwin  = { "IG_QUEST_LIST_COMPLETE" },                                -- jackpot / natural blackjack
    lose    = { "IG_PLAYER_INVITE_DECLINE" },                              -- fallback for the cry
    bust    = { "IG_PLAYER_INVITE_DECLINE" },                              -- fallback for the cry
    push    = { "IG_MAINMENU_OPTION_CHECKBOX_OFF" },                       -- void / tie
    coin    = { "LOOT_WINDOW_COIN_SOUND", "IG_QUEST_LIST_COMPLETE" },      -- a payment counted
    death   = { "IG_PLAYER_INVITE_DECLINE" },                              -- fallback for the death cry
    cheer   = {},                                                          -- the cheer has no fallback
}

-- Game sound files played by file ID (as working addons do with PlaySoundFile). Tried before
-- the kit list above; if the client doesn't have the file, the kit plays instead.
-- A table picks one at random.
ns.SOUND_FILES = {
    death = 540868,              -- sound/character/nightelf/nightelffemale/nightelffemaledeath.ogg
    lose  = 540873,              -- sound/character/nightelf/nightelffemale/nightelffemalecry01.ogg
    bust  = 540873,
    cheer = { 541043, 541055 },  -- sound/character/nightelf/nightelfvocalfemale/nightelffemalecheer01/02.ogg
}

function ns.Sound(event)
    if ns.db and ns.db.sound == false then return end
    local file = ns.SOUND_FILES[event]
    if type(file) == "function" then file = file()
    elseif type(file) == "table" then file = file[math.random(#file)] end
    if file and PlaySoundFile then
        -- on the sound-effects channel, so the game's effects volume controls it
        local ok, willPlay = pcall(PlaySoundFile, file, "SFX")
        if ok and willPlay then return file end
    end
    local kits = ns.SOUNDS[event]
    if not kits or not PlaySound or type(SOUNDKIT) ~= "table" then return end
    for _, name in ipairs(kits) do
        local id = SOUNDKIT[name]
        if id then
            pcall(PlaySound, id, "SFX")
            return name
        end
    end
end

--- A random secret string (for commit-reveal salts).
function ns.RandomSalt()
    local t = {}
    for i = 1, 16 do t[i] = ("%02x"):format(math.random(0, 255)) end
    return table.concat(t)
end
