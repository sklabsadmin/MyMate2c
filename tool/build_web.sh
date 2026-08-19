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
# A bare `rm -rf` is enough on macOS and not on Windows, where a leftover
# `wrangler dev`/workerd from a preview, an editor, or a virus scanner can hold
# an open handle on the directory. rm then empties it and still fails with
# "Device or resource busy" — and under `set -e` that aborted the entire deploy
# over a directory that was, by then, already clean.
#
# Retry briefly, then judge the result rather than rm's exit code: an EMPTY
# build/web is exactly what the build wants, whether or not the directory
# itself could be unlinked. Only real surviving files are a failure.
for _attempt in 1 2 3; do
  rm -rf build/web 2>/dev/null && break
  sleep 1
done
if [[ -d build/web ]] && [[ -n "$(ls -A build/web 2>/dev/null)" ]]; then
  echo "ERROR: could not clear build/web; files are still in it." >&2
  echo "       Something is holding the directory open. On Windows that is" >&2
  echo "       usually a 'wrangler dev' or workerd left over from a preview:" >&2
  echo "       stop it and run this again." >&2
  exit 1
fi

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

# Stamp the bundle version into the visit beacon. The beacon runs in <head>
# before Flutter exists, so it cannot ask package_info — the build has to
# tell it. Without this stamp every site_visits row is versionless and a
# funnel cannot be segmented across a deploy: the day that question actually
# came up, versions had to be reconstructed from delivery receipts, which
# only exist for visits that rendered a bubble
# (docs/EVAL-2026-08-18-entry-rate-by-bundle.md).
APP_VERSION="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -1 | tr -d '[:space:]')"
if [[ -z "$APP_VERSION" ]]; then
  echo "ERROR: could not read version: from pubspec.yaml." >&2
  exit 1
fi
python3 - "$APP_VERSION" <<'PY'
import pathlib, sys
version = sys.argv[1]
p = pathlib.Path("build/web/index.html")
s = p.read_text(encoding="utf-8")
token = "%MYTHOS_APP_VERSION%"
if token not in s:
    # Missing means the beacon is absent or already stamped — either way this
    # build's rows would be versionless or mislabeled. flutter_native_splash
    # regenerating index.html before tool/patch_splash.py re-ran is the known
    # way to get here.
    sys.exit("build/web/index.html has no " + token +
             " placeholder - run python3 tool/patch_splash.py and rebuild")
p.write_text(s.replace(token, version), encoding="utf-8")
PY
if ! grep -qF "'${APP_VERSION}'" build/web/index.html; then
  echo "ERROR: version stamp did not land in build/web/index.html." >&2
  exit 1
fi
echo "==> stamped bundle version ${APP_VERSION} into the visit beacon"

echo "==> ok: APP_SECRET baked in, API at ${WORKER_URL}"
du -sh build/web
