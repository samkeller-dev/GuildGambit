-- Rules/Blackjack.lua: pure blackjack rules (no WoW API).
--
-- Cards come from server rolls 1-52 drawn with replacement (an "infinite shoe").
-- Standard deal: player and dealer both get two cards; the dealer's second card is shown
-- face down until the player is done, and a dealer blackjack ends the hand at once (peek).
-- Dealer stands on all 17s. Blackjack pays 3:2. Double on the first two cards (one more
-- card). No splits or insurance in this version.
local ADDON_NAME, ns = ...
ns.Rules = ns.Rules or {}

local BJ = {}
ns.Rules.Blackjack = BJ

BJ.ROLL_MIN, BJ.ROLL_MAX = 1, 52

local RANKS = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }
local SUITS = { "s", "h", "d", "c" }
local SUIT_COLORS = { s = "e0e0e0", h = "ff4040", d = "ff4040", c = "e0e0e0" }

--- roll (1-52) -> card { rank = 1..13, suit = "s"/"h"/"d"/"c" }
function BJ.Card(roll)
    assert(roll >= 1 and roll <= 52, "card roll out of range")
    local i = roll - 1
    return { rank = (i % 13) + 1, suit = SUITS[math.floor(i / 13) + 1] }
end

function BJ.CardText(card)
    return ("|cff%s%s%s|r"):format(SUIT_COLORS[card.suit], RANKS[card.rank], card.suit)
end

function BJ.HandText(cards)
    local parts = {}
    for i, c in ipairs(cards) do parts[i] = BJ.CardText(c) end
    return table.concat(parts, " ")
end

--- Returns best total and whether it is soft (an ace counted as 11).
function BJ.Value(cards)
    local total, aces = 0, 0
    for _, c in ipairs(cards) do
        local v = c.rank >= 10 and 10 or c.rank
        if c.rank == 1 then aces = aces + 1 end
        total = total + v
    end
    if aces > 0 and total + 10 <= 21 then return total + 10, true end
    return total, false
end

function BJ.IsBlackjack(cards)
    return #cards == 2 and (BJ.Value(cards)) == 21
end

function BJ.IsBust(cards)
    return (BJ.Value(cards)) > 21
end

function BJ.ValueText(cards)
    local v, soft = BJ.Value(cards)
    if BJ.IsBlackjack(cards) then return "Blackjack" end
    if v > 21 then return v .. " bust" end
    return (soft and "soft " or "") .. v
end

--- The dealer always gets two cards in the deal, then (once the player is done) draws while
--- below 17 and stands on all 17s. No drawing after a player bust or either side's blackjack.
function BJ.DealerNeedsCard(dealer, player)
    if #dealer < 2 then return true end
    if BJ.IsBust(player) or BJ.IsBlackjack(player) or BJ.IsBlackjack(dealer) then return false end
    return (BJ.Value(dealer)) < 17
end

--- Final outcome once both sides are done.
--- Returns outcome ("blackjack","win","push","lose","bust") and the player's net multiple of
--- the base bet (doubled hands count double).
function BJ.Outcome(player, dealer, doubled)
    local stake = doubled and 2 or 1
    if BJ.IsBust(player) then return "bust", -stake end
    local pBJ, dBJ = BJ.IsBlackjack(player), BJ.IsBlackjack(dealer)
    if pBJ and dBJ then return "push", 0 end
    if pBJ then return "blackjack", 1.5 end
    if dBJ then return "lose", -stake end
    local p, d = BJ.Value(player), BJ.Value(dealer)
    if d > 21 or p > d then return "win", stake end
    if p == d then return "push", 0 end
    return "lose", -stake
end
