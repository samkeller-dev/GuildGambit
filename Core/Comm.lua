-- Comm.lua: addon messages between GuildGambit clients.
-- Wire format: "TYPE|key=value|key=value", values %XX-escaped. Whispers for game traffic,
-- GUILD for presence and house announcements.
local ADDON_NAME, ns = ...
local Compat = ns.Compat

local Comm = {}
ns.Comm = Comm

Comm.PREFIX = "GGAMBIT"
Comm.handlers = {}

local function escape(v)
    return (tostring(v):gsub("[%%|=]", function(c) return ("%%%02X"):format(c:byte()) end))
end

local function unescape(v)
    return (v:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

function Comm.Encode(msgType, fields)
    local parts = { msgType }
    local keys = {}
    for k in pairs(fields or {}) do keys[#keys + 1] = k end
    table.sort(keys) -- stable output, easier to debug
    for _, k in ipairs(keys) do
        parts[#parts + 1] = k .. "=" .. escape(fields[k])
    end
    return table.concat(parts, "|")
end

function Comm.Decode(text)
    local msgType, rest = text:match("^([%w_]+)(.*)$")
    if not msgType then return nil end
    local fields = {}
    for k, v in rest:gmatch("|([%w_]+)=([^|]*)") do
        fields[k] = unescape(v)
    end
    return msgType, fields
end

function Comm.RegisterPrefix()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, Comm.PREFIX)
    end
end

--- Sends to one player (whisper) or, with target nil, to the guild.
function Comm.Send(msgType, fields, target)
    if target and ns.IsMe(target) then return true end -- practice games talk to nobody
    local text = Comm.Encode(msgType, fields)
    if #text > 255 then
        ns.Debug("message too long, dropped: %s", msgType)
        return false
    end
    local channel = target and "WHISPER" or "GUILD"
    if channel == "GUILD" and IsInGuild and not IsInGuild() then return false end
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return false end
    local ok, err = pcall(C_ChatInfo.SendAddonMessage, Comm.PREFIX, text, channel, target)
    if not ok then ns.Debug("send failed (%s): %s", msgType, tostring(err)) end
    ns.Debug("-> %s %s", target and ns.Short(target) or "GUILD", text)
    return ok
end

function Comm.On(msgType, fn)
    Comm.handlers[msgType] = fn
end

--- CHAT_MSG_ADDON handler.
function Comm.OnAddonMessage(prefix, text, channel, sender)
    if prefix ~= Comm.PREFIX then return end
    text, sender = Compat.Safe(text), Compat.Safe(sender)
    if not text or not sender then return end
    local msgType, fields = Comm.Decode(text)
    if not msgType then return end
    -- our own HELLO echoing back on the guild channel tells us how the server spells us
    if msgType == "HELLO" and fields.n == ns.nonce then
        ns.AddMyName(sender, true)
        return
    end
    sender = ns.Full(sender)
    if ns.IsMe(sender) then return end -- our own guild broadcasts echo back
    if ns.House and ns.House.SeePeer then ns.House.SeePeer(sender) end -- they have the addon
    local handler = Comm.handlers[msgType]
    ns.Debug("<- %s %s", ns.Short(sender), text)
    if handler then
        local ok, err = pcall(handler, fields, sender, channel)
        if not ok then ns.Print("|cffff4040error handling %s: %s|r", msgType, tostring(err)) end
    end
end
