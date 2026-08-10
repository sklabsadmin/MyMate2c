# Analytics handoff — reading the Mythos Live logs

Written 2026-07-31 for a session whose job is to **evaluate the data**, not change
the app. Everything below is about what the numbers mean and where they lie.

The single most important thing: **this data changes meaning depending on when it
was recorded.** Instrumentation landed in stages over four days, and two bugs
corrupted parts of it. Any query that spans 2026-07-28 to 2026-08-01 without a
date filter will mix incompatible data and produce a confident wrong answer.

---

## 1. Where the data lives

Cloudflare D1 database `mymate2_db` (binding `CHAT_LOGS_DB`), on worker
`mymate-v2`. Four tables matter:

| Table | One row per | Key columns |
|---|---|---|
| `conversation_logs` | chat message | `user_id`, `chat_id`, `visit_id`, `latency_ms`, `status`, `total_tokens`, `created_at` |
| `site_visits` | funnel event | `visit_id`, `event`, `source`, `path`, `duration_ms`, `detail`, `viewport_w`, `failure_reason` |
| `referral_visits` | `/c/<char>` arrival | `character_id`, `source`, `utm_*`, `known_character` |
| `user_profiles` / `linked_accounts` | signed-in user | identity only, no behaviour |

`site_visits.event` is one of: `arrive`, `app_ready`, `character_tap`,
`first_message`, `login_gate`, `send_failed`, `leave`.

Rough scale as of 2026-07-31: `conversation_logs` ~153 rows, `site_visits` ~674
rows. **This is a small dataset.** Most differences will not be statistically
meaningful; look for large effects and structural facts, not 5% deltas.

---

## 2. Getting the data out

Three routes, in order of usefulness for analysis:

**a) Query D1 directly** — best for analysis. Requires Cloudflare auth as the
`sklabs` account (not the personal one).

```bash
npx wrangler d1 execute mymate2_db --remote --command "SELECT ..."
npx wrangler d1 execute mymate2_db --remote --file query.sql
```

Returns JSON. `--local` hits a local dev copy instead, which is **not** the same
data.

**b) Admin JSON endpoints** — behind HTTP Basic Auth (any username, password =
the `ADMIN_TOKEN` secret):

- `GET /api/admin/visits?days=N` — funnel, by-source, by-day, recent arrivals
- `GET /api/admin/logs?limit=&offset=&user_id=&chat_id=&status=`
- `GET /api/admin/logs/:id` — single record with full payloads
- `GET /api/admin/conversations`, `/api/admin/transcript?user_id=&chat_id=`
- `GET /api/admin/referrals?days=N`
- `GET /api/admin/export?...` — **plain text**, `Content-Disposition: attachment`,
  filename `mymate-chat-logs-YYYY-MM-DD.txt`. Human-readable transcripts, not
  structured data. Fine for reading conversations, poor for aggregation.

Reachable on all four origins: `chat.deeplovepoems.com`,
`chat.deeploveechoes.com`, `logs.deeplovepoems.com`,
`mymate-v2.sklabs-admin.workers.dev`.

**c) Hand the next session a file.** Yes — this works and is often easiest.
Save any of the JSON endpoints to a file and point the session at it, or dump
tables to JSON/CSV via `wrangler d1 execute` and share those. A file avoids
needing Cloudflare credentials in that session at all. Prefer the JSON
endpoints or raw D1 output over `/api/admin/export`, which is prose.

**Note:** `conversation_logs` contains full user and assistant message text.
Treat exports as sensitive.

---

## 3. Timeline — when each signal became real

Times are **UTC**, and are *deploy* times where known (commit time is earlier
and irrelevant to the data). Use these as query boundaries.

