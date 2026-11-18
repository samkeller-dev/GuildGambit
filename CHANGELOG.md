# Changelog

Newest first. Versioning rules: see VERSIONING.md. Add new changes under "Unreleased";
`bump.ps1` turns that section into the next version's entry.

## Unreleased

## 2.1.5 - 2026-11-18

- **Clearing a debt can't be undone by an old mail any more.** If gold mailed with **Pay debts** was still waiting for the other player to confirm when you cleared everything with them, confirming it afterwards counted it as a new payment and opened the debt again the other way. Clearing now drops mailed gold that's still waiting, and a mail sent before the clear is refused if its popup is answered later. Gold mailed after a clear still counts. A leaderboard reset does the same.

## 2.1.4 - 2026-11-18

- **Spam-clicking Roll no longer rolls twice.** After you click, the Roll button greys out until your roll shows up in chat (or 3 seconds pass, in case it got lost). `/gg roll` and `/gg hit` work the same way. In deathroll the extra roll was already ignored, but in blackjack a fast double-click on Hit could deal you a card you didn't ask for.

## 2.1.3 - 2026-11-18

- **Group deathroll: no more stuck players.** If a player's addon misses a roll (out of range, or a lost message), it now catches up from the others within a few seconds instead of waiting forever, so it can roll when its turn comes. An addon that missed the start still gets the result.
- If a group deathroll goes completely quiet for 5 minutes, the addon drops it (no result recorded), so the buttons can't stay greyed out. Until everyone updates, `/reload` (or `/gg cancel` twice) frees a stuck player.

## 2.1.2 - 2026-11-17

- **Lottery pot fixes:** taking the gold out of a ticket mail no longer counts it twice behind the scenes. The pot character's addon puts the old totals right for everyone the next time it opens the mailbox. A ticket mail taken before the addon had read the inbox is no longer missed, and a mail from a short spelling of a buyer's name (like "Eoka" for "Eoka Pistol") counts for them.
- **Confirm gold by hand:** if the addon ever misses someone's ticket gold, the pot character can click that player's row on the lottery page (or `/gg lottery confirm <name>`) to mark it received. Click again (or `/gg lottery unconfirm <name>`) to take it back. If the mail turns up later, it isn't counted twice. Gold mail from a guildie that isn't a ticket mail is pointed out on the pot character's lottery page.
- **Buying tickets is safer:** your tickets only count once the gold has actually left your bags. Before, a mail the game reported as "sent" counted even if the gold never went with it. While the mailbox is open, the lottery page reminds you to keep it open until your tickets are confirmed in chat.
- `/gg lottery check` on the pot character lists every mail with gold on it, as the game reports it.

## 2.1.1 - 2026-11-17

- No more "X has an outdated GuildGambit" line for every guildie on an old version when you log in. You're told only if you try to play them (and the opponent list marks them). If your own version is the old one, you're told once per session.
- Lottery page: the "Paid" column no longer runs into the pot on the right, and the pot character no longer sees a stray "ticket(s)" label.

## 2.1.0 - 2026-11-16

- **Change the lottery's draw date:** the lottery's creator has a **Change draw date** button on the lottery page (or `/gg lottery date`), for a date set by mistake or a draw that needs moving. Tickets already bought keep counting, and everyone's addon is told the new date. Players on 2.0.0 won't see the change until they update.

## 2.0.0 - 2026-11-16 (protocol 8)

**Everyone needs to update:** coinflips work differently, so 2.0 can't play with 1.x versions at all - the version check shows an error and blocks games until both players are on 2.0.

