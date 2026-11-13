-- NOT USED (Events.lua no longer calls Setup): payments are recorded by hand and confirmed.
-- Payments.lua: notices gold moving between you and someone you have an open debt with,
-- by trade or by mail, and pays the debt down. Nothing here moves gold - you still trade or
-- mail it yourself. If detection ever misses, /gg paid and /gg received record it by hand.
--
-- Only gold that pays down an open debt in the right direction is counted, so selling a
-- guildie an item isn't mistaken for a gambling payment.
local ADDON_NAME, ns = ...
local Compat = ns.Compat

local Payments = {}
ns.Payments = Payments

local trade      -- { partner, give, get, startMoney, done }
local pendingMail -- { to, money }
local inbox = {} -- index -> { sender, money } snapshot, refreshed on MAIL_INBOX_UPDATE

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, e, f = pcall(fn, ...)
    if ok then return a, b, c, d, e, f end
end

---------------------------------------------------------------------------
-- Trade
---------------------------------------------------------------------------
local function TradeMoney()
    if not trade then return end
    trade.give = tonumber(Compat.Safe(Call(GetPlayerTradeMoney))) or trade.give or 0
    trade.get = tonumber(Compat.Safe(Call(GetTargetTradeMoney))) or trade.get or 0
end

local function TradeDone(how)
    if not trade or trade.done or not trade.partner then return end
    trade.done = true
    ns.Debug("trade with %s complete (%s): gave %s, got %s", ns.Short(trade.partner), how,
        ns.Money(trade.give or 0), ns.Money(trade.get or 0))
    if (trade.give or 0) > 0 then ns.Ledger.Payment(trade.partner, trade.give, "paid", "trade", true) end
    if (trade.get or 0) > 0 then ns.Ledger.Payment(trade.partner, trade.get, "received", "trade", true) end
end

function Payments.TRADE_SHOW()
    local partner = Compat.Safe(Call(UnitName, "NPC"))
    trade = { partner = partner and ns.Full(partner), give = 0, get = 0, startMoney = Call(GetMoney) }
end

Payments.TRADE_MONEY_CHANGED = TradeMoney
Payments.PLAYER_TRADE_MONEY = TradeMoney
Payments.TRADE_ACCEPT_UPDATE = TradeMoney

function Payments.UI_INFO_MESSAGE(_, msg)
    msg = Compat.Safe(msg)
    if msg and _G.ERR_TRADE_COMPLETE and msg == _G.ERR_TRADE_COMPLETE then TradeDone("message") end
end

function Payments.TRADE_CLOSED()
    if not trade then return end
    local t = trade
    -- the completion message and the money update can arrive just after the window closes
    C_Timer.After(2, function()
        if trade == t then trade = nil end
    end)
end

-- Fallback when ERR_TRADE_COMPLETE isn't seen: our gold changed by exactly get - give.
function Payments.PLAYER_MONEY()
    if not trade or trade.done or not trade.startMoney then return end
    local now = Call(GetMoney)
    if now and (trade.give > 0 or trade.get > 0) and now - trade.startMoney == trade.get - trade.give then
        TradeDone("money")
    end
end

---------------------------------------------------------------------------
-- Mail
---------------------------------------------------------------------------
function Payments.OnSendMail(recipient)
    local money = tonumber(Compat.Safe(Call(GetSendMailMoney))) or 0
    recipient = Compat.Safe(recipient)
    pendingMail = (recipient and money > 0) and { to = ns.Full(recipient), money = money } or nil
end

function Payments.MAIL_SEND_SUCCESS()
    if pendingMail then
        ns.Ledger.Payment(pendingMail.to, pendingMail.money, "paid", "mail", true)
        pendingMail = nil
    end
end

function Payments.MAIL_FAILED() pendingMail = nil end

function Payments.MAIL_INBOX_UPDATE()
    inbox = {}
    local n = Call(GetInboxNumItems) or 0
    for i = 1, n do
        local _, _, sender, _, money = Call(GetInboxHeaderInfo, i)
        sender, money = Compat.Safe(sender), Compat.Safe(money)
        if sender and money and money > 0 then inbox[i] = { sender = ns.Full(sender), money = money } end
    end
end

function Payments.OnTakeMoney(index)
    local m = inbox[index]
    if not m then return end
    inbox[index] = nil
    ns.Ledger.Payment(m.sender, m.money, "received", "mail", true)
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
Payments.EVENTS = {
    "TRADE_SHOW", "TRADE_MONEY_CHANGED", "PLAYER_TRADE_MONEY", "TRADE_ACCEPT_UPDATE", "TRADE_CLOSED",
    "UI_INFO_MESSAGE", "PLAYER_MONEY", "MAIL_SEND_SUCCESS", "MAIL_FAILED", "MAIL_INBOX_UPDATE",
}

function Payments.Setup(frame)
    for _, event in ipairs(Payments.EVENTS) do Compat.TryRegisterEvent(frame, event) end
    if hooksecurefunc then
        if SendMail then pcall(hooksecurefunc, "SendMail", Payments.OnSendMail) end
        if TakeInboxMoney then pcall(hooksecurefunc, "TakeInboxMoney", Payments.OnTakeMoney) end
        if AutoLootMailItem then pcall(hooksecurefunc, "AutoLootMailItem", Payments.OnTakeMoney) end
    end
end

-- for tests
function Payments._State() return trade, pendingMail, inbox end
