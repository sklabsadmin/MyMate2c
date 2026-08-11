# Deploy runbook — analytics instrumentation + quick-reply cues

Branch: `feat/quick-reply-attention-cues`

**This deploy needs a D1 schema change applied FIRST.** That is the only unusual
step; everything else is the normal `npm run deploy`. Read step 1 before
starting — getting the order wrong fails silently.

---

## What is changing

| Layer | Change |
|---|---|
| **D1 schema** | 5 new nullable columns on `site_visits` |
| **Worker** | New event types, corrected admin queries, new admin columns |
| **Web client** | New beacon events (`hide`/`show`/`strip_rotate`), viewport height, nav type |

New columns: `viewport_h`, `visible_ms`, `hide_count`, `exit_mode`, `nav_type`.
All nullable, no backfill. SQLite adds a nullable column by updating the table
header rather than rewriting rows, so this is near-instant and does not lock
anything meaningful.

---

## Before you start

- [ ] `wrangler` authenticated against the Cloudflare account that owns `mymate2_db`
- [ ] `APP_SECRET` present in `.env` (gitignored) or exported in the shell.
      `tool/build_web.sh` refuses without it. It must be the SAME value the
      worker has, or every `/api/chat` call fails "Invalid signature" and chat
      is dead while the site looks fine.
- [ ] On branch `feat/quick-reply-attention-cues`, working tree clean.
      `tool/preflight_deploy.sh` refuses on a dirty tree — it builds from the
      working tree, not from HEAD.
- [ ] `wrangler.jsonc` names the worker `mythoslive`. Preflight checks this and
      refuses otherwise; do not override it.

---

## Step 1 — Apply the migrations to the REMOTE database

Run both, in this order:

```bash
npx wrangler d1 execute mymate2_db --remote --file backend/migrations/0008_viewport_height.sql
npx wrangler d1 execute mymate2_db --remote --file backend/migrations/0009_exit_mode.sql
```

**This must happen before `npm run deploy`.** `npm run deploy` does NOT apply
migrations — the deploy script never touches D1.

Adding nullable columns is invisible to the worker currently running in
production, which never references them. So there is no window where the live
site is broken; it is safe to run these minutes or hours before deploying.

### Do NOT use `wrangler d1 migrations apply`

This project has never used wrangler's migration system and has no
`d1_migrations` tracking table. That command would treat all nine migrations as
unapplied and re-run them from the start. Migrations 0001–0006 are
`IF NOT EXISTS` and would no-op, but 0007/0008/0009 are `ALTER TABLE ADD COLUMN`
and are not idempotent — it would fail partway with "duplicate column name" and
could leave the schema half-applied.

Apply by file, as above. That is how every previous migration on this project
was applied.

---

## Step 2 — Verify the schema before deploying

```bash
npx wrangler d1 execute mymate2_db --remote \
  --command "SELECT name FROM pragma_table_info('site_visits');"
```

All five must be present:

```
viewport_h   visible_ms   hide_count   exit_mode   nav_type
```

**If any are missing, stop.** Do not deploy. Re-run the missing migration.

---

## Step 3 — Deploy

```bash
npm run deploy
```

This runs, in order: preflight checks → web build (release) → `wrangler deploy`
→ deploy verification → smoke test → domain assertions. Any step failing aborts
the rest.

---

## Step 4 — Verify data is actually flowing

Give it a few minutes of real traffic, then:

```bash
npx wrangler d1 execute mymate2_db --remote --command \
  "SELECT event, COUNT(*) n FROM site_visits \
    WHERE created_at >= datetime('now','-1 hour') GROUP BY event ORDER BY n DESC;"
```

You should see the new event names appearing alongside the existing ones:

- `hide` and `show` — visibility transitions
- `strip_rotate` — the quick-reply strip changing what it offers

And the new columns populated:

```bash
npx wrangler d1 execute mymate2_db --remote --command \
  "SELECT COUNT(*) total, COUNT(viewport_h) with_height, COUNT(nav_type) with_nav \
     FROM site_visits WHERE event='arrive' AND created_at >= datetime('now','-1 hour');"
```

`with_height` and `with_nav` should be close to `total`. Rows from before this
deploy will have NULLs — that is correct, not a fault.

Then open `/admin/visits` and `/admin/sessions` and confirm the pages render.

---

## If the order gets reversed

If the worker ships before the migrations, **the failure is silent**. The insert
is wrapped in try/catch:

```js
} catch (error) {
    console.error(JSON.stringify({ event: "site_visit_log_failed", error: error.message }));
}
```

So the site keeps working perfectly and **all visit logging simply stops**. The
only symptom is `site_visit_log_failed` in the worker logs and a suspiciously
empty admin page. Fix by applying the migrations — no redeploy needed, logging
resumes on the next request.

Check with:

```bash
npx wrangler tail mythoslive --format pretty | grep site_visit_log_failed
```

---

## Rollback

**The worker** rolls back normally — redeploy the previous version. See
`tool/rollback_hint.sh`.

**The schema does not need rolling back.** The columns are additive and nullable,
and older worker code never references them, so leaving them in place is
harmless. Treat the schema change as forward-only: SQLite's `DROP COLUMN` has
restrictions and D1's support for it varies, so do not attempt to remove them as
part of an incident response.

---

## One-line summary for the deploy log

> Applied D1 migrations 0008 + 0009 (5 nullable columns on `site_visits`), then
> deployed `feat/quick-reply-attention-cues`. Migrations must precede the
> worker; `npm run deploy` does not apply them.