- **Coinflip lobby:** accepting a coinflip no longer flips straight away. Both players land in a lobby and click **Ready**; once both are ready there's a 3-2-1 countdown, then the coin flips. The win/lose sound and chat line now wait until the coin has stopped spinning, so you can't hear the result before you see it.
- **Rematch / Double or nothing:** after any game, the finished table has a **Rematch** button (same game, same opponent, same stake - a deathroll keeps its start) and **Double or nothing** (twice the stake). The invite says "Rematch!" or "Double or nothing!". In a group deathroll the host gets **Reopen room**.
- **Side bets for spectators:** watching a game in the Live tab, back one of the players with some gold (the arrows pick who). You're betting against the other spectators, not a house: when the game ends, the losing bets are split between everyone who backed the winner, in proportion to what they bet, and it all goes in the ledger. Bets stay open for 20 seconds once a game starts (a coinflip: until the flip; a group deathroll: also while the room is open). If nobody backed the winner, nobody took the other side, or the game is a push or cancelled, all bets are off. The players see how much is riding on them.
- **Right-click to challenge:** right-click a guildie who has GuildGambit - their name in chat, their portrait, or the guild list - and pick **Challenge > Deathroll / Coinflip / Blackjack / Kodo Crossing**. It uses the wager on the Play tab.
- **Guild lottery:** officers open a lottery from the Live tab - ticket price, most tickets per player, the draw day and time (Brisbane time), and the guildie whose character holds the pot. One lottery at a time. Creating it is quiet: the creator checks the details, then clicks **Announce** to post it in guild chat and open ticket sales (or **Close lottery** to remove it, as long as nobody has bought a ticket). Buy tickets at a mailbox with the **Buy** button: the gold is mailed straight to the pot character and the tickets count once the mail is sent. Sales close 1h15m before the draw, so every ticket's gold has arrived by then. The lottery is pinned at the top of the Live tab: everyone's tickets and stake, the pot, the draw time, and the last winner. The pot character's addon checks its mailbox and shows who has actually paid. The creator clicks **Draw** after the draw time (any officer can once it's 3 days overdue): one server /roll picks the winning ticket, with a spinning-number animation for everyone watching, and the winner takes the whole pot. The pot character mails the winnings and marks them paid. Players who were offline find out next time they log in, and there's a daily reminder while a lottery is open. `/gg lottery`.
- **Debt reminder:** when you log in, a line in chat says who you owe and who owes you (only if anyone does). `/gg remind` shows it any time; turn it off on the options page or with `/gg remind off`.
- **Options page:** GuildGambit now has its own page under Esc > Options > AddOns, with the game's usual checkboxes - do not disturb, guild members only, mute guild chat, whisper rolls, sound effects and hide minimap button - plus buttons to open the window and the Guild Wealth chart. `/gg options` opens it. The page and the `/gg` commands always agree.
- **Do not disturb (`/gg dnd`):** turns down every incoming challenge automatically - deathroll, blackjack, coinflip and Kodo Crossing (the challenger sees "declined (do not disturb)") - and hides group deathroll invites. Guildies see "(do not disturb)" next to your name in their opponent list, and your window title says "(DND)".
- **Mute guild chat (`/gg gmute`):** stops your wins being posted in guild chat. It replaces `/gg announce on|off` (which still works); if you had announcements off, you start muted.
- Players on an older version are told what's new in the newer one when they're asked to update (from 2.0 on).
- The automated tests were brought up to date with the current games.

## 1.9.1 - 2026-11-14

- **Leaderboard scrolls:** with more than 8 players, scroll the list below the podium with the mouse wheel or the little arrows (a counter shows e.g. "4-8 of 13"). The Kodo Crossing high scores scroll the same way past the top 10.

## 1.9.0 - 2026-11-14

- **Guild Wealth:** a new coin tab on the side of the window pops out a donut chart of the guild's gold - one slice per character, sized by the gold in their bags. Click a slice (or a name in the list below it) for that player's card: wallet, share of the guild's gold, change over the last 7 days and most ever held; honorable and dishonorable kills; and their GuildGambit record - net, win rate, wagered, current and longest streak, biggest win and biggest loss (with dates), biggest drop to 1, nemesis (who has won the most gold off them), victim (who they've won the most from), Kodo Crossing best, and what you owe each other. Each character shares its own numbers; opening the chart asks everyone online for fresh ones. Also `/gg wealth [player]`.
- The addon description no longer mentions Slots.

## 1.8.1 - 2026-11-14

- **Fix: games not showing in the Live tab.** 1.8.0 announced games on a second message channel, which some setups can't receive. Everything is back on GuildGambit's original channel (spectator messages still wait behind game messages, so they can't slow games down), and 1.7.0 players can see 1.8 games again.
- **Kodo Crossing duels:** the side panel with your opponent's run is gone (it didn't work for everyone). Instead the game screen shows a box with who you're up against and their score, live, next to the "DUEL vs ..." header.
- Live tab: your own game is listed too, marked "(you)", so you can see it's live for the guild.
- New `/gg live` command: shows what the Live tab knows (for tracking down problems).