| When (UTC) | What changed | Effect on data |
|---|---|---|
| 2026-07-28 16:55 | `site_visits` created; splash beacon added | `arrive` / `app_ready` / `leave` start. Nothing before this exists. |
| 2026-07-29 ~10:54 | In-app funnel instrumented | `character_tap` / `first_message` / `login_gate` start. **Before this they are absent, not zero.** |
| 2026-07-30 13:44 | Junk-link fix + `ig` normalisation + synthetic-test gate | `/c/favicon.png` etc. stop being logged as characters; UA-detected Instagram switches from source `instagram` to `ig`. |
| 2026-07-30 17:02 | `visit_id` on chat logs, `latency_ms`, `viewport_w`, `send_failed`; **visit-id bug fixed** | New columns start populating. Dwell/visit counts become trustworthy. |
| 2026-07-31 07:42 | Splash 3s dwell removed; **no splash at all on `/c/` links** | Expect bounce-under-3s to change. This is the big before/after. |
| 2026-07-31 09:50 | New dark splash logo as WebP (886KB → 78KB at 3x) | Load times on `/` should improve. |
| 2026-08-10 | Real-user-id guard on writes + 57 junk rows deleted (see 4.5) | `conversation_logs` stops accepting invented ids; `site_visits.app_user_id` stops storing them. 2026-08-03..05 message counts drop sharply — that is the fake traffic leaving, not real usage falling. |

---

## 4. Known data quality problems

### 4.1 The visit-id collision (fixed 2026-07-30 17:02) — worst one

Before the fix, `visit_id` was read from `sessionStorage`, which survives a page
reload. A reload therefore **reused the same id** and wrote a second `arrive`
and `leave` under it. The admin `bySource` query joins arrive→leave, so
duplicates multiply: 2 arrives × 2 leaves = 4 rows for one visitor.

Consequences for data **before 2026-07-30 17:02**:

- `visits` counts inflated. Observed: `direct` 26 vs 18 true (+44%),
  `instagram` 6 vs 3 (+100%), `ig` 134 vs 127 (+6%).
- `avg dwell`, `avg load`, `left under 3s` all computed over multiplied rows.
- One row shows a **3.9-hour dwell**; another 9.25 hours — tabs left open.

**Mitigation:** use `COUNT(DISTINCT visit_id)`, never `COUNT(*)`, and prefer
aggregate subqueries over chained `LEFT JOIN`s. The funnel table in the admin UI
already uses `COUNT(DISTINCT …)` and is *not* affected; the "By source" table is.

### 4.2 Dwell time is unreliable in both directions

`duration_ms` on `leave` is client-measured, sent via `sendBeacon` on `pagehide`
/ `visibilitychange`. Three separate biases:

- **Survivorship (skews high):** `AVG` ignores NULLs, so it only averages visits
  that successfully reported a leave. Visits killed hard (browser closed, network
  gone) never report. The query computes `with_duration` for this reason but the
  admin UI never displays it — the denominator is invisible.
- **First-hide latch (skews low):** the leave handler is once-only. A visitor who
  tab-switches at 5s and returns for three minutes is recorded as 5s.
- **Small-n and admin contamination:** one 385.9s session on `/chat/logs` was
  most of `direct`'s total dwell.

Treat dwell as directional only. "Social bounces in single-digit seconds, direct
dwells much longer" is real. "42.9s" is not a fact about users.

Same flaw hits `left under 3s`: a visit with no `leave` row has NULL
`duration_ms`, and `NULL < 3000` is not true, so it is silently excluded.

### 4.3 `character_tap` was blind to campaign links until 2026-07-30 13:44

It only fired from the dashboard card tap. `/c/<id>` links open the chat screen
directly and never touch a card, so **"opened a character" read 0% for campaign
traffic regardless of how well it converted.** Do not interpret pre-fix zeros as
drop-off. After the fix it fires on any chat open — including roleplay, custom
characters, and reopening a recent chat — so it is a slightly broader definition
than before.

### 4.4 The 20-reply gate means messages 2–19 were dark

`login_gate` does not fire until `AppConfig.freeRepliesPerCharacter` = **20**.
Combined with `first_message` being one-shot, the funnel jumps from message 1 to
message 20 with nothing in between. To analyse "how far into a conversation do
people get", **do not use funnel events** — join `conversation_logs` on
`visit_id` and count rows per visit. That works only after 2026-07-30 17:02.

### 4.5 Synthetic test traffic

109 rows of Claude/manual test traffic were **deleted** from `conversation_logs`
on 2026-07-31 (`diag_*`, `qa-*`, `sig*`, `deploycheck`, `h2`, `hosttest`,
`opencheck`, `wakeup-check`, `persona-test`, `user_test_smoke_1`).

