#!/usr/bin/env bash
#
# Confirms the custom domains are still attached to THIS worker.
#
# Why this exists, and why verify_deploy.sh is not enough:
#
# Custom domains are account-scoped and bind to exactly one worker at a time.
# Every `wrangler deploy` whose config declares them RE-ASSERTS them, which
# takes them from whoever held them — silently, reported as an ordinary
# "(custom domain)" line in the deploy output. See
# github.com/cloudflare/workers-sdk/issues/13925. Anything that deploys this
# repo — another branch, a CI runner, a Workers Builds git connection — can
# therefore walk off with production without touching this machine.
#
# On the night this was written, verify_deploy.sh passed honestly at 21:29 and
# the domains were taken at 21:29:01. It compares the served main.dart.js
# against the local build, which proves the right FILE is live on the hostname
# and says nothing about which worker owns that hostname a second later. The
# hijack then served a working-looking app on every hostname for 19 hours while
# chat was dead, so uptime monitoring would not have caught it either.
#
# There is no wrangler command for this; the account-level domains API is the
# only authority.
#
# Credentials, in order of preference:
#   CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID   (Workers Scripts:Read),
#       read from .env if present. Preferred: no expiry, works headless.
#   otherwise the `wrangler login` OAuth token, which CAN read this endpoint —
#       an earlier version of this script asserted it could not, and so printed
#       SKIPPED through three deploys for want of a token it never needed.
#
# Usage: bash tool/assert_domains.sh              # check now
#        bash tool/assert_domains.sh --delay 300  # wait 5 min, then check
#
# The delayed form matters: a git-triggered build lands whenever it lands,
# which is routinely after the deploy script has finished and declared success.
set -euo pipefail

cd "$(dirname "$0")/.."

DELAY=0
if [[ "${1:-}" == "--delay" ]]; then
  DELAY="${2:?--delay needs seconds}"
fi

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

WORKER="$(sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' wrangler.jsonc | head -1)"

# The hostnames to defend. Read from wrangler.jsonc while they are still
# declared there; once they are removed from the config (so that deploying can
# no longer claim them) set EXPECTED_DOMAINS instead — this check must keep
# working after that change, since that is precisely when nothing else is
# watching them.
if [[ -n "${EXPECTED_DOMAINS:-}" ]]; then
  read -r -a DOMAINS <<< "$EXPECTED_DOMAINS"
