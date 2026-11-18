-- Options.lua: GuildGambit's page in the game's Options > AddOns list (the same native
-- checkboxes Blizzard and MinimapButtonButton use), and one place that changes a setting so
-- the slash commands and the options page always agree.
local ADDON_NAME, ns = ...

local Options = {}
ns.Options = Options

Options.settings = {} -- key -> the game's setting object (to update the page after /gg commands)

-- Every option: key in its table, label, tooltip, slash command shown in the tooltip.
-- invert: the checkbox is on when the stored value is false. tbl: a nested table in ns.db.
local DEFS = {
    { section = "Challenges" },
    { key = "dnd", name = "Do not disturb", slash = "/gg dnd",
        tip = "Turn down every incoming challenge automatically - deathroll, blackjack, coinflip and group deathroll invites. The challenger is told you're not taking games." },
    { key = "guildOnly", name = "Guild members only", slash = "/gg guildonly",
        tip = "Only accept games from members of your guild." },
    { section = "Chat" },
    { key = "gmute", name = "Mute guild chat messages", slash = "/gg gmute",
        tip = "Don't post your wins in guild chat. (Nothing else GuildGambit sends shows up in guild chat.)" },
    { key = "whisperRolls", name = "Whisper rolls to far-away opponents", slash = "/gg whispers",
        tip = "When your opponent isn't in your group, also whisper them each of your rolls so they can see it in chat." },
    { key = "debtReminder", name = "Debt reminder at login", slash = "/gg remind",
        tip = "When you log in, a line in chat says who you owe and who owes you (only if anyone does)." },
    { section = "Interface" },
    { key = "sound", name = "Sound effects", slash = "/gg sound",
        tip = "Dice, cards, wins and losses." },
    { key = "hide", tbl = "minimap", name = "Hide minimap button", slash = "/gg minimap",
        tip = "Hide the coin-and-dice button on the minimap. /gg still opens the window." },
}
Options.DEFS = DEFS

local function Table(def)
    if def.tbl then
        ns.db[def.tbl] = ns.db[def.tbl] or {}
        return ns.db[def.tbl]
    end
    return ns.db
end

local function Def(key)
    for _, d in ipairs(DEFS) do if d.key == key then return d end end
end

--- What changing an option does besides storing it.
local EFFECTS = {
    dnd = function(on)
        -- tell everyone, so their opponent list shows we're not taking games
        if ns.House then ns.House.SayDnd() end
    end,
    hide = function(hidden)
        if ns.MinimapButton and ns.MinimapButton.SetShown then ns.MinimapButton.SetShown(not hidden) end
    end,
}

local busy = false -- (the page's callback fires when we update it ourselves)

local function Changed(def, value)
    local effect = EFFECTS[def.key]
    if effect then effect(value) end
    if ns.UI and ns.UI.Refresh then ns.UI.Refresh() end
end

function Options.Get(key)
    local def = Def(key)
    return def and Table(def)[key] or false
end

--- Sets an option (nil value: toggle it), runs its side effect and updates the options page.
function Options.Set(key, value)
    local def = Def(key)
    if not def then return end
    if value == nil then value = not Table(def)[key] end
    value = value and true or false
    Table(def)[key] = value
    local setting = Options.settings[key]
    if setting and setting.SetValue and not busy then
        busy = true
        pcall(setting.SetValue, setting, value)
        busy = false
    end
    Changed(def, value)
    return value
end

---------------------------------------------------------------------------
-- The options page
---------------------------------------------------------------------------
Options.category = nil

function Options.Register()
    local S = _G.Settings
    if Options.category or not (S and S.RegisterVerticalLayoutCategory and S.RegisterAddOnSetting
        and S.CreateCheckbox and S.RegisterAddOnCategory) then
        return Options.category
    end
    local category, layout = S.RegisterVerticalLayoutCategory("GuildGambit")
    local header = _G.CreateSettingsListSectionHeaderInitializer
    for _, def in ipairs(DEFS) do
        if def.section then
            if header and layout and layout.AddInitializer then
                pcall(function() layout:AddInitializer(header(def.section)) end)
            end
        else
            local tbl = Table(def)
            if tbl[def.key] == nil then tbl[def.key] = false end
            local ok, setting = pcall(S.RegisterAddOnSetting, category, "GuildGambit_" .. def.key, def.key, tbl,
                "boolean", def.name, tbl[def.key])
            if ok and setting then
                Options.settings[def.key] = setting
                if setting.SetValueChangedCallback then
                    setting:SetValueChangedCallback(function(_, value)
                        if busy then return end
                        Changed(def, value)
                    end)
                end
                S.CreateCheckbox(category, setting, def.tip .. "\n\n|cffffd100" .. def.slash .. "|r")
            end
        end
    end
    -- shortcuts into the addon
    local button = _G.CreateSettingsButtonInitializer
    if button and layout and layout.AddInitializer then
        pcall(function()
            layout:AddInitializer(button("Open GuildGambit", "Open", function() ns.UI.SetShown(true) end,
                "The GuildGambit window (/gg).", false))
            layout:AddInitializer(button("Guild Wealth", "Open", function() ns.WealthUI.SetShown(true) end,
                "Who holds the guild's gold (/gg wealth).", false))
        end)
    end
    S.RegisterAddOnCategory(category)
    Options.category = category
    return category
end

--- Opens the options page (/gg options).
function Options.Open()
    local S = _G.Settings
    local category = Options.Register()
    if category and S and S.OpenToCategory then
        local id = category.GetID and category:GetID() or category.ID
        if pcall(S.OpenToCategory, id) then return true end
    end
    ns.Print("Couldn't open the options page - use the /gg commands instead (/gg help).")
    return false
end
