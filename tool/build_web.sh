#!/usr/bin/env bash
#
# The only supported way to build the web app.
#
# Three things have silently broken a deploy before, and each is guarded here:
#
#   1. A missing APP_SECRET. REQUIRE_SIGNATURE is "true" on the worker, so a
#      build without the secret compiles and deploys perfectly happily, then
#      fails every /api/chat call with "Invalid signature". Chat is dead for
#      everyone and the build looks fine. We refuse to build rather than ship
#      that, and refuse again afterwards if the secret somehow didn't land in
#      the compiled output.
#
#   2. A missing WORKER_URL. Falls back to the page's own origin, which works
#      on the deployed domain but silently points a local build at localhost.
#
#   3. Stale assets. `flutter build web` does NOT clean its output directory,
#      so files deleted from assets/ stay in build/web and get deployed. This
#      is how an 89MB payload survived a round of "shrinking".
#
# Usage: npm run build:web
set -euo pipefail

cd "$(dirname "$0")/.."

WORKER_URL="${WORKER_URL:-https://chat.deeploveechoes.com}"

# .env is gitignored and holds APP_SECRET. Only fills in what the environment
# has not already set, so CI can override without editing anything.
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

if [[ -z "${APP_SECRET:-}" ]]; then
  echo "ERROR: APP_SECRET is not set (looked at the environment and .env)." >&2
  echo "       Building without it would deploy an app whose every chat" >&2
  echo "       request fails with 'Invalid signature'. Refusing to build." >&2
  exit 1
fi

echo "==> cleaning build/web (flutter build does not)"
rm -rf build/web

echo "==> building against ${WORKER_URL}"
flutter build web --release \
  --dart-define=APP_SECRET="$APP_SECRET" \
  --dart-define=WORKER_URL="$WORKER_URL"

# Belt and braces: prove the secret actually reached the compiled output
# rather than trusting that the flag was accepted.
if ! grep -qF "$APP_SECRET" build/web/main.dart.js; then
  echo "ERROR: APP_SECRET did not make it into build/web/main.dart.js." >&2
  echo "       Do not deploy this build — chat would be broken." >&2
  exit 1
fi

echo "==> ok: APP_SECRET and WORKER_URL both baked in"
du -sh build/web
