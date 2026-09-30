# Coin packs (consumable IAP) — decisions before coding

Written 2026-09-16, before any purchase code exists. Read with
`mythos-coins-2026-08-20.md`, which designed the wallet this sits on top of.

The aim: when a user runs out of free Mythos Coins they buy a pack of coins for
real money through the App Store (iOS first; web and Android later). This
document lists what is already in place, the structure I recommend, and the
questions that need an answer before the first line of purchase code. The
questions are ordered by how much they change the design. **Part A must be
settled first — everything else assumes its answers.**

---

## Decisions (Adam, 2026-09-28)

| # | Question | Decision |
|---|---|---|
| A1 | Subscription? | **No. Coins only**, gifting model. `isFreeTier` stays `true`; `/paywall` becomes the coin store; `premium_access` and "restore purchases" go. A subscription may come later. |
| A2 | What coins gate | Gifts, as today. Free faucets (daily 20, reply 8/cap 20, link 100, profile 200) **stay as they are**; tune from `/admin/coins` numbers later. |
| A3 | Packs | **300 / 1,000 / 3,000 coins at $2.99 / $7.99 / $19.99.** Product ids `mythos_coins_300`, `mythos_coins_1000`, `mythos_coins_3000`. |
| A4 | Expiry | Coins never expire, non-transferable. |
| B1 | Source of truth | **D1 ledger.** RevenueCat is a verification adapter only; our `user_id` is passed to it as `appUserID`. No table other than the `rc_events` audit log ever stores a RevenueCat id. |
| B2 | Free vs paid | **One balance, tracked separately.** Free coins are spent first (arithmetic, not per-coin). New `lifetime_purchased` on `coin_wallets`. Key metric: paid coins consumed per day. |
| C1–C3 | Identity | **Buy first, register after.** Keychain-stable device id + claim token for v1. The sign-in branch (`feat/sign-in-apple-google-email`: Apple, Google, email code) supplies the "protect your coins" prompt once merged; prompt once right after purchase, then a quiet badge. |
| D1 | Where "buy" appears | **v1: a secondary "Get more coins" link on the claim screen** (test surface, reachable in two taps). 402 upsell and coins-sheet entry follow. |
| D4 | Restore button | Dropped. |
| E1 | Refunds | **Balance may go negative.** Refund debits the paid pool. |
| F1 | Platform | iOS first; webhook path built store-neutral for Stripe/Play later. |
| — | Migration number | **0017** — the sign-in branch already took 0016 (`email_codes`). |

---

## Status (2026-09-28) — built and walked on the simulator against a local worker

Branch `feat/revenuecat-restore`. Worker suite: 111 tests green (21 new in
`backend/test/coin_packs.test.mjs`). `flutter analyze`: no errors.

Simulator run (iPhone 17 Pro, Xcode 27, `wrangler dev --local` with 0017
applied, launch config `wrangler-local-packs`; app built with
`--dart-define=WORKER_URL=http://localhost:8787` and the local APP_SECRET):
- RevenueCat configures under our device id (`[RevenueCat] configured for
  user_…`).
- Claim tap → +100, and the sync claimed the wallet (hash stored); the app's
  next `GET /api/wallet` was 200, so the token round trip works.
- "Get more coins" on the claim screen opens the store.
- A `NON_RENEWING_PURCHASE` webhook posted to the local worker for that id
  credited 1000 (`applied: true`, `lifetime_purchased` 1000); reopening the
  store showed 1100.
- Store sheet walked (later the same day, with Adam watching): RevenueCat
  dashboard now has `mythos_coins_300/1000/3000` as Test Store consumables
  ($2.99/$7.99/$19.99) in offering `coins`, set as default. The store lists
  all three with store prices; "Test valid purchase" on the 300 pack → the app
  polled the wallet 8× over 12 s, reconcile answered 503 (no `RC_SECRET_KEY`
  locally), so it showed "Your coins are on the way" — the designed fallback.
  A simulated webhook carrying the Test Store's transaction id then credited
  300 (`purchase:test_…` row; balance 400 = 100 free + 300 paid).
- Gotcha found: the `test_…` key that had been hard-coded belonged to a
  DIFFERENT RevenueCat project (its offering was `monthly/yearly/lifetime`).
  The fallback is now this project's Test Store key; the store's filter (only
  products the worker can credit) is what made the mismatch visible instead
  of selling the wrong thing.
