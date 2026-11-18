-- UI/Social.lua: GuildGambit in the game's right-click menus (challenge a guildie straight
-- from their name in chat, their portrait or the guild list), and the debt reminder at login.
local ADDON_NAME, ns = ...
local Compat = ns.Compat

local Social = {}
ns.Social = Social

---------------------------------------------------------------------------
-- Right-click menus
---------------------------------------------------------------------------
-- the menus that open on another player (chat names, portraits, party/raid, guild list)
Social.MENUS = {
    "MENU_UNIT_PLAYER", "MENU_UNIT_FRIEND", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER",
    "MENU_UNIT_GUILD", "MENU_UNIT_COMMUNITIES_GUILD_MEMBER", "MENU_UNIT_TARGET", "MENU_UNIT_FOCUS",
}

--- The player a menu was opened on, or nil.
function Social.MenuName(context)
    if type(context) ~= "table" then return nil end
    local name = Compat.Safe(context.name)
    if not name and context.unit and UnitIsPlayer and UnitIsPlayer(context.unit) then
        name = Compat.Safe((UnitName(context.unit)))
    end
    if type(name) ~= "string" or name == "" then return nil end
    return ns.Full(name)
end

--- True if we can challenge this player from a menu: a guildie with a compatible GuildGambit.
function Social.CanChallenge(name)
    if not name or ns.IsMe(name) then return false end
    if not ns.House.peers[name] then return false end -- no GuildGambit (that we've heard of)
    return ns.Guild.Allowed(name) and ns.House.Status(name) == "ok"
end

--- The challenge entries: { label, fn } for the current Play tab wager.
function Social.Entries(name)
    local bet, start = ns.UI.CurrentBet()
    local copper = ns.GoldToCopper(bet) or 0
    local stake = copper > 0 and ns.Money(copper) or "for fun"
    local function go(fn) return function() ns.UI.SetShown(true) ns.UI.SelectTab("play") fn() end end
    return {
        { ("Deathroll (%s, 1-%s)"):format(stake, start), go(function() ns.Deathroll.Challenge(name, bet, start) end) },
        { ("Coinflip (%s)"):format(stake), go(function() ns.Coinflip.Challenge(name, bet) end) },
        { ("Blackjack (%s)"):format(stake), go(function() ns.Blackjack.Deal(name, bet) end) },
    }
end

local function Build(owner, root, context)
    local name = Social.MenuName(context)
    if not Social.CanChallenge(name) then return end
    root:CreateDivider()
    if root.CreateTitle then root:CreateTitle("GuildGambit") end
    local sub = root:CreateButton("Challenge " .. ns.Short(name))
    local busy = ns.Games.Busy() or ns.House.IsDnd(name)
    for _, e in ipairs(Social.Entries(name)) do
        local b = sub:CreateButton(e[1], e[2])
        if busy and b.SetEnabled then b:SetEnabled(false) end
    end
    sub:CreateDivider()
    sub:CreateButton("Change the wager (Play tab)", function()
        ns.UI.SetShown(true)
        ns.UI.SelectTab("play")
    end)
end

function Social.HookMenus()
    if not (Menu and Menu.ModifyMenu) then return false end
    for _, tag in ipairs(Social.MENUS) do
        pcall(Menu.ModifyMenu, tag, function(owner, root, context)
            local ok, err = pcall(Build, owner, root, context)
            if not ok then ns.Debug("menu: %s", tostring(err)) end
        end)
    end
    return true
end

---------------------------------------------------------------------------
-- Debt reminder: a quiet line in chat at login if anyone owes anyone
---------------------------------------------------------------------------
Social.REMIND_AFTER = 10 -- seconds after login (after the loading-screen chat spam)

local function List(debts)
    local out = {}
    for i, d in ipairs(debts) do
        if i > 5 then out[#out + 1] = ("%d more"):format(#debts - 5) break end
        out[#out + 1] = ("%s %s"):format(ns.Short(d.name), ns.Money(d.amount))
    end
    return table.concat(out, ", ")
end

--- Prints the reminder (returns true if there was anything to remind).
function Social.RemindDebts()
    local owedToMe, iOwe = ns.Ledger.Debts()
    if #iOwe == 0 and #owedToMe == 0 then return false end
    if #iOwe > 0 then
        ns.Print("|cffff8040Reminder:|r you owe %s. Open a mailbox and click |cffffff00Pay debts|r in the Ledger tab.", List(iOwe))
    end
    if #owedToMe > 0 then
        ns.Print("|cff20ff20Reminder:|r %s owe%s you.", List(owedToMe), (#owedToMe == 1) and "s" or "")
    end
    return true
end

function Social.Login()
    pcall(Social.HookMenus)
    if ns.Lottery then pcall(ns.Lottery.HookMail) end
    C_Timer.After(Social.REMIND_AFTER, function()
        if ns.db.debtReminder ~= false then Social.RemindDebts() end
        if ns.Lottery then ns.Lottery.Remind() end -- daily, while a lottery is open
    end)
end
