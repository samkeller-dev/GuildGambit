# Changelog

Newest first. Versioning rules: see VERSIONING.md. Add new changes under "Unreleased";
`bump.ps1` turns that section into the next version's entry.

## Unreleased

## 2.5.0 - 2026-11-21

- **New: High Roller (beta).** A casual survivors game, just for fun, with no gold involved. It plays in its own 800 x 600 window that you can move and resize: type `/gg roller`, or click **High Roller** at the top left of the Arcade tab and then **Play High Roller**.
  - **Hand-painted look:** torch-lit casino rooms, animated enemies, tumbling dice, and level-up choices dealt as cards.
  - **A five-picture guide** on the game's page in the Arcade tab shows how to play.
  - **You only move** (WASD or the arrow keys). Your weapons fire on their own. The game pauses whenever you have a choice to make, and keys 1-3 pick.
  - **Five casino rooms, a boss in each.** Every boss has a trick you solve by where you stand. Every boss attack is drawn on the floor in red before it lands, and it kills in one hit if you're still standing in it.
  - **You play the Dicemaster,** who throws dice that throw again on doubles, and collects the good ones off the floor. More classes are coming later; they show as "??" in the menu.
  - **Build as you go:** 13 more weapons that level up and evolve, stacking charms, relics from boss chests (some cursed), and set bonuses for collecting a suit.
  - **Things to grab on the floor:** power-ups you walk over (Lucky Boots for speed, a Magnet, a Fire Alarm that clears the floor, a Stopwatch, and more), casino furniture to smash for chips, and chests from elites that pay out one, three or five prizes.
  - **Rooms that keep changing:** a golden imp to chase, swarms, lucky tables, high rollers with guards, and a mini-boss halfway through each room.
  - **Rare, Epic and Legendary** upgrade cards and relics. Luck makes the better ones turn up more often.
  - **Bosses fire rapid barrages** between their big attacks. Every one is drawn on the floor first.
  - **Three talent trees** for the Dicemaster, earned by playing and kept across your whole account. Resetting them is free.
  - **Chips are your score.** After each boss you pick a relic and go straight on, or walk away and keep your chips: dying scores 0. You keep class experience and unlocks either way.
  - **Personal bests only.** There's no leaderboard, and the game sends nothing to other players.
  - **Made for flight paths:** a run is about 10 minutes (or about 6 in Quick Hand mode). It pauses when you land, enter combat or close the window, and a /reload puts you back at the start of the room you were in.
  - It's a beta: the difficulty and rewards haven't been tuned by real play yet.
- Kodo Crossing is still in the Arcade tab; the button at the top left swaps between the two games.

## 2.4.6 - 2026-11-21

- **A /reload or disconnect no longer drops you out of a game.** After you log back in, your addon asks the guild whether you were in a game, and the other players' addons answer:
  - **Deathroll and group deathroll:** you're back in where the game stands, with your Roll button and only the time that was left on your turn. A host who reloads keeps announcing the game in the Live tab.
  - **Ended while you were away:** the result goes on your ledger exactly as it did on theirs.
  - **Coinflip and blackjack:** these can't be picked up again (your hidden card is gone), so both sides cancel and nobody owes anything.
- **A game result is never recorded twice**, even if it reaches your addon more than once.
- **Group deathroll: a slow roller is still knocked out if the player meant to do it has reloaded or logged off.** The next player in line does it 10 seconds later. Before, the game stalled for 5 minutes and was then dropped with no result.
- For about 20 seconds after you log in, new games and invites wait while your addon checks for a game in progress.
- Catching up needs the other players on 2.4.6 too. Older versions don't answer, but your addon still catches up from their normal turn updates once someone rolls.

## 2.4.5 - 2026-11-21

- **No more mid-screen messages in group deathrolls.** The turn and 30-second warnings now appear only in chat (with the warning sound and the countdown on the status line). The raid-warning-style message got in the way.

## 2.4.4 - 2026-11-20

- **Clearer wording in chat.** Fixed messages with bad English: the login debt reminder ("Eoka Pistol 5g owes you" now reads "Eoka Pistol owes you 5g"), "you only has 5g", payment lines ("You paid Bob 5g by mail. You still owe them 3g."), blackjack and coinflip results, group deathroll stakes for fun games, and lottery draw dates.
- **You're told when someone pays you with Pay debts.** When a guildie's Pay debts mail reaches you, a line in chat says who mailed you how much. It's already on your ledger, so there's nothing to confirm. If you were offline, you're told when you next log in.

## 2.4.3 - 2026-11-19