- "Check again" now re-reads the wallet before asking RevenueCat, so it
  works without the secret key once the webhook has landed.

**Triple-check (2026-09-28, two adversarial reviews + dashboard audit) — fixed:**
1. *Sign-in merge bypassed the claim* (security): anyone guessing a device id
   could sign in with a fresh account and take the wallet. Now a claimed
   wallet merges only when the sign-in redirect carries a **merge ticket**
   (`POST /api/wallet/merge-ticket`, HMAC over the id, 10 min) obtained with
   the claim; the Google start route takes `anon_ticket`, the callback
   verifies it. Unclaimed wallets merge as before. **The sign-in branch's
   Apple/email/native flows must pass the ticket the same way.**
2. *Refund debt vanished on sign-in*: negative balances now cross too.
3. *Refund before purchase* (webhooks are unordered): the debit is booked
   from the catalogue, so the later purchase nets to zero.
4. *Reconcile could double-credit*: it now keys only on
   `store_transaction_id`, never RevenueCat's entry `id`. **Verify with one
   real `GET /v1/subscribers` response before setting `RC_SECRET_KEY`.**
5. *Lost claim-token response locked the wallet forever*: new
   `claim_used_at` column; a never-used claim can be re-minted once (the
   client clears its token on 403 and retries with `new`); a used one cannot.
