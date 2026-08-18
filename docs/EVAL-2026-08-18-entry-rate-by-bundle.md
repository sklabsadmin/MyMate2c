# Entry rate across the +68 boundary — the eval, and what it actually found

**Date:** 2026-08-18 11:40–12:00 UTC · **Data:** 48h `export-all` via
`tool/prod_eval_segments.mjs` (10,297 site_visits rows, TH excluded) ·
**Branch:** `claude/logs-logging-eval-adi2i9`

The job was: re-run the funnel on the +68 bundle, segmented by bundle version
across the a9813f1 boundary, and answer (a) does the wider, unbiased
denominator move the entry rate, and (b) does "opting in predicts depth"
survive a sample bigger than 3. Both questions got answers, neither the
expected way.

## What production is actually running

| | |
|---|---|
| `deploy_log` says | 1.7.1+67, deployed 2026-08-17 13:00 UTC, "Current" |
| `version.json` says | **1.7.1+70** |
| This repo's main | 1.7.1+68 (a9813f1) |
| This branch | 1.7.1+69 (e2ac747, unmerged) |

A build numbered +70 — which exists nowhere in this repo's history — is live,
and no deploy after +67 was recorded in `deploy_log`. So: **+68 as such was
never deployed**, something newer than anything on main is serving, and the
deploy record has a hole. The worker was NOT redeployed along with it
(`export-all` still returns four tables), so `message_delivery.app_version`
is still unreadable in bulk and per-visit bundle attribution is still
impossible. Until the +70 contents are identified, every "post-boundary"
statement below is time-based, bounded by behaviour.

## (a) The denominator question — answered, but not by +68

The premise of the question was that the +67 card was gated on *empty
history*, so devices carrying the 1.7.0 auto-played monologue were silently
excluded and the measured cohort was skewed toward fresh devices. a9813f1's
commit message put the first-night skew at nine to one: "45 Instagram visits
reached a chat screen and 5 saw the card."

**That number does not reproduce, and the mechanism it implies was never
material in this window.** Against `site_visits` for the first night
(2026-08-17 13:00 → 2026-08-18 02:00 UTC):

| first night | n | `/c/*` path | app_ready | character_tap | entry_shown |
|---|---|---|---|---|---|
| Instagram | 65 | 65 | 59 | 49 | **49** |
| Facebook | 162 | 162 | 150 | 121 | **120** |
| browser | 26 | 25 | 24 | 25 | 25 |

Every Instagram visit that reached a character screen saw the card, the first
night included. The 59 card-less "reached" visits that night decompose by
event shape into `arrive/hide/leave` and `arrive/leave` with median visible
time 0–1.7s — **deaths during load, "reached" only by URL**. Exactly one
visit all night reached a screen (character_tap) without a card: 7.5s
visible, strip_rotate present, i.e. one genuine pre-card bundle (or one
returning speaker). The 45-vs-5 was almost certainly counted on path or on a
table other than the funnel; whatever its provenance, the population it
described is not in the funnel rows.

Across the whole era since +67 deployed: shown/reached is **319/320 =
99.7%** (ig 70/70, fb 223/224, browser 26/26). The cohort the +68 fix widens
the card to is ~0.3% of reached screens, not ~90%.

So the answer to (a): **no. The wider denominator cannot move the entry
rate, because the excluded cohort had already churned to ~1 visit in 320 by
the time the fix landed.** Retroactively, this also means the 0.9% measured
pre-fix was never meaningfully biased — "treat 0.9% as pre-fix" turns out to
be "treat 0.9% as correct". a9813f1 stays right by construction (it asks
"has this person spoken", which is the question the card poses) — it just
fixes a fault with almost no remaining cases.

## The entry rate itself, per segment

48h window, visits segmented by the app deploy they arrived under
(deploy-time boundaries — see caveat about +70 above):

