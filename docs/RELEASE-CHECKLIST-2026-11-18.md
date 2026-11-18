# Release checklist — 2026-11-18

For whoever runs the next deploy. Everything here is either an action or a
number to check afterwards; the reasoning lives in the commits.

## Where things stand

| | |
|---|---|
| `main` | `3325b74` (PRs #20 and #21 merged ~13:42 UTC) |
| Version | `1.0.7+104` |
| Last deploy | `1.0.7+103`, commit `3715dcc`, 12:51 UTC |
| Undeployed | the version bump (#20) and the `/admin/platforms` page (#21) |

**Deploys are manual.** `deploy_log` shows every entry as "auto-logged by
`npm run deploy`" — that is the log line writing itself, not the deploy
triggering itself. Merging to `main` ships nothing.

## 1. Deploy

```bash
npm run deploy
```

That script already does the right things in the right order — preflight,
`wrangler d1 migrations apply --remote`, web build, `wrangler deploy`, verify,
log, domain assert, smoke test. **Migrations run before the worker goes live**,
which is what keeps a new column from taking down the write path for the gap
between the two. Use the script rather than running `wrangler deploy` by hand.

### Afterwards, check these

```bash
curl -s -o /dev/null -w "%{http_code}\n" -u "admin:$ADMIN_TOKEN" \
  https://logs.deeplovepoems.com/admin/platforms
```

- `/admin/platforms` → **200**. It returns **405 right now**, because the
  deployed worker predates the merge. That 405 is the current symptom and the
  single best check that the deploy landed.
- `/api/admin/platforms?hours=24` → **200** with JSON.
- The other admin pages → still 200 (`/admin`, `/api/admin/first30`,
  `/api/admin/delivery` were all 200 before this deploy).

## 2. Migrations — nothing to do by hand

`0023_client_platform` and `0024_platform_repair` are **already applied to the
remote D1**, verified against production:

- `message_delivery` and `conversation_logs` both have a `client_platform`
  column.
- `site_visits.platform` reads `direct` and no longer contains
  `chat.deeplovepoems.com` / `chat.deeploveechoes.com`, so 0024's repair ran.

`npm run deploy` applies anything new before deploying, so there is no separate
step. Do not run `wrangler d1 execute` by hand to "fix" a column.

## 3. Store builds — needed before the new page says much

`/admin/platforms` can only report what a client tells it, and only clients
built after `0023` say anything.

- **Web** is already wired: the deployed `main.dart.js` sends
  `x-client-platform`, so web traffic starts being attributed as soon as
  step 1 is done.
- **iOS and Android** report nothing until new store builds ship. Until then
  all app traffic lands in `(unattributed)` on the page.

So expect **low coverage at first** — the big number at the top of the page
will be well under 100%, and the banner explains why in the actual row counts.
That is the page working, not a fault. Do not read an early per-platform count
as "we have few iOS users"; it is a lower bound.

## 4. Known-wrong, deliberately not in this release

**The dwell buckets across the admin pages read `duration_ms`, which is wall
clock, not attention.** On this traffic ~91% of exits are a backgrounded tab
rather than a close, and the clock keeps running in a browser nobody is looking
at. It reports a real 5.2s median as 32.7s. `visible_ms` is the honest column.

Nothing in this release touches it, so every dwell figure on the admin pages is
still wrong in the same flattering direction. Worth fixing next; not a reason
to hold this deploy.

## 5. There is no CI

No `.github/workflows`, no check runs on PRs. Verification is whatever a person
runs locally:

```bash
npm test          # 251 worker tests
flutter test      # 190 tests
flutter analyze   # 102 pre-existing infos, no errors — unchanged is the pass
```

All three were green on `main` at `3325b74` before this was written.
