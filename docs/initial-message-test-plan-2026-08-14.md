# Test plan — the "Ask Me About" / campaign-link opener fix

For a tester session to run **against production, after the deploy lands**. Everything
below has been verified locally except where it says otherwise; the point of this pass is
the things a local preview structurally cannot show — a real AI reply, a real phone, and
the Facebook in-app browser that most of the paid traffic arrives in.

## What changed

`ChatScreen.initialMessage` — the opener tapped on a profile card's "Ask Me About", and
the same thing carried on `/c/<id>?initialMessage=…` — used to be sent from the first
post-frame callback. The chat's history load is asynchronous and is the only thing that
builds the AI service, so on a cold load the send arrived first, found no service and
returned: the user's question was drawn and saved, **no `POST /api/chat` was ever made**,
and the typing indicator span for as long as the tab stayed open. It could also duplicate
the question, two different ways.

The opener now waits for the history load; the send waits for the service rather than
giving up on it; the typing indicator is cleared by a `finally` that covers every exit;
and the history merge and a reload guard close the two duplication paths.

## Before you start

1. **Confirm the build under test is actually being served.** The edge cache will happily
   serve you yesterday's bundle and every result below becomes meaningless. Preferred:
   have the deploy session run `bash tool/verify_deploy.sh https://chat.deeploveechoes.com`,
   which compares the live `main.dart.js` against the one it just built. Failing that,
   compare hashes yourself and check `cf-cache-status` on the response.
2. **Know the two failure vocabularies.** They look similar and mean opposite things:

   | What you see | What it means |
   |---|---|
   | Your question, then dots that never stop, and nothing else — ever | **The original bug, unfixed.** This is the P0 result. |
   | Your question, then "*<Name> is having trouble thinking right now*" | The request **was** made and the backend refused it. The opener fix passed. This is an auth/secret problem — a separate bug, report it separately. |
   | Your question, then a real in-character reply | Pass. |

3. **Cold means cold.** Clear site data between the FIX-1/FIX-6 runs, or use a fresh
   private window per run. A conversation that already holds the question will
   deliberately not re-send it (that is FIX-4).
4. If you have a devtools console, this dumps the stored conversation — more reliable than
   reading the screen, which clips under the quick-reply strip:

   ```js
   Object.keys(localStorage).filter(k => k.includes('chat_history')).map(k =>
     [k, JSON.parse(localStorage.getItem(k).replace(/^!/, '')).map(s => {
       const m = JSON.parse(s); return (m.isUser ? 'USER: ' : 'CHAR: ') + m.text.slice(0, 70);
     })])
   ```

   Two known traps when reading it: emoji render as tofu for the first second while the
   font downloads, and a backgrounded tab has its timers throttled, so anything paced
   (bubbles, nudges) stalls and the timestamps lie.

## P0 — the fix itself

| # | Test | Steps | Pass |
|---|---|---|---|
| **FIX-1** | Cold campaign link | Fresh private window → open `/c/odysseus?initialMessage=What%20happened%20when%20you%20finally%20reached%20Ithaca%3F` and don't touch anything | Your question appears once, then a reply within ~10s. Network shows exactly one `POST /api/chat`. |
| **FIX-2** | Indicator clears | Same run, watch for 60s after the reply | The dots are gone. They may reappear briefly with an idle nudge after ~14s of quiet — that is normal. Dots still going a minute after a reply is a fail. |
| **FIX-3** | No duplicate question | Same run | Your question appears **once**, not twice. Check the stored conversation, not just the screen. |
| **FIX-4** | Reload doesn't re-ask | On the FIX-1 chat, reload the page | The conversation comes back as it was. No new `POST`, no second copy of the question. |
| **FIX-5** | Second question, same character ⚠️ | From the dashboard, open a character's profile → tap an "Ask Me About" question → wait for the reply → back to the dashboard → open the **same** character's profile → tap a **different** question | The second question is sent and answered. **This is the one code path with no automated coverage and no local verification — spend time here.** |
| **FIX-6** | A real reply | Any cold opener against production | A genuine in-character answer, not the "trouble thinking" fallback. Multi-paragraph answers should arrive as several bubbles, paced. Never exercised before this deploy — local has no backend. |
| **FIX-7** | Time to your own bubble | Cold load, stopwatch from page load to **your question** appearing | Under ~1s on a normal connection. The fix deliberately delays the send until storage answers, so a slow device shows a gap here that did not exist before. Anything over ~2s is a regression worth reporting even though the reply still arrives. |
| **FIX-8** | Restricted storage | iOS Safari private mode, and the Facebook in-app browser | The opener is still sent and answered. Storage failure is handled, but if storage *hangs* rather than failing, the send waits with it — a question that never appears at all in these browsers is a P0. |

