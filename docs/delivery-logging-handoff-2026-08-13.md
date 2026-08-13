# Delivery logging — handoff, 2026-08-13

Branch `feat/mega-client-logging`, based on `main` at `bc353e0`. Everything below
is committed and pushed. Nothing is deployed.

## What this is for

`conversation_logs` records what the worker sent. Nothing recorded whether it
reached the screen, and the two had drifted apart: one reply is split into
several bubbles and paced out over seconds, the text is rewritten before it is
drawn, and most of what the character says early on is composed on the device
and never passes through the worker at all.

The suspicion driving it is regional delivery failure — that some visitors are
shown far less than we think, which would explain engagement the funnel says
should be higher. That needs the *negative* case, and the negative case is the
hard part: when delivery breaks the server hears nothing, so a broken region and
a quiet one look identical. Hence intent recorded before the draw, receipts held
on the device, and a flush on the next connection that works.

Three moments per bubble. `intended` → `rendered` → `seen`. Intent with no render
is a delivery failure. Render with no sighting is a bubble drawn into a hidden
tab or below the fold — delivered and unread, which is a pacing question, not a
network one.

## State

| | |
|---|---|
| Flutter tests | 21 pass |
| Backend tests | 48 pass |
| Analyzer errors | 0 |
| Deployed | no |
| Migration applied to remote D1 | **no — must happen before the worker deploys** |

## What exists

- `backend/migrations/0011_message_delivery.sql` — new table, 5 indexes.
  **Purely additive**: no ALTER, no DROP, nothing existing is touched. Safe to
  leave unapplied (the endpoint 503s and the client keeps queueing), and
  `DROP TABLE message_delivery` is a complete rollback.
- `POST /api/delivery` in `backend/src/worker.js` — batched receipts, idempotent
  per bubble (COALESCE on each timestamp), acked so the client knows what to
  discard. Awaits its write rather than using `ctx.waitUntil`, because acking a
  failed write would destroy the evidence permanently.
- `log_id` added to the `/api/chat` response, so a receipt can name the reply it
  was cut from. Added to the outgoing copy only; `response_json` still records
  exactly what the provider returned.
- `lib/src/core/services/delivery_log.dart` — the durable queue.
- `lib/src/core/presentation/seen_detector.dart` — decides "seen".
- `chat_screen.dart` — `_addMessage` now requires an `origin`, so a new way for
  the character to speak cannot go unlogged by omission.
- `/admin/delivery` + `/api/admin/delivery` — the read surface.
- `docs/mobile-delivery-logging.md` — what a mobile release would have to add.

## Verified, and not

Verified live against a local `wrangler dev --local` with the Odysseus opening:

- intent declared for the whole script before pacing starts (51/51)
- `rendered` stamps (51/51)
- flush, sign, ack; queue drains to empty; `queued_ms` ~240ms against the 250ms
  debounce, so bubbles coalesce into one request rather than 51
- `connection_type` via `dart:js_interop`, `visit_id`, `country`, `chat_id`
- turn grouping — a 51-bubble opening is one row in `cut_short`, not 51

**Not verified, in priority order:**

1. **The `ai_reply` path has never run.** Everything tested live was
   `welcome_script` and `idle_nudge`. So `origin: ai_reply`, the `log_id` join,
   `local_fallback`, and — most importantly — **the fidelity check** are
   untested against real data. `fidelity.checkable` was `0` in every run.
   This is the actual product; the rest is scaffolding around it.
2. **The offline/tombstone path.** Failed flush → queue survives → backoff
   retry → `queued_ms` records the outage. Only the happy path has been seen,
   and this mechanism is what the whole regional theory rests on. Testable by
   pointing the client at a dead port.
3. **`seen`, after the last two fixes.** Nine unit tests cover it, but the final
   live run reported `seen=0` because the browser pane was hidden — which is
   correct behaviour, not a regression. Needs one run with the pane visible.
4. `queue_dropped` / the queue cap. Never reached.

