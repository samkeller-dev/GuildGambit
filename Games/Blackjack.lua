-- Games/Blackjack.lua: player vs a guildie's house (the dealer).
--
-- Every card is a server roll: the player rolls 1-52 for their own cards (each roll after
-- the deal is a hit), the dealer rolls 1-52 for the dealer's cards. Both clients run the
-- same state machine from the same rolls, so they agree on the result.
-- Stand and double are messages carrying the card count they apply at, so they work in
-- either order relative to the rolls.
-- Practice: you are both player and dealer; dealer cards use /roll 101-152 so the two
-- kinds of roll can't be confused.
local ADDON_NAME, ns = ...
local Games, Rolls, Comm = ns.Games, ns.Rolls, ns.Comm
local Rules = ns.Rules.Blackjack

local BJ = {}
ns.Blackjack = BJ

BJ.ANSWER_TIMEOUT = 15
BJ.DEALER_DELAY = 0.8
BJ.PRACTICE = "Practice"
BJ.PRACTICE_OFFSET = 100

local Update

local function IsPlayer(game) return not game.asHouse end
local function IsDealer(game) return game.asHouse or game.practice end

local function DealerRange(game)
    local off = game.practice and BJ.PRACTICE_OFFSET or 0
    return Rules.ROLL_MIN + off, Rules.ROLL_MAX + off, off
end

local function Trim(cards, n)
    for i = #cards, n + 1, -1 do cards[i] = nil end
end

--- What this client's player may do right now.
function BJ.CanAct(game)
    if game and game.kind ~= "blackjack" then return false end -- e.g. /gg stand during slots
    if game and game.mode == "duel" then
        local mine = BJ.MyHand(game)
        return game.state == "play" and not mine.done and #mine.cards >= 2
    end
    return game and game.kind == "blackjack" and IsPlayer(game) and game.state == "play"
        and not game.pDone and #game.p >= 2 and #game.d >= 2
end

--- The dealer's second card stays face down until the player is done (house games only:
--- in a head-to-head game both hands are open).
function BJ.HoleHidden(game)
    if game.mode == "duel" then return false end
    return not game.finished and not game.pDone and #game.d >= 2
end

--- Dealer (or opponent) cards to show face up.
function BJ.VisibleDealer(game)
    if BJ.HoleHidden(game) then return { game.d[1] } end
    return game.d
end

function BJ.CanDouble(game)
    if game and game.mode == "duel" then
        local mine = BJ.MyHand(game)
        return BJ.CanAct(game) and #mine.cards == 2 and not mine.doubled
    end
    return BJ.CanAct(game) and #game.p == 2 and not game.doubled
end

local function StatusText(game)
    local you = IsPlayer(game) and "You" or ns.Short(game.opponent)
    local p = #game.p > 0 and (Rules.HandText(game.p) .. " (" .. Rules.ValueText(game.p) .. ")") or "-"
    local shown = BJ.VisibleDealer(game)
    local d = #shown > 0 and (Rules.HandText(shown) .. (BJ.HoleHidden(game) and " ??" or "")
        .. " (" .. Rules.ValueText(shown) .. ")") or "-"
    return ("%s: %s\nDealer: %s%s"):format(you, p, d, game.doubled and "\n(doubled)" or "")
end

local function Finish(game)
    local outcome, mult = Rules.Outcome(game.p, game.d, game.doubled)
    game.bigWin, game.bust = outcome == "blackjack", outcome == "bust"
    local playerNet = math.floor(game.bet * mult)
    if game.asHouse then ns.House.bjGame = nil end
    local summary = ("%s %s vs dealer %s - %s"):format(
        IsPlayer(game) and "you" or ns.Short(game.opponent),
        Rules.ValueText(game.p), Rules.ValueText(game.d), outcome)
    local sign = mult > 0 and 1 or mult < 0 and -1 or 0
    Games.Finish(game, game.asHouse and -playerNet or playerNet, summary, game.asHouse and -sign or sign)
end

