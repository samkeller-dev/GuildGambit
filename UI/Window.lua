-- UI/Window.lua: the GuildGambit window. Everything here is also reachable by /gg commands,
-- so a broken layout never blocks a game.
-- Skin: Blizzard's gold dialog border and header (game textures). Cards, reels and frames: our
-- art in Media/, with the game's portrait icons and elite dragon frames layered on top.
local ADDON_NAME, ns = ...
local Art = ns.Art

local UI = {}
ns.UI = UI

local W, H = 470, 690
local frame, panels, tabs = nil, {}, {}
local prompt -- { lo, hi, label } or nil

---------------------------------------------------------------------------
-- Small builders
---------------------------------------------------------------------------
local function Button(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 90, 22)
    b:SetText(text)
    b:SetScript("OnClick", function(...)
        UI.ReleaseFocus()
        return onClick(...)
    end)
    return b
end

local function Label(parent, text, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    fs:SetText(text or "")
    fs:SetJustifyH("LEFT")
    return fs
end

local inputs = {} -- every edit box, so clicks elsewhere can release keyboard focus

--- Releases keyboard focus from our edit boxes, so action-bar keys go back to the game.
--- (A Bet box that kept focus once turned "1" key presses into a 1,111,111,111g bet.)
function UI.ReleaseFocus()
    for _, e in ipairs(inputs) do e:ClearFocus() end
end

local function Input(parent, width, default, numeric, maxLetters)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(width, 20)
    e:SetAutoFocus(false)
    if numeric then e:SetNumeric(true) end
    if maxLetters then e:SetMaxLetters(maxLetters) end
    e:SetText(default or "")
    e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    inputs[#inputs + 1] = e
    return e
end

local function Panel(name)
    local p = CreateFrame("Frame", nil, frame)
    p:SetPoint("TOPLEFT", 18, -70)
    p:SetPoint("BOTTOMRIGHT", -18, 100)
    p:Hide()
    panels[name] = p
    return p
end

local function Tex(parent, layer, path, w, h)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    if path then t:SetTexture(path) end
    if w then t:SetSize(w, h or w) end
    return t
end

---------------------------------------------------------------------------
-- Play: controls, the game table and actions
---------------------------------------------------------------------------
local REEL = 64

local function BuildTable(p, y)
    y = y or -92
    local t = CreateFrame("Frame", nil, p, "BackdropTemplate")
    t:SetPoint("TOPLEFT", 0, y)
    t:SetPoint("TOPRIGHT", 0, y)
    t:SetHeight(330)
    t:SetBackdrop({
        bgFile = Art.GAME.marble, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 128, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    t:SetBackdropColor(0.35, 0.3, 0.25, 1)
    t:SetBackdropBorderColor(0.9, 0.72, 0.3, 1)
    p.table = t

    -- idle
    t.idle = CreateFrame("Frame", nil, t)
    t.idle:SetAllPoints()
    local logo = Tex(t.idle, "ARTWORK", Art.Tex("icons/addon"), 72)
    logo:SetPoint("CENTER", 0, 20)
    local hint = Label(t.idle, "Pick a game above - or type \"practice\" to play solo.", "GameFontNormal")
    hint:SetPoint("TOP", logo, "BOTTOM", 0, -10)

    -- blackjack
    t.bj = CreateFrame("Frame", nil, t)
    t.bj:SetAllPoints()
    t.bj.dealerLabel = Label(t.bj, "Dealer", "GameFontNormal")
    t.bj.dealerLabel:SetPoint("TOPLEFT", 12, -10)
    t.bj.dealer = ns.Cards.CreateRow(t.bj, 80, 6)
    t.bj.dealer:SetPoint("TOPLEFT", 12, -28)
    t.bj.playerLabel = Label(t.bj, "You", "GameFontNormal")
    t.bj.playerLabel:SetPoint("TOPLEFT", 12, -152)
    t.bj.player = ns.Cards.CreateRow(t.bj, 80, 6)
    t.bj.player:SetPoint("TOPLEFT", 12, -170)

    -- slots: your three reels (bottom) and your opponent's (top), each in gold rings
    t.slots = CreateFrame("Frame", nil, t)
    t.slots:SetAllPoints()
    local function ReelRow(y)
        local row = {}
        for i = 1, 3 do
            local ring = Tex(t.slots, "OVERLAY", Art.Tex("frames/ring_gold"), REEL / Art.RING.d)
            local icon = Tex(t.slots, "ARTWORK", nil, REEL)
            icon:SetPoint("CENTER", t.slots, "CENTER", (i - 2) * (REEL + 52), y)
            ring:SetPoint("TOPLEFT", icon, "CENTER", -Art.RING.cx * ring:GetWidth(), Art.RING.cy * ring:GetHeight())
            row.rings = row.rings or {}
            row.rings[i] = ring
            row[i] = icon
        end
        return row
    end
    t.slots.theirReels = ReelRow(110)
    t.slots.theirLabel = Label(t.slots, "", "GameFontNormal")
    t.slots.theirLabel:SetPoint("TOP", 0, -6)
    t.slots.theirLabel:SetJustifyH("CENTER")
    t.slots.reels = ReelRow(12)
    t.slots.result = Label(t.slots, "", "GameFontNormal")
    t.slots.result:SetPoint("CENTER", 0, -36)
    t.slots.result:SetJustifyH("CENTER")

    -- paytable legend: every winning line with its reels and multiplier
    local legend = CreateFrame("Frame", nil, t.slots)
    legend:SetPoint("BOTTOMLEFT", 10, 8)
    legend:SetPoint("BOTTOMRIGHT", -10, 8)
    legend:SetHeight(96)
    local title = Label(legend, "|cffffd100Pays (times your bet)|r", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 0, 0)
    local ICON, ROW = 18, 19
    for n, line in ipairs(ns.Rules.Slots.PAYTABLE) do
        local col, row = (n - 1) % 2, math.floor((n - 1) / 2)
        local x, y = col * 210, -16 - row * ROW
        for k, sym in ipairs(line.icons) do
            local ic = Tex(legend, "ARTWORK", Art.Tex("icons/" .. sym:lower()), ICON)
            ic:SetPoint("TOPLEFT", x + (k - 1) * (ICON + 2), y)
        end
        local text = Label(legend, ("|cffffffffx%d|r  %s%s"):format(line.mult, line.name,
            #line.icons < 3 and " (any spot)" or ""), "GameFontHighlightSmall")
        text:SetPoint("TOPLEFT", x + 3 * (ICON + 2) + 4, y - 3)
    end
    local nothing = Label(legend, "|cff888888Anything else pays nothing.|r", "GameFontHighlightSmall")
    nothing:SetPoint("TOPLEFT", 210, -16 - 3 * ROW - 3)

    -- deathroll: only the latest roll, big in the middle. It pops in with a gold flash, is
    -- coloured by how close to 1 it is, and a skull behind it grows (and pulses) as the
    -- range shrinks.
    local dr = CreateFrame("Frame", nil, t)
    t.dr = dr
    dr:SetAllPoints()
    dr.skull = Tex(dr, "BACKGROUND", Art.Tex("icons/skull"), 230)
    dr.skull:SetPoint("CENTER", 0, 4)
    dr.skull:SetAlpha(0.1)
    dr.glow = Tex(dr, "BORDER", Art.Tex("icons/glow"), 280)
    dr.glow:SetPoint("CENTER", 0, 8)
    dr.glow:SetAlpha(0)

    dr.who = Label(dr, "", "GameFontNormalLarge")
    dr.who:SetPoint("TOP", 0, -24)
    dr.who:SetJustifyH("CENTER")

    dr.holder = CreateFrame("Frame", nil, dr)
    dr.holder:SetSize(320, 120)
    dr.holder:SetPoint("CENTER", 0, 8)
    dr.number = dr.holder:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    pcall(dr.number.SetFont, dr.number, "Fonts\\FRIZQT__.TTF", 88, "THICKOUTLINE")
    dr.number:SetPoint("CENTER")
    dr.number:SetJustifyH("CENTER")

    dr.outof = Label(dr, "", "GameFontHighlight")
    dr.outof:SetPoint("TOP", dr.holder, "BOTTOM", 0, 6)
    dr.outof:SetJustifyH("CENTER")
    dr.next = Label(dr, "", "GameFontNormalLarge")
    dr.next:SetPoint("BOTTOM", 0, 24)
    dr.next:SetJustifyH("CENTER")

    -- pop: the number slams in from big to normal size
    dr.pop = dr.holder:CreateAnimationGroup()
    local grow = dr.pop:CreateAnimation("Scale")
    if grow.SetScaleFrom then grow:SetScaleFrom(2.2, 2.2) grow:SetScaleTo(1, 1)
    else grow:SetFromScale(2.2, 2.2) grow:SetToScale(1, 1) end
    grow:SetDuration(0.3)
    grow:SetOrigin("CENTER", 0, 0)
    if grow.SetSmoothing then grow:SetSmoothing("OUT") end
    local fadeIn = dr.pop:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(0.12)

    -- flash: a gold burst behind it that fades out
    dr.flash = dr.glow:CreateAnimationGroup()
    local burst = dr.flash:CreateAnimation("Alpha")
    burst:SetFromAlpha(0.95)
    burst:SetToAlpha(0)
    burst:SetDuration(0.8)
    if burst.SetSmoothing then burst:SetSmoothing("OUT") end

    -- tension: the skull pulses once the range is down to 20 or less
    dr.shown, dr.pulse, dr.pulseT, dr.skullAlpha = "", false, 0, 0.1
    dr:SetScript("OnUpdate", function(self, elapsed)
        if not self.pulse then return end
        self.pulseT = (self.pulseT or 0) + elapsed
        self.skull:SetAlpha(self.skullAlpha + 0.18 * (0.5 + 0.5 * math.sin(self.pulseT * 7)))
    end)
end

-- Coinflip: the game's Alliance / Horde banner icons on our gold coin ring. When the result
-- lands the coin spins (swapping faces) for a moment, then settles on the winning side.
local COIN_SPIN = 1.2

local function BuildCoin(t)
    local cf = CreateFrame("Frame", nil, t)
    t.cf = cf
    cf:SetAllPoints()
    cf.heads = Label(cf, "", "GameFontNormal")
    cf.heads:SetPoint("TOPLEFT", 14, -12)
    cf.tails = Label(cf, "", "GameFontNormal")
    cf.tails:SetPoint("TOPRIGHT", -14, -12)
    cf.tails:SetJustifyH("RIGHT")
    cf.coin = Art.CreatePortrait(cf, 130)
    cf.coin:SetPoint("CENTER", 0, 14)
    cf.result = Label(cf, "", "GameFontNormalLarge")
    cf.result:SetPoint("BOTTOM", 0, 40)
    cf.result:SetJustifyH("CENTER")
    cf.sub = Label(cf, "", "GameFontHighlight")
    cf.sub:SetPoint("BOTTOM", 0, 18)
    cf.sub:SetJustifyH("CENTER")
    cf.shown, cf.spinUntil, cf.spinT, cf.final, cf.finalText, cf.game = "", 0, 0, "A", "", false
    cf:SetScript("OnUpdate", function(self, elapsed)
        if self.spinUntil <= 0 then return end
        self.spinT = self.spinT + elapsed
        if GetTime() < self.spinUntil then
            -- swap faces and squash, like a coin turning over
            local face = math.floor(self.spinT * 12) % 2 == 0 and "A" or "H"
            self.coin.icon:SetTexture(ns.Coinflip.SIDES[face].icon)
            self.coin:SetScale(0.55 + 0.45 * math.abs(math.cos(self.spinT * 18)))
        else
            self.spinUntil = 0
            self.coin:SetScale(1)
            Art.SetPortrait(self.coin, ns.Coinflip.SIDES[self.final].icon, "ring_gold")
            self.result:SetText(self.finalText)
            -- read the amount now: the game is settled by the time the coin lands
            local g = self.game
            self.sub:SetText(g and g.net and ns.ResultText(g.net, g.outcome) or "")
        end
    end)
    return cf
end

local function RefreshCoin(cf, game)
    local CF = ns.Coinflip
    local function who(c)
        local n = (c == game.call) and game.a or game.b
        return ns.IsMe(n) and "You" or ns.Short(n)
    end
    cf.heads:SetText("|cff4aa3ffHeads - Alliance|r\n" .. who("A"))
    cf.tails:SetText("|cffff4040Tails - Horde|r\n" .. who("H"))
    if not game.landed then
        Art.SetPortrait(cf.coin, CF.SIDES[game.call].icon, "ring_gold")
        cf.coin:SetScale(1)
        cf.result:SetText(game.status or "Flipping...")
        cf.sub:SetText(game.bet > 0 and ("%s on the line"):format(ns.Money(game.bet)) or "Just for fun")
        return
    end
    if cf.shown ~= game.id then
        -- a fresh result: spin first, then reveal
        cf.shown = game.id
        cf.final = game.landed
        local winner = who(game.landed)
        cf.finalText = ("%s - %s %s!"):format(CF.Label(game.landed), winner, winner == "You" and "win" or "wins")
        cf.game = game
        cf.result:SetText("")
        cf.sub:SetText("")
        cf.spinT, cf.spinUntil = 0, GetTime() + COIN_SPIN
    end
end

--- Colour and skull visibility for a roll: gold far from 1, through orange, to blood red.
local function Danger(v)
    if v <= 1 then return 0.85, 0.05, 0.05, 0.6 end
    if v <= 9 then return 1, 0.15, 0.1, 0.38 end
    if v <= 49 then return 1, 0.38, 0.1, 0.26 end
    if v <= 199 then return 1, 0.6, 0.15, 0.17 end
    return 1, 0.84, 0.25, 0.1
end

local function RefreshDeathroll(dr, game)
    local lr = game.lastRoll
    local function rollerName(n) return ns.IsMe(n) and "You" or ns.Short(n) end
    if not lr then
        dr.who:SetText(("Deathroll for %s"):format(ns.Stake(game.stake)))
        dr.number:SetText("?")
        dr.number:SetTextColor(1, 0.84, 0.25)
        dr.outof:SetText(("1 - %d"):format(game.start))
        dr.next:SetText(ns.IsMe(game.turn) and ("|cffffd100Your roll: 1 - %d|r"):format(game.start)
            or ("%s rolls first: 1 - %d"):format(ns.Short(game.turn), game.start))
        dr.skull:SetAlpha(0.1)
        dr.pulse = false
        return
    end
    local r, g, b, skullAlpha = Danger(lr.value)
    dr.who:SetText(rollerName(lr.who) .. " rolled")
    dr.number:SetText(tostring(lr.value))
    dr.number:SetTextColor(r, g, b)
    dr.outof:SetText(("out of %d"):format(lr.max))
    if game.finished then
        local loser = ns.IsMe(lr.who) and "You lose" or (ns.Short(lr.who) .. " loses")
        dr.next:SetText(("|cffff2020DEATHROLLED!|r  %s%s"):format(loser,
            game.stake > 0 and (" " .. ns.Money(game.stake)) or ""))
        dr.pulse = false
        dr.skull:SetAlpha(skullAlpha)
    else
        dr.next:SetText(ns.IsMe(game.turn) and ("|cffffd100Your roll: 1 - %d|r"):format(game.max)
            or ("%s's roll: 1 - %d"):format(ns.Short(game.turn), game.max))
        dr.skullAlpha = skullAlpha
        dr.pulse = lr.value <= 20
        if not dr.pulse then dr.skull:SetAlpha(skullAlpha) end
    end
    -- a new roll: replay the pop and the flash
    local stamp = game.id .. ":" .. lr.seq
    if dr.shown ~= stamp then
        dr.shown = stamp
        dr.pop:Stop()
        dr.pop:Play()
        dr.flash:Stop()
        dr.flash:Play()
    end
end

--- Group deathroll: the same big number, with everyone's names along the top
--- (whose turn in gold, knocked-out players greyed out).
local function RefreshGroup(dr, game)
    if not rawget(dr, "roster") then
        dr.roster = Label(dr, "", "GameFontHighlightSmall")
        dr.roster:SetPoint("TOP", 0, -46)
        dr.roster:SetWidth(W - 70)
        dr.roster:SetJustifyH("CENTER")
    end
    local out = {}
    for _, n in ipairs(game.out or {}) do out[n] = true end
    local names = {}
    for _, n in ipairs(game.players) do
        local label = ns.IsMe(n) and "You" or ns.Short(n)
        if out[n] then label = "|cff666666" .. label .. " (out)|r"
        elseif game.winner and ns.SameName(game.winner, n) then label = "|cff20ff20" .. label .. " (winner)|r"
        elseif game.turn and ns.SameName(game.turn, n) then label = "|cffffd100> " .. label .. "|r" end
        names[#names + 1] = label
    end
    dr.roster:SetText(table.concat(names, "   "))
    local each = ns.Stake(game.bet) .. (game.bet > 0 and " each" or "")
    if game.state == "lobby" then
        dr.who:SetText(("Group deathroll for %s"):format(each))
        dr.number:SetText(tostring(#game.players))
        dr.number:SetTextColor(1, 0.84, 0.25)
        dr.outof:SetText(("player%s in the room  -  1 - %d"):format(#game.players == 1 and "" or "s", game.start))
        dr.next:SetText(ns.IsMe(game.host) and "|cffffd100Press Start when everyone's in|r"
            or ("Waiting for %s to start"):format(ns.Short(game.host)))
        dr.skull:SetAlpha(0.1)
        dr.pulse = false
        return
    end
    -- reuse the 1v1 view for the number, colours and animations
    game.stake = game.bet
    RefreshDeathroll(dr, game)
    local lr = game.lastRoll
    if game.finished then
        local pot = game.bet * (#game.players - 1)
        dr.next:SetText(ns.IsMe(game.winner) and ("|cff20ff20Last one standing - you win%s!|r"):format(
            pot > 0 and (" " .. ns.Money(pot)) or "")
            or ("|cffff2020DEATHROLLED!|r  %s %s the last one standing"):format(ns.Short(game.winner or "?"), "is"))
    elseif not lr then
        dr.who:SetText(("Group deathroll for %s"):format(each))
    elseif lr.value == 1 then
        dr.next:SetText(("|cffff2020%s out!|r  %s"):format(ns.IsMe(lr.who) and "You're" or (ns.Short(lr.who) .. " is"),
            ns.IsMe(game.turn) and ("|cffffd100Your roll: 1 - %d|r"):format(game.max)
            or ("%s rolls 1 - %d"):format(ns.Short(game.turn or "?"), game.max)))
    end
end

---------------------------------------------------------------------------
-- Opponent picker: guildies online with GuildGambit, plus practice
---------------------------------------------------------------------------
local PICK_ROWS, PICK_ROW_H = 10, 20
local ARROW = " |TInterface\\Buttons\\Arrow-Down-Up:14:14|t"

local function PickerEntries()
    local list = {
        { label = "|cffaaaaaaPractice (solo)|r", value = "practice" },
    }
    -- guild members only, and only ones whose addon we can play with
    local peers = ns.House.OnlinePeers()
    for _, peer in ipairs(peers) do
        if peer.status == "ok" then
            local extra = ns.House.IsNewer(ns.version, peer.version) and "  |cffaaaaaa(older version)|r" or ""
            list[#list + 1] = { label = ns.Short(peer.name) .. extra, value = peer.name }
        elseif peer.status == "outdated" then
            list[#list + 1] = { label = ("|cff888888%s|r  |cffff4040(outdated v%s - needs update)|r"):format(
                ns.Short(peer.name), peer.version or "?"), value = peer.name, disabled = true, outdated = true }
        elseif peer.status == "newer" then
            list[#list + 1] = { label = ("|cff888888%s|r  |cffff4040(has v%s - update yours)|r"):format(
                ns.Short(peer.name), peer.version or "?"), value = peer.name, disabled = true, outdated = true }
        else
            ns.House.AskVersion(peer.name) -- haven't heard their version yet: ask
            list[#list + 1] = { label = ("|cff888888%s  (checking version...)|r"):format(ns.Short(peer.name)),
                value = peer.name, disabled = true }
        end
    end
    if #peers == 0 then
        list[#list + 1] = { label = "|cff888888No guild members with GuildGambit online|r", disabled = true }
    end
    return list
end

local function BuildPicker(p)
    local who = Label(p, "Opponent:")
    who:SetPoint("TOPLEFT", 0, -4)
    p.pick = Button(p, "Choose an opponent" .. ARROW, 240, function()
        if p.pickList:IsShown() then p.pickList:Hide() return end
        ns.Guild.Request() -- fresh online status
        UI.FillPicker(p)
        p.pickList:Show()
    end)
    p.pick:SetPoint("LEFT", who, "RIGHT", 10, 0)

    local list = CreateFrame("Frame", nil, p, "BackdropTemplate")
    list:SetPoint("TOPLEFT", p.pick, "BOTTOMLEFT", 0, -2)
    list:SetSize(300, PICK_ROWS * PICK_ROW_H + 12)
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    list:SetBackdrop({
        bgFile = Art.GAME.dialogBg, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 32, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    list:SetBackdropBorderColor(0.9, 0.72, 0.3, 1)
    list:EnableMouse(true)
    list:Hide()
    list.rows = {}
    for i = 1, PICK_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetSize(288, PICK_ROW_H)
        row:SetPoint("TOPLEFT", 6, -6 - (i - 1) * PICK_ROW_H)
        row:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
        row.text = Label(row, "", "GameFontHighlight")
        row.text:SetPoint("LEFT", 4, 0)
        row:SetScript("OnClick", function(self)
            local e = self.entry
            if e and not e.disabled then UI.SetOpponent(p, e.value)
            elseif e and e.outdated then ns.House.WarnOutdated(e.value, true) end
            list:Hide()
        end)
        list.rows[i] = row
    end
    p.pickList = list
    p.selected = nil
end

function UI.FillPicker(p)
    local entries = PickerEntries()
    local list = p.pickList
    for i, row in ipairs(list.rows) do
        local e = entries[i]
        row.entry = e
        row:SetShown(e ~= nil)
        if e then row.text:SetText(e.label) end
    end
    list:SetHeight(math.min(#entries, PICK_ROWS) * PICK_ROW_H + 12)
end

--- value: a player name, "practice", or nil (nobody picked yet).
function UI.SetOpponent(p, value)
    p.selected = value
    local label = value == "practice" and "Practice (solo)" or (value and ns.Short(value)) or "Choose an opponent"
    p.pick:SetText(label .. ARROW)
end

local function BuildPlay(p)
    BuildPicker(p)

    local betLabel = Label(p, "Wager:")
    betLabel:SetPoint("TOPLEFT", 0, -36)
    -- gold, silver and copper boxes, each followed by the game's coin icon
    local function Coin(box, icon)
        local l = Label(p, ("|TInterface\\MoneyFrame\\UI-%sIcon:12:12|t"):format(icon))
        l:SetPoint("LEFT", box, "RIGHT", 2, 0)
        return l
    end
    p.bet = Input(p, 50, "10", true, 6)
    p.bet:SetPoint("LEFT", betLabel, "RIGHT", 8, 0)
    p.silver = Input(p, 22, "", true, 2)
    p.silver:SetPoint("LEFT", Coin(p.bet, "Gold"), "RIGHT", 8, 0)
    p.copper = Input(p, 22, "", true, 2)
    p.copper:SetPoint("LEFT", Coin(p.silver, "Silver"), "RIGHT", 8, 0)
    local copperIcon = Coin(p.copper, "Copper")
    local startLabel = Label(p, "Start:")
    startLabel:SetPoint("LEFT", copperIcon, "RIGHT", 12, 0)
    p.start = Input(p, 54, "1000", true, 7)
    p.start:SetPoint("LEFT", startLabel, "RIGHT", 8, 0)

    local function target() return p.selected end
    -- "10g5s0c": empty boxes count as 0 (all empty = a game just for fun)
    local function bet()
        local function n(box) local v = tonumber(box:GetText()) return v and math.floor(v) or 0 end
        return ("%dg%ds%dc"):format(n(p.bet), n(p.silver), n(p.copper))
    end

    p.dr = Button(p, "Deathroll", 82, function()
        local t = target()
        if not t and UnitExists("target") and UnitIsPlayer and UnitIsPlayer("target") then
            t = ns.Compat.Safe((UnitName("target")))
        end
        if not t then ns.Print("Pick an opponent (or Practice) from the list first.") return end
        ns.Deathroll.Challenge(t, bet(), p.start:GetText())
    end)
    p.dr:SetPoint("TOPLEFT", betLabel, "BOTTOMLEFT", 0, -12)
    p.kodo = Button(p, "Kodo", 82, function() ns.Kodo.Challenge(target(), bet()) end)
    p.kodo:SetPoint("LEFT", p.dr, "RIGHT", 6, 0)
    p.bj = Button(p, "Blackjack", 82, function() ns.Blackjack.Deal(target(), bet()) end)
    p.bj:SetPoint("LEFT", p.kodo, "RIGHT", 6, 0)
    p.cf = Button(p, "Coinflip", 82, function() ns.Coinflip.Challenge(target(), bet()) end)
    p.cf:SetPoint("LEFT", p.bj, "RIGHT", 6, 0)
    p.gdr = Button(p, "Group DR", 82, function() ns.GroupDeathroll.Open(bet(), p.start:GetText()) end)
    p.gdr:SetPoint("LEFT", p.cf, "RIGHT", 6, 0)

    BuildTable(p)

    p.status = Label(p, "", "GameFontNormal")
    p.status:SetPoint("TOPLEFT", p.table, "BOTTOMLEFT", 2, -8)
    p.status:SetWidth(W - 40)

    p.roll = Button(p, "Roll", 120, function()
        if prompt and prompt.action then prompt.action()
        elseif prompt then ns.Rolls.Roll(prompt.lo, prompt.hi) end
    end)
    p.roll:SetPoint("BOTTOMLEFT", 0, 0)
    p.stand = Button(p, "Stand", 80, function() ns.Blackjack.Stand(ns.Games.Mine()) end)
    p.stand:SetPoint("LEFT", p.roll, "RIGHT", 8, 0)
    p.double = Button(p, "Double", 80, function() ns.Blackjack.Double(ns.Games.Mine()) end)
    p.double:SetPoint("LEFT", p.stand, "RIGHT", 8, 0)
    p.cancel = Button(p, "Cancel", 80, function() ns.Games.Cancel(ns.Games.Mine()) end)
    p.cancel:SetPoint("LEFT", p.double, "RIGHT", 8, 0)
end

---------------------------------------------------------------------------
-- Ledger: who owes whom, payments
---------------------------------------------------------------------------
--- Who you can record a payment with: everyone you have an open balance with (biggest
--- first), then guildies online with GuildGambit.
local function LedgerEntries()
    local list, seen, online = {}, {}, {}
    for _, peer in ipairs(ns.House.OnlinePeers()) do online[peer.name:lower()] = true end
    local open = {}
    for name, bal in pairs(ns.Ledger.Balances()) do open[#open + 1] = { name = name, bal = bal } end
    table.sort(open, function(a, b) return math.abs(a.bal) > math.abs(b.bal) end)
    for _, o in ipairs(open) do
        seen[o.name:lower()] = true
        local owes = o.bal > 0 and ("|cff20ff20owes you " .. ns.Money(o.bal) .. "|r")
            or ("|cffff4040you owe " .. ns.Money(-o.bal) .. "|r")
        list[#list + 1] = { label = ("%s  %s%s"):format(ns.Short(o.name), owes,
            online[o.name:lower()] and "" or "  |cff888888(offline)|r"), value = o.name }
    end
    for _, peer in ipairs(ns.House.OnlinePeers()) do
        if not seen[peer.name:lower()] then
            list[#list + 1] = { label = ns.Short(peer.name) .. "  |cff888888(all square)|r", value = peer.name }
        end
    end
    if #list == 0 then list[1] = { label = "|cff888888Nobody to settle with yet|r", disabled = true } end
    return list
end

local LEDGER_PICK_ROWS = 8

local function BuildLedgerPicker(p, anchor)
    local function setLabel()
        local picked = rawget(p, "whoSelected")
        p.whoPick:SetText((picked and ns.Short(picked) or "Choose a player") .. ARROW)
    end
    p.whoPick = Button(p, "Choose a player" .. ARROW, 150, function()
        local list = p.whoList
        if list:IsShown() then list:Hide() return end
        ns.Guild.Request()
        local entries = LedgerEntries()
        for i, row in ipairs(list.rows) do
            local e = entries[i]
            row.entry = e
            row:SetShown(e ~= nil)
            if e then row.text:SetText(e.label) end
        end
        list:SetHeight(math.min(#entries, LEDGER_PICK_ROWS) * PICK_ROW_H + 12)
        list:Show()
    end)
    p.whoPick:SetPoint("LEFT", anchor, "RIGHT", 10, 0)
    -- the picker sits near the bottom of the window, so the list opens upwards
    local list = CreateFrame("Frame", nil, p, "BackdropTemplate")
    list:SetPoint("BOTTOMLEFT", p.whoPick, "TOPLEFT", 0, 2)
    list:SetSize(300, LEDGER_PICK_ROWS * PICK_ROW_H + 12)
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    list:SetBackdrop({
        bgFile = Art.GAME.dialogBg, edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 32, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    list:SetBackdropBorderColor(0.9, 0.72, 0.3, 1)
    list:EnableMouse(true)
    list:Hide()
    list.rows = {}
    for i = 1, LEDGER_PICK_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetSize(288, PICK_ROW_H)
        row:SetPoint("TOPLEFT", 6, -6 - (i - 1) * PICK_ROW_H)
        row:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight")
        row.text = Label(row, "", "GameFontHighlight")
        row.text:SetPoint("LEFT", 4, 0)
        row:SetScript("OnClick", function(self)
            local e = self.entry
            if e and not e.disabled then
                p.whoSelected = e.value
                setLabel()
            end
            list:Hide()
        end)
        list.rows[i] = row
    end
    p.whoList = list
    p.whoSelected = nil
end
local function BuildLedger(p)
    local left = Label(p, "", "GameFontNormal")
    left:SetPoint("TOPLEFT", 0, 0)
    left:SetWidth((W - 40) / 2 - 6)
    local right = Label(p, "", "GameFontNormal")
    right:SetPoint("TOPLEFT", (W - 40) / 2 + 6, 0)
    right:SetWidth((W - 40) / 2 - 6)
    p.owedToMe, p.iOwe = left, right

    p.recent = Label(p, "")
    p.recent:SetPoint("TOPLEFT", 0, -150)
    p.recent:SetWidth(W - 40)

    local how = Label(p, "After you trade or mail the gold, record it here - the other player confirms it:")
    how:SetPoint("BOTTOMLEFT", 0, 56)
    local who = Label(p, "Player:")
    who:SetPoint("BOTTOMLEFT", 0, 34)
    BuildLedgerPicker(p, who)
    local amount = Label(p, "Amount:")
    amount:SetPoint("LEFT", p.whoPick, "RIGHT", 12, 0)
    local function Coin(box, icon)
        local l = Label(p, ("|TInterface\\MoneyFrame\\UI-%sIcon:12:12|t"):format(icon))
        l:SetPoint("LEFT", box, "RIGHT", 2, 0)
        return l
    end
    p.gold = Input(p, 50, "", true, 6)
    p.gold:SetPoint("LEFT", amount, "RIGHT", 8, 0)
    p.silver = Input(p, 22, "", true, 2)
    p.silver:SetPoint("LEFT", Coin(p.gold, "Gold"), "RIGHT", 8, 0)
    p.copper = Input(p, 22, "", true, 2)
    p.copper:SetPoint("LEFT", Coin(p.silver, "Silver"), "RIGHT", 8, 0)
    Coin(p.copper, "Copper")

    local function name()
        local picked = rawget(p, "whoSelected")
        if not picked then ns.Print("Pick a player from the list first.") end
        return picked
    end
    local function copper()
        local function n(box) local v = tonumber(box:GetText()) return v and math.floor(v) or 0 end
        local c = n(p.gold) * 10000 + n(p.silver) * 100 + n(p.copper)
        if c <= 0 then ns.Print("Enter how much: gold, silver and/or copper.") return nil end
        return c
    end
    local function pay(kind)
        local n = name()
        local c = n and copper()
        if n and c and ns.Ledger.Request(kind, n, c) then
            p.gold:SetText("") p.silver:SetText("") p.copper:SetText("")
        end
    end
    p.paid = Button(p, "I paid", 100, function() pay("paid") end)
    p.paid:SetPoint("BOTTOMLEFT", 0, 0)
    p.received = Button(p, "I received", 100, function() pay("received") end)
    p.received:SetPoint("LEFT", p.paid, "RIGHT", 8, 0)
    p.clear = Button(p, "Clear debt", 100, function()
        local n = name()
        if n then ns.Ledger.Request("settle", n) end
    end)
    -- with a mailbox open: mail everyone you owe what you owe them
    p.payAll = Button(p, "Pay debts", 100, function() ns.MailPay.PayAll() end)
    p.clear:SetPoint("LEFT", p.received, "RIGHT", 8, 0)
    p.payAll:SetPoint("LEFT", p.clear, "RIGHT", 8, 0)
    p.payHint = Label(p, "", "GameFontHighlightSmall")
    p.payHint:SetPoint("BOTTOMLEFT", 0, 76)
    p.payHint:SetWidth(W - 40)
end

---------------------------------------------------------------------------
-- Leaderboard
---------------------------------------------------------------------------
-- Podium: 1st in the middle and raised with Blizzard's winged gold dragon, 2nd on the left
-- with the silver dragon, 3rd on the right with a bronze-tinted dragon. Everyone below gets
-- a plain row, no frame.
local PODIUM = {
    { x = 0,    portrait = 68, base = 54, color = { 0.95, 0.75, 0.2 },  frame = "winged" }, -- 1st
    { x = -140, portrait = 56, base = 36, color = { 0.78, 0.8, 0.86 },  frame = "silver" }, -- 2nd
    { x = 140,  portrait = 56, base = 24, color = { 0.8, 0.5, 0.28 },   frame = "bronze" }, -- 3rd
}
local PODIUM_FLOOR = -214  -- y of the podium's bottom edge
local ROWS, ROW_H, SMALL = 5, 26, 22

-- Scrolling a list of rows: the mouse wheel over `area`, or the little arrows.
-- owner.offset = how many entries are scrolled past.
local SCROLL_TEX = "Interface\\Buttons\\UI-ScrollBar-Scroll%sButton-%s"
local function ScrollArrow(parent, dir, onClick)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(20, 20)
    b:SetNormalTexture(SCROLL_TEX:format(dir, "Up"))
    b:SetPushedTexture(SCROLL_TEX:format(dir, "Down"))
    b:SetDisabledTexture(SCROLL_TEX:format(dir, "Disabled"))
    b:SetHighlightTexture(SCROLL_TEX:format(dir, "Highlight"), "ADD")
    b:SetScript("OnClick", onClick)
    return b
end

local function AddScroll(owner, area)
    owner.offset = 0
    local function Move(by)
        owner.offset = owner.offset + by
        UI.Refresh()
    end
    area:EnableMouseWheel(true)
    area:SetScript("OnMouseWheel", function(_, delta) Move(-delta) end)
    owner.scrollUp = ScrollArrow(owner, "Up", function() Move(-1) end)
    owner.scrollDown = ScrollArrow(owner, "Down", function() Move(1) end)
    owner.scrollText = Label(owner, "", "GameFontDisableSmall")
    owner.scrollText:SetPoint("RIGHT", owner.scrollDown, "LEFT", -4, 0)
end

--- Keeps owner.offset in range for `total` entries shown `visible` at a time (skipping
--- `first` entries shown elsewhere, e.g. the podium); updates the arrows. Returns the offset.
local function ClampScroll(owner, total, visible, first)
    first = first or 0
    local listed = math.max(0, total - first)
    local max = math.max(0, listed - visible)
    owner.offset = math.min(math.max(owner.offset or 0, 0), max)
    local scrolls = max > 0
    owner.scrollUp:SetShown(scrolls)
    owner.scrollDown:SetShown(scrolls)
    owner.scrollText:SetShown(scrolls)
    if scrolls then
        owner.scrollUp:SetEnabled(owner.offset > 0)
        owner.scrollDown:SetEnabled(owner.offset < max)
        owner.scrollText:SetText(("%d-%d of %d"):format(first + owner.offset + 1,
            first + math.min(owner.offset + visible, listed), total))
    end
    return owner.offset
end

-- Leaderboard sub-tabs: Gold (the podium) and Kodo Crossing (high scores).
local HS_ROWS, HS_ROW_H = 10, 32

local function BuildHighScores(p)
    p.view = "gold"
    local function Sub(label, view, anchor, x)
        local b = Button(p, label, 110, function()
            p.view = view
            UI.Refresh()
        end)
        b:SetPoint(anchor, x, 0)
        return b
    end
    p.subGold = Sub("Gold", "gold", "TOPLEFT", 0)
    p.subKodo = Sub("Kodo Crossing", "kodo", "TOPRIGHT", 0)

    local hs = CreateFrame("Frame", nil, p)
    p.hs = hs
    hs:SetPoint("TOPLEFT", 0, -30)
    hs:SetPoint("BOTTOMRIGHT", 0, 0)
    hs.title = Label(hs, "Kodo Crossing - high scores", "GameFontNormalLarge")
    hs.title:SetPoint("TOP", 0, 0)
    hs.empty = Label(hs, "|cff888888No runs yet. Play in the Arcade tab!|r", "GameFontHighlight")
    hs.empty:SetPoint("TOP", 0, -40)
    hs.rows = {}
    hs.area = CreateFrame("Frame", nil, hs)
    hs.area:SetPoint("TOP", 0, -26)
    hs.area:SetSize(W - 40, HS_ROWS * HS_ROW_H)
    for i = 1, HS_ROWS do
        local r = CreateFrame("Frame", nil, hs.area)
        r:SetSize(W - 60, HS_ROW_H)
        r:SetPoint("TOP", 0, -(i - 1) * HS_ROW_H)
        r.rank = Label(r, i .. ".", "GameFontNormalLarge")
        r.rank:SetPoint("LEFT", 10, 0)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(28, 28)
        r.icon:SetPoint("LEFT", 50, 0)
        r.name = Label(r, "", "GameFontHighlightLarge")
        r.name:SetPoint("LEFT", 90, 0)
        r.score = Label(r, "", "GameFontNormalLarge")
        r.score:SetPoint("RIGHT", -10, 0)
        hs.rows[i] = r
    end
    AddScroll(hs, hs.area)
    hs.scrollUp:SetPoint("TOPRIGHT", 0, 2)
    hs.scrollDown:SetPoint("BOTTOMRIGHT", 0, 0)
    hs.me = Label(hs, "", "GameFontNormal")
    hs.me:SetPoint("BOTTOMLEFT", 0, 0)
    hs:Hide()
end

local function RefreshHighScores(p)
    local hs = p.hs
    local list = ns.Board.HighScores()
    hs.empty:SetShown(#list == 0)
    local medal = { "ffd100", "c0c8d8", "d08048" }
    local offset = ClampScroll(hs, #list, HS_ROWS)
    for i, r in ipairs(hs.rows) do
        local n = offset + i
        local e = list[n]
        r:SetShown(e ~= nil)
        if e then
            r.rank:SetText(n .. ".")
            ns.Arcade.SetSprite(r.icon, e.char or "gnome")
            local name = ns.IsMe(e.name) and ("|cffffd100" .. ns.Short(e.name) .. "|r") or ns.Short(e.name)
            r.name:SetText(name)
            r.score:SetText(("|cff%s%d|r"):format(medal[n] or "ffffff", e.score))
        end
    end
    hs.me:SetText(("Your best: |cffffd100%d|r"):format(ns.Arcade.Best()))
end

local function BuildBoard(p)
    p.podium = {}
    for rank, spec in ipairs(PODIUM) do
        local s = CreateFrame("Frame", nil, p)
        s:SetSize(130, 200)
        s:SetPoint("BOTTOM", p, "TOP", spec.x, PODIUM_FLOOR)
        -- the podium step
        s.step = Tex(s, "BACKGROUND", "Interface\\Buttons\\WHITE8X8", 110, spec.base)
        s.step:SetPoint("BOTTOM", 0, 0)
        s.step:SetVertexColor(spec.color[1], spec.color[2], spec.color[3], 0.55)
        s.rank = Label(s, tostring(rank), "GameFontNormalLarge")
        s.rank:SetPoint("CENTER", s.step, "CENTER", 0, 0)
        -- who's standing on it
        s.net = Label(s, "", "GameFontHighlight")
        s.net:SetPoint("BOTTOM", s.step, "TOP", 0, 4)
        s.name = Label(s, "", "GameFontNormal")
        s.name:SetPoint("BOTTOM", s.net, "TOP", 0, 2)
        s.portrait = Art.CreatePortrait(s, spec.portrait)
        s.portrait:SetPoint("BOTTOM", s.name, "TOP", 0, 14)
        s.wl = Label(s, "", "GameFontHighlightSmall")
        s.wl:SetPoint("TOP", s.step, "BOTTOM", 0, -2)
        s.spec = spec
        p.podium[rank] = s
    end
    -- column headings for the rows below the podium
    local head = {}
    for _, h in ipairs({ { "Net", 200 }, { "W-L", 290 }, { "Wagered", 345 } }) do
        local l = Label(p, h[1], "GameFontNormalSmall")
        l:SetPoint("TOPLEFT", h[2], PODIUM_FLOOR - 38)
        head[#head + 1] = l
    end
    p.rowHeads = head
    p.rows = {}
    p.rowArea = CreateFrame("Frame", nil, p)
    p.rowArea:SetPoint("TOPLEFT", 0, PODIUM_FLOOR - 52)
    p.rowArea:SetSize(W - 40, ROWS * ROW_H)
    for i = 1, ROWS do
        local r = CreateFrame("Frame", nil, p.rowArea)
        r:SetSize(W - 40, ROW_H)
        r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        r.rank = Label(r, tostring(i + 3), "GameFontNormal")
        r.rank:SetPoint("LEFT", 6, 0)
        r.portrait = Art.CreatePortrait(r, SMALL)
        r.portrait:SetPoint("LEFT", 34, 0)
        r.name = Label(r, "", "GameFontHighlight")
        r.name:SetPoint("LEFT", 66, 0)
        r.net = Label(r, "", "GameFontHighlight")
        r.net:SetPoint("LEFT", 200, 0)
        r.wl = Label(r, "", "GameFontHighlightSmall")
        r.wl:SetPoint("LEFT", 290, 0)
        r.wag = Label(r, "", "GameFontHighlightSmall")
        r.wag:SetPoint("LEFT", 345, 0)
        p.rows[i] = r
    end
    -- more than 8 players: scroll the rows (mouse wheel, or the arrows)
    AddScroll(p, p.rowArea)
    p.scrollUp:SetPoint("TOPRIGHT", 0, PODIUM_FLOOR - 32)
    p.scrollDown:SetPoint("TOPRIGHT", 0, PODIUM_FLOOR - 52 - ROWS * ROW_H - 2)
    p.me = Label(p, "", "GameFontNormal")
    p.me:SetPoint("BOTTOMLEFT", 0, 0)
    p.me:SetWidth(W - 40)
    p.drop = Label(p, "", "GameFontHighlight")
    p.drop:SetPoint("BOTTOMLEFT", 0, 20)
    p.drop:SetWidth(W - 40)
    BuildHighScores(p)
end

---------------------------------------------------------------------------
-- Live: games other guildies are playing right now, and watching one on the same table
-- the players see (the big deathroll number, the cards, the reels, the coin).
---------------------------------------------------------------------------
local LIVE_ROWS, LIVE_ROW_H = 4, 22

local function BuildLive(p)
    local title = Label(p, "Games in progress", "GameFontNormal")
    title:SetPoint("TOPLEFT", 0, 0)
    p.empty = Label(p, "|cff888888Nobody in the guild is playing right now.|r", "GameFontHighlight")
    p.empty:SetPoint("TOPLEFT", 0, -22)
    p.rows = {}
    for i = 1, LIVE_ROWS do
        local r = CreateFrame("Frame", nil, p)
        r:SetSize(W - 40, LIVE_ROW_H)
        r:SetPoint("TOPLEFT", 0, -16 - (i - 1) * LIVE_ROW_H)
        r.text = Label(r, "", "GameFontHighlight")
        r.text:SetPoint("LEFT", 0, 0)
        r.text:SetWidth(W - 40 - 96)
        r.text:SetWordWrap(false)
        r.id = false
        r.watch = Button(r, "Watch", 86, function()
            local id = rawget(r, "id")
            if id and id == ns.Live.watching then ns.Live.Unwatch() elseif id then ns.Live.Watch(id) end
        end)
        r.watch:SetPoint("RIGHT", 0, 0)
        p.rows[i] = r
    end
    -- the same table frame as the Play tab, drawn from the game the player's addon sends us
    BuildTable(p, -16 - LIVE_ROWS * LIVE_ROW_H - 8)
    p.hint = Label(p, "", "GameFontHighlightLarge")
    p.hint:SetPoint("CENTER", p.table, "CENTER", 0, 0)
    p.hint:SetWidth(W - 80)
    p.hint:SetJustifyH("CENTER")
    p.info = Label(p, "", "GameFontNormal")
    p.info:SetPoint("TOPLEFT", p.table, "BOTTOMLEFT", 2, -8)
    p.info:SetWidth(W - 40 - 130)
    p.stop = Button(p, "Stop watching", 120, function() ns.Live.Unwatch() end)
    p.stop:SetPoint("TOPRIGHT", p.table, "BOTTOMRIGHT", 0, -4)
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local TABS = { { "play", "Play" }, { "live", "Live" }, { "ledger", "Ledger" }, { "board", "Leaderboard" }, { "arcade", "Arcade" } }
local LOG_LINES = 5 -- the log at the bottom: one line each, newest last, never taller than this

local function SelectTab(name)
    ns.db.window.tab = name
    for key, p in pairs(panels) do p:SetShown(key == name) end
    for key, t in pairs(tabs) do
        if key == name then t:Disable() else t:Enable() end
    end
    UI.Refresh()
end

local function Build()
    if frame then return frame end
    frame = CreateFrame("Frame", "GuildGambitFrame", UIParent, "BackdropTemplate")
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
        ns.db.window.point, ns.db.window.x, ns.db.window.y = point, x, y
    end)
    frame:Hide()
    tinsert(UISpecialFrames, "GuildGambitFrame") -- close with Escape

    local header = Tex(frame, "ARTWORK", Art.GAME.dialogHeader, 320, 64)
    header:SetPoint("TOP", 0, 12)
    local title = Label(frame, "GuildGambit", "GameFontNormal")
    title:SetPoint("TOP", header, "TOP", 0, -14)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() UI.SetShown(false) end)

    local x = 18
    for _, def in ipairs(TABS) do
        local key = def[1]
        local t = Button(frame, def[2], 84, function() SelectTab(key) end)
        t:SetPoint("TOPLEFT", x, -36)
        tabs[key] = t
        x = x + 86
    end

    BuildPlay(Panel("play"))
    BuildLive(Panel("live"))
    if ns.Arcade then
        local ok, err = pcall(ns.Arcade.Build, Panel("arcade"))
        if not ok then ns.Print("|cffff4040the Arcade tab failed to build: %s|r", tostring(err)) end
    end
    BuildLedger(Panel("ledger"))
    BuildBoard(Panel("board"))

    -- the log: a fixed stack of single lines that can't grow over the buttons above it
    -- (long entries are cut off with "..."; the full text is always in chat)
    frame.logLines = {}
    for i = 1, LOG_LINES do
        local line = Label(frame, "", "GameFontHighlightSmall")
        line:SetPoint("BOTTOMLEFT", 20, 16 + (LOG_LINES - i) * 14)
        line:SetWidth(W - 40)
        line:SetHeight(14)
        line:SetWordWrap(false)
        frame.logLines[i] = line
    end

    -- the coin tab on the side: pops out the guild wealth window
    if ns.WealthUI then
        local ok, err = pcall(ns.WealthUI.Attach, frame)
        if not ok then ns.Print("|cffff4040the wealth tab failed to build: %s|r", tostring(err)) end
    end

    frame.ready = true
    SelectTab(panels[ns.db.window.tab] and ns.db.window.tab or "play")
    return frame
end

-- If any part of the window fails to build in-game, report it once and carry on: every game
-- still works through chat and /gg commands.
local buildFailed = false
local function SafeBuild()
    if frame and frame.ready then return true end
    if buildFailed then return false end
    local ok, err = pcall(Build)
    if not ok then
        buildFailed = true
        if frame then frame:Hide() end
        ns.Print("|cffff4040The window failed to build: %s|r", tostring(err))
        ns.Print("Games still work through /gg commands - please report this error.")
        return false
    end
    return true
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------
-- Kodo Crossing duel: both runs' scores side by side, counting up live.
local function BuildKodo(t)
    local kd = CreateFrame("Frame", nil, t)
    t.kd = kd
    kd:SetAllPoints()
    kd.title = Label(kd, "", "GameFontNormalLarge")
    kd.title:SetPoint("TOP", 0, -18)
    kd.title:SetJustifyH("CENTER")
    kd.kodo = kd:CreateTexture(nil, "ARTWORK")
    if not pcall(kd.kodo.SetTexture, kd.kodo, Art.Tex("arcade/kodo"), nil, nil, "NEAREST") then
        kd.kodo:SetTexture(Art.Tex("arcade/kodo"))
    end
    kd.kodo:SetSize(128, 64)
    kd.kodo:SetPoint("CENTER", 0, 22)
    kd.kodo:SetAlpha(0.35)
    kd.vs = Label(kd, "VS", "GameFontNormalHuge")
    kd.vs:SetPoint("CENTER", 0, 0)
    kd.sides = {}
    for i, s in ipairs({ "a", "b" }) do
        local x = i == 1 and -110 or 110
        local side = {}
        side.name = Label(kd, "", "GameFontNormalLarge")
        side.name:SetPoint("CENTER", x, 64)
        side.score = kd:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        pcall(side.score.SetFont, side.score, "Fonts\\FRIZQT__.TTF", 64, "THICKOUTLINE")
        side.score:SetPoint("CENTER", x, 4)
        side.state = Label(kd, "", "GameFontHighlight")
        side.state:SetPoint("CENTER", x, -46)
        kd.sides[s] = side
    end
    kd.result = Label(kd, "", "GameFontNormalLarge")
    kd.result:SetPoint("BOTTOM", 0, 26)
    kd.result:SetWidth(W - 80)
    kd.result:SetJustifyH("CENTER")
end

local function RefreshKodo(kd, game)
    local function nm(n) return ns.IsMe(n) and "You" or ns.Short(n) end
    kd.title:SetText(("Kodo Crossing  -  %s"):format(ns.Stake(game.bet or 0)))
    local scores, done = game.scores or { a = 0, b = 0 }, game.finishedRun or {}
    local bothDone = done.a and done.b
    for _, s in ipairs({ "a", "b" }) do
        local side, other = kd.sides[s], s == "a" and "b" or "a"
        local sc = scores[s] or 0
        side.name:SetText(nm(s == "a" and game.a or game.b))
        side.score:SetText(tostring(sc))
        if bothDone and sc > (scores[other] or 0) then side.score:SetTextColor(0.2, 1, 0.2)
        elseif bothDone and sc < (scores[other] or 0) then side.score:SetTextColor(1, 0.3, 0.3)
        else side.score:SetTextColor(1, 0.84, 0.25) end
        side.state:SetText(game.state == "invite" and "|cff888888waiting...|r"
            or (done[s] and "|cffffd100final|r" or "|cff20ff20running...|r"))
    end
    if bothDone then
        local a, b = scores.a or 0, scores.b or 0
        kd.result:SetText(a == b and "|cffffd100A tie - push!|r" or ("|cff20ff20%s %s!|r"):format(
            nm(a > b and game.a or game.b), (ns.IsMe(a > b and game.a or game.b)) and "win" or "wins"))
    else
        kd.result:SetText("")
    end
end

local function ShowView(t, which)
    if not rawget(t, "cf") then BuildCoin(t) end
    if not rawget(t, "kd") then BuildKodo(t) end
    for _, key in ipairs({ "idle", "bj", "slots", "dr", "cf", "kd" }) do t[key]:SetShown(key == which) end
end

local function RefreshTable(p, game)
    local t = p.table
    local BJ = ns.Rules.Blackjack
    if not game then return ShowView(t, "idle") end
    if game.kind == "blackjack" then
        ShowView(t, "bj")
        local shown = ns.Blackjack.VisibleDealer(game)
        local duel = game.mode == "duel"
        ns.Cards.SetRow(t.bj.dealer, shown, ns.Blackjack.HoleHidden(game) and 1 or 0)
        -- your own hole card in a duel: shown to you, badged "face down" (your opponent can't see it)
        local holeMark = duel and not game.finished and game.myHole or nil
        ns.Cards.SetRow(t.bj.player, game.p, 0, holeMark)
        local myDoubled = duel and ns.Blackjack.MyHand(game).doubled or (not duel and game.doubled)
        local theirDoubled = duel and ns.Blackjack.TheirHand(game).doubled
        local theirValue = duel and ns.Blackjack.DuelValueText(game.d) or (#shown > 0 and BJ.ValueText(shown) or "")
        t.bj.dealerLabel:SetText((duel and ns.Short(game.opponent) or "Dealer")
            .. (theirValue ~= "" and ("  -  " .. theirValue) or "") .. (theirDoubled and "  (doubled)" or ""))
        local me = (game.spectator and ns.Short(game.b)) or (game.asHouse and ns.Short(game.player)) or "You"
        local myValue = #game.p > 0 and (duel and ns.Blackjack.DuelValueText(game.p) or BJ.ValueText(game.p)) or ""
        t.bj.playerLabel:SetText(me .. (myValue ~= "" and ("  -  " .. myValue) or "") .. (myDoubled and "  (doubled)" or ""))
    elseif game.kind == "slots" then
        ShowView(t, "slots")
        local function ShowReels(row, result)
            local reels = result and result.reels
            for i = 1, 3 do
                local sym = reels and reels[i]
                row[i]:SetTexture(Art.Tex("icons/" .. (sym and sym:lower() or "seven")))
                row[i]:SetDesaturated(not sym)
                row[i]:SetAlpha(sym and 1 or 0.35)
            end
        end
        local function Name(result)
            return result and (result.name .. (result.mult > 0 and ("  x" .. result.mult) or "")) or nil
        end
        local duel = game.mode == "duel"
        -- the opponent's row only exists in a 1v1 game
        for i = 1, 3 do
            t.slots.theirReels[i]:SetShown(duel)
            t.slots.theirReels.rings[i]:SetShown(duel)
        end
        if duel then
            ShowReels(t.slots.theirReels, game.theirResult)
            local theirSide = ns.IsMe(game.a) and "b" or "a"
            t.slots.theirLabel:SetText(ns.Short(game.opponent) .. ":  "
                .. (ns.Slots.Line(game, theirSide) or "waiting to spin..."))
        else
            t.slots.theirLabel:SetText("")
        end
        ShowReels(t.slots.reels, game.result)
        local mySide = duel and (ns.IsMe(game.a) and "a" or "b")
        t.slots.result:SetText((game.spectator and (ns.Short(game.b) .. ":  ") or "You:  ") .. ((duel and ns.Slots.Line(game, mySide)) or Name(game.result) or "Spin to play!"))
    elseif game.kind == "coinflip" then
        ShowView(t, "cf")
        RefreshCoin(t.cf, game)
    elseif game.kind == "deathroll" then
        ShowView(t, "dr")
        RefreshDeathroll(t.dr, game)
        if rawget(t.dr, "roster") then t.dr.roster:SetText("") end
    elseif game.kind == "groupdr" then
        ShowView(t, "dr")
        RefreshGroup(t.dr, game)
    elseif game.kind == "kodo" then
        ShowView(t, "kd")
        RefreshKodo(t.kd, game)
    end
end

local function RefreshPlay(p)
    local game = ns.Games.Mine()
    local shown = game or ns.Games.last
    RefreshTable(p, shown)
    if game and game.kind == "groupdr" then
        p.status:SetText(("Group Deathroll - %s each, %d players:  %s"):format(ns.Stake(game.bet),
            #game.players, game.status or ""))
    elseif game then
        p.status:SetText(("%s vs %s - %s:  %s"):format(game.title, ns.Short(game.opponent),
            ns.Stake(game.bet or game.stake), (game.status or ""):gsub("\n", "  ")))
    elseif shown and shown.kind == "groupdr" then
        p.status:SetText(("Last: Group Deathroll - %s"):format(ns.ResultText(shown.net, shown.outcome)))
    elseif shown then
        p.status:SetText(("Last: %s vs %s - %s"):format(shown.title, ns.Short(shown.opponent),
            ns.ResultText(shown.net, shown.outcome)))
    else
        p.status:SetText("")
    end
    local watchers = game and ns.Live and ns.Live.WatcherCount(game) or 0
    if watchers > 0 then
        p.status:SetText(p.status:GetText() .. ("  |cffbbbbbb(%d watching)|r"):format(watchers))
    end
    if prompt then
        p.roll:SetText(prompt.label or ("Roll " .. prompt.lo .. "-" .. prompt.hi))
        p.roll:Enable()
    else
        p.roll:SetText("Roll")
        p.roll:Disable()
    end
    local isBJ = game and game.kind == "blackjack"
    p.stand:SetShown(isBJ)
    p.double:SetShown(isBJ)
    if isBJ then
        if ns.Blackjack.CanAct(game) then p.stand:Enable() else p.stand:Disable() end
        if ns.Blackjack.CanDouble(game) then p.double:Enable() else p.double:Disable() end
    end
    if game then p.cancel:Enable() else p.cancel:Disable() end
    for _, b in ipairs({ p.dr, p.kodo, p.bj, p.cf, p.gdr }) do
        if game then b:Disable() else b:Enable() end
    end
end

local function DebtLines(title, color, list)
    local lines = { title }
    if #list == 0 then lines[#lines + 1] = "|cff888888  nobody|r" end
    for i, d in ipairs(list) do
        if i > 7 then lines[#lines + 1] = ("  ...and %d more"):format(#list - 7) break end
        lines[#lines + 1] = ("  %s  |cff%s%s|r"):format(ns.Short(d.name), color, ns.Money(d.amount))
    end
    return table.concat(lines, "\n")
end

local function RefreshLedger(p)
    local owedToMe, iOwe = ns.Ledger.Debts()
    p.owedToMe:SetText(DebtLines("Owed to you", "20ff20", owedToMe))
    p.iOwe:SetText(DebtLines("You owe", "ff4040", iOwe))
    -- Pay debts: only with a mailbox open and something left to pay
    local Mail = ns.MailPay
    local left = Mail.Owed()
    local mailed = 0
    for _, d in ipairs(iOwe) do mailed = mailed + ns.Ledger.InTransit(d.name) end
    local ready = Mail.open and #left > 0 and not Mail.Busy()
    if ready then p.payAll:Enable() else p.payAll:Disable() end
    p.payAll:SetText(Mail.Busy() and "Mailing..." or (#left > 1 and ("Pay debts (" .. #left .. ")") or "Pay debts"))
    local hint
    if mailed > 0 then hint = ("|cffbbbbbb%s mailed, waiting for them to confirm.|r"):format(ns.Money(mailed)) end
    if #left > 0 and not Mail.open then
        hint = (hint and (hint .. "  ") or "") .. "|cffbbbbbbOpen a mailbox to pay what you owe by mail.|r"
    end
    p.payHint:SetText(hint or "")
    local lines = { "Recent:" }
    for _, e in ipairs(ns.Ledger.Recent(6)) do
        local what = e.kind == "payment" and ("payment (" .. (e.via or "manual") .. ")") or e.game
        lines[#lines + 1] = ("  %s %s: %s%s%s"):format(what, ns.Short(e.opponent), ns.Money(e.net, true),
            e.practice and " (practice)" or "", (not e.verified and not e.practice) and " (unverified)" or "")
    end
    p.recent:SetText(table.concat(lines, "\n"))
end

-- more than 3 in a row: on fire, or cursed
local STREAK = 4
local FIRE = "|TInterface\\Icons\\Spell_Fire_Fire:14:14|t"
local CURSE = "|TInterface\\Icons\\Spell_Shadow_CurseOfSargeras:14:14|t"

local function StreakIcon(e)
    local k = e.streak or 0
    if k >= STREAK then return " " .. FIRE .. (k > STREAK and ("|cffff9020" .. k .. "|r") or "") end
    if k <= -STREAK then return " " .. CURSE .. (k < -STREAK and ("|cffb070ff" .. -k .. "|r") or "") end
    return ""
end

local function NameText(e)
    local name = ns.IsMe(e.name) and ("|cffffd100" .. ns.Short(e.name) .. "|r") or ns.Short(e.name)
    return name .. StreakIcon(e)
end

local function NetText(e)
    local color = e.net > 0 and "|cff20ff20" or (e.net < 0 and "|cffff4040" or "|cffcccccc")
    return color .. ns.Money(e.net, true) .. "|r"
end

local function RefreshBoard(p)
    -- Gold (the podium) or Kodo Crossing (high scores)
    local kodo = p.view == "kodo"
    if kodo then p.subKodo:Disable() p.subGold:Enable() else p.subGold:Disable() p.subKodo:Enable() end
    p.hs:SetShown(kodo)
    for _, s in ipairs(p.podium) do s:SetShown(not kodo) end
    p.me:SetShown(not kodo)
    p.drop:SetShown(not kodo)
    if kodo then
        for _, r in ipairs(p.rows) do r:Hide() end
        for _, l in ipairs(p.rowHeads) do l:Hide() end
        p.scrollUp:Hide() p.scrollDown:Hide() p.scrollText:Hide()
        return RefreshHighScores(p)
    end
    local ranked = ns.Board.Ranked()
    for rank, s in ipairs(p.podium) do
        local e = ranked[rank]
        s.portrait:SetShown(e ~= nil)
        if e then
            Art.SetPortrait(s.portrait, Art.PlayerIcon(e.race, e.sex), s.spec.frame)
            s.name:SetText(NameText(e))
            s.net:SetText(NetText(e))
            s.wl:SetText(("%d-%d\n|cffbbbbbb%s wagered|r"):format(e.wins, e.losses, ns.Money(e.wagered or 0)))
        else
            s.name:SetText("|cff888888-|r")
            s.net:SetText("")
            s.wl:SetText("")
        end
    end
    local offset = ClampScroll(p, #ranked, ROWS, 3)
    for i, r in ipairs(p.rows) do
        local n = offset + i + 3
        local e = ranked[n]
        r:SetShown(e ~= nil)
        if e then
            r.rank:SetText(tostring(n))
            Art.SetPortrait(r.portrait, Art.PlayerIcon(e.race, e.sex), nil) -- no frame below 3rd
            r.name:SetText(NameText(e))
            r.net:SetText(NetText(e))
            r.wl:SetText(e.wins .. "-" .. e.losses)
            r.wag:SetText(ns.Money(e.wagered or 0))
        end
    end
    for _, l in ipairs(p.rowHeads) do l:SetShown(ranked[4] ~= nil) end
    local mine
    for i, e in ipairs(ranked) do if ns.IsMe(e.name) then mine = i end end
    local who, range = ns.Board.BiggestDrop()
    p.drop:SetText(who and ("|TInterface\\Icons\\INV_Misc_Bone_HumanSkull_01:14:14|t Biggest drop to 1: |cffffd100%s|r rolled a 1 from |cffff4040%s|r"):format(
        ns.Short(who), "1-" .. range) or "")
    p.me:SetText(#ranked == 0 and "No games played in this guild yet."
        or (mine and ("You are #%d of %d players."):format(mine, #ranked) or "Play a game to join the board."))
end

-- Watching a Kodo Crossing duel: both runs side by side, replayed live from each player's
-- hops on the same seeded lanes (half size).
local WATCH_SCALE = 0.5

local function BuildKodoWatch(p)
    if rawget(p, "kodoView") then return p.kodoView end
    local v = CreateFrame("Frame", nil, p)
    p.kodoView = v
    v:SetPoint("TOPLEFT", p.table, "TOPLEFT", 0, 0)
    v:SetPoint("BOTTOMRIGHT", p.table, "BOTTOMRIGHT", 0, 0)
    v.engines, v.labels, v.watching = {}, {}, false
    local A = ns.Arcade
    local w, h = A.COLS * A.TILE * WATCH_SCALE, A.VIEW_ROWS * A.TILE * WATCH_SCALE
    for i, side in ipairs({ "a", "b" }) do
        local holder = CreateFrame("Frame", nil, v)
        holder:SetSize(w, h)
        holder:SetPoint("BOTTOM", v, "BOTTOM", (i == 1 and -1 or 1) * (w / 2 + 6), 4)
        local e = A.NewEngine({ spectator = true })
        local canvas = e:BuildCanvas(holder)
        canvas:SetScale(WATCH_SCALE)
        canvas:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
        e:New()
        v.engines[side] = e
        local label = Label(v, "", "GameFontNormal")
        label:SetPoint("BOTTOM", holder, "TOP", 0, 6)
        label:SetWidth(w + 10)
        label:SetJustifyH("CENTER")
        v.labels[side] = label
    end
    v:SetScript("OnUpdate", function(_, elapsed)
        for _, e in pairs(v.engines) do
            if e.g and e.g.queue then e:Replay(elapsed) end
            e:Render()
        end
    end)
    v:Hide()
    return v
end

--- A spectator just tuned in to one side of a duel (from Core/House.lua's RUNS handler).
function UI.FollowRun(side, run)
    local p = panels.live
    if not p or not run.seed then return end
    local v = BuildKodoWatch(p)
    -- the replays now belong to this duel (so the first table update doesn't clear them)
    if v.watching ~= ns.Live.watching then
        v.watching = ns.Live.watching
        for _, e in pairs(v.engines) do e:New() end
    end
    v.engines[side]:Follow(run.seed, run.char or "gnome", run.snap)
end

--- More hops for one side of the duel we're watching.
function UI.FeedRun(side, events, knownTime)
    local p = panels.live
    local v = p and rawget(p, "kodoView")
    if v then v.engines[side]:Feed(events, knownTime) end
end

local function RefreshLive(p)
    local Live = ns.Live
    local list = Live.List()
    p.empty:SetShown(#list == 0)
    for i, r in ipairs(p.rows) do
        local g = list[i]
        r:SetShown(g ~= nil)
        if g then
            r.id = g.id
            if g.own then
                r.text:SetText("|cff20ff20(you)|r " .. (g.h or "?"))
                r.watch:SetText("Playing")
                r.watch:Disable()
            else
                r.text:SetText((g.h or "?") .. (g.ended and "  |cff888888(finished)|r" or ""))
                r.watch:SetText(g.id == Live.watching and "Watching" or "Watch")
                if g.ended and g.id ~= Live.watching then r.watch:Disable() else r.watch:Enable() end
            end
        end
    end
    local g = Live.watching and Live.games[Live.watching]
    if not g then
        if rawget(p, "kodoView") then p.kodoView:Hide() end
        p.table:Hide()
        p.hint:SetText(#list > 0 and "|cff888888Pick a game above to watch it live.|r" or "")
        p.hint:Show()
        p.info:SetText("")
        p.stop:Hide()
        return
    end
    p.stop:Show()
    local kodo = g.mirror and g.mirror.kind == "kodo"
    local v = kodo and BuildKodoWatch(p) or rawget(p, "kodoView")
    if v then
        -- a different duel than last time: clear the replays until the new runs arrive
        if kodo and v.watching ~= g.id then
            v.watching = g.id
            for _, e in pairs(v.engines) do e:New() end
        end
        v:SetShown(kodo)
    end
    if kodo then
        p.hint:Hide()
        p.table:Hide()
        local m = g.mirror
        for _, side in ipairs({ "a", "b" }) do
            local done = m.finishedRun and m.finishedRun[side]
            v.labels[side]:SetText(("%s  |cffffffff%d|r%s"):format(ns.Short(side == "a" and m.a or m.b),
                m.scores and m.scores[side] or 0, done and "  |cffffd100final|r" or ""))
        end
    elseif g.mirror then
        p.hint:Hide()
        p.table:Show()
        RefreshTable(p, g.mirror)
    else
        -- a player on an older GuildGambit only sends text: show that
        p.table:Hide()
        p.hint:SetText(("%s\n\n%s\n%s"):format(g.h or "", g.l1 or "|cff888888Joining...|r", g.l2 or ""))
        p.hint:Show()
    end
    p.info:SetText(g.ended and ("|cffffd100" .. g.ended .. "|r") or ("Watching: " .. (g.h or "")))
end

function UI.Refresh()
    if not frame or not frame.ready or not frame:IsShown() then return end
    if panels.play:IsShown() then RefreshPlay(panels.play) end
    if panels.ledger:IsShown() then RefreshLedger(panels.ledger) end
    if panels.board:IsShown() then RefreshBoard(panels.board) end
    if panels.live and panels.live:IsShown() then RefreshLive(panels.live) end
    -- newest entry on the bottom line; strip the /gg accept hints, the popup covers those
    local log = ns.logLines
    for i, line in ipairs(frame.logLines) do
        local entry = log[#log - LOG_LINES + i]
        line:SetText(entry and entry:gsub("%s*|cffffff00/gg accept|r or |cffffff00/gg decline|r", "") or "")
    end
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------
--- Sets what the Roll button rolls (nil disables it).
function UI.SetRollPrompt(lo, hi, label)
    prompt = lo and { lo = lo, hi = hi, label = label } or nil
    UI.Refresh()
end

function UI.GetRollPrompt() return prompt end

--- Puts a non-roll action on the Roll button (e.g. "Start" for a group deathroll host).
function UI.SetAction(label, fn)
    prompt = { action = fn, label = label }
    UI.Refresh()
end

function UI.SetShown(shown)
    if not SafeBuild() then return end
    ns.db.window.shown = shown
    frame:SetShown(shown)
    UI.Refresh()
end

function UI.Toggle()
    UI.SetShown(not (frame and frame:IsShown()))
end

function UI.Restore()
    if not SafeBuild() then return end
    local w = ns.db.window
    frame:ClearAllPoints()
    frame:SetPoint(w.point, UIParent, w.point, w.x, w.y)
    UI.SetShown(w.shown)
end

function UI.Frame() return frame end
function UI.Panel(name) return panels[name] end
function UI.SelectTab(name) if SafeBuild() then SelectTab(name) end end

---------------------------------------------------------------------------
-- Invites: a popup, with /gg accept and /gg decline as a fallback.
---------------------------------------------------------------------------
UI.pendingInvite = nil

StaticPopupDialogs["GUILDGAMBIT_INVITE"] = {
    text = "%s",
    button1 = ACCEPT or "Accept",
    button2 = DECLINE or "Decline",
    -- The popup system has changed between clients: the invite may arrive as `data`, as
    -- `self.data`, or not at all. Fall back to the invite we remembered when showing it.
    OnAccept = function(self, data)
        UI.AnswerInvite(UI.InviteFrom(self, data), true)
    end,
    OnCancel = function(self, data, reason)
        if reason == "override" then return end -- replaced by another popup, not a decline
        local invite = UI.InviteFrom(self, data)
        if reason == "timeout" and invite and invite.timeout then
            -- nobody answered: for some asks that isn't a "no" (they'll be asked again)
            invite.answered = true
            if UI.pendingInvite == invite then UI.pendingInvite = nil end
            return invite.timeout()
        end
        UI.AnswerInvite(invite, false)
    end,
    timeout = 60,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function UI.InviteFrom(self, data)
    if type(data) == "table" and data.accept then return data end
    if type(self) == "table" and type(rawget(self, "data")) == "table" and self.data.accept then return self.data end
    return UI.pendingInvite
end

function UI.ShowInvite(text, onAccept, onDecline, onTimeout)
    local invite = { text = text, accept = onAccept, decline = onDecline, timeout = onTimeout }
    ns.Sound("invite")
    UI.pendingInvite = invite
    ns.Log("%s |cffffff00/gg accept|r or |cffffff00/gg decline|r", text)
    local dialog = StaticPopup_Show and StaticPopup_Show("GUILDGAMBIT_INVITE", text)
    if dialog then dialog.data = invite end
    if frame and frame.ready and not frame:IsShown() then UI.SetShown(true) end
end

function UI.AnswerInvite(invite, accepted)
    invite = invite or UI.pendingInvite
    if not invite or invite.answered then return false end
    invite.answered = true
    if UI.pendingInvite == invite then UI.pendingInvite = nil end
    if accepted then invite.accept() else invite.decline() end
    if StaticPopup_Hide then StaticPopup_Hide("GUILDGAMBIT_INVITE") end
    return true
end

---------------------------------------------------------------------------
-- Addon compartment (minimap addon menu), named in the TOC.
---------------------------------------------------------------------------
function GuildGambit_OnCompartmentClick() UI.Toggle() end

function GuildGambit_OnCompartmentEnter(_, button)
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:SetText("GuildGambit")
    GameTooltip:AddLine("Click to open. /gg for commands.", 1, 1, 1)
    GameTooltip:Show()
end

function GuildGambit_OnCompartmentLeave() GameTooltip:Hide() end


---------------------------------------------------------------------------
-- Minimap button (kept in this file so it loads with an already-running client's TOC)
---------------------------------------------------------------------------
do
-- UI/Minimap.lua: minimap button. Left-click opens the window, right-click the Ledger,
-- drag to move it around the minimap. Built from the same game textures and APIs as the
-- working Forever addons' buttons; named like a LibDBIcon button so minimap-button
-- collectors (e.g. MinimapButtonButton) pick it up.
local Art = ns.Art

local MinimapButton = {}
ns.MinimapButton = MinimapButton

local button

local function Settings()
    ns.db.minimap = ns.db.minimap or {}
    local s = ns.db.minimap
    if s.angle == nil then s.angle = 215 end -- lower left, away from the clock and tracking
    return s
end

--- Places the button on the minimap's edge at the saved angle (degrees, 0 = right).
function MinimapButton.Position()
    if not button then return end
    local angle = math.rad(Settings().angle)
    local radius = (Minimap:GetWidth() or 140) / 2 + 10
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function OnUpdateDrag()
    local mx, my = Minimap:GetCenter()
    if not mx or not my then return end
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    x, y = x / scale, y / scale
    Settings().angle = math.deg(math.atan2(y - my, x - mx))
    MinimapButton.Position()
end

local function Tooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("GuildGambit", 1, 0.82, 0.25)
    local owedToMe, iOwe = ns.Ledger.Debts()
    local owed, owe = 0, 0
    for _, d in ipairs(owedToMe) do owed = owed + d.amount end
    for _, d in ipairs(iOwe) do owe = owe + d.amount end
    if owed > 0 then GameTooltip:AddLine("Owed to you: " .. ns.Money(owed), 0.2, 1, 0.2) end
    if owe > 0 then GameTooltip:AddLine("You owe: " .. ns.Money(owe), 1, 0.3, 0.3) end
    local game = ns.Games.Mine()
    if game then GameTooltip:AddLine("Playing: " .. game.title .. " vs " .. ns.Short(game.opponent), 1, 1, 1) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Left-click: open / close", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Right-click: ledger", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Drag: move", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

function MinimapButton.Create()
    if button or not Minimap then return button end
    button = CreateFrame("Button", "LibDBIcon10_" .. ADDON_NAME, Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel((Minimap:GetFrameLevel() or 0) + 8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(20, 20)
    bg:SetPoint("CENTER")

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(Art.Tex("icons/addon"))
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    icon:SetTexCoord(0.06, 0.94, 0.06, 0.94)
    button.icon = icon

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT")
    button.border = border

    button:SetScript("OnClick", function(_, which)
        if which == "RightButton" then
            ns.UI.SetShown(true)
            ns.UI.SelectTab("ledger")
        else
            ns.UI.Toggle()
        end
    end)
    button:SetScript("OnEnter", Tooltip)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", OnUpdateDrag)
    end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)

    MinimapButton.Position()
    button:SetShown(not Settings().hide)
    return button
end

function MinimapButton.SetShown(shown)
    Settings().hide = not shown
    if button then button:SetShown(shown) end
end

function MinimapButton.Button() return button end

end
