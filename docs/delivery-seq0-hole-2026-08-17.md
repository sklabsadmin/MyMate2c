# The seq 0 hole — an ack applied to a receipt that had moved on

The production read that opened this, 2026-08-17:

| seq | intended | rendered |
|---|---|---|
| 0 | 291 | 11 |
| 1 | 287 | 182 |
| 2 | 287 | 190 |
| 3 | 287 | 103 |
| 4 | 287 | 90 |

The first bubble cannot be drawn less often than the second one that follows
it, so this was never real behaviour. It is a client bug, and not the one the
brief suspected: the flat `welcomeBubbleIds` list and the nested segment/line
loops in `_playOpeningScript` walk the same lines in the same order, and the
receipt for the first bubble is recorded long before anything is drawn.

## The bug

`DeliveryLog.flush()`, in the ack handler.

An ack is a statement about the receipts **as they were posted**. The code
applied it to each receipt **as it stood when the answer came back**, and the
answer takes a round trip during which the app carries on drawing bubbles. A
stamp landing in that window was therefore marked delivered without ever having
been sent — and, because `dirty` is what decides whether a receipt is ever sent
again, it was then never sent. A *sighting* landing in that window was worse:
`seenAt` makes a receipt `canDiscard`, so the ack deleted the whole record.

The welcome script's first bubble hits that window nearly every time:

- every line of the opening is declared up front, so the intent for the whole
  script is one batch, flushed 250ms later;
- that flush is the session's first request — DNS, TLS, and a batch of forty-odd
  inserts;
- `seq 0` is drawn at `typingMs` after the declaration, which for Odysseus's
  nine-word opener under `_briskPacing` is **742ms**.

Nothing after seq 0 is close enough to a flush to be caught by it, which is why
the loss has the impossible shape it does. The smaller dip at seq 1 (182 against
seq 2's 190) is the same bug's tail: seq 1 is occasionally drawn while the flush
carrying seq 0's stamps is still out.

## The fix

`_Receipt.rev`, a counter bumped every time a receipt learns anything. `flush()`
snapshots it per bubble as the batch is serialised, and the ack only clears
`dirty` — or discards the receipt — where the value is unchanged. Where it has
moved, the receipt stays dirty and the existing `_hasDirty` check resends it
immediately.

Monotonic across the queue rather than per receipt, because `recordIntended`
replaces the receipt object outright and a per-receipt counter would restart at
the value the replaced one was sent under.

Two tests in `test/delivery_log_test.dart` ("the round trip"), both of which fail
against the old code: one for a render stamped mid-flight, one for a sighting.

## Confirmed against a local preview run

Local preview cannot reproduce this on its own — the loopback round trip is a
millisecond or two, so the window never opens. A proxy on :8790 forwarding to
`wrangler dev` on :8791 held `/api/delivery` for 800ms and logged what each
flush carried, as `seq` plus which of intended/rendered/seen it had.

Same build, same script, fix out and then in:

```
  without the fix                      with the fix
  16225 POST 0i-- 1i-- … 48i--         235219 POST 0i-- 1i-- … 48i--
  17048 ACK  49 ids                    236037 ACK  49 ids
  18219 POST 1ir-   <-- seq 0 gone     236217 POST 0ir-   <-- seq 0 lands
  20080 POST 2ir-                      237463 POST 1ir-
```

`message_delivery` afterwards: without the fix, `seq 0` alone has
`rendered_at NULL` and every later seq is stamped — the production shape
exactly. With the fix, the rendered bubbles are a contiguous prefix ending
wherever the session was cut short, which is what abandonment is supposed to
look like.

## Three things the fix exposed, dealt with in the same change

None of these produced the seq 0 hole. They are the neighbouring ground the fix
made visible, and the first two are the kind of thing that only bites once the
`rev` check exists.

**A stamp that changes nothing no longer dirties the receipt.** `_stamp` used to
set `dirty = true` unconditionally, and now bumps `rev` as well — so a repeated
`markRendered` would post, be acked under an older rev, post again, forever. It
is unreachable today (each bubble is added once, and `SeenDetector` reports once
behind its `_reported` guard), so this is a brake on a slope rather than a bug
being fixed. `markRendered`/`markSeen` now answer whether they learned anything
and `_stamp` returns early when they did not, which also removes a pointless
resend on the healthy path.

**The flush request that gets swallowed is genuinely covered.** A mid-flight
stamp asks for a flush, that request fires 250ms later while the first is still
out, and `flush()` drops it — `if (_flushing) return`, nothing rescheduled. What
saves it is the completing flush's own `if (_hasDirty) _scheduleRetry(immediate:
true)`. That was reasoning, not a guarantee, so it is now a test ("a bubble drawn
mid-flight is sent even though its own flush was swallowed") which calls nothing
after the flush completes and asserts a retry is armed.

**The catch block counted attempts against the wrong receipts.** It re-derived
the batch from the queue instead of using the one it had sent — the same set only
if nothing changed in between, and a request that throws is exactly when the app
has been drawing bubbles throughout. `batch` is now hoisted above the `try`.

## Left alone on purpose: `markRendered` fires before the frame

`_addMessage` stamps the render and then calls `setState`, so `rendered_at` means
"the app committed to drawing this", not "it was painted". The gap only shows for
a bubble added and torn down inside one frame, and closing it means moving the
stamp into a post-frame callback — which would shift every `rendered_at` in the
series, including the baseline 1.7.1 is about to be read against. The doc comment
now says what is actually measured. Worth revisiting once that baseline exists.

## The other discrepancy: 291 intended at seq 0, 287 everywhere else

Not a bug. There are two producers of `origin='welcome_script'` rows, and only
one of them is a script:

- `_playOpeningScript` — the whole opening declared at once, `seq 0..N-1`;
- the single-question opener every other character uses
  (`_triggerWelcomeSequence`, `openerBubbleIds`) — exactly **one** bubble, at
  `seq 0`, and nothing after it.

Only `odysseus` and `calypso` have scripts (`_openingScriptFor`). So each visit
to any other character adds one row at seq 0 and none at seq 1+. The intent rows
of a script are all-or-nothing — declared before the first line is drawn — which
is also why seq 1-4 are identical at 287.

Confirm with:

```sql
SELECT COUNT(*) AS lone_seq0_turns FROM (
  SELECT turn_id FROM message_delivery
  WHERE origin='welcome_script' GROUP BY turn_id HAVING MAX(seq) = 0);
