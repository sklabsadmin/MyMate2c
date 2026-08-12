# Analysis handoff — 2026-08-12

For the session doing today's log analysis. Everything below is either measured
or checkable; where something is inferred it says so.

---

## 1. Where things stand

| Branch | State |
|---|---|
| `main` | Analytics instrumentation + quick-reply attention cues. **Deployed** as 1.6.4+60. |
| `feat/quick-reply-attention-cues` | Ahead of main by the survival-curve admin view. **Not deployed.** |

Production is `chat.deeplovepoems.com` and `chat.deeploveechoes.com` (worker
`mythoslive`). `version.json` answers "is this live" without comparing asset
hashes.

D1 `site_visits` is 24 columns, ~12,092 visit rows, migrations all recorded.

---

## 2. What the instrumentation now records

Live since the 11 Aug deploy. **None of it exists on rows written before that**,
so any comparison with earlier days is a comparison of different measurements.

| Event / column | Answers |
|---|---|
| `hide` / `show` | Backgrounded vs gone. `hide` carries visible-ms so far — a checkpoint that survives a visit whose `pagehide` never arrives |
| `leave.exit_mode` | `dismissed` (destroyed on screen) / `hidden` (destroyed after backgrounding) / `bfcache` (frozen, restorable) |
| `visible_ms` | Time actually on screen, summed across backgroundings |
| `hide_count` | How many times they backgrounded |
| `strip_rotate` | What the quick-reply strip offered, and when. The **offer** half of offer/take |
| `screen_ping.detail` | Script position: `odysseus#t<turns>#s<set>` |
| `viewport_h` | Which of three strip layouts they saw (see §5) |
| `nav_type` | `navigate` / `reload` / `back_forward` — reload inflation is now a fact, not an inference |

---

## 3. Baseline: the night of 10–11 Aug (pre-instrumentation)

15½ hours, from 20:30 Thai on the 10th. `country='TH'` is the developer and is
excluded, matching the opening brief.

- **104 sessions, 99 real.** All 99 landed on a `/c/` link — 98 Odysseus, 1
  Calypso. **Zero homepage traffic.** The campaign link is the entire funnel.
- **74 reached a character screen** (75%). 25 did not.
- **0 of 74 tapped or typed anything.** `send_failed` was also 0, so nothing was
  attempted and failed — nothing was attempted.
- **Median time on the chat screen: 5.5s.** 47% gone within 5s. 19 stayed past
  10s; 8 hit the 28s tick cap and still touched nothing.
- Audience: PT 17, GR 15, RO 11, ES 9, IT 7, FR 7, SK 6. **US was 4 of 99.**

### The 25 who never reached a character screen

`character_tap` fires from `ChatScreen.initState` — automatically on mount, no
user action. On a `/c/` link that screen *is* the destination, so this is the
app failing to deliver, not disinterest.

- 8 never signalled `app_ready` at all
- 2 had `app_ready` at 13.9s and 17.9s, which is the 15s splash cap firing
  (`MYTHOS_READY_CAP_MS`) — `app_ready` fires on timeout too, so a load figure
  near 15s is a failure wearing a success's clothes
- 6 waited 24–30s and still never got a character screen

Never-reached rate by load time: **<2s → 9%, 2–5s → 35%, 5s+ → 71%.** Median
load 2.4s for never-reached vs 1.2s for reached.

---

## 4. Beat map — deterministic, from the running script

`tool/beat_map.mjs` + `test/odysseus_beat_map_dump.dart`. Plays the real
`ChatScreen` on flutter_test's virtual clock, so these are exact, not estimated.

```
first line lands        0.4s
FIRST QUESTION asked    6.3s   "What have you heard?"
strip swaps to set 2   15.4s
strip swaps to set 3   26.9s
```

Against the 74 chat opens: **51% left before the first question**, 78% before
the strip changed once, 89% before it changed twice.

`_briskPacing` was tuned to reach the first question at 6.2s and hits 6.3s — it
meets its own target. The target is simply set later than half the audience
stays.

**Also:** the strip carries set 1 from 0.1s, but set 1 is *answers* to "What
have you heard?" — a question that arrives at 6.3s. For the first six seconds
every visitor is offered three replies to something nobody asked.

Virtual-clock timings are a **floor**. A backgrounded tab is throttled to ~1Hz
and quantises every delay to a whole second, so real visitors reach each line at
these times or later, never sooner.

---

## 5. Traps

**The dwell figures in §3 are built on a broken measurement.** `leave` used to
fire on the first `visibilitychange` and latch, so dwell was time-to-first-
backgrounding. 24 of 68 sessions kept firing ticks after their own recorded
departure; one was logged as a 1.2s bounce while still on screen 28s later. The
load-bucket comparison survives (like vs like); any absolute "they left at X"
from before the deploy does not. This is what the `hide`/`show` split fixes.

**Ticks are not session length.** `screen_ping` stops at the first sign of
engagement and caps at 28s. Someone who read for three minutes and someone who
left at 28s are identical. Use `visible_ms` for duration; ticks measure
hesitation before engaging.

**`source` is the utm tag, not the client.** `detectTrafficSource` returns
`utm_source` before it looks at the user-agent, so the bio link tags everything
`ig` whichever app opened it. The opening brief measured ~93% of that as
Facebook's in-app browser. Use the **Client** column, derived from user_agent.

**`country='TH'` is the developer.** A handful of long local sessions visibly
bends a curve this small.

**Three viewport bands, not two** (`chat_screen.dart`): ≥720 shows the hint plus
3 prompts; 560–719 shows 3 prompts and no hint; <560 drops to 2 prompts.
`_shortScreenHeight` gates the *hint*, `_veryShortScreenHeight` drops the
prompt. Nothing enforces agreement between those Dart constants and the worker
template that describes them.

