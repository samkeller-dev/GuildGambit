-- UI/Wealth.lua: the guild wealth window. A coin tab on the side of the main window pops it
-- out: a donut chart of the guild's gold (one slice per character with GuildGambit), and a
-- card for whichever slice is clicked - wallet, PvP kills and GuildGambit records.
local ADDON_NAME, ns = ...
local Art, Compat = ns.Art, ns.Compat

local WUI = {}
ns.WealthUI = WUI

local W, H = 580, 440
local D = 200            -- pie diameter
local HOLE = 0.52        -- the donut's hole, as a share of the diameter
local SEG = 120          -- wedges: 3 degrees each (matches tools/art/pie.py)
local MAX_SLICES = 11    -- plus "Others"
local MIN_SHARE = 0.02   -- slices smaller than this go into "Others"
local LEGEND = 8
local ROWS = 20

-- distinct colours that read well on the dark dialog (slice order: richest first)
local PALETTE = {
    { 0.95, 0.75, 0.20 }, { 0.30, 0.62, 0.95 }, { 0.85, 0.30, 0.30 }, { 0.35, 0.78, 0.40 },
    { 0.70, 0.45, 0.90 }, { 0.95, 0.55, 0.20 }, { 0.30, 0.80, 0.80 }, { 0.90, 0.45, 0.65 },
    { 0.65, 0.75, 0.30 }, { 0.55, 0.55, 0.95 }, { 0.80, 0.60, 0.45 },
}
local OTHERS = { 0.45, 0.45, 0.45 }

local frame, pie, card
local slices, total = {}, 0
local selected, hovered -- slices
local focus -- name of the player (or "Others") whose card is shown

