# Odysseus opening — what the data says, and what to try

Written 2026-08-10 for a session whose job is to **change the Odysseus chat
opening**. Read §2 before proposing anything: most of what looks like a finding
in this dataset is confounded, and the single biggest risk is shipping a
confident fix for a cause that was never established.

> **Superseded in part, same day.** Commit `74436ba` ("Let Odysseus ask,
> instead of talking for ninety seconds first") replaced the v1 script this
> document analyses — see `docs/odysseus-v2-handoff-2026-08-10.md`. v2 ends
> every turn on a question, which implements §3.1 more thoroughly than
> suggested here.
>
> What is still live in this document:
> - **§1's measured numbers and §4's baselines** — these are the pre-v2
>   baseline, and the only thing v2 can honestly be judged against. They were
>   measured on the v1 script; do not re-measure them from current traffic.
> - **§2 in full** — the confounds and the warning against Calypso comparisons
>   apply to judging v2 exactly as they applied to designing it.
> - **§4's method** — in particular, that ~1 message/day is too rare to A/B on,
>   so v2 must be judged on the tick distribution.
>
> What is superseded: **§1's script timeline** (describes v1, now deleted) and
> **§3's proposals** (§3.1 is done; §3.2 is addressed by v2's per-character
> `_briskPacing`; §3.3 remains untested).

---

## 1. The measured situation

**Use only data from 2026-08-09 00:00 UTC onward.** The Odysseus scripted
opening was committed 2026-08-08 21:24 and the build bumped at 22:54. Anything
earlier is a different app and mixing it in produces wrong answers — this
already happened once during the analysis that produced this document.

Last full window (2026-08-09 → 2026-08-10 05:00 UTC), excluding `country='TH'`
which is the developer:

| | |
|---|---|
| Arrivals | 147 |
| App loaded (`app_ready`) | 143 (97%) |
| Chat screen opened (`character_tap`) | 134 (91%) |
| Tapped a starter or typed (`starter_tap` / `input_typed`) | **1** |
| Messages sent | **1** |

**This is not a technical failure.** Page loads run 0.4–2s, 97% reach
`app_ready`, 91% get the chat screen open, and there were zero `send_failed`
rows. People arrive, the app works, and they leave without touching anything.

How long they stay on the chat screen, from the `screen_ping` tick trail:

| Time on chat screen | Visits | Share |
|---|---|---|
| 0 ticks | 18 | 13% |
| under 2s | 13 | 10% |
| 2–5s | 36 | 27% |
| 5–10s | 34 | 25% |
| 10–28s | 27 | 20% |
| full 28s+ | 6 | **4%** |

Half are gone within 5 seconds. Three-quarters within 10.

### The script timeline against that

