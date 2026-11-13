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

-- Spectator traffic goes on its own prefix, so it has its own share of WoW's addon-message
-- allowance and can never crowd out the games' own messages.
Comm.LIVE_PREFIX = "GGLIVE"
local LIVE_TYPES = { LIVE = true, LIVE_END = true, SPEC = true, STATE = true, RUNS = true, RUN = true, RUNREQ = true }

function Comm.RegisterPrefix()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, Comm.PREFIX)
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, Comm.LIVE_PREFIX)
    end
end

---------------------------------------------------------------------------
-- Sending. WoW only lets an addon send a few messages a second; past that, the send call
-- returns "throttled" (3, or 8 for a busy channel) instead of sending - without an error. So
-- every message goes through a queue: sent at once if WoW takes it, otherwise retried a moment
-- later. Game messages always go first; spectator messages can be merged (opts.key: a newer
-- message with the same key replaces one still waiting, e.g. the latest table state).
---------------------------------------------------------------------------
local THROTTLED = { [3] = true, [8] = true }
Comm.RETRY = 0.25
Comm.queue = {}  -- game messages, oldest first
Comm.live = {}   -- spectator messages, oldest first
local pumping = false

local function TrySend(m)
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return "error" end
    local ok, res = pcall(C_ChatInfo.SendAddonMessage, m.prefix, m.text, m.channel, m.target)
    if not ok then
        ns.Debug("send failed: %s", tostring(res))
        return "error"
    end
    if type(res) == "number" and THROTTLED[res] then return "throttled" end
    if Enum and Enum.SendAddonMessageResult and res == Enum.SendAddonMessageResult.AddonMessageThrottle then
        return "throttled"
    end
    return "sent"
end

--- Sends what's waiting, game messages first, until WoW says to wait.
local function Pump()
    for _, q in ipairs({ Comm.queue, Comm.live }) do
        while q[1] do
            local result = TrySend(q[1])
            if result == "throttled" then return false end
            table.remove(q, 1)
        end
    end
    return true
end

local function StartPump()
    if pumping then return end
    pumping = true
    local function tick()
        if Pump() then pumping = false return end
        C_Timer.After(Comm.RETRY, tick)
    end
    C_Timer.After(Comm.RETRY, tick)
end

--- Sends to one player (whisper) or, with target nil, to the guild.
--- opts.key (spectator messages): replaces a waiting message with the same key.
function Comm.Send(msgType, fields, target, opts)
    if target and ns.IsMe(target) then return true end -- practice games talk to nobody
    local text = Comm.Encode(msgType, fields)
    if #text > 255 then
        ns.Debug("message too long, dropped: %s", msgType)
        return false
    end
    local channel = target and "WHISPER" or "GUILD"
    if channel == "GUILD" and IsInGuild and not IsInGuild() then return false end
    local live = LIVE_TYPES[msgType] or false
    local m = { prefix = live and Comm.LIVE_PREFIX or Comm.PREFIX, text = text, channel = channel, target = target,
        key = opts and opts.key }
    local q = live and Comm.live or Comm.queue
    ns.Debug("-> %s %s", target and ns.Short(target) or "GUILD", text)
    if m.key then
        for i, w in ipairs(q) do
            if w.key == m.key then q[i] = m return true end -- the newer one replaces it
        end
    end
    -- nothing ahead of it: try right away
    if not Comm.queue[1] and (not live or not Comm.live[1]) then
        local result = TrySend(m)
        if result ~= "throttled" then return result == "sent" end
    end
    q[#q + 1] = m
    StartPump()
    return true
end

--- How many messages are waiting (for /gg info and tests).
function Comm.Waiting() return #Comm.queue + #Comm.live end

function Comm.On(msgType, fn)
    Comm.handlers[msgType] = fn
end

--- CHAT_MSG_ADDON handler.
function Comm.OnAddonMessage(prefix, text, channel, sender)
    if prefix ~= Comm.PREFIX and prefix ~= Comm.LIVE_PREFIX then return end
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