**I got the migration advice wrong yesterday** and it is worth knowing why: I
checked the **local** D1 for a `d1_migrations` table, found none, and concluded
the project had never used wrangler's migration system. Remote had it all along
with all nine recorded. Followed literally, applying by file would have left
0008/0009 unrecorded and manufactured the duplicate-column failure it warned
about. Corrected in `docs/DEPLOY-2026-08-11-analytics.md` — use
`migrations list --remote` then `migrations apply --remote`. **Do not infer
remote state from local state.**

**Migration number collision:** `0008_viewport_height.sql` here and
`0008_visit_platform.sql` on `claude/distracted-jepsen-f66243` are different
files sharing a number. Both applied; `d1_migrations` keys on filename so
nothing breaks today, but whoever merges that branch should renumber.

**`worker.js` has no automated tests.** It took +550/−88 across this work and
was verified manually — against a fixture built from the real migrations, driven
through the real endpoints under `wrangler dev`, with every admin page rendered
in headless Chromium. None of that re-runs on the next change.

---

## 6. What today's session should do

**First, get the data.** Two obstacles, both real:

- A cloud session cannot reach production — no `CLOUDFLARE_API_TOKEN`, and the
  egress proxy blocks browser CONNECT. **Run this locally.**
- The `ADMIN_TOKEN` in `.env` is a local dev value, not the deployed secret, so
  the admin pages cannot be read remotely with it. The survival curve built in
  `2b86a25` has never been run against real data for exactly this reason.

Queries that produce what the analysis needs are in §7 below.

**Then answer these, in order of value:**

1. **Did anyone tap?** Baseline is 0 of 74. This is the first data with the
   attention cue live. This is the whole question.
2. **How much of the old "bounce" was an aborted swipe?** `hides > 0` with a
   healthy `visible_ms`. Predicted ~35% from the tick/dwell discrepancy.
3. **Does the 51%-before-6.3s finding survive** now that `screen_ping.detail`
   gives logged script position instead of replayed timing?
4. **What share of arrivals are `nav_type='reload'`?** That has never been
   measured and it inflates every visit count in the historical record.
5. **Is the 560–719 viewport band populated?** i.e. how many visitors get
   prompts with no hint telling them the prompts are tappable.
6. **`exit_mode` distribution** — dismissed vs hidden vs never-reported.

**Deploy the survival curve** (`feat/quick-reply-attention-cues`, not yet on
main) once there is data worth pointing it at. It reads existing rows, so it
works retroactively over everything logged to date.

**Do not start on the fix list until 1–3 are answered.** The obvious candidate —
cutting two lines from turn 1 so the first question lands near 3s instead of
6.3s — is a content edit, cheap and reversible, and the beat map measures it
directly. But it is the wrong move if the cue already fixed the tap rate.

---

## 7. Data pull

```bash
# A — how sessions ended (the genuinely new dimension)
npx wrangler d1 execute mymate2_db --remote --command "
SELECT ending, COUNT(*) n FROM (
  SELECT a.visit_id,
         COALESCE((SELECT l.exit_mode FROM site_visits l
                    WHERE l.visit_id=a.visit_id AND l.event='leave'
                    ORDER BY l.created_at DESC LIMIT 1),'no leave row') AS ending
  FROM site_visits a
  WHERE a.event='arrive' AND a.created_at >= datetime('now','-24 hours')
  GROUP BY a.visit_id) GROUP BY ending ORDER BY n DESC;"

# B — per-session detail, the one to actually analyse
npx wrangler d1 execute mymate2_db --remote --json --command "
SELECT MIN(a.created_at) t, MIN(a.country) cc, MIN(a.path) path, MIN(a.nav_type) nav,
  MIN(a.viewport_h) vh,
  (SELECT MIN(r.duration_ms) FROM site_visits r WHERE r.visit_id=a.visit_id AND r.event='app_ready') load_ms,
  COALESCE((SELECT MAX(l.visible_ms) FROM site_visits l WHERE l.visit_id=a.visit_id AND l.event='leave'),
           (SELECT MAX(h.visible_ms) FROM site_visits h WHERE h.visit_id=a.visit_id AND h.event='hide')) vis_ms,
  (SELECT COUNT(*) FROM site_visits h WHERE h.visit_id=a.visit_id AND h.event='hide') hides,
  (SELECT l.exit_mode FROM site_visits l WHERE l.visit_id=a.visit_id AND l.event='leave'
    ORDER BY l.created_at DESC LIMIT 1) exit_mode,
  (SELECT COUNT(*) FROM site_visits g WHERE g.visit_id=a.visit_id AND g.event='screen_ping') ticks,
  (SELECT g.detail FROM site_visits g WHERE g.visit_id=a.visit_id AND g.event='screen_ping'
    ORDER BY g.created_at DESC LIMIT 1) last_pos,
  (SELECT COUNT(*) FROM site_visits s WHERE s.visit_id=a.visit_id AND s.event='strip_rotate') rots,
  EXISTS(SELECT 1 FROM site_visits e WHERE e.visit_id=a.visit_id
           AND e.event IN ('input_typed','starter_tap','first_message')) engaged
FROM site_visits a WHERE a.event='arrive' AND a.created_at >= datetime('now','-24 hours')
GROUP BY a.visit_id ORDER BY t DESC;" > last-night.json
```

Exclude `cc='TH'` when computing rates. Remember `visible_ms` is NULL for rows
written before the 11 Aug deploy — treat NULL as unknown, never as zero.
