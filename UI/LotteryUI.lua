-- UI/LotteryUI.lua: the guild lottery's page in the Live tab (pinned above the games), the
-- draw animation, and the officers' "New lottery" form. All times are Brisbane time.
local ADDON_NAME, ns = ...
local Art = ns.Art

local LUI = {}
ns.LotteryUI = LUI

local ROWS, ROW_H = 12, 18
local PICK_ROWS, PICK_ROW_H = 10, 18
local ARROW = " |TInterface\\Buttons\\Arrow-Down-Up:14:14|t"
local RIGHT = 272 -- x of the right-hand column
LUI.SPIN = 5      -- seconds the draw's number spins before it stops on the winning ticket
LUI.HOLD = 8      -- seconds the result stays up afterwards

local view, form

---------------------------------------------------------------------------
-- Small builders (the same look as the main window's)
---------------------------------------------------------------------------
local function Label(parent, text, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    fs:SetText(text or "")
    fs:SetJustifyH("LEFT")
    return fs
end

local function Button(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 90, 22)
    b:SetText(text)
    b:SetScript("OnClick", function(...)
        if ns.UI.ReleaseFocus then ns.UI.ReleaseFocus() end
        return onClick(...)
    end)
    return b
end

local function Input(parent, width, default, maxLetters)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(width, 20)
    e:SetAutoFocus(false)
    e:SetNumeric(true)
    if maxLetters then e:SetMaxLetters(maxLetters) end
    e:SetText(default or "")
    e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return e
end

local function Num(box) local v = tonumber(box:GetText()) return v and math.floor(v) or 0 end

--- "in 2d 4h", "in 35m", "now"
local function Until(t)
    local s = t - ns.Lottery.Now()
    if s <= 0 then return "now" end
    if s >= 86400 then return ("in %dd %dh"):format(math.floor(s / 86400), math.floor(s % 86400 / 3600)) end
    if s >= 3600 then return ("in %dh %dm"):format(math.floor(s / 3600), math.floor(s % 3600 / 60)) end
    return ("in %dm"):format(math.max(1, math.floor(s / 60)))
end

---------------------------------------------------------------------------
-- The Live list's pinned row
---------------------------------------------------------------------------
--- The lottery row is always there (in a guild), so officers can open the first one.
function LUI.HasLottery()
    return IsInGuild == nil or IsInGuild() == true
end

function LUI.RowText()
    local Lot = ns.Lottery
    local L = Lot.Current()
    if not L then
        local prev = Lot.Previous()
        if prev then
            return ("|cffffd100Guild Lottery|r - last won by %s (%s)"):format(ns.Short(prev.winner), ns.Money(prev.pot or 0))
        end
        return "|cffffd100Guild Lottery|r - " .. (Lot.IsOfficer() and "none running - open one here" or "none running right now")
    end
    local n, pot = Lot.Totals(L)
    if L.state == "open" and not L.announced then
        return "|cffffd100Guild Lottery|r - " .. (ns.IsMe(L.by) and "created - |cffff8040not announced yet|r" or "coming soon")
    end
    if L.state == "open" then
        local when = Lot.Now() >= L.drawAt and "|cffff8040draw due|r"
            or (Lot.SalesOpen(L) and ("draw " .. Until(L.drawAt)) or ("sales closed, draw " .. Until(L.drawAt)))
        return ("|cffffd100Guild Lottery|r - %s pot, %d ticket%s - %s"):format(ns.Money(pot), n, n == 1 and "" or "s", when)
    end
    if L.winner == "" then return "|cffffd100Guild Lottery|r - drawn, no tickets sold" end
    return ("|cffffd100Guild Lottery|r - drawn: %s won %s"):format(ns.Short(L.winner), ns.Money(L.potGold or 0))
end

---------------------------------------------------------------------------
-- The draw animation: the deathroll's big number, spinning, slowing, stopping on the ticket
---------------------------------------------------------------------------
local function BuildDraw(v)
    local d = CreateFrame("Frame", nil, v, "BackdropTemplate")
    v.drawAnim = d
    d:SetAllPoints()
    d:SetFrameLevel(v:GetFrameLevel() + 10)
    d:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    d:SetBackdropColor(0, 0, 0, 0.82)
    d:EnableMouse(true)
    d:Hide()
    d.cap = Label(d, "Drawing the lottery...", "GameFontNormalLarge")
    d.cap:SetPoint("TOP", 0, -40)
    d.cap:SetJustifyH("CENTER")
    d.holder = CreateFrame("Frame", nil, d)
    d.holder:SetSize(300, 110)
    d.holder:SetPoint("CENTER", 0, 20)
    d.number = d.holder:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    pcall(d.number.SetFont, d.number, "Fonts\\FRIZQT__.TTF", 88, "THICKOUTLINE")
    d.number:SetPoint("CENTER")
    d.number:SetJustifyH("CENTER")
    d.outof = Label(d, "", "GameFontHighlight")
    d.outof:SetPoint("TOP", d.holder, "BOTTOM", 0, -2)
    d.outof:SetJustifyH("CENTER")
    d.result = Label(d, "", "GameFontNormalLarge")
    d.result:SetPoint("TOP", d.outof, "BOTTOM", 0, -16)
    d.result:SetJustifyH("CENTER")
    d.close = Button(d, "Close", 80, function() d:Hide() end)
    d.close:SetPoint("BOTTOM", 0, 14)
    -- the landing: a pop of the number, like a deathroll roll
    d.pop = d.holder:CreateAnimationGroup()
    local grow = d.pop:CreateAnimation("Scale")
    grow:SetScale(1.35, 1.35) grow:SetDuration(0.12) grow:SetOrder(1)
    local shrink = d.pop:CreateAnimation("Scale")
    shrink:SetScale(1 / 1.35, 1 / 1.35) shrink:SetDuration(0.2) shrink:SetOrder(2)
    d:SetScript("OnUpdate", function(self, elapsed)
        local a = self.anim
        if not a then return end
        a.t = a.t + elapsed
        if a.t < LUI.SPIN then
            -- quick at first, slower and slower: the gap between numbers grows with t^3
            local p = a.t / LUI.SPIN
            a.next = a.next - elapsed
            if a.next <= 0 then
                local n = math.random(1, a.total)
                if a.total > 1 then while n == a.shown do n = math.random(1, a.total) end end
                a.shown = n
                self.number:SetText(tostring(n))
                self.number:SetTextColor(1, 0.84 - 0.4 * p, 0.25 - 0.15 * p)
                a.next = 0.03 + 0.55 * p * p * p
                if ns.Sound and p > 0.5 then ns.Sound("card") end
            end
        elseif not a.landed then
            a.landed = true
            self.number:SetText(tostring(a.roll))
            self.number:SetTextColor(1, 0.84, 0.25)
            self.pop:Stop() self.pop:Play()
            self.cap:SetText("Winning ticket")
            self.result:SetText(("|cff20ff20%s|r wins %s!"):format(ns.Short(a.winner), ns.Money(a.pot)))
            if ns.IsMe(a.winner) then ns.Sound("bigwin") else ns.Sound("win") end
        elseif a.t > LUI.SPIN + LUI.HOLD then
            self.anim = nil
            self:Hide()
        end
    end)
end

--- Plays the draw for whoever has the lottery page open (from the drawer, or the result arriving).
function LUI.PlayDraw(L)
    if not view or not view:IsVisible() or not L or not L.roll or L.roll < 1 then return end
    local d = view.drawAnim
    d.anim = { t = 0, next = 0, total = L.drawnTotal or 1, roll = L.roll, winner = L.winner, pot = L.potGold or 0 }
    d.cap:SetText("Drawing the lottery...")
    d.result:SetText("")
    d.outof:SetText(("out of %d ticket%s"):format(L.drawnTotal or 1, (L.drawnTotal or 1) == 1 and "" or "s"))
    d:Show()
end

---------------------------------------------------------------------------
-- The lottery page
---------------------------------------------------------------------------
function LUI.Build(p)
    view = CreateFrame("Frame", nil, p, "BackdropTemplate")
    p.lottery = view
    view:SetPoint("TOPLEFT", p.table, "TOPLEFT", 0, 0)
    view:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", 0, 0)
    view:SetBackdrop({
        bgFile = Art.GAME.marble, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 128, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    view:SetBackdropColor(0.35, 0.3, 0.25, 1)
    view:SetBackdropBorderColor(0.9, 0.72, 0.3, 1)
    view:Hide()

    view.title = Label(view, "Guild Lottery", "GameFontNormalLarge")
    view.title:SetPoint("TOPLEFT", 12, -10)
    view.sub = Label(view, "", "GameFontHighlightSmall")
    view.sub:SetPoint("TOPLEFT", 12, -30)
    view.sub:SetWidth(410)

    -- players (left): name, tickets, stake, whether the pot character has the gold
    local function Head(text, x)
        local l = Label(view, "|cffffd100" .. text .. "|r", "GameFontNormalSmall")
        l:SetPoint("TOPLEFT", 12 + x, -50)
    end
    Head("Player", 0) Head("Tickets", 108) Head("Stake", 158) Head("Paid", 222)
    view.listArea = CreateFrame("Frame", nil, view)
    view.listArea:SetPoint("TOPLEFT", 12, -66)
    view.listArea:SetSize(252, ROWS * ROW_H)
    view.listArea:EnableMouseWheel(true)
    view.offset = 0
    view.listArea:SetScript("OnMouseWheel", function(_, delta)
        view.offset = view.offset - delta
        LUI.Refresh()
    end)
    view.rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Frame", nil, view.listArea)
        r:SetSize(252, ROW_H)
        r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        r.name = Label(r, "", "GameFontHighlightSmall")
        r.name:SetPoint("LEFT", 0, 0)
        r.name:SetWidth(104)
        r.name:SetWordWrap(false)
        r.n = Label(r, "", "GameFontHighlightSmall")
        r.n:SetPoint("LEFT", 118, 0)
        r.stake = Label(r, "", "GameFontHighlightSmall")
        r.stake:SetPoint("LEFT", 158, 0)
        r.paid = Label(r, "", "GameFontHighlightSmall")
        r.paid:SetPoint("LEFT", 224, 0)
        view.rows[i] = r
    end
    view.empty = Label(view.listArea, "|cff888888No tickets bought yet.|r", "GameFontHighlightSmall")
    view.empty:SetPoint("TOPLEFT", 0, 0)
    view.more = Label(view, "", "GameFontDisableSmall")
    view.more:SetPoint("TOPLEFT", view.listArea, "BOTTOMLEFT", 0, -2)
    view.more:SetWidth(252)
    view.checked = Label(view, "", "GameFontDisableSmall")
    view.checked:SetPoint("TOPLEFT", view.more, "BOTTOMLEFT", 0, -2)
    view.checked:SetWidth(252)

    -- the pot and the draw (right)
    local potCap = Label(view, "Pot", "GameFontNormal")
    potCap:SetPoint("TOPLEFT", RIGHT, -50)
    view.pot = Label(view, "", "GameFontHighlightHuge")
    view.pot:SetPoint("TOPLEFT", RIGHT, -68)
    view.draw = Label(view, "", "GameFontHighlightSmall")
    view.draw:SetPoint("TOPLEFT", RIGHT, -100)
    view.draw:SetWidth(152)
    view.holder = Label(view, "", "GameFontHighlightSmall")
    view.holder:SetPoint("TOPLEFT", RIGHT, -150)
    view.holder:SetWidth(152)
    view.mine = Label(view, "", "GameFontNormal")
    view.mine:SetPoint("TOPLEFT", RIGHT, -176)

    -- buying
    view.count = Input(view, 30, "1", 3)
    view.count:SetPoint("TOPLEFT", RIGHT + 6, -196)
    local x = Label(view, "ticket(s)", "GameFontHighlightSmall")
    x:SetPoint("LEFT", view.count, "RIGHT", 4, 0)
    view.buy = Button(view, "Buy", 60, function() ns.Lottery.Buy(Num(view.count)) end)
    view.buy:SetPoint("LEFT", x, "RIGHT", 6, 0)
    view.hint = Label(view, "", "GameFontDisableSmall")
    view.hint:SetPoint("TOPLEFT", RIGHT, -222)
    view.hint:SetWidth(152)

    -- the pot character / creator: settling up by hand
    view.markPaid = Button(view, "Mark as paid", 150, function() ns.Lottery.MarkPaid("winner") end)
    view.markPaid:SetPoint("TOPLEFT", RIGHT, -262)
    view.markRefunds = Button(view, "Mark refunds done", 150, function() ns.Lottery.MarkPaid("refunds") end)
    view.markRefunds:SetPoint("TOPLEFT", RIGHT, -288)

    -- the last lottery
    view.prev = Label(view, "", "GameFontHighlightSmall")
    view.prev:SetPoint("BOTTOMLEFT", 12, 40)
    view.prev:SetWidth(410)

    -- officers
    view.new = Button(view, "New lottery", 110, function() LUI.ShowForm() end)
    view.new:SetPoint("BOTTOMLEFT", 10, 10)
    view.drawBtn = Button(view, "Draw", 70, function() ns.Lottery.Draw() end)
    view.drawBtn:SetPoint("LEFT", view.new, "RIGHT", 8, 0)
    -- the creator only: announce it (opens ticket sales), or close it while nobody has a ticket
    view.announce = Button(view, "Announce", 90, function() ns.Lottery.Announce() end)
    view.announce:SetPoint("LEFT", view.drawBtn, "RIGHT", 8, 0)
    view.close = Button(view, "Close lottery", 110, function()
        ns.UI.ShowInvite("Close this lottery? It's removed for everyone.", function() ns.Lottery.Close() end, function() end)
    end)
    view.close:SetPoint("LEFT", view.announce, "RIGHT", 8, 0)

    BuildDraw(view)
    return view
end

function LUI.Refresh()
    if not view or not view:IsShown() then return end
    local Lot = ns.Lottery
    local L = Lot.Current()
    local officer = Lot.IsOfficer()
    local prev = Lot.Previous()
    view.prev:SetText(prev and ("|cffbbbbbbLast lottery:|r %s won %s (%s)"):format(ns.Short(prev.winner),
        ns.Money(prev.pot or 0), date("!%d %b", (prev.at or 0) + Lot.BRISBANE)) or "|cff888888No lottery has been drawn yet.|r")
    -- officers can open the next one once this one is drawn (one at a time, never cancelled)
    view.new:SetShown(officer)
    if not L or L.state ~= "open" then view.new:Enable() else view.new:Disable() end
    local mayDraw = L and L.state == "open" and (ns.IsMe(L.by) or officer)
    view.drawBtn:SetShown(mayDraw and true or false)
    if mayDraw then
        if Lot.CanDraw(L) then view.drawBtn:Enable() else view.drawBtn:Disable() end
        view.drawBtn:SetText(Lot.drawing and "Drawing..." or "Draw")
    end
    view.markPaid:Hide() view.markRefunds:Hide()
    local creatorOpen = L and L.state == "open" and ns.IsMe(L.by)
    view.announce:SetShown(creatorOpen and true or false)
    view.close:SetShown(creatorOpen and true or false)
    if creatorOpen then
        view.announce:SetText(L.announced and "Announce again" or "Announce")
        if Lot.Now() < Lot.SalesClose(L) then view.announce:Enable() else view.announce:Disable() end
        if Lot.CanClose(L) then view.close:Enable() else view.close:Disable() end
    end
    if not L then
        view.sub:SetText(officer and "No lottery is running. Open one with New lottery." or "No lottery is running right now.")
        view.pot:SetText("-")
        view.draw:SetText("") view.holder:SetText("") view.mine:SetText("") view.checked:SetText("")
        for _, r in ipairs(view.rows) do r:Hide() end
        view.empty:Show() view.more:SetText("")
        view.count:Hide() view.buy:Hide() view.hint:SetText("")
        return
    end
    local n, pot = Lot.Totals(L)
    local players = Lot.Players(L)
    view.sub:SetText(("Tickets %s each, up to %d per player - opened by %s, the pot is held by %s"):format(
        ns.Money(L.price), L.max, ns.Short(L.by), ns.Short(L.pot)))
    view.pot:SetText(ns.Money(L.state == "drawn" and (L.potGold or pot) or pot))
    if L.state == "open" then
        local due = Lot.Now() >= L.drawAt
        view.draw:SetText(("Draw: %s\n%s\nSales close: %s"):format(Lot.When(L.drawAt),
            due and "|cffff8040due - waiting for " .. ns.Short(L.by) .. "|r" or Until(L.drawAt),
            Lot.SalesOpen(L) and Until(Lot.SalesClose(L)) or "|cff888888closed|r"))
    elseif L.winner == "" then
        view.draw:SetText("Drawn - nobody bought a ticket.")
    else
        view.draw:SetText(("|cff20ff20%s won!|r\nticket %d of %d\n%s"):format(ns.Short(L.winner), L.roll or 0,
            L.drawnTotal or n, Lot.When(L.drawnAt)))
    end
    local mine = Lot.Mine(L)
    view.mine:SetText(("Your tickets: %d%s"):format(mine, mine > 0 and (" (" .. ns.Money(mine * L.price) .. ")") or ""))
    view.checked:SetText(L.potChecked and ("%s last checked their mail %s"):format(ns.Short(L.pot), Lot.When(L.potChecked))
        or ("%s hasn't checked their mail yet"):format(ns.Short(L.pot)))

    -- the players, most tickets first, scrolling
    local maxOff = math.max(0, #players - ROWS)
    view.offset = math.min(math.max(view.offset, 0), maxOff)
    for i, r in ipairs(view.rows) do
        local e = players[view.offset + i]
        r:SetShown(e ~= nil)
        if e then
            local name = ns.IsMe(e.name) and ("|cffffd100" .. ns.Short(e.name) .. "|r") or ns.Short(e.name)
            if L.state == "drawn" and ns.SameName(e.name, L.winner) then name = "|cff20ff20" .. ns.Short(e.name) .. " (won)|r" end
            r.name:SetText(name)
            r.n:SetText(tostring(e.n))
            r.stake:SetText(ns.Money(e.stake))
            r.paid:SetText(e.verified and "|cff20ff20received|r" or (e.received > 0 and "|cffffd100part|r" or "|cff888888in mail|r"))
        end
    end
    view.empty:SetShown(#players == 0)
    view.more:SetText(maxOff > 0 and ("%d-%d of %d players (scroll)"):format(view.offset + 1,
        math.min(view.offset + ROWS, #players), #players) or ("%d player%s, %d ticket%s"):format(#players,
        #players == 1 and "" or "s", n, n == 1 and "" or "s"))

    -- buying
    local selling = Lot.SalesOpen(L) and not ns.IsMe(L.pot)
    view.count:SetShown(selling)
    view.buy:SetShown(selling)
    local hint = ""
    if selling then
        local canBuy = Lot.MailOpen() and not Lot.Busy() and mine < L.max
        if canBuy then view.buy:Enable() else view.buy:Disable() end
        if mine >= L.max then hint = "You have the most tickets allowed."
        elseif Lot.Busy() then hint = "Sending..."
        elseif not Lot.MailOpen() then hint = "Open a mailbox to buy - the gold is mailed to " .. ns.Short(L.pot) .. "." end
    elseif L.state == "open" and not L.announced then
        hint = ns.IsMe(L.by) and "Not announced yet - check the details, then click Announce to open ticket sales."
            or ("Ticket sales open once " .. ns.Short(L.by) .. " announces it.")
    elseif L.state == "open" and ns.IsMe(L.pot) then
        hint = "You hold the pot - open your mailbox now and then so every paid ticket is counted."
    elseif L.state == "open" then
        hint = "Ticket sales have closed."
    end

    -- after the draw: what the pot character still has to do by hand
    if L.state == "drawn" then
        local owes = Lot.Owes(L)
        local settler = ns.IsMe(L.pot) or ns.IsMe(L.by)
        local lines = {}
        if owes.winner then
            lines[#lines + 1] = ("%s owes %s %s"):format(ns.Short(L.pot), ns.Short(owes.winner.to), ns.Money(owes.winner.amount))
        elseif L.winner ~= "" then
            lines[#lines + 1] = "|cff20ff20Winner paid.|r"
        end
        for _, r in ipairs(owes.refunds) do
            lines[#lines + 1] = ("Missed the draw: %s - refund %s"):format(ns.Short(r.to), ns.Money(r.amount))
        end
        hint = table.concat(lines, "\n")
        view.markPaid:SetShown(settler and owes.winner ~= nil)
        view.markRefunds:SetShown(settler and #owes.refunds > 0)
    end
    view.hint:SetText(hint)
    view.holder:SetText(L.state == "drawn" and "" or ("Pot held by |cffffd100%s|r"):format(ns.Short(L.pot)))
end

---------------------------------------------------------------------------
-- The officers' "New lottery" form
---------------------------------------------------------------------------
local function BuildPotPicker(f)
    f.potPick = Button(f, "Choose a character" .. ARROW, 190, function()
        if f.potList:IsShown() then f.potList:Hide() return end
        f.potOffset = 0
        LUI.FillPotList()
        f.potList:Show()
    end)
    local list = CreateFrame("Frame", nil, f, "BackdropTemplate")
    list:SetPoint("TOPLEFT", f.potPick, "BOTTOMLEFT", 0, -2)
    list:SetSize(220, PICK_ROWS * PICK_ROW_H + 12)
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    list:SetBackdrop({
        bgFile = Art.GAME.dialogBg, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 32, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    list:SetBackdropBorderColor(0.9, 0.72, 0.3, 1)
    list:EnableMouse(true)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        f.potOffset = (f.potOffset or 0) - delta
        LUI.FillPotList()
    end)
    list:Hide()
    list.rows = {}
    for i = 1, PICK_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetSize(208, PICK_ROW_H)
        row:SetPoint("TOPLEFT", 6, -6 - (i - 1) * PICK_ROW_H)
        row:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
        row.text = Label(row, "", "GameFontHighlight")
        row.text:SetPoint("LEFT", 4, 0)
        row.value = false
        row:SetScript("OnClick", function(self)
            if self.value then LUI.SetPot(self.value) end
            list:Hide()
        end)
        list.rows[i] = row
    end
    f.potList = list
end

--- Guild members with GuildGambit (online or not), scrollable.
function LUI.FillPotList()
    local names = ns.Lottery.Candidates()
    local list = form.potList
    local maxOff = math.max(0, #names - PICK_ROWS)
    form.potOffset = math.min(math.max(form.potOffset or 0, 0), maxOff)
    for i, row in ipairs(list.rows) do
        local name = names[form.potOffset + i]
        row.value = name or false
        row:SetShown(name ~= nil)
        if name then
            local online = ns.IsMe(name) or ns.Guild.IsOnline(name)
            row.text:SetText(ns.Short(name) .. (online and "" or "  |cff888888(offline)|r"))
        end
    end
    list:SetHeight(math.max(1, math.min(#names, PICK_ROWS)) * PICK_ROW_H + 12)
end

function LUI.SetPot(name)
    form.pot = name or false
    form.potPick:SetText((name and ns.Short(name) or "Choose a character") .. ARROW)
end

local function FormTime()
    return ns.Lottery.BrisbaneTime(form.day, Num(form.hour), Num(form.minute))
end

local function RefreshForm()
    local Lot = ns.Lottery
    local t = FormTime()
    form.dayText:SetText(date("!%a %d %b", t + Lot.BRISBANE))
    if form.day > 0 then form.prevDay:Enable() else form.prevDay:Disable() end
    if t - Lot.SALES_CLOSE <= Lot.Now() + 60 then
        form.when:SetText("|cffff4040The draw has to be more than 1h15m away.|r")
    else
        form.when:SetText(("Draw %s (%s)\nTicket sales close at %s"):format(Lot.When(t), Until(t),
            date("!%H:%M", t - Lot.SALES_CLOSE + Lot.BRISBANE)))
    end
end

local function BuildForm()
    local f = CreateFrame("Frame", "GuildGambitLotteryForm", UIParent, "BackdropTemplate")
    form = f
    f.pot, f.potOffset, f.day = false, 0, 7
    f:SetSize(360, 320)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = Art.GAME.dialogBg, edgeFile = Art.GAME.dialogBorder,
        tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    tinsert(UISpecialFrames, "GuildGambitLotteryForm")
    local title = Label(f, "New guild lottery", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -18)

    local y = -50
    local function Row(text)
        local l = Label(f, text, "GameFontNormal")
        l:SetPoint("TOPLEFT", 22, y)
        y = y - 34
        return l
    end
    local potL = Row("Pot held by:")
    BuildPotPicker(f)
    f.potPick:SetPoint("LEFT", potL, "RIGHT", 10, 0)

    local priceL = Row("Ticket price:")
    f.gold = Input(f, 50, "10", 6)
    f.gold:SetPoint("LEFT", priceL, "RIGHT", 10, 0)
    local g = Label(f, "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12|t")
    g:SetPoint("LEFT", f.gold, "RIGHT", 2, 0)
    f.silver = Input(f, 24, "", 2)
    f.silver:SetPoint("LEFT", g, "RIGHT", 8, 0)
    local s = Label(f, "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12|t")
    s:SetPoint("LEFT", f.silver, "RIGHT", 2, 0)

    local maxL = Row("Most tickets per player:")
    f.max = Input(f, 36, "5", 3)
    f.max:SetPoint("LEFT", maxL, "RIGHT", 10, 0)

    local dayL = Row("Draw day:")
    f.prevDay = Button(f, "<", 24, function() f.day = math.max(0, f.day - 1) RefreshForm() end)
    f.prevDay:SetPoint("LEFT", dayL, "RIGHT", 10, 0)
    f.dayText = Label(f, "", "GameFontHighlight")
    f.dayText:SetPoint("LEFT", f.prevDay, "RIGHT", 6, 0)
    f.dayText:SetWidth(96)
    f.dayText:SetJustifyH("CENTER")
    f.nextDay = Button(f, ">", 24, function() f.day = math.min(60, f.day + 1) RefreshForm() end)
    f.nextDay:SetPoint("LEFT", f.dayText, "RIGHT", 6, 0)

    local timeL = Row("Draw time (Brisbane time, 24h):")
    f.hour = Input(f, 26, "20", 2)
    f.hour:SetPoint("LEFT", timeL, "RIGHT", 10, 0)
    local colon = Label(f, ":", "GameFontHighlight")
    colon:SetPoint("LEFT", f.hour, "RIGHT", 2, 0)
    f.minute = Input(f, 26, "00", 2)
    f.minute:SetPoint("LEFT", colon, "RIGHT", 6, 0)
    for _, box in ipairs({ f.hour, f.minute }) do box:SetScript("OnTextChanged", RefreshForm) end

    f.when = Label(f, "", "GameFontHighlightSmall")
    f.when:SetPoint("TOPLEFT", 22, y + 6)
    f.when:SetWidth(316)
    local note = Label(f, "|cff888888Only one lottery at a time, and it can't be cancelled once open.|r", "GameFontHighlightSmall")
    note:SetPoint("TOPLEFT", 22, y - 28)
    note:SetWidth(316)

    local create = Button(f, "Open lottery", 120, function()
        local hour, minute = Num(f.hour), Num(f.minute)
        if hour > 23 or minute > 59 then ns.Print("Enter a time like 20:00.") return end
        local L = ns.Lottery.Open({
            pot = f.pot or nil, price = Num(f.gold) * ns.COPPER_PER_GOLD + Num(f.silver) * 100,
            max = Num(f.max), drawAt = FormTime(),
        })
        if L then f:Hide() ns.UI.ShowLottery() end
    end)
    create:SetPoint("BOTTOMRIGHT", -20, 18)
    local close = Button(f, "Cancel", 80, function() f:Hide() end)
    close:SetPoint("RIGHT", create, "LEFT", -8, 0)
    f:Hide()
end

function LUI.ShowForm()
    if not ns.Lottery.IsOfficer() then ns.Print("Only guild officers can open a lottery.") return end
    local L = ns.Lottery.Current()
    if L and L.state == "open" then ns.Print("A lottery is already running - only one at a time.") return end
    if not form then BuildForm() end
    if not form.pot and L then LUI.SetPot(L.pot) end -- default: last time's pot holder
    RefreshForm()
    form:Show()
end

function LUI.Form() return form end
function LUI.View() return view end
