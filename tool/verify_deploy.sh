#!/usr/bin/env bash
#
# Runs immediately after `wrangler deploy`. Confirms the live site is
# actually serving the file we just built, not a stale one.
#
# What this guards against: `wrangler deploy` reported success, and
# build/web/main.dart.js on disk was correct (tool/build_web.sh already
# proved the secret is baked in) — but the file Cloudflare actually served
# afterward was a *different*, older build, with a different (or missing)
# secret baked in. Every real chat request then failed "Invalid signature",
# while any test that hand-signs a request directly against the worker
# (bypassing the shipped bundle) stays green throughout, because it never
# exercises the actual client code users are running. That gap is exactly
# how this went unnoticed for an evening: server-side checks all passed.
#
# The likely cause was process, not platform: Workers Assets skips
# re-uploading files it believes are unchanged, and a bare `wrangler deploy`
# (skipping tool/build_web.sh) re-publishes whatever happens to be sitting in
# build/web at that moment. A few quick backend-only iterations were done
# that way tonight. This check does not depend on diagnosing the exact cause
# staying fixed — it just makes the symptom impossible to ship unnoticed
# again, from here on, regardless of which command produced the deploy.
#
# Usage: bash tool/verify_deploy.sh <url>   (e.g. https://chat.deeploveechoes.com)
set -euo pipefail

cd "$(dirname "$0")/.."

URL="${1:?Usage: verify_deploy.sh <deployed-url>}"
LOCAL_FILE="build/web/main.dart.js"

# Shared with smoke_test.sh: both run after the deploy, so a failure here is
# also a failure that is already live. See tool/rollback_hint.sh.
# shellcheck source=tool/rollback_hint.sh
. "$(dirname "$0")/rollback_hint.sh"

if [[ ! -f "$LOCAL_FILE" ]]; then
  echo "ERROR: $LOCAL_FILE not found — build before verifying." >&2
  exit 1
fi

echo "==> waiting for edge propagation"
sleep 8

echo "==> comparing local build against ${URL}/main.dart.js"
local_hash=$(shasum -a 256 "$LOCAL_FILE" | awk '{print $1}')

live_hash=""
for attempt in 1 2 3 4 5 6; do
  live_hash=$(curl -s --max-time 20 "${URL}/main.dart.js?cachebust=$(date +%s)-$attempt" | shasum -a 256 | awk '{print $1}')
  if [[ "$live_hash" == "$local_hash" ]]; then
    echo "==> ok: live main.dart.js matches the build we just deployed ($local_hash)"
    exit 0
  fi
  echo "    attempt $attempt/6: live=$live_hash local=$local_hash — retrying"
  sleep 10
done

echo "ERROR: live main.dart.js does NOT match the local build after 6 attempts." >&2
echo "       local:  $local_hash" >&2
echo "       live:   $live_hash" >&2
echo "       The deployed bundle is stale or mismatched — every real chat" >&2
echo "       request will likely fail 'Invalid signature' even though the" >&2
echo "       worker and secret are both correct. Re-run 'npm run deploy'." >&2
rollback_hint
exit 1
