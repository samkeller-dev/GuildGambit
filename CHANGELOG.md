# Changelog

Newest first. Versioning rules: see VERSIONING.md. Add new changes under "Unreleased";
`bump.ps1` turns that section into the next version's entry.

## Unreleased

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
