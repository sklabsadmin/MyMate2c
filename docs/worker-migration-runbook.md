# Runbook — moving the app to a new Cloudflare Worker

Written for the planned move to `mythoslive`, but the steps apply to any Worker
rename. **Cloudflare has no rename operation**: changing `"name"` in
`wrangler.jsonc` creates a *new* Worker and leaves the old one running, still
holding its custom domains and its secrets. Everything below exists because
that half-finished state is invisible from the repo and looks exactly like
success.

## Why this document exists

On 2026-07-21 the config was renamed `mymate2c` → `mymate-v2`. The new Worker
deployed cleanly from then on, but the three custom domains stayed attached to
`mymate2c`. For two weeks every `npm run deploy` shipped correctly to a Worker
that nothing routed to, while visitors were served `mymate2c`'s pre-21-July
build.

It surfaced as *"<character> is having trouble thinking right now"* on every
character. The cause was not the AI: `mymate2c` held an older `APP_SECRET`, so
the current client's HMAC failed and `/api/chat` returned
`401 Invalid signature`. The client renders any non-429 failure as that same
sentence, which is why it read as an AI outage. The chat log page also looked
dead, because a request rejected at the signature gate returns before
`persistConversationLog()` ever runs.

Diagnosis took hours largely because the symptoms all pointed away from routing.

## Preconditions

This is a **local-only** procedure. Cloud sessions cannot deploy: the sandbox
egress policy blocks `api.cloudflare.com`, there is no `.env`, and
`wrangler login` needs a browser that can reach the container.

```bash
ls .env                 # must exist and define APP_SECRET
npx wrangler whoami     # must be authenticated
flutter --version       # build toolchain present
git status --short      # clean tree, on the commit you intend to ship
```

## What has to move

Creating the Worker is the easy part. These are the attachments, and a new
Worker starts with **none** of them:

| Item | Current value |
| --- | --- |
| Secrets | `ADMIN_SECRET`, `ADMIN_TOKEN`, `APP_SECRET`, `GOOGLE_CLIENT_SECRET`, `INWORLD_API_KEY`, `OPENAI_API_KEY` |
| D1 binding | `CHAT_LOGS_DB` → `mymate2_db` (`5ada4bd9-a4ad-4a75-8c0a-5f4d023f578f`) |
| Vars | `REQUIRE_CHAT_LOGS`, `REQUIRE_SIGNATURE`, `APP_ORIGIN`, `GOOGLE_CLIENT_ID` |
| Custom domains | `chat.deeploveechoes.com`, `chat.deeplovepoems.com`, `logs.deeplovepoems.com` |
| Other config | `placement: smart`, `nodejs_compat`, `compatibility_date` |

Two that bite hardest:

**`APP_SECRET` must equal the value in `.env`.** The client bakes `.env`'s value
in at build time (`tool/build_web.sh`) and the Worker verifies against its own
secret. Any mismatch fails every chat request with `401 Invalid signature`.
`mymate2c` is the cautionary example — it still holds a stale one.

**Keep the same D1 database.** `conversation_logs`, `site_visits`,
`user_profiles` and `linked_accounts` all live in `mymate2_db`. Creating a fresh
database discards every user's chat history and the entire funnel dataset, and
does so silently — the app works perfectly against an empty database.

## Registrations that live outside this repo

`GOOGLE_REDIRECT_URI` is deliberately unset, so `getGoogleRedirectUri()` falls
back to the origin of the incoming request. The three custom domains therefore
keep working across a migration without changes. The **workers.dev origin
changes**, and Google rejects unregistered redirect URIs with
`redirect_uri_mismatch`.

Before cutting over, add to the OAuth client in Google Cloud Console:

```
https://<new-worker>.sklabs-admin.workers.dev/auth/google/callback
```

and update the `APP_ORIGIN` var in `wrangler.jsonc` to the new workers.dev URL.
Instagram's redirect URI has the same shape, though that flow is still WIP.

## Procedure

The 21 July migration failed because the domains moved separately from
everything else. This order keeps the new Worker invisible to users until it is
fully proven.

### 1. Create and deploy, with no routes

Edit `wrangler.jsonc`: set `"name": "mythoslive"` and **temporarily comment out
the `routes` array**. Then:

```bash
npm run deploy
```

Users are unaffected — the domains still point at the old Worker.

### 2. Set every secret