## P1 — regressions around the change

The same method now handles every send, and the history merge changed, so these are the
neighbours most likely to have broken.

| # | Test | Pass |
|---|---|---|
| **REG-1** | Open a character with **no** opener (`/c/odysseus`, or a dashboard card tap) | The scripted/welcome opening plays as before, in order, and is not cut short. |
| **REG-2** | Type a message by hand and send | Bubble, dots, reply. Indicator clears. |
| **REG-3** | Tap a quick-reply from the strip **in the first second** of a cold load | Sent and answered — the other send that used to race the service. |
| **REG-4** | Ask "what do you look like?" | The portrait arrives, the indicator clears, and it does **not** count against the free-reply allowance. |
| **REG-5** | Reload mid-conversation | History comes back once, in the right order, nothing duplicated and nothing lost. |
| **REG-6** | Open character A, then B, then back to A | Each keeps its own conversation; no bleed, no reset. |
| **REG-7** | Back arrow out of a chat and re-enter | Returns to the dashboard, chat intact on return. |
| **REG-8** | *(optional, slow)* Signed out, send 20+ messages to one character | The login gate appears. An opener that hits the gate should post no bubble at all, and should be re-sent if you reload the link. |

## Environments

In priority order — the first row is where the money goes.

| Environment | Why |
|---|---|
| **Facebook in-app browser, iOS + Android** | Where the paid traffic actually lands. Also the restricted-storage case (FIX-8). Reach it by posting the `/c/…?initialMessage=…` link somewhere you can tap it inside the app. |
| Mobile Safari (iOS) and Chrome (Android) | Normal phone behaviour, and private mode for FIX-8. |
| Desktop Chrome | Only place with comfortable devtools — use it for the network and localStorage evidence. |

## Server-side, after the run

The distinguishing signature of the fix is not in the funnel events — `first_message` was
logged *before* the code bailed, so it fired even when nothing was sent. What was missing
was the request itself.

- For each test visit, confirm a **`conversation_logs` row** exists (joined on the
  `x-user-id` the client sends). Under the bug there was none, for any opener arrival.
- `send_failed` should be **absent** for successful runs. If it appears with reason
  `network`, the request never reached the worker — report with the browser and time.
- Over the following day of paid traffic, opener-driven `/c/…` arrivals should stop
  showing `first_message` with no matching conversation row. That gap closing is the
  aggregate proof.

## Known not covered

Say so explicitly if you run out of time before these — they are the current blind spots,
not settled ground:

- **FIX-5** (second opener into a live chat screen) — new code, never run.
- **FIX-6** — the successful-reply path has only ever run against a backend that refused
  the request.
- The profile-card tap itself was never driven locally; the Browser pane cannot click
  Flutter's canvas, so only the route it navigates to was verified.

## Reporting

One line per test id, `PASS` / `FAIL` / `SKIPPED`, and for anything that is not a pass:

- the exact URL, browser and device;
- what you saw versus what the table expects;
- the stored-conversation dump from the snippet above;
- whether a `POST /api/chat` appears in the network tab, and its status;
- a screenshot — but never *only* a screenshot: a chat mid-pace looks identical to a
  stalled one.

Severity: anything in P0 fails → the fix did not land, stop and report before continuing.
P1 failures are shippable-but-report unless they lose messages.
