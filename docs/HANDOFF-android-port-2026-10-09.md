# Handoff: Android port of Mythos Live

Written 2026-10-09 by the deploy session ("Build Boy") for a dedicated Android
session. iOS 1.0.5 (96) and web 1.0.5 (96) are in sync and the iOS build is
with App Review (submission ca684bb0). Android is the one platform not shipped.

## Where things stand

| | |
|---|---|
| Source of truth | branch `feat/star-gift` = `main` (5fe20a2 + later). Build from here. |
| App version | `pubspec.yaml` 1.0.5+96. Android `versionCode` = the +N, so the next Android upload must be > 96 (use 97+ and bump web/iOS to match when they next ship; one number for all platforms). |
| Android package in code | `com.sklabs.mythoslive` (applicationId AND Kotlin namespace, set by the rebrand). |
| Play listing that exists | **"MyMate: AI Boyfriend Chat"**, package `com.iosappv2.ai_boyfriend_chat`, 164 installs, last release versionCode 22 (1.1.0) on 2026-01-08, Play App Signing on. A Play package name can never change. |
| Upload key | `upload-keystore.jks`, alias `upload`. Copies at `~/abldev/mymate/android/app/upload-keystore.jks` (and two `MyMate1.3x` checkouts). The password is the one that used to be hardcoded in `android/app/build.gradle.kts` (still there on `feat/star-gift` — see "First fix"). Play's upload cert SHA-256 starts `1E:1B:ED:A0`; verify with `keytool -list -v`. |
| Toolchain on this Mac | None existed. `brew install openjdk@17 android-commandlinetools` was started 2026-10-09 with the SDK going to `~/Library/Android/sdk` (platform-tools, platforms;android-35, build-tools;35.0.0). **Run `flutter doctor` first** — if the Android toolchain is still red, finish the install (`sdkmanager --licenses`, `flutter config --android-sdk ~/Library/Android/sdk --jdk-dir $(brew --prefix openjdk@17)`). |
| Earlier Android work | branch `origin/android/play-parity` (2026-09-03, 8 commits, never merged). Worth cherry-picking, NOT merging: it targets the old package and conflicts with the rebrand in `build.gradle.kts`, `MainActivity.kt`, `pubspec.yaml`. |
| Backend config | `.env` has `APP_SECRET`; `WORKER_URL` is `https://chat.deeploveechoes.com`. Native builds get them only via `--dart-define` (flutter_dotenv never loads on device). `REVENUECAT_ANDROID_KEY` does not exist yet → `RevenueCatService.isSupported` is false on Android, so the coin store hides itself and the app ships with free coins + gifts only. That is fine for a first release. |

## The decision Adam has to make first

The rebrand's package `com.sklabs.mythoslive` cannot go on the existing
listing. Either:

1. **New Play app "Mythos Live"** under `com.sklabs.mythoslive` — matches iOS,
   but a listing from zero (store text, phone screenshots, content rating,
   data safety, privacy policy URL `https://chat.deeplovepoems.com/privacy`),
   and the 164 old installs never get the update.
2. **Update the old listing** — set `applicationId` back to
   `com.iosappv2.ai_boyfriend_chat` (the Kotlin namespace can stay
   `com.sklabs.mythoslive`; `android/play-parity` did exactly this split with
   `com.aiboyfriend.mymate`), label "Mythos Live", upload to the existing app.
   Fastest, and existing users get the update.

Build Boy's recommendation was 2. Ask Adam; do not assume.

## What to take from `android/play-parity`

`git log HEAD..origin/android/play-parity` — the useful commits:

- `5b99c8d` Make the Android app launch, sign, and talk to the backend —
  signing from a gitignored `android/key.properties` (template
  `android/key.properties.example`), falling back to the debug key with a
  warning; `tool/build_android.sh` bakes the dart-defines and refuses to build
  without them (mirror of `tool/ios_release.sh`).
- `e22147e` gradle.properties flags Flutter 3.44 wants.
- `c34eedc` `npm run android` / `tool/run_android.sh`.
- `d600791` Drop the `BILLING` permission Play rejects without a billing library.
- `d472ff5` `docs/android-release-runbook.md` — the full story of the listing
  and the key. Read it.
- `78ce002` Ship under the package the Play listing already has — only if
  Adam picks option 2.
- Skip `4649404` (version bump to 2.0.0+87) and the MainActivity move to
  `com.aiboyfriend.mymate` — the rebrand already moved it to
  `com.sklabs.mythoslive`.

The notification-service changes in `5b99c8d` (POST_NOTIFICATIONS, exact-alarm
fallback) touch `lib/src/core/services/notification_service.dart`, which
`feat/star-gift` has also changed — expect a small manual merge there.

## First fix, before anything ships

`android/app/build.gradle.kts` on `feat/star-gift` still has the keystore
passwords in plain text (`storePassword`/`keyPassword`, lines ~37–45). Move
them to `android/key.properties` (gitignored) the way `5b99c8d` does, and
drop them from git history consideration: the password is already public in
the repo's history, so after the first successful upload consider rotating the
upload key via Play Console → App integrity → "Request upload key reset".

## Checks before uploading

- `flutter build appbundle --release` with the three dart-defines; then
  `unzip -p build/app/outputs/bundle/release/app-release.aab base/manifest/AndroidManifest.xml`
  is binary — use `bundletool dump manifest` or just check
  `strings` of the extracted `libapp.so` for `chat.deeploveechoes.com`, the same
  way `tool/ios_release.sh` checks `App.framework/App` for `APP_SECRET`.
- Install on an emulator or device and send one chat (a reply proves the
  secret). Claim coins; open the coins sheet; confirm "Get more coins" is
  hidden (no Android RevenueCat key yet).
- Upload to **Internal testing** first. SK Labs LLC is an organization
  account, so there is no closed-testing waiting period before production.

## Chrome / Play Console

The Claude-in-Chrome extension is blocked from `play.google.com` ("domain not
allowed") until Adam allows the domain in the extension's site settings. Until
then, hand Adam the `.aab` to upload.

## Build numbering rule

Web and iOS share one build number (currently 96). Android's versionCode
must only ever go up; start at 97 and tell Build Boy, so the next web/iOS
release uses 98+.

## Android session log (2026-10-09, later the same day)

- Adam chose option 2: update the old listing. `applicationId` is
  `com.iosappv2.ai_boyfriend_chat`; namespace stays `com.sklabs.mythoslive`.
- Mac toolchain finished (SDK 36, JDK 17 via Homebrew); runbook updated.
- Parity commits applied by hand (not cherry-picked): key.properties signing,
  `tool/build_android.sh`, `tool/run_android.sh`, manifest permissions and
  receivers, notification-service fallback, runbook.
- **pubspec is now 1.0.5+97.** Build Boy: next web/iOS release is 98+.
- Keystore copied to `android/app/upload-keystore.jks` in this worktree,
  passwords in `android/key.properties` (both gitignored). Fingerprint matches
  Play's upload cert (`1E:1B:ED:A0…`).
