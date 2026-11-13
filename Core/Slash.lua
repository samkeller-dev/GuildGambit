-- Slash.lua: /gg and /guildgambit. Every game action is available here as well as in the UI.
local ADDON_NAME, ns = ...
local Compat = ns.Compat

local Slash = {}
ns.Slash = Slash

local commands = {}

local HELP = {
    "/gg - open the window",
    "Wagers: 10 (gold), 1.5, or gold/silver/copper like 1g 50s 25c. 0 = just for fun.",
    "/gg dr <player|practice> <wager> [start] - deathroll (default start 1000)",
    "/gg group <wager> [start] - open a group deathroll for the guild | /gg start - start it",
    "/gg kodo <wager> <player|practice> - Kodo Crossing: one run each on the same lanes, higher score wins",
    "/gg bj <wager> <player|practice> - blackjack",
    "/gg flip <wager> <player|practice> [alliance|horde] - coinflip: heads Alliance, tails Horde",
    "/gg roll | hit | stand | double | cancel - act in your game",
    "/gg accept | decline - answer a challenge",
    "/gg ledger - who owes whom | /gg board - leaderboard | /gg wealth [player] - guild wealth chart",
    "/gg paid <player> <amount> | received <player> <amount> - record a payment (they confirm it)",
    "/gg settle <player> - clear everything with a player (they confirm it)",
    "/gg art - check the dragon frames | art <kind> cx cy d - adjust",
    "/gg undo - remove your last game (e.g. a mistyped bet)",
    "/gg whispers on|off - whisper your rolls to opponents outside your group",
    "/gg sound on|off - sound effects | /gg announce on|off - post your wins in guild chat",
    "/gg reset <password> - new leaderboard season, clears all debts",
    "/gg minimap - show/hide the minimap button",
    "/gg guildonly on|off | debug | info",
}

commands[""] = function() ns.UI.Toggle() end
commands.show = commands[""]

commands.help = function()
    for _, line in ipairs(HELP) do ns.Print(line) end
end

