# GuildGambit — first in-game test

The prototype passes 56 mock-client tests (75 across both addons). Planted bugs in the rules,
rolls, guild check, payments and leaderboard were all caught. Everything it calls appears in
a working Forever addon, except the names listed under "Unproven" below — each has a fallback.
This checklist covers what the mock can't: the real client, and how things look.

Work top to bottom. Each step says what to look for and what to tell me if it's wrong.

## 0. Install (once)

```
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Name GuildGambit
```

This links the folder into `_forever_\Interface\AddOns`, so later fixes need only `/reload`.
Turn on Lua errors before logging in: `/console scriptErrors 1` (or install BugSack).

## 1. Solo — about 10 minutes

| # | Do | Expect | If not, tell me |
|---|---|---|---|
| 1 | Log in | No red error. AddOns list shows GuildGambit (not "out of date") | The error text |
| 2 | `/gg info` | `interface 16001`, `Forever: true`, **`RandomRoll: yes`** | The whole line |
| 3 | `/gg art` | `winged`, `gold`, `silver` all **found** | Which say missing |
| 4 | `/gg` | Window with Blizzard's gold border + header; Play / House / Ledger / Leaderboard tabs | A screenshot |
| 5 | Type `/roll 1-100` | Chat says `<You> rolls N (1-100)` | The exact chat line (copy it) |
| 6 | `/gg dr practice 1 100`, click **Roll** | Skull + range on the table, a real `/roll` in chat | Did the roll appear? |
| 7 | Keep rolling until it ends | Result in the log; Ledger shows a "(practice)" entry | Anything stuck |
| 8 | `/gg slots 5 practice` → **Spin!** | Three reel pictures in gold rings, e.g. "Two Cherries x2" | Screenshot |
| 9 | `/gg bj 5 practice` → **Deal card** ×2 | Real card pictures; dealer card + face-down card appear on their own | Screenshot |
| 10 | Play hands until you get a J, Q, K or A | **Race portrait** in the card (orc/human/elf/dwarf), **dragon head** on aces; king/ace have the **gold dragon frame** | Screenshot — is the dragon lined up on the portrait? |
| 11 | If the dragon is off-centre | Try `/gg art winged 0.40 0.56 0.59` and nudge the numbers (cx, cy = where the portrait centre sits in the dragon, d = portrait size) | The numbers that look right |
| 12 | If any of our pictures are **green/missing** | `/gg art tga`, `/reload` | Did TGA fix it? |
| 13 | `/reload`, open Ledger | Practice games still listed | — |
| 13a | Look at the minimap | Coin-and-dice button on the edge; tooltip on hover; left-click opens, right-click opens the Ledger; drag moves it | Screenshot |
| 13b | Log in / `/reload` | **No** "No player named '…' is currently playing" message (fixed 2026-11-14) | The message if it's back |

**Most important:** steps 2, 3, 5 and 10.

## 2. With a guildie — about 15 minutes

Both need the addon. **Form a party first** — rolls are only "verified" for players who can see
them (grouped or standing close).

| # | Do | Expect |
|---|---|---|
| 14 | Both `/reload`, wait 5s | Leaderboard tab can show each other after a game |
| 15 | A: `/gg dr <B> 1 100`, B accepts, play it out | Both see the same turns. Ledger: loser "You owe 1g", winner "Owed to you 1g" |
| 16 | Leaderboard tab | Both listed, winner #1 with the **winged gold dragon** frame around their race portrait, #2 silver |
| 17 | **Trade** the 1g (loser → winner) | Both ledgers log "Paid/Received 1g … All square!" and the debt disappears |
| 18 | Play again, settle by **mail** this time | Sender's ledger clears when sent; receiver's when they take the gold from the mail |
| 19 | Trade some gold for no reason | Not counted as a payment (no debt in that direction) |
| 20 | B: `/gg house open 10`, A: `/gg slots 1`, then `/gg bj 1` | Both ledgers agree; B's client deals blackjack automatically |
| 21 | Leave the party, deathroll again | Works, marked "(unverified)" |

If 17 or 18 doesn't clear the debt, record it by hand — `/gg paid <name> <gold>` or
`/gg received <name> <gold>` (or the Ledger tab buttons) — and tell me which way failed.

## 3. Things to note even if everything works

- Text that doesn't fit, overlapping buttons, cards running off the table (layout is the part I
  couldn't check at all).
- The exact roll chat line for **someone from another realm**, if you can get one.
- Whether the challenge popup appeared, or only the chat line.

## Unproven names (all have fallbacks)

| Name | Used for | If it's missing |
|---|---|---|
| `RandomRoll`, `RANDOM_ROLL_RESULT` | server rolls and reading them | asks you to type `/roll`; English pattern |
| The 3 elite dragon atlases | king/ace/leaderboard frames | our own drawn dragon (`/gg art` shows which) |
| `TRADE_SHOW`, `TRADE_MONEY_CHANGED`, `PLAYER_TRADE_MONEY`, `TRADE_ACCEPT_UPDATE`, `GetPlayerTradeMoney`, `GetTargetTradeMoney`, `ERR_TRADE_COMPLETE` | spotting trades | `/gg paid` / `/gg received` |
| `SendMail`, `GetSendMailMoney`, `MAIL_SEND_SUCCESS`, `MAIL_FAILED`, `MAIL_INBOX_UPDATE`, `GetInboxNumItems`, `TakeInboxMoney`, `AutoLootMailItem` | spotting mailed gold | `/gg paid` / `/gg received` |
| `DECLINE` | popup button text | "Decline" |

## Art

- **Ours** (in `Media/`, PNG + TGA): card faces and back, slot symbols, skull, coins, addon icon,
  ring frames and a fallback dragon. Source SVGs in `art/svg/`, generated by `tools/art/`.
  Rebuild: `python -I tools/art/build.py` then `python -I tools/art/render.py`.
- **The game's own** (referenced from the client, not shipped): race and dragon portrait icons,
  Blizzard's elite dragon frames, the gold dialog border/header, marble background.
- Suits → races: ♠ orcs, ♥ humans, ♦ elves, ♣ dwarves. Aces: black, red, blue, green dragons.

## Known limits of this prototype

- **Poker isn't included yet** — hole cards must stay secret and server rolls are public.
- No splits or insurance in blackjack (European rules: dealer draws after you finish).
- Gold is never moved by the addon; it only notices trades/mail and keeps the ledger.
- Leaderboard stats are self-reported by each client (fine among guildies, not cheat-proof).
- A house deals one blackjack table at a time. Slots have no limit.
