# Operational notes

Things that are true about this project but not visible from the code, written
for whoever picks it up next. Everything here was learned by getting it wrong
first.

## Where production actually is

`mythoslive` is the live Worker. It owns all three custom domains
(`chat.deeploveechoes.com`, `chat.deeplovepoems.com`, `logs.deeplovepoems.com`),
holds five secrets, and binds D1 `mymate2_db` (`5ada4bd9-…`).

`mymate-v2` and `mymate2c` are frozen predecessors, still deployed as rollback.
Delete them once nobody needs that. `mymate-api` is older still and serves the
approved App Store build 1.39 — leave it alone.

**Cloudflare has no rename.** Changing `"name"` in `wrangler.jsonc` creates a new
Worker and leaves the old one running with its domains and secrets attached.
This is invisible from the repo and looks exactly like a successful deploy: a
21 July rename left production serving a two-week-old build, and nobody noticed
until users complained. `docs/worker-migration-runbook.md` has the full
procedure; the short version is that domains move **last**, after the new Worker
is proven on its workers.dev URL.

## Deploying

**Local only.** Cloud sessions cannot deploy: the sandbox egress policy blocks
`api.cloudflare.com`, there is no `.env`, and `wrangler login` needs a browser
that can reach the container. Cloud sessions are fine for code, builds, tests
and commits — just not for anything touching Cloudflare.

The Mac at `/Users/adam/abldev/mymate2c` has `.env`, an authenticated wrangler
and Flutter. There is a second checkout on Windows at
`C:\Users\adam\abldev\MyMate2c`.

Always `npm run deploy`. Never a bare `wrangler deploy` — that republishes
whatever happens to be sitting in `build/web`, which has shipped a stale bundle
before. The npm script chains build → deploy → `verify_deploy.sh` →
`smoke_test.sh`.

**`wrangler secret put` does not take effect until the next deploy, and then
needs a moment to propagate.** This cost hours across three separate incidents.
After setting a secret, deploy, then wait before testing — testing immediately
returns the previous value's behaviour from colos that have not caught up, which
looks exactly like the secret being wrong.

## Never hand-verify a deploy with curl

Cloudflare's edge serves a stale `main.dart.js` for a while after a deploy,
ignores client `Cache-Control: no-cache`, and is not reliably busted by a
`?query` string. This produced three confident, entirely wrong conclusions in one
afternoon — including "the wrong bundle is deployed" when the origin was correct
the whole time.

`tool/verify_deploy.sh` retries with sleeps until the edge revalidates and is the
only trustworthy check. It compares `main.dart.js` only, so it is blind to
version-only bumps: the version lives in `build/web/version.json`, not in
compiled Dart. Bumping the version before a risky change is a cheap, unambiguous
way to prove which build is live.

Cloudflare also answers a default curl user-agent with `403 error 1010`, which
reads exactly like an auth failure. Send a browser UA.

## The one error message you will actually see

Any backend failure reaches the user as:

> "<character> is having trouble thinking right now. Please stand by..."

The client renders every non-429 failure that way, so this sentence means "the
request failed", not "the AI is down". Causes seen in practice:

| Cause | Status |
| --- | --- |
| Worker `APP_SECRET` ≠ the one baked into the client | 401 `Invalid signature` |
| Inworld key wrong or from another workspace | 502, provider 401/403 |
| OpenAI key missing or rejected | 502 |
| A D1 write failing inside the chat handler | 500 (now guarded) |

`conversation_logs` records `status`, `status_code` and the provider's own error,
which is the fastest way in — **except** when the request was rejected at the
signature gate, because that returns before logging runs. Silent logs plus failing
chat points at auth, not at the AI.

`tool/smoke_test.sh` (`npm run smoke <url>`) checks all of this against a live
URL by signing a request the way the app does. It would have caught every secret
incident so far.

## Secrets

Five live on the Worker: `APP_SECRET`, `OPENAI_API_KEY`, `GOOGLE_CLIENT_SECRET`,
`INWORLD_API_KEY`, `ADMIN_TOKEN`. `ADMIN_SECRET` exists on `mymate-v2` but is
referenced nowhere — do not carry it forward.

**`APP_SECRET` is the dangerous one.** The client bakes `.env`'s value in at
build time and the Worker verifies against its own copy. Rotating it requires
rebuilding and redeploying the client in the same step, or every chat request
fails instantly. It was rotated mid-session once and took production down until
it was restored.

`SESSION_SECRET` is unset everywhere, so session signing falls back to
`APP_SECRET`. That is why signed-in users survived the worker migration — and it
means rotating `APP_SECRET` also invalidates every session.

`INWORLD_API_KEY` must be base64 of `key:secret` — the Worker sends it as
`Authorization: Basic`. A structurally valid key from the wrong workspace
authenticates and then returns a bare `403 Forbidden`, which is easy to misread
as a formatting problem.

Admin pages take any username with `ADMIN_TOKEN` as the password. `.dev.vars` has
drifted out of sync with the live value more than once; treat the Worker as
authoritative and re-set it if in doubt.

## screen_ping and the dwell buckets

The chat screen reports a `screen_ping` funnel event on a two-phase cadence:
every 500ms for the first 10s (20 ticks), then every 3s to 28s — 26 ticks total.
Fine resolution through the window that decides whether someone bounced, cheap
after.

Cost is the reason it is not 500ms throughout: every tick is a D1 row, most
visits that open a character never engage, and those writes share a database with
`conversation_logs` — so exhausting the quota degrades chat itself.

Ticks no longer convert to seconds by one multiply (tick 22 is 16s, not 11s).
The conversion lives in `screenPingSeconds()` / `screenPingTicksAt()` in the
worker, mirrored by constants in `chat_screen.dart`, and the admin dwell buckets
derive from them. Do not write thresholds out as literals — they were hardcoded
for 500ms once and silently reported "nobody stayed" after the cadence changed.

**Dwell data has eras.** A tick was 0.5s flat, then briefly 2s, and is now
two-phase. Only compare within one era.

Per-visit tick counts are on `/admin/visits` under "Recent arrivals", in the
Ticks column, with the implied seconds in the tooltip.

## Admin pages are client-rendered

`/admin/visits` and `/admin/referrals` fetch their data and render in the
browser. Their `<script>` is inside a template literal, so `'x' + f() + 'y'` is
text sent to the browser while `${f()}` runs in the Worker. Calling a Worker
function from that script ships a reference the page has never seen; it throws
before rendering, and without a catch the page sits on "Loading…" forever,
indistinguishable from a slow request. Both pages now catch and display errors —
keep it that way.

## Known open items

- The iOS keyboard fix (`keyboard_inset.dart`, `?vpdebug=1` readout) is a
  reasoned candidate that has never been confirmed on a device. If `PEAK` reads 0
  while the keyboard is up, the browser is not reporting it and the answer is at
  the `index.html` viewport-meta layer, not in Dart.
- The version sorts below the approved App Store build 1.39, so an iOS
  submission would be rejected. See `docs/known-issues-2026-08-03.md` item 3.
- `logs.deeplovepoems.com` does not fully restrict non-admin paths. Documented as
  deliberate; same doc, item 1.
- Six analyzer warnings and ~99 deprecated `withOpacity` infos, all pre-existing.
- `.dev.vars` carries a duplicate `ADMIN_TOKEN` line; the last one wins.
