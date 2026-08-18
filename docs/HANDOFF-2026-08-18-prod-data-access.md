# Handoff — reading production analytics from a Claude Code session

**Date:** 2026-08-18 · **Branch:** `claude/git-latest-sync-kkfyab`

Read this before trying to reach production data. The obvious route does not
work and the reason is not fixable from inside a session.

## Cloudflare's API is blocked, and a new session will not change that

`api.cloudflare.com` is not on the sandbox's egress allowlist. Every attempt —
`wrangler d1 execute --remote`, raw `curl`, any SDK — dies at the proxy:

```
api.cloudflare.com:443   connect_rejected
"gateway answered 403 to CONNECT (policy denial or upstream failure)"
```

The request never leaves the container, so **no token, scope, or expiry changes
anything.** `curl -sS "$HTTPS_PROXY/__agentproxy/status"` shows `selective:
false` with no Cloudflare host permitted. This was retried across two container
restarts with identical results.

It is a property of the **environment's network policy**, not of the session.
A new session in the same environment inherits the same block. The only fix is
to add `api.cloudflare.com` (and `sparrow.cloudflare.com`, which wrangler also
calls) to the environment's allowlist at claude.ai/code → environments — see
https://code.claude.com/docs/en/claude-code-on-the-web.

**But you almost certainly do not need it.** See below.

## What works instead: the worker's own admin API

`logs.deeplovepoems.com` and `chat.deeplovepoems.com` are ordinary public
hostnames and are reachable. The worker serves the whole analytics surface
itself, gated by HTTP Basic auth whose password is the worker's `ADMIN_TOKEN`
(the username is ignored — see `requireAdminAuth` in `backend/src/worker.js`).

```bash
curl -u "admin:$MYMATE_ADMIN_TOKEN" https://logs.deeplovepoems.com/api/admin/first30
```

Endpoints (all `GET`, all under `/api/admin/`): `visits`, `sessions`, `first30`,
`referrals`, `logs`, `conversations`, `transcript`, `visit-chat`, `visit-detail`,
`delivery`, `deploys`, `export`, `export-all`.

`export-all?hours=N` is the useful one for analysis — it dumps raw rows from
`site_visits`, `conversation_logs`, `referral_visits` and `deploy_log` for the
window, capped at 50,000 rows per table (`X-Export-Truncated` says if you hit
it). Aggregate locally rather than trying to get SQL to the remote D1.

### Getting the token

**It is not in this repo and must not be committed.** Ask the user for it and
export it for the command only:

```bash
MYMATE_ADMIN_TOKEN='...' node tool/prod_eval.mjs 24
```

Note for whoever asks: as of 2026-08-18 production's `ADMIN_TOKEN` was the same
value that appeared in a `.dev.vars` screenshot in chat, and the user was asked
to rotate it. If a 401 comes back, that rotation happened — ask for the new
value, do not assume the endpoint is broken.

## `tool/prod_eval.mjs`

Fetches the window and prints the funnel. Reproduces the 2026-08-18 numbers
exactly. Two corrections are baked into it because both have already produced a
confidently wrong answer:

- **`duration_ms` is wall clock, not attention.** 91% of exits are
  `exit_mode='hidden'` — backgrounded, not closed — and the clock keeps running
  in a browser nobody is looking at. Reading it as attention turns a flat
  **5.2s** median into a triumphant **32.7s**. Use `visible_ms`.
  *The admin pages still bucket on `duration_ms` and are wrong in exactly this
  way — an unfixed known issue.*
- **`character_tap` is not a tap.** It fires on landing on `/c/<character>`, in
  the same breath as `entry_shown`. It means "reached a character screen".
  Engagement is `input_typed` / `starter_tap` / `first_message`, nothing else.

## What the data said on 2026-08-18

24h, 7,464 rows, 417 real visits (TH is the developer, excluded).

| | |
|---|---|
| `entry_shown` → `entry_tap` | **3 / 316 = 0.9%** |
| Prior baseline (auto-playing screen, 30d, 3,490 visits) | **0.95% engaged** |
| Visible time on a character screen, median | **5.2s** (pre-1.7.1: 5.5s) |
| Entry card on screen at | median 1.9s, p90 4.2s |
| Left before the card could appear | 13% |
| Engaged after tapping in | **2 of 3** |
| Clients | Facebook 300 · Instagram 89 · browser 28 |
| Entry rate by client | browser 3.8% · Instagram 1.5% · Facebook 0.4% |

**Reading:** the card was genuinely on screen for 87% of people, so 99% are
*declining* a visible one-tap ask, not missing it. Lowering the bar from "type
something to a stranger" to "press one button" moved the rate from 0.95% to
0.9% — i.e. not at all. The bottleneck is not the difficulty of the ask; this
traffic arrives with no intention of interacting. The lever is upstream, in who
the campaign delivers and what the ad promises before the tap.

The counter-signal, worth keeping: 2 of the 3 who did tap went on to send a
message, one staying 92 visible seconds. Opting in predicts depth almost
perfectly. n=3 — a direction, not a rate.

Delivery is healthy (386/387 `app_ready` clean, one `splash_cap_timeout`), so
nothing is broken. People are choosing to leave.

## Open items

- **Rotate `ADMIN_TOKEN`** (exposed in a screenshot) and `GOOGLE_CLIENT_SECRET`.
  If `APP_SECRET` is rotated, the worker secret and the next `build_web.sh` must
  ship the same new value together or every `/api/chat` fails "Invalid
  signature" while the site looks healthy.
- **Revoke the Cloudflare token** `cfat_lUa…` — posted in chat, never
  authenticated, and unnecessary now.
- **Fix the admin dwell buckets** to read `visible_ms` instead of `duration_ms`.
- Standing rule from an earlier mistake: **do not infer remote state from
  local.** Advice written from a local D1 inspection once contradicted the real
  remote and would have caused the failure it warned about.
