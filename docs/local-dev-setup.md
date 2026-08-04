# Recreating this machine's local dev setup elsewhere

Written for a fresh session on another machine (e.g. Windows) that needs the
same local development capability just set up here. Everything below reflects
commits through `54bf511`.

## Comes free with `git pull` + `npm install`

Nothing to hand-copy for these — they're committed:

- **`wrangler` 4.118.0** (was 4.104.0). The older version's bundled `workerd`
  binary is too old to run this repo's `compatibility_date`
  (`2026-07-05`) at all — `wrangler dev --local` refuses to start,
  citing `2026-06-30` as the newest date it supports. `npm install` alone
  fixes this by pulling the pinned version in `package.json`.
- **`.claude/launch.json`**, including the `preview-local` config
  (`bash tool/preview_web.sh serve`, port 8788) — this used to be gitignored
  and invisible to git entirely; now tracked.

If `npm install` reports pending/blocked install scripts for `workerd`,
`esbuild`, or `fsevents`, approve them — `workerd`'s postinstall is what
actually places the updated runtime binary:

```bash
npm approve-scripts workerd esbuild fsevents
```

## Needs a one-time manual step on the new machine (not transferable via git)

**Local D1 has no schema until you apply migrations to it.** This bit us
directly tonight — chat returned a raw `500` locally
(`table conversation_logs has no column named visit_id`) because the local
Miniflare D1 instance starts completely empty. Fix, once, after first boot:

```bash
npx wrangler d1 migrations apply mymate2_db --local
```

This only touches the local, throwaway D1 emulation under `.wrangler/state/`
— never the real database.

## Needs a value transferred securely (do not paste into chat, a doc, or git)

**`.env`**, for `npm run build:web` / `npm run deploy` only (not needed for
local-only preview). One line:

```
APP_SECRET=<the same 64-char hex value already set as the mymate-v2 Worker's
APP_SECRET secret in Cloudflare>
```

If that value isn't available from wherever it's already stored (password
manager, etc.), it is **not recoverable from Cloudflare** — Worker secrets
are write-only. The only way back at that point is generating a new one and
setting it in both places (`wrangler secret put APP_SECRET` and this file),
which invalidates the old one — not something to do casually since it also
means rebuilding and redeploying the client.

## Auto-created, zero action needed

- **`.dev.vars`** — `tool/preview_web.sh` writes this itself on first run
  with a throwaway, non-production `APP_SECRET`. Never needs to match the
  real one; local and the local worker only need to agree with each other.

## To also test the admin pages locally

The script only auto-creates `APP_SECRET`. For `/admin/*` to work locally
too (rather than "Admin access is not configured"), add a line to
`.dev.vars` yourself after its first run, then restart the server:

```
ADMIN_TOKEN=<anything>
```

## Running it

```bash
npm run preview:local          # build + serve the full stack on :8788
npx wrangler d1 migrations apply mymate2_db --local   # first time only
```

Then `http://localhost:8788` (or `/c/<character>` for a specific one).
`Ctrl-C` stops it; rerunning `npm run preview:local` rebuilds from scratch.
For a faster restart that skips the Flutter rebuild (e.g. after only editing
`.dev.vars`): `SKIP_BUILD=1 bash tool/preview_web.sh serve`.

## What this local setup cannot do, by design

From `tool/preview_web.sh`'s own docs — not bugs, not things to try to fix:

- **Real AI replies.** The worker calls OpenAI/Inworld with API keys this
  setup does not have. `/api/chat` authenticates correctly and then fails at
  the upstream call — the character will say it's "having trouble thinking."
  That is expected here, not a sign of a real bug.
- **Google Sign-In** — needs `GOOGLE_CLIENT_SECRET` and a registered
  redirect URI.
- **Anything reading real production data** — local D1 starts empty aside
  from whatever you generate by clicking around locally.
