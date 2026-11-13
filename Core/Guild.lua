-- Guild.lua: guild roster membership, so games are only accepted from guildies.
local ADDON_NAME, ns = ...
local Compat = ns.Compat

local Guild = {}
ns.Guild = Guild

Guild.members = {}
Guild.count = 0

function Guild.Request()
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        pcall(C_GuildInfo.GuildRoster)
    end
end

Guild.byLower = {} -- "bob" -> "Bob": how the server spells each member's name

Guild.online = {} -- "bob" -> true while they're online (from the roster)

function Guild.Rebuild()
    local members, byLower, online, count = {}, {}, {}, 0
    local n = (GetNumGuildMembers and GetNumGuildMembers()) or 0
    for i = 1, n do
        local name, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
        name = Compat.Safe(name)
        if name then
            local base = name:gsub("%-.*$", "")
            members[base:lower()] = true
            byLower[base:lower()] = base
            if Compat.Safe(isOnline) then online[base:lower()] = true end
            count = count + 1
        end
    end
    Guild.members, Guild.byLower, Guild.online, Guild.count = members, byLower, online, count
    Guild.rosterKnown = n > 0
    -- We're always online ourselves: if the roster doesn't say so, its online data can't be
    -- trusted, and "online" falls back to "heard from recently".
    local me = ns.Me()
    Guild.onlineKnown = me ~= nil and online[me:lower()] == true
    if ns.UI then ns.UI.Refresh() end
end

--- True if name is in our guild's roster (loads the roster if we haven't yet).
function Guild.IsMember(name)
    if not Guild.rosterKnown then Guild.Rebuild() end
    local full = ns.Full(name)
    return full ~= nil and Guild.members[full:lower()] == true
end

--- Online according to the roster; nil when we have no roster to ask.
function Guild.IsOnline(name)
    if not Guild.rosterKnown or not Guild.onlineKnown then return nil end
    local full = ns.Full(name)
    return full ~= nil and Guild.online[full:lower()] == true
end

--- True if name may play with us under the current settings.
function Guild.Allowed(name)
    if not ns.db.guildOnly then return true end
    if not (IsInGuild and IsInGuild()) then return false end
    if Guild.count == 0 then Guild.Rebuild() end
    local full = ns.Full(name)
    return full ~= nil and Guild.members[full:lower()] == true
end