local function DealerRoll(game, j)
    local lo, hi = DealerRange(game)
    game.autoRolled = game.autoRolled or {}
    if game.autoRolled[j] then return end
    game.autoRolled[j] = true
    C_Timer.After(BJ.DEALER_DELAY, function()
        local key = game.id .. ":d" .. j
        if Games.Get(game.id) ~= game or not Rolls.IsWatching(key) then return end
        if not Rolls.Roll(lo, hi) then
            -- RandomRoll unavailable: the dealer has to click Roll / type it
            game.dealerPrompt = { key = key, lo = lo, hi = hi }
            BJ.Prompt(game)
        end
    end)
end

--- Sets the Roll button for this client: the player's next card first, then a pending
--- manual dealer roll, otherwise nothing.
function BJ.Prompt(game)
    local p, d = game.p, game.d
    if IsPlayer(game) and not game.pDone and (#p < 2 or #d >= 2) then
        ns.UI.SetRollPrompt(Rules.ROLL_MIN, Rules.ROLL_MAX, #p < 2 and "Deal card" or "Hit")
    elseif game.dealerPrompt and Rolls.IsWatching(game.dealerPrompt.key) then
        ns.UI.SetRollPrompt(game.dealerPrompt.lo, game.dealerPrompt.hi, "Dealer roll")
    else
        ns.UI.SetRollPrompt(nil)
    end
end

local function WatchPlayerCard(game)
    local i = #game.p + 1
    local key = game.id .. ":p" .. i
    if Rolls.IsWatching(key) then return end
    Rolls.UnwatchPrefix(game.id .. ":p")
    Rolls.Watch({
        player = game.player, min = Rules.ROLL_MIN, max = Rules.ROLL_MAX, key = key,
        relayTo = (IsPlayer(game) and not game.practice) and { game.opponent } or nil,
        onRoll = function(v, verified)
            if #game.p ~= i - 1 then return end
            Games.NoteRoll(game, verified)
            ns.Sound("card")
            game.p[i] = Rules.Card(v)
            Update(game)
        end,
    })
    -- the opening two cards deal themselves; after that each roll is a Hit you choose
    if i <= 2 and IsPlayer(game) then
        C_Timer.After(BJ.DEALER_DELAY, function()
            if Games.Get(game.id) == game and Rolls.IsWatching(key) then
                Rolls.Roll(Rules.ROLL_MIN, Rules.ROLL_MAX) -- if it fails, the Roll button still says "Deal card"
            end
        end)
    end
end

local function WatchDealerCard(game)
    local j = #game.d + 1
    local key = game.id .. ":d" .. j
    if not Rolls.IsWatching(key) then
        local lo, hi, off = DealerRange(game)
        Rolls.Watch({
            player = game.dealer, min = lo, max = hi, key = key,
            relayTo = (game.asHouse and not game.practice) and { game.opponent } or nil,
            onRoll = function(v, verified)
                if #game.d ~= j - 1 then return end
                Games.NoteRoll(game, verified)
                ns.Sound("card")
                game.d[j] = Rules.Card(v - off)
                Update(game)
            end,
        })
    end
    if IsDealer(game) then DealerRoll(game, j) end
end

--- Central state step, run after every card or action on both clients.
function Update(game)
    if Games.Get(game.id) ~= game or game.state ~= "play" then return end
    local p, d = game.p, game.d

    -- stand/double are authoritative: drop any card rolled past them
    if game.standAt and #p > game.standAt then Trim(p, game.standAt) end
    if game.doubleAt and #p > game.doubleAt + 1 then Trim(p, game.doubleAt + 1) end

    if not game.pDone and #p >= 2 then
        if Rules.IsBlackjack(p) or Rules.IsBust(p) or (Rules.Value(p)) == 21
            or (game.doubleAt and #p >= game.doubleAt + 1)
            or (game.standAt and #p >= game.standAt) then
            game.pDone = true
        end
    end

    -- player bust: no dealer cards needed
    if game.pDone and Rules.IsBust(p) then return Finish(game) end

    -- dealer peek: with both hands dealt, a dealer blackjack ends the hand straight away
    if #p >= 2 and #d >= 2 and Rules.IsBlackjack(d) and not game.standAt and not game.doubled then
        game.pDone = true
        return Finish(game)
    end

    -- player cards: two in the deal, then one per hit once the dealer has both cards
    if not game.pDone and (#p < 2 or #d >= 2) then
        WatchPlayerCard(game)
    else
        Rolls.UnwatchPrefix(game.id .. ":p")
    end

    -- dealer cards: two in the deal, then draw to 17 once the player is done
    if #d < 2 or (game.pDone and Rules.DealerNeedsCard(d, p)) then
        WatchDealerCard(game)
    elseif game.pDone then
        return Finish(game)
    end

    -- prompt and status for this client
    game.status = StatusText(game)
    BJ.Prompt(game)
    ns.UI.Refresh()
end

local function Begin(game)
    game.state = "play"
    ns.Log("Blackjack: %s vs dealer %s for %s.",
        IsPlayer(game) and "you" or ns.Short(game.player),
        game.practice and "(practice)" or (game.asHouse and "you" or ns.Short(game.dealer)),
        ns.Stake(game.bet))
    Update(game)
end

local function NewGame(fields)
    fields.kind = "blackjack"
    fields.title = fields.asHouse and "Blackjack (house)" or "Blackjack"
    fields.p, fields.d, fields.verified = {}, {}, true
    fields.pDone, fields.doubled = false, false
    return Games.Add(fields)
end

---------------------------------------------------------------------------
-- Player actions
---------------------------------------------------------------------------
--- Blackjack against a guildie (head to head), or solo against the dealer with "practice".
function BJ.Deal(opponent, betGold)
    if Games.Busy() then
        ns.Print("Finish your current game first (or |cffffff00/gg cancel|r).")
        return nil
    end
    local bet = ns.GoldToCopper(betGold)
    if not bet then ns.Print("Usage: /gg bj <wager> <player|practice>") return nil end
    if not opponent or opponent == "" then
        ns.Print("Pick an opponent (or Practice) first.")
        return nil
    end
    if not (opponent:lower() == "practice" or ns.IsMe(opponent)) then
        return BJ.Challenge(opponent, betGold) -- every real game is 1v1
    end
    -- practice: you against the dealer, your client plays both sides
    local game = NewGame({
        id = ns.NewId(), player = ns.Me(), dealer = ns.Me(),
        opponent = BJ.PRACTICE, bet = bet, practice = true, state = "wait",
    })
    Begin(game)
    return game
end

function BJ.Hit(game)
    if not BJ.CanAct(game) then return false end
    return Rolls.Roll(Rules.ROLL_MIN, Rules.ROLL_MAX)
end

function BJ.Stand(game)
    if game and game.mode == "duel" then return BJ.DuelStand(game) end
    if not BJ.CanAct(game) then return false end
    game.standAt = #game.p
    if not game.practice then Comm.Send("BJ_ST", { id = game.id, n = game.standAt }, game.opponent) end
    Update(game)
    return true
end

function BJ.Double(game)
    if game and game.mode == "duel" then return BJ.DuelDouble(game) end
    if not BJ.CanDouble(game) then return false end
    game.doubled, game.doubleAt = true, 2
    if not game.practice then Comm.Send("BJ_DB", { id = game.id }, game.opponent) end
    ns.Log("Doubled to %s - dealing your one extra card...", ns.Money(game.bet * 2))
    Update(game)
    -- the double card deals itself (it can bust you)
    local key = game.id .. ":p3"
    C_Timer.After(BJ.DEALER_DELAY, function()
        if Games.Get(game.id) == game and Rolls.IsWatching(key) then
            Rolls.Roll(Rules.ROLL_MIN, Rules.ROLL_MAX)
        end
    end)
    return true
end

---------------------------------------------------------------------------
-- Head-to-head blackjack: two guildies, no house.
--
-- Deal: each player's addon rolls their face-up card, then their hole card - automatically.
-- You see both your cards (the hole card is marked); your opponent sees your hole card face
-- down, like a normal table. Then each plays their own hand: hit, stand or double. When both
-- are done the hole cards are revealed and the better hand wins. A blackjack beats any other
-- 21; both bust, or equal totals, is a push. Doubling doubles the bet (both double: x4).
--
-- Keeping the hole card secret when every /roll is public (commit-reveal):
--   1. Your addon picks a secret number 0-51 and sends a SHA-256 fingerprint of it.
--   2. Once the opponent confirms they have the fingerprint, you /roll 1-52 publicly.
--   3. Hole card = (roll + secret) mod 52. You know it; they only know the roll.
--   4. At showdown you reveal the secret; their addon checks it against the fingerprint.
-- The secret is locked before the roll, so it can't be chosen to fit; a mismatch or no
-- reveal forfeits the hand.
---------------------------------------------------------------------------
BJ.DUEL_INVITE_TIMEOUT = 60
BJ.DUEL_ACCEPT_RETRY = 5
BJ.DUEL_ACCEPT_RETRIES = 6
BJ.DUEL_DEAL_DELAY = 0.6     -- seconds before each automatic deal roll
BJ.DUEL_RESEND = 3           -- resend fingerprint / reveal every few seconds until answered
BJ.DUEL_REVEAL_ASK_EVERY = 5 -- ask again for a missing reveal this often...
BJ.DUEL_REVEAL_ASKS = 8      -- ...this many times (about 40s) before it counts as a forfeit

--- The secret behind a hole card (tests replace this to make deals predictable).
function BJ.PickSecret() return math.random(0, 51) end

local UpdateDuel

local function MySide(game) return ns.IsMe(game.a) and "a" or "b" end
local function OtherSide(s) return s == "a" and "b" or "a" end
local function SidePlayer(game, s) return s == "a" and game.a or game.b end

function BJ.MyHand(game) return game.hands[MySide(game)] end
function BJ.TheirHand(game) return game.hands[OtherSide(MySide(game))] end

local function Fingerprint(salt, n) return ns.SHA256(salt .. ":" .. n) end
local function HoleCard(roll, n) return Rules.Card((roll - 1 + n) % 52 + 1) end

--- Cards that are known (face-down entries are `false`).
local function Known(cards)
    local out = {}
    for _, c in ipairs(cards) do if c then out[#out + 1] = c end end
    return out
end

--- "17", or "10 + ?" while a card is face down.
function BJ.DuelValueText(cards)
    local known = Known(cards)
    local hidden = #known < #cards
    if #known == 0 then return hidden and "?" or "" end
    if hidden then
        local v = Rules.Value(known)
        return v .. " + ?"
    end
    return Rules.ValueText(cards)
end

local function DuelScore(cards)
    if Rules.IsBust(cards) then return -1 end
    if Rules.IsBlackjack(cards) then return 22 end -- beats a many-card 21
    return (Rules.Value(cards))
end

local function DuelMultiplier(game)
    local m = 1
    for _, h in pairs(game.hands) do if h.doubled then m = m * 2 end end
    return m
end

local function FinishDuel(game, forfeit)
    local mine, theirs = BJ.MyHand(game), BJ.TheirHand(game)
    local stake = game.bet * DuelMultiplier(game)
    game.wagered = stake
    local net, why, outcome
    if forfeit then
        net, why, outcome = stake, forfeit, 1
    else
        local a, b = DuelScore(mine.cards), DuelScore(theirs.cards)
        game.bust, game.bigWin = a == -1, a == 22 and b ~= 22
        outcome = a > b and 1 or (a < b and -1 or 0)
        net = stake * outcome
        why = ("you %s vs %s %s"):format(Rules.ValueText(mine.cards), ns.Short(game.opponent), Rules.ValueText(theirs.cards))
    end
    Games.Finish(game, net, why, outcome)
end

-- Rolls ------------------------------------------------------------------

local function AutoRoll(game, key, label)
    C_Timer.After(BJ.DUEL_DEAL_DELAY, function()
        if Games.Get(game.id) ~= game or not Rolls.IsWatching(key) then return end
        if not Rolls.Roll(Rules.ROLL_MIN, Rules.ROLL_MAX) then
            game.manualDeal = label -- RandomRoll unavailable: the Roll button deals instead
            UpdateDuel(game)
        end
    end)
end

--- Watches card i of side s. onCard(value, verified) receives the raw roll.
local function WatchCard(game, s, i, onRoll)
    local key = game.id .. ":" .. s .. i
    if Rolls.IsWatching(key) then return key, false end
    local player = SidePlayer(game, s)
    Rolls.Watch({
        player = player, min = Rules.ROLL_MIN, max = Rules.ROLL_MAX, key = key,
        relayTo = ns.IsMe(player) and { game.opponent } or nil,
        onRoll = function(v, verified)
            Games.NoteRoll(game, verified)
            ns.Sound("card")
            onRoll(v)
            UpdateDuel(game)
        end,
    })
    return key, true
end

-- My hand ---------------------------------------------------------------

local function SendFingerprint(game)
    local mine = BJ.MyHand(game)
    if Games.Get(game.id) ~= game or mine.acked then return end
    Comm.Send("BJD_COMMIT", { id = game.id, h = mine.fingerprint }, game.opponent)
    C_Timer.After(BJ.DUEL_RESEND, function() SendFingerprint(game) end)
end

-- reveals we've sent, kept after our side finishes so a late request can still be answered
BJ.sentReveals = {}

local function SendReveal(game)
    local mine, theirs = BJ.MyHand(game), BJ.TheirHand(game)
    if Games.Get(game.id) ~= game then return end
    Comm.Send("BJD_REVEAL", { id = game.id, n = mine.secret, s = mine.salt }, game.opponent)
    BJ.sentReveals[game.id] = { n = mine.secret, s = mine.salt, to = game.opponent }
    mine.revealSent = true
    if not theirs.revealed then
        C_Timer.After(BJ.DUEL_RESEND, function()
            if Games.Get(game.id) == game and not BJ.TheirHand(game).revealed then SendReveal(game) end
        end)
    end
end

local function StepMine(game)
    local s = MySide(game)
    local mine = game.hands[s]
    local c = mine.cards
    if mine.standAt and #c > mine.standAt then Trim(c, mine.standAt) end
    if mine.doubleAt and #c > mine.doubleAt + 1 then Trim(c, mine.doubleAt + 1) end

    if #c == 0 then
        -- face-up card
        local key, new = WatchCard(game, s, 1, function(v) if #c == 0 then c[1] = Rules.Card(v) end end)
        if new then AutoRoll(game, key, "Deal card") end
    elseif #c == 1 then
        -- hole card: lock in the secret first, then roll once the opponent has the fingerprint
        if not mine.fingerprint then
            mine.secret, mine.salt = BJ.PickSecret(), ns.RandomSalt()
            mine.fingerprint = Fingerprint(mine.salt, mine.secret)
            SendFingerprint(game)
        end
        if mine.acked then
            local key, new = WatchCard(game, s, 2, function(v)
                if #c == 1 then
                    mine.holeRoll = v
                    c[2] = HoleCard(v, mine.secret)
                end
            end)
            if new then AutoRoll(game, key, "Deal hole card") end
        end
    elseif not mine.done then
        if Rules.IsBlackjack(c) or Rules.IsBust(c) or (Rules.Value(c)) == 21
            or (mine.doubleAt and #c >= mine.doubleAt + 1) or (mine.standAt and #c >= mine.standAt) then
            mine.done = true
            Rolls.UnwatchPrefix(game.id .. ":" .. s)
            Comm.Send("BJD_DONE", { id = game.id, n = #c }, game.opponent)
        else
            local i = #c + 1
            WatchCard(game, s, i, function(v) if #c == i - 1 then c[i] = Rules.Card(v) end end)
        end
    end
end

-- Their hand ------------------------------------------------------------

local function StepTheirs(game)
    local s = OtherSide(MySide(game))
    local theirs = game.hands[s]
    local c = theirs.cards
    if theirs.doneN and #c > theirs.doneN then Trim(c, theirs.doneN) end
    if #c == 0 then
        WatchCard(game, s, 1, function(v) if #c == 0 then c[1] = Rules.Card(v) end end)
    elseif #c == 1 then
        -- the hole roll only counts once we've acknowledged their fingerprint
        if theirs.fingerprint then
            WatchCard(game, s, 2, function(v)
                if #c == 1 then
                    theirs.holeRoll = v
                    c[2] = false -- face down until they reveal
                    -- their reveal arrived before we'd seen the hole roll: apply it now
                    if theirs.pendingReveal then BJ.ApplyReveal(game, theirs.pendingReveal) end
                end
            end)
        end
    elseif theirs.doneN and #c >= theirs.doneN then
        theirs.done = true
        Rolls.UnwatchPrefix(game.id .. ":" .. s)
    elseif not theirs.done then
        local i = #c + 1
        WatchCard(game, s, i, function(v) if #c == i - 1 then c[i] = Rules.Card(v) end end)
    end
end

function UpdateDuel(game)
    if Games.Get(game.id) ~= game or game.state ~= "play" then return end
    StepMine(game)
    StepTheirs(game)
    local mine, theirs = BJ.MyHand(game), BJ.TheirHand(game)

    if mine.done and theirs.done then
        if not mine.revealSent then
            SendReveal(game)
            -- their reveal may get lost: ask for it again before ever calling it a forfeit
            local asks = 0
            local function ask()
                if Games.Get(game.id) ~= game or BJ.TheirHand(game).revealed then return end
                asks = asks + 1
                if asks > BJ.DUEL_REVEAL_ASKS then
                    return FinishDuel(game, ns.Short(game.opponent) .. " never showed their hole card")
                end
                Comm.Send("BJD_WANT", { id = game.id }, game.opponent)
                C_Timer.After(BJ.DUEL_REVEAL_ASK_EVERY, ask)
            end
            C_Timer.After(BJ.DUEL_REVEAL_ASK_EVERY, ask)
        end
        if theirs.revealed then
            if theirs.cheated then
                return FinishDuel(game, ns.Short(game.opponent) .. "'s hole card didn't match its fingerprint")
            end
            return FinishDuel(game)
        end
    end

    game.status = ("You: %s\n%s: %s%s"):format(
        #mine.cards > 0 and (Rules.HandText(Known(mine.cards)) .. " (" .. BJ.DuelValueText(mine.cards) .. ")") or "dealing...",
        ns.Short(game.opponent),
        #theirs.cards > 0 and (Rules.HandText(Known(theirs.cards)) .. (#Known(theirs.cards) < #theirs.cards and " ??" or "")
            .. " (" .. BJ.DuelValueText(theirs.cards) .. ")") or "dealing...",
        mine.done and (theirs.done and "  - revealing..." or ("  - waiting for " .. ns.Short(game.opponent))) or "")

    local c = mine.cards
    if not mine.done and #c >= 2 then
        ns.UI.SetRollPrompt(Rules.ROLL_MIN, Rules.ROLL_MAX, "Hit")
    elseif game.manualDeal and ((#c == 0) or (#c == 1 and mine.acked)) then
        ns.UI.SetRollPrompt(Rules.ROLL_MIN, Rules.ROLL_MAX, game.manualDeal)
    else
        ns.UI.SetRollPrompt(nil)
    end
    ns.UI.Refresh()
end

local function NewDuel(fields)
    fields.kind, fields.mode, fields.title = "blackjack", "duel", "Blackjack duel"
    fields.verified = true
    fields.hands = { a = { cards = {} }, b = { cards = {} } }
    local game = Games.Add(fields)
    -- the table view shows game.p (my cards) and game.d (theirs); my hole card is index 2
    game.p, game.d, game.myHole = BJ.MyHand(game).cards, BJ.TheirHand(game).cards, 2
    return game
end

local function BeginDuel(game)
    game.state = "play"
    ns.Log("Blackjack duel vs %s for %s: dealing two cards each...", ns.Short(game.opponent), ns.Stake(game.bet))
    UpdateDuel(game)
end

--- Challenges a guildie to head-to-head blackjack.
function BJ.Challenge(target, betGold)
    if Games.Busy() then
        ns.Print("Finish your current game first (or |cffffff00/gg cancel|r).")
        return nil
    end
    local bet = ns.GoldToCopper(betGold)
    if not bet or not target or target == "" then ns.Print("Usage: /gg bj <wager> <player>") return nil end
    local cant = ns.CantCover(bet)
    if cant then ns.Print("Can't bet %s: you %s.", ns.Stake(bet), cant) return nil end
    target = ns.Full(target)
    if ns.House.CheckOpponent(target) then return nil end
    local game = NewDuel({ id = ns.NewId(), a = ns.Me(), b = target, opponent = target, bet = bet, state = "invite" })
    game.status = ("Waiting for %s to accept..."):format(ns.Short(target))
    Comm.Send("BJD_INV", { id = game.id, s = bet }, target)
    ns.Log("Challenged %s to blackjack for %s.", ns.Short(target), ns.Stake(bet))
    C_Timer.After(BJ.DUEL_INVITE_TIMEOUT, function()
        if Games.Get(game.id) == game and game.state == "invite" then Games.Cancel(game, "no answer") end
    end)
    ns.UI.Refresh()
    return game
end

function BJ.DuelStand(game)
    if not BJ.CanAct(game) then return false end
    local mine = BJ.MyHand(game)
    mine.standAt = #mine.cards
    UpdateDuel(game)
    return true
end

function BJ.DuelDouble(game)
    if not BJ.CanDouble(game) then return false end
    local mine = BJ.MyHand(game)
    mine.doubled, mine.doubleAt = true, 2
    Comm.Send("BJD_DB", { id = game.id }, game.opponent)
    ns.Log("Doubled - the bet is now %s. Dealing your one extra card...", ns.Money(game.bet * DuelMultiplier(game)))
    UpdateDuel(game)
    -- the double card deals itself (it can bust you)
    AutoRoll(game, game.id .. ":" .. MySide(game) .. "3", "Deal card")
    return true
end

local function TheirDuel(f, sender)
    local game = Games.Get(f.id)
    if game and game.mode == "duel" and ns.SameName(game.opponent, sender) then return game end
end

Comm.On("BJD_INV", function(f, sender)
    local bet = tonumber(f.s)
    if not f.id or not bet or bet < 0 then return end
    local function no(reason) Comm.Send("BJD_NO", { id = f.id, r = reason }, sender) end
    if Games.Busy() then return no("busy") end
    if not ns.Guild.Allowed(sender) then return no("not in my guild") end
    local why = ns.House.CheckOpponent(sender) -- e.g. their GuildGambit is outdated (shown in chat)
    if why then return no(why) end
    local cant = ns.CantCover(bet)
    if cant then return no("can't cover " .. ns.Stake(bet) .. " - " .. cant) end
    local text = ("%s challenges you to blackjack for %s. You each get two cards and play your own hand."):format(
        ns.Short(sender), ns.Stake(bet))
    ns.UI.ShowInvite(text, function()
        if Games.Busy() then return no("busy") end
        if ns.CantCover(bet) then return no("can't cover the bet") end
        local game = NewDuel({ id = f.id, a = sender, b = ns.Me(), opponent = sender, bet = bet })
        Comm.Send("BJD_ACC", { id = f.id }, sender)
        BeginDuel(game)
        local tries = 0
        local function retry()
            if Games.Get(game.id) ~= game or #BJ.TheirHand(game).cards > 0 then return end
            tries = tries + 1
            if tries > BJ.DUEL_ACCEPT_RETRIES then return Games.Cancel(game, ns.Short(sender) .. " never started") end
            Comm.Send("BJD_ACC", { id = f.id }, sender)
            C_Timer.After(BJ.DUEL_ACCEPT_RETRY, retry)
        end
        C_Timer.After(BJ.DUEL_ACCEPT_RETRY, retry)
    end, function() no("declined") end)
end)

Comm.On("BJD_ACC", function(f, sender)
    local game = TheirDuel(f, sender)
    if game then
        if game.state == "invite" then BeginDuel(game) end
        return
    end
    Comm.Send("BJD_GONE", { id = f.id }, sender)
end)

Comm.On("BJD_NO", function(f, sender)
    local game = TheirDuel(f, sender)
    if game and game.state == "invite" then
        ns.Log("%s declined blackjack (%s).", ns.Short(sender), f.r or "no reason")
        Games.Remove(game)
    end
end)

Comm.On("BJD_GONE", function(f, sender)
    local game = TheirDuel(f, sender)
    if game and #BJ.TheirHand(game).cards == 0 then Games.Cancel(game, "the challenge had expired", true) end
end)

-- their fingerprint: keep the first one, confirm receipt (they roll their hole card after this)
Comm.On("BJD_COMMIT", function(f, sender)
    local game = TheirDuel(f, sender)
    if not game or type(f.h) ~= "string" or #f.h ~= 64 then return end
    local theirs = BJ.TheirHand(game)
    if theirs.fingerprint and theirs.fingerprint ~= f.h then return end
    theirs.fingerprint = f.h
    Comm.Send("BJD_CACK", { id = game.id }, sender)
    UpdateDuel(game)
end)

-- they have our fingerprint: we may roll our hole card
Comm.On("BJD_CACK", function(f, sender)
    local game = TheirDuel(f, sender)
    if not game then return end
    local mine = BJ.MyHand(game)
    if mine.fingerprint and not mine.acked then
        mine.acked = true
        UpdateDuel(game)
    end
end)

Comm.On("BJD_DONE", function(f, sender)
    local game, n = TheirDuel(f, sender), tonumber(f.n)
    if not game or not n or n < 2 then return end
    local theirs = BJ.TheirHand(game)
    if not theirs.doneN then
        theirs.doneN = n
        UpdateDuel(game)
    end
end)

Comm.On("BJD_DB", function(f, sender)
    local game = TheirDuel(f, sender)
    if not game then return end
    local theirs = BJ.TheirHand(game)
    if not theirs.doubled then
        theirs.doubled = true
        UpdateDuel(game)
    end
end)

--- Checks their revealed secret against the fingerprint and turns their hole card face up.
function BJ.ApplyReveal(game, f)
    local theirs = BJ.TheirHand(game)
    if theirs.revealed then return end
    if not theirs.holeRoll then
        theirs.pendingReveal = f -- keep it until we've seen their hole roll
        return
    end
    theirs.pendingReveal = nil
    local n = tonumber(f.n)
    theirs.revealed = true
    if not n or n < 0 or n > 51 or n % 1 ~= 0 or type(f.s) ~= "string"
        or Fingerprint(f.s, n) ~= theirs.fingerprint then
        theirs.cheated = true
    else
        theirs.cards[2] = HoleCard(theirs.holeRoll, n)
    end
    UpdateDuel(game)
end

Comm.On("BJD_REVEAL", function(f, sender)
    local game = TheirDuel(f, sender)
    if game then BJ.ApplyReveal(game, f) end
end)

-- they're still waiting for our reveal (ours got lost): send it again
Comm.On("BJD_WANT", function(f, sender)
    local game = TheirDuel(f, sender)
    if game then
        if BJ.MyHand(game).done then SendReveal(game) end
        return
    end
    -- our side already finished (we got their reveal first): answer from what we sent
    local sent = f.id and BJ.sentReveals[f.id]
    if sent and ns.SameName(sent.to, sender) then
        Comm.Send("BJD_REVEAL", { id = f.id, n = sent.n, s = sent.s }, sender)
    end
end)

---------------------------------------------------------------------------
-- Safety net: a 1-52 roll of ours that no game claimed, while we have Hit available, is a
-- hit. (In-game a hit card was once missed and the hand settled on the old total.)
---------------------------------------------------------------------------
Rolls.OnUnclaimed(function(who, roll, lo, hi)
    if not ns.IsMe(who) or lo ~= Rules.ROLL_MIN or hi ~= Rules.ROLL_MAX then return false end
    local game = Games.Mine()
    if not game or game.kind ~= "blackjack" or game.state ~= "play" then return false end
    if game.mode == "duel" then
        local mine = BJ.MyHand(game)
        if mine.done or #mine.cards < 2 then return false end
        local s = MySide(game)
        local i = #mine.cards + 1
        Rolls.Unwatch(game.id .. ":" .. s .. i)
        mine.cards[i] = Rules.Card(roll)
        Comm.Send("ROLL", { k = game.id .. ":" .. s .. i, v = roll, a = lo, b = hi }, game.opponent)
        ns.Sound("card")
        UpdateDuel(game)
        return true
    end
    if not BJ.CanAct(game) then return false end
    local i = #game.p + 1
    Rolls.Unwatch(game.id .. ":p" .. i)
    game.p[i] = Rules.Card(roll)
    if not game.practice then
        Comm.Send("ROLL", { k = game.id .. ":p" .. i, v = roll, a = lo, b = hi }, game.opponent)
    end
    ns.Sound("card")
    Update(game)
    return true
end)