- **Pay debts only counts gold that actually leaves your bags.** Before, a mail the game called "sent" counted as paid even if no gold went with it, and the receiver's confirm popup made it look settled. Now each Pay debts mail counts only once its gold has gone. Then it's recorded on both ledgers straight away, with no popup for the receiver (they need 2.4.3 or newer; older versions still see the popup). If the gold doesn't leave within a few seconds, nothing is recorded and you're told.

## 2.4.2 - 2026-11-19

- **Group deathroll: no more surprise time-outs.** When it's your turn you're now told in chat and in the middle of the screen (even with the window closed), the status line counts down the time left, and at 30 seconds left you get a loud warning. Everyone else sees the clock and a note when the roller is down to 30 seconds. The kick now comes a few seconds after the countdown ends, so a slow relay can't cut you off early.

## 2.4.1 - 2026-11-19

- **Cleanup: everything unused is gone.** The retired Slots game (its code, table and symbol pictures), the Kodo Crossing duel code (retired in 2.4.0), unused coin pictures and a few unused functions have been removed - about 1,300 lines and 18 image files, so the download is smaller. Nothing you can use changes: Kodo Crossing is still in the Arcade, and `/gg kodo` opens it. A Kodo duel invite from an older version is still turned down politely.

## 2.4.0 - 2026-11-19

- **Kodo Crossing is arcade-only.** It's no longer a gambling game: play it for fun in the Arcade tab, with its high scores on the leaderboard as before. Kodo duels can't be started any more (the Play tab button, `/gg kodo`, the right-click menu and rematch are gone), and a duel invite from an older version is turned down. Past Kodo results stay in your ledger.
- **Fixed the lottery going back to the old one.** A guildie whose addon had missed a draw kept sharing that lottery as still open, and other addons swapped the new lottery for it (the older one won). Addons now remember which lotteries have been drawn and never take one back, a stuck addon is told the lottery was drawn and catches up, and the draw result clears a copy that missed it. Anyone still on 2.3.0 can stay stuck on the old lottery until they update, but they can no longer spread it.
- **Side bets are gone.** Spectators can no longer bet on a live game; watching works as before. Side-bet results already in your ledger stay there.
- **The Draw button turns on by itself.** If you had the lottery page open before the draw time, the Draw button stayed greyed out until something else refreshed the page. It now turns on at the draw time with the page left open.

## 2.3.0 - 2026-11-18

- **Double or nothing is really double or nothing.** It used to just double the last stake, so after losing 3g a double or nothing was played for 6g, and winning it left you 3g up instead of even. Now it's played for what the run of back-to-back games stands at: lose 3g, and double or nothing is for 3g, so you end up owing 6g or nothing. Lose that too and the next one is for 6g. Once someone wins it back to nothing, only Rematch is offered. Debts from other games aren't part of it. The button shows the stake. Rematch still uses the same stake and starts a new run. Group deathroll no longer offers double or nothing, since every player's total is different.
- **The lottery counts on the leaderboard.** Once the draw's spin has landed, every player who had tickets gets the result in their net gold: the winner gains the pot minus what they put in, everyone else loses what they put in. What they put in also counts toward their total wagered. It doesn't count as a game, win, loss or streak, and it's never a debt: the gold already moved by mail. Players who only played the lottery now appear on the leaderboard too.
- **See your lottery numbers before the roll.** When an officer clicks **Draw**, the addon collects everyone's tickets for 5 seconds, then freezes the list and shuffles the players. Every player gets a block of ticket numbers, and everyone is told who holds which. A 15-second countdown follows, with your numbers and everyone else's on screen the whole time. Your numbers are also posted in your chat. The roll is over exactly that list, and the winner's numbers show when the spin lands.
- Players used to get their numbers in A-Z name order at the moment of the roll. Shuffling doesn't change anyone's odds: each ticket is still one number out of the total.

## 2.2.0 - 2026-11-18

- **The lottery draw is now a show.** Clicking **Draw** starts a 15-second countdown on everyone's addon, with a chat line telling the guild to open the lottery on the Live tab to watch. The lottery page shows the countdown, then the spin, on everyone's screen at once. Open the page partway through and you join the countdown or the spin where it's up to. The draw itself hasn't changed: it's still started by hand, and ticket sales still close 1h15m before.
- **No spoilers.** Nobody is told the winner until the spin has landed: not in guild chat, not in anyone's chat, not on the Live row or the lottery page.
- **The last winner's stake.** The Live tab shows the last lottery's winner, the pot they won and how much they had in it (their tickets x the price). The lottery row shows it until the next lottery opens, and the lottery page always does. Players who log in later hear it too.

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
