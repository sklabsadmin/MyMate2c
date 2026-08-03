#!/usr/bin/env bash
#
# SessionStart hook for Claude Code on the web.
#
# The remote container ships Node but no Flutter, so without this every web
# session starts with `flutter: command not found` — no analyzer, no tests,
# no web build. This installs a pinned Flutter SDK and both dependency sets.
#
# Idempotent: re-running is a no-op once the SDK is unpacked and deps resolve.
set -euo pipefail

# Local machines already have their own Flutter; don't touch them.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Pinned deliberately. Dart 3.12.2 satisfies pubspec's `sdk: ^3.10.0`; bumping
# this is a decision, not something a session should drift into silently.
FLUTTER_VERSION="3.44.8"
FLUTTER_SHA256="672089e001571a9fbb209a495c583580c0c6c73ef98999264ba07fa93ace332d"
FLUTTER_HOME="/opt/flutter"
FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"

export FLUTTER_SUPPRESS_ANALYTICS=true
export PATH="${FLUTTER_HOME}/bin:${PATH}"

if [ ! -x "${FLUTTER_HOME}/bin/flutter" ]; then
  echo "==> installing Flutter ${FLUTTER_VERSION}"
  tarball="$(mktemp -d)/flutter.tar.xz"
  curl -fsSL --retry 3 --retry-delay 2 "$FLUTTER_URL" -o "$tarball"
  echo "${FLUTTER_SHA256}  ${tarball}" | sha256sum -c -
  tar -xJf "$tarball" -C /opt
  rm -rf "$(dirname "$tarball")"
else
  echo "==> Flutter already present at ${FLUTTER_HOME}"
fi

# The container runs as root and the SDK is an unowned git checkout, so every
# flutter invocation aborts on "dubious ownership" until this is set.
git config --global --add safe.directory "${FLUTTER_HOME}" 2>/dev/null || true

flutter --version

# Web is this repo's deploy target (tool/build_web.sh -> wrangler deploy).
# Precaching here means the artifacts land in the cached container image
# rather than being fetched during the first build of every session.
flutter precache --web

cd "$PROJECT_DIR"

echo "==> flutter pub get"
flutter pub get

# `npm ci`, not `npm install`: the container's npm 10 rewrites package-lock.json
# (dropping `libc` fields a newer npm wrote), which would leave every session
# starting on a dirty working tree. `ci` never writes the lockfile.
echo "==> npm ci (wrangler)"
npm ci --no-audit --no-fund || npm install --no-audit --no-fund

# Persist for the session so Claude's own shells find flutter/dart.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export PATH=\"${FLUTTER_HOME}/bin:\$PATH\""
    echo "export FLUTTER_SUPPRESS_ANALYTICS=true"
  } >> "$CLAUDE_ENV_FILE"
fi

echo "==> ready: flutter analyze / flutter test / npm run build:web"
