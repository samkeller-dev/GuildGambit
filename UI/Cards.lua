-- UI/Cards.lua: playing card widgets. Pip cards are a single texture; court cards and aces
-- add the game's portrait icon in the card's socket with a frame over it:
--   jack = silver ring, queen = gold ring, king = Blizzard's winged elite dragon,
--   ace = Blizzard's elite dragon around a dragon head.
local ADDON_NAME, ns = ...
local Art = ns.Art

local Cards = {}
ns.Cards = Cards

Cards.ASPECT = 350 / 250
-- portrait socket on the card art (fractions of card width/height); see tools/art/cards.py
local SOCKET_X, SOCKET_Y, SOCKET_D = 125 / 250, 158 / 350, 108 / 250

local RANKS = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }

--- Texture name for a rules card { rank = 1..13, suit = "s"/"h"/"d"/"c" }.
function Cards.Code(card)
    return RANKS[card.rank] .. card.suit
end

function Cards.Portrait(card)
    local r, s = card.rank, card.suit
    if r == 1 then return Art.DragonIcon(Art.SUIT_DRAGON[s]), "gold" end
    if r == 11 then return Art.HeadIcon(Art.SUIT_RACE[s], false), "ring_silver" end
    if r == 12 then return Art.HeadIcon(Art.SUIT_RACE[s], true), "ring_gold" end
    if r == 13 then return Art.HeadIcon(Art.SUIT_RACE[s], false), "winged" end
end

function Cards.Create(parent, width)
    local height = math.floor(width * Cards.ASPECT + 0.5)
    local c = CreateFrame("Frame", nil, parent)
    c:SetSize(width, height)
    c.base = c:CreateTexture(nil, "BACKGROUND")
    c.base:SetAllPoints()
    c.portrait = Art.CreatePortrait(c, width * SOCKET_D)
    c.portrait:SetPoint("CENTER", c, "TOPLEFT", width * SOCKET_X, -height * SOCKET_Y)
    c.portrait:Hide()
    -- "face down to your opponent" badge: a small card back in the corner + a label
    c.mark = CreateFrame("Frame", nil, c)
    c.mark:SetAllPoints()
    c.mark:SetFrameLevel(c:GetFrameLevel() + 5)
    c.mark.back = c.mark:CreateTexture(nil, "OVERLAY")
    c.mark.back:SetTexture(Art.Tex("cards/back"))
    c.mark.back:SetSize(width * 0.34, width * 0.34 * Cards.ASPECT)
    c.mark.back:SetPoint("TOPRIGHT", -2, -2)
    c.mark.text = c.mark:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    c.mark.text:SetPoint("BOTTOM", 0, 3)
    c.mark.text:SetText("|cffffd100face down|r")
    c.mark:Hide()
    c.width, c.height = width, height
    return c
end

--- Shows the badge for "your hole card - your opponent can't see it".
function Cards.SetHiddenMark(c, on)
    c.mark:SetShown(on and true or false)
end

--- card = rules card, or nil for a face-down card.
function Cards.Set(c, card)
    c.card = card
    if not card then
        c.base:SetTexture(Art.Tex("cards/back"))
        c.portrait:Hide()
        return
    end
    c.base:SetTexture(Art.Tex("cards/" .. Cards.Code(card)))
    local icon, frame = Cards.Portrait(card)
    if icon then
        Art.SetPortrait(c.portrait, icon, frame)
        c.portrait:Show()
    else
        c.portrait:Hide()
    end
end

--- A row of card widgets that grows as needed. Returns the row frame.
function Cards.CreateRow(parent, width, gap)
    local row = CreateFrame("Frame", nil, parent)
    row.cards, row.cardWidth, row.gap = {}, width, gap or 4
    row:SetSize(width, math.floor(width * Cards.ASPECT + 0.5))
    return row
end

--- cards: rules cards, or false for a face-down card. markIndex: which card gets the
--- "face down to your opponent" badge (your own hole card).
function Cards.SetRow(row, cards, faceDownExtra, markIndex)
    local list = {}
    for i = 1, #(cards or {}) do list[i] = cards[i] end
    for _ = 1, faceDownExtra or 0 do list[#list + 1] = false end
    for i, card in ipairs(list) do
        local w = row.cards[i]
        if not w then
            w = Cards.Create(row, row.cardWidth)
            -- overlap cards a little once the hand gets long
            row.cards[i] = w
        end
        local step = row.cardWidth + row.gap
        if #list > 5 then step = math.floor((row.cardWidth * 5 + row.gap * 4 - row.cardWidth) / (#list - 1)) end
        w:ClearAllPoints()
        w:SetPoint("LEFT", row, "LEFT", (i - 1) * step, 0)
        Cards.Set(w, card or nil)
        Cards.SetHiddenMark(w, i == markIndex and card)
        w:Show()
    end
    for i = #list + 1, #row.cards do row.cards[i]:Hide() end
end
