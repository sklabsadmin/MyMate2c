#!/usr/bin/env bash
#
# One-shot iOS release prep for the Mac. Run from the repo root:
#
#   bash tool/ios_release.sh            # prep + open Xcode for Archive
#   bash tool/ios_release.sh --ipa      # prep + build the .ipa on the CLI
#
# Pulls the current branch, cleans, resolves CocoaPods, and either opens the
# workspace (Product → Archive → Distribute) or builds an App Store .ipa
# into build/ios/ipa/ ready for Transporter or `xcrun altool`.
set -euo pipefail
cd "$(dirname "$0")/.."

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
echo "==> git pull origin $BRANCH"
git pull --ff-only origin "$BRANCH"

echo "==> flutter clean && flutter pub get"
flutter clean >/dev/null
flutter pub get

echo "==> flutter precache --ios"
flutter precache --ios

echo "==> pod install"
( cd ios && rm -rf Pods Podfile.lock && pod install --repo-update )

if [[ "${1:-}" == "--ipa" ]]; then
  echo "==> flutter build ipa --release"
  flutter build ipa --release
  echo
  echo "IPA ready: $(ls build/ios/ipa/*.ipa)"
  echo "Upload with Transporter.app, or:"
  echo "  xcrun altool --upload-app -f build/ios/ipa/*.ipa -t ios --apiKey KEY --apiIssuer ISSUER"
else
  echo "==> opening Xcode workspace"
  open ios/Runner.xcworkspace
  cat <<'MSG'

In Xcode:
  1. Select the Runner target → Signing & Capabilities.
     Team: SK Labs Limited Liability Company. Bundle ID: com.sklabs.mythoslive.
     Tick "Automatically manage signing" if it isn't.
  2. Top bar device selector: "Any iOS Device (arm64)".
  3. Product → Archive.
  4. In the Organizer window: Distribute App → App Store Connect → Upload.
MSG
fi
