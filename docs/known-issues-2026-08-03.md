# Known issues — for the next code-gen session

Written after a verification pass on `main` at commit `3b9609e`. Each item
below was reproduced and root-caused, not just reported — file, mechanism,
and current behavior are all confirmed against the live code and (where
noted) the live Cloudflare deployment / D1 database.

This list deliberately excludes three other complaints from this session
(Google profile picture not showing after sign-in, Settings not returning to
the dashboard, Oedipus's chat replies taking ~18s vs ~2–4s for every other
character) — those were never independently reproduced or diagnosed, only
relayed from the user's report. Treat them as separate investigation tasks,
not confirmed bugs, until someone reproduces the actual cause.

---

## 1. `logs.deeplovepoems.com` doesn't fully lock down to admin tools

**Severity:** low-moderate. Not a data leak — real endpoints are gated
correctly — but the domain is not doing the one job it exists for.

**Where:** [`wrangler.jsonc`](../wrangler.jsonc) (`run_worker_first`, lines
39–63) and [`backend/src/worker.js`](../backend/src/worker.js) (hostname
guard, lines 121–128).

**Mechanism:**

`logs.deeplovepoems.com` is a Cloudflare Workers custom domain pointed at the
same worker as `chat.deeploveechoes.com` / `chat.deeplovepoems.com`. A
hostname guard in `worker.js` is supposed to redirect every path on
`logs.*` except `/admin` and `/api/admin/*` back to `/admin`:

```js
if (url.hostname.startsWith("logs.")) {
    if (!url.pathname.startsWith("/admin") && !url.pathname.startsWith("/api/admin")) {
        return Response.redirect(`${url.origin}/admin`, 302);
    }
}
```

The problem: this guard only runs for requests that reach the worker at all.
Cloudflare Workers Assets with `run_worker_first` is **one shared path list
across every custom domain bound to the worker** — there is no per-hostname
form. `run_worker_first` currently lists `/api/*`, `/auth/*`, `/admin`,
`/admin/*`, and `/c/*`. Any path *not* on that list (e.g. `/dashboard`,
`/settings`, `/`) is served directly by the static asset handler on **every**
domain, `logs.*` included, and the guard above never executes.

**Confirmed behavior (reproduced):**
- `https://logs.deeplovepoems.com/admin` → 401 without auth ✓ (correctly gated)
- `https://logs.deeplovepoems.com/api/admin/visits` → 401 without auth ✓ (correctly gated)
- `https://logs.deeplovepoems.com/dashboard` → **200, serves the full app** ✗ (should redirect to `/admin`)

**Why it wasn't fixed on the spot:** the obvious fix is routing `"/*"` in
`run_worker_first` so every request on every domain reaches the worker. But
the worker's `fetch` handler has no fallback to `env.ASSETS.fetch(request)`
for the normal case — it was written assuming most paths never reach it. A
bare `"/*"` change would make the worker responsible for serving every static
asset (JS, images, fonts) on the **live, revenue-relevant** `chat.*` domains
too, and untested, that risks breaking asset serving there. This needs to be
done deliberately, with a real fallback path added and tested against
`chat.deeploveechoes.com` before it ships — not as a quick patch.

**Suggested fix, for whoever picks this up:**
1. Add `"/*"` to `run_worker_first` in `wrangler.jsonc`, replacing the
   current explicit list (the comment there already documents why).
2. At the very end of the worker's `fetch` handler (after every other
   `if` block, right before the function would otherwise return
   undefined), add: `return env.ASSETS.fetch(request);`
3. Test on a preview/staging build first: confirm `chat.deeploveechoes.com`
   still serves `main.dart.js`, images, and every existing route exactly as
   before, *then* confirm `logs.deeplovepoems.com/dashboard` now redirects.
4. Redeploy and re-run the four checks above.

---

## 2. Admin visits page doesn't show `send_failed` / latency / viewport data

**Severity:** low. No data is lost — everything is being written to D1
correctly, confirmed live via `pragma_table_info`. It's purely invisible.

**Where:** [`backend/src/worker.js`](../backend/src/worker.js) — the
`/api/admin/visits` handler (~line 202) and `adminVisitsPageHtml()`
(~line 2422).

**What exists but isn't surfaced:**

- `site_visits.failure_reason` — set when a `send_failed` funnel event
  fires (a message was sent and got nothing usable back; `"network"` means
  the request never reached the worker at all, so there's no
  `conversation_logs` row for it either — this event is the *only* record
  that the send happened).
- `site_visits.viewport_w` — window width at arrival, meant to answer
  whether wide-viewport (desktop) visitors bounce harder, since the app is a
  portrait-phone layout.
- `conversation_logs.latency_ms` — wall-clock time for each AI reply, on
  both the direct-OpenAI path and the Inworld path.
- `conversation_logs.visit_id` — joins a chat message back to the browser
  session (`site_visits.visit_id`) that sent it, which is what makes "how
  many messages did this session send before quitting" answerable.

None of the four current `/admin/visits` queries (`bySource`, `byDay`,
`recent`, `funnel`) select any of these columns. The "Engaged" column added
for `input_typed`/`starter_tap` (same page) is the template to follow —
that's the last column that was added successfully.

**Suggested additions, roughly in priority order:**
1. A **failure_reason breakdown** — count grouped by reason, filtered to
   `event = 'send_failed'`, over the same date-range selector the page
   already has. This tells you what fraction of failures are `"network"`
   (invisible otherwise) vs. specific HTTP/model failures.
2. **Average `latency_ms` per character**, from `conversation_logs`,
   joined or filtered the same way the existing funnel query filters by
   date. Useful for spotting a character (or an engine — Inworld vs.
   OpenAI) that's slow enough to cost conversations.
3. **Viewport distribution** on the `bySource` table or its own small
   table — how many arrivals are under vs. over some phone-width threshold.

This is presentation-only work — the data model and collection are already
correct and live.

---

## 3. App version will be rejected by the App Store

**Severity:** low today (web-only deploys don't read this), but a real
blocker whenever a native build is next submitted.

**Where:** [`pubspec.yaml`](../pubspec.yaml) line 19: `version: 1.6.2+58`.
(Was `1.5.55+55` when this was written; the minor has moved 5 -> 6 across
several web deploys since, which changes nothing here — see below.)

**Mechanism:** app stores compare version strings component-by-component as
integers, not as whole numbers or semver. `1.6.2` has a minor version of
`6`, which is *less than* the live App Store version's minor of `49`
(`1.49.4`) — so `1.6.2` reads as an **older** version than what's live, and
the store will reject the submission outright, regardless of the build
number.

Note that ordinary patch bumps do not walk out of this: going 1.6.1 -> 1.6.2
raises the patch, while the comparison fails on the minor. Only a deliberate
jump past 49 fixes it, so this issue survives every routine bump and will
still be here at the next submission unless someone acts on it on purpose.

**Fix:** bump the minor version above 49 — e.g. `1.50.x` — before any native
build is submitted. Not urgent for web deploys, but should not be left
unnoticed until the next store submission fails.
