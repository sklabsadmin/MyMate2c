# MyMate — session handoff

Written 2026-07-23. Start Claude from **this directory** (`~/abldev/mymate2c`).

> **Trap:** `~/abldev/MyMate1.3x` is a *different, older* project (the 1.39c App
> Store build — a real backup, don't delete). It contains a file with the same
> path as this project's dashboard **and** its own `build:web` / `deploy` npm
> scripts. Running a bare `grep`, `npm run build:web`, or `npm run deploy` from
> the wrong cwd silently succeeds against the wrong app. This cost hours on
> 2026-07-23: fixes were edited here but compiled there, so the browser kept
> showing a stale bundle while everything "looked" correct.

---

## What this is

Flutter web + iOS/Android AI companion chat app. Greek mythological characters
plus a few modern ones. Bought from a third-party developer as "MyMate"
(a straight boyfriend-chat app) and being reworked into a Greek-themed,
mixed-gender roster.

- **Frontend:** Flutter (`lib/`), deployed as static web assets
- **Backend:** single Cloudflare Worker (`backend/src/worker.js`, ~1900 lines)
- **Data:** Cloudflare D1 (`mymate2_db`) for conversation logs
- **Live:** `chat.deeploveechoes.com`, `chat.deeplovepoems.com`,
  `mymate-v2.sklabs-admin.workers.dev` — all one worker, `mymate-v2`
- **Version:** 1.48.1+49

### Build & deploy

```bash
cd ~/abldev/mymate2c && rm -rf .dart_tool/flutter_build && npm run build:web && npm run deploy
```

`rm -rf .dart_tool/flutter_build` matters — a stale build cache has silently
served old code more than once. Verify a deploy by hash, not by the CLI output:

```bash
curl -sL -H 'Cache-Control: no-cache' "https://chat.deeploveechoes.com/main.dart.js?cb=$RANDOM" | shasum -a 256 | cut -c1-12
shasum -a 256 build/web/main.dart.js | cut -c1-12
```

Cloudflare edge-caches assets, so a plain (non-cache-busted) fetch can return
the old bundle for a while after a successful deploy.

### Local dev

`.claude/launch.json` in the *parent* session directory ran
`npx wrangler dev --remote --port 8787`. `--remote` is deliberate: the worker's
secrets (`OPENAI_API_KEY` etc.) only exist server-side, so local mode returns
`Incorrect API key provided: undefined`. Consequence: local testing uses the
**live** D1 and spends **real** OpenAI credits.

---

## Two AI paths

The worker decides server-side from `characterId` — the client only ever sends
an id, never the engine choice.

**Direct path** (Zeus, Damon, Liam, Kai, Penelope, Cupid) — one call to
`gpt-4o-mini`. Came with the app.

**Inworld path** (Odysseus, Oedipus only) — Inworld generates in character,
then a second `gpt-4o-mini` pass cleans it up for chat bubbles. Added by the
owner. `INWORLD_CHARACTERS` in `worker.js`.

### The persona layer (important)

The client sends one generic system prompt for *every* character
(`lib/src/features/chat/data/chat_prompt.dart`): *"You are 'My Boyfriend'… You
are strictly MALE… THE USER IS FEMALE"*, with only the display name dropped
into a context line.

Zeus survives that because he agrees with it. **Penelope contradicted its most
emphasised instruction and lost** — she answered as a generic devoted male
partner and never said she was Penelope. The fix was not teaching the model who
she is (it knows); it was removing the instruction saying she's a man.

`CHARACTER_PERSONAS` in `worker.js` **replaces** the client prompt for a
matching id — appending would leave the contradiction in place. Each entry
carries its own safety/tone rules since it *is* the whole instruction. Personas
are server-side: editable with a worker deploy, no app rebuild.

**Anyone who isn't a straight male romantic lead will break the same way on the
direct path unless given a persona.** Penelope and Cupid have them; Zeus,
Damon, Liam and Kai still ride on the generic template.

Roadmap note from the owner: characters will eventually be female, male and
non-binary, so the "boyfriend" framing in the client template is on borrowed
time.

---

## Current roster

`AppConfig.visibleCharacterIds` controls what shows; definitions live in
`dashboard_screen.dart`'s `_characters` list (many defined but hidden).

- **GREEK tab:** zeus, odysseus, oedipus, penelope, cupid
- **MODERN tab:** badboy (Damon), poet (Liam), surfer (Kai)

Profile cards exist for **all five Greek characters** (`character_profiles.dart`).
The badge only appears on cards that have one.

Naming: **Cupid, not Eros** — deliberate, the Roman name is better known.
Consistent across dashboard, worker persona and profile.

---

## Known state / gotchas

**`REQUIRE_SIGNATURE` is `"false"` in production.** The worker normally verifies
an HMAC on `/api/chat`. A build shipped without `APP_SECRET` broke chat
entirely; the flag was the workaround. **Before real users, set it to `"true"`
and rebuild the client with the same `APP_SECRET` as the worker's secret** —
otherwise `/api/chat` is an open proxy to the OpenAI account. The `APP_SECRET`
in local `.env` files and `.claude/launch.json` is **stale** and matches nothing.

**Tab is a hidden shortcut**, live in production:
- Settings → "clear all chat history"
- Any profile screen → "clear this character's history"
- Y confirms, any other key cancels. Device-local only — D1 logs are never
  touched, by design.
- The WIP holding page also used Tab, but it's disabled now
  (`AppConfig.showMaintenanceGate = false`; screen and bypass kept in code).

**Google sign-in only completes on the workers.dev origin** — `APP_ORIGIN` and
`GOOGLE_REDIRECT_URI` still point there, so OAuth won't finish on either custom
domain. Pre-existing.

**Old chats can't open profiles from the chat header** — conversations created
before `characterId` was plumbed through have no id stored. New ones are fine.

**`assets/images/avatar_cupid_toon.png`** is untracked but still gets bundled
(pubspec globs the whole images dir). It's a cartoon cherub — deliberately not
wired to Cupid, who is a flirtatious character. Worth deleting.

**10 commits unpushed to GitHub** (`git@github.com:sklabsadmin/MyMate2c.git`).
Production is deployed from them, so only the remote is behind. There is no CI —
pushing does **not** deploy.

---

## Verification discipline

Two habits, both learned the hard way on 2026-07-23:

1. **`cd` explicitly on every shell command.** See the trap at the top.
2. **When told something is still broken, measure — don't re-reason from the
   code.** A screenshot contradicting the code *is* the bug. After two failed
   attempts at the same visual issue, paint the container a debug colour, print
   computed values, or verify the artifact under test is the one actually being
   served. Don't say "fixed" from a screenshot that merely looks different.

Also: `worker.js` contains a `·` character, so `file` classifies it as binary
and **plain `grep` silently returns nothing**. Use `LC_ALL=C grep -a`. A grep
returning no matches there once led to the wrong conclusion that the worker had
no HMAC verification at all.

---

## Suggested next steps

1. Push the 10 commits to GitHub.
2. Delete `avatar_cupid_toon.png`.
3. Test profile clear-history end-to-end (fixed but never clicked through).
4. Personas for Zeus, Damon, Liam, Kai — the same treatment Penelope got.
5. Real artwork for Kai (currently `custom_avatar_02.png`).
6. Before launch: re-enable `REQUIRE_SIGNATURE` with a matching `APP_SECRET`.