local function Label(parent, text, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    fs:SetText(text or "")
    fs:SetJustifyH("LEFT")
    return fs
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------
local function Gold(c)
    c = math.floor(c or 0)
    if math.abs(c) >= 100000 then -- 10g and up: whole gold reads better in a chart
        local g = tostring(math.floor(math.abs(c) / 10000)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
        return (c < 0 and "-" or "") .. g .. "g"
    end
    return ns.Money(c)
end

local function Signed(c, good)
    if not c or c == 0 then return "|cffbbbbbb0g|r" end
    local color = (c > 0) == (good ~= false) and "20ff20" or "ff4040"
    return ("|cff%s%s%s|r"):format(color, c > 0 and "+" or "-", Gold(math.abs(c)))
end

local function Day(t) return (t and t > 0) and date("%d %b", t) or "" end

local function Ago(t)
    local s = time() - (t or 0)
    if s < 90 then return "just now" end
    if s < 3600 then return math.floor(s / 60) .. "m ago" end
    if s < 86400 then return math.floor(s / 3600) .. "h ago" end
    return math.floor(s / 86400) .. "d ago"
end

local CLASS_NAMES = {
    WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
    SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid", DEATHKNIGHT = "Death Knight",
}
local RACE_NAMES = { NightElf = "Night Elf", Scourge = "Undead" }

local function ClassColor(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c and c.r then return ("%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255) end
    return "ffd100"
end

--- Guild roster line for a name: { rank, zone, online, lastOnline (text) } or nil.
local function Roster(name)
    local n = (GetNumGuildMembers and GetNumGuildMembers()) or 0
    for i = 1, n do
        local who, rank, _, _, _, zone, _, _, online = GetGuildRosterInfo(i)
        who = Compat.Safe(who)
        if who and ns.SameName(who, name) then
            local r = { rank = Compat.Safe(rank), zone = Compat.Safe(zone), online = Compat.Safe(online) }
            if not r.online and GetGuildRosterLastOnline then
                local ok, y, m, d, h = pcall(GetGuildRosterLastOnline, i)
                if ok then
                    y, m, d, h = tonumber(y) or 0, tonumber(m) or 0, tonumber(d) or 0, tonumber(h) or 0
                    if y > 0 then r.last = y .. "y ago"
                    elseif m > 0 then r.last = m .. "mo ago"
                    elseif d > 0 then r.last = d .. "d ago"
                    elseif h > 0 then r.last = h .. "h ago"
                    else r.last = "<1h ago" end
                end
            end
            return r
        end
    end
end

---------------------------------------------------------------------------
-- Slices
---------------------------------------------------------------------------
local function BuildSlices()
    slices, total = {}, 0
    local list = ns.Wealth.List()
    for _, e in ipairs(list) do total = total + math.max(0, e.gold or 0) end
    local others
    for _, e in ipairs(list) do
        if (e.gold or 0) > 0 then
            local share = e.gold / total
            if #slices < MAX_SLICES and share >= MIN_SHARE then
                slices[#slices + 1] = { name = e.name, entry = e, gold = e.gold, color = PALETTE[#slices + 1] }
            else
                others = others or { others = {}, gold = 0, color = OTHERS, name = "Others" }
                others.others[#others.others + 1] = e
                others.gold = others.gold + e.gold
            end
        end
    end
    if others then slices[#slices + 1] = others end
    local start = 0
    for _, s in ipairs(slices) do
        s.from = start
        s.share = s.gold / total
        start = start + s.share
        s.to = start
    end
    if slices[1] then slices[#slices].to = 1 end -- no gap from rounding
    -- the card stays on the same player across refreshes
    selected = nil
    for _, s in ipairs(slices) do if focus and s.name == focus then selected = s end end
    return list
end

local function SliceAt(frac)
    for _, s in ipairs(slices) do
        if frac >= s.from and frac < s.to then return s end
    end
end

---------------------------------------------------------------------------
-- Pie drawing: SEG thin wedges, rotated into place and tinted with their slice's colour
---------------------------------------------------------------------------
local function Rotate(t, angle)
    if t.SetRotation then
        t:SetRotation(angle)
        return
    end
    -- older clients: rotate the texture coordinates around the centre instead
    local c, s = math.cos(angle), math.sin(angle)
    local function p(x, y) -- texture space point after rotating by -angle around (0.5, 0.5)
        x, y = x - 0.5, y - 0.5
        return 0.5 + x * c - y * s, 0.5 + x * s + y * c
    end
    local ulx, uly = p(0, 0)
    local llx, lly = p(0, 1)
    local urx, ury = p(1, 0)
    local lrx, lry = p(1, 1)
    t:SetTexCoord(ulx, uly, llx, lly, urx, ury, lrx, lry)
end

local function Shade(color, lift)
    return color[1] + (1 - color[1]) * lift, color[2] + (1 - color[2]) * lift, color[3] + (1 - color[3]) * lift
end

local function PaintPie()
    for i, t in ipairs(pie.wedges) do
        local s = slices[1] and SliceAt((i - 0.5) / SEG)
        if s then
            local lift = (s == hovered and 0.35) or (s == selected and 0.2) or 0
            local dim = selected and s ~= selected and s ~= hovered and 0.55 or 1
            local r, g, b = Shade(s.color, lift)
            t:SetVertexColor(r * dim, g * dim, b * dim, 1)
            t:Show()
        else
            t:Hide()
        end
    end
end

--- The slice under the cursor, or nil (outside the ring, or in the hole).
local function SliceUnderCursor()
    local x, y = GetCursorPosition()
    local scale = pie:GetEffectiveScale()
    local cx, cy = pie:GetCenter()
    if not (x and cx) then return nil end
    local dx, dy = x / scale - cx, y / scale - cy
    local r = math.sqrt(dx * dx + dy * dy)
    if r > D / 2 or r < D * HOLE / 2 then return nil end
    local angle = math.atan2(dx, dy) -- clockwise from 12 o'clock
    if angle < 0 then angle = angle + 2 * math.pi end
    return SliceAt(angle / (2 * math.pi))
end

---------------------------------------------------------------------------
-- The card
---------------------------------------------------------------------------
local function SetRows(rows)
    for i, row in ipairs(card.rows) do
        local r = rows[i]
        if r then
            row.label:SetText(("|cff%s%s|r"):format(r[2] and "bbbbbb" or "ffd100", r[1])) -- no value: a section title
            row.value:SetText(r[2] or "")
            row.label:Show() row.value:Show()
        else
            row.label:Hide() row.value:Hide()
        end
    end
end

local function RankOf(name, list)
    for i, e in ipairs(list) do if e.name == name then return i end end
end

local function ShowOthers(s)
    card.name:SetText(("|cffbbbbbbOthers|r  (%d)"):format(#s.others))
    card.sub:SetText(("%s, %.1f%% of the guild's gold"):format(Gold(s.gold), s.share * 100))
    card.where:SetText("Click a name for their card.")
    local rows = {}
    for _, e in ipairs(s.others) do
        rows[#rows + 1] = { ("|cff%s%s|r"):format(ClassColor(e.class), ns.Short(e.name)), Gold(e.gold), name = e.name }
    end
    SetRows(rows)
    for i, row in ipairs(card.rows) do row.target = rows[i] and rows[i].name or nil end
    card.footer:SetText("")
end

local function ShowPlayer(name, list)
    local e
    for _, x in ipairs(list) do if x.name == name then e = x end end
    if not e then return end
    for _, row in ipairs(card.rows) do row.target = nil end
    local me = ns.IsMe(name)
    local race = e.race and (RACE_NAMES[e.race] or e.race) or ""
    local class = e.class and (CLASS_NAMES[e.class] or e.class) or ""
    card.name:SetText(("|cff%s%s|r"):format(ClassColor(e.class), ns.Short(name)))
    card.sub:SetText((("Level %d %s %s"):format(e.level or 0, race, class):gsub("%s+$", "")))
    local r = Roster(name)
    if r then
        local where = r.online and ("|cff20ff20online|r" .. ((r.zone and r.zone ~= "") and (" in " .. r.zone) or ""))
            or ("|cff888888last online " .. (r.last or "?") .. "|r")
        card.where:SetText((r.rank and (r.rank .. "  ·  ") or "") .. where)
    else
        card.where:SetText("")
    end

    local b = ns.Board.Table()[name] or {}
    local games = (b.wins or 0) + (b.losses or 0)
    local rows = {
        { "Wealth" },
        { "Wallet", "|cffffffff" .. ns.Money(e.gold) .. "|r" },
        { "Share", total > 0 and ("%.1f%% of the guild  (#%d of %d)"):format(e.gold / total * 100,
            RankOf(name, list) or 0, #list) or "-" },
        { (e.days or 0) >= 7 and "Last 7 days" or (e.days or 0) > 0 and ("Last %d day%s"):format(e.days, e.days == 1 and "" or "s")
            or "Last 7 days", (e.days or 0) > 0 and Signed(e.change) or "|cff888888tracking from today|r" },
        { "Most ever held", Gold(e.peak) },
        { "PvP" },
        { "Honorable kills", tostring(e.hk or 0) },
        { "Dishonorable kills", tostring(e.dk or 0) },
        { "GuildGambit" },
        { "Net", Signed(b.net or 0) },
        { "Record", games > 0 and ("%dW %dL  (%d%% win rate)"):format(b.wins or 0, b.losses or 0,
            math.floor((b.wins or 0) / games * 100 + 0.5)) or "|cff888888no games yet|r" },
        { "Wagered", Gold(b.wagered or 0) },
        { "Streak", ("%s  (longest: %d win%s)"):format(
            (b.streak or 0) > 0 and ("|cff20ff20%d won|r"):format(b.streak)
            or (b.streak or 0) < 0 and ("|cffff4040%d lost|r"):format(-b.streak) or "-", e.longest or 0, (e.longest or 0) == 1 and "" or "s") },
        { "Biggest win", (e.bestWin or 0) > 0 and (Signed(e.bestWin) .. "  " .. Day(e.bestWinAt)) or "-" },
        { "Biggest loss", (e.worstLoss or 0) < 0 and (Signed(e.worstLoss) .. "  " .. Day(e.worstLossAt)) or "-" },
        { "Biggest drop", (b.drop or 0) > 0 and ("rolled a 1 from 1-" .. b.drop) or "-" },
        { "Nemesis", e.nemesis and (ns.Short(e.nemesis) .. "  " .. Signed(-(e.nemesisNet or 0))) or "-" },
        { "Victim", e.victim and (ns.Short(e.victim) .. "  " .. Signed(e.victimNet or 0)) or "-" },
        { "Kodo best", (b.arcade or 0) > 0 and tostring(b.arcade) or "-" },
    }
    if not me then
        local bal = ns.Ledger.Balance(name)
        rows[#rows + 1] = { "Between you", bal > 0 and ("|cff20ff20owes you " .. ns.Money(bal) .. "|r")
            or bal < 0 and ("|cffff4040you owe " .. ns.Money(-bal) .. "|r") or "all square" }
    end
    SetRows(rows)
    card.footer:SetText(me and "|cff888888This is you.|r" or ("|cff888888Updated " .. Ago(e.seen) .. "|r"))
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------
function WUI.Refresh()
    if not frame or not frame:IsShown() then return end
    if not focus then focus = ns.Me() end -- start on yourself
    local list = BuildSlices()
    local known = selected ~= nil
    for _, e in ipairs(list) do if e.name == focus then known = true end end
    if not known then
        focus = slices[1] and slices[1].name or nil
        BuildSlices()
    end
    PaintPie()
    pie.total:SetText(slices[1] and Gold(total) or "-")
    pie.count:SetText(("%d player%s"):format(#list, #list == 1 and "" or "s"))
    pie.empty:SetShown(not slices[1])
    for i, row in ipairs(frame.legend) do
        local s = slices[i]
        if s and i <= LEGEND then
            row.slice = s
            row.swatch:SetVertexColor(s.color[1], s.color[2], s.color[3], 1)
            local name = s.others and ("Others (%d)"):format(#s.others) or ns.Short(s.name)
            row.text:SetText(((s == selected) and "|cffffffff" or "|cffcccccc") .. name .. "|r")
            row.value:SetText(("%s  |cff888888%d%%|r"):format(Gold(s.gold), math.floor(s.share * 100 + 0.5)))
            row:Show()
        else
            row:Hide()
        end
    end
    if selected and selected.others then ShowOthers(selected)
    elseif focus then ShowPlayer(focus, list) -- (also players inside "Others")
    else
        card.name:SetText("|cff888888Nobody yet|r")
        card.sub:SetText("") card.where:SetText("") card.footer:SetText("")
        SetRows({})
    end
end

local function Select(s)
    focus = s.name
    WUI.Refresh()
end

--- Shows one player's card (from the Others list, a slash command, or a test).
function WUI.ShowPlayer(name)
    focus = ns.Full(name)
    WUI.SetShown(true)
end

---------------------------------------------------------------------------
-- Building
---------------------------------------------------------------------------
local function BuildPie(parent)
    pie = CreateFrame("Frame", nil, parent)
    pie:SetSize(D, D)
    pie:SetPoint("TOPLEFT", 26, -50)
    pie:EnableMouse(true)
    pie.wedges = {}
    for i = 1, SEG do
        local t = pie:CreateTexture(nil, "ARTWORK")
        t:SetTexture(Art.Tex("pie/wedge"))
        t:SetSize(D, D)
        t:SetPoint("CENTER")
        Rotate(t, -((i - 0.5) / SEG) * 2 * math.pi) -- SetRotation turns anticlockwise
        pie.wedges[i] = t
    end
    local ring = pie:CreateTexture(nil, "OVERLAY")
    ring:SetTexture(Art.Tex("pie/ring"))
    ring:SetSize(D + 8, D + 8)
    ring:SetPoint("CENTER")
    local hole = pie:CreateTexture(nil, "OVERLAY")
    hole:SetTexture(Art.Tex("pie/hole"))
    hole:SetSize(D * HOLE, D * HOLE)
    hole:SetPoint("CENTER")
    local cap = Label(pie, "Guild gold", "GameFontNormalSmall")
    cap:SetPoint("CENTER", 0, 16)
    pie.total = Label(pie, "", "GameFontHighlightLarge")
    pie.total:SetPoint("CENTER", 0, 0)
    pie.count = Label(pie, "", "GameFontDisableSmall")
    pie.count:SetPoint("CENTER", 0, -16)
    pie.empty = Label(pie, "No numbers yet - guildies'\naddons answer within a few seconds.", "GameFontDisableSmall")
    pie.empty:SetPoint("TOP", pie, "BOTTOM", 0, -10)
    pie.empty:SetJustifyH("CENTER")

    pie:SetScript("OnUpdate", function(self)
        local over = self.mouseIn and SliceUnderCursor() or nil
        if over == hovered then return end
        hovered = over
        PaintPie()
        if over then
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:ClearLines()
            GameTooltip:AddLine(over.others and ("Others (%d)"):format(#over.others) or ns.Short(over.name))
            GameTooltip:AddDoubleLine(ns.Money(over.gold), ("%.1f%%"):format(over.share * 100), 1, 1, 1, 0.7, 0.7, 0.7)
            GameTooltip:Show()
        else
            GameTooltip:Hide()
        end
    end)
    pie:SetScript("OnEnter", function(self) self.mouseIn = true end)
    pie:SetScript("OnLeave", function(self)
        self.mouseIn = false
        hovered = nil
        GameTooltip:Hide()
        PaintPie()
    end)
    pie:SetScript("OnMouseUp", function()
        local s = SliceUnderCursor()
        if s then Select(s) end
    end)
end

local function BuildLegend(parent)
    frame.legend = {}
    for i = 1, LEGEND do
        local row = CreateFrame("Button", nil, parent)
        row:SetSize(D + 20, 15)
        row:SetPoint("TOPLEFT", 18, -50 - D - 16 - (i - 1) * 15)
        row.swatch = row:CreateTexture(nil, "ARTWORK")
        row.swatch:SetTexture("Interface\\Buttons\\WHITE8X8")
        row.swatch:SetSize(10, 10)
        row.swatch:SetPoint("LEFT", 4, 0)
        row.text = Label(row, "")
        row.text:SetPoint("LEFT", 20, 0)
        row.value = Label(row, "")
        row.value:SetPoint("RIGHT", -2, 0)
        row.value:SetJustifyH("RIGHT")
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row:SetScript("OnClick", function(self) if self.slice then Select(self.slice) end end)
        frame.legend[i] = row
    end
end

local function BuildCard(parent)
    card = CreateFrame("Frame", nil, parent)
    card:SetPoint("TOPLEFT", D + 56, -44)
    card:SetPoint("BOTTOMRIGHT", -20, 18)
    card.name = Label(card, "", "GameFontNormalLarge")
    card.name:SetPoint("TOPLEFT", 0, 0)
    card.sub = Label(card, "", "GameFontHighlightSmall")
    card.sub:SetPoint("TOPLEFT", 0, -20)
    card.where = Label(card, "", "GameFontHighlightSmall")
    card.where:SetPoint("TOPLEFT", 0, -34)
    card.where:SetWidth(W - D - 80)
    card.where:SetWordWrap(false)
    card.rows = {}
    for i = 1, ROWS do
        local y = -54 - (i - 1) * 15
        local row = CreateFrame("Button", nil, card)
        row:SetSize(W - D - 80, 15)
        row:SetPoint("TOPLEFT", 0, y)
        row.label = Label(row, "")
        row.label:SetPoint("LEFT", 0, 0)
        row.value = Label(row, "")
        row.value:SetPoint("LEFT", 112, 0)
        row.value:SetWidth(W - D - 80 - 112)
        row.value:SetWordWrap(false)
        row:SetScript("OnClick", function(self) if self.target then WUI.ShowPlayer(self.target) end end)
        card.rows[i] = row
    end
    card.footer = Label(card, "", "GameFontDisableSmall")
    card.footer:SetPoint("BOTTOMLEFT", 0, 0)
end

local function Build()
    if frame then return frame end
    frame = CreateFrame("Frame", "GuildGambitWealthFrame", UIParent, "BackdropTemplate")
    frame:SetSize(W, H)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetBackdrop({
        bgFile = Art.GAME.dialogBg, edgeFile = Art.GAME.dialogBorder,
        tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        ns.db.wealthWindow = { point = point, x = x, y = y }
    end)
    frame:SetScript("OnShow", function()
        ns.Wealth.Ask() -- fresh numbers from everyone's addon
        WUI.Refresh()
    end)
    frame:Hide()
    tinsert(UISpecialFrames, "GuildGambitWealthFrame")

    local header = frame:CreateTexture(nil, "ARTWORK")
    header:SetTexture(Art.GAME.dialogHeader)
    header:SetSize(320, 64)
    header:SetPoint("TOP", 0, 12)
    local title = Label(frame, "Guild Wealth", "GameFontNormal")
    title:SetPoint("TOP", header, "TOP", 0, -14)
    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() frame:Hide() end)

    BuildPie(frame)
    BuildLegend(frame)
    BuildCard(frame)

    local saved = ns.db.wealthWindow
    if saved and saved.point then
        frame:SetPoint(saved.point, UIParent, saved.point, saved.x, saved.y)
    elseif ns.UI.Frame() then
        frame:SetPoint("TOPLEFT", ns.UI.Frame(), "TOPRIGHT", 36, 0)
    else
        frame:SetPoint("CENTER")
    end
    return frame
end

function WUI.SetShown(shown)
    local ok, err = pcall(Build)
    if not ok then
        ns.Print("|cffff4040The wealth window failed to build: %s|r", tostring(err))
        return
    end
    frame:SetShown(shown)
    if shown then WUI.Refresh() end
end

function WUI.Toggle() WUI.SetShown(not (frame and frame:IsShown())) end
function WUI.Frame() return frame end
function WUI.Pie() return pie end
function WUI.Card() return card end
function WUI.Slices() return slices, total end
function WUI.Selected() return selected end

---------------------------------------------------------------------------
-- The coin tab on the main window's right edge (like the spellbook's side tabs)
---------------------------------------------------------------------------
function WUI.Attach(main)
    if WUI.tab then return WUI.tab end
    local b = CreateFrame("Button", nil, main)
    b:SetSize(32, 32)
    b:SetPoint("TOPLEFT", main, "TOPRIGHT", -4, -70)
    local back = b:CreateTexture(nil, "BACKGROUND")
    back:SetTexture("Interface\\SpellBook\\SpellBook-SkillLineTab")
    back:SetSize(64, 64)
    back:SetPoint("TOPLEFT", -3, 11)
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02")
    icon:SetAllPoints()
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:SetScript("OnClick", function() WUI.Toggle() end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine("Guild Wealth")
        GameTooltip:AddLine("Who holds the guild's gold, and their stats.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    WUI.tab = b
    return b
end
