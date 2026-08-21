# First two days of the engagement instrumentation — what the new columns said

**Date:** 2026-08-21 01:30 UTC (scheduled Friday-morning review) ·
**Window:** 48h for rates, 90h for the depth tracker · **Live:** 1.7.2+77,
deployed 01:19 UTC and auto-logged (every deploy since +74 has a
`deploy_log` row written by the deploy chain itself — the record is
self-maintaining now).

Traffic doubled versus the eval baseline: 1,457 arrivals in 48h, 749 cards
shown. Bundle penetration is directly visible at last: 1,399 of the versioned
visits ran +76 within a day of it shipping.

## The reel boost buys almost nothing but volume

The By-ad ids separate the campaigns cleanly for the first time:

| campaign (48h) | visits | taps | engaged |
|---|---|---|---|
| hercules-**reel** | 1,334 | **1** | 0 |
| hercules-**paid** | 105 | **4** | 0 |
| organic / none | 25 | 2 | **2** |

The paid (feed) campaign's tap rate per visit is ~**50×** the reel's
(4/105 vs 1/1334 — this one clears significance comfortably). Thursday, when
the scaled-up reel flood was ~92% of all traffic, produced **zero taps the
entire day**. Every conversation in the window came from organic arrivals.
The reel boost is buying visits whose measured behaviour is
indistinguishable from nobody: 27% show even 5s of attention, 85% of
decliners never touch the screen once.

The US boost stayed tiny (14 visits — US CPM, not a malfunction) and stayed
warm: 69% attention ≥5s vs 27% elsewhere, 1 tap, 1 engaged. Judge it on cost
per tap in Ads Manager, not cost per click.

## Fold: two-thirds of cards still render with the button off-screen

fold=below is **460 of 708** flagged showings (65%, same as day one).
Tap rates: fit **3/248 (1.2%)** vs below **2/460 (0.4%)** — the ~3× gap held
its direction at doubled n, though tap counts are still too small for
significance. The 65% itself needs no statistics: it is a rendering fact
that the screen's only call to action starts outside the first viewport for
most visitors. The card-fit fix (smaller portrait under a height threshold,
or a viewport-pinned button) remains the one product change the data argues
for.

## Considered vs inert: replicated

Of 703 measured decliners, **595 (85%) never touched the glass** — the
Wednesday 87% was not a first-day artefact. ~70 people per 48h "consider"
(touch and watch 5s+). That is the entire audience a copy change can reach.

## Returning devices never tap

9% of arrivals are repeat devices (124/1,400) and **0 of them tapped** —
cumulative since the flag shipped: 0 taps from ~180 returner visits. A
frequency cap on the boosts converts that ~9% of delivery from waste into
reach.

## Depth after opting in — n=13 now

| tapped (UTC) | client | fold | visible | engaged | turns |
|---|---|---|---|---|---|
| 08-17 17:42 | ig | — | 56s | no | 0 |
| 08-17 22:57 | fb | — | 92s | yes | 4 |
| 08-17 22:59 | browser | — | ? | yes | 1 |
| 08-18 14:24 | fb | — | 195s | yes | 2 |
| 08-18 14:46 | fb | — | 176s | yes | 4 |
| 08-18 15:34 | ig | — | 16s | no | 0 |
| 08-19 04:05 | fb | — | 20s | no | 0 |
| 08-19 08:35 | browser | — | 46s | no | 0 |
| 08-19 09:37 | fb | below | 23s | no | 0 |
| 08-19 10:08 | fb | fit | 14s | no | 0 |
| 08-19 14:31 | browser | below | 145s | yes | 1 |
| 08-19 15:24 | browser | fit | 250s | yes | 2 |
| 08-19 20:43 | ig | fit | 10s | no | 0 |

**6 of 13 engaged** after tapping, and the engagers are unambiguous: 1–4
completed exchanges, 1.5–4 minutes of real attention each — against a
population whose median attention is ~4 seconds and whose per-shown
engagement is ~0.3%. Instagram tappers remain 0-for-3. "Opting in predicts
depth" has survived a quadrupling of its sample.

## What this recommends

1. **Move budget from the reel boost to the feed campaign.** 50× the taps
   per visit is not a nuance. The reel spend is the flat ~1% made flesh.
2. **Cap ad frequency** — returners are ~9% of delivery and never convert.
3. **Ship the card-fit fix** so the ask is at least on screen for everyone;
   read the fold-split tap rates again a few days after.
4. Keep the US boost small and judge it on cost per tap; it is expensive
   and warm, which is the same trade the browser-vs-in-app split has shown
   all along.
