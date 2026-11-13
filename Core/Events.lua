-- Events.lua: event dispatch. Handlers are functions on ns.events keyed by event name;
-- every one is registered with pcall so a missing event can't abort loading.
local ADDON_NAME, ns = ...
local Compat = ns.Compat

local events = {}
ns.events = events

local driver = CreateFrame("Frame")
ns.eventFrame = driver
driver:SetScript("OnEvent", function(_, event, ...)
    local handler = events[event] or ns.Payments[event]
    if handler then
        local ok, err = pcall(handler, ...)
        if not ok then ns.Print("|cffff4040error in %s: %s|r", event, tostring(err)) end
    end
end)

function events.ADDON_LOADED(name)
    if name ~= ADDON_NAME then return end
    driver:UnregisterEvent("ADDON_LOADED")
    ns.InitDB()
end

function events.PLAYER_LOGIN()
    ns.Comm.RegisterPrefix()
    ns.Guild.Request()
    -- no automatic trade/mail detection: other gold kept throwing the ledger off.
    -- Payments are recorded by hand and confirmed by the other player (Ledger.Request).
    if ns.MinimapButton then
        local ok, err = pcall(ns.MinimapButton.Create)
        if not ok then ns.Print("|cffff4040minimap button failed: %s|r - use /gg instead.", tostring(err)) end
    end
    ns.UI.Restore()
    if not Compat.IS_FOREVER then
        ns.Print("built for WoW: Forever (interface 16001); this client reports %d.", Compat.interface)
    end
    -- say hello once the loading screen is gone, so houses can answer
    C_Timer.After(5, ns.House.SayHello)
end

function events.CHAT_MSG_ADDON(prefix, text, channel, sender)
    ns.Comm.OnAddonMessage(prefix, text, channel, sender)
end

function events.CHAT_MSG_SYSTEM(msg)
    ns.Rolls.OnSystemMessage(msg)
end

function events.GUILD_ROSTER_UPDATE()
    ns.Guild.Rebuild()
end

-- the mailbox, for the Ledger tab's Pay debts button
for _, e in ipairs({ "MAIL_SHOW", "MAIL_CLOSED", "MAIL_SEND_SUCCESS", "MAIL_FAILED" }) do
    events[e] = function(...) return ns.MailPay[e](...) end
end

for event in pairs(events) do
    Compat.TryRegisterEvent(driver, event)
end
