# Delivery logging — second-opinion notes from the Mac run, 2026-08-14

An independent macOS calibration run, plus a follow-up attempt at the one open
anomaly. Local `npm run preview:local`, real OpenAI key, nothing deployed, no
product code changed.

The Windows session had already met the calibration goal, so this is a delta.
Its value is what a second machine saw differently — and, in the follow-up, a
likely explanation for the seq 16-22 anomaly that does not require a bug.

> **Correction, 2026-08-19.** That last clause was wrong in a way that pointed
> away from a real defect, and §1 and §3 below should be read against
> `docs/delivery-seq0-hole-2026-08-17.md`.
>
> §1 says a missing render stamp "self-heals on the next flush". That is only
> true while the receipt stays `dirty`. The seq 0 hole is exactly the case where
> it does not: an ack was applied to receipts as they stood when the response
> came back rather than as they were posted, so a stamp landing mid-flight was
> marked delivered without ever being sent — and then never sent again. A
> sighting in that window was worse, because `seenAt` makes a receipt
> discardable and the ack deleted the record outright. Production showed seq 0
> intended 291 against rendered 11.
>
> So "rendered lags the client and catches up" describes the healthy case only.
> The unhealthy one has the same appearance and never catches up, and nothing in
> §1 distinguishes them. Offering flush latency as the benign reading of seq
> 16-22 was too confident on one machine's evidence.
>
> §3 is the concrete miss. The single `never_rendered` row there is a lone
> `seq 0`, which I attributed to abandonment. That is the signature of this bug,
> in the position it most often strikes — the opening's first bubble is drawn
> ~742ms after intent is declared, inside the window of the session's first
> flush. One row on one machine was not evidence of anything on its own, but it
> was the same shape, and calling it abandonment closed the question early.
>
> The lesson is the one this document argues for elsewhere and did not apply to
> itself: a benign explanation for a "recorded, then nothing" row needs the same
> scrutiny as an alarming one, because both explain the observation equally well
> and only one of them is safe to be wrong about.

## 1. The seq 16-22 anomaly did not reproduce — and here is what it looks like

Ran the documented repro lead in full on a fresh session: 49-bubble Odysseus
opening, left mid-script via the in-app back arrow at seq 41, returned through
the dashboard card, tapped a quick reply at the pause (a real send —
`POST /api/chat 200`).

**Result: 54 rows, `never_rendered` 0, declared == rendered.** No cluster, no
gap.

But the run reproduced the *appearance* transiently, and that is the useful
part. At the moment of navigating away the server showed 42 of 49 rendered —
seq 42-48 sitting as intent with nothing after. Those bubbles had already been
drawn on screen; their receipts had not flushed yet. The dispose-time flush
delivered them and the count went to 50/50 with no gap at all.

So **the server's `rendered` lags the client's actual rendering by up to a
flush**, and leaving the screen is simultaneously the moment that gap is widest
and the moment an observer is most likely to look. A read taken during or just
after an interactive session shows bubbles that were visibly on screen with
`rendered_at` NULL — precisely the documented signature — and it self-heals on
the next flush.

**It self-heals only while the receipt stays `dirty`.** See the correction at
the top: the seq 0 hole is the same appearance with the opposite ending, where
an ack clears `dirty` for a stamp that was never sent and the row stays empty
for good. Everything below describes the healthy case; it does not rule out the
other one.

**Worth checking whether the seq 16-22 read was taken before that session's
final flush landed.** If it was, this is instrument latency rather than a
defect, and the anomaly can come off the open list.

Caveat: one machine, one sequence. The interactive session was 5 bubbles of
user/reply traffic on top of a 49-bubble opening, not a long conversation.

## 2. The fidelity closure — resolved by inspection, not by sampling

Item 1 was marked verified on `checkable: 4, verified: 4, unexplained: 0`. On
this machine's rows that comparison was nearly `text == text`: across both raw
replies, `*` appeared 0 times, `"` 0 times, `'` once, in 1,556 characters.

That turns out not to matter, because the question can be answered directly
rather than by sampling. The two sides strip equivalent sets:

| side | strips |
|---|---|
| `OpenAIService.sendMessage` ([openai_service.dart:185-188](../lib/src/features/chat/services/openai_service.dart)) | `**`, `"`, `'`, `*` |
| `STRIPPED_ASSISTANT_SQL` (`worker.js`) | `*`, `"`, `'` |

The client's `**`-then-`*` pair is covered by the SQL's global `*` replace.
**They are in sync today**, which is stronger evidence than any single live
sample. The remaining exposure is only future drift, and that is what the live
check would guard.

**A practical note on that guard: it is unlikely to ever fire.** The model
emits *typographic* quotes, not ASCII ones — a forced-quotation reply came back
with `“Nobody, eh?` and `What’s` (U+201C / U+2019), which **neither** side
strips. They pass through both sides identically, so fidelity still verifies,
but it means the `"` and `'` rules are close to dead code in practice and `*`
is the only realistic exerciser.

A deliberately asterisk-heavy reply was generated for that purpose
(`*leans forward, eyes glinting with mischief*`, 6 asterisks, log `2fa27385`)
but its delivery rows never landed — see §5. That sample is still worth taking.

**Method note, because it is easy to get wrong.** Count these in
`conversation_logs.assistant_message`. `message_delivery.text` is the client's
*already-stripped* text, so a zero there cannot distinguish "the reply had none"
from "stripping worked". `response_json` is the wrong column too. My first pass
made exactly this mistake.

