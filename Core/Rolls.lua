-- Rolls.lua: server /roll results as the only source of randomness.
--
-- Games register watchers: "the next roll by PLAYER with range MIN-MAX is step KEY".
-- A watcher is satisfied by the first matching system roll message this client sees
-- (verified), or, if this client can't see the roller's rolls (not grouped/nearby), by the
-- roller's relayed ROLL message after a short wait (unverified).
local ADDON_NAME, ns = ...
local Compat = ns.Compat

local Rolls = {}
ns.Rolls = Rolls

Rolls.RELAY_WAIT = 1.5 -- seconds to wait for the real system message before trusting a relay
Rolls.watchers = {}    -- ordered list
Rolls.byKey = {}

---------------------------------------------------------------------------
-- Parsing "Name rolls 42 (1-100)" in any locale, from the client's own format string.
---------------------------------------------------------------------------
function Rolls.BuildPattern(fmt)
    -- escape Lua pattern magic characters except % (format specifiers)
    local p = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%%d?%$?s", "(.+)")
    p = p:gsub("%%%d?%$?d", "(%%d+)")
    return "^" .. p .. "$"
end

local pattern
local function Pattern()
    if not pattern then
        local fmt = Compat.Safe(_G.RANDOM_ROLL_RESULT) or "%s rolls %d (%d-%d)"
        pattern = Rolls.BuildPattern(fmt)
    end
    return pattern
end

--- Returns name, roll, min, max (numbers) or nil.
function Rolls.Parse(msg)
    if type(msg) ~= "string" then return nil end
    local name, roll, lo, hi = msg:match(Pattern())
    if not name then return nil end
    return name, tonumber(roll), tonumber(lo), tonumber(hi)
end