```

Expect 4. **This matters for the 1.7.1 diagnostic**: seq 0 mixes two populations,
so "how far into the opening turn people get" must not use seq 0's intended
count as the denominator. Segment by character, or exclude lone-seq-0 turns.

## Consequence for existing data, and a prediction worth checking

Every `rendered_at` and `seen_at` collected before this fix is a lower bound,
not a measurement. seq 0 is unusable; later seqs are slightly under-counted.

The same mechanism should have hit **sightings across every origin**, not just
the welcome script, and harder: a bubble's render schedules a flush 250ms later,
and the standard `SeenDetector` dwell reports the sighting at render + 300ms — so
the sighting lands inside that flush's round trip whenever it exceeds 50ms, which
in production is always. The ack then deletes the receipt outright.

Prediction: `seen_at` is non-null far less often than it should be in the data
collected to date, and where it is non-null it belongs to bubbles seen well after
they were drawn (scrolled back to) or to sessions where a backoff shifted the
timing. Not verified here — the preview tab was unfocused throughout and
`seen` tracks focus (see the 2026-08-14 calibration notes, §6).

```sql
SELECT origin,
       COUNT(*) AS rows,
       SUM(rendered_at IS NOT NULL) AS rendered,
       SUM(seen_at IS NOT NULL)     AS seen
FROM message_delivery GROUP BY origin;
```

## Two traps in the local harness

Both cost a run here, and both produce a result that looks like a finding.

1. **`wrangler d1 execute --local` kills a running `wrangler dev --local`.**
   Same SQLite file; the dev server exits 143 mid-session. Clear or query the
   local D1 with the server stopped, never during a run.
2. **`build_web.sh` starts with `rm -rf build/web`.** Rebuilding under a running
   `wrangler dev` leaves it serving an asset manifest for files that no longer
   exist, and the app loads to a blank screen. Restart the server after a
   rebuild.

A third, less obvious one: clearing `localStorage` while the chat screen is
still mounted achieves nothing, because its dispose flush persists the queue
again on the way out. Navigate away first, then clear.
