#!/usr/bin/env bash
#
# `flutter run` with the backend config baked in, the way tool/build_android.sh
# does for release builds. A bare `flutter run` boots the app with no
# WORKER_URL/APP_SECRET (they are --dart-defines, not a bundled .env), so it
# looks fine until the first message fails.
#
# Usage: npm run android            (debug, hot reload, on the connected device
#                                    or running emulator)
#        npm run android -- -d <id> (pick a device: `flutter devices` lists them)
set -euo pipefail
cd "$(dirname "$0")/.."

CALLER_WORKER_URL="${WORKER_URL:-}"
CALLER_APP_SECRET="${APP_SECRET:-}"
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi
if [[ -n "$CALLER_WORKER_URL" ]]; then WORKER_URL="$CALLER_WORKER_URL"; fi
if [[ -n "$CALLER_APP_SECRET" ]]; then APP_SECRET="$CALLER_APP_SECRET"; fi
WORKER_URL="${WORKER_URL:-https://chat.deeploveechoes.com}"

if [[ -z "${APP_SECRET:-}" ]]; then
  echo "ERROR: APP_SECRET is not set (looked at the environment and .env)." >&2
  exit 1
fi

echo "==> flutter run against ${WORKER_URL}"
exec flutter run \
  --dart-define=APP_SECRET="$APP_SECRET" \
  --dart-define=WORKER_URL="$WORKER_URL" \
  "$@"
