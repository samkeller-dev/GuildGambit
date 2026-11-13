-- Board.lua: guild leaderboard. Each client works out its own stats from its ledger (real
-- games only, no practice, no payments) and shares them on the guild addon channel.
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
    ns.db.seasons[GuildKey()] = { t = t, k = password, localStart = time() }
    ns.db.board = ns.db.board or {}
    ns.db.board[GuildKey()] = {}
    -- a reset wipes the slate: every open debt on this client is cleared too
    for _, e in ipairs(ns.charDB.ledger) do
        if not e.settled then
            e.settled = true
            e.clearedByReset = t
        end
    end
    Board.Changed() -- re-adds our own (now empty) row and re-broadcasts it
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
    end
end)

--- My stats from the ledger (this season's real games only).
function Board.MyStats()
    local s = { net = 0, games = 0, wins = 0, losses = 0, best = 0, wagered = 0 }
    local season = Board.Season()
    local since = season and season.localStart or 0
    for _, e in ipairs(ns.charDB.ledger) do
        if not e.practice and (e.kind or "game") == "game" and (e.time or 0) >= since then
            s.net = s.net + e.net
            if e.net > s.best then s.best = e.net end
            if not e.extra then -- extra: the other losers' entries of one group deathroll win
                s.games = s.games + 1
                local r = e.result or e.net -- result: who won a 0g game
                if r > 0 then s.wins = s.wins + 1 elseif r < 0 then s.losses = s.losses + 1 end
                s.wagered = s.wagered + (e.wager or math.abs(e.net)) -- older entries: the amount won/lost
            end
        end
    end
    local _, raceFile = UnitRace("player")
    s.race, s.sex = Compat.Safe(raceFile), Compat.Safe(UnitSex("player"))
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

local function Store(name, s)
    local t = Board.Table()
    if ns.IsMe(name) then
        name = ns.Me()
        Board.CleanSelf()
    end
    t[name] = {
        net = tonumber(s.net) or 0, games = tonumber(s.games) or 0, wins = tonumber(s.wins) or 0,
        losses = tonumber(s.losses) or 0, best = tonumber(s.best) or 0, wagered = tonumber(s.wagered) or 0,
        race = s.race, sex = tonumber(s.sex), seen = time(),
    }
end

local function Fields(s)
    return { n = s.net, g = s.games, w = s.wins, l = s.losses, b = s.best, t = s.wagered or 0,
        r = s.race or "", x = s.sex or 0 }
end

--- Sends my stats to the guild (or one player).
function Board.Send(target)
    local s = Board.MyStats()
    Store(ns.Me(), s)
    Comm.Send("STATS", Fields(s), target)
end

local pending = false
--- Call after anything that changes my stats; broadcasts once a few seconds later.
function Board.Changed()
    Store(ns.Me(), Board.MyStats())
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
        if s.games and s.games > 0 then
            list[#list + 1] = { name = name, net = s.net, games = s.games, wins = s.wins, losses = s.losses,
                best = s.best, wagered = s.wagered or 0, race = s.race, sex = s.sex }
        end
    end
    table.sort(list, function(a, b)
        if a.net ~= b.net then return a.net > b.net end
        return a.name < b.name
    end)
    return list
end

Comm.On("STATS", function(f, sender)
    Store(sender, { net = f.n, games = f.g, wins = f.w, losses = f.l, best = f.b, wagered = f.t,
        race = f.r ~= "" and f.r or nil, sex = f.x })
    if ns.UI then ns.UI.Refresh() end
end)