## 1.8.0 - 2026-11-13

- **Spectating fixed:** the Live view stopped updating (deathroll numbers froze, Kodo Crossing replays got stuck) because WoW only lets an addon send a few messages a second and silently refuses the rest. Messages are now queued and retried instead of lost, with game messages always first; spectator traffic has its own channel, goes out once to the guild instead of once per watcher, and is merged when it piles up. A Kodo Crossing replay that misses some hops asks for exactly those again.
- **Kodo Crossing duels:** your opponent's run plays live in a panel beside the window, and the Arcade tab says who you're up against ("DUEL vs ... - You 12 : 9 Them").
- **Live tab:** finished games leave the list straight away (the one you're watching shows its result for a few seconds first).

## 1.7.0 - 2026-11-13

- **Kodo Crossing** - a new lane-crossing arcade game in its own **Arcade** tab: hop across roads full of kodos and raptors, stampede lanes, and rivers with drifting logs and lily pads. Collect coins to unlock characters (gnome, orc, night elf, tauren, forsaken). Every 40 rows you enter a new zone (Elwynn, the Barrens, Winterspring). Arrow keys / WASD, P to pause.
- **Kodo Crossing duels replace Slots:** challenge a guildie with a wager; you each get one run on exactly the same lanes and the higher score wins. Results go to the ledger, leaderboard, guild chat and Live tab like every other game. (Slots is retired; older addons that offer it get a polite decline.)
- **Live tab shows the real game:** spectators now see the same table as the players - the big deathroll number, the cards (hole cards stay hidden until the showdown), the coin, the group roster - and a live split-screen replay of both runs in a Kodo Crossing duel.
- **Leaderboard:** a fire icon for 4+ wins in a row and a curse icon for 4+ losses in a row; "biggest drop to 1" (the largest range someone has rolled a 1 from); and a new **Kodo Crossing** high-score sub-tab.
- Coinflip waits 3 seconds before the flip, so there's a moment of suspense (and spectators can tune in).

## 1.6.0 - 2026-11-13

- **Live tab:** see every game being played in the guild right now, all modes, and watch one live. Blackjack hole cards stay hidden until the showdown. Players see how many people are watching.
- Guild chat now announces wins in **every** game mode: blackjack, slots and coinflip as well as deathroll and group deathroll.
- Ledger: when a game result cancels out what was owed, the log says so ("That evens out with ... - you're all square") instead of the debt silently disappearing.

## 1.5.0 - 2026-11-13

- Deathroll wins, 1v1 and group, are posted in guild chat by the winner: who won, who they beat and the wager. Turn it off with `/gg announce off`.
- AddOns list description now mentions group deathroll and coinflip.

## 1.4.0 - 2026-11-13

- Ledger: a **Pay debts** button, which works with a mailbox open. It mails every player you owe exactly what you owe them, one mail after another.
- Mailed gold counts once the recipient confirms it. If they're offline they're asked again when they come online, and nothing is ever mailed twice.

## 1.3.0

- Ledger: pick the player from a list (open balances first, then guildies online) instead of typing the name.
- Ledger: amounts in gold, silver and copper.

## 1.2.1

- Install guide in the zip: simpler steps; fixed an out-of-date line about automatic payments.

## 1.2.0 (protocol 7)

- Every ledger change needs the other player to confirm in a popup: "I paid", "I received" and "Clear debt".
- Removed automatic trade and mail detection, since unrelated gold was throwing the ledger off.

## 1.1.0 (protocol 6)

- **Group deathroll:** a host opens a room for the guild, anyone online joins, and the last one standing wins the pot.
- Wagers in gold, silver and copper for every game.
- Leaderboard: total wagered.
- Fix: the host of a group deathroll is listed by the name the server uses, so every addon agrees on the result.
- Fix: a player whose addon missed a roll catches up to the final result.
- Fix: `/gg stand` during a slots game caused an error.

## 1.0.0 (protocol 5)

- First release: deathroll, blackjack, slots and coinflip, 1v1 between guildies, with server rolls.
- Ledger of who owes whom, and a guild leaderboard with a podium.
- 0g bets for games just for fun.
