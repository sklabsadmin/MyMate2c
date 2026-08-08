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

Read section 9 before deciding how long that window should be. Every day the
old Workers stay deployed is a day one of them can take production back.

### 9. Clean up — this is a mitigation, not tidying

Once settled, delete the orphaned Workers:

```bash
npx wrangler delete --name mymate2c
npx wrangler delete --name mymate-v2
```

This used to read as housekeeping. It is not. See "An old Worker taking the
domains back" below — on 2026-08-07 an old Worker did exactly that, five times,
and took production down twice.

Also update the stale comments in `wrangler.jsonc` and `.env.example`, which
still describe `mymate-v2` as the active target and `mymate2c` as the frozen
checkpoint.

## An old Worker taking the domains back

Everything above guards the forward direction: you rename, a *new* Worker is
created, and the old one keeps the domains. This section is the reverse, and it
is worse, because it happens after the migration is finished and believed safe.

**What happened (2026-08-07 to 08-08).** Repeated deploys of `mymate2c` and
`mymate-v2`. A custom domain belongs to whichever Worker most recently claims
it, so each of those deploys silently moved all three domains off `mythoslive`.
The longest stretch ran from 20:14 ICT on 07 Aug to 15:39 ICT on 08 Aug —
roughly **nineteen hours** — served by a frozen Worker with its own build, its
own secrets and its own D1. It recurred the same evening at 21:26, seconds after
a push. Cloudflare records nothing on the losing side: `wrangler deployments
list --name mythoslive` still showed our deploy as current, and the dashboard
showed the Worker as healthy.

Do not trust an early estimate of the duration. This was first believed to be
"about twenty minutes, and later most of an hour", because it was measured from
the deploys that were noticed rather than from the domain ownership, which
nothing was recording. The honest measure is the `conversation_logs` gap.

**Why it is hard to diagnose.** Every symptom points at secrets:

- `npm run smoke` fails `401 Invalid signature`, because it signs with the
  `APP_SECRET` from `.env` and is talking to a different Worker entirely.
- Visitors see "&lt;character&gt; is having trouble thinking right now", the same
  sentence that four unrelated secret failures produce.
- `verify_deploy.sh` passed minutes earlier and was telling the truth at the
  time — the domains moved afterwards.

The first hour of this incident was spent rotating and re-checking secrets. The
secrets were never wrong.

**The check that settles it in one command.** Ask who owns the domains, not
what the Worker contains:

```bash
npx wrangler deployments list --name mythoslive   # says nothing useful — it is not the loser's job to notice
```

Use the API instead; there is no wrangler command for this:

```bash
TOKEN=$(sed -n 's/.*oauth_token *= *"\([^"]*\)".*/\1/p' \
        ~/Library/Preferences/.wrangler/config/default.toml)
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/workers/domains" \
  | python3 -c 'import json,sys; [print(d["hostname"], "->", d["service"]) for d in json.load(sys.stdin)["result"]]'
```

All three hostnames must say `mythoslive`. Anything else is this failure, and
no amount of secret rotation will help. Note the OAuth token in that file
expires every twenty minutes or so and only a `wrangler` command renews it — a
`401` from this call usually means run `npx wrangler whoami` and retry, not
that access was revoked.

**The fix** is `npm run deploy`, which reclaims the domains as a side effect of
declaring them in `wrangler.jsonc`. It takes about two minutes and holds until
something claims them again.

When production is down and two minutes matters, reclaim the hostnames directly
instead — no rebuild, no deploy, seconds rather than minutes. The API refuses a
plain `PUT` with `already in use by other custom domain`; the flag it wants is
`override_existing_origin`:

```bash
for pair in "chat.deeploveechoes.com:$ECHOES_ZONE" \
            "chat.deeplovepoems.com:$POEMS_ZONE" \
            "logs.deeplovepoems.com:$POEMS_ZONE"; do
  curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    --data "{\"environment\":\"production\",\"hostname\":\"${pair%%:*}\",
             \"service\":\"mythoslive\",\"zone_id\":\"${pair##*:}\",
             \"override_existing_origin\":true}" \
    "https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/workers/domains"
done
```

