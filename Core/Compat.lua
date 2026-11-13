-- Compat.lua: client detection and secret-value helpers. Loaded first.
local ADDON_NAME, ns = ...

local Compat = {}
ns.Compat = Compat

-- Forever reports interface 16001. Detect by interface range (as Questie/Auctionator do),
-- because WOW_PROJECT_ID has differed between Forever builds.
local _, build, _, interface = GetBuildInfo()
Compat.interface = interface
Compat.build = build
Compat.IS_FOREVER = interface >= 16000 and interface < 17000

local issecretvalue = _G.issecretvalue or function() return false end
Compat.issecretvalue = issecretvalue

--- Returns v, or nil if it is a secret value.
function Compat.Safe(v)
    if v == nil or issecretvalue(v) then return nil end
    return v
end

--- Registers an event without aborting the file if the client doesn't know it.
function Compat.TryRegisterEvent(frame, event)
    local ok = pcall(frame.RegisterEvent, frame, event)
    if not ok and ns.Debug then ns.Debug("event not available: %s", event) end
    return ok
end
