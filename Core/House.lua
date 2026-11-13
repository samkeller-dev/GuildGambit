-- House.lua: knowing which guildies have GuildGambit (and which version), plus a few
-- messages every game shares. (Houses - one player covering everyone's bets - were removed:
-- every game is 1v1 between two guildies.)
local ADDON_NAME, ns = ...
local Comm = ns.Comm

local House = {}
ns.House = House

House.peers = {} -- name -> { version, protocol, seen }

-- Bumped only when the game messages change, so bug-fix releases stay compatible.
-- Versions before 0.5.1 don't send it and count as outdated.
House.PROTOCOL = 7

local function Peer(name)
    local p = House.peers[name] or {}
    House.peers[name] = p
    p.seen = time()
    return p
end

--- Any message from a guildie's addon: they have GuildGambit.
function House.SeePeer(name)
    if name and not ns.IsMe(name) then
        Peer(name)
        if ns.Ledger and ns.Ledger.Reask then ns.Ledger.Reask(name) end -- mailed gold to confirm
    end
end

House.PEER_RECENT = 600 -- with no guild roster to ask, "online" = heard from in the last 10 min

--- "ok", "outdated" (theirs is too old), "newer" (ours is too old - we need to update), or
--- "unknown" (no version heard yet). Only "ok" can play together.
function House.Status(name)
    local p = House.peers[ns.Full(name) or ""]
    if not p or not p.version then return "unknown" end
    local theirs = tonumber(p.protocol) or 0
    if theirs < House.PROTOCOL then return "outdated" end
    if theirs > House.PROTOCOL then return "newer" end
    return "ok"
end