## Bugs already found and fixed — do not re-introduce

All four were silent, and all four produced *the same signature as the regional
fault this feature exists to detect*: rows with intent recorded and nothing
after. That is why this cannot be trusted without the calibration above.

1. **Acked receipts were deleted from the queue.** Intent for a whole reply is
   flushed within 250ms; the bubbles are not drawn for another ten seconds, so
   every render and sighting arrived to find its receipt gone. Receipts now stay
   until the bubble is *seen*, with a `dirty` flag so acknowledged ones are not
   resent on every flush.
2. **A dwell that elapsed mid-scroll gave up permanently.** Now re-arms.
3. **Scroll checks read stale geometry.** Scroll listeners fire *before* the
   layout they cause, and a scroll relayouts without rebuilding — so a bubble
   arriving on screen was measured at its old off-screen position and never
   looked at again. Every check is now deferred past the frame.
4. **`addPostFrameCallback` does not request a frame.** Scrolling produces one
   anyway, but the app returning to the foreground dirties nothing, so checks
   for bubbles already on screen waited on an unrelated repaint. It now calls
   `scheduleFrame()`.

`test/seen_detector_test.dart` pins down 2–4, plus the cases that must *not*
report: below the fold, flicked past, hidden tab, and a message restored from
history (which has no receipt and must never be reported as freshly read).

## How to run it

```bash
npm run preview:local          # builds web, serves worker + D1 on :8788
```

Open `http://localhost:8788/c/odysseus` **with the browser visible** — a hidden
tab correctly reports nothing as seen, which looks like a bug and is not. Clear
site data first, or the chat restores from history and replays no script (a
restored message deliberately carries no receipt).

```bash
curl -s -u "admin:localdev" "http://localhost:8788/api/admin/delivery?days=7"
```

`ADMIN_TOKEN` is in `.dev.vars`.

## Traps

- **Local D1 is broken independently of this work.** `0009_exit_mode.sql` fails
  to apply with `duplicate column name: visible_ms` — the column exists but the
  bookkeeping does not record 0009 as applied, so 0009/0010/0011 are all wedged
  behind it. `wrangler d1 migrations apply --local` will not work until someone
  reconciles it. Workaround used here, which does not touch the bookkeeping:
  `npx wrangler d1 execute mymate2_db --local --file backend/migrations/0011_message_delivery.sql`
  This is a close cousin of what `bc353e0` fixed for `0008_visit_platform`.
- **Taps and typing time out on the Flutter web canvas in preview.** Verification
  is observation-only. This is why the `ai_reply` path is untested — triggering a
  reply needs typing. `ChatScreen.initialMessage` sends a message automatically
  "as though the user had typed it" (the profile card's "Ask Me About" route);
  reaching that may be the way in without a keyboard.
- **Restarting the preview needs a tree kill.** Killing `workerd` alone just has
  wrangler respawn it; kill the parent `bash`/`cmd` running `wrangler dev` too.
- **Do not run `dart format`.** The repo is not format-clean and it adds ~150
  lines of churn to any diff.
- **Commit and push; do not deploy.** Adam deploys from a separate session.
- The `STRIPPED_ASSISTANT_SQL` constant in `worker.js` replays the client's own
  character stripping (`*`, `**`, both quote characters) so the fidelity check
  compares like with like. If that cleanup in `OpenAIService.sendMessage` ever
  changes, this must change with it or every row starts reading as a mismatch.

## Open questions for Adam

- **Is there a region hunch** — a country, carrier, language, character? Cheap to
  index for now, a migration later.
- **Pacing as the alternative explanation.** The opening runs to 51 lines with
  per-line delays and pauses waiting for a reply. In the live run the visitor saw
  3 of 51 before it parked. If people leave before the character finishes, that
  presents exactly as "not getting intended messages" but is entirely local. The
  `welcome_script` vs `ai_reply` split separates the two — and because both share
  the identical render/seen code path but different delivery paths, comparing
  them cancels out any residual bug in the instrument.