-- Forever names can be two words ("Love Crits"), so a name is every word up to the first
-- number: "/gg dr Love Crits 10 1000".
local function NameThenNumbers(...)
    local words, name, rest = { ... }, {}, {}
    for i, w in ipairs(words) do
        if ns.GoldToCopper(w) then
            for j = i, #words do rest[#rest + 1] = words[j] end
            break
        end
        name[#name + 1] = w
    end
    return (#name > 0 and table.concat(name, " ") or nil), rest[1], rest[2]
end

--- "<gold> [name words...]"
local function NumberThenName(gold, ...)
    local rest = { ... }
    return gold, (#rest > 0 and table.concat(rest, " ") or nil)
end

commands.dr = function(...)
    local target, gold, start = NameThenNumbers(...)
    ns.Deathroll.Challenge(target, gold, start)
end
commands.deathroll = commands.dr

-- Slots was retired in 1.7.0, replaced by Kodo Crossing
commands.slots = function()
    ns.Print("Slots has been retired - challenge someone to Kodo Crossing instead: |cffffff00/gg kodo <wager> <player>|r")
end
commands.spin = commands.slots

-- "/gg kodo <wager> <player words...>"
commands.kodo = function(gold, ...)
    local words = { ... }
    ns.Kodo.Challenge(#words > 0 and table.concat(words, " ") or nil, gold)
end
commands.arcade = function() ns.UI.SetShown(true) ns.UI.SelectTab("arcade") end
commands.wealth = function(...)
    local name = table.concat({ ... }, " ")
    if name ~= "" then ns.WealthUI.ShowPlayer(name) else ns.WealthUI.Toggle() end
end

commands.bj = function(...)
    local gold, house = NumberThenName(...)
    ns.Blackjack.Deal(house, gold)
end
commands.blackjack = commands.bj

-- "/gg flip <gold> <player words...> [alliance|horde|heads|tails]"
commands.flip = function(gold, ...)
    local words = { ... }
    local call
    if #words > 1 and ns.Coinflip.ParseCall(words[#words]) then call = ns.Coinflip.ParseCall(table.remove(words)) end
    ns.Coinflip.Challenge(#words > 0 and table.concat(words, " ") or nil, gold, call)
end
commands.coinflip = commands.flip

commands.roll = function()
    local p = ns.UI.GetRollPrompt()
    if p and p.action then p.action()
    elseif p then ns.Rolls.Roll(p.lo, p.hi)
    else ns.Print("Nothing to roll right now.") end
end

-- "/gg group <wager> [start]": a room for the whole guild; "/gg start" once people have joined
commands.group = function(...)
    local wager, start = ... -- gold/silver/copper parts are already glued into one word
    ns.GroupDeathroll.Open(wager, start)
end
commands.gdr = commands.group
commands.start = function() ns.GroupDeathroll.Start() end

commands.hit = function()
    if not ns.Blackjack.Hit(ns.Games.Mine()) then ns.Print("You can't hit right now.") end
end

commands.stand = function()
    if not ns.Blackjack.Stand(ns.Games.Mine()) then ns.Print("You can't stand right now.") end
end

commands.double = function()
    if not ns.Blackjack.Double(ns.Games.Mine()) then ns.Print("You can only double on your first two cards.") end
end

commands.cancel = function()
    if not ns.Games.Cancel(ns.Games.Mine()) then ns.Print("No game to cancel.") end
end

commands.accept = function()
    if not ns.UI.AnswerInvite(nil, true) then ns.Print("No challenge to accept.") end
end

commands.decline = function()
    if not ns.UI.AnswerInvite(nil, false) then ns.Print("No challenge to decline.") end
end


commands.ledger = function()
    local any = false
    for name, bal in pairs(ns.Ledger.Balances()) do
        if bal ~= 0 then
            any = true
            ns.Print("%s: %s", ns.Short(name), bal > 0 and ("owes you " .. ns.Money(bal)) or ("you owe " .. ns.Money(-bal)))
        end
    end
    if not any then ns.Print("All square - nothing owed either way.") end
end

commands.settle = function(...)
    local name = select("#", ...) > 0 and table.concat({ ... }, " ") or nil
    if not name then ns.Print("Usage: /gg settle <player>") return end
    ns.Ledger.Request("settle", name)
end

local function payment(direction)
    return function(...)
        local name, gold = NameThenNumbers(...)
        local copper = ns.GoldToCopper(gold)
        if not name or not copper or copper <= 0 then
            ns.Print("Usage: /gg %s <player> <amount>", direction)
            return
        end
        ns.Ledger.Request(direction, name, copper)
    end
end
commands.paid = payment("paid")
commands.received = payment("received")

commands.board = function()
    local ranked = ns.Board.Ranked()
    if #ranked == 0 then ns.Print("No games on the leaderboard yet.") return end
    for i = 1, math.min(5, #ranked) do
        local e = ranked[i]
        local k = e.streak or 0
        ns.Print("#%d %s  %s  (%d-%d, %s wagered)%s", i, ns.Short(e.name), ns.Money(e.net, true), e.wins, e.losses,
            ns.Money(e.wagered or 0), k >= 4 and ("  on fire: " .. k .. " wins in a row") or
            (k <= -4 and ("  cursed: " .. -k .. " losses in a row") or ""))
    end
    local who, range = ns.Board.BiggestDrop()
    if who then ns.Print("Biggest drop to 1: %s rolled a 1 from 1-%d", ns.Short(who), range) end
end
commands.leaderboard = commands.board

-- /gg art                       which elite dragon atlases this client has
-- /gg art <winged|gold|silver> <cx> <cy> <d>   move/scale a dragon frame around portraits
-- /gg art reset | own | tga | png
commands.art = function(what, a, b, c)
    what = (what or ""):lower()
    local db = ns.db
    if ns.Art.ELITE[what] then
        local cx, cy, d = tonumber(a), tonumber(b), tonumber(c)
        if not (cx and cy and d) then ns.Print("Usage: /gg art %s <cx> <cy> <d>  (fractions, e.g. 0.4 0.56 0.59)", what) return end
        db.art = db.art or {}
        db.art[what] = { cx = cx, cy = cy, d = d }
        ns.Print("%s frame: centre %.2f, %.2f  diameter %.2f", what, cx, cy, d)
    elseif what == "reset" then
        db.art = nil
        ns.Print("Dragon frame positions reset.")
    elseif what == "own" then
        db.ownDragons = not db.ownDragons
        ns.Print("Using %s dragon frames.", db.ownDragons and "GuildGambit's own" or "Blizzard's")
    elseif what == "tga" or what == "png" then
        db.textureExt = what
        ns.Print("Textures now load as .%s - /reload to apply everywhere.", what)
    else
        for kind, g in pairs(ns.Art.ELITE) do
            ns.Print("%s: %s", kind, ns.Art.HasAtlas(g.atlas) and "|cff20ff20found|r" or "|cffff4040missing (using our own art)|r")
        end
    end
    ns.UI.Refresh()
end

commands.guildonly = function(state)
    state = (state or ""):lower()
    if state == "on" then ns.db.guildOnly = true elseif state == "off" then ns.db.guildOnly = false end
    ns.Print("Guild-only games: %s", ns.db.guildOnly and "on" or "off")
end

-- What the game reports for us vs what we've learned from the server (for bug reports).
commands.whoami = function()
    local raw = UnitName("player")
    local names = {}
    for _, n in pairs(ns.myNames) do names[#names + 1] = n end
    table.sort(names)
    ns.Print("UnitName: '%s' (%s) | using: '%s' | known spellings: %s | realm: %s",
        tostring(raw), type(raw), tostring(ns.Me()), table.concat(names, ", "),
        tostring(GetNormalizedRealmName and GetNormalizedRealmName()))
end

commands.reset = function(password)
    if not password then ns.Print("Usage: /gg reset <password>") return end
    if ns.Board.Reset(password) then
        ns.Log("Leaderboard and all debts reset for the whole guild - a new season starts now.")
    else
        ns.Print("Wrong password - the leaderboard was not reset.")
    end
end

-- what the Live tab knows, for tracking down "my game isn't showing"
commands.live = function()
    local Live, Comm = ns.Live, ns.Comm
    local reg = {}
    for prefix, res in pairs(Comm.registered or {}) do reg[#reg + 1] = prefix .. "=" .. res end
    ns.Print("Live: prefixes [%s] | messages waiting to send: %d", table.concat(reg, ", "), Comm.Waiting())
    local mine = ns.Games.Mine()
    if mine then
        ns.Print("Your game: %s (%s) - you %s announce it; %d watching", mine.title or mine.kind, mine.state or "?",
            Live.IsAnnouncer(mine) and "do" or "don't (the other player does)", Live.WatcherCount(mine))
    end
    local n = 0
    for id, g in pairs(Live.games) do
        n = n + 1
        ns.Print("  %s - from %s, heard %ds ago%s%s", g.h or id, ns.Short(g.host), math.floor(GetTime() - (g.seen or 0)),
            g.ended and (" - ended: " .. g.ended) or "", Live.watching == id and " - WATCHING" or "")
    end
    if n == 0 then ns.Print("  No games heard from other guildies.") end
end

commands.who = function()
    local peers = ns.House.OnlinePeers()
    if #peers == 0 then ns.Print("No guildies with GuildGambit online right now.") return end
    for _, peer in ipairs(peers) do
        ns.Print("%s  v%s", ns.Short(peer.name), peer.version or "?")
    end
end

commands.undo = function()
    local e = ns.Ledger.VoidLast()
    if not e then ns.Print("No game to undo.") return end
    ns.Log("Removed your last game: %s vs %s (%s). It no longer counts in the ledger or leaderboard - %s should /gg undo too.",
        e.game, ns.Short(e.opponent), ns.Money(e.net, true), ns.Short(e.opponent))
end

commands.sound = function(state)
    state = (state or ""):lower()
    -- "/gg sound death" (or win, lose, card, ...) plays that sound to check it works
    if ns.SOUNDS[state] then
        local played = ns.Sound(state)
        ns.Print(played and ("Played the %s sound (%s)."):format(state, tostring(played))
            or ("Couldn't play the %s sound - is /gg sound on, and the game's sound enabled?"):format(state))
        return
    end
    if state == "on" then ns.db.sound = true elseif state == "off" then ns.db.sound = false
    else ns.db.sound = not ns.db.sound end
    ns.Print("Sound effects: %s", ns.db.sound and "on" or "off")
    if ns.db.sound then ns.Sound("win") end
end
commands.sounds = commands.sound

commands.announce = function(state)
    state = (state or ""):lower()
    if state == "on" then ns.db.announce = true elseif state == "off" then ns.db.announce = false
    else ns.db.announce = not ns.db.announce end
    ns.Print("Posting your wins in guild chat: %s", ns.db.announce and "on" or "off")
end

commands.whispers = function(state)
    state = (state or ""):lower()
    if state == "on" then ns.db.whisperRolls = true elseif state == "off" then ns.db.whisperRolls = false end
    ns.Print("Whispering your rolls to opponents outside your group: %s", ns.db.whisperRolls and "on" or "off")
end

commands.minimap = function(state)
    state = (state or ""):lower()
    local b = ns.MinimapButton.Button()
    local shown = state == "show" or state == "on" or (state == "" and not (b and b:IsShown()))
    ns.MinimapButton.SetShown(shown)
    ns.Print("Minimap button %s.", shown and "shown" or "hidden - /gg minimap to bring it back")
end

commands.debug = function()
    ns.db.debug = not ns.db.debug
    ns.Print("debug %s", ns.db.debug and "on" or "off")
end

commands.info = function()
    ns.Print("v%s | build %s | interface %d | Forever: %s | RandomRoll: %s | guild members known: %d",
        ns.version, Compat.build, Compat.interface, tostring(Compat.IS_FOREVER),
        RandomRoll and "yes" or "no", ns.Guild.count)
end

function Slash.Run(msg)
    local words = {}
    for w in (msg or ""):gmatch("%S+") do words[#words + 1] = w end
    local cmd = (table.remove(words, 1) or ""):lower()
    -- "1g 50s 25c" is one wager: glue gold/silver/copper parts together ("1g50s25c")
    local merged = {}
    for _, w in ipairs(words) do
        local prev = merged[#merged]
        if prev and w:lower():match("^%d+[gsc]$") and prev:lower():match("%d+[gsc]$") then
            merged[#merged] = prev .. w
        else
            merged[#merged + 1] = w
        end
    end
    words = merged
    local fn = commands[cmd]
    if not fn then return commands.help() end
    fn(unpack(words))
end

SLASH_GUILDGAMBIT1 = "/gg"
SLASH_GUILDGAMBIT2 = "/guildgambit"
SlashCmdList.GUILDGAMBIT = Slash.Run