```bash
for s in ADMIN_SECRET ADMIN_TOKEN APP_SECRET GOOGLE_CLIENT_SECRET \
         INWORLD_API_KEY OPENAI_API_KEY; do
  npx wrangler secret put "$s" --name mythoslive
done
npx wrangler secret list --name mythoslive     # expect all six
```

`APP_SECRET` must be pasted from `.env` exactly — no trailing newline or quotes.

### 3. Confirm the database is the shared one

```bash
npx wrangler d1 execute mymate2_db --remote \
  --command "SELECT COUNT(*) AS logs FROM conversation_logs"
```

A non-zero count means you are on the existing database. Zero means a new one
was created — stop and fix the binding before going further.

### 4. Update external registrations

Add the new workers.dev callback in Google Cloud Console, and set `APP_ORIGIN`
in `wrangler.jsonc` to the new workers.dev URL. Redeploy.

### 5. Prove it works before any user sees it

Against `https://mythoslive.sklabs-admin.workers.dev`:

- a signed `POST /api/chat` returns `200` with a real reply
- `/admin/logs` prompts for Basic Auth and lists recent rows
- Google sign-in completes
- `/version.json` reports the version you just built

The signed request is the one that matters — it is the exact check that would
have caught the 21 July failure on day one. `tool/verify_deploy.sh` does not
exercise the client's own signing path.

### 6. Repoint the domains

Restore the `routes` array in `wrangler.jsonc`, then:

```bash
npm run deploy
```

Wrangler asks:

```
Custom Domains already exist for these domains: ...
Update them to point to this script instead? (Y/n)
```

Answer **Y**. This prompt is interactive and does nothing if unanswered — a
non-interactive or piped deploy can skip it silently. **Confirm from the deploy
output** that the trigger list names all three domains.

### 7. Verify on the real domains

```bash
bash tool/verify_deploy.sh https://chat.deeplovepoems.com
for u in chat.deeplovepoems.com chat.deeploveechoes.com logs.deeplovepoems.com; do
  curl -s "https://$u/version.json"; echo
done
```

Then repeat the signed `/api/chat` check against `chat.deeplovepoems.com`.

**Do not hand-verify assets with `curl`.** Cloudflare's edge serves a stale
`main.dart.js` for a while after deploy, ignores client `Cache-Control:
no-cache`, and is not reliably busted by a `?query` string. During this
migration that produced three separate, entirely convincing false conclusions —
including "the wrong bundle is deployed" when the origin was correct all along.
`tool/verify_deploy.sh` retries with sleeps until the edge revalidates, and is
the only trustworthy check.

Note it compares `main.dart.js` only. A version-only bump leaves that file
byte-identical, so it will report "no change" — check `version.json` instead.

### 8. Leave a rollback window

Do not delete anything for a few days. Rolling back is: restore the old `name`
in `wrangler.jsonc` and `npm run deploy`, answering **Y** to take the domains
back.

### 9. Clean up

Once settled, delete the orphaned Workers so nobody inherits this confusion:

```bash
npx wrangler delete --name mymate2c
npx wrangler delete --name mymate-v2
```

Also update the stale comments in `wrangler.jsonc` and `.env.example`, which
still describe `mymate-v2` as the active target and `mymate2c` as the frozen
checkpoint.

## After migrating

Users' browsers cache the app aggressively via `flutter_service_worker.js`. A
returning visitor may run the previous bundle for a load or two. That is
expected and self-healing; if you need to check current behaviour immediately,
use a private window, which bypasses the service worker entirely.

## Checklist

- [ ] Deployed with routes commented out
- [ ] All six secrets set and listed
- [ ] `APP_SECRET` matches `.env` exactly
- [ ] D1 points at existing `mymate2_db`, row count non-zero
- [ ] Google redirect URI added for the new workers.dev origin
- [ ] `APP_ORIGIN` updated
- [ ] Signed `/api/chat` returns 200 on workers.dev
- [ ] Admin page and Google sign-in work on workers.dev
- [ ] Routes restored, **Y** answered, all three domains in the trigger list
- [ ] `verify_deploy.sh` passes
- [ ] `version.json` correct on all three domains
- [ ] Signed `/api/chat` returns 200 on `chat.deeplovepoems.com`
- [ ] Old Workers left deployed for rollback
- [ ] Old Workers deleted, comments updated
