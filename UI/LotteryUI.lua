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
LUI.SPIN = ns.Lottery and ns.Lottery.REVEAL or 5 -- seconds the draw's number spins before it stops on the winning ticket
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

--- "Bob won 30g with 10g in" (the stake is left out if it isn't known).
local function WonText(winner, pot, stake)
    return ("%s won %s"):format(ns.Short(winner), ns.Money(pot or 0))
        .. (stake and stake > 0 and (" with " .. ns.Money(stake) .. " in") or "")
end

function LUI.RowText()
    local Lot = ns.Lottery
    local L = Lot.Current()
    if not L then
        local prev = Lot.Previous()
        if prev then
            return "|cffffd100Guild Lottery|r - last lottery: " .. WonText(prev.winner, prev.pot, prev.stake)
        end
        return "|cffffd100Guild Lottery|r - " .. (Lot.IsOfficer() and "none running - open one here" or "none running right now")
    end
    local n, pot = Lot.Totals(L)
    if L.state == "open" and not L.announced then
        return "|cffffd100Guild Lottery|r - " .. (ns.IsMe(L.by) and "created - |cffff8040not announced yet|r" or "coming soon")
    end
    if Lot.Countdown(L) or Lot.Revealing(L) then
        return "|cffffd100Guild Lottery|r - |cffff8040drawing now - click to watch!|r"
    end
    if L.state == "open" then
        local when = Lot.Now() >= L.drawAt and "|cffff8040draw due|r"
            or (Lot.SalesOpen(L) and ("draw " .. Until(L.drawAt)) or ("sales closed, draw " .. Until(L.drawAt)))
        return ("|cffffd100Guild Lottery|r - %s pot, %d ticket%s - %s"):format(ns.Money(pot), n, n == 1 and "" or "s", when)
    end
    if L.winner == "" then return "|cffffd100Guild Lottery|r - drawn, no tickets sold" end
    return "|cffffd100Guild Lottery|r - drawn: " .. WonText(L.winner, L.potGold, Lot.WinnerStake(L))
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
    -- the draw's numbers: mine (big) and everyone's (small, above the Close button)
    d.mine = Label(d, "", "GameFontNormalLarge")
    d.mine:SetPoint("TOP", d.result, "BOTTOM", 0, -10)
    d.mine:SetJustifyH("CENTER")
    d.list = Label(d, "", "GameFontHighlightSmall")
    d.list:SetPoint("BOTTOMLEFT", 20, 46)
    d.list:SetPoint("BOTTOMRIGHT", -20, 46)
    d.list:SetJustifyH("CENTER")
    d.close = Button(d, "Close", 80, function()
        -- closed by hand: don't bring this countdown or spin back on the next refresh
        d.closedFor = ns.Lottery.countdown or ns.Lottery.revealing
        d.anim, d.count = nil, nil
        d:Hide()
    end)
    d.close:SetPoint("BOTTOM", 0, 14)
    -- the landing: a pop of the number, like a deathroll roll
    d.pop = d.holder:CreateAnimationGroup()
    local grow = d.pop:CreateAnimation("Scale")
    grow:SetScale(1.35, 1.35) grow:SetDuration(0.12) grow:SetOrder(1)
    local shrink = d.pop:CreateAnimation("Scale")
    shrink:SetScale(1 / 1.35, 1 / 1.35) shrink:SetDuration(0.2) shrink:SetOrder(2)
    d:SetScript("OnUpdate", function(self, elapsed)
        local a = rawget(self, "anim")
        local count = rawget(self, "count")
        if not a and count then
            -- before the roll: collecting the tickets, then the countdown with everyone's numbers
            local L = ns.Lottery.Current()
            local left, phase = ns.Lottery.Countdown(L)
            if not left then self.count = nil self:Hide() return end
            if phase ~= count.phase then
                count.phase, count.shown = phase, nil
                LUI.ShowNumbers(self, L)
            end
            if phase == "collect" then
                if count.shown ~= "c" then
                    count.shown = "c"
                    self.cap:SetText("Collecting everyone's tickets...")
                    self.number:SetText("")
                end
            elseif left > 0 then
                local s = math.ceil(left)
                if s ~= count.shown then
                    count.shown = s
                    self.cap:SetText("Drawing the lottery in")
                    self.number:SetText(tostring(s))
                    self.number:SetTextColor(1, 0.84, 0.25)
                    self.pop:Stop() self.pop:Play()
                    if s <= 5 and ns.Sound then ns.Sound("card") end
                end
            elseif count.shown ~= 0 then
                count.shown = 0
                self.cap:SetText("Rolling...")
                self.number:SetText("?")
            end
            return
        end
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
            local lo, hi = ns.Lottery.NumbersOf(ns.Lottery.Current(), a.winner)
            self.result:SetText(("|cff20ff20%s|r wins %s!%s"):format(ns.Short(a.winner), ns.Money(a.pot),
                lo and (" |cffbbbbbb(numbers " .. LUI.Range(lo, hi) .. ")|r") or ""))
            if ns.IsMe(a.winner) then ns.Sound("bigwin") else ns.Sound("win") end
        elseif a.t > LUI.SPIN + LUI.HOLD then
            self.anim = nil
            self:Hide()
        end
    end)
end

--- "7-9", or "7" for one ticket.
function LUI.Range(lo, hi) return lo == hi and tostring(lo) or (lo .. "-" .. hi) end

LUI.LIST_MAX = 30 -- players named in the overlay's list of numbers

--- The draw's numbers on the overlay: mine, and everyone's (nothing until the list is frozen).
function LUI.ShowNumbers(d, L)
    local u = ns.Lottery.LineupOf(L)
    if not u then d.mine:SetText("") d.list:SetText("") return end
    local lo, hi = ns.Lottery.NumbersOf(L, ns.Me())
    d.mine:SetText(lo and ("Your numbers: |cffffffff" .. LUI.Range(lo, hi) .. "|r")
        or "|cff888888You have no tickets in this draw.|r")
    d.outof:SetText(("%d ticket%s in the draw"):format(u.total, u.total == 1 and "" or "s"))
    local parts = {}
    for i, e in ipairs(u.list) do
        if i > LUI.LIST_MAX then
            parts[#parts + 1] = ("+%d more"):format(#u.list - LUI.LIST_MAX)
            break
        end
        local text = ns.Short(e.name) .. " " .. LUI.Range(e.lo, e.hi)
        parts[#parts + 1] = ns.IsMe(e.name) and ("|cffffd100" .. text .. "|r") or text
    end
    d.list:SetText(table.concat(parts, "    "))
end

--- Plays the draw for whoever has the lottery page open (from the drawer, the result arriving,
--- or the page being opened mid-spin). `from`: seconds already spun.
function LUI.PlayDraw(L, from)
    if not view or not view:IsVisible() or not L or not L.roll or L.roll < 1 then return end
    local d = view.drawAnim
    d.count = nil
    d.anim = { t = math.max(0, from or 0), next = 0, total = L.drawnTotal or 1, roll = L.roll, winner = L.winner,
        pot = L.potGold or 0 }
    d.cap:SetText("Drawing the lottery...")
    d.result:SetText("")
    LUI.ShowNumbers(d, L) -- my numbers stay up while it spins
    d.list:SetText("")
    d.outof:SetText(("out of %d ticket%s"):format(L.drawnTotal or 1, (L.drawnTotal or 1) == 1 and "" or "s"))
    d:Show()
end

--- The countdown before the roll, for whoever has the lottery page open.
function LUI.ShowCountdown(L)
    if not view or not view:IsVisible() or not ns.Lottery.Countdown(L) then return end
    local d = view.drawAnim
    if rawget(d, "anim") then return end -- a spin is already showing
    local _, phase = ns.Lottery.Countdown(L)
    d.count = { shown = nil, phase = phase }
    d.cap:SetText(phase == "collect" and "Collecting everyone's tickets..." or "Drawing the lottery in")
    d.number:SetText("")
    d.outof:SetText("")
    d.result:SetText("")
    LUI.ShowNumbers(d, L)
    d:Show()
end

--- Opening the page during a draw joins it: the countdown, or the spin where it's up to.
local function JoinDraw(L)
    local d = view.drawAnim
    if d:IsShown() then return end
    local Lot = ns.Lottery
    if Lot.Countdown(L) and rawget(d, "closedFor") ~= Lot.countdown then
        LUI.ShowCountdown(L)
    elseif Lot.Revealing(L) and rawget(d, "closedFor") ~= Lot.revealing then
        LUI.PlayDraw(L, LUI.SPIN - Lot.RevealLeft(L))
    end
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
    -- (kept narrow: the right-hand column starts at RIGHT)
    Head("Player", 0) Head("Tickets", 92) Head("Stake", 138) Head("Paid", 192)
    view.listArea = CreateFrame("Frame", nil, view)
    view.listArea:SetPoint("TOPLEFT", 12, -66)
    view.listArea:SetSize(244, ROWS * ROW_H)
    view.listArea:EnableMouseWheel(true)
    view.offset = 0
    view.listArea:SetScript("OnMouseWheel", function(_, delta)
        view.offset = view.offset - delta
        LUI.Refresh()
    end)
    view.rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Button", nil, view.listArea)
        r:SetSize(244, ROW_H)
        -- the pot character clicks a row to confirm (or take back) that player's gold by hand
        r:SetScript("OnClick", function(self) LUI.ConfirmRow(self.entry) end)
        r:SetScript("OnEnter", function(self)
            if not self.canConfirm or not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.entry.manual and "Click to take back your confirmation"
                or (self.entry.verified and "Their gold has arrived" or "Click to confirm their gold arrived (if the addon missed the mail)"))
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        r.name = Label(r, "", "GameFontHighlightSmall")
        r.name:SetPoint("LEFT", 0, 0)
        r.name:SetWidth(90)
        r.name:SetWordWrap(false)
        r.n = Label(r, "", "GameFontHighlightSmall")
        r.n:SetPoint("LEFT", 102, 0)
        r.stake = Label(r, "", "GameFontHighlightSmall")
        r.stake:SetPoint("LEFT", 138, 0)
        r.paid = Label(r, "", "GameFontHighlightSmall")
        r.paid:SetPoint("LEFT", 192, 0)
        view.rows[i] = r
    end
    view.empty = Label(view.listArea, "|cff888888No tickets bought yet.|r", "GameFontHighlightSmall")
    view.empty:SetPoint("TOPLEFT", 0, 0)
    view.more = Label(view, "", "GameFontDisableSmall")
    view.more:SetPoint("TOPLEFT", view.listArea, "BOTTOMLEFT", 0, -2)
    view.more:SetWidth(244)
    view.checked = Label(view, "", "GameFontDisableSmall")
    view.checked:SetPoint("TOPLEFT", view.more, "BOTTOMLEFT", 0, -2)
    view.checked:SetWidth(244)

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
    view.countLabel = Label(view, "ticket(s)", "GameFontHighlightSmall")
    view.countLabel:SetPoint("LEFT", view.count, "RIGHT", 4, 0)
    view.buy = Button(view, "Buy", 60, function() ns.Lottery.Buy(Num(view.count)) end)
    view.buy:SetPoint("LEFT", view.countLabel, "RIGHT", 6, 0)
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
    view.changeDate = Button(view, "Change draw date", 150, function() LUI.ShowDateForm() end)
    view.changeDate:SetPoint("TOPLEFT", RIGHT, -262)

    BuildDraw(view)
    return view
end

--- Redraws the open page when the next time-based change is due (the Draw button turning on,
--- ticket sales closing), so a page left open doesn't wait for something else to refresh it.
--- Only one wake is pending at a time; a long wait is broken into hour-long steps.
local wakeAt
local function WakeFor(L, officer)
    local Lot = ns.Lottery
    if not L or L.state ~= "open" then return end
    local now = Lot.Now()
    local due
    for _, t in ipairs({ Lot.SalesClose(L), L.drawAt,
        (officer and not ns.IsMe(L.by)) and (L.drawAt + Lot.TAKEOVER) or nil }) do
        if t > now and (not due or t < due) then due = t end
    end
    if not due then return end
    local at = math.min(due, now + 3600)
    if wakeAt and wakeAt > now and wakeAt <= at then return end -- an earlier one is already set
    wakeAt = at
    C_Timer.After(at - now + 0.5, function()
        if wakeAt ~= at then return end -- replaced by a newer one
        wakeAt = nil
        LUI.Refresh()
    end)
end

function LUI.Refresh()
    if not view or not view:IsShown() then return end
    local Lot = ns.Lottery
    local L = Lot.Current()
    local officer = Lot.IsOfficer()
    WakeFor(L, officer)
    local prev = Lot.Previous()
    view.prev:SetText(prev and ("|cffbbbbbbLast lottery:|r %s (%s)"):format(WonText(prev.winner, prev.pot, prev.stake),
        date("!%d %b", (prev.at or 0) + Lot.BRISBANE)) or "|cff888888No lottery has been drawn yet.|r")
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
    if L then JoinDraw(L) end
    local creatorOpen = L and L.state == "open" and ns.IsMe(L.by)
    view.announce:SetShown(creatorOpen and true or false)
    view.close:SetShown(creatorOpen and true or false)
    view.changeDate:SetShown(creatorOpen and true or false)
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
        view.count:Hide() view.countLabel:Hide() view.buy:Hide() view.hint:SetText("")
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
    elseif Lot.Revealing(L) then
        view.draw:SetText("|cffff8040Drawing...|r") -- no winner on the page before the number lands
    elseif L.winner == "" then
        view.draw:SetText("Drawn - nobody bought a ticket.")
    else
        local stake = Lot.WinnerStake(L)
        view.draw:SetText(("|cff20ff20%s won!|r%s\nticket %d of %d\n%s"):format(ns.Short(L.winner),
            stake and (" (" .. ns.Money(stake) .. " in)") or "", L.roll or 0, L.drawnTotal or n, Lot.When(L.drawnAt)))
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
            if L.state == "drawn" and not Lot.Revealing(L) and ns.SameName(e.name, L.winner) then name = "|cff20ff20" .. ns.Short(e.name) .. " (won)|r" end
            r.name:SetText(name)
            r.n:SetText(tostring(e.n))
            r.stake:SetText(ns.Money(e.stake))
            r.paid:SetText(e.manual and "|cff20ff20confirmed|r" or (e.verified and "|cff20ff20received|r"
                or (e.unpaid > 0 and "|cffff4040not paid|r")
                or (e.received > 0 and "|cffffd100part|r" or "|cff888888in mail|r")))
            r.entry, r.canConfirm = e, ns.IsMe(L.pot) and (L.state == "open" or L.state == "drawn")
        end
    end
    view.empty:SetShown(#players == 0)
    view.more:SetText(maxOff > 0 and ("%d-%d of %d players (scroll)"):format(view.offset + 1,
        math.min(view.offset + ROWS, #players), #players) or ("%d player%s, %d ticket%s"):format(#players,
        #players == 1 and "" or "s", n, n == 1 and "" or "s"))

    -- buying
    local selling = Lot.SalesOpen(L) and not ns.IsMe(L.pot)
    view.count:SetShown(selling)
    view.countLabel:SetShown(selling)
    view.buy:SetShown(selling)
    local hint = ""
    if selling then
        local canBuy = Lot.MailOpen() and not Lot.Busy() and mine < L.max
        if canBuy then view.buy:Enable() else view.buy:Disable() end
        if mine >= L.max then hint = "You have the most tickets allowed."
        elseif Lot.Busy() then hint = "Sending..."
        elseif not Lot.MailOpen() then hint = "Open a mailbox to buy - the gold is mailed to " .. ns.Short(L.pot) .. "."
        else hint = "|cffffd100Keep the mailbox open until you see \"Bought ... tickets\" in chat.|r" end
    elseif L.state == "open" and not L.announced then
        hint = ns.IsMe(L.by) and "Not announced yet - check the details, then click Announce to open ticket sales."
            or ("Ticket sales open once " .. ns.Short(L.by) .. " announces it.")
    elseif L.state == "open" and ns.IsMe(L.pot) then
        hint = "You hold the pot - open your mailbox now and then. If the addon misses someone's gold, click their row to confirm it."
        local other = L.otherMail and L.otherMail[1]
        if other then
            hint = ("In your mailbox: %s from %s that isn't a ticket mail. If it's for tickets, click their row to confirm it."):format(
                ns.Money(other.money), ns.Short(other.from))
        end
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
        local unpaid = {}
        for _, e in ipairs(players) do
            if e.unpaid > 0 then unpaid[#unpaid + 1] = ("%s (%d)"):format(ns.Short(e.name), e.unpaid) end
        end
        if #unpaid > 0 then
            lines[#lines + 1] = "|cffff8040Not paid, left out of the draw:|r " .. table.concat(unpaid, ", ")
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
    f.setupRows = {} -- the rows hidden when only the date is being changed
    local function Row(text, setup)
        local l = Label(f, text, "GameFontNormal")
        l:SetPoint("TOPLEFT", 22, y)
        y = y - 34
        if setup then f.setupRows[#f.setupRows + 1] = l end
        return l
    end
    f.title = title
    local potL = Row("Pot held by:", true)
    BuildPotPicker(f)
    f.potPick:SetPoint("LEFT", potL, "RIGHT", 10, 0)

    local priceL = Row("Ticket price:", true)
    f.gold = Input(f, 50, "10", 6)
    f.gold:SetPoint("LEFT", priceL, "RIGHT", 10, 0)
    local g = Label(f, "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12|t")
    g:SetPoint("LEFT", f.gold, "RIGHT", 2, 0)
    f.silver = Input(f, 24, "", 2)
    f.silver:SetPoint("LEFT", g, "RIGHT", 8, 0)
    local s = Label(f, "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12|t")
    s:SetPoint("LEFT", f.silver, "RIGHT", 2, 0)

    local maxL = Row("Most tickets per player:", true)
    f.max = Input(f, 36, "5", 3)
    f.max:SetPoint("LEFT", maxL, "RIGHT", 10, 0)
    for _, w in ipairs({ f.potPick, f.gold, g, f.silver, s, f.max }) do f.setupRows[#f.setupRows + 1] = w end

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
    f.note = Label(f, "", "GameFontHighlightSmall")
    f.note:SetPoint("TOPLEFT", 22, y - 28)
    f.note:SetWidth(316)

    local create = Button(f, "Open lottery", 120, function()
        local hour, minute = Num(f.hour), Num(f.minute)
        if hour > 23 or minute > 59 then ns.Print("Enter a time like 20:00.") return end
        if f.dateOnly then
            if ns.Lottery.ChangeDate(FormTime()) then f:Hide() ns.UI.ShowLottery() end
            return
        end
        local L = ns.Lottery.Open({
            pot = f.pot or nil, price = Num(f.gold) * ns.COPPER_PER_GOLD + Num(f.silver) * 100,
            max = Num(f.max), drawAt = FormTime(),
        })
        if L then f:Hide() ns.UI.ShowLottery() end
    end)
    create:SetPoint("BOTTOMRIGHT", -20, 18)
    f.create = create
    local close = Button(f, "Cancel", 80, function() f:Hide() end)
    close:SetPoint("RIGHT", create, "LEFT", -8, 0)
    f:Hide()
end

local function FormMode(dateOnly)
    form.dateOnly = dateOnly
    for _, w in ipairs(form.setupRows) do w:SetShown(not dateOnly) end
    form.title:SetText(dateOnly and "Change the draw date" or "New guild lottery")
    form.create:SetText(dateOnly and "Save date" or "Open lottery")
    form.note:SetText(dateOnly and "|cff888888Everyone's addon is told the new date. Tickets already bought still count.|r"
        or "|cff888888Only one lottery at a time. It stays quiet until you click Announce.|r")
end

--- The pot character clicked a player's row.
function LUI.ConfirmRow(e)
    local L = ns.Lottery.Current()
    if not e or not L or not ns.IsMe(L.pot) or (L.state ~= "open" and L.state ~= "drawn") then return end
    if e.manual then
        ns.UI.ShowInvite(("Take back your confirmation of %s's gold?"):format(ns.Short(e.name)),
            function() ns.Lottery.Confirm(e.name, true) end, function() end)
    elseif not e.verified then
        ns.UI.ShowInvite(("Confirm that %s's %s for %d ticket%s has arrived? Only do this if the gold is in your bags."):format(
            ns.Short(e.name), ns.Money(e.stake), e.n, e.n == 1 and "" or "s"),
            function() ns.Lottery.Confirm(e.name) end, function() end)
    end
end

function LUI.ShowForm()
    if not ns.Lottery.IsOfficer() then ns.Print("Only guild officers can open a lottery.") return end
    local L = ns.Lottery.Current()
    if L and L.state == "open" then ns.Print("A lottery is already running - only one at a time.") return end
    if not form then BuildForm() end
    FormMode(false)
    if not form.pot and L then LUI.SetPot(L.pot) end -- default: last time's pot holder
    RefreshForm()
    form:Show()
end

--- The creator: the same form, just the draw day and time.
function LUI.ShowDateForm()
    local Lot = ns.Lottery
    local L = Lot.Current()
    if not L or L.state ~= "open" then ns.Print("There's no running lottery to change.") return end
    if not ns.IsMe(L.by) then ns.Print("Only %s, who opened this lottery, can change its date.", ns.Short(L.by)) return end
    if not form then BuildForm() end
    FormMode(true)
    -- start from the current draw time
    local bne = date("!*t", L.drawAt + Lot.BRISBANE)
    form.day = math.max(0, math.floor((L.drawAt + Lot.BRISBANE) / 86400) - math.floor((Lot.Now() + Lot.BRISBANE) / 86400))
    form.hour:SetText(("%02d"):format(bne.hour))
    form.minute:SetText(("%02d"):format(bne.min))
    RefreshForm()
    form:Show()
end

function LUI.Form() return form end
function LUI.View() return view end
