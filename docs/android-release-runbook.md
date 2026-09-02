# Android release runbook

How to get Mythos Live from this repo onto a phone and onto Google Play.
Written 2026-09-02, when the Android side was brought up to the 2.0.0 line
the web and iOS builds were already on.

## What was wrong before this

The repo said "targeting iOS and Android", but the Android project had never
run. Found on the first pass:

- `AndroidManifest.xml` declared the activity as `.MainActivity`, which
  resolves against the Gradle namespace `com.aiboyfriend.mymate`. The Kotlin
  class lived in `com.iosappv2.ai_boyfriend_chat` (the project this one was
  cloned from). Every launch would have died in `ClassNotFoundException`
  before Flutter started. Moved to the right package.
- Release signing was hardcoded in `build.gradle.kts` (passwords in git) and
  pointed at `upload-keystore.jks`, which exists nowhere. Now read from a
  gitignored `android/key.properties`; without it, release builds fall back
  to the debug key with a warning (installable for testing, rejected by Play).
- Nothing set `WORKER_URL`/`APP_SECRET` for native builds. `.env` is not a
  bundled asset (on purpose), so a bare `flutter build` shipped an app with
  no backend and "Invalid signature" on every chat. `tool/build_android.sh`
  now bakes them in as `--dart-define`s and refuses to build without them,
  mirroring `tool/build_web.sh`.
- Reminders: no `POST_NOTIFICATIONS` permission (Android 13+ drops them
  silently), no scheduled/boot receivers for `flutter_local_notifications`,
  and `exactAllowWhileIdle` scheduling, which throws on Android 13+ unless
  the user has toggled exact alarms on. The service now asks for the
  notification permission, checks whether exact alarms are allowed and falls
  back to inexact ones, and swallows scheduling failures instead of crashing.
- App label was still `MyMate`; now `Mythos Live`, matching the web manifest.
- The `AD_ID` permission was declared with no ads SDK in the app. Removed, so
  the Play data-safety form does not have to explain an advertising ID the
  app never reads. Put it back only if an ads SDK is added.

## One-time setup on the build machine (Windows)

1. Android Studio (Quail 4 or later is fine) with, in SDK Manager: the SDK
   Platform Flutter currently targets, Build-Tools, Command-line Tools,
   Platform-Tools. Then `flutter doctor --android-licenses` and check
   `flutter doctor` is clean for the Android toolchain.
2. `android/local.properties` should already have `sdk.dir` and
   `flutter.sdk`; Flutter rewrites it on first build if not.
3. `.env` in the repo root with `WORKER_URL` and `APP_SECRET` (the same file
   `npm run deploy` uses).

## Upload key

Google Play ties the app to the key that first uploads it, so decide this
before the first upload:

- If the previous owner ever published `com.aiboyfriend.mymate` on Play, the
  app must be signed with *their* upload key (or Play Console → Setup → App
  signing → "Request upload key reset"). Ask for the `.jks` and its passwords
  as part of the handover.
- If it was never on Play, generate one and keep it outside the repo:

      keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload

  Put the file at `android/app/upload-keystore.jks` (gitignored) and copy
  `android/key.properties.example` to `android/key.properties` with the real
  passwords. Back up the `.jks` somewhere that is not this machine.

With Play App Signing (the default for new apps), Google holds the *app*
signing key and this is only the *upload* key, so losing it is recoverable
through a reset request rather than fatal, but it still costs days.

## Build

    npm run build:android:apk     # release APK, sideload to a phone
    npm run build:android         # release .aab for Play (needs key.properties)

For a debug run on the emulator or a plugged-in phone, `flutter run` does not
read `.env` either, so pass the defines by hand:

    flutter run --dart-define=WORKER_URL=https://mymate-v2.sklabs-admin.workers.dev --dart-define=APP_SECRET=...

or the app boots but every chat fails. The script prints "APP_SECRET is
MISSING" in the run log when that happens.

Version comes from `pubspec.yaml`: `version: 2.0.0+86` is versionName 2.0.0,
versionCode 86. Play requires each upload's versionCode to be higher than
the last, so bump `+N` for every upload, as for iOS/TestFlight.

## First-run checklist on a device

- Launch: splash (Mythos medallion) → app. If it dies instantly, check
  `adb logcat | grep -i "AndroidRuntime\|ClassNotFound"`.
- Notification permission prompt appears on Android 13+ at first launch.
- Send a message; it should get a reply (proves WORKER_URL and APP_SECRET
  were baked in). "Invalid signature" means they were not.
- Background the app for 15 seconds: the "you left mid-thought" nudge should
  arrive (may be a few minutes late on Android 13+ without exact alarms).
- Settings → Google connect returns to the app via `mymate://settings?...`.
- Profile → change avatar opens the photo picker (no storage permission
  prompt expected on 13+).

## Play Console notes

- Package: `com.aiboyfriend.mymate` (cannot change without a new listing).
- Data safety: the app sends chat text and a device-generated user id to the
  worker; no advertising ID; no location; no contacts. The privacy policy is
  `web/privacy.html` on the deployed domain.
- Content: the companions are fiction/mentor-flavoured (see the prompt notes
  in `docs/odysseus-opening-brief-2026-08-10.md`) - rate accordingly in the
  questionnaire.
- Billing: RevenueCat/`purchases_flutter` is commented out in `pubspec.yaml`
  and `BILLING` is declared in the manifest. Harmless until it is re-enabled;
  when it is, add `REVENUECAT_ANDROID_KEY` as a `--dart-define` in
  `tool/build_android.sh` next to the other two.
