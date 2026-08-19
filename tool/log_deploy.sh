#!/usr/bin/env bash
#
# Records the deploy that just happened into the worker's deploy_log.
#
# Exists because the record had a hole the day it mattered: production was
# serving 1.7.1+70 while deploy_log ended at +67 marked "Current", and every
# deploy-boundary analysis keys on that table — a missing row turns
# segmentation into archaeology (docs/EVAL-2026-08-18-entry-rate-by-bundle.md).
# A step in the deploy chain cannot forget; a human already three commands
# past `wrangler deploy` can.
#
# Never fails the chain: by the time this runs the deploy is live and
# verified, and a logging failure is a warning to act on, not grounds to
# report the deploy itself as failed. Every early exit below is exit 0 with
# the loudest warning it can print.
set -uo pipefail
cd "$(dirname "$0")/.."

HOST="${MYMATE_LOGS_HOST:-logs.deeplovepoems.com}"

# The environment wins; .env (gitignored) is the fallback for local deploys.
# The token itself must never be committed — see the handoff doc.
TOKEN="${MYMATE_ADMIN_TOKEN:-}"
if [[ -z "$TOKEN" && -f .env ]]; then
  TOKEN="$(sed -n 's/^MYMATE_ADMIN_TOKEN=//p' .env | head -1)"
fi
if [[ -z "$TOKEN" ]]; then
  echo "==> WARNING: MYMATE_ADMIN_TOKEN not set (env or .env) — this deploy was NOT logged." >&2
  echo "    Record it by hand at https://${HOST}/admin/deploys" >&2
  exit 0
fi

# The version of the bundle that actually shipped, read from the artefact
# itself rather than from pubspec — a stale build/web deploys the stale
# version, and the log must say what went out, not what the tree says.
VERSION="$(python3 -c 'import json; d = json.load(open("build/web/version.json")); print(d["version"] + "+" + d["build_number"])' 2>/dev/null || true)"
if [[ -z "$VERSION" ]]; then
  echo "==> WARNING: could not read build/web/version.json — deploy NOT logged." >&2
  echo "    Record it by hand at https://${HOST}/admin/deploys" >&2
  exit 0
fi

DEPLOYED_AT="$(date -u '+%Y-%m-%d %H:%M:%S')"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo '?')"

BODY="$(python3 - "$VERSION" "$DEPLOYED_AT" "$COMMIT" <<'PY'
import json, sys
print(json.dumps({
    "version": sys.argv[1],
    "deployed_at": sys.argv[2],
    # npm run deploy ships the worker and the freshly built assets together.
    "target": "both",
    "notes": "auto-logged by npm run deploy, commit " + sys.argv[3],
}))
PY
)"

RESPONSE="$(curl -sS -w $'\n%{http_code}' -u "admin:${TOKEN}" \
  -H 'Content-Type: application/json' \
  -X POST "https://${HOST}/api/admin/deploys" --data "$BODY" 2>&1 || true)"
STATUS="${RESPONSE##*$'\n'}"

if [[ "$STATUS" == "200" ]]; then
  echo "==> deploy_log: recorded ${VERSION} at ${DEPLOYED_AT} UTC (commit ${COMMIT})"
else
  echo "==> WARNING: deploy_log POST answered '${STATUS}' — record ${VERSION} by hand at https://${HOST}/admin/deploys" >&2
  echo "    ${RESPONSE%$'\n'*}" >&2
fi
exit 0