--- Guild members with GuildGambit who are online now, sorted by name.
--- Each entry: { name, version, status }.
function House.OnlinePeers()
    ns.Guild.Rebuild() -- fresh membership and online status every time the list is built
    local out = {}
    for name, p in pairs(House.peers) do
        if not ns.IsMe(name) and ns.Guild.IsMember(name) then
            local online = ns.Guild.IsOnline(name)
            if online == nil then online = (time() - (p.seen or 0)) < House.PEER_RECENT end
            if online then out[#out + 1] = { name = name, version = p.version, status = House.Status(name) } end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local function Hello(target, isReply)
    Comm.Send("HELLO", { v = ns.version, p = House.PROTOCOL, n = (not target) and ns.nonce or nil,
        r = isReply and 1 or nil }, target)
end

function House.SayHello()
    Hello(nil, false)
    if ns.Board then ns.Board.Send(nil) end
end

--- Asks one player for their version (they answer with a HELLO reply).
function House.AskVersion(name)
    Hello(name, false)
end

--- The red error for an outdated player, at most once per player per session.
local warnedOutdated = {}
function House.WarnOutdated(name, force)
    local key = (ns.Full(name) or ""):lower()
    if warnedOutdated[key] and not force then return end
    warnedOutdated[key] = true
    local p = House.peers[ns.Full(name) or ""] or {}
    if House.Status(name) == "newer" then
        ns.Print("|cffff4040Your GuildGambit is outdated (v%s) - %s has v%s. Update to play together.|r",
            ns.version, ns.Short(name), p.version or "?")
    else
        ns.Print("|cffff4040%s has an outdated GuildGambit (v%s) - you have v%s. They need to update before you can play together.|r",
            ns.Short(name), p.version or "?", ns.version)
    end
end

--- nil if we can play name, otherwise the reason (also printed as an error in chat).
function House.CheckOpponent(name)
    if not name then return "no opponent" end
    if ns.db.guildOnly and not ns.Guild.IsMember(name) and ns.Guild.rosterKnown then
        ns.Print("|cffff4040%s isn't in your guild.|r", ns.Short(name))
        return "not in my guild"
    end
    local status = House.Status(name)
    if status == "outdated" or status == "newer" then
        House.WarnOutdated(name, true)
        return "outdated GuildGambit - please update"
    end
    return nil
end

--- Compares "1.2.3" version strings: returns true if a is newer than b.
function House.IsNewer(a, b)
    local function parts(v)
        local out = {}
        for n in tostring(v or ""):gmatch("%d+") do out[#out + 1] = tonumber(n) end
        return out
    end
    local pa, pb = parts(a), parts(b)
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i] or 0, pb[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

local warnedVersion
local function CheckVersion(theirs, sender)
    if theirs and House.IsNewer(theirs, ns.version) and theirs ~= warnedVersion then
        warnedVersion = theirs
        ns.Print("|cffffd100%s has GuildGambit v%s - you have v%s. Please update, older versions may not play with newer ones.|r",
            ns.Short(sender), theirs, ns.version)
    end
end

Comm.On("HELLO", function(f, sender)
    local p = Peer(sender)
    p.version, p.protocol = f.v, tonumber(f.p)
    CheckVersion(f.v, sender)
    -- a version mismatch with a guildie: a red error in chat (whoever is behind is named)
    local status = House.Status(sender)
    if (status == "outdated" or status == "newer") and ns.Guild.IsMember(sender) then House.WarnOutdated(sender) end
    if ns.UI then ns.UI.Refresh() end
    if f.r then return end -- a reply to our hello: nothing more to send
    Hello(sender, true)    -- tell them our version too
    if ns.Board then
        ns.Board.SendSeason(sender) -- first, so their board resets before our stats arrive
        ns.Board.Send(sender)
    end
end)

-- Shared messages handled here so every module is loaded first.
Comm.On("ROLL", function(f, sender) ns.Rolls.OnRelay(f, sender) end)

Comm.On("CANCEL", function(f, sender)
    local game = ns.Games.Get(f.id)
    if game and game.kind ~= "groupdr" and ns.SameName(game.opponent, sender) then
        ns.Games.Cancel(game, "by " .. ns.Short(sender), true)
    end
end)

---------------------------------------------------------------------------
-- Live games and spectators (kept in this file so it loads without changing the file list).
--
-- Every real game (deathroll, group deathroll, blackjack, slots, coinflip) is announced to the
-- guild by ONE addon - the challenger's, or the group host's - with a LIVE message, repeated
-- every LIVE_HEARTBEAT seconds while it runs and ended with LIVE_END. Guildies see them in the
-- Live tab. Watching one sends WATCH to that addon, which then sends the watcher SPEC updates:
-- a few lines of plain text describing the table from a neutral seat. Blackjack hole cards
-- stay hidden until the showdown, so a spectator can't tip anyone off.
---------------------------------------------------------------------------
local Live = {}
ns.Live = Live

Live.HEARTBEAT = 20     -- seconds between LIVE repeats
Live.EXPIRE = 70        -- a game we haven't heard about for this long is gone
Live.ENDED_SHOW = 60    -- a finished game stays in the list this long, showing the result
Live.MAX_WATCHERS = 15
Live.LINE_MAX = 120
Live.games = {}         -- id -> { id, host, h, a, b, seen, ended, endedAt } (other people's games)
Live.watching = nil     -- id we're watching

local function Cut(s)
    s = tostring(s or "")
    if #s > Live.LINE_MAX then s = s:sub(1, Live.LINE_MAX - 3) .. "..." end
    return s
end

--- True if this addon is the one that announces this game.
function Live.IsAnnouncer(game)
    if not game or game.practice or game.asHouse then return false end
    if game.kind == "groupdr" then return ns.IsMe(game.host) end
    return game.a ~= nil and ns.IsMe(game.a) and game.state ~= "invite"
end

local function Name(n) return ns.Short(n) end

-- Blackjack hand as a spectator sees it: hidden cards (unknown, or my own hole card before
-- the showdown) as "?".
local function HandLine(name, hand, cards, hideIndex)
    local BJR = ns.Rules.Blackjack
    local shown, hidden = {}, 0
    for i, c in ipairs(cards or {}) do
        if c and i ~= hideIndex then shown[#shown + 1] = c else hidden = hidden + 1 end
    end
    local text = #shown > 0 and BJR.HandText(shown) or ""
    if hidden > 0 then text = text .. (" ?"):rep(hidden) end
    local value = #shown > 0 and BJR.ValueText(shown) or "?"
    local flags = ""
    if hand and hand.doubled then flags = flags .. "  doubled" end
    if hand and hand.done then flags = flags .. "  done" end
    return ("%s: %s  (%s%s)%s"):format(Name(name), text ~= "" and text or "-", value, hidden > 0 and " + ?" or "", flags)
end

--- header, line 1, line 2 describing the game from a neutral seat.
function Live.Describe(game)
    local kind = game.kind
    if kind == "groupdr" then
        local each = ns.Stake(game.bet) .. (game.bet > 0 and " each" or "")
        local h = ("Group Deathroll: %d players - %s"):format(#game.players, each)
        local out = {}
        for _, n in ipairs(game.out or {}) do out[n] = true end
        local names = {}
        for _, n in ipairs(game.players) do
            local s = Name(n)
            if out[n] then s = s .. " (out)" elseif game.turn and ns.SameName(game.turn, n) then s = "> " .. s end
            names[#names + 1] = s
        end
        if game.state == "lobby" then
            return h, "Waiting to start: " .. table.concat(names, ", "), ("Host: %s, 1-%d"):format(Name(game.host), game.start)
        end
        local lr = game.lastRoll
        local l2 = lr and (("%s rolled %d (1-%d)"):format(Name(lr.who), lr.value, lr.max)
            .. (lr.value == 1 and " - OUT!" or "")) or ("Starting at 1-%d"):format(game.start)
        if game.turn then l2 = l2 .. ("  |  %s rolls 1-%d"):format(Name(game.turn), game.max) end
        return h, table.concat(names, ", "), l2
    end
    local h = ("%s: %s vs %s - %s"):format(game.title or kind, Name(game.a), Name(game.b), ns.Stake(game.bet or game.stake or 0))
    if kind == "deathroll" then
        local lr = game.lastRoll
        local l1 = lr and ("%s rolled %d (1-%d)"):format(Name(lr.who), lr.value, lr.max)
            or ("%s rolls first: 1-%d"):format(Name(game.a), game.start)
        local l2 = (game.turn and not game.finished) and ("Next: %s rolls 1-%d"):format(Name(game.turn), game.max) or ""
        return h, l1, l2
    elseif kind == "blackjack" and game.mode == "duel" then
        local mySide = ns.IsMe(game.a) and "a" or "b"
        local function line(side)
            local hand = game.hands[side]
            local mine = side == mySide
            return HandLine(side == "a" and game.a or game.b, hand, hand.cards,
                (mine and not game.finished) and game.myHole or nil)
        end
        return h, line("a"), line("b")
    elseif kind == "slots" and game.mode == "duel" then
        local function line(side)
            local sp = game.spins[side]
            local last = sp.last and (", last " .. sp.last.name .. (sp.last.mult > 0 and (" x" .. sp.last.mult) or "")) or ""
            return ("%s: x%d after %d/%d spins%s"):format(Name(side == "a" and game.a or game.b), sp.total, sp.count, game.n, last)
        end
        return h, line("a"), line("b")
    elseif kind == "coinflip" then
        local CF = ns.Coinflip
        local call = game.call and CF.Label(game.call) or "?"
        local other = game.call and CF.Label(game.call == "A" and "H" or "A") or "?"
        return h, ("%s calls %s, %s has %s"):format(Name(game.a), call, Name(game.b), other),
            game.landed and ("Landed " .. CF.Label(game.landed)) or "Flipping..."
    end
    return h, game.status or "", ""
end

--- "Eoka won 10g from Bob" (neutral), for the end of a game.
function Live.ResultText(game)
    if game.kind == "groupdr" then
        if not game.winner then return "Ended with no winner" end
        local pot = game.bet * (#game.players - 1)
        return ("%s is the last one standing%s"):format(Name(game.winner), pot > 0 and (" - wins " .. ns.Money(pot)) or "")
    end
    if not game.finished then return "Cancelled" end
    local o = game.outcome or 0
    if o == 0 then return "Push - nobody wins" end
    local winner = o > 0 and ns.Me() or game.opponent
    local loser = o > 0 and game.opponent or ns.Me()
    local amount = math.abs(game.net or 0)
    return ("%s beat %s%s"):format(Name(winner), Name(loser), amount > 0 and (" - wins " .. ns.Money(amount)) or " (just for fun)")
end

local function SendSpec(game, target)
    local h, l1, l2 = Live.Describe(game)
    Comm.Send("SPEC", { id = game.id, h = Cut(h), a = Cut(l1), b = Cut(l2) }, target)
end

--- Called when one of my games ends (from Games.Remove).
function Live.End(game)
    local live = game.live
    if not live then return end
    game.live = nil
    Comm.Send("LIVE_END", { id = game.id, r = Cut(Live.ResultText(game)) }, nil)
    for name in pairs(live.watchers) do SendSpec(game, name) end -- the final table
end

function Live.WatcherCount(game)
    local n = 0
    if game and game.live then for _ in pairs(game.live.watchers) do n = n + 1 end end
    return n
end

--- Once a second: announce my game, update its watchers, forget stale games.
local function Tick()
    local now = GetTime()
    local game = ns.Games and ns.Games.Mine()
    if game and Live.IsAnnouncer(game) then
        local live = game.live
        if not live then
            live = { sent = 0, watchers = {}, last = nil }
            game.live = live
        end
        local h = Live.Describe(game)
        if now - live.sent >= Live.HEARTBEAT or live.header ~= h then
            live.sent, live.header = now, h
            Comm.Send("LIVE", { id = game.id, h = Cut(h) }, nil)
        end
        if next(live.watchers) then
            local h2, l1, l2 = Live.Describe(game)
            local text = h2 .. "\n" .. l1 .. "\n" .. l2
            if text ~= live.last then
                live.last = text
                for name in pairs(live.watchers) do SendSpec(game, name) end
            end
        end
    end
    local changed = false
    for id, g in pairs(Live.games) do
        if (g.ended and now - g.endedAt > Live.ENDED_SHOW) or (not g.ended and now - g.seen > Live.EXPIRE) then
            if Live.watching == id and not g.ended then g.ended, g.endedAt = "Lost touch with this game", now
            elseif Live.watching ~= id or now - (g.endedAt or now) > Live.ENDED_SHOW then
                Live.games[id] = nil
                if Live.watching == id then Live.watching = nil end
            end
            changed = true
        end
    end
    if changed and ns.UI then ns.UI.Refresh() end
    C_Timer.After(1, Tick)
end
C_Timer.After(1, Tick)

--- Games other people are playing, newest first.
function Live.List()
    local list = {}
    for _, g in pairs(Live.games) do list[#list + 1] = g end
    -- games still running first, newest first
    table.sort(list, function(x, y)
        if (x.ended == nil) ~= (y.ended == nil) then return x.ended == nil end
        return (x.first or 0) > (y.first or 0)
    end)
    return list
end

function Live.Watch(id)
    local g = Live.games[id]
    if not g then return false end
    if Live.watching and Live.watching ~= id then Live.Unwatch() end
    Live.watching = id
    Comm.Send("WATCH", { id = id }, g.host)
    if ns.UI then ns.UI.Refresh() end
    return true
end

function Live.Unwatch()
    local id = Live.watching
    if not id then return end
    Live.watching = nil
    local g = Live.games[id]
    if g and not g.ended then Comm.Send("UNWATCH", { id = id }, g.host) end
    if ns.UI then ns.UI.Refresh() end
end

Comm.On("LIVE", function(f, sender)
    if not f.id or not ns.Guild.Allowed(sender) then return end
    local g = Live.games[f.id]
    if not g then
        g = { id = f.id, host = sender, first = GetTime() }
        Live.games[f.id] = g
    end
    if not ns.SameName(g.host, sender) then return end
    g.h, g.seen = f.h, GetTime()
    -- we were watching and the host forgot us (e.g. they reloaded): ask again
    if Live.watching == f.id and not g.l1 then Comm.Send("WATCH", { id = f.id }, sender) end
    if ns.UI then ns.UI.Refresh() end
end)

Comm.On("LIVE_END", function(f, sender)
    local g = Live.games[f.id or ""]
    if not g or not ns.SameName(g.host, sender) then return end
    g.ended, g.endedAt = f.r or "Finished", GetTime()
    if ns.UI then ns.UI.Refresh() end
end)

Comm.On("WATCH", function(f, sender)
    local game = ns.Games.Get(f.id)
    if not game or not game.live or not ns.Guild.Allowed(sender) then return end
    if not game.live.watchers[sender] then
        if Live.WatcherCount(game) >= Live.MAX_WATCHERS then return end
        game.live.watchers[sender] = true
        ns.Log("%s is watching your game.", Name(sender))
    end
    SendSpec(game, sender)
    if ns.UI then ns.UI.Refresh() end
end)

Comm.On("UNWATCH", function(f, sender)
    local game = ns.Games.Get(f.id)
    if game and game.live then
        game.live.watchers[sender] = nil
        if ns.UI then ns.UI.Refresh() end
    end
end)

Comm.On("SPEC", function(f, sender)
    local g = Live.games[f.id or ""]
    if not g or not ns.SameName(g.host, sender) then return end
    g.h, g.l1, g.l2, g.seen = f.h or g.h, f.a or "", f.b or "", GetTime()
    if ns.UI then ns.UI.Refresh() end
end)