Then smoke test. Reclaiming the hostnames is enough on its own — the Worker
already has the right code; it had simply stopped receiving the traffic.

**Confirm with the UI, not just the API.** A build served by an old Worker
looks plausible. Two tells that cost nothing: the chat screen showing
"N/20 anonymous messages" above the message box (removed 2026-08-07), and
`/admin/sessions` returning 404 instead of prompting for a password.

**The cause: Cloudflare Workers Builds (found 2026-08-08).** No machine was
responsible. `mymate2c` and `mymate-v2` each had Cloudflare's git integration
connected to `sklabsadmin/MyMate2c`. Every push to `main` made Cloudflare run
`wrangler deploy` server-side, from the repo's root `wrangler.jsonc` — routes
block included — so **every push handed production to a frozen Worker.**
`mythoslive` had no such connection, which is why it always lost: the builds
deployed last, automatically, a minute or two after each push.

The correlation is what identifies it. Ten pushes, ten paired deploys, no
exceptions:

| push (ICT) | mymate2c | mymate-v2 | lag |
| --- | --- | --- | --- |
| 08-08 21:26:15 | 21:27:07 | 21:26:53 | +52s / +38s |
| 08-08 19:59:31 | 20:01:41 | 20:01:49 | +2m10s |
| 08-07 20:10:59 | 20:14:11 | 20:14:00 | +3m |
| 08-07 19:16:03 | 19:19:03 | 19:18:16 | +3m |
| 08-07 17:14:55 | 17:17:55 | 17:17:53 | +3m |

Two false trails cost hours, both worth recognising:

- **`source: wrangler` does not mean a human ran wrangler.** Workers Builds runs
  wrangler too, and Cloudflare attributes the version to the account email — the
  same as every machine sharing the login. It identifies nobody.
- **"No local wrangler log, therefore another machine"** is the wrong inference.
  Wrangler writes a log per run to `~/Library/Preferences/.wrangler/logs/`
  (filenames are UTC), and its *absence* does correctly rule out this Mac — but
  the alternative is a server-side build, not a second laptop. Several hours went
  into hunting a phantom Windows checkout and then a phantom cloud session, on
  timing that happened to correlate.

**What actually ends it** is deleting the Workers that can win the race. The
build configuration belongs to the Worker, so deleting the Worker deletes its
trigger, and a push can no longer resurrect it. Both were deleted 2026-08-08.
This corrects the earlier advice in this section that deleting first does not
help — that is true of a human running `wrangler deploy --name`, and false of a
git-triggered build, which is what this actually was.

Before blaming anyone, check for git connections: dashboard → Workers & Pages →
the Worker → Settings → Builds. The API path is scope-blocked for a
`wrangler login` OAuth token (`Authentication error`), so this needs the
dashboard or an API token with builds read.

**Impact, for calibration.** Visits kept being logged throughout; chats stopped
dead. `site_visits` recorded ~210 arrivals between 08-07 20:14 and 08-08 15:39
and `conversation_logs` recorded **zero** over the same window, against 8 in the
healthy hour before it. The site loads and looks fine while nobody can talk to
anyone — so a quiet chat log during a traffic-normal period is itself a symptom
worth checking domain ownership over.

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
- [ ] **No git connection on any old Worker** (dashboard → the Worker → Settings
      → Builds). One connected build turns every push into a domain hijack — see
      "An old Worker taking the domains back"
- [ ] Domain ownership re-checked after the rollback window (see "An old Worker
      taking the domains back") — all three hostnames still on the new Worker
- [ ] Domain ownership re-checked again after the *next push*, not just after the
      deploy — a git-triggered build lands minutes later and `verify_deploy.sh`
      will have already passed
- [ ] Old Workers deleted, comments updated
