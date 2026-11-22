-- Board.lua: guild leaderboard. Each client works out its own stats from its ledger (real
-- games, plus the guild lottery's net gold and wagered; no practice, no payments) and shares
-- them on the guild addon channel.
--
-- How everyone agrees on the rows:
--   * a player's own addon is the only source of their row. It stamps the row with the (server)
--     time its numbers last changed ("at"), and sends it to the guild on every change and to
--     each guildie who logs in;
--   * that alone only reaches whoever is online at the same time, so every addon also passes
--     on the rows it holds: on login an addon tells the guild which rows it has and how new
--     (BSUM), anyone holding a newer one broadcasts it (BROW), and anyone holding an older one
--     asks for it (BWANT). The newest stamp always wins, so every board ends up the same.
--   Rows are only passed on within the same season, and nobody takes their own row from others.
-- Stored per guild in account-wide saved variables, so it survives reloads and alts.
local ADDON_NAME, ns = ...
local Comm, Compat = ns.Comm, ns.Compat

local Board = {}
ns.Board = Board

Board.SEND_DELAY = 3 -- seconds: batch several finished games into one broadcast

local function GuildKey()
    local name = IsInGuild and IsInGuild() and Compat.Safe((GetGuildInfo("player")))
    return name or "_noguild"
end

function Board.Table()
    ns.db.board = ns.db.board or {}
    local key = GuildKey()
    ns.db.board[key] = ns.db.board[key] or {}
    return ns.db.board[key]
end

---------------------------------------------------------------------------
-- Seasons: "/gg reset <password>" starts the leaderboard fresh for the whole guild.
-- Only games after the reset count; the ledger (who owes whom) is untouched.
-- The addon only stores the password's SHA-256 fingerprint, not the password itself.
---------------------------------------------------------------------------
Board.RESET_FINGERPRINT = "5094562135cd86e840497f4b82153981122baf1adf726284cb1adaf55893f3b9"

function Board.Season()
    ns.db.seasons = ns.db.seasons or {}
    return ns.db.seasons[GuildKey()]
end

--- Applies a season started at time t (the resetter's clock), if the password checks out
--- and it's newer than the one we have. Returns true if it was applied.
function Board.ApplySeason(t, password)
    t = tonumber(t)
    if not t or type(password) ~= "string" or ns.SHA256(password) ~= Board.RESET_FINGERPRINT then return false end
    local current = Board.Season()
    if current and current.t >= t then return false end
    -- (the season starts when it was reset, even if we only hear of it later: games we've
    -- played since still count, exactly as they do for everyone who heard at once)
    ns.db.seasons[GuildKey()] = { t = t, k = password, localStart = math.min(time(), t) }
    ns.db.board = ns.db.board or {}
    ns.db.board[GuildKey()] = {}
    Board.ClearForSeason(t)
    Board.Changed() -- re-adds our own (now empty) row and re-broadcasts it
    return true
end

--- A reset wipes the slate: every debt on THIS character from before the reset is cleared, and
--- gold mailed before it no longer counts. Debts made after the reset stay - the other player
--- still has them. The season is saved per account but ledgers are per character, so each
--- character does this for itself (Board.CatchUp, at login).
function Board.ClearForSeason(t)
    for _, e in ipairs(ns.charDB.ledger) do
        if not e.settled and (e.time or 0) <= t then
            e.settled = true
            e.clearedByReset = t
        end
    end
    local at = math.min(ns.Ledger.Now(), t)
    ns.charDB.clearedAll = math.max(ns.charDB.clearedAll or 0, at)
    ns.Ledger.DropPendingMail(nil, at)
    ns.charDB.seasonT = t
end

--- At login: this character hasn't cleared its debts for the account's current season yet
--- (the reset reached another of our characters first).
function Board.CatchUp()
    local s = Board.Season()
    if not s or not ns.charDB or (ns.charDB.seasonT or 0) >= s.t then return false end
    Board.ClearForSeason(s.t)
    return true
end

--- Starts a new season for the guild. Returns false for a wrong password.
function Board.Reset(password)
    local t = time()
    local current = Board.Season()
    if current and current.t >= t then t = current.t + 1 end
    if not Board.ApplySeason(t, password) then return false end
    Comm.Send("SEASON", { t = t, k = password }, nil)
    Board.Send(nil)
    return true
end

--- Tells one player (e.g. someone who just logged in) about the current season.
function Board.SendSeason(target)
    local s = Board.Season()
    if s then Comm.Send("SEASON", { t = s.t, k = s.k }, target) end
end

Comm.On("SEASON", function(f, sender)
    if Board.ApplySeason(f.t, f.k) then
        ns.Log("%s reset the leaderboard and cleared all debts - a new season starts now!", ns.Short(sender))
        Board.Send(nil)
        C_Timer.After(3, function() Board.SendDigest() end) -- (and fetch the new season's rows)
    end
end)

-- Seasons only used to pass from players already online to someone logging in. Now any
-- message that shows the two of us are in different seasons settles it: whoever has the newer
-- one sends it (it carries its own proof), whoever has the older one asks for it.
local seasonTold = {} -- name -> GetTime() we last sent / asked
local function SeasonMismatch(theirs, sender)
    theirs = tonumber(theirs)
    local mine = Board.Season()
    mine = mine and mine.t or 0
    if not theirs or theirs == mine then return false end
    local key = (ns.Full(sender) or sender):lower()
    if GetTime() - (seasonTold[key] or -1e9) >= 60 then
        seasonTold[key] = GetTime()
        if mine > theirs then Board.SendSeason(sender) else Comm.Send("SASK", {}, sender) end
    end
    return true
end
Board.SeasonMismatch = SeasonMismatch

Comm.On("SASK", function(f, sender)
    local key = (ns.Full(sender) or sender):lower() .. "|ask"
    if GetTime() - (seasonTold[key] or -1e9) < 30 then return end
    seasonTold[key] = GetTime()
    Board.SendSeason(sender)
end)

--- My stats from the ledger (this season's real games only).
function Board.MyStats()
    local s = { net = 0, games = 0, wins = 0, losses = 0, best = 0, wagered = 0, streak = 0, drop = 0 }
    local season = Board.Season()
    local since = season and season.localStart or 0
    for _, e in ipairs(ns.charDB.ledger) do
        -- the guild lottery: net gold and wagered only (not a game, win, loss or streak)
        if e.kind == "lottery" and (e.time or 0) >= since then
            s.net = s.net + (e.net or 0)
            s.wagered = s.wagered + (e.wager or 0)
        end
        if not e.practice and (e.kind or "game") == "game" and (e.time or 0) >= since then
            s.net = s.net + e.net
            if e.net > s.best then s.best = e.net end
            if not e.extra then -- extra: the other losers' entries of one group deathroll win
                s.games = s.games + 1
                local r = e.result or e.net -- result: who won a 0g game
                if r > 0 then s.wins = s.wins + 1 elseif r < 0 then s.losses = s.losses + 1 end
                s.wagered = s.wagered + (e.wager or math.abs(e.net)) -- older entries: the amount won/lost
                -- current streak: wins (+) or losses (-) in a row, newest last; pushes don't break it
                if r > 0 then s.streak = s.streak > 0 and s.streak + 1 or 1
                elseif r < 0 then s.streak = s.streak < 0 and s.streak - 1 or -1 end
            end
            -- biggest range we rolled a 1 from (deathroll and group deathroll)
            if (e.drop or 0) > s.drop then s.drop = e.drop end
        end
    end
    local _, raceFile = UnitRace("player")
    s.race, s.sex = Compat.Safe(raceFile), Compat.Safe(UnitSex("player"))
    -- Kodo Crossing: best run ever, and the character it was run with
    s.arcade = ns.charDB.arcadeBest or 0
    s.char = ns.Arcade and ns.Arcade.Character() or "gnome"
    return s
end

--- Removes rows filed under my other spellings (e.g. "Eoka" saved before the addon learned
--- the server calls me "Eoka Pistol"), so I appear once.
function Board.CleanSelf()
    local t, me = Board.Table(), ns.Me()
    for name in pairs(t) do
        if name ~= me and ns.IsMe(name) then t[name] = nil end
    end
end

local function Row(s, at)
    return {
        net = tonumber(s.net) or 0, games = tonumber(s.games) or 0, wins = tonumber(s.wins) or 0,
        losses = tonumber(s.losses) or 0, best = tonumber(s.best) or 0, wagered = tonumber(s.wagered) or 0,
        streak = tonumber(s.streak) or 0, drop = tonumber(s.drop) or 0,
        arcade = tonumber(s.arcade) or 0, char = s.char,
        race = s.race, sex = tonumber(s.sex), seen = time(),
        at = tonumber(at) or 0, -- when its owner's numbers last changed: the newest wins
    }
end

local SAME = { "net", "games", "wins", "losses", "best", "wagered", "streak", "drop", "arcade", "char", "race", "sex" }
local function SameNumbers(a, b)
    for _, k in ipairs(SAME) do if a[k] ~= b[k] then return false end end
    return true
end

local function Store(name, s, at)
    local t = Board.Table()
    if ns.IsMe(name) then
        name = ns.Me()
        Board.CleanSelf()
    end
    t[name] = Row(s, at)
end

local function Fields(s)
    return { n = s.net, g = s.games, w = s.wins, l = s.losses, b = s.best, t = s.wagered or 0,
        k = s.streak or 0, d = s.drop or 0, ar = s.arcade or 0, ac = s.char or "",
        r = s.race or "", x = s.sex or 0 }
end

--- When my own numbers last changed (remembered per character, so logging in doesn't make an
--- unchanged row look new).
local function MyAt(s)
    local sig = Comm.Encode("S", Fields(s))
    if ns.charDB.boardSig ~= sig or not ns.charDB.boardAt then
        ns.charDB.boardSig, ns.charDB.boardAt = sig, ns.Ledger.Now()
    end
    return ns.charDB.boardAt
end

--- Sends my stats to the guild (or one player).
function Board.Send(target)
    local s = Board.MyStats()
    local at = MyAt(s)
    Store(ns.Me(), s, at)
    local f = Fields(s)
    f.v = at
    local season = Board.Season()
    f.s = season and season.t or 0 -- (which season these numbers are for)
    Comm.Send("STATS", f, target)
end

local pending = false
--- Call after anything that changes my stats; broadcasts once a few seconds later.
function Board.Changed()
    local mine = Board.MyStats()
    Store(ns.Me(), mine, MyAt(mine))
    if ns.UI then ns.UI.Refresh() end
    if pending then return end
    pending = true
    C_Timer.After(Board.SEND_DELAY, function()
        pending = false
        Board.Send(nil)
    end)
end

--- Players sorted by net winnings (best first).
function Board.Ranked()
    Board.CleanSelf()
    local list = {}
    for name, s in pairs(Board.Table()) do
        -- anyone who has played a game, or put gold in the lottery
        if (s.games and s.games > 0) or (tonumber(s.wagered) or 0) > 0 then
            list[#list + 1] = { name = name, net = s.net, games = s.games, wins = s.wins, losses = s.losses,
                best = s.best, wagered = s.wagered or 0, streak = s.streak or 0, drop = s.drop or 0,
                race = s.race, sex = s.sex }
        end
    end
    table.sort(list, function(a, b)
        if a.net ~= b.net then return a.net > b.net end
        return a.name < b.name
    end)
    return list
end

--- Kodo Crossing high scores: { { name, score, char } }, best first.
function Board.HighScores()
    Board.CleanSelf()
    local list = {}
    for name, s in pairs(Board.Table()) do
        if (s.arcade or 0) > 0 then list[#list + 1] = { name = name, score = s.arcade, char = s.char or "gnome" } end
    end
    table.sort(list, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.name < b.name
    end)
    return list
end

--- The guild's biggest drop to 1 this season: name, range (or nil).
function Board.BiggestDrop()
    local who, best = nil, 0
    for name, s in pairs(Board.Table()) do
        if (s.drop or 0) > best then who, best = name, s.drop end
    end
    return who, best > 0 and best or nil
end

local function FromFields(f)
    return { net = f.n, games = f.g, wins = f.w, losses = f.l, best = f.b, wagered = f.t,
        streak = f.k, drop = f.d, arcade = f.ar, char = f.ac ~= "" and f.ac or nil,
        race = f.r ~= "" and f.r or nil, sex = f.x }
end

-- A player's own row, from that player: always taken.
Comm.On("STATS", function(f, sender)
    -- numbers from another season aren't this season's (an older addon doesn't say: taken as before)
    if f.s and SeasonMismatch(f.s, sender) then return end
    local s = FromFields(f)
    local at = tonumber(f.v)
    if not at then
        -- an older addon doesn't stamp its row: it's as new as when we first heard these numbers
        local cur = Board.Table()[ns.Full(sender) or sender]
        at = (cur and SameNumbers(cur, Row(s)) and cur.at) or ns.Ledger.Now()
    end
    Store(sender, s, at)
    if ns.UI then ns.UI.Refresh() end
end)

---------------------------------------------------------------------------
-- Passing rows on, so every board agrees (see the top of the file).
-- All of it waits behind game messages, and goes out one row a second.
---------------------------------------------------------------------------
Board.DIGEST_DELAY = 10                 -- seconds after our hello before we compare boards
Board.ANSWER_MIN, Board.ANSWER_SPREAD = 3, 10 -- answer a comparison 3-12s later (each addon its own moment)
Board.AIR_EVERY = 1                     -- seconds between rows we broadcast
Board.AIRED_FOR = 15                    -- a row broadcast this recently isn't broadcast again

local function SeasonT()
    local s = Board.Season()
    return s and s.t or 0
end

-- rows worth passing on: anyone who shows on a list
local function Shown(r)
    return (r.games or 0) > 0 or (tonumber(r.wagered) or 0) > 0 or (r.arcade or 0) > 0
end

-- an owner who is online sends their own row: no need to pass it on
local function OwnerOnline(name)
    return ns.Guild and ns.Guild.IsOnline(name) == true
end

local function Hash(s)
    local h = 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 65521 end
    return h
end

local function Batched(items, fn)
    local cur = ""
    for _, item in ipairs(items) do
        if cur ~= "" and #cur + #item + 1 > 180 then fn(cur) cur = "" end
        cur = cur == "" and item or (cur .. ";" .. item)
    end
    fn(cur) -- (an empty list still says "I have nothing")
end

--- Tells the guild which rows we hold and how new each is.
function Board.SendDigest()
    if not (ns.db and ns.charDB) then return end
    Board.CleanSelf()
    local items = {}
    for name, r in pairs(Board.Table()) do
        if not ns.IsMe(name) and Shown(r) and not name:find("[:;]") then
            items[#items + 1] = name .. ":" .. (r.at or 0)
        end
    end
    table.sort(items)
    local season = SeasonT()
    Batched(items, function(part) Comm.Send("BSUM", { s = season, b = part }, nil) end)
end

Board.aired = {}   -- name -> { at, t }: rows somebody broadcast a moment ago
Board.outbox = {}  -- names of rows we're about to broadcast, in order
Board.queued = {}  -- name -> true while it's in the outbox
local airing = false

local function AiredLately(name, at)
    local a = Board.aired[name]
    return a ~= nil and a.at >= at and GetTime() - a.t < Board.AIRED_FOR
end

local function AirNext()
    while Board.outbox[1] do
        local name = table.remove(Board.outbox, 1)
        Board.queued[name] = nil
        local r = Board.Table()[name]
        if r and not ns.IsMe(name) and not AiredLately(name, r.at or 0) then
            local f = Fields(r)
            f.o, f.v, f.s = name, r.at or 0, SeasonT()
            Board.aired[name] = { at = r.at or 0, t = GetTime() }
            Comm.Send("BROW", f, nil)
            C_Timer.After(Board.AIR_EVERY, AirNext)
            return
        end
    end
    airing = false
end

--- Queues one of the rows we hold for a broadcast to the guild.
local function Air(name)
    if Board.queued[name] then return end
    Board.queued[name] = true
    Board.outbox[#Board.outbox + 1] = name
    if airing then return end
    airing = true
    -- (a moment of our own first, so two addons answering together don't send in step)
    C_Timer.After(Hash(ns.Me() or "") % 20 / 20, AirNext)
end

-- What `sender` holds (d: name -> at), once their whole list is in: broadcast what we have
-- newer, ask them for what they have newer.
local function Answer(sender, d)
    local t, me = Board.Table(), ns.Me() or ""
    local offers, wants = {}, {}
    for name, r in pairs(t) do
        if not ns.IsMe(name) and not ns.SameName(name, sender) and Shown(r) and not OwnerOnline(name)
            and (r.at or 0) > (d[name] or -1) then
            offers[#offers + 1] = name
        end
    end
    for name, at in pairs(d) do
        local r = t[name]
        if not ns.IsMe(name) and not OwnerOnline(name) and (not r or (r.at or 0) < at) then wants[#wants + 1] = name end
    end
    -- each addon in its own order, so two answering at once don't broadcast the same rows first
    table.sort(offers, function(a, b)
        local ha, hb = Hash(a .. me), Hash(b .. me)
        if ha ~= hb then return ha < hb end
        return a < b
    end)
    for _, name in ipairs(offers) do Air(name) end
    if #wants > 0 then
        table.sort(wants)
        local season = SeasonT()
        Batched(wants, function(part) Comm.Send("BWANT", { s = season, b = part }, sender) end)
    end
end

Board.lists = {} -- sender -> { d = { name -> at }, gen } while their list is still arriving

Comm.On("BSUM", function(f, sender, channel)
    if channel ~= "GUILD" then return end
    if Board.SeasonMismatch(f.s, sender) or tonumber(f.s) ~= SeasonT() then return end
    local job = Board.lists[sender] or { d = {}, gen = 0 }
    Board.lists[sender] = job
    for name, at in (f.b or ""):gmatch("([^:;]+):(%d+)") do job.d[name] = tonumber(at) end
    job.gen = job.gen + 1
    local gen = job.gen
    local wait = Board.ANSWER_MIN + Hash((ns.Me() or "") .. sender) % Board.ANSWER_SPREAD
    C_Timer.After(wait, function()
        if Board.lists[sender] ~= job or job.gen ~= gen then return end -- more of the list came in
        Board.lists[sender] = nil
        if ns.db and ns.charDB then Answer(sender, job.d) end
    end)
end)

-- someone holds an older copy of these rows than we told the guild we have
Comm.On("BWANT", function(f)
    if tonumber(f.s) ~= SeasonT() then return end
    local t = Board.Table()
    for name in (f.b or ""):gmatch("[^;]+") do
        if t[name] and not ns.IsMe(name) then Air(name) end
    end
end)

-- somebody else's row, passed on: taken only if it's newer than ours
Comm.On("BROW", function(f, sender, channel)
    if channel ~= "GUILD" or tonumber(f.s) ~= SeasonT() then return end
    local at = tonumber(f.v)
    local owner = type(f.o) == "string" and f.o ~= "" and (ns.Full(f.o) or f.o) or nil
    if not at or not owner or ns.IsMe(owner) or ns.SameName(owner, sender) then return end
    local a = Board.aired[owner]
    if not a or a.at <= at then Board.aired[owner] = { at = at, t = GetTime() } end
    local cur = Board.Table()[owner]
    if cur and (cur.at or 0) >= at then return end
    Store(owner, FromFields(f), at)
    if ns.UI then ns.UI.Refresh() end
end)

---------------------------------------------------------------------------
-- The same passing-on for another table of per-player rows (the wealth chart uses it). It is
-- the scheme above, kept separate so the leaderboard's own code stays exactly as it was:
-- on login we tell the guild which rows we hold and how new (cfg.sum), anyone holding a newer
-- one broadcasts it (cfg.row), anyone holding an older one asks for it (cfg.want). The newest
-- stamp ("at", set by the row's owner) wins; nobody takes their own row from others.
--   cfg: sum, want, row = message types; table() = name -> row (each with .at);
--        shown(name, row) = worth passing on; fields(row) = its message fields;
--        take(owner, fields, at) = store one that was passed on.
-- A row too long for one message goes out as two halves (p=1, p=2) and is taken once both are in.
---------------------------------------------------------------------------
function Board.NewRelay(cfg)
    local relay = { aired = {}, outbox = {}, queued = {}, lists = {}, halves = {} }
    local airing = false

    local function AiredLately(name, at)
        local a = relay.aired[name]
        return a ~= nil and a.at >= at and GetTime() - a.t < Board.AIRED_FOR
    end

    local function Rows()
        local ok, t = pcall(cfg.table)
        return ok and type(t) == "table" and t or {}
    end

    local function Worth(name, r)
        if type(r) ~= "table" or ns.IsMe(name) or name:find("[:;]") then return false end
        local ok, yes = pcall(cfg.shown, name, r)
        return ok and yes and true or false
    end

    function relay.SendDigest()
        if not (ns.db and ns.charDB) then return end
        local items = {}
        for name, r in pairs(Rows()) do
            if Worth(name, r) then items[#items + 1] = name .. ":" .. (tonumber(r.at) or 0) end
        end
        table.sort(items)
        Batched(items, function(part) Comm.Send(cfg.sum, { b = part }, nil) end)
    end

    local function SendRow(name, r)
        local ok, f = pcall(cfg.fields, r)
        if not ok or type(f) ~= "table" then return false end
        local at = tonumber(r.at) or 0
        f.o, f.v = name, at
        if #Comm.Encode(cfg.row, f) <= 255 then
            Comm.Send(cfg.row, f, nil)
            return true
        end
        -- too long for one message: two halves
        local keys = {}
        for k in pairs(f) do if k ~= "o" and k ~= "v" then keys[#keys + 1] = k end end
        table.sort(keys)
        local half = math.ceil(#keys / 2)
        local parts = { { o = name, v = at, p = 1 }, { o = name, v = at, p = 2 } }
        for i, k in ipairs(keys) do parts[i <= half and 1 or 2][k] = f[k] end
        for _, part in ipairs(parts) do
            if #Comm.Encode(cfg.row, part) > 255 then return false end
        end
        for _, part in ipairs(parts) do Comm.Send(cfg.row, part, nil) end
        return true
    end

    local function AirNext()
        while relay.outbox[1] do
            local name = table.remove(relay.outbox, 1)
            relay.queued[name] = nil
            local r = Rows()[name]
            if r and Worth(name, r) and not AiredLately(name, tonumber(r.at) or 0) then
                relay.aired[name] = { at = tonumber(r.at) or 0, t = GetTime() }
                if SendRow(name, r) then
                    C_Timer.After(Board.AIR_EVERY, AirNext)
                    return
                end
            end
        end
        airing = false
    end

    local function Air(name)
        if relay.queued[name] then return end
        relay.queued[name] = true
        relay.outbox[#relay.outbox + 1] = name
        if airing then return end
        airing = true
        C_Timer.After(Hash(ns.Me() or "") % 20 / 20, AirNext)
    end

    local function Answer(sender, d)
        local t, me = Rows(), ns.Me() or ""
        local offers, wants = {}, {}
        for name, r in pairs(t) do
            if Worth(name, r) and not ns.SameName(name, sender) and not OwnerOnline(name)
                and (tonumber(r.at) or 0) > (d[name] or -1) then
                offers[#offers + 1] = name
            end
        end
        for name, at in pairs(d) do
            local r = t[name]
            if not ns.IsMe(name) and not OwnerOnline(name) and (not r or (tonumber(r.at) or 0) < at) then
                wants[#wants + 1] = name
            end
        end
        table.sort(offers, function(a, b)
            local ha, hb = Hash(a .. me), Hash(b .. me)
            if ha ~= hb then return ha < hb end
            return a < b
        end)
        for _, name in ipairs(offers) do Air(name) end
        if #wants > 0 then
            table.sort(wants)
            Batched(wants, function(part) Comm.Send(cfg.want, { b = part }, sender) end)
        end
    end

    Comm.On(cfg.sum, function(f, sender, channel)
        if channel ~= "GUILD" then return end
        local job = relay.lists[sender] or { d = {}, gen = 0 }
        relay.lists[sender] = job
        for name, at in (f.b or ""):gmatch("([^:;]+):(%d+)") do job.d[name] = tonumber(at) end
        job.gen = job.gen + 1
        local gen = job.gen
        local wait = Board.ANSWER_MIN + Hash((ns.Me() or "") .. sender) % Board.ANSWER_SPREAD
        C_Timer.After(wait, function()
            if relay.lists[sender] ~= job or job.gen ~= gen then return end
            relay.lists[sender] = nil
            if ns.db and ns.charDB then Answer(sender, job.d) end
        end)
    end)

    Comm.On(cfg.want, function(f)
        local t = Rows()
        for name in (f.b or ""):gmatch("[^;]+") do
            if t[name] and Worth(name, t[name]) then Air(name) end
        end
    end)

    Comm.On(cfg.row, function(f, sender, channel)
        if channel ~= "GUILD" then return end
        local at = tonumber(f.v)
        local owner = type(f.o) == "string" and f.o ~= "" and (ns.Full(f.o) or f.o) or nil
        if not at or not owner or ns.IsMe(owner) or ns.SameName(owner, sender) then return end
        if f.p then
            -- one half of a long row: wait for the other
            local key = sender .. "|" .. owner .. "|" .. at
            local h = relay.halves[key] or { f = {}, got = {} }
            relay.halves[key] = h
            for k, v in pairs(f) do if k ~= "p" then h.f[k] = v end end
            h.got[f.p] = true
            if not (h.got["1"] and h.got["2"]) then return end
            relay.halves[key] = nil
            f = h.f
        end
        local a = relay.aired[owner]
        if not a or a.at <= at then relay.aired[owner] = { at = at, t = GetTime() } end
        local cur = Rows()[owner]
        if cur and (tonumber(cur.at) or 0) >= at then return end
        cfg.take(owner, f, at)
    end)

    return relay
end
