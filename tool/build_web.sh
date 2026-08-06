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

# `bash tool/build_web.sh release` marks this as the build that gets deployed,
# which turns on the checks below that only make sense for one. Passed as an
# argument rather than as a `RELEASE_BUILD=1 bash ...` prefix because npm runs
# scripts through cmd.exe on Windows, where that prefix is a syntax error and
# not an environment variable. The env var is still honoured for CI.
if [[ "${1:-}" == "release" ]]; then
  RELEASE_BUILD=1
fi

# Captured before anything else assigns these, so we can tell "the caller
# exported it" from "the default filled it in".
CALLER_WORKER_URL="${WORKER_URL:-}"
CALLER_APP_SECRET="${APP_SECRET:-}"

# .env is gitignored and holds APP_SECRET. Only fills in what the environment
# has not already set, so CI can override without editing anything.
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

# `set -a; . ./.env` assigns unconditionally, so on its own it does the opposite
# of what the comment above promises: the file beats the environment. That is
# how `npm run preview:local` came to serve the app on one port while building
# a client that called another — preview_web.sh exports WORKER_URL and .env
# quietly replaced it. Invisible in cloud sessions, which have no .env.
if [[ -n "$CALLER_WORKER_URL" ]]; then
  WORKER_URL="$CALLER_WORKER_URL"
fi
if [[ -n "$CALLER_APP_SECRET" ]]; then
  APP_SECRET="$CALLER_APP_SECRET"
fi

# Applied last, once both the environment and .env have had their say.
WORKER_URL="${WORKER_URL:-https://chat.deeploveechoes.com}"

if [[ -z "${APP_SECRET:-}" ]]; then
  echo "ERROR: APP_SECRET is not set (looked at the environment and .env)." >&2
  echo "       Building without it would deploy an app whose every chat" >&2
  echo "       request fails with 'Invalid signature'. Refusing to build." >&2
  exit 1
fi

# The failure this exists for: a .env left holding WORKER_URL=http://localhost
# from a session of local testing, which silently becomes the API address for
# every real visitor. It compiles, deploys, and serves a page that looks
# perfect right up until the first message, which goes to the visitor's own
# machine and fails. Checked before the build rather than after, so a release
# that cannot ship does not cost ninety seconds to find out.
if [[ -n "${RELEASE_BUILD:-}" ]] &&
   [[ "$WORKER_URL" == *localhost* || "$WORKER_URL" == *127.0.0.1* ]]; then
  echo "ERROR: refusing to build a release against ${WORKER_URL}." >&2
  echo "       Every visitor's chat request would go to their own machine." >&2
  echo "       Unset WORKER_URL in .env, or export the real origin." >&2
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

if ! grep -qF "$WORKER_URL" build/web/main.dart.js; then
  echo "ERROR: WORKER_URL did not make it into build/web/main.dart.js." >&2
  exit 1
fi

echo "==> ok: APP_SECRET baked in, API at ${WORKER_URL}"
du -sh build/web
