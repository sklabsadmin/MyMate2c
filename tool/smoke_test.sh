#!/usr/bin/env bash
#
# Post-deploy smoke test: exercises the live site the way the app does, so a
# wrong or missing secret fails the deploy instead of reaching a visitor.
#
# Everything this checks has already shipped broken at least once, and every
# time it surfaced as the same sentence in the chat window — "<character> is
# having trouble thinking right now" — because the client renders any backend
# failure that way. Four different causes, one symptom, each needing its own
# investigation from scratch:
#
#   * the worker's APP_SECRET stopped matching the one baked into the client
#     (a rename left the domains on an older worker; later, a rotation)
#   * INWORLD_API_KEY was set to a key from the wrong workspace
#   * ADMIN_TOKEN was rotated and the admin pages locked everyone out
#   * a deploy shipped a client with no secret in it at all
#
# verify_deploy.sh cannot catch any of these: it compares the served
# main.dart.js against the local build, which says the right *file* is live but
# nothing about whether the secrets that file depends on actually work. This
# signs a real request the way the app signs one, which is the only check that
# exercises the client/worker contract end to end.
#
# Note on Cloudflare secrets: `wrangler secret put` does not take effect until
# the next deploy on this setup. If a secret was just rotated, deploy before
# running this or it will report the previous value's behaviour.
#
# Usage: bash tool/smoke_test.sh <url>   (e.g. https://chat.deeplovepoems.com)
set -euo pipefail

cd "$(dirname "$0")/.."

URL="${1:?Usage: smoke_test.sh <deployed-url>}"
URL="${URL%/}"

# Whichever Python this machine actually has. Hard-coding `python3` broke the
# deploy on Windows: there is no python3 there, and the name resolves to the
# Microsoft Store's installer stub, which prints "Python was not found" and
# exits non-zero — so a successful, verified deploy reported as a failure at
# the last step. `py` is the Windows launcher; `python` is Python 3 on any
# machine new enough to run this project.
PYTHON=""
for candidate in python3 python py; do
  if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' \
       >/dev/null 2>&1; then
    PYTHON="$candidate"
    break
  fi
done
if [[ -z "$PYTHON" ]]; then
  echo "ERROR: no Python 3 found (tried python3, python, py)." >&2
  echo "       The signed-request checks cannot run without it, and a smoke" >&2
  echo "       test that skips them is not worth reporting a pass on." >&2
  exit 1
fi

# Cloudflare answers a default curl user-agent with 403 error 1010, which looks
# exactly like an auth failure if you are not expecting it.
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

# Remember whether the caller exported one before .env gets a say. `set -a; .
# ./.env` assigns unconditionally, so without this the file silently overrides
# the environment — which made the first negative test of this script pass:
# a deliberately wrong secret was replaced by the correct one from .env before
# anything was signed, and the run reported everything healthy.
# tool/build_web.sh carries the same guard for the same reason.
CALLER_APP_SECRET="${APP_SECRET:-}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

if [[ -n "$CALLER_APP_SECRET" ]]; then
  APP_SECRET="$CALLER_APP_SECRET"
fi

if [[ -z "${APP_SECRET:-}" ]]; then
  echo "ERROR: APP_SECRET is not set (looked at the environment and .env)." >&2
  echo "       Cannot sign a request without it, so the check that matters" >&2
  echo "       most cannot run. Refusing to report a pass." >&2
  exit 1
fi

fail=0
note() { printf '  %-34s %s\n' "$1" "$2"; }

# Shared with verify_deploy.sh: both run after the deploy, so both need to
# offer the undo. See tool/rollback_hint.sh for why it is printed, not run.
# shellcheck source=tool/rollback_hint.sh
. "$(dirname "$0")/rollback_hint.sh"

