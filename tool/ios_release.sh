#!/usr/bin/env bash
#
# One-shot iOS release prep for the Mac. Run from the repo root:
#
#   bash tool/ios_release.sh            # prep + open Xcode for Archive
#   bash tool/ios_release.sh --ipa      # prep + build the .ipa on the CLI
#
# Pulls the current branch, cleans, resolves CocoaPods, bakes the release
# config in, and either opens the workspace (Product → Archive → Distribute) or
# builds an App Store .ipa into build/ios/ipa/ ready for Transporter.
#
# Release config comes from .env and is passed as --dart-define, because
# flutter_dotenv never loads on native: without the defines the app ships with
# an empty WORKER_URL and APP_SECRET (no chat at all) and RevenueCat falls back
# to the sandbox Test Store key (purchases never credit). The script refuses to
# build rather than produce that. Required in .env:
#   APP_SECRET           the HMAC secret the worker checks
#   REVENUECAT_IOS_KEY   the appl_ public SDK key of the Mythos Live app
# Optional: WORKER_URL (defaults to the production worker below).
# ALLOW_TEST_STORE=1 permits a test_ RevenueCat key, for local sandbox runs only.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "ERROR: .env missing" >&2; exit 1; }
set -a; . ./.env; set +a
WORKER_URL="${WORKER_URL:-https://chat.deeploveechoes.com}"

[[ -n "${APP_SECRET:-}" ]] || { echo "ERROR: APP_SECRET not set in .env" >&2; exit 1; }
RC_KEY="${REVENUECAT_IOS_KEY:-}"
if [[ "$RC_KEY" != appl_* ]]; then
  if [[ "$RC_KEY" == test_* && "${ALLOW_TEST_STORE:-}" == "1" ]]; then
    echo "WARNING: RevenueCat Test Store key — sandbox only, do NOT upload this build" >&2
  else
    echo "ERROR: REVENUECAT_IOS_KEY in .env must be the appl_ key of the Mythos Live" >&2
    echo "       RevenueCat app (got '${RC_KEY:0:5}…'). Without it the build falls back" >&2
    echo "       to the Test Store key and purchases never credit." >&2
    exit 1
  fi
fi
DEFINES=(--dart-define "APP_SECRET=$APP_SECRET"
         --dart-define "WORKER_URL=$WORKER_URL"
         --dart-define "REVENUECAT_IOS_KEY=$RC_KEY")

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "==> git pull origin $BRANCH"
git pull --ff-only origin "$BRANCH"

echo "==> flutter clean && flutter pub get"
flutter clean >/dev/null
flutter pub get

echo "==> flutter precache --ios"
flutter precache --ios

# Keep Podfile.lock: the release should use the pod versions that were tested.
# Only refresh the spec repo if the lock can't be satisfied.
echo "==> pod install"
( cd ios && { pod install || pod install --repo-update; } )

if [[ "${1:-}" == "--ipa" ]]; then
  echo "==> flutter build ipa --release (config baked in)"
  flutter build ipa --release "${DEFINES[@]}"
  APP_BIN="build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app/Frameworks/App.framework/App"
  if strings "$APP_BIN" | grep -qF -- "$APP_SECRET"; then
    echo "==> verified: APP_SECRET is baked into App.framework"
  else
    echo "ERROR: APP_SECRET not found in the built App.framework — do not upload" >&2
    exit 1
  fi
  echo
  echo "IPA ready: $(ls build/ios/ipa/*.ipa)"
  echo "Upload with Transporter.app, or:"
  echo "  xcrun altool --upload-app -f build/ios/ipa/*.ipa -t ios --apiKey KEY --apiIssuer ISSUER"
else
  # An Xcode Archive reads DART_DEFINES from ios/Flutter/Generated.xcconfig, which
  # only a `flutter build` writes. --config-only writes it without compiling.
  echo "==> writing release config into Generated.xcconfig"
  flutter build ios --release --config-only "${DEFINES[@]}"
  n=$(grep -E '^DART_DEFINES=' ios/Flutter/Generated.xcconfig | sed 's/^DART_DEFINES=//' | tr ',' '\n' \
      | while read -r d; do echo "$d" | base64 -d 2>/dev/null | cut -d= -f1; echo; done \
      | grep -cE '^(APP_SECRET|WORKER_URL|REVENUECAT_IOS_KEY)$' || true)
  [[ "$n" == "3" ]] || { echo "ERROR: Generated.xcconfig is missing release defines ($n/3)" >&2; exit 1; }
  echo "==> verified: APP_SECRET, WORKER_URL, REVENUECAT_IOS_KEY in Generated.xcconfig"
  echo "==> opening Xcode workspace"
  open ios/Runner.xcworkspace
  cat <<'MSG'

In Xcode:
  1. Select the Runner target → Signing & Capabilities.
     Team: SK Labs Limited Liability Company. Bundle ID: com.sklabs.mythoslive.
     Tick "Automatically manage signing" if it isn't.
  2. Top bar device selector: "Any iOS Device (arm64)".
  3. Product → Archive.  (Do not run `flutter build` or `flutter run` in
     between — they rewrite Generated.xcconfig without the release config.)
  4. In the Organizer window: Distribute App → App Store Connect → Upload.
MSG
fi