| segment | visits | reached | shown | tapped | engaged | entry rate |
|---|---|---|---|---|---|---|
| 1.7.0+65 (auto-play) | 147 | 114 | — | — | 2 | — (no card) |
| 1.7.1+66 | 3 | 3 | 3 | 0 | 0 | 0/3 |
| 1.7.1+67→+70 | 410 | 320 | 319 | 3 | 2 | **0.9% [0.3–2.7%]** |

The +65 segment is the old auto-playing design measured in the same window
against the same campaign mix: engaged 2/147 = 1.4% [0.4–4.8%]. The card
design: 2/410 = 0.5% [0.1–1.8%]. Same statistical answer as the 30-day
baseline (0.95%): **two opposite first-screen designs, one flat ~1%.** The
first screen has now been tested both ways with the same result, on top of a
delivery layer measured healthy — the lever is upstream in who the campaign
delivers and what the ad promises, exactly as the 2026-08-18 morning read
concluded.

Since 22:59 UTC on the 17th — roughly 13 hours and ~150 shown cards at the
time of this pull — there have been **zero taps**. The last 90 minutes
(under +70): 19 visits, 14 reached, 14 shown, 0 taps, 0 engaged.

## (b) Depth after opting in — n is still 3, and cannot be bigger yet

All three `entry_tap` visits in the 48h window, joined to their conversation
rows:

| arrived (UTC) | client | src | visible | engaged | turns (ok) |
|---|---|---|---|---|---|
| 08-17 17:42 | instagram | button | 56s | no | 0 |
| 08-17 22:57 | facebook | button | 92s | yes | 4 (4) |
| 08-17 22:59 | browser | button | ? | yes | 1 (1) |

The card is 23 hours old; these are the only tappers that exist. At 0.9% of
~300 shown/day the sample grows by ~3/day, so "does it survive n>3" is a
question for later in the week, not for today. What can be said now:

- Engaged after tapping: 2/3 [20.8–93.9%]. Under this design engagement
  *requires* the tap, so the honest comparison is against the auto-play era:
  P(first_message | reached screen) there was 2/114 = 1.8%. The tap
  concentrates intent by an order of magnitude even at the bottom of its
  interval.
- Visible time: tapper median 91.8s vs decliner median 5.2s.
- The Facebook tapper went four completed exchanges deep. The Instagram
  tapper tapped and then did nothing — the first counter-example to "opting
  in predicts depth". 2/3, not 3/3.

Direction intact, sample unchanged, verdict deferred by arithmetic: nothing
about +68/+70 changes how fast tappers accumulate.

## What this eval could not do, and what unblocks it

1. **Per-visit bundle attribution.** `site_visits` records no version;
   `message_delivery.app_version` is the only per-visit version anywhere and
   `export-all` on the deployed worker predates its inclusion. This branch
   widens `export-all` to carry it (`backend/src/worker.js`, tested). It
   takes effect on the next worker deploy. Until then, stale-bundle
   contamination is bounded behaviourally (shown/reached, engaged-without-
   card), which this eval did — the bound came out at ~0.3%.
2. **Deploy hygiene.** +70 is live with no `deploy_log` row and no repo
   commit that says what it is. Whoever deployed it: `POST
   /api/admin/deploys` with the real `deployed_at`, and say which commits it
   contains — every segmented analysis after this one keys on that table.
3. **Client version in the beacon.** The durable fix is for the splash
   beacon to carry the bundle version on `arrive` (stamped into index.html at
   build time), so every visit self-identifies without needing to have
   rendered a bubble. Schema change (`site_visits.app_version`) + build
   stamping; worth doing the next time the funnel schema is touched.

## Traps carried forward

Unchanged from `docs/HANDOFF-2026-08-18-prod-data-access.md`: `duration_ms`
is wall clock (use `visible_ms`); `character_tap` means "reached a screen",
never a tap; the admin dwell buckets still read `duration_ms` and are still
wrong. New from this eval: **"reached" must mean `character_tap`, never
`path=/c/*`** — by path, 59 first-night load-deaths masqueraded as an unasked
cohort and produced the 45-vs-5 misread that motivated a fix for a fault that
barely existed.
