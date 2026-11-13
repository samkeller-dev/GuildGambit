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
