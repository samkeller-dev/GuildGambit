-- Ledger.lua: who owes whom. Games add debts; payments (trade, mail or entered by hand) pay
-- them down. When a balance with someone reaches zero, everything with them is settled.
local ADDON_NAME, ns = ...

local Ledger = {}
ns.Ledger = Ledger

--- entry: { id, game, opponent, net (copper, + = they owe me), verified, practice }
function Ledger.Record(entry)
    entry.time = time()
    entry.kind = entry.kind or "game"
    entry.settled = entry.practice and true or false
    local list = ns.charDB.ledger
    list[#list + 1] = entry
    while #list > (ns.db.maxLedger or 500) do table.remove(list, 1) end
    if not entry.practice then Ledger.SettleIfSquare(entry.opponent) end
    return entry
end

--- Unsettled balance with one opponent (+ = they owe me, - = I owe them).
function Ledger.Balance(opponent)
    opponent = ns.Full(opponent)
    local sum = 0
    for _, e in ipairs(ns.charDB.ledger) do
        if not e.settled and e.opponent == opponent then sum = sum + e.net end
    end
    return sum
end

--- { [opponent] = balance } for every opponent with a non-zero balance.
function Ledger.Balances()
    local out = {}
    for _, e in ipairs(ns.charDB.ledger) do
        if not e.settled then out[e.opponent] = (out[e.opponent] or 0) + e.net end
    end
    for name, bal in pairs(out) do
        if bal == 0 then out[name] = nil end
    end
    return out
end

--- Sorted lists for display: owedToMe = {{name, amount}}, iOwe = {{name, amount}}.
function Ledger.Debts()
    local owedToMe, iOwe = {}, {}
    for name, bal in pairs(Ledger.Balances()) do
        if bal > 0 then owedToMe[#owedToMe + 1] = { name = name, amount = bal }
        else iOwe[#iOwe + 1] = { name = name, amount = -bal } end
    end
    table.sort(owedToMe, function(a, b) return a.amount > b.amount end)
    table.sort(iOwe, function(a, b) return a.amount > b.amount end)
    return owedToMe, iOwe
end

function Ledger.SettleIfSquare(opponent)
    if Ledger.Balance(opponent) ~= 0 then return false end
    for _, e in ipairs(ns.charDB.ledger) do
        if e.opponent == opponent then e.settled = true end
    end
    return true
end

--- Marks everything with opponent as settled regardless of balance (forgive / clear).
function Ledger.Settle(opponent)
    opponent = ns.Full(opponent)
    local sum = Ledger.Balance(opponent)
    for _, e in ipairs(ns.charDB.ledger) do
        if e.opponent == opponent then e.settled = true end
    end
    return sum
end

--- Records a payment. direction: "paid" (I gave gold) or "received".
--- With onlyDebt, only the part that pays down an open debt in that direction is counted
--- (used for automatic trade/mail detection, so unrelated gold isn't mistaken for a payment).
--- Returns the copper actually recorded (0 if nothing).
function Ledger.Payment(opponent, copper, direction, via, onlyDebt)
    opponent = ns.Full(opponent)
    copper = math.floor(tonumber(copper) or 0)
    if not opponent or copper <= 0 then return 0 end
    local amount = copper
    if onlyDebt then
        local bal = Ledger.Balance(opponent)
        if direction == "paid" and bal < 0 then amount = math.min(copper, -bal)
        elseif direction == "received" and bal > 0 then amount = math.min(copper, bal)
        else return 0 end
    end
    local list = ns.charDB.ledger
    list[#list + 1] = {
        kind = "payment", game = "payment", opponent = opponent, via = via or "manual",
        net = direction == "paid" and amount or -amount, verified = true, time = time(), settled = false,
    }
    local cleared = Ledger.SettleIfSquare(opponent)
    ns.Sound("coin")
    local left = Ledger.Balance(opponent)
    ns.Log("%s %s %s %s (%s).%s", direction == "paid" and "Paid" or "Received", ns.Money(amount),
        direction == "paid" and "to" or "from", ns.Short(opponent), via or "manual",
        cleared and " |cff20ff20All square!|r" or (left > 0 and (" They still owe you " .. ns.Money(left) .. ".")
            or (" You still owe " .. ns.Money(-left) .. ".")))
    if ns.Board then ns.Board.Changed() end
    return amount
end

--- Removes my most recent game from the ledger and leaderboard (e.g. a mistyped bet).
--- Only affects this client: the other player runs it too. Returns the removed entry.
function Ledger.VoidLast()
    local list = ns.charDB.ledger
    for i = #list, 1, -1 do
        local e = list[i]
        if (e.kind or "game") == "game" and not e.practice then
            table.remove(list, i)
            for j = #list, 1, -1 do
                local x = list[j]
                if x.id == e.id and (x.kind or "game") == "game" then table.remove(list, j) end
            end
            if ns.Board then ns.Board.Changed() end
            return e
        end
    end
end

function Ledger.Recent(n)
    local list, out = ns.charDB.ledger, {}
    for i = #list, math.max(1, #list - (n or 10) + 1), -1 do out[#out + 1] = list[i] end
    return out
end

---------------------------------------------------------------------------
-- Payments, confirmed by the other player. Gold is never matched up automatically (mail
-- and trades from other things threw the ledger off). "I paid Bob 4g" asks Bob's addon;
-- only when Bob accepts do both ledgers record it (Bob's as "received"). The same goes for
-- "I received" and for clearing everything with a player.
--
-- Gold mailed with "Pay debts" is asked the same way, but that request is kept (across
-- reloads) and asked again whenever the player is seen online, until they answer. Until
-- then the amount counts as on its way, so it isn't paid twice.
---------------------------------------------------------------------------
Ledger.CONFIRM_TIMEOUT = 60
Ledger.REASK = 60       -- seconds between asking again about mailed gold
Ledger.requests = {}    -- id -> { to, copper, kind } (in-session requests)

local KINDS = { paid = "received", received = "paid", settle = "settle" } -- kind -> the other side's view

--- Mailed gold waiting for the recipient to confirm: id -> { to, copper, kind, via, asked }.
function Ledger.Pending()
    ns.charDB.pendingPays = ns.charDB.pendingPays or {}
    return ns.charDB.pendingPays
end

--- Ids of requests we've already confirmed, so a repeated ask isn't recorded twice.
local function Answered()
    ns.charDB.answeredPays = ns.charDB.answeredPays or {}
    return ns.charDB.answeredPays
end

--- Copper mailed to name that they haven't confirmed yet.
function Ledger.InTransit(name)
    local sum = 0
    for _, r in pairs(Ledger.Pending()) do
        if r.kind == "paid" and ns.SameName(r.to, name) then sum = sum + r.copper end
    end
    return sum
end

local function Apply(kind, name, copper, via)
    if kind == "settle" then
        local amount = Ledger.Settle(name)
        ns.Log("Cleared everything with %s (%s). |cff20ff20All square!|r", ns.Short(name), ns.Money(amount, true))
        if ns.Board then ns.Board.Changed() end
    else
        Ledger.Payment(name, copper, kind, via or "confirmed", false)
    end
end

--- What the asker is claiming, from the asker's side.
local function MineText(kind, name, copper, via)
    if kind == "paid" then
        return ("you %s %s %s"):format(via == "mail" and "mailed" or "paid", ns.Short(name), ns.Money(copper))
    end
    if kind == "received" then return ("%s paid you %s"):format(ns.Short(name), ns.Money(copper)) end
    return ("you and %s are all square"):format(ns.Short(name))
end

local function Ask(id, r)
    r.asked = time()
    ns.Comm.Send("PAY_REQ", { id = id, k = r.kind, c = r.copper, v = r.via }, r.to)
end

--- Asks name's addon to confirm a payment (kind "paid" / "received") or clearing all debts
--- ("settle"). Nothing is recorded until they accept. via "mail": gold we just mailed - the
--- request is kept until they answer, however long that takes.
function Ledger.Request(kind, name, copper, via)
    name = ns.Full(name)
    if not KINDS[kind] or not name then return false end
    if ns.IsMe(name) then ns.Print("That's you.") return false end
    copper = math.floor(tonumber(copper) or 0)
    if kind ~= "settle" and copper <= 0 then return false end
    local id = ns.NewId()
    if via == "mail" then
        local r = { to = name, copper = copper, kind = kind, via = via }
        Ledger.Pending()[id] = r
        Ask(id, r)
        ns.Log("Mailed %s %s. It counts once they confirm - they'll be asked whenever they're online.",
            ns.Short(name), ns.Money(copper))
        return true
    end
    if ns.House.CheckOpponent(name) then return false end -- their addon can't confirm (shown in chat)
    Ledger.requests[id] = { to = name, copper = copper, kind = kind }
    ns.Comm.Send("PAY_REQ", { id = id, k = kind, c = copper }, name)
    ns.Log("Asked %s to confirm that %s. Nothing is recorded until they accept.", ns.Short(name), MineText(kind, name, copper))
    C_Timer.After(Ledger.CONFIRM_TIMEOUT, function()
        if Ledger.requests[id] then
            Ledger.requests[id] = nil
            ns.Log("%s didn't confirm that %s - nothing recorded. They need to be online with GuildGambit.",
                ns.Short(name), MineText(kind, name, copper))
        end
    end)
    return true
end

--- We heard from name: ask again about any mailed gold they haven't confirmed.
function Ledger.Reask(name)
    local now = time()
    for id, r in pairs(Ledger.Pending()) do
        if ns.SameName(r.to, name) and now - (r.asked or 0) >= Ledger.REASK then Ask(id, r) end
    end
end

ns.Comm.On("PAY_REQ", function(f, sender)
    local kind, copper = f.k, math.floor(tonumber(f.c) or 0)
    if not f.id or not KINDS[kind] or (kind ~= "settle" and copper <= 0) then return end
    local function no(reason) ns.Comm.Send("PAY_NO", { id = f.id, r = reason }, sender) end
    if Answered()[f.id] then return ns.Comm.Send("PAY_OK", { id = f.id }, sender) end -- our "yes" got lost
    if not ns.Guild.Allowed(sender) then return no("not in my guild") end
    local who = ns.Short(sender)
    local mail = f.v == "mail"
    local text
    if kind == "paid" and mail then
        text = ("%s mailed you %s to pay what they owe. Confirm once it's in your mailbox?"):format(who, ns.Money(copper))
    elseif kind == "paid" then
        text = ("%s says they paid you %s. Did you get it?"):format(who, ns.Money(copper))
    elseif kind == "received" then
        text = ("%s says you paid them %s. Is that right?"):format(who, ns.Money(copper))
    else
        local bal = Ledger.Balance(sender)
        local now = bal > 0 and ("they owe you " .. ns.Money(bal)) or bal < 0 and ("you owe them " .. ns.Money(-bal))
            or "you're all square"
        text = ("%s wants to clear everything between you (%s). Agree?"):format(who, now)
    end
    ns.UI.ShowInvite(text, function()
        if Answered()[f.id] then return end
        Answered()[f.id] = time()
        Apply(KINDS[kind], sender, copper, mail and "mail" or nil)
        ns.Comm.Send("PAY_OK", { id = f.id }, sender)
    end, function()
        no("declined")
    end, mail and function() end or nil) -- mailed gold: no answer isn't a "no", they'll be asked again
end)

ns.Comm.On("PAY_OK", function(f, sender)
    local r = Ledger.requests[f.id] or Ledger.Pending()[f.id]
    if not r or not ns.SameName(r.to, sender) then return end
    Ledger.requests[f.id], Ledger.Pending()[f.id] = nil, nil
    Apply(r.kind, r.to, r.copper, r.via)
end)

ns.Comm.On("PAY_NO", function(f, sender)
    local r = Ledger.requests[f.id] or Ledger.Pending()[f.id]
    if not r or not ns.SameName(r.to, sender) then return end
    Ledger.requests[f.id], Ledger.Pending()[f.id] = nil, nil
    ns.Log("%s didn't confirm that %s (%s) - nothing recorded.%s", ns.Short(sender), MineText(r.kind, r.to, r.copper, r.via),
        f.r or "no reason", r.via == "mail" and " Check with them that the mail arrived." or "")
    if ns.UI then ns.UI.Refresh() end
end)

---------------------------------------------------------------------------
-- Pay debts by mail. With a mailbox open, one click mails every player you owe what you
-- still owe them (minus anything already on its way), one mail after another: each is sent
-- once the server has confirmed the last. If the game won't let the next one go without
-- another click, the button picks up where it left off.
---------------------------------------------------------------------------
local Mail = {}
ns.MailPay = Mail
Mail.open = false
Mail.STEP_TIMEOUT = 8
Mail.NEXT_DELAY = 0.5
Mail.SUBJECT = "GuildGambit: paying what I owe"

--- { { name, amount } } still to pay, biggest first.
function Mail.Owed()
    local _, iOwe = Ledger.Debts()
    local out = {}
    for _, d in ipairs(iOwe) do
        local left = d.amount - Ledger.InTransit(d.name)
        if left > 0 then out[#out + 1] = { name = d.name, amount = left } end
    end
    return out
end

function Mail.Busy() return Mail.sending ~= nil end

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
end

local function Stop(why)
    Mail.sending, Mail.queue = nil, nil
    if why then ns.Print(why) end
    if ns.UI then ns.UI.Refresh() end
end

function Mail.SendNext()
    if not Mail.open then return Stop() end
    local d = Mail.queue and table.remove(Mail.queue, 1)
    if not d then
        Stop()
        ns.Log("Done - everyone you owed has been mailed.")
        return
    end
    local postage = tonumber(Call(GetSendMailPrice)) or 30
    local money = tonumber(Call(GetMoney)) or 0
    if money < d.amount + postage then
        return Stop(("Not enough gold to mail %s %s (plus %s postage) - stopped."):format(
            ns.Short(d.name), ns.Money(d.amount), ns.Money(postage)))
    end
    Call(ClearSendMail)
    if Call(SetSendMailMoney, d.amount) == false then
        return Stop(("Couldn't put %s on the mail to %s - stopped."):format(ns.Money(d.amount), ns.Short(d.name)))
    end
    local token = { to = d.name, amount = d.amount }
    Mail.sending = token
    if ns.UI then ns.UI.Refresh() end
    local ok, err = pcall(SendMail, d.name, Mail.SUBJECT,
        ("Paying the %s I owe you on GuildGambit. Confirm it in the popup when it arrives."):format(ns.Money(d.amount)))
    if not ok then return Stop("Couldn't send the mail: " .. tostring(err)) end
    C_Timer.After(Mail.STEP_TIMEOUT, function()
        if Mail.sending == token then
            Mail.sending = nil
            if Mail.queue then table.insert(Mail.queue, 1, d) end
            ns.Print("The game didn't send the mail to %s - click |cffffff00Pay debts|r again to carry on.", ns.Short(d.name))
            if ns.UI then ns.UI.Refresh() end
        end
    end)
end

--- The Pay debts button.
function Mail.PayAll()
    if not Mail.open then ns.Print("Open a mailbox first.") return false end
    if Mail.sending then return false end
    local queue = Mail.Owed()
    if #queue == 0 then ns.Print("You don't owe anyone anything.") return false end
    Mail.queue = queue
    Mail.SendNext()
    return true
end

function Mail.MAIL_SHOW() Mail.open = true if ns.UI then ns.UI.Refresh() end end
function Mail.MAIL_CLOSED()
    Mail.open = false
    Mail.sending, Mail.queue = nil, nil
    if ns.UI then ns.UI.Refresh() end
end
function Mail.MAIL_SEND_SUCCESS()
    local s = Mail.sending
    if not s then return end
    Mail.sending = nil
    Ledger.Request("paid", s.to, s.amount, "mail")
    C_Timer.After(Mail.NEXT_DELAY, Mail.SendNext)
end
function Mail.MAIL_FAILED()
    local s = Mail.sending
    if s then Stop(("The mail to %s failed - nothing was sent or recorded."):format(ns.Short(s.to))) end
end