```sql
SELECT substr(id,1,8) AS log_id,
       length(assistant_message)-length(replace(assistant_message,'*',''))  AS n_star,
       length(assistant_message)-length(replace(assistant_message,'"',''))  AS n_dq,
       length(assistant_message)-length(replace(assistant_message,'''','')) AS n_apos
FROM conversation_logs
WHERE id IN (SELECT DISTINCT conversation_log_id FROM message_delivery
             WHERE origin='ai_reply' AND conversation_log_id IS NOT NULL);
```

## 3. `never_rendered` across this machine's sessions

| visit_id | rows | user | ai_reply | never_rendered |
|---|---|---|---|---|
| `msskw4tmls88nyl8` | 11 | 3 | 4 | 0 — interactive: taps, typing, send clicks |
| `mssktd1z7qbr5ski` | 51 | 1 | 0 | 1 — hands-off, torn down mid-script |
| `msslgzcidz1n14ma` | 50 | 0 | 0 | 0 — hands-off, dead-port run |
| repro session (§1) | 54 | 1 | 1 | 0 — back-nav, re-entry, quick-reply tap |

The single `never_rendered` is a lone `seq 0` welcome bubble in a hands-off
session whose tab was closed mid-script — abandonment, not a cluster.

**Probably wrong.** `docs/delivery-seq0-hole-2026-08-17.md` found a real bug
whose signature is precisely a missing `seq 0`, and the opening's first bubble
sits inside the window of the session's first flush. Abandonment was a
plausible reading of one row; it was not the only one, and it was the reading
that required no further work.

## 4. Synthetic clicks work here; `initialMessage` is a race

The handoff says scripting the repro "is impossible without real clicks" and
the Windows notes that the canvas eats synthetic clicks. On macOS through the
in-app browser's CDP input it does not: every send in these runs came from
clicking the message box, typing, and clicking send, and §1 was driven entirely
that way. What fails here is **scrolling** — it times out against the canvas.
The constraint is inverted, not absent.

`?initialMessage=` is the opposite story. It is reliable on Windows and failed
twice here. `initState`
([chat_screen.dart:313](../lib/src/features/chat/presentation/chat_screen.dart))
calls `_loadHistory()` without awaiting, and that is the only place `_aiService`
is assigned (~:648/:655, behind two storage awaits); the opener fires from the
post-frame callback at ~:326 and hits `if (_aiService == null) return;` at
~:2465, *after* the user bubble is recorded at ~:2427 and `_isTyping = true` at
~:2437. Cold load: bubble drawn and logged, no `POST /api/chat`, typing
indicator spinning forever. It resolves per machine and per load, so it is
latent for real visitors on the "Ask Me About" route, not merely a harness
quirk.

Fixed in `9abe29f` — but that was cherry-picked onto `main`, so **this branch
still carries the race**. Do not rely on `?initialMessage=` for scripted runs
here until it is merged.

Note it also produced the signature this table exists to detect — intent
recorded, nothing after — and the instrument was right while the app was wrong.

## 5. Why the asterisk sample is missing

Two Claude sessions shared one working copy. Mid-run, the session fixing §4
checked out `main`, cherry-picked its fix and bumped the version; wrangler
reloaded onto `main`'s `worker.js`, which has no `/api/delivery` routes. Every
receipt after 15:58 got a 405, so the asterisk reply reached
`conversation_logs` but never reached `message_delivery`.

Everything in §1 and §3 was written before the switch and is unaffected.
Worth knowing generally: **a concurrent session can change the branch under a
running experiment**, and the symptom is an endpoint that suddenly 405s rather
than anything that looks like a test failure.

## 6. `seen` tracks focus, not visibility

The hidden-tab verification scored 50 rendered, 0 seen. This run recorded 15
sightings on a surface reporting `document.visibilityState === "hidden"` with
`document.hasFocus() === true`. Both hold if the Windows hidden tab was also
unfocused, but they separate the two conditions and only focus tracked `seen`
here. Over-counting `seen` is the opposite failure mode from the one being
hunted, so a surface genuinely hidden *and* unfocused is still unverified.

## 7. Corroboration, and one residual

Bugs (d) and (e) were reached independently here before `76eb9cf` was pulled,
from a separate live outage — client built against a dead port, welcome script
running, then a worker brought up on that port:

- backoff bypassed by new activity: `flush_attempts: 38` over a ~176s outage,
  against the ~5 the 2/5/15/60/300s ladder implies (Windows measured 21 in two
  minutes)
- `queued_ms` measuring stamp latency: rows at 123s with `flush_attempts: 1` —
  hold-until-seen, never offline

Two machines, two independent runs, same two conclusions, neither from review.

**Residual:** rows written before `76eb9cf` carry old-semantics `queued_ms`. A
local D1 that survived the fix holds a mix, and the old rows inflate the
over-a-minute bucket. Clear local state rather than comparing across that
boundary.

## 8. Small trap

`backend/src/worker.js` contains a byte that makes `grep` treat it as binary —
it returns nothing and exits 1 on patterns that are plainly present. Use
`grep -a`. This briefly looked like the delivery endpoint was missing from the
branch entirely.

## Still open

1. The asterisk fidelity sample (§2) — the only realistic exerciser of the
   stripping, and the guard against future drift. Everything else about the
   pair is settled by inspection.
2. Whether the seq 16-22 read predated its session's final flush (§1). If it
   did, the anomaly is explained.
3. `seen` on a surface genuinely hidden *and* unfocused (§6).
4. `queue_dropped` / the 1000 cap. Still never reached by a real session.
5. Merging `9abe29f` into this branch (§4).
