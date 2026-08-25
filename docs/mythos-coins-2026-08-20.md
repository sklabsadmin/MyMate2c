# Mythos Coins — what shipped, how to turn it on, and what to watch

Written 2026-08-20, on branch `feat/coins`, for whoever flips the switch.
The full design brief (economy rationale, rejected mechanics, phases) lives
outside the repo; this is the operational half. The currency was renamed from
the working name "Ambrosia Drops" to **Coins** by the 20 Aug design meeting —
if you find "drops" anywhere, it is stale.

## Where things stand (updated 2026-08-25)

| | |
|---|---|
| Production | **LIVE** since 2026-08-24: `COIN_LEDGER: "true"` on `main`, migration 0014 applied to remote D1, build 1.7.8+81 |
| In flight | PR #11 (grant-on-claim + streak line), PR #12 (admin coins reporting) — merge #11 first |
| Tests | 83 worker (`npm test`), 86 Flutter (`flutter test`) — all passing on the PR branches |
| Known issue until #11 lands | the app-load sync GRANTS, so every visitor gets a 100-coin wallet without tapping (~84/day at current traffic); #11 moves the grant to the claim tap |
| First real data | traffic returned 2026-08-24 (~100 opens/day, ig); 0 real users have tapped "Claim Coins" yet — every coin interaction so far is developer testing (see the test bucket on /admin/visits) |

## What it is, in one paragraph