---------------------------------------------------------------------------
-- Watchers
---------------------------------------------------------------------------
--- opts: player, min, max, key (unique per game step), onRoll(value, verified),
---       relayTo (list of names to forward our own roll to)
function Rolls.Watch(opts)
    assert(opts.key and opts.player and opts.min and opts.max and opts.onRoll, "bad watcher")
    if Rolls.byKey[opts.key] then return Rolls.byKey[opts.key] end
    local w = {
        key = opts.key, player = ns.Full(opts.player), min = opts.min, max = opts.max,
        onRoll = opts.onRoll, relayTo = opts.relayTo,
    }
    Rolls.watchers[#Rolls.watchers + 1] = w
    Rolls.byKey[w.key] = w
    -- a relay may have arrived before we started watching
    if Rolls.pendingRelays and Rolls.pendingRelays[w.key] then
        local r = Rolls.pendingRelays[w.key]
        Rolls.pendingRelays[w.key] = nil
        Rolls.OnRelay(r, r.sender)
    end
    return w
end

local function remove(w)
    for i, x in ipairs(Rolls.watchers) do
        if x == w then table.remove(Rolls.watchers, i) break end
    end
    if Rolls.byKey[w.key] == w then Rolls.byKey[w.key] = nil end
    w.done = true
end

function Rolls.Unwatch(key)
    local w = Rolls.byKey[key]
    if w then remove(w) end
end

--- Removes every watcher whose key starts with prefix (e.g. a whole game).
function Rolls.UnwatchPrefix(prefix)
    for i = #Rolls.watchers, 1, -1 do
        local w = Rolls.watchers[i]
        if w.key:sub(1, #prefix) == prefix then remove(w) end
    end
end

function Rolls.IsWatching(key)
    return Rolls.byKey[key] ~= nil
end

local function satisfy(w, value, verified)
    remove(w)
    if verified and w.relayTo and ns.IsMe(w.player) then
        for _, target in ipairs(w.relayTo) do
            ns.Comm.Send("ROLL", { k = w.key, v = value, a = w.min, b = w.max }, target)
            -- outside our group they can't see our /roll: tell them in a normal whisper too
            if ns.db.whisperRolls and not ns.InGroupWith(target) then
                ns.Whisper(target, ("[GuildGambit] I rolled %d (%d-%d)"):format(value, w.min, w.max))
            end
        end
    end
    w.onRoll(value, verified)
end

--- Feed a system chat message (CHAT_MSG_SYSTEM).
function Rolls.OnSystemMessage(msg)
    msg = Compat.Safe(msg)
    local name, roll, lo, hi = Rolls.Parse(msg)
    if not name then return false end
    local who = ns.Full(name)
    ns.Debug("roll seen: %s %d (%d-%d)", ns.Short(who), roll, lo, hi)
    -- The first roll line in the range we just asked the server for, from someone we're not
    -- playing against, is ours: learn how the server spells our name.
    local asked = Rolls.lastAsk
    if asked and asked.lo == lo and asked.hi == hi and GetTime() - asked.t < Rolls.SELF_WINDOW then
        Rolls.lastAsk = nil
        if not ns.IsMe(who) and not ns.Games.IsParticipant(who) then
            ns.AddMyName(who, true)
        end
    end
    for _, w in ipairs(Rolls.watchers) do
        local same = ns.SameName(w.player, who) or (ns.IsMe(w.player) and ns.IsMe(who))
        if same and w.min == lo and w.max == hi then
            satisfy(w, roll, true)
            return true
        end
    end
    -- Nothing claimed it. Games get a last chance (e.g. a Hit that should never be lost).
    for _, handler in ipairs(Rolls.unclaimedHandlers) do
        local ok, took = pcall(handler, who, roll, lo, hi)
        if ok and took then
            ns.Debug("unclaimed roll %d (%d-%d) by %s taken by a fallback", roll, lo, hi, ns.Short(who))
            return true
        end
    end
    if ns.IsMe(who) then ns.Debug("our roll %d (%d-%d) wasn't expected by any game", roll, lo, hi) end
    return false
end

Rolls.unclaimedHandlers = {}
--- handler(who, roll, lo, hi) -> true if it used the roll.
function Rolls.OnUnclaimed(handler)
    Rolls.unclaimedHandlers[#Rolls.unclaimedHandlers + 1] = handler
end

--- Feed a relayed ROLL message from the roller's client.
function Rolls.OnRelay(fields, sender)
    local key, value = fields.k, tonumber(fields.v)
    local lo, hi = tonumber(fields.a), tonumber(fields.b)
    if not key or not value then return end
    local w = Rolls.byKey[key]
    if not w then
        -- we may not have reached this step yet; keep it briefly
        Rolls.pendingRelays = Rolls.pendingRelays or {}
        fields.sender = sender
        Rolls.pendingRelays[key] = fields
        return
    end
    if not (ns.SameName(w.player, sender) or (ns.IsMe(w.player) and ns.IsMe(sender)))
        or w.min ~= lo or w.max ~= hi then return end
    if value < lo or value > hi then return end
    C_Timer.After(Rolls.RELAY_WAIT, function()
        if not w.done then
            ns.Debug("using relayed roll for %s (not seen in chat)", key)
            satisfy(w, value, false)
        end
    end)
end

---------------------------------------------------------------------------
-- Rolling
---------------------------------------------------------------------------
--- Asks the server for a roll. Falls back to telling the player to type it.
Rolls.SELF_WINDOW = 5 -- seconds: a roll line this soon after we asked is ours

function Rolls.Roll(lo, hi)
    Rolls.lastAsk = { lo = lo, hi = hi, t = GetTime() }
    if RandomRoll then
        local ok = pcall(RandomRoll, lo, hi)
        if ok then return true end
    end
    ns.Print("Type |cffffff00/roll %d-%d|r to roll.", lo, hi)
    return false
end

function Rolls.Reset()
    Rolls.watchers, Rolls.byKey, Rolls.pendingRelays = {}, {}, nil
end