**Still present and intentionally kept:** `user_test_calypso_s1/s2/s3` — 105 rows
from a manual QA pass on the Calypso persona, 2026-07-30 11:42–11:51 UTC. These
are **not real users** and will dominate any unfiltered analysis. Exclude with
`user_id NOT LIKE 'user_test_%'`.

Real user ids look like `user_<13-digit-epoch-ms>` (anonymous, client-generated)
or `google:<sub>` (signed in), plus `instagram:<id>` since Instagram login
landed. Anything else is test traffic.

**The `X-Synthetic-Test: 1` header did not hold on its own.** It shipped
2026-07-30 and works — every logging path checks it — but it is opt-in, and only
`tool/smoke_test.sh` ever sent it. Ad-hoc verification (curl by hand, a browser
console, an agent checking a deploy) invented a user id and skipped the header,
so **57 more junk rows arrived after the gate existed**, across 2026-08-03..05:

| Date | Ids |
|---|---|
| 2026-08-03 | `check_*` (11 characters), `fin_*`, `fin2_1`, `fin3_1`, `fin4_*`, `oedbug`, `oedbug1`–`oedbug5`, `h1`, `browsertest` — 27 rows |
| 2026-08-04 | `livecheck` |
| 2026-08-05 | `migration-check` (12), `synthetic-diagnostic` (10), `postmigration` (4), `healthcheck` (2) |

They dominate the raw counts: 2026-08-03 reads as 33 messages from 33 "users"
when only 6 of those ids were real people.

Since 2026-08-10 the id shape decides, not the header. `writeConversationLogRow`
drops any row whose `user_id` is not one of the three shapes above, and
`recordSiteVisit` stores `NULL` for an unrecognised `app_user_id` (the visit row
itself is kept — a funnel event with no user attached is still true). Both log
`{"event":"chat_log_skipped","reason":"unrecognised_user_id"}` to `wrangler
tail`, so a dropped row is visible rather than silent.

Send `X-Synthetic-Test: 1` anyway when testing — it skips the write before it is
attempted, and it also covers `site_visits` and `referral_visits`, which the id
guard cannot (they have no user id of their own). It is now in the CORS
allow-list too, so a browser-driven test can actually send it; before, preflight
rejected it, which is how `browsertest` ended up in the table.

**Those 57 rows were deleted on 2026-08-10**, backed up first to
`dev/deleted_synthetic_rows_2026-08-10.json` (all 20 columns, restorable). The
table went 251 → 194 rows, and 2026-08-03 now reads 6 messages from 6 users
instead of 33 from 33.

**The 105 `user_test_*` rows are still there** — kept deliberately, see above.
Exclude them (and anything else that ever slips in) with:

```sql
WHERE user_id GLOB 'user_[0-9]*' AND length(user_id) = 18
   OR user_id LIKE 'google:%' OR user_id LIKE 'instagram:%'
```

The sessions page applies this by default as of 2026-08-10, and its summary
line says how many rows the filter removed. Tick **include test ids** to put
them back. Two places still count them, because they were out of scope rather
than deliberate: the campaign-conversion subquery on the referrals page
(`COUNT(DISTINCT l.chat_id)` against `conversation_logs`) and the chat-log
export endpoint.

### 4.6 Source attribution is fragmented

- `ig` and `instagram` were separate buckets for the same platform. Fixed
  forward on 2026-07-30 13:44; **~6 historical rows still say `instagram`** and
  were never merged.
- 69 of 75 campaign-link arrivals recorded source `direct` because bio links
  carried no `utm_source` and Instagram strips the referrer. Tagged links were
  discussed; the profile link may or may not carry `?utm_source=ig` now — check
  before trusting source splits on recent data.
- `referral_visits` still contains historical junk `character_id`s from before
  the fix: `favicon.png` (4), `icons` (1), `hector%0ahttps:` (2), `zeuss` (1),
  `flutter_bootstrap.js` (1), NULL (2). Code no longer creates these; the old
  rows were never purged.

### 4.7 New columns are NULL before 2026-07-30 17:02

`conversation_logs.visit_id`, `conversation_logs.latency_ms`,
`site_visits.viewport_w`, `site_visits.failure_reason` cannot be backfilled.
Any analysis using them starts at that timestamp.

`latency_ms` measures the AI call only — not network time to the user's device.

---

## 5. What was already found (don't re-derive)

