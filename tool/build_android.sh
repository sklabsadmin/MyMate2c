#!/usr/bin/env bash
#
# The only supported way to build the Android app.
#
# Native builds get their backend config the same way web builds do: baked in
# as --dart-define values (AppConfig reads those first, then a bundled .env,
# which we never ship). A bare `flutter build appbundle` compiles happily
# without them and produces an app whose first message fails with "Invalid
# signature" - the same silent failure tool/build_web.sh exists to prevent,
# so this script guards the same three things:
#
#   1. APP_SECRET must be set (environment, else .env). Refuse otherwise.
#   2. WORKER_URL must not point at localhost for a release.
#   3. Release signing: android/key.properties present, or say so loudly.
#
# Usage:
#   npm run build:android            -> release App Bundle (.aab) for Play
#   npm run build:android:apk        -> release APK for sideloading on a phone
#   bash tool/build_android.sh apk debug  -> debug APK (flutter run does this too)
set -euo pipefail

cd "$(dirname "$0")/.."

ARTIFACT="${1:-appbundle}"   # appbundle | apk
MODE="${2:-release}"         # release | profile | debug

case "$ARTIFACT" in
  appbundle|apk) ;;
  *) echo "usage: $0 [appbundle|apk] [release|profile|debug]" >&2; exit 2 ;;
esac

CALLER_WORKER_URL="${WORKER_URL:-}"
CALLER_APP_SECRET="${APP_SECRET:-}"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi
# The environment beats .env, same as build_web.sh and for the same reason.
if [[ -n "$CALLER_WORKER_URL" ]]; then WORKER_URL="$CALLER_WORKER_URL"; fi
if [[ -n "$CALLER_APP_SECRET" ]]; then APP_SECRET="$CALLER_APP_SECRET"; fi

# The worker the shipped apps talk to. .env in a dev checkout usually points
# at mymate-v2 (the auto-deploy target for main), which is also what the web
# build ships against, so the default follows build_web.sh.
WORKER_URL="${WORKER_URL:-https://chat.deeploveechoes.com}"

if [[ -z "${APP_SECRET:-}" ]]; then
  echo "ERROR: APP_SECRET is not set (looked at the environment and .env)." >&2
  echo "       Building without it would ship an app whose every chat" >&2
  echo "       request fails with 'Invalid signature'. Refusing to build." >&2
  exit 1
fi

if [[ "$MODE" == "release" ]] &&
   [[ "$WORKER_URL" == *localhost* || "$WORKER_URL" == *127.0.0.1* || "$WORKER_URL" == *10.0.2.2* ]]; then
  echo "ERROR: refusing to build a release against ${WORKER_URL}." >&2
  echo "       Unset WORKER_URL in .env, or export the real origin." >&2
  exit 1
fi

if [[ "$MODE" == "release" ]] && [[ ! -f android/key.properties ]]; then
  if [[ "$ARTIFACT" == "appbundle" ]]; then
    echo "ERROR: android/key.properties is missing, so this bundle would be" >&2
    echo "       signed with the debug key and Play would reject it." >&2
    echo "       See android/key.properties.example." >&2
    exit 1
  fi
  echo "WARNING: android/key.properties is missing - the APK will be signed" >&2
  echo "         with the debug key. Fine for a phone test, not for Play." >&2
fi

APP_VERSION="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -1 | tr -d '[:space:]')"
echo "==> building ${ARTIFACT} (${MODE}) ${APP_VERSION} against ${WORKER_URL}"

flutter build "$ARTIFACT" "--${MODE}" \
  --dart-define=APP_SECRET="$APP_SECRET" \
  --dart-define=WORKER_URL="$WORKER_URL"

# Locate the output flutter just wrote.
if [[ "$ARTIFACT" == "appbundle" ]]; then
  OUT="build/app/outputs/bundle/${MODE}/app-${MODE}.aab"
else
  OUT="build/app/outputs/flutter-apk/app-${MODE}.apk"
fi
if [[ ! -f "$OUT" ]]; then
  echo "ERROR: expected output ${OUT} not found." >&2
  exit 1
fi

# Belt and braces, as build_web.sh does for main.dart.js: in a release build
# the defines are compiled into the AOT snapshot (libapp.so), where string
# constants survive as plain bytes. Debug/profile builds keep them in the
# kernel blob instead, so only the release layout is checked.
if [[ "$MODE" == "release" ]]; then
  CHECK_DIR="$(mktemp -d)"
  trap 'rm -rf "$CHECK_DIR"' EXIT
  # No `find` here: in Git Bash on Windows an unquoted `find` resolves to
  # C:\Windows\System32\FIND.EXE and dies with "Parameter format not
  # correct". A shell glob over the two layouts (APK: lib/<abi>/, AAB:
  # base/lib/<abi>/) needs no external tool at all.
  unzip -q -o "$OUT" 'lib/*/libapp.so' 'base/lib/*/libapp.so' -d "$CHECK_DIR" 2>/dev/null || true
  shopt -s nullglob
  LIBAPPS=("$CHECK_DIR"/lib/*/libapp.so "$CHECK_DIR"/base/lib/*/libapp.so)
  shopt -u nullglob
  LIBAPP="${LIBAPPS[0]:-}"
  if [[ -z "$LIBAPP" ]]; then
    echo "WARNING: no libapp.so found inside ${OUT}; could not verify defines." >&2
  else
    if ! grep -qF "$WORKER_URL" "$LIBAPP"; then
      echo "ERROR: WORKER_URL did not make it into the app. Do not ship this." >&2
      exit 1
    fi
    if ! grep -qF "$APP_SECRET" "$LIBAPP"; then
      echo "ERROR: APP_SECRET did not make it into the app - chat would be broken." >&2
      exit 1
    fi
    echo "==> ok: APP_SECRET baked in, API at ${WORKER_URL}"
  fi
fi

ls -lh "$OUT"
echo "==> ${OUT}"