Computed from the pacing constants in
`lib/src/features/chat/presentation/chat_screen.dart` (`_scriptBeatBaseMs` 400,
`_scriptMsPerWord` 260, clamped 900–4500ms, plus each segment's `pauseMs`):

| Elapsed | Line |
|---|---|
| 0.9s | "Well now..." |
| 2.6s | "I wasn't expecting company today." |
| 3.5s | "I'm Odysseus." |
| 6.0s | "King of Ithaca. Sailor. Occasional troublemaker. Professional survivor." |
| 12.0s | "If you've heard stories about me, I should warn you..." |
| 16.5s | "the poets had a habit of making me sound far more impressive..." |
| 18.5s | "Although... they weren't entirely wrong. 😉" |
| 23.2s | "May I ask you something?" |
| **26.7s** | **"What made you stop here instead of visiting one of the others?"** |

**Odysseus does not address the visitor until 26.7s. Only 4–5% of them are
still there.** His second question lands at 57s and segment 10 —
"Ah... you're still here" — is effectively unreachable.

The starter chips (`_odysseusQuickReplies` set 0) *are* on screen from t=0 and
persist, so "nothing to tap" is not the problem. Three static chips sit below a
stream of arriving bubbles and a restarting typing indicator; the monologue is
the thing moving, so it is the thing being watched.

---

## 2. What is NOT established — read this before proposing a fix

**The 26.7s delay has not been shown to cause the low engagement.** It is a
design fact, not a proven cause. Specifically:

- Calypso retained **23%** of visitors to 28s **with no scripted opening at
  all** (2026-08-05 → 08-06 20:12, 171 chat opens), and **22%** after her
  script landed (65 opens). The script made no measurable difference to her
  retention. So "faster script ⇒ better retention" is not supported.
- Odysseus retains 5% to 28s versus Calypso's 22–23%, but that comparison is
  confounded three ways at once: **different character, different audience
  (258 US vs 115 Eastern/Southern European), different app build.** Three
  variables, two data points. It cannot carry a conclusion.

**Do not use any Calypso-vs-Odysseus comparison as evidence for a change.**

### Traffic context that limits what any fix can achieve

- 93% of arrivals are in the **Facebook in-app browser** (UA contains
  FBAN/FBAV), not Instagram — only ~4 Instagram in-app visits total. The
  `source=ig` label in the admin UI is wrong; `detectTrafficSource` in
  `backend/src/worker.js` returns the hardcoded `utm_source=ig` before it ever
  checks the user-agent.
- Cost is ~$0.065–$0.15 per landing-page view, which is 10–30× below genuine
  US rates. This is low-intent traffic bought cheaply, and a meaningful share
  of the sub-5s bounces are probably accidental taps on Reels.
- Conclusion: **a perfect opening may still convert poorly here.** Judge
  changes on retention, not on absolute conversion.

---

## 3. Changes worth trying, in order

Change **one thing at a time**. With ~130 visits/day, a single variable is
detectable in the tick distribution within a day or two; two at once is not.

### 3.1 Move the first question early (highest value)

Target: Odysseus addresses the visitor by **~10s**, ideally sooner — that is
where 25% of them still are, versus 5% at 28s.

The material is already there; it is ordered wrong. His four-line résumé
("King of Ithaca. Sailor. Occasional troublemaker. Professional survivor") is
better content *after* someone is engaged than as the thing that spends their
first six seconds. Suggested restructure of `_odysseusOpeningScript`
(`chat_screen.dart` ~line 1195):

- Segment 1: keep "Well now..." and "I wasn't expecting company today." Drop
  or defer the other two lines.
- Segment 2: go straight to a question.
- Move the résumé and the "poets exaggerated" segment to after the first
  exchange, as the no-answer continuation or as a reply to their first message.

Note the structure Calypso uses, which reaches her question at 15.0s: two
lines, then a permission line at 10.1s, then the question at 15.0s. Her second
line — "I'm genuinely glad you came" — is about the *visitor*. Odysseus's first
four are about himself. That contrast is worth borrowing even though, per §2,
it is not proven to be why she retained better.

### 3.2 Trim dead time between segments

Two 3000ms segment pauses sit before the current first question, contributing
6s of the 26.7s. Calypso opens with 2500/1500 instead. Reducing early `pauseMs`
is a cheap, low-risk lever.

**Caution:** the pacing constants carry long explanatory comments (see
`_scriptMsPerWord`, `_scriptBeatMinMs`). They were tuned deliberately — a flat
interval was tried first and was worse. Adjust segment `pauseMs` in preference
to the per-word rate, and do not change `_screenPingPhase1Ticks` /
`_maxScreenPingTicks`: those are mirrored by `SCREEN_PING_*` in
`backend/src/worker.js` and changing one side silently shifts every dwell
figure in the admin UI.

### 3.3 Make the chips compete better with the stream

Lower confidence, but worth considering: the starter chips are present from
t=0 yet essentially never tapped (1 in 134). Whether they are being seen at all
during the incoming-bubble stream is untested. Options: hold the typing
indicator less often early, or make the strip more visually assertive during
the opening.

---

## 4. How to know whether it worked

**Do not measure on messages sent.** At ~1/day, that metric cannot detect any
change. Use the tick distribution, which gets 130+ samples/day.

Primary metric — share of chat opens still present at each threshold, current
baseline in bold:

| Threshold | Baseline (Aug 9–10) |
|---|---|
| still at 10s (ticks ≥ 21) | **25%** |
| still at 28s (ticks ≥ 26) | **5%** |

Secondary: `starter_tap` + `input_typed` per chat open (baseline 1/134).

Tick-to-seconds conversion: ticks 1–20 are 500ms apart (first 10s), ticks 21–26
are 3s apart (10s → 28s). So ticks ≥21 means "still there at 10s" and 26 means
the full 28s cap.

Query the comparison as arrivals excluding `country='TH'`, windowed strictly
after the deploy that carries the change — see §1 on why the window matters.

Hold the audience fixed: same character, same Facebook European traffic, one
changed variable. If 28s retention moves off 5%, the pacing hypothesis is
confirmed.
If it does not, the cause is the audience or the creative, and the answer is in
Meta's targeting rather than in this file.

---

## 5. Related

- `docs/ANALYTICS_HANDOFF.md` — how to query the data, and the older data
  quality traps. Note its §4 predates `screen_ping`, `starter_tap` and
  `input_typed`.
- `docs/operational-notes.md` — includes the warning that `grep` treats
  `backend/src/worker.js` as binary; use `grep -an`.
- Deploys: `npm run deploy`, never a bare `wrangler deploy`. Edge caching makes
  hand-checking with curl unreliable; `tool/verify_deploy.sh` is the trustworthy
  check.