6. Client: store waits for RevenueCat init; purchase detection watches
   `lifetime_purchased` (a reply grant can't pass for a pack); claim screen
   shows the live balance; Xcode 27's rewrite of the Runner deployment
   target was reverted (still iOS 15.0).
Known and accepted: cold-start offline shows the store closed (no cached
`packs`); reply grants don't check the claim (free coins only); Linux builds
now need libsecret.
- Not yet: a webhook actually delivered BY RevenueCat (needs the production
  URL live with 0017 + `RC_WEBHOOK_AUTH`), and a real App Store sandbox
  purchase (needs the App Store app configuration in RevenueCat + products in
  App Store Connect).

Xcode 27 notes: Flutter 3.44's two-arch simulator build fails on a `lipo`
ordering quirk (`flutter build ios --simulator`); `flutter run -d <sim>` (one
arch) and device/archive builds are unaffected. Pods declaring iOS 13 are
lifted to 15.0 in `ios/Podfile` `post_install`, which Xcode 27 requires.

**Server** (`backend/src/worker.js`, migration `0017_coin_packs.sql`)
- `POST /api/rc/webhook` — RevenueCat → worker. Auth = static `Authorization`
  value in secret `RC_WEBHOOK_AUTH` (plain or `Bearer …`). Stores every event
  in `rc_events`, credits `NON_RENEWING_PURCHASE` as `purchase:<transaction_id>`
  (idempotent), debits `CANCELLATION` as `refund:<transaction_id>` by the
  purchase row's own delta (balance may go negative). Sandbox events credit
  only allowlisted / `?dev=1`-marked wallets, or when var `RC_SANDBOX_CREDITS`
  is `"true"`. Always 200 once understood; 5xx only on storage failure.
- `POST /api/wallet/reconcile` — HMAC-signed like the wallet routes; asks
  RevenueCat's REST API (secret `RC_SECRET_KEY`, the `sk_…` key) for the
  customer's non-subscription purchases and credits any the ledger lacks.
- Wallet claim token: `x-wallet-claim: new` on a sync mints one (returned
  once as `claim_token`); a claimed anonymous wallet then refuses reads,
  grants, reconcile and gifts without it (403). Unclaimed wallets and signed-in
  ids are unaffected. The purchase itself needs no claim — the webhook is
  server-to-server.
- Wallet state gains `lifetime_purchased`, `free_unspent`, `paid_unspent`,
  `packs` (product id → coins). Trigger routes purchase/refund rows into
  `lifetime_purchased`; `coinMergeWallet` carries the paid remainder across a
  sign-in merge via `meta_json.paid`.
- Catalogue `COIN_PACKS` in the worker: `mythos_coins_300/1000/3000`.

**Client** (`lib/`)
- `purchases_flutter` ^10.12.0; `purchases_ui_flutter` removed (no consumable
  paywalls). `flutter_secure_storage` added.
- `core/services/device_identity.dart` — mirrors `user_id` and the claim token
  into the keychain (after-first-unlock, so it travels in backups); restored
  at the top of `main()`.
- `core/services/revenue_cat_service.dart` — rewritten: `init(appUserId)` with
  our id, `identify()` for the sign-in moment, `coinPackages()`,
  `purchase()` → `PurchaseOutcome {purchased, cancelled, pending, failed}`. iOS
  only (`isSupported`); the `test_…` Test Store key is the fallback.
- `features/wallet/coin_wallet.dart` — claim header on every call, stores the
  token, `reconcile()`, `awaitCredit()` (poll 12 s, then reconcile once).
- `features/wallet/presentation/coin_store_screen.dart` — the store, at
  `/coins` (and `/paywall`). `paywall_screen.dart` deleted.
- Claim screen: "Get more coins" text link (iOS only) → `/coins`.
- `AppConfig.isFreeTier` back to a constant `true`; subscription code paths
  stay dormant.

**Still to do before a sale**
1. Adam: accept the Xcode licence; then build to the simulator and walk the
   Test Store purchase (RevenueCat Test Store fires real webhooks).
2. RevenueCat dashboard: products `mythos_coins_300/1000/3000` in an offering
   (make it current, or name it `coins`); webhook URL
   `https://chat.deeploveechoes.com/api/rc/webhook` with an Authorization
   value; copy that value to `wrangler secret put RC_WEBHOOK_AUTH`, and the
   project's secret API key to `wrangler secret put RC_SECRET_KEY`.
3. App Store Connect: the three consumables, Paid Apps agreement, banking/tax,
   Server Notifications → RevenueCat (refunds depend on it), real `appl_` key
   into `.env` as `REVENUECAT_IOS_KEY`.
4. Deploy order: `wrangler d1 migrations apply mymate2_db --remote` (0017)
   before the worker — `npm run deploy` does this. Mark the test device with
   `?dev=1` (web) or add its id to `COIN_ALLOWLIST` so sandbox credits land.
5. Rotate `ADMIN_TOKEN` (still the leaked one).
6. Follow-ups: 402 upsell → `/coins`; "Get more" in the coins sheet;
   `/admin/coins` revenue/refund/paid-consumed figures; on the sign-in branch,
   call `RevenueCatService().identify(userId)` after login so anonymous
   purchases follow the account (the worker's wallet merge already carries the
   coins).

---

## 0. Where we stand (facts, verified today)

**Wallet — live since 2026-08-24.** `feat/coins` merged on 2026-08-22 (`42b718a`),
`COIN_LEDGER=true` in `wrangler.jsonc`. `backend/migrations/0014_coin_ledger.sql`
defines:

- `coin_ledger` — append-only; the row `id` is a *caller-chosen idempotency key*
  (`grant:daily:<user>:<date>`, `gift:<clientGiftId>` …). `kind` and `reason`
  are free text; the schema comments already name `kind='purchase'`,
  `kind='refund'` and `reason='pack'`, but **no code writes them**. `ref` is
  documented as "a transaction id for a pack".
- `coin_wallets` — a cache maintained by the `coin_ledger_ai` trigger. Balance
  is always `SUM(delta)`. It has an unused `claim_token_hash` column reserved
  for "Phase 2".
- Spends are a single conditional `INSERT … WHERE balance >= price` (D1 has no
  interactive transactions), so a spend can never overdraw. Insufficient funds
  → HTTP 402 → the client shows "Not enough coins for that tribute." **There is
  no buy path anywhere in the client.**

Economy (server-side constants, `worker.js` ~2283): welcome 80, daily 20, reply
grant 8 (cap 20/day), Google-link bonus 100, profile bonus 200. Sinks: roses 50,
ambrosia 150, pendant 500 (once per character).

**Identity — the weak point.**

- iOS: every user is an anonymous device id `user_<13-digit ms>` minted into
  SharedPreferences. There is no sign-in on iOS at all
  (`auth_service.dart:41` returns signed-out for `!kIsWeb`; no `google_sign_in`
  package). A reinstall mints a new id → new empty wallet.
- Web: Google Sign-In gives `google:<sub>`, with anon→account wallet merge.
- The worker only *shape-checks* `x-user-id`. It is unverified: anyone who
  knows (or guesses — it's an epoch timestamp) another user's id can read and
  spend that wallet. The coins runbook flagged this explicitly: *"Before
  anything purchasable exists, add the claim-token step … Do not key anything
  irreversible on the bare header."*

**RevenueCat — restored on branch `feat/revenuecat-restore` (uncommitted).**
The code is the pre-July subscription integration: entitlement
`premium_access`, `getOfferings` → `purchasePackage` → flip a local
`is_user_premium` flag. It never calls `Purchases.logIn`, so RevenueCat's
customer id has no relationship to our `user_id`. The server has no webhook
route and no notion of premium. In this session I also changed
`AppConfig.isFreeTier` to be `false` on iOS, which would switch on the
*subscription* paywall gates on the dashboard, chats and roleplay — see A1
before that ships.

**What RevenueCat offers today (docs checked 2026-09-16).**

- Consumables are "non-subscription purchases". Do **not** attach them to an
  entitlement (an entitlement would unlock forever after one purchase).
- The official grant pattern: don't credit client-side; listen for the
  `NON_RENEWING_PURCHASE` webhook and grant idempotently by `transaction_id`.
  Refunds arrive as `CANCELLATION` with the same `transaction_id` (needs App
  Store Server Notifications wired into RevenueCat).
- Webhooks are at-least-once, retried up to 5× with the same event `id`,
  **unordered**, authenticated by a static `Authorization` header you choose.
- Consumables cannot be restored via Apple once finished. Recovery on a new
  device only works if the RevenueCat app user id is *our* stable id.
- RevenueCat now has a first-class **In-App Currency** feature (free on all
  plans): server-side balances, products auto-credit on purchase, refunds
  auto-debit, REST endpoints for spend. Limits: no negative balances, not
  available on Flutter web, spends are one REST call each (~900/min), and RC's
  own docs say if you already have a backend ledger, keep it as truth.
- RevenueCat Paywalls (`purchases_ui_flutter`) do **not** support consumables;
  we build the pack UI ourselves.
- Web Billing (Stripe) supports consumables; Flutter web SDK is beta.
- `purchases_flutter` latest is 10.12.0 (we pin ^10.3.0); iOS 13+. No breaking
  changes 10.3 → 10.12. Bump.
- Fees: Apple 30%, or 15% on the Small Business Program (< $1M/yr — apply if
  not already enrolled). RevenueCat free to $2,500 monthly tracked revenue,
  then 1%.

---

## 1. Recommended structure

Stated up front so the questions have something to push against.

```
 iOS app                       RevenueCat                     Worker (D1)
 ────────                      ──────────                     ───────────
 configure(appUserID = our user_id)
 purchasePackage(pack) ──────▶ verifies with Apple
   ◀── PurchaseResult          ── webhook NON_RENEWING_PURCHASE ──▶ POST /api/rc/webhook
 poll GET /api/wallet                                              auth header check
   until balance moves                                             dedupe on event id
   (or 10 s → "on its way")                                        INSERT OR IGNORE
                                                                   coin_ledger id =
                                                                   purchase:<transaction_id>
                               ── CANCELLATION (refund) ─────────▶ refund:<transaction_id>, negative delta
```

1. **D1 ledger stays the single source of truth.** RevenueCat verifies the
   purchase with Apple and tells us about it; it never holds the balance.
   (RevenueCat In-App Currency is an alternative — see B1 — but it would mean
   every gift spend becomes a REST call out of the worker and we lose the
   ability to go negative on refunds.)
2. **RevenueCat app user id = our `user_id`.** Set at `configure` time from the
   id we already mint. That is the join key for the webhook and the only way a
   purchase survives to a new device.
3. **Credit happens only from the webhook**, keyed `purchase:<transaction_id>`
   through the existing `coinGrant` idempotent insert, so retries and
   duplicate events are free. Raw events land in a small `rc_events` table
   first (event id PK) so we can audit and replay.
4. **Client never asserts a purchase.** After `purchasePackage` resolves it
   simply re-reads the wallet. A reconcile route (`POST /api/wallet/reconcile`)
   asks RevenueCat's REST API for the customer's non-subscription transactions
   and back-fills any missing `purchase:` rows — the belt-and-braces for a lost
   webhook and the answer to "I paid and nothing happened".
5. **Refund = negative ledger row.** Balance may go negative; spending is
   already guarded by `balance >= price`, so a negative balance just means the
   next pack pays the debt first.
6. **Claim token before launch.** Server issues a random secret on first
   `/api/wallet/sync`, stores its hash in the existing `claim_token_hash`
   column, and requires it on every wallet write and on the purchase paths. Turns
   the guessable `x-user-id` into something an attacker can't use. Small job;
   the column is already there.
7. **Sandbox events credit only dev-marked wallets** (`environment=SANDBOX` →
   require `site_visits.is_dev` or a `COIN_ALLOWLIST` id), so a tester can
   never mint production coins.

---

## 2. Questions to settle

### A. Product model (changes everything downstream)

**A1. Is there still a subscription?** The restored code gates dashboard, chat
and roleplay behind a `premium_access` subscription. Coins are a different
model. Options:

- **Coins only** — everyone can chat; coins buy gifts (and later photos,
  Oracle, etc.). Then `isFreeTier` must stay `true` everywhere, the old
  `/paywall` becomes the coin store, and `premium_access` / the "restore
  purchases" button go away. *(My recommendation for v1 — it's what the wallet
  was designed for and it's one product to explain to Apple.)*
- **Hybrid** — a subscription for unlimited chat *plus* coins for gifts. Common
  in companion apps, but it is two purchase flows, two sets of App Store
  products and a much bigger review surface. Not a v1.
- **Subscription only** — then this brief is moot.

**A2. What do coins gate?** Today only tributes. If chat itself never costs
coins, most users never run out and never buy. Is the plan to add sinks
(per-message cost after a daily free allowance? photos? Oracle?) *before* or
*after* packs ship? This decides whether the "out of coins" moment happens in
the chat composer or in the gift sheet, and it decides the pack sizes.

**A3. Pack sizes and prices.** Need concrete numbers. Anchors: free income is
100 on day one and ~40/day after; roses 50, ambrosia 150, pendant 500. A
typical ladder is three packs with a rising bonus, e.g. 300 / 1,000 / 3,000
coins at $2.99 / $7.99 / $19.99 — but that's a placeholder, not a proposal.
Also: do the gift prices stay as they are once coins cost money?

**A4. Coins never expire and are non-transferable.** Apple 3.1.1 forbids
expiring purchased currency. Fine with the ledger as is — confirming it is
policy, so no "use it or lose it" mechanics later.

### B. Where the balance lives

**B1. D1 ledger (recommended) or RevenueCat In-App Currency?** RC's feature is
free and gives a dashboard, but every spend becomes an outbound REST call from
`/api/chat`, it clamps at zero on refunds, it doesn't do Flutter web, and its
balance would drift from ours the first time anything spends outside RC. Their
own docs say keep an existing backend ledger as truth. I'd use D1 and, if we
want their dashboard, mirror purchases only.

**B2. One balance or two?** Should purchased coins be distinguishable from
earned coins? Needed for: refund clawback that only touches purchased coins,
and for analytics ("did paid coins get spent?"). The ledger already records
`kind`, so this is free at the data level; the question is whether the *UI*
ever shows two numbers. Recommend: one balance, ledger keeps the provenance.

### C. Identity and recovery

**C1. Buying while anonymous on iOS.** With no iOS sign-in, purchases attach
to the device id. Delete the app → the id is gone → the coins are gone, and
Apple cannot restore a consumable. Three options:

- Ship anonymous with a plain disclosure on the store screen ("coins are stored
  on this device") — fastest; some support load; Apple has accepted this
  pattern.
- Build native Google Sign-In first (there is none on iOS today; it is a real
  sub-project: `google_sign_in` package, the existing web session cookie flow
  doesn't apply). Coins then follow the account.
- Middle path: iOS keychain-backed device id. The keychain survives app
  deletion, so a reinstall keeps the same `user_id` and wallet. Small change
  (`ensureUserId` in `delivery_log.dart`), no sign-in needed, and it's what we
  pass to RevenueCat. *(Recommended for v1; sign-in can come after.)*

**C2. Cross-platform.** A web user is `google:<sub>` or an anon id; an iOS user
is `user_<ms>`. The same person's coins won't follow them between web and iOS
until iOS has sign-in. Acceptable for v1? (The paid traffic is on web; see F.)

**C3. Claim token now?** See §1.6. The alternative is to accept that a
guessable header protects real-money balances until sign-in exists. I would not
ship money on the bare header.

### D. Purchase flow and UX

**D1. Where does "buy" appear?** Candidates: a "Get more" row in the coins
sheet; a direct offer at the 402 moment ("Not enough coins — get 300 for
$2.99"); the empty-balance chip. Apple wants the price visible before the sheet.

**D2. The wait after purchase.** The webhook usually beats the client, but not
always. Copy for the poll state ("Adding your coins…") and for the timeout
("Your coins are on the way — they'll appear shortly") plus a "Didn't get your
coins?" button that hits reconcile. Decide whether the store screen stays open
or pops back to chat.

**D3. Pending / deferred purchases.** "Ask to Buy" on child accounts returns a
pending result. With an AI‑romance app the age rating will be 17+/18+, which
should make this rare, but the code has to handle `PurchasesErrorCode.paymentPendingError`
gracefully rather than as a failure.

**D4. Restore button.** The old paywall's "Restore purchases" is meaningless for
consumables and would confuse people. Drop it, or make it call reconcile.

**D5. Custom store UI.** RevenueCat's hosted Paywalls can't sell consumables,
so `purchases_ui_flutter` can be removed again unless a subscription returns.
The pack screen is ours; it reads packages from an offering and shows
`storeProduct.priceString` (already localised by Apple).

### E. Refunds and abuse

**E1. Negative balance policy.** Buy → spend → refund is the standard abuse. RC
clamps at zero; I recommend allowing the ledger to go negative (the guard on
spend already handles it) so a refund is never a free gift. Needs one line of
UI ("−250 coins") — or do we hide negatives and show 0 with a note?

**E2. Apple consumption information.** When a customer requests a refund Apple
asks the developer (via `CONSUMPTION_REQUEST`) whether the content was consumed;
answering lowers refund approvals. RevenueCat can answer automatically once
enabled in the dashboard, but Apple requires the user's consent to share it.
Decide whether to turn this on and add the consent line to the store screen.

**E3. App Store Server Notifications → RevenueCat** must be configured in App
Store Connect or refunds never reach us at all. Adam's action (needs the
App Store Connect account).

### F. Platforms and traffic

**F1. iOS first — but is anyone there?** Memory says paid traffic is web via
Facebook. Before building, pull the platform split from `site_visits` /
`message_delivery` for the last 30 days. If iOS is a rounding error, either
the first release should be web (Stripe via RevenueCat Web Billing) or the
iOS build is a proving ground for the flow with revenue coming later.

**F2. Web Billing.** Supports consumables; needs a Stripe account connected to
RevenueCat; Flutter web SDK is beta. Same webhook path serves both stores
(`store: STRIPE`), so the worker work is shared. Do we plan it into the schema
now (yes — `store` column in `rc_events`) even if the UI comes later?

**F3. Android.** Later; same code path via Google Play. Nothing to decide now
beyond keeping product ids store-neutral.

### G. Security and ops

**G1. `ADMIN_TOKEN` is still the leaked 2026-08-08 token.** `/admin/coins` will
now show purchase data. Rotate before packs ship. Adam's action.

**G2. Webhook secret.** A new `RC_WEBHOOK_AUTH` secret via `wrangler secret
put`, checked with `timingSafeEqual` like the admin token. Reject anything else
with 401 and log it.

**G3. Sandbox isolation.** §1.7. Also: RevenueCat Test Store purchases fire real
webhooks with `environment=SANDBOX`, so this must be in place before the first
simulator test, not before launch.

**G4. `REQUIRE_SIGNATURE` stays true; HMAC continues to cover `/api/wallet*`.**
The webhook route is the one unsigned-by-us entry point, hence G2.

### H. Data and reporting

**H1. Migration `0016`.** Proposed: `rc_events (id PK, type, app_user_id,
user_id, transaction_id, product_id, store, environment, price, currency,
event_ts, received_at, applied, payload_json)`; plus a `CHECK` on
`coin_ledger.kind` now that the vocabulary matters. No change to
`coin_wallets`. Apply remotely with `wrangler d1 migrations apply` before the
worker ships (standard rule).

**H2. Admin.** `/admin/coins` gains revenue, packs sold, refunds, negative
balances, and an "unapplied events" list. `export-all` already has the
`created_at` format mismatch between tables — purchase rows will inherit it;
decide whether to fix that now.

### I. Compliance and store setup (Adam's actions, can start today)

- App Store Connect: create the consumable products (ids like
  `mythos_coins_300`, never containing a price), attach to the app,
  set up the **shared secret / In-App Purchase key** and **Server
  Notifications URL** pointing at RevenueCat. Products need review with the
  first build that uses them.
- RevenueCat dashboard: real `appl_` key into `.env` (replacing the
  `test_` fallback); an offering "coins" with the three packages; webhook URL
  `https://chat.deeploveechoes.com/api/rc/webhook` with the auth header.
- Age rating: Apple's 2025 questionnaire asks about AI chatbot functionality;
  romance chat → expect 17+/18+. Check the current rating before submitting a
  build with IAP.
- Small Business Program enrolment (15% instead of 30%).
- Paid Apps Agreement signed and banking/tax forms complete in App Store
  Connect — IAP is rejected in review without them.

### J. Sequencing

Proposed order, each a separate branch/PR on top of `feat/revenuecat-restore`:

1. **Foundation (no money yet):** keychain-stable device id, claim token, SDK
   bump to 10.12, `Purchases.configure(appUserID: userId)`, remove subscription
   gating (`isFreeTier` back to always-true if A1 = coins only).
2. **Server:** migration 0016, `/api/rc/webhook`, `/api/wallet/reconcile`,
   sandbox isolation, admin additions. Deploy with no client that can buy —
   nothing changes for users.
3. **Client store:** pack screen, 402 upsell, post-purchase poll. Test end to
   end with RevenueCat Test Store on the simulator, then Apple sandbox on
   TestFlight.
4. **Launch gates:** ADMIN_TOKEN rotated, Server Notifications confirmed by a
   sandbox refund arriving as `CANCELLATION`, products approved.

Version: this is the second money release; suggest it lands as **2.2.0**.

---

## 3. Things I couldn't verify

- Whether RevenueCat's automatic consumption-info reply covers consumables (their
  doc page 404'd) and how consent is captured.
- The current iOS share of traffic (query needed — F1).
- Whether the App Store Connect app already has any IAP products or a signed
  Paid Apps Agreement.

---

## Update 2026-09-30 — App Store side wired up; iOS floor raised to 16

- App Store Connect (Mythos Live, `com.sklabs.mythoslive`): three consumables
  created (`mythos_coins_300/1000/3000`, $2.99/$7.99/$19.99, all countries,
  review notes set). Paid Apps Agreement, bank and W-9 all Active. **Still
  needed per product: a review screenshot of the coin store**, and the first
  IAPs must be submitted together with the 1.0 app version.
- RevenueCat: App Store app "Mythos Live (App Store)" with the In-App Purchase
  key (valid), the three products attached to the `coins` offering beside the
  Test Store ones, "track purchases from server-to-server notifications" on.
  Apple's production AND sandbox Server Notification URLs point at
  RevenueCat's endpoint. Worker webhook verified end to end (TEST event → 200,
  `rc_events` row). `REVENUECAT_IOS_KEY` (the public `appl_` key) is in `.env`.
- **iOS deployment target raised 15.0 → 16.0** (Podfile ×2, pbxproj ×3,
  Podfile.lock synced; `pod install` needs `LANG=en_US.UTF-8` in this shell).
  Reason: 15.0 was only the floor Apple/Xcode 27 allow, not a user-support
  decision; iOS 16 drops just the iPhone 6s/7/SE-1 class. It also removes the
  StoreKit 1 path, so the legacy App-Specific Shared Secret is NOT needed.
- **Before App Review: `wrangler secret put RC_SANDBOX_CREDITS` = `true`.**
  Reviewers and TestFlight testers buy in Apple's sandbox, which the worker
  refuses to credit by default; without this the reviewer never gets coins.
  Remove it after approval (`wrangler secret delete RC_SANDBOX_CREDITS`).
- Small Business Program date in RevenueCat (2026-09-29) affects reporting
  only; confirm enrolment or click Remove.