else
  read -r -a DOMAINS <<< "$(sed -n 's/.*"pattern"[[:space:]]*:[[:space:]]*"\([^"]*\)".*custom_domain.*/\1/p' wrangler.jsonc | tr '\n' ' ')"
fi

if [[ ${#DOMAINS[@]} -eq 0 ]]; then
  echo "==> no custom domains to check (none in wrangler.jsonc, EXPECTED_DOMAINS unset)."
  echo "    If the domains were removed from config on purpose, set EXPECTED_DOMAINS"
  echo "    so this check keeps guarding them:"
  echo "      EXPECTED_DOMAINS=\"chat.deeploveechoes.com chat.deeplovepoems.com logs.deeplovepoems.com\""
  exit 0
fi

# Credentials. A scoped API token is preferred — it does not expire and works
# where wrangler is not logged in. But it is not required: the `wrangler login`
# OAuth token CAN read workers/domains, contrary to what this script first
# assumed. That wrong assumption made this check print SKIPPED after three
# consecutive deploys while ownership was verified by hand each time, which is
# the failure mode a guard is supposed to remove.
#
# The OAuth token expires roughly every twenty minutes and only a wrangler
# invocation renews it, so a 4xx here is routine rather than a real failure —
# refresh and retry once before believing it. Expiry has been observed as both
# HTTP 400 and HTTP 200 with success:false, hence checking the body, not a code.
WRANGLER_CONFIG="${HOME}/Library/Preferences/.wrangler/config/default.toml"
[[ -f "$WRANGLER_CONFIG" ]] || WRANGLER_CONFIG="${HOME}/.wrangler/config/default.toml"

oauth_token() {
  [[ -f "$WRANGLER_CONFIG" ]] || return 1
  sed -n 's/^oauth_token[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$WRANGLER_CONFIG" | head -1
}

CF_TOKEN="${CLOUDFLARE_API_TOKEN:-$(oauth_token || true)}"
CF_ACCOUNT="${CLOUDFLARE_ACCOUNT_ID:-}"
if [[ -z "$CF_ACCOUNT" ]]; then
  # `|| true` is load-bearing: under `set -euo pipefail` a failing whoami — which
  # is exactly what a broken or unrenewable token produces — would abort the
  # script here with no output at all. Exiting 1 in silence is worse than the
  # SKIPPED this replaced, because nothing tells you the check did not run.
  CF_ACCOUNT="$(npx wrangler whoami 2>/dev/null \
    | sed -n 's/.*│[[:space:]]*\([0-9a-f]\{32\}\)[[:space:]]*│.*/\1/p' | head -1 || true)"
fi

if [[ -z "$CF_TOKEN" || -z "$CF_ACCOUNT" ]]; then
  echo "==> SKIPPED: ownership of the custom domains was NOT verified." >&2
  echo "    No credentials: set CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID, or run" >&2
  echo "    'npx wrangler login' so the OAuth token can be used instead." >&2
  echo "    Until then nothing detects another worker taking these hostnames:" >&2
  printf '      %s\n' "${DOMAINS[@]}" >&2
  # Deliberately not a failure: a blocked deploy is its own outage. Loud so it
  # does not become permanent.
  exit 0
fi

if [[ "$DELAY" -gt 0 ]]; then
  echo "==> waiting ${DELAY}s before re-checking domain ownership"
  sleep "$DELAY"
fi

api_ok() {
  printf '%s' "$1" | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  try { process.exit(JSON.parse(s).success ? 0 : 1); } catch { process.exit(1); }
});'
}

fetch_domains() {
  curl -sS --max-time 30 \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT}/workers/domains"
}

echo "==> checking which worker owns each custom domain"
resp="$(fetch_domains)"

if ! api_ok "$resp"; then
  # Only worth retrying when the token is the expiring kind.
  if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    npx wrangler whoami >/dev/null 2>&1 || true
    CF_TOKEN="$(oauth_token || true)"
    resp="$(fetch_domains)"
  fi
fi

if ! api_ok "$resp"; then
  echo "ERROR: workers/domains API call failed. Response:" >&2
  printf '%s\n' "$resp" >&2
  exit 1
fi

bad=0
for d in "${DOMAINS[@]}"; do
  owner="$(printf '%s' "$resp" | node -e '
    let s="";process.stdin.on("data",c=>s+=c).on("end",()=>{
      const want=process.argv[1];
      const hit=(JSON.parse(s).result||[]).find(r=>r.hostname===want);
      process.stdout.write(hit ? (hit.service||"") : "<unattached>");
    });' "$d")"
  if [[ "$owner" == "$WORKER" ]]; then
    echo "    ok   $d -> $owner"
  else
    echo "    LOST $d -> ${owner:-<none>} (expected $WORKER)" >&2
    bad=1
  fi
done

if [[ "$bad" -ne 0 ]]; then
  echo >&2
  echo "ERROR: production hostnames are not served by '$WORKER'." >&2
  echo "       Something else deployed and took them. Find it before redeploying —" >&2
  echo "       redeploying takes them back but does not stop it happening again," >&2
  echo "       and it will keep happening on every one of its builds." >&2
  echo "       Check Workers & Pages -> each worker -> Settings -> Builds for a" >&2
  echo "       git connection, and the branches whose wrangler.jsonc still" >&2
  echo "       declares these hostnames." >&2
  exit 1
fi

echo "==> ok: all ${#DOMAINS[@]} custom domains served by '$WORKER'"
