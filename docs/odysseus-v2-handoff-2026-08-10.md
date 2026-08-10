# Odysseus scripted chat v2 — handoff, 2026-08-10

Source document: "Odysseus Conversation Script v2" (PDF, supplied 2026-08-10).
It replaced v1 ("Odysseus - Scripted Opening + Lazy-User Quick Replies v1",
2026-08-08) outright, at the author's instruction. v1 is gone from the code, not
kept behind a flag.

Everything below is uncommitted on `main` at the time of writing.

## What changed

`lib/src/features/chat/presentation/chat_screen.dart`

- `_odysseusOpeningScript` — 12 turns (ODY2_P01..P12), 51 bubbles, replacing
  v1's 14 turns. Every turn now ends on a question to the visitor; v1 asked
  three questions in total. That is the whole point of the revision.
- `_odysseusQuickReplies` — the document's 12 answer-shaped sets, **plus four
  I wrote (13–16)**. See "Why sets 13–16 exist" below; they are not from the
  document and should not be deleted as if they were padding.
- Pacing is now per-character. `_ScriptPacing` + `_briskScriptCharacters`.
  Odysseus runs on `_briskPacing`; Calypso is untouched on `_readablePacing`.
- `initState` no longer calls `ref.read(authProvider.notifier).refresh()`
  directly — it moved into the post-frame callback below it. Pre-existing bug,
  unrelated to v2, found by the tests. Riverpod asserts against modifying a
  provider during a widget life-cycle, so every debug run logged an error and
  no widget test could mount this screen. Release builds never saw it.

`test/odysseus_script_v2_test.dart` — new, 6 tests, all passing.

`backend/src/starters.generated.js` — regenerated (`npm run gen:starters`).
**Read the analytics section before deploying this.**

## Why sets 13–16 exist

`_setQuickReplyIndex` falls back to sets that pass `_setStandsAlone` (every
entry ends in `?`) when a visitor interrupts the script, because the unplayed
turns' replies would otherwise answer lines the character never said.

v1's replies were questions, so that worked. v2's are *answers* — "Knowing when
to let go.", "I like to improvise." — and an answer never stands alone. With
only the document's twelve sets the fallback pool is empty, `_setQuickReplyIndex`
returns early, and **the strip freezes on whatever set was showing when she
spoke**. v2's own shape breaks a recovery path v1 did not need.

Sets 13–16 are cold-safe questions drawn from the document's §6 topic bank. They
also fix v1 parking on its last set forever once the script ran out.

Verified: interrupted cycles 14→15→16→13…, finished walks 13→16 and parks.

## Analytics — this one needs a decision

Regenerating `starters.generated.js` **deleted every v1 Odysseus tap line**.
"Are you really that Odysseus?", "Tell me about the Cyclops.", "Ask me another
captain's question." — all gone. Zero occurrences remain.

That file is how the worker tells a tapped starter from a typed message.
Consequences:

- Every historical Odysseus session that tapped a v1 reply now classifies as
  **"starter (unmatched)"** — the label `tool/gen_starters.mjs` documents as the
  alarm for the file being stale. It will fire loudly and it will be a false
  alarm.
- `CHARACTER_QUICK_REPLY_SETS.odysseus` went from 14 sets to 16, with entirely
  different content. Set number is how "how far into the script did they get" is
  measured, so **Odysseus depth metrics are not comparable across the
  cut-over**. Calypso is unaffected.

`gen_starters.mjs` reads current source only, so it has no way to retain retired
text. If historical matching matters, that script needs an archive of retired
sets. That is a change to someone else's file and I have not made it.

## Deploy state — do not deploy as-is

`tool/preflight_deploy.sh` guard 2 (dirty tree) would refuse, correctly.
`npm run deploy` builds from the working tree, not HEAD.

At the time of writing the tree also holds, from other sessions:

- `backend/src/worker.js` — ~1343 insertions. Two sessions' work in one file:
  sortable admin tables (`sortableTableJs`, `makeSortable`, `renderTimeline`)
  and real-vs-synthetic user filtering (`REAL_USER_ID`, `isRealUserId`, the new
  `x-synthetic-test` CORS header).
- `docs/ANALYTICS_HANDOFF.md`, `dev/deleted_synthetic_rows_2026-08-10.json`.

The only chat-path change in that diff is the one CORS header. Nothing touches
personas, signing, or the upstream call.

## Verified / not verified

Verified — 6 widget tests driving the real `ChatScreen`, plus a local preview
run (`npm run preview:local`):

- 51 bubbles, correct order
- first question at **6.2s** (the document requires 5–8s)
- set 1 tappable before the opening turn finishes; strip advances at each pause
- a tap stops the script and falls back to a cold-safe set
- no replay into a chat that already has history

Measured cadence, virtual clock, from the running widget:

    P01 6.2s   P02 15.4s  P03 26.8s  P04 38.0s
    P05 50.3s  P06 61.1s  P07 71.7s  P08 82.0s
    P09 93.3s  P10 104.0s P11 114.1s P12 125.0s

Not verified — anything past the AI handoff. The worker is unreachable in tests
and the local preview has no upstream keys, so §5 of the document (acknowledge a
specific thing she said, then one follow-up) has never been exercised. That is
the real reason to want a production check, and the only one.

## Known gaps, deliberate

- **The document's 5–8s repeat cadence is not met and cannot be.** Later
  questions land 9.2–12.4s apart. 3s of each gap is the document's own
  `pause_after_seconds` and the rest is a 4–5 bubble turn; hitting 5–8s end to
  end means ~1s per bubble, which is the flat interval the pacing scheme exists
  to replace. Closing it means **fewer bubbles per turn** — a copy decision, not
  a pacing one. Written up in the `_briskPacing` doc comment.
- **The strip shows 2 rows, not 3, below 720 logical pixels**
  (`_shortScreenHeight`). So a keyboard-up phone hides the third quick reply,
  exactly when v2's one-tap-answer bet matters most. Not changed; flagging it.
- **ODY2_P10's "she"/"her" is deliberate** and confirmed as such by the author.
  It reads as an assertion about the visitor because the next bubble points it
  at her. Do not neutralise it to "they" without asking. There is a comment on
  the segment saying so.