# --- the app's own contract -------------------------------------------------
# Signs exactly as openai_service.dart does: HMAC-SHA256(secret, body+timestamp),
# hex, sent as x-signature with the millisecond timestamp in x-timestamp.
chat_check() {
  local character="$1" scenario="$2" label="$3"
  local out status body
  out="$(APP_SECRET="$APP_SECRET" URL="$URL" UA="$UA" CHARACTER="$character" \
         SCENARIO="$scenario" "$PYTHON" - <<'PY'
import hashlib, hmac, json, os, subprocess, sys, time

secret = os.environ["APP_SECRET"]
body = json.dumps({"messages": [{"role": "user", "content": "ping"}]},
                  separators=(",", ":"))
ts = str(int(time.time() * 1000))
sig = hmac.new(secret.encode(), (body + ts).encode(), hashlib.sha256).hexdigest()

proc = subprocess.run([
    "curl", "-sS", "--max-time", "120", "-X", "POST",
    os.environ["URL"] + "/api/chat", "-A", os.environ["UA"],
    "-H", "Content-Type: application/json",
    "-H", "x-signature: " + sig,
    "-H", "x-timestamp: " + ts,
    # Marked synthetic so these never land in conversation_logs and skew the
    # funnel — the worker checks this header and skips persisting.
    "-H", "x-synthetic-test: 1",
    "-H", "x-user-id: smoke-test",
    "-H", "x-chat-id: smoke-test",
    "-H", "x-character-id: " + os.environ["CHARACTER"],
    "-H", "x-scenario: " + os.environ["SCENARIO"],
    "-d", body, "-w", "\n%{http_code}",
], capture_output=True, text=True)

raw = proc.stdout
code = raw.rsplit("\n", 1)[-1].strip() if "\n" in raw else "000"
payload = raw.rsplit("\n", 1)[0]
try:
    reply = json.loads(payload)["choices"][0]["message"]["content"]
    print(code + "\t" + reply.replace("\n", " ")[:60])
except Exception:
    print(code + "\t" + payload.replace("\n", " ")[:160])
PY
  )"
  status="${out%%$'\t'*}"
  body="${out#*$'\t'}"

  if [[ "$status" == "200" ]]; then
    note "$label" "ok — \"$body\""
    return 0
  fi

  fail=1
  note "$label" "FAILED (HTTP $status) $body"
  case "$status:$body" in
    401:*signature*)
      echo "       -> The worker's APP_SECRET does not match the one baked into" >&2
      echo "          the live client. Rebuild and redeploy together, or restore" >&2
      echo "          the worker secret to the value in .env." >&2 ;;
    502:*|503:*)
      echo "       -> Upstream AI call failed. For $CHARACTER this is usually a" >&2
      echo "          bad or unauthorised provider key. /admin/logs records the" >&2
      echo "          provider's own status code." >&2 ;;
  esac
  return 0
}

echo "==> smoke testing ${URL}"

# One OpenAI-backed character and one Inworld-backed one: they use different
# keys and different code paths, and each has failed independently.
chat_check "penelope" "Penelope (Queen of Ithaca)" "chat via OpenAI"
chat_check "oedipus"  "Oedipus (King of Thebes)"   "chat via Inworld"

# --- everything else --------------------------------------------------------
# Cache-busted, and compared against the local build rather than just echoed.
#
# Without the unique query this read the edge's cached copy: on 2026-08-10 it
# reported 1.6.2+58 for a deploy that had actually shipped 1.6.3+59, i.e. it
# said a release had not landed when it had. A version-only change is invisible
# to verify_deploy.sh (which compares main.dart.js), so this is the ONLY check
# that sees one — printing a stale value here means nothing checks it at all.
#
# Comparing to build/web/version.json is what turns it from a report into a
# test. Only possible when run right after a build; when that file is absent
# (smoke-testing a URL from elsewhere) fall back to reporting what is served.
version="$(curl -s --max-time 30 -A "$UA" "$URL/version.json?smoke=$$-$(date +%s)" || true)"
if [[ "$version" != *'"version"'* ]]; then
  fail=1
  note "version.json" "FAILED — not served"
elif [[ -f build/web/version.json ]] && [[ "$version" != "$(cat build/web/version.json)" ]]; then
  fail=1
  note "version.json" "FAILED — served version is not the local build
       served: $(printf '%s' "$version" | tr -d '{}\"' | tr ',' ' ')
       built : $(tr -d '{}"' < build/web/version.json | tr ',' ' ')
       Either the edge is still serving the previous copy (re-run in a minute)
       or the build did not pick up the pubspec version."
else
  note "version.json" "$(printf '%s' "$version" | tr -d '{}"' | tr ',' ' ')"
fi

# Unauthenticated, so this only proves the admin surface is reachable AND
# refusing entry. A 503 means ADMIN_TOKEN is missing entirely, which locks the
# logs away exactly when something has gone wrong and you need them.
admin="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -A "$UA" "$URL/admin" || true)"
case "$admin" in
  401) note "admin auth" "ok — challenges for credentials" ;;
  503) fail=1; note "admin auth" "FAILED — ADMIN_TOKEN not configured on the worker" ;;
  *)   fail=1; note "admin auth" "FAILED — expected 401, got $admin" ;;
esac

# The signature gate itself. If this ever returns 200 the endpoint is an open
# proxy to our OpenAI account, which costs money rather than time.
unsigned="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -A "$UA" \
            -X POST "$URL/api/chat" -H 'content-type: application/json' \
            -d '{"messages":[]}' || true)"
if [[ "$unsigned" == "401" ]]; then
  note "unsigned request refused" "ok"
else
  fail=1
  note "unsigned request refused" "FAILED — expected 401, got $unsigned"
fi

echo
if [[ "$fail" -ne 0 ]]; then
  echo "SMOKE TEST FAILED — the deploy is live but not working. See above." >&2
  rollback_hint
  exit 1
fi
echo "==> smoke test passed: ${URL} is serving and its secrets line up"
