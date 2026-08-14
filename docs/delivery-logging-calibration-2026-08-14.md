# Delivery logging — second-opinion notes from the Mac run, 2026-08-14

Written after pulling `f7b3745`, from an independent macOS calibration run made
on `aa7be94` before the pull (local `npm run preview:local`, real OpenAI key,
nothing deployed, no product code changed).

The Windows session had already met the calibration goal, so this is a delta,
not a second report. Its value is what a second machine saw differently: one
closure that rests on thinner evidence than it looks, one platform-dependent
race, and one blocked repro that is not blocked here.

## 1. The fidelity closure barely exercises the stripping

Item 1 is marked verified on `checkable: 4, verified: 4, unexplained: 0`. That
result is real, and the join it proves is real. But on this machine's four rows
the comparison was very close to `text == text`.

`STRIPPED_ASSISTANT_SQL` strips three characters from `c.assistant_message`:
`*`, `"`, `'`. Counting them in the raw replies behind this run's `ai_reply`
rows:

| log_id | raw len | `*` | `"` | `'` |
|---|---|---|---|---|
| `a3586af3` | 444 | 0 | 0 | **1** |
| `058ae173` | 1112 | 0 | 0 | 0 |

One apostrophe across 1,556 characters. `*` and `"` were never exercised at
all — and `*` is the markdown-emphasis case the strip exists for, the most
likely thing to drift if either side is edited.

**Method note, because it is easy to get wrong.** The check must count these in
`conversation_logs.assistant_message`. `message_delivery.text` is the client's
*already-stripped* text, so a zero there is equally consistent with "the raw
reply had none" and "stripping worked perfectly" — it cannot distinguish them.
`response_json` is the wrong column too. My first pass made exactly this
mistake and had to be redone.

**Worth running against the Windows four**, which are different rows from a
different run and may well cover it:

```sql
SELECT substr(id,1,8) AS log_id,
       length(assistant_message) AS len,
       length(assistant_message)-length(replace(assistant_message,'*',''))  AS n_star,
       length(assistant_message)-length(replace(assistant_message,'"',''))  AS n_dq,
       length(assistant_message)-length(replace(assistant_message,'''','')) AS n_apos
FROM conversation_logs
WHERE id IN (SELECT DISTINCT conversation_log_id FROM message_delivery
             WHERE origin='ai_reply' AND conversation_log_id IS NOT NULL);
```

If those come back non-zero for `*` or `"`, item 1 is genuinely closed and this
section can be deleted. If they are zero too, the honest reading is "the
fidelity check runs and joins correctly", and one reply containing emphasis or
dialogue still closes it properly.

## 2. `never_rendered` in an interactive run — asked and answered: no

Directly on the open anomaly. Per-visit, this machine's three sessions:

| visit_id | rows | user | ai_reply | never_rendered |
|---|---|---|---|---|
| `msskw4tmls88nyl8` | 11 | 3 | 4 | **0** — interactive: real taps, typing, send clicks |
| `mssktd1z7qbr5ski` | 51 | 1 | 0 | 1 — hands-off, torn down mid-script |
| `msslgzcidz1n14ma` | 50 | 0 | 0 | 0 — hands-off, dead-port run |

**The interactive session shows zero.** Declared equals rendered across all 11.

This is a weak negative, not a refutation. It is 11 bubbles, not 50; the
interaction was typing and send-clicks only, with no quick-reply tap at a script
pause and no in-app back-navigation — which is precisely the shape the Windows
repro lead names. The one `never_rendered` row here is a different animal: a
single `seq 0` welcome bubble in a hands-off session whose tab I closed
mid-script, not a seq 16-22 cluster.

## 3. The repro is scriptable on this machine

The handoff says scripting it "is impossible without real clicks" and the
Windows notes that "the Flutter canvas eats synthetic clicks". On macOS through
the in-app browser's CDP input, it does not: both `ai_reply` replies in this run
came from clicking the message box, typing, and clicking send. No
`initialMessage` involved.

What fails here is **scrolling** — every scroll attempt against the canvas timed
out, intermittently and in a way tied to whether the pane had been fronted.

So the constraint is inverted rather than absent, and the Windows repro lead —
tap a quick reply at a script pause, in-app back-navigation, re-entry, then diff
on-screen bubbles against stamps — is executable here. That is the obvious next
experiment, and this machine is currently the only one that can run it.

## 4. `initialMessage` is a race, and it lost on this machine

The Windows notes use `?initialMessage=` as the reliable zero-typing path. It is
not reliable — it failed twice here, and that is why this run fell back to
typing.

`initState` ([chat_screen.dart:313](../lib/src/features/chat/presentation/chat_screen.dart))
calls `_loadHistory()` without awaiting, and that is the only place `_aiService`
is assigned (~:648/:655, behind two storage awaits). The opener fires from the
post-frame callback at ~:326 and hits `if (_aiService == null) return;` at
~:2465 — *after* the user bubble is added at ~:2427 and `_isTyping = true` at
~:2437. Result on a cold load: bubble drawn and logged, no `POST /api/chat`,
typing indicator spinning forever. One run also fired it twice, producing two
identical user bubbles.

It works on Windows and fails on macOS because it is a race between the first
frame and two storage awaits, so it resolves per machine and per load. That
makes it latent for real users on the profile card's "Ask Me About" route, not
merely a test-harness quirk. A separate session is fixing it — worth not
depending on that path for scripted runs until it lands.

Note it also produced the signature this table exists to detect — intent
recorded, nothing after — and on inspection the instrument was right and the
app was wrong. That is a point in the instrument's favour, and it is the second
independent case of a real bug wearing the regional-fault costume.

## 5. `seen` tracks focus, not visibility

The hidden-tab verification scored 50 rendered, 0 seen. This run recorded 15
sightings on a surface reporting `document.visibilityState === "hidden"` with
`document.hasFocus() === true`.

Both can be true if the Windows hidden tab was also unfocused, but they
separate the two conditions and only focus tracked `seen` here. Since
over-counting `seen` is the opposite failure mode from the one being hunted, a
surface that is genuinely hidden *and* unfocused is still unverified.

## 6. Corroboration, and one residual

Bugs (d) and (e) were reached independently here before `76eb9cf` was pulled,
from a separate live outage — client built against a dead port, welcome script
running, then a worker brought up on that port:

- backoff bypassed by new activity: `flush_attempts: 38` over a ~176s outage,
  against the ~5 the 2/5/15/60/300s ladder implies (Windows measured 21 in two
  minutes)
- `queued_ms` measuring stamp latency: rows at 123s with `flush_attempts: 1` —
  hold-until-seen, never offline

Two machines, two independent runs, same two conclusions, neither from review.
That is the strongest available argument for the "watch the path work before
reading the number" rule.

**Residual:** rows written before `76eb9cf` carry old-semantics `queued_ms`. Any
local D1 that survived the fix holds a mix, and the old rows inflate the
over-a-minute bucket exactly as described. Clear local state rather than
comparing across that boundary.

## 7. Small trap

`backend/src/worker.js` contains a byte that makes `grep` treat it as binary —
it returns nothing and exits 1 on patterns that are plainly present. Use
`grep -a`. This briefly looked like the delivery endpoint was missing from the
branch entirely.

## Still open

1. The stripping replay (§1) — currently reads as closed; one query settles it.
2. The seq 16-22 render-stamp cluster — not reproduced here, but §3 means it can
   now be attempted.
3. `seen` on a surface genuinely hidden *and* unfocused (§5).
4. `queue_dropped` / the 1000 cap. Still never reached by a real session.
