-- Rules/Slots.lua: pure slot machine rules (no WoW API).
-- One server roll 1-1000 decides all three reels: roll-1 is 000..999, one digit per reel.
local ADDON_NAME, ns = ...
ns.Rules = ns.Rules or {}

local Slots = {}
ns.Rules.Slots = Slots

Slots.ROLL_MIN, Slots.ROLL_MAX = 1, 1000

-- Digit -> symbol. Frequencies: Cherry 3, Lemon 2, Orange 2, Bell 1, Bar 1, Seven 1.
Slots.REEL = { [0] = "Cherry", "Cherry", "Cherry", "Lemon", "Lemon", "Orange", "Orange", "Bell", "Bar", "Seven" }

-- Total return as a multiple of the bet (1 = bet back, 0 = lose the bet).
Slots.PAYTABLE = {
    { name = "Triple Seven", mult = 100, icons = { "Seven", "Seven", "Seven" }, test = function(a, b, c) return a == "Seven" and b == "Seven" and c == "Seven" end },
    { name = "Triple Bar", mult = 50, icons = { "Bar", "Bar", "Bar" }, test = function(a, b, c) return a == "Bar" and b == "Bar" and c == "Bar" end },
    { name = "Triple Bell", mult = 25, icons = { "Bell", "Bell", "Bell" }, test = function(a, b, c) return a == "Bell" and b == "Bell" and c == "Bell" end },
    { name = "Triple Orange", mult = 10, icons = { "Orange", "Orange", "Orange" }, test = function(a, b, c) return a == "Orange" and b == "Orange" and c == "Orange" end },
    { name = "Triple Lemon", mult = 10, icons = { "Lemon", "Lemon", "Lemon" }, test = function(a, b, c) return a == "Lemon" and b == "Lemon" and c == "Lemon" end },
    { name = "Triple Cherry", mult = 8, icons = { "Cherry", "Cherry", "Cherry" }, test = function(a, b, c) return a == "Cherry" and b == "Cherry" and c == "Cherry" end },
    { name = "Two Cherries", mult = 2, icons = { "Cherry", "Cherry" }, test = function(a, b, c)
        local n = (a == "Cherry" and 1 or 0) + (b == "Cherry" and 1 or 0) + (c == "Cherry" and 1 or 0)
        return n == 2
    end },
}

Slots.COLORS = {
    Cherry = "ff3030", Lemon = "ffff40", Orange = "ff9020", Bell = "ffd100", Bar = "c0c0c0", Seven = "40a0ff",
}

--- roll (1-1000) -> { reels = {a,b,c}, mult, name }
function Slots.Spin(roll)
    assert(roll >= Slots.ROLL_MIN and roll <= Slots.ROLL_MAX, "slot roll out of range")
    local n = roll - 1
    local a = Slots.REEL[math.floor(n / 100) % 10]
    local b = Slots.REEL[math.floor(n / 10) % 10]
    local c = Slots.REEL[n % 10]
    for _, line in ipairs(Slots.PAYTABLE) do
        if line.test(a, b, c) then
            return { reels = { a, b, c }, mult = line.mult, name = line.name }
        end
    end
    return { reels = { a, b, c }, mult = 0, name = "No win" }
end

--- Player's net in copper for a bet (+ = player wins).
function Slots.Net(bet, result)
    return math.floor(bet * result.mult) - bet
end

function Slots.Describe(result)
    local parts = {}
    for i, sym in ipairs(result.reels) do
        parts[i] = ("|cff%s%s|r"):format(Slots.COLORS[sym] or "ffffff", sym)
    end
    return table.concat(parts, " | ") .. " - " .. result.name ..
        (result.mult > 0 and (" (x" .. result.mult .. ")") or "")
end

--- Expected return to the player per 1 bet, over all 1000 rolls (for tests/tuning).
function Slots.ReturnToPlayer()
    local total = 0
    for r = Slots.ROLL_MIN, Slots.ROLL_MAX do total = total + Slots.Spin(r).mult end
    return total / (Slots.ROLL_MAX - Slots.ROLL_MIN + 1)
end
