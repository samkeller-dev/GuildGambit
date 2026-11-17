-- Lottery.lua: the guild lottery.
--
-- An officer opens one: ticket price, most tickets per player, the draw date/time (Brisbane
-- time) and the guildie whose character holds the pot. Only one lottery runs at a time and it
-- can't be cancelled. Players buy tickets at a mailbox: the addon mails the ticket gold to the
-- pot character (the subject carries the lottery's id) and the tickets count as soon as the
-- game confirms the mail was sent. Sales close 1h15m before the draw - longer than the hour
-- mail takes to arrive - so every ticket's gold is in the pot character's mailbox by the draw.
--
-- How everyone agrees on the tickets:
--   * the buyer's addon tells every guildie online, and every addon passes on what it knows to
--     anyone who logs in later (counts only ever go up);
--   * the pot character's addon reads its mailbox and records the gold each player sent, and
--     shares that. A player's tickets are the more of what they claimed and what their gold
--     pays for (never more than the limit), so a paid ticket counts even if no addon ever
--     passed the purchase on.
-- The creator draws (any officer may once it's 3 days overdue): their addon asks everyone
-- online for the latest tickets, waits a moment, then does one server /roll 1-<tickets>.
-- The result goes out with the exact ticket list used, so every player can check theirs were
-- in it; any that weren't are listed as owed back. Paying the winner (and any such refund) is
-- done by hand by the pot character, who marks it done for everyone to see.
local ADDON_NAME, ns = ...
local Comm, Compat = ns.Comm, ns.Compat

local Lottery = {}
ns.Lottery = Lottery

Lottery.SUBJECT = "GuildGambit lottery "  -- .. lottery id
Lottery.MAX_TICKETS = 100        -- the most "tickets per player" an officer can allow
Lottery.SALES_CLOSE = 75 * 60    -- ticket sales close this long before the draw
Lottery.TAKEOVER = 3 * 86400     -- after the draw time + this, any officer may draw
Lottery.SYNC_WAIT = 5            -- seconds the drawer waits for everyone's tickets
Lottery.ROLL_TIMEOUT = 30        -- seconds to see the draw's roll before giving up
Lottery.MAIL_WAIT = 8            -- seconds before saying the mail is taking a while
Lottery.MONEY_WAIT = 5           -- seconds after "mail sent" for the gold to leave our bags
Lottery.BRISBANE = 10 * 3600     -- UTC+10, no daylight saving

local function Now() return (GetServerTime and GetServerTime()) or time() end
Lottery.Now = Now

local function Changed()
    if ns.UI then ns.UI.Refresh() end
end

---------------------------------------------------------------------------
-- Brisbane time
---------------------------------------------------------------------------
--- "Sun 23 Nov 20:00 Brisbane time"
function Lottery.When(t)
    return date("!%a %d %b %H:%M", (t or 0) + Lottery.BRISBANE) .. " Brisbane time"
end

local function DaysFromCivil(y, m, d) -- days since 1970-01-01 (proleptic Gregorian)
    y = m <= 2 and y - 1 or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

--- The moment that is hour:minute (Brisbane time) on the Brisbane date `dayOffset` days from today.
function Lottery.BrisbaneTime(dayOffset, hour, minute)
    local today = date("!*t", Now() + Lottery.BRISBANE)
    local days = DaysFromCivil(today.year, today.month, today.day) + (dayOffset or 0)
    return days * 86400 + (hour or 0) * 3600 + (minute or 0) * 60 - Lottery.BRISBANE
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local function GuildKey()
    local name = IsInGuild and IsInGuild() and Compat.Safe((GetGuildInfo("player")))
    return name or "_noguild"
end

--- This guild's lottery record: { cur = lottery or nil, prev = { id, winner, pot, at } or nil }.
function Lottery.Data()
    ns.db.lottery = ns.db.lottery or {}
    local key = GuildKey()
    ns.db.lottery[key] = ns.db.lottery[key] or {}
    return ns.db.lottery[key]
end

function Lottery.Current() return Lottery.Data().cur end
function Lottery.Previous() return Lottery.Data().prev end

local function Fresh(L)
    L.tickets, L.received, L.collected, L.inbox = L.tickets or {}, L.received or {}, L.collected or {}, L.inbox or {}
    L.taking, L.manual = L.taking or {}, L.manual or {} -- (pot character only)
    return L
end

function Lottery.SalesClose(L) return L.drawAt - Lottery.SALES_CLOSE end
function Lottery.SalesOpen(L)
    return L ~= nil and L.state == "open" and L.announced == true and Now() < Lottery.SalesClose(L)
end

--- A player's tickets: what they claim or what their gold pays for, whichever is more, up to the limit.
function Lottery.TicketsOf(L, name)
    local claimed = L.tickets[name] or 0
    local paid = L.price > 0 and math.floor((L.received[name] or 0) / L.price) or 0
    return math.min(L.max, math.max(claimed, paid))
end

--- { { name, n, stake, received, verified } } most tickets first.
function Lottery.Players(L)
    if not L then return {} end
    Fresh(L)
    local names, out = {}, {}
    for name in pairs(L.tickets) do names[name] = true end
    for name in pairs(L.received) do names[name] = true end
    for name in pairs(names) do
        local n = Lottery.TicketsOf(L, name)
        if n > 0 then
            local received = L.received[name] or 0
            out[#out + 1] = { name = name, n = n, stake = n * L.price, received = received,
                verified = received >= n * L.price,
                manual = (L.manual[name] or 0) > (L.collected[name] or 0) + (L.inbox[name] or 0) }
        end
    end
    table.sort(out, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.name < b.name
    end)
    return out
end

--- Tickets sold, and the pot (copper).
function Lottery.Totals(L)
    local n = 0
    for _, e in ipairs(Lottery.Players(L)) do n = n + e.n end
    return n, n * (L and L.price or 0)
end

function Lottery.Mine(L) return L and Lottery.TicketsOf(Fresh(L), ns.Me()) or 0 end

---------------------------------------------------------------------------
-- Officers
---------------------------------------------------------------------------
function Lottery.IsOfficer()
    local function try(fn) if type(fn) == "function" then local ok, v = pcall(fn) return ok and v == true end end
    -- the game's own officer check (proven on Forever), or the guild master. Only if the game had no
    -- officer check at all would "can edit officer notes" stand in (a permission any rank can be given).
    if try(_G.IsGuildLeader) then return true end
    local officer = (C_GuildInfo and C_GuildInfo.IsGuildOfficer) or _G.IsGuildOfficer
    if type(officer) == "function" then return try(officer) end
    return try(_G.CanEditOfficerNote) or try(C_GuildInfo and C_GuildInfo.CanEditOfficerNote) or false
end

--- Guild members known to have GuildGambit (online or not), for the pot-holder picker.
function Lottery.Candidates()
    local seen, out = {}, {}
    local function add(name)
        name = ns.Full(name)
        -- any spelling of my own name ("Eoka" vs the server's "Eoka Pistol") is me, listed once
        if name and ns.IsMe(name) then name = ns.Me() end
        if not name or seen[name] then return end
        if ns.Guild.rosterKnown and not ns.Guild.IsMember(name) and not ns.IsMe(name) then return end
        seen[name] = true
        out[#out + 1] = name
    end
    add(ns.Me())
    for name in pairs(ns.House.peers) do add(name) end
    if ns.Board then for name in pairs(ns.Board.Table()) do add(name) end end
    if ns.Wealth then for name in pairs(ns.Wealth.Table()) do add(name) end end
    table.sort(out)
    return out
end

--- True if `name` may draw: the creator, or (3 days overdue) any officer.
local function MayDraw(L, name, isOfficer)
    if L.state ~= "open" or Now() < L.drawAt then return false end
    if ns.SameName(name, L.by) then return true end
    return isOfficer and Now() >= L.drawAt + Lottery.TAKEOVER
end

function Lottery.CanDraw(L)
    L = L or Lottery.Current()
    return L ~= nil and MayDraw(L, ns.Me(), Lottery.IsOfficer()) and not Lottery.drawing
end

---------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------
local function NewFields(L)
    return { id = L.id, by = L.by, p = L.pot, c = L.price, m = L.max, d = L.drawAt, t = L.created,
        a = L.announced and 1 or nil, dr = (L.dateRev or 0) > 0 and L.dateRev or nil }
end

--- A newer draw date (higher revision) than ours: take it. Returns true if it changed.
local function TakeDate(L, drawAt, rev)
    drawAt, rev = tonumber(drawAt), tonumber(rev) or 0
    if not drawAt or L.state ~= "open" or rev <= (L.dateRev or 0) then return false end
    local old = L.drawAt
    L.drawAt, L.dateRev = drawAt, rev
    return old ~= drawAt
end

local function Batches(list, fn)
    local parts, cur = {}, ""
    for _, item in ipairs(list) do
        if #cur + #item + 1 > 180 then parts[#parts + 1] = cur cur = "" end
        cur = cur == "" and item or (cur .. ";" .. item)
    end
    if cur ~= "" then parts[#parts + 1] = cur end
    for i, part in ipairs(parts) do fn(i, #parts, part) end
end

local function SendClaims(L, target)
    local items = {}
    for name, n in pairs(L.tickets) do if n > 0 then items[#items + 1] = name .. ":" .. n end end
    table.sort(items)
    Batches(items, function(_, _, part) Comm.Send("LOT_TS", { id = L.id, b = part }, target) end)
end

local function SendReceipts(L, target) -- the pot character only
    local items = {}
    for name, g in pairs(L.received) do if g > 0 then items[#items + 1] = name .. ":" .. g end end
    table.sort(items)
    -- rr: receipts revision - a higher one replaces everyone's copy (after a correction)
    local rr = (L.rcvRev or 0) > 0 and L.rcvRev or nil
    Batches(items, function(_, _, part) Comm.Send("LOT_RCV", { id = L.id, b = part, ck = L.potChecked, rr = rr }, target) end)
    if #items == 0 and (L.potChecked or rr) then Comm.Send("LOT_RCV", { id = L.id, b = "", ck = L.potChecked, rr = rr }, target) end
end

local function SendResult(L, target)
    if L.state ~= "drawn" then return end
    Comm.Send("LOT_WIN", { id = L.id, w = L.winner or "", r = L.roll or 0, n = L.drawnTotal or 0,
        g = L.potGold or 0, at = L.drawnAt or 0, by = L.drawnBy or "", pd = L.paid and 1 or nil,
        rf = L.refundsDone and 1 or nil }, target)
    local items = {}
    for name, n in pairs(L.drawn or {}) do items[#items + 1] = name .. ":" .. n end
    table.sort(items)
    Batches(items, function(i, n, part) Comm.Send("LOT_DL", { id = L.id, i = i, n = n, b = part }, target) end)
end

--- Everything we know, to one player (a guildie who just logged in) or the guild.
function Lottery.Share(target)
    local data = Lottery.Data()
    for id, by in pairs(data.closed or {}) do Comm.Send("LOT_CLOSE", { id = id, by = by }, target) end
    local prev = data.prev
    if prev then Comm.Send("LOT_PREV", { id = prev.id, w = prev.winner, g = prev.pot, at = prev.at }, target) end
    local L = data.cur
    if not L then return end
    Fresh(L)
    Comm.Send("LOT_NEW", NewFields(L), target)
    SendClaims(L, target)
    if ns.IsMe(L.pot) then SendReceipts(L, target) end
    SendResult(L, target)
end

-- a guildie logged in: pass on what we know (only to them)
function Lottery.OnHello(sender)
    local data = Lottery.Data()
    if data.cur or data.prev or next(data.closed or {}) then Lottery.Share(sender) end
end

local function KeepPrevious(data, L)
    if L and L.state == "drawn" and L.winner and L.winner ~= "" then
        data.prev = { id = L.id, winner = L.winner, pot = L.potGold, at = L.drawnAt }
    end
end

--- Adopts a lottery heard from someone else. One at a time: a running lottery is only ever
--- replaced by an OLDER one (the first opened wins, everywhere); a finished one by any newer one.
local function Adopt(f)
    local data = Lottery.Data()
    local L = data.cur
    local created = tonumber(f.t) or 0
    if data.closed and data.closed[f.id] then return nil end -- closed by its creator: gone for good
    if L and L.id == f.id then
        if f.a == "1" then L.announced = true end
        TakeDate(L, f.d, f.dr) -- (passed on by someone who heard about a date change we missed)
        return L
    end
    if L then
        local mine = L.created or 0
        if L.state == "open" then
            local theirsFirst = created < mine or (created == mine and tostring(f.id) < tostring(L.id))
            if not theirsFirst then return nil end
            if ns.IsMe(L.by) then
                ns.Log("|cffff8040Another lottery was already open (by %s) - yours has been withdrawn.|r", ns.Short(f.by))
            end
        elseif mine > created then
            return nil -- a finished lottery gives way to any newer (or same-age) one
        end
    end
    KeepPrevious(data, L)
    L = Fresh({ id = f.id, by = ns.Full(f.by), pot = ns.Full(f.p), price = tonumber(f.c) or 0, max = tonumber(f.m) or 1,
        drawAt = tonumber(f.d) or 0, created = created, state = "open", announced = f.a == "1",
        dateRev = tonumber(f.dr) or 0 })
    data.cur = L
    return L
end

-- (quietly: guildies are only told once the creator clicks Announce)
Comm.On("LOT_NEW", function(f, sender)
    if not f.id or not ns.Guild.Allowed(sender) then return end
    Adopt(f)
    Changed()
end)

local function AnnounceText(L)
    return ("|cffffd100%s opened a guild lottery!|r Tickets %s each (up to %d), drawn %s. Buy them at a mailbox from the Live tab."):format(
        ns.Short(L.by), ns.Money(L.price), L.max, Lottery.When(L.drawAt))
end

-- the creator announced it: ticket sales are open
Comm.On("LOT_ANN", function(f, sender)
    local L = Lottery.Current()
    if not L or L.id ~= f.id or not ns.SameName(sender, L.by) or L.state ~= "open" then return end
    local first = not L.announced
    L.announced = true
    if first then
        ns.Log(AnnounceText(L))
        ns.Sound("invite")
    end
    Changed()
end)

-- the creator closed it (before anyone bought a ticket)
Comm.On("LOT_CLOSE", function(f, sender)
    local data = Lottery.Data()
    local L = data.cur
    if not f.id then return end
    if L and L.id == f.id then
        if not ns.SameName(f.by or sender, L.by) then return end
        if L.state ~= "open" then return end
        if Lottery.Totals(L) > 0 then
            -- we know of tickets the creator doesn't: keep it, and show them
            Comm.Send("LOT_NOCLOSE", { id = L.id }, sender)
            Lottery.Share(sender)
            return
        end
        data.cur = nil
        if L.announced then ns.Log("The guild lottery was closed by %s before any tickets were sold.", ns.Short(L.by)) end
    end
    data.closed = data.closed or {}
    data.closed[f.id] = f.by or sender
    Changed()
end)

-- someone knew of tickets I didn't: the close is undone everywhere and the lottery comes back
Comm.On("LOT_NOCLOSE", function(f, sender)
    local data = Lottery.Data()
    if not f.id or not (data.closed and data.closed[f.id]) or not ns.IsMe(data.closed[f.id]) then return end
    data.closed[f.id] = nil
    Comm.Send("LOT_REOPEN", { id = f.id, by = ns.Me() }, nil)
    ns.Log("|cffff8040Couldn't close the lottery: %s knows of tickets already bought.|r It's back on the Live tab.", ns.Short(sender))
    -- (their copy arrives right after this message; then pass it on to everyone)
    C_Timer.After(2, function() if data.cur and data.cur.id == f.id then Lottery.Share(nil) end end)
end)

Comm.On("LOT_REOPEN", function(f, sender)
    local data = Lottery.Data()
    if f.id and data.closed and data.closed[f.id] and ns.SameName(data.closed[f.id], sender) then
        data.closed[f.id] = nil
    end
end)

local function Merge(map, name, n)
    name = ns.Full(name)
    n = tonumber(n) or 0
    if not name or n <= 0 then return false end
    if n > (map[name] or 0) then map[name] = n return true end -- counts only ever go up
    return false
end

local CheckMissed -- (below, with the draw) tickets that turn up after the draw are owed back

-- a buyer's own tickets: only accepted from the buyer
Comm.On("LOT_T", function(f, sender)
    local L = Lottery.Current()
    if not L or L.id ~= f.id then return end
    Fresh(L)
    if f.n and not ns.SameName(f.n, sender) then return end
    Merge(L.tickets, sender, math.min(tonumber(f.k) or 0, L.max))
    if L.state == "drawn" then CheckMissed(L) end
    Changed()
end)

-- everyone's claims, passed on (to a late joiner, or the drawer)
Comm.On("LOT_TS", function(f, sender)
    local L = Lottery.Current()
    if not L or L.id ~= f.id then return end
    Fresh(L)
    for name, n in (f.b or ""):gmatch("([^:;]+):(%d+)") do Merge(L.tickets, name, math.min(tonumber(n), L.max)) end
    if L.state == "drawn" then CheckMissed(L) end
    Changed()
end)

-- the pot character's receipts: only accepted from the pot character
Comm.On("LOT_RCV", function(f, sender)
    local L = Lottery.Current()
    if not L or L.id ~= f.id or not ns.SameName(sender, L.pot) then return end
    Fresh(L)
    local rr = tonumber(f.rr) or 0
    if rr < (L.rcvRev or 0) then return end -- from before a correction
    if rr > (L.rcvRev or 0) then L.received, L.rcvRev = {}, rr end -- corrected: start again from these
    for name, g in (f.b or ""):gmatch("([^:;]+):(%d+)") do Merge(L.received, name, g) end
    local ck = tonumber(f.ck)
    if ck and ck > (L.potChecked or 0) then L.potChecked = ck end
    if L.state == "drawn" then CheckMissed(L) end
    Changed()
end)

---------------------------------------------------------------------------
-- Opening
---------------------------------------------------------------------------
--- opts: { pot = name, price = copper, max = tickets per player, drawAt = epoch }
function Lottery.Open(opts)
    if not Lottery.IsOfficer() then ns.Print("Only guild officers can open a lottery.") return nil end
    local data = Lottery.Data()
    local cur = data.cur
    if cur and cur.state == "open" then ns.Print("A lottery is already running - only one at a time.") return nil end
    local pot = opts.pot and ns.Full(opts.pot)
    if not pot then ns.Print("Pick the character that holds the pot.") return nil end
    local price, max, drawAt = tonumber(opts.price), tonumber(opts.max), tonumber(opts.drawAt)
    if not price or price <= 0 then ns.Print("Set a ticket price.") return nil end
    if not max or max < 1 or max > Lottery.MAX_TICKETS then
        ns.Print("Tickets per player must be 1-%d.", Lottery.MAX_TICKETS) return nil
    end
    if not drawAt or drawAt - Lottery.SALES_CLOSE <= Now() + 60 then
        ns.Print("The draw has to be more than 1h15m away (ticket sales close 1h15m before it).") return nil
    end
    KeepPrevious(data, cur)
    local L = Fresh({ id = ns.NewId(), by = ns.Me(), pot = pot, price = math.floor(price), max = math.floor(max),
        drawAt = math.floor(drawAt), created = Now(), state = "open" })
    data.cur = L
    Comm.Send("LOT_NEW", NewFields(L), nil)
    ns.Log("Lottery created (not announced yet): tickets %s each, up to %d per player, drawn %s, pot held by %s. Check it, then click |cffffd100Announce|r to open ticket sales - or |cffffd100Close lottery|r if something's wrong.",
        ns.Money(L.price), L.max, Lottery.When(L.drawAt), ns.Short(L.pot))
    Changed()
    return L
end

Lottery.ANNOUNCE_EVERY = 300 -- the creator can re-post the announcement, at most this often

--- The creator: tell the guild (guild chat and everyone's addon) and open ticket sales.
function Lottery.Announce()
    local L = Lottery.Current()
    if not L or L.state ~= "open" then ns.Print("There's no lottery to announce.") return false end
    if not ns.IsMe(L.by) then ns.Print("Only %s, who opened this lottery, can announce it.", ns.Short(L.by)) return false end
    if Now() >= Lottery.SalesClose(L) then ns.Print("Too late to announce - ticket sales would already be closed.") return false end
    if L.announcedAt and Now() - L.announcedAt < Lottery.ANNOUNCE_EVERY then
        ns.Print("You announced it a moment ago.") return false
    end
    L.announced, L.announcedAt = true, Now()
    Comm.Send("LOT_ANN", { id = L.id }, nil)
    Comm.Send("LOT_NEW", NewFields(L), nil)
    -- a deliberate click, so it's posted even with guild chat muted for game results
    local send = (C_ChatInfo and C_ChatInfo.SendChatMessage) or _G.SendChatMessage
    if send and IsInGuild and IsInGuild() then
        pcall(send, ("[GuildGambit] Guild lottery open! Tickets %s each (up to %d per player), drawn %s. Buy them at a mailbox from GuildGambit's Live tab."):format(
            ns.Money(L.price), L.max, Lottery.When(L.drawAt)), "GUILD")
    end
    ns.Log("Lottery announced - ticket sales are open.")
    Changed()
    return true
end

-- the creator moved the draw
Comm.On("LOT_DATE", function(f, sender)
    local L = Lottery.Current()
    if not L or L.id ~= f.id or not ns.SameName(sender, L.by) then return end
    if TakeDate(L, f.d, f.dr) then
        ns.Log("|cffffd100The guild lottery's draw has moved to %s|r (by %s). Tickets you've bought still count.",
            Lottery.When(L.drawAt), ns.Short(sender))
    end
    Changed()
end)

--- The creator: move the draw (earlier or later). Tickets already bought keep counting.
function Lottery.ChangeDate(drawAt)
    local L = Lottery.Current()
    drawAt = math.floor(tonumber(drawAt) or 0)
    if not L or L.state ~= "open" then ns.Print("There's no running lottery to change.") return false end
    if not ns.IsMe(L.by) then ns.Print("Only %s, who opened this lottery, can change its date.", ns.Short(L.by)) return false end
    if Lottery.drawing then ns.Print("The draw is happening right now.") return false end
    if drawAt - Lottery.SALES_CLOSE <= Now() + 60 then
        ns.Print("The draw has to be more than 1h15m away (ticket sales close 1h15m before it).") return false
    end
    if drawAt == L.drawAt then ns.Print("That's already the draw time.") return false end
    L.drawAt, L.dateRev = drawAt, (L.dateRev or 0) + 1
    Comm.Send("LOT_DATE", { id = L.id, d = L.drawAt, dr = L.dateRev }, nil)
    ns.Log("Lottery draw moved to %s. Ticket sales close at %s.%s", Lottery.When(L.drawAt),
        date("!%H:%M", Lottery.SalesClose(L) + Lottery.BRISBANE),
        L.announced and " Click Announce again if you want to post the new date in guild chat." or "")
    if L.announcedAt then L.announcedAt = nil end -- (so the new date can be announced straight away)
    Changed()
    return true
end

--- True if the creator may close it: still open, and nobody has a ticket (or has sent gold).
function Lottery.CanClose(L)
    L = L or Lottery.Current()
    if not L or L.state ~= "open" or not ns.IsMe(L.by) then return false end
    Fresh(L)
    if Lottery.Totals(L) > 0 then return false end
    for _, g in pairs(L.received) do if g > 0 then return false end end
    return true
end

--- The creator: remove the lottery everywhere (only before any ticket is bought).
function Lottery.Close()
    local L = Lottery.Current()
    if not L or L.state ~= "open" then ns.Print("There's no lottery to close.") return false end
    if not ns.IsMe(L.by) then ns.Print("Only %s, who opened this lottery, can close it.", ns.Short(L.by)) return false end
    if not Lottery.CanClose(L) then ns.Print("Tickets have been bought - the lottery can't be closed now.") return false end
    local data = Lottery.Data()
    data.cur = nil
    data.closed = data.closed or {}
    data.closed[L.id] = ns.Me()
    Comm.Send("LOT_CLOSE", { id = L.id, by = ns.Me() }, nil)
    ns.Log("Lottery closed.")
    Changed()
    return true
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
--- Which player holds ticket number `ticket`: players in name order, consecutive numbers.
function Lottery.Owner(list, ticket)
    local names = {}
    for name, n in pairs(list) do if n > 0 then names[#names + 1] = name end end
    table.sort(names)
    local upto = 0
    for _, name in ipairs(names) do
        upto = upto + list[name]
        if ticket <= upto then return name end
    end
end

--- Tells me I won (once), whenever I find out.
local function TellWinner(L)
    if not L or not L.winner or L.winner == "" or not ns.IsMe(L.winner) then return end
    ns.charDB.lotteryWon = ns.charDB.lotteryWon or {}
    if ns.charDB.lotteryWon[L.id] then return end
    ns.charDB.lotteryWon[L.id] = true
    ns.Log("|cff20ff20You won the guild lottery!|r The pot is %s - %s will mail it to you.", ns.Money(L.potGold or 0),
        ns.Short(L.pot))
    ns.Sound("bigwin")
end

--- After the draw: tickets that weren't in it (owed back by the pot character, by hand).
CheckMissed = function(L)
    if not L.drawn then return end
    L.missed = {}
    for _, e in ipairs(Lottery.Players(L)) do
        local left = e.n - (L.drawn[e.name] or 0)
        if left > 0 then L.missed[e.name] = left * L.price end
    end
    local mine = L.missed[ns.Me()]
    if mine and not L.toldMissed then
        L.toldMissed = true
        ns.Log("|cffff8040%d of your lottery tickets weren't in the draw|r - %s owes you %s back. Tell an officer if it isn't sorted.",
            mine / L.price, ns.Short(L.pot), ns.Money(mine))
    end
end

local function Applies(L, f)
    -- two results (only possible in a takeover race): everyone keeps the lower-named drawer's
    if L.state ~= "drawn" then return true end
    if (L.drawnBy or "") == (f.by or "") then return false end
    return (f.by or "") < (L.drawnBy or "")
end

local function ApplyResult(L, f)
    L.state, L.winner, L.roll = "drawn", (f.w and f.w ~= "") and ns.Full(f.w) or "", tonumber(f.r)
    L.drawnTotal, L.potGold, L.drawnAt, L.drawnBy = tonumber(f.n), tonumber(f.g), tonumber(f.at), f.by
    L.drawn, L.drawnParts = nil, nil
end

Comm.On("LOT_WIN", function(f, sender)
    local L = Lottery.Current()
    if not L or L.id ~= f.id then return end
    if Applies(L, f) then
        local replaced = L.state == "drawn"
        ApplyResult(L, f)
        if replaced then ns.Log("|cffff8040Lottery: two draws happened - keeping %s's.|r", ns.Short(f.by)) end
        if L.winner ~= "" and not ns.IsMe(L.winner) then
            ns.Log("Guild lottery drawn: |cffffd100%s|r won the %s pot!", ns.Short(L.winner), ns.Money(L.potGold or 0))
        end
        if ns.LotteryUI then ns.LotteryUI.PlayDraw(L) end
    end
    if f.pd == "1" then L.paid = true end
    if f.rf == "1" then L.refundsDone = true end
    TellWinner(L)
    Changed()
end)

-- the ticket list the draw used (in parts)
Comm.On("LOT_DL", function(f, sender)
    local L = Lottery.Current()
    if not L or L.id ~= f.id or L.state ~= "drawn" or L.drawn then return end
    L.drawnParts = L.drawnParts or {}
    L.drawnParts[tonumber(f.i) or 1] = f.b or ""
    local n = tonumber(f.n) or 1
    for i = 1, n do if not L.drawnParts[i] then return end end
    local list = {}
    for i = 1, n do
        for name, k in L.drawnParts[i]:gmatch("([^:;]+):(%d+)") do list[ns.Full(name)] = tonumber(k) end
    end
    L.drawn, L.drawnParts = list, nil
    CheckMissed(L)
    Changed()
end)

-- the drawer asks for the latest tickets: send ours (and, the pot character, the receipts)
Comm.On("LOT_SYNC", function(f, sender)
    local L = Lottery.Current()
    if not L or L.id ~= f.id then return end
    Fresh(L)
    C_Timer.After(math.random() * 2, function()
        SendClaims(L, sender)
        if ns.IsMe(L.pot) then SendReceipts(L, sender) end
    end)
end)

Comm.On("LOT_PAID", function(f, sender)
    local L = Lottery.Current()
    if not L or L.id ~= f.id then return end
    if not (ns.SameName(sender, L.pot) or ns.SameName(sender, L.by)) then return end
    if f.what == "refunds" then L.refundsDone = true else L.paid = true end
    Changed()
end)

Comm.On("LOT_PREV", function(f, sender)
    local data = Lottery.Data()
    local at = tonumber(f.at) or 0
    if not f.w or f.w == "" then return end
    if data.prev and (data.prev.at or 0) >= at then return end
    if data.cur and data.cur.id == f.id then return end -- that's the current one, drawn
    data.prev = { id = f.id, winner = ns.Full(f.w), pot = tonumber(f.g) or 0, at = at }
    Changed()
end)

--- The draw button. Asks everyone for their tickets, waits a moment, then rolls.
function Lottery.Draw(force)
    local L = Lottery.Current()
    if not L or L.state ~= "open" then ns.Print("There's no lottery to draw.") return false end
    Fresh(L)
    if Now() < L.drawAt then ns.Print("The draw isn't until %s.", Lottery.When(L.drawAt)) return false end
    if not MayDraw(L, ns.Me(), Lottery.IsOfficer()) then
        ns.Print("Only %s can draw this lottery (any officer can from %s).", ns.Short(L.by), Lottery.When(L.drawAt + Lottery.TAKEOVER))
        return false
    end
    if Lottery.drawing then return false end
    -- the pot character's mailbox proves every paid ticket: warn if it hasn't been checked since sales closed
    if not force and not ns.IsMe(L.pot) and (L.potChecked or 0) < Lottery.SalesClose(L) then
        ns.UI.ShowInvite(("%s hasn't checked their mailbox since ticket sales closed, so some paid tickets may be missing. Draw anyway?"):format(
            ns.Short(L.pot)), function() Lottery.Draw(true) end, function() end)
        return false
    end
    Lottery.drawing = true
    Comm.Send("LOT_SYNC", { id = L.id }, nil)
    ns.Log("Drawing the lottery: collecting everyone's tickets...")
    Changed()
    C_Timer.After(Lottery.SYNC_WAIT, function() Lottery.Roll(L) end)
    return true
end

--- Step 2 of the draw: the roll itself, over the tickets as they are now.
function Lottery.Roll(L)
    if L ~= Lottery.Current() or L.state ~= "open" then Lottery.drawing = false Changed() return end
    local snapshot = {}
    local total = 0
    for _, e in ipairs(Lottery.Players(L)) do snapshot[e.name] = e.n total = total + e.n end
    if total == 0 then
        L.drawn = {}
        ApplyResult(L, { w = "", r = 0, n = 0, g = 0, at = Now(), by = ns.Me() })
        L.drawn = {}
        Lottery.drawing = false
        SendResult(L, nil)
        ns.Log("Lottery drawn - nobody bought a ticket.")
        Changed()
        return
    end
    local key = "lottery:" .. L.id
    local done = false
    ns.Rolls.Watch({
        player = ns.Me(), min = 1, max = total, key = key,
        onRoll = function(v)
            if done then return end
            done = true
            Lottery.drawing = false
            if L ~= Lottery.Current() or L.state ~= "open" then return end
            local winner = Lottery.Owner(snapshot, v)
            ApplyResult(L, { w = winner, r = v, n = total, g = total * L.price, at = Now(), by = ns.Me() })
            L.drawn = snapshot
            CheckMissed(L)
            SendResult(L, nil)
            ns.Log("|cffffd100Lottery drawn:|r ticket %d of %d - %s wins %s! %s holds the pot.", v, total,
                ns.Short(winner), ns.Money(L.potGold), ns.Short(L.pot))
            ns.GuildAnnounce(("[GuildGambit] Lottery drawn! %s wins the %s pot (ticket %d of %d)!"):format(
                ns.Short(winner), ns.Money(L.potGold), v, total))
            if ns.LotteryUI then ns.LotteryUI.PlayDraw(L) end
            TellWinner(L)
            Changed()
        end,
    })
    if not ns.Rolls.Roll(1, total) then
        done = true
        Lottery.drawing = false
        ns.Rolls.UnwatchPrefix(key)
        ns.Print("Couldn't roll 1-%d for the draw - try again.", total)
        Changed()
        return
    end
    C_Timer.After(Lottery.ROLL_TIMEOUT, function()
        if done then return end
        done = true
        Lottery.drawing = false
        ns.Rolls.UnwatchPrefix(key)
        ns.Log("|cffff4040The draw's roll was never seen - nothing was recorded. Click Draw again.|r")
        Changed()
    end)
end

--- The pot character (or the creator): mark the winner paid / the missed tickets refunded.
function Lottery.MarkPaid(what)
    local L = Lottery.Current()
    if not L or L.state ~= "drawn" then return false end
    if not (ns.IsMe(L.pot) or ns.IsMe(L.by)) then ns.Print("Only %s or %s can mark this.", ns.Short(L.pot), ns.Short(L.by)) return false end
    if what == "refunds" then L.refundsDone = true else L.paid = true end
    Comm.Send("LOT_PAID", { id = L.id, what = what }, nil)
    Changed()
    return true
end

---------------------------------------------------------------------------
-- Buying tickets (mailing the pot character)
---------------------------------------------------------------------------
Lottery.sending = nil -- { to, amount, n, id }

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a = pcall(fn, ...)
    if ok then return a end
end

function Lottery.MailOpen() return ns.MailPay and ns.MailPay.open or false end
function Lottery.Busy()
    return Lottery.sending ~= nil or Lottery.confirming ~= nil or (ns.MailPay and ns.MailPay.Busy())
end

function Lottery.Buy(n)
    local L = Lottery.Current()
    n = math.floor(tonumber(n) or 0)
    if not L or L.state ~= "open" then ns.Print("There's no lottery running right now.") return false end
    Fresh(L)
    if not Lottery.SalesOpen(L) then ns.Print("Ticket sales have closed (1h15m before the draw).") return false end
    if ns.IsMe(L.pot) then ns.Print("You hold the pot - you can't mail tickets to yourself.") return false end
    if n < 1 then ns.Print("Buy at least one ticket.") return false end
    local mine = Lottery.Mine(L)
    if mine + n > L.max then ns.Print("You can have at most %d tickets (you have %d).", L.max, mine) return false end
    if not Lottery.MailOpen() then ns.Print("Open a mailbox first.") return false end
    if Lottery.Busy() then ns.Print("Still sending the last mail - try again in a moment.") return false end
    local amount = n * L.price
    local postage = tonumber(Call(GetSendMailPrice)) or 30
    if (tonumber(Call(GetMoney)) or 0) < amount + postage then
        ns.Print("Not enough gold: %s plus %s postage.", ns.Money(amount), ns.Money(postage))
        return false
    end
    Call(ClearSendMail)
    if Call(SetSendMailMoney, amount) == false then ns.Print("Couldn't put %s on the mail.", ns.Money(amount)) return false end
    local job = { to = L.pot, amount = amount, n = n, id = L.id, had = mine, before = tonumber(Call(GetMoney)) }
    Lottery.sending = job
    local ok, err = pcall(SendMail, L.pot, Lottery.SUBJECT .. L.id,
        ("%d GuildGambit lottery ticket%s (%s each), drawn %s."):format(n, n == 1 and "" or "s",
            ns.Money(L.price), Lottery.When(L.drawAt)))
    if not ok then
        Lottery.sending = nil
        ns.Print("Couldn't send the mail: %s", tostring(err))
        return false
    end
    -- never give up on a slow confirmation (the gold may have gone): just say we're waiting
    C_Timer.After(Lottery.MAIL_WAIT, function()
        if Lottery.sending == job then ns.Print("Waiting for the game to confirm your ticket mail...") end
    end)
    ns.Print("Mailing %s to %s - keep the mailbox open until your tickets are confirmed.", ns.Money(amount), ns.Short(L.pot))
    Changed()
    return true
end

--- True once the ticket gold has left our bags.
local function GoldLeft(job)
    local now = tonumber(Call(GetMoney))
    if not job.before or not now then return true end -- (can't tell: trust the game's "sent")
    return job.before - now >= job.amount
end

local Claim

--- MAIL_SEND_SUCCESS (from MailPay): true if it was our ticket mail. The tickets only count
--- once the gold has actually left our bags (a "sent" mail without the gold buys nothing).
function Lottery.OnMailSent()
    local job = Lottery.sending
    if not job then return false end
    Lottery.sending = nil
    if GoldLeft(job) then Claim(job) return true end
    Lottery.confirming = job
    C_Timer.After(Lottery.MONEY_WAIT, function()
        if Lottery.confirming ~= job then return end
        Lottery.confirming = nil
        ns.Log("|cffff8040Your ticket mail was sent, but the %s didn't leave your bags|r - no tickets were bought. Check your gold and try again. (If the gold did go, your tickets count once %s's mailbox gets it.)",
            ns.Money(job.amount), ns.Short(job.to))
        Changed()
    end)
    Changed()
    return true
end

--- PLAYER_MONEY: the gold for a sent ticket mail has left our bags.
function Lottery.OnMoney()
    local job = Lottery.confirming
    if job and GoldLeft(job) then
        Lottery.confirming = nil
        Claim(job)
    end
end

Claim = function(job)
    local L = Lottery.Current()
    if L and L.id == job.id then
        Fresh(L)
        local me = ns.Me()
        L.tickets[me] = math.min(L.max, math.max(L.tickets[me] or 0, job.had + job.n))
        Comm.Send("LOT_T", { id = L.id, n = me, k = L.tickets[me] }, nil)
        ns.Log("Bought %d lottery ticket%s (%s mailed to %s). You have %d.", job.n, job.n == 1 and "" or "s",
            ns.Money(job.amount), ns.Short(job.to), L.tickets[me])
        ns.Sound("coin")
    end
    Changed()
end

function Lottery.OnMailFailed()
    local job = Lottery.sending
    if not job then return false end
    Lottery.sending = nil
    ns.Log("The ticket mail to %s failed - no gold was sent and no tickets were bought.", ns.Short(job.to))
    Changed()
    return true
end

--- The mailbox closed while a ticket mail was unconfirmed.
function Lottery.OnMailClosed()
    local job = Lottery.sending
    if not job then return end
    Lottery.sending = nil
    ns.Log("|cffff8040Couldn't confirm your ticket mail was sent.|r If the %s left your bags, your tickets will count once %s's mailbox receives it.",
        ns.Money(job.amount), ns.Short(job.to))
    Changed()
end

---------------------------------------------------------------------------
-- The pot character's mailbox: who has actually sent gold
---------------------------------------------------------------------------
--- A ticket mail's sender, matched to the name they bought under (Forever sometimes gives
--- only the first part of a name, like "Eoka" for "Eoka Pistol").
local function Buyer(L, sender)
    local full = ns.Full(sender)
    if not full or L.tickets[full] or L.received[full] then return full end
    local key = full:lower()
    for name in pairs(L.tickets) do
        local first = name:lower():match("^(%S+)")
        if name:lower() == key or (first == key and name:find(" ")) then return name end
    end
    return full
end

--- One inbox mail with gold on it: { sender, money, subject, ticket = true if it's for this lottery }.
local function ReadMail(L, i)
    local ok, _, _, sender, subject, money = pcall(GetInboxHeaderInfo, i)
    if not ok then return nil end
    sender, subject, money = Compat.Safe(sender), Compat.Safe(subject), tonumber(Compat.Safe(money)) or 0
    if not sender or money <= 0 then return nil end
    local ticket = subject == Lottery.SUBJECT .. L.id
    return { sender = ticket and Buyer(L, sender) or ns.Full(sender), money = money, subject = subject or "",
        ticket = ticket }
end

--- Recomputes received = collected + still in the inbox (or confirmed by hand). Normally it only
--- grows; rebuild = true starts again from these (after a correction).
local function Recount(L, rebuild)
    local names, changed = {}, false
    for _, t in ipairs({ L.collected, L.inbox, L.manual, rebuild and L.received or {} }) do
        for n in pairs(t) do names[n] = true end
    end
    for n in pairs(names) do
        -- (a hand confirmation covers their stake; if the mail turns up later it isn't counted twice)
        local total = math.max((L.collected[n] or 0) + (L.inbox[n] or 0), L.manual[n] or 0)
        if total > (L.received[n] or 0) or (rebuild and total ~= (L.received[n] or 0)) then
            L.received[n] = total > 0 and total or nil
            changed = true
        end
    end
    if rebuild then L.rcvRev = (L.rcvRev or 0) + 1 end
    return changed
end

--- Reads the inbox: ticket gold still waiting, and any other gold mail (shown to the pot character).
local function ReadInbox(L)
    local seen, others = {}, {}
    local count = tonumber(Call(GetInboxNumItems)) or 0
    for i = 1, count do
        local m = ReadMail(L, i)
        if m and m.ticket then
            seen[m.sender] = (seen[m.sender] or 0) + m.money
        elseif m and (L.tickets[m.sender] or (ns.Guild.IsMember and ns.Guild.IsMember(m.sender))) then
            -- (a guildie's gold mail without the ticket subject - shown, in case it's for tickets)
            others[#others + 1] = { from = m.sender, money = m.money, subject = m.subject }
        end
    end
    -- gold we've just taken can still show on its mail for a moment: don't count it twice
    L.inbox = {}
    for name, g in pairs(seen) do
        local taking = math.min(L.taking[name] or 0, g)
        if g - taking > 0 then L.inbox[name] = g - taking end
    end
    for name, t in pairs(L.taking) do
        local left = math.min(t, seen[name] or 0)
        L.taking[name] = left > 0 and left or nil
    end
    L.otherMail = others
end

--- MAIL_INBOX_UPDATE on the pot character.
function Lottery.ScanInbox()
    local L = Lottery.Current()
    if not L or not ns.IsMe(L.pot) then return end
    Fresh(L)
    ReadInbox(L)
    L.potChecked = Now()
    -- 2.1.2: taken gold used to be counted twice - put the totals right, once, for everyone
    Recount(L, not L.rcvFixed)
    L.rcvFixed = true
    if L.state == "drawn" then CheckMissed(L) end
    SendReceipts(L, nil)
    Changed()
end

--- Taking gold from a mail (hooked): if it's ticket gold, it moves from "in the inbox" to
--- "collected". The mail is read right now (not from an earlier scan), so it can't be missed
--- or mixed up with another mail.
function Lottery.OnTakeMoney(index)
    local L = Lottery.Current()
    if not L or not ns.IsMe(L.pot) then return end
    Fresh(L)
    local m = ReadMail(L, index)
    if not m or not m.ticket then return end
    ReadInbox(L)
    if (L.inbox[m.sender] or 0) < m.money then return end -- (already being taken)
    L.collected[m.sender] = (L.collected[m.sender] or 0) + m.money
    L.taking[m.sender] = (L.taking[m.sender] or 0) + m.money
    L.inbox[m.sender] = (L.inbox[m.sender] or 0) - m.money
    if L.inbox[m.sender] <= 0 then L.inbox[m.sender] = nil end
    L.potChecked = Now()
    Recount(L)
    SendReceipts(L, nil)
    Changed()
end

--- The pot character: confirm by hand that a player's ticket gold arrived (if the mailbox
--- reading ever misses it). Covers their tickets in full; undo = true takes it back.
function Lottery.Confirm(name, undo)
    local L = Lottery.Current()
    if not L or (L.state ~= "open" and L.state ~= "drawn") then ns.Print("There's no lottery to confirm gold for.") return false end
    if not ns.IsMe(L.pot) then ns.Print("Only %s, who holds the pot, can confirm gold.", ns.Short(L.pot)) return false end
    Fresh(L)
    name = name and ns.Full(name)
    if not name then ns.Print("Whose gold?") return false end
    for n in pairs(L.tickets) do if ns.SameName(n, name) then name = n end end
    if undo then
        if not L.manual[name] then ns.Print("%s's gold wasn't confirmed by hand.", ns.Short(name)) return false end
        L.manual[name] = nil
        ns.Log("Lottery: took back the hand confirmation of %s's gold.", ns.Short(name))
    else
        local stake = Lottery.TicketsOf(L, name) * L.price
        local seen = (L.collected[name] or 0) + (L.inbox[name] or 0)
        if stake <= 0 then ns.Print("%s has no tickets.", ns.Short(name)) return false end
        if seen >= stake then ns.Print("%s's gold has already arrived.", ns.Short(name)) return false end
        L.manual[name] = stake
        ns.Log("Lottery: confirmed %s's %s by hand (%d ticket%s).", ns.Short(name), ns.Money(stake),
            stake / L.price, stake == L.price and "" or "s")
    end
    Recount(L, true)
    if L.state == "drawn" then CheckMissed(L) end
    SendReceipts(L, nil)
    Changed()
    return true
end

function Lottery.HookMail()
    if Lottery.hooked or not hooksecurefunc then return end
    Lottery.hooked = true
    if TakeInboxMoney then pcall(hooksecurefunc, "TakeInboxMoney", Lottery.OnTakeMoney) end
    if AutoLootMailItem then pcall(hooksecurefunc, "AutoLootMailItem", Lottery.OnTakeMoney) end
end

--- What the pot character still has to sort out by hand: { winner = {to, amount} or nil, refunds = { {to, amount} } }
function Lottery.Owes(L)
    L = L or Lottery.Current()
    local out = { refunds = {} }
    if not L or L.state ~= "drawn" then return out end
    if not L.paid and L.winner and L.winner ~= "" and not ns.SameName(L.winner, L.pot) then
        out.winner = { to = L.winner, amount = L.potGold or 0 }
    end
    if not L.refundsDone then
        for name, amount in pairs(L.missed or {}) do out.refunds[#out.refunds + 1] = { to = name, amount = amount } end
        table.sort(out.refunds, function(a, b) return a.to < b.to end)
    end
    return out
end

--- /gg lottery check: what this client can do (for checking a new game version works).
function Lottery.Check()
    local function has(fn) return type(fn) == "function" and "|cff20ff20yes|r" or "|cffff4040missing|r" end
    local function try(fn) if type(fn) ~= "function" then return "missing" end local ok, v = pcall(fn) return ok and tostring(v) or "error" end
    ns.Print("Lottery check - officer: %s (IsGuildOfficer %s, CanEditOfficerNote %s, IsGuildLeader %s)",
        Lottery.IsOfficer() and "|cff20ff20yes|r" or "no",
        try(C_GuildInfo and C_GuildInfo.IsGuildOfficer or _G.IsGuildOfficer),
        try(_G.CanEditOfficerNote or (C_GuildInfo and C_GuildInfo.CanEditOfficerNote)), try(_G.IsGuildLeader))
    ns.Print("  mail: SendMail %s, GetInboxNumItems %s, GetInboxHeaderInfo %s, TakeInboxMoney %s | server time %s",
        has(SendMail), has(GetInboxNumItems), has(GetInboxHeaderInfo), has(TakeInboxMoney), Lottery.When(Now()))
    local L = Lottery.Current()
    if L then
        local n, pot = Lottery.Totals(L)
        ns.Print("  lottery %s: %s, %d tickets, %s pot, pot held by %s, mail last checked %s", L.id, L.state, n,
            ns.Money(pot), ns.Short(L.pot), L.potChecked and Lottery.When(L.potChecked) or "never")
        if ns.IsMe(L.pot) then -- every mail with gold on it, as the game reports it
            Fresh(L)
            local count = tonumber(Call(GetInboxNumItems)) or 0
            for i = 1, count do
                local m = ReadMail(L, i)
                if m then
                    ns.Print("  mail %d: %s from %s, \"%s\"%s", i, ns.Money(m.money), tostring(m.sender), m.subject,
                        m.ticket and " |cff20ff20(ticket)|r" or "")
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Login reminders
---------------------------------------------------------------------------
function Lottery.Remind()
    local L = Lottery.Current()
    if not L then return end
    Fresh(L)
    TellWinner(L)
    local now = Now()
    if L.state == "open" then
        if now >= L.drawAt and MayDraw(L, ns.Me(), Lottery.IsOfficer()) then
            ns.Print("|cffffd100Lottery:|r the draw time has passed - draw it from the Live tab (or |cffffff00/gg lottery draw|r).")
        elseif not L.announced and ns.IsMe(L.by) then
            ns.Print("|cffffd100Lottery:|r yours isn't announced yet - click Announce on the lottery page to open ticket sales.")
        elseif not L.announced then
            -- not announced yet: nothing to remind anyone of
        elseif ns.IsMe(L.pot) and now >= Lottery.SalesClose(L) and (L.potChecked or 0) < Lottery.SalesClose(L) then
            ns.Print("|cffffd100Lottery:|r ticket sales have closed - open your mailbox so every paid ticket is counted before the draw.")
        elseif Lottery.SalesOpen(L) and ns.charDB.lotteryRemindDay ~= date("%Y%m%d") then
            ns.charDB.lotteryRemindDay = date("%Y%m%d")
            local _, pot = Lottery.Totals(L)
            local mine = Lottery.Mine(L)
            ns.Print("|cffffd100Guild lottery:|r %s pot, drawn %s. %s Tickets are %s - buy them at a mailbox from the Live tab (sales close 1h15m before the draw).",
                ns.Money(pot), Lottery.When(L.drawAt),
                mine > 0 and ("You have " .. mine .. " ticket" .. (mine == 1 and "" or "s") .. ".") or "You haven't got a ticket yet.",
                ns.Money(L.price))
        end
    elseif L.state == "drawn" and ns.IsMe(L.pot) then
        local owes = Lottery.Owes(L)
        if owes.winner then
            ns.Print("|cffffd100Lottery:|r you hold the pot - mail %s their %s, then click Mark as paid on the lottery page.",
                ns.Short(owes.winner.to), ns.Money(owes.winner.amount))
        end
        if #owes.refunds > 0 then
            ns.Print("|cffffd100Lottery:|r %d player%s had tickets that missed the draw - see the lottery page.",
                #owes.refunds, #owes.refunds == 1 and "" or "s")
        end
    end
end