A server-authoritative wallet. Every movement of coins is one row in
`coin_ledger`, whose PRIMARY KEY is an idempotency key the caller chooses
(message_delivery's bubble_id trick), so a retry can never pay or charge
twice. `coin_wallets.balance` is a cache maintained by a trigger in the same
statement that writes the row — no code path updates it directly, and it is
rebuildable as `SUM(delta)`. D1 has no interactive transactions, so a spend
is a single conditional `INSERT OR IGNORE ... WHERE balance >= cost`, and a
`changes = 0` result is disambiguated by looking the key up.

Faucets (all amounts live in `COINS` in worker.js, never in the client):
welcome +80 once · dawn offering a flat +20 every day (≥20 h apart, per-date
idempotency key), riding beside the welcome on day one so the first claim is a
round 100 · +8 per completed reply capped 20/day · Google link +100 once,
with the anonymous
wallet merged across as two `merge` rows inside `recordLinkedAccount`'s
once-only guard · profile-with-a-name +200 once.

The daily is a flat **20** (decided 2026-08-22): 80 + 20 makes the first
claim a round **100**, which is what the entry card promises, and every return
pays the same 20. An earlier build paid a higher return rate than the arrival;
that split was dropped for simplicity.

The one sink: **gifts**, three of them, and that is the whole MVP catalogue
(`COINS.gifts`): **Roses 50**, **Ambrosia 150**, **Pendant 500**. A chat turn
carries `gift: { id, item }`; the worker debits after validation and *before*
the upstream call — an unaffordable turn costs no OpenAI request and returns
402 — then narrates the gift onto the last user message (both engine paths
strip system messages), so the reply is the character's in-character
reaction. Client-side, gifts also move the ♥ meter (+1/+3/+10), which now
lives in the coins sheet; the gold chip took its header slot and falls back
to the old Level column whenever coins are off.

Prices carry the whole economy, because there is nothing else to buy. They
are set against the faucets deliberately: 100 on arrival affords Roses at
once, a day's talking (20 replies × 8 = 160) affords Ambrosia, and the
Pendant is the thing to come back for — or to unlock by completing a profile,
which is the only reason that +200 exists.

**The pendant is given once per character and worn from then on.** Its ledger
id is derived from `(user, character)` rather than from the client's random
id, so a second giving collapses onto the row that already exists: nothing is
charged, the reply still happens, and the response carries
`wallet.gift.charged: false` so the client does not celebrate a spend that
did not occur. The sheet reads **Worn** instead of a price. From then on
every turn with that character carries `PENDANT_NOTE` in the system prompt —
worded permissively on purpose, because a model told to mention a keepsake
mentions it in every single reply. Which characters wear one is derived from
the ledger (`coinPendantWorn`), so there is no second source of truth to keep
in step.

The way in from the conversation is a **Gift** button in the quick-reply
strip, beside Photo. Before it existed the only door was the coin chip in the
app bar, which is findable only if you already know it is there.

## The claim screen

The entry card's button reads **Tap to Claim Coins** (gated: a dark build
shows the original "Tap to Talk"), and as of PR #11 **the tap is the grant**:
app start only ever reads the wallet (GET /api/wallet — no rows created,
nothing granted), and the claim tap calls the granting POST /api/wallet/sync,
then raises the full-bleed claim screen (`CoinClaimScreen`) itemising what
landed — with a "2nd dawn in a row" streak line for returners (server-counted
from the daily grants' date refs; drawn only from 2 up). Things that matter
operationally:

- **It holds the story.** The screen defers `_raiseGate()` and
  `_triggerWelcomeSequence()` until it is collected, the same rule the entry
  card is built on — otherwise the opening plays out behind it and is gone by
  the time the visitor looks. A widget test pins this.
- **It is a new step in the funnel**, between `entry_tap` and the first line.
  `claim_shown` and `claim_tap` bracket it, both carrying
  `<characterId>#<coins claimed>`, and both are in `ALLOWED_EVENTS` — an event
  the worker does not know is silently counted as an arrival, which would
  inflate the denominator of every rate on the visits page. The gap between
  the two events is what the screen costs; watch it.

It never appears with nothing to show: `claim()` returns what THIS tap
granted, so a returning visitor whose daily is already claimed gets an empty
list and drops straight into the conversation. After #11, an `entry_tap`
without a `claim_shown` means the grant round trip FAILED — network or worker
error — which makes that gap on the visits funnel a health alarm, not noise.

## Surfaces

- `POST /api/wallet/sync`, `GET /api/wallet` — same HMAC + identity
  resolution as `/api/chat`; unrecognised ids get `wallet: null`, no rows.
- `/api/chat` — accepts `gift`, answers with a `wallet { enabled, balance,
  granted }` block; the client chip moves on every turn without polling.
- `/api/profile` PUT — pays the profile bonus, answers with the same block.
- `/admin/coins` + `/api/admin/coins` — faucets vs sinks by day and reason,
  top balances, any user's history. Basic auth like every admin page.
- Export-everything includes `coin_ledger` and `coin_wallets`.

## The off switch (read before touching)

`COIN_LEDGER` in wrangler.jsonc `vars`, currently the **default-off idiom**:
only the exact string `"true"` enables it. Off follows DELIVERY_LOGGING's
ack-don't-refuse rule — `/api/wallet*` answers `200 { enabled: false }` and a
gifted turn goes through as plain chat carrying `wallet: { enabled: false }`
— so "switched off" is distinguishable from "broken" in every response, and a
client built with the UI in it goes quiet instead of retrying. The client
additionally has its own kill switch, `AppConfig.coinsUiEnabled` (a build-time
const): FALSE builds a client with no coin surface at all and restores the
header exactly as it was. Once coins are the normal state, flip the worker
check to the `!== "false"` idiom in the same commit that removes the
allowlist.

## Rollout, in order

1. Merge to `main` with a version bump (suggest opening **1.8.0** — this is
   the kind of feature version strings exist to mark). `npm run deploy`
   applies migration 0014 to remote D1 *before* `wrangler deploy`; that
   ordering is load-bearing, do not deploy by hand. **Check
   `npx wrangler d1 migrations list mymate2_db --remote` first** — the 0008
   numbering collision is a known wound and nothing else may claim 0014.
2. Deployed dark, nothing is visible. Confirm: `/admin/coins` renders with
   zero rows; the app header still shows ♥ Level.
3. Soak: `npx wrangler secret put COIN_ALLOWLIST` with your own user id(s)
   (comma-separated; the literal entry `synthetic` admits
   `x-synthetic-test: 1` requests). Secrets take effect on the next deploy —
   the operational-notes trap. Play a session; read it back in `/admin/coins`.
4. Flip `COIN_LEDGER` to `"true"` in wrangler.jsonc, deploy. The next sync of
   every visitor grants welcome+daily and the chip appears.
5. To retreat: set it back to `"false"` and deploy. Balances keep; UI hides;
   the header falls back on its own.

## What to watch after the flip

- `/api/chat` p95 — the tribute debit is on the critical path (one indexed
  INSERT); the reply grant is not awaited into failure (it can cost at most
  the coin, never the reply — persistConversationLog's rule).
- `/admin/coins` faucet:sink by day — if nobody spends, the sink is the
  problem, not the faucets.
- The funnel pages — entry rate should not move (nothing coin-shaped exists
  before the entry tap; if it moves, something leaked upstream of it).
- Ledger write volume — it shares the D1 quota with chat logs and
  screen_ping; the 20/day reply cap is partly a budget cap.

## Traps specific to this feature

- The ledger uses SQLite space-form timestamps on purpose; do not "fix" any
  of its queries to ISO, and never window it jointly with conversation_logs
  without normalising (`exportAllTables` shows how).
- `x-user-id` is unverified. Anonymous wallets are deliberately allowed and
  deliberately low-stakes (server-set amounts, cosmetic sink). Before
  anything purchasable exists, add the claim-token step from the brief and
  require a signed-in session for purchases. Do not key anything
  irreversible on the bare header.
- A retried tribute is free (same gift id) but its *reply* grants +1 again —
  bounded by the daily cap, accepted for now.
- An upstream failure after a debit is not refunded: the client retry with
  the same gift id gets the reaction without paying twice, which heals the
  common case. A stuck one is an admin `adjust` row.
- The gift bubble text (`*gives … to <name>*`) is not a starter; if it is ever
  routed through the starter strip instead, `gen_starters` will label it
  "starter (unmatched)" — that label appearing is the alarm.
- Two lists in different files have to agree: `COINS.gifts` on the worker and
  `kTributeOptions` in the sheet, plus `AppConfig.tributeHeartScore`. A gift
  added to one and not the others is priced-but-undrawable, or drawn and
  scored zero. A Flutter test asserts the catalogue and the ♥ map have exactly
  the same keys; the worker refuses an item it does not sell with a 400.

## Deliberate gaps (phase 2+, in the brief)

Streak bonus (blocked on `is_return` having a baseline) · claim tokens ·
photo / "ask the Oracle" sinks · referral faucet · purchasable packs (needs a
web-billing decision and server-side receipt validation, neither of which
exists anywhere yet).