From the 7-day window ending 2026-07-30, with all the caveats above:

- **~51% of Instagram visits left in under 3 seconds** (68 of 134). fb similar
  at 48%. `direct` only 15%.
- **It is not a performance problem.** Avg load 1.3–1.8s and fb had *zero*
  give-ups. People saw a working app and left.
- **A 3-second splash dwell was in force during all of that.** `app_ready`
  averaged ~1.5s, so first-time visitors stared at a logo for ~1.5s *after* the
  app was usable, and anyone leaving before 3s saw **only the logo**. This may
  explain much of the bounce. Removed 2026-07-31 07:42 — **the before/after on
  bounce-under-3s is the single highest-value question in this dataset.**
- Campaign links: 75 arrivals → 17 conversations (~23%). **Penelope is the
  outlier: 19 arrivals → 2 conversations (11%)**, highest traffic, worst rate.
  Cupid 3→3, Oedipus 2→2 (tiny samples). Surfer/badboy/poet 0.
- **13% of campaign arrivals (10 of 75) hit broken links** — now fixed forward.
- Real usage is tiny: roughly 15 distinct genuine user ids, 48 real messages,
  over 5 days.
- One real user (`user_1785245420879`) got errors on **Odysseus and Cupid**,
  0 tokens both. Cupid is a plain OpenAI character, so this is not just a
  missing Inworld key. Worth chasing.

---

## 6. Ready-made queries

`scratchpad/funnel_queries.sql` (may not persist — regenerate if missing) covers:
dwell-bucket distribution for `/c/` arrivals, per-character arrival→message
conversion, the junk-link inventory, tracing bad links to their referrer, the
post-instrumentation funnel, and source-attribution sanity.

The query that only became possible on 2026-07-30 17:02 — per-session behaviour:

```sql
SELECT a.visit_id,
       a.source,
       a.viewport_w,
       (SELECT COUNT(*) FROM conversation_logs c
         WHERE c.visit_id = a.visit_id) AS msgs,
       (SELECT CAST(AVG(c.latency_ms) AS INTEGER) FROM conversation_logs c
         WHERE c.visit_id = a.visit_id) AS avg_reply_ms,
       (SELECT COUNT(*) FROM site_visits f
         WHERE f.visit_id = a.visit_id AND f.event = 'send_failed') AS failed,
       (SELECT MAX(l.duration_ms) FROM site_visits l
         WHERE l.visit_id = a.visit_id AND l.event = 'leave') AS dwell_ms
FROM site_visits a
WHERE a.event = 'arrive'
  AND a.created_at >= '2026-07-30 17:02:00'
GROUP BY a.visit_id;
```

Aggregate subqueries, not joins — deliberately, so duplicate rows cannot
multiply (see 4.1).

---

## 7. Questions worth asking of this data

Ranked by value, given the caveats:

1. **Did removing the 3s splash dwell reduce bounce-under-3s?** Compare `/`
   arrivals before/after 2026-07-31 07:42. Needs several days of traffic.
2. **Where in messages 1→5 do people stop?** `conversation_logs` grouped by
   `visit_id`, post-2026-07-30 17:02.
3. **Does reply latency predict abandonment?** Correlate `latency_ms` against
   whether the session sent another message.
4. **Left waiting vs left after reading** — compare `leave` timestamp against
   `created_at + latency_ms` of the last message.
5. **Why is Penelope converting at 11%** when Zeus manages 33%?
6. **Do wide viewports bounce harder?** `viewport_w` on arrival — the app is a
   portrait phone layout that stretches on desktop.
7. **How many sends fail invisibly?** `send_failed` rows with
   `failure_reason = 'network'` never reach the worker and have no
   `conversation_logs` row at all.

---

## 8. Traps that will produce wrong answers

- Querying across the whole date range without windowing on §3.
- `COUNT(*)` on `site_visits` joins instead of `COUNT(DISTINCT visit_id)`.
- Reading pre-2026-07-30 `character_tap` zeros as drop-off.
- Including `user_test_calypso_*` (105 rows) as real users.
- Treating `avg dwell` as a fact rather than a direction.
- Assuming `login_gate` marks message 5 — it is message **20**.
- Comparing `ig` against `instagram` as if they were different sources.
- Reading `/api/admin/export` output as structured data; it is prose.
