# Changelog

Newest first. Versioning rules: see VERSIONING.md. Add new changes under "Unreleased";
`bump.ps1` turns that section into the next version's entry.

## Unreleased

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
