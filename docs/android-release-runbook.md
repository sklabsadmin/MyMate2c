# Android release runbook

How to get Mythos Live from this repo onto a phone and onto Google Play.
Written 2026-09-02 on the `android/play-parity` branch; folded onto main
2026-10-09 for the Mythos Live 1.0.5 release, after the rebrand to
`com.sklabs.mythoslive` on iOS. Read `docs/HANDOFF-android-port-2026-10-09.md`
for the state of play when that happened.

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

## One-time setup on the build machine (Adam's Mac, done 2026-10-09)

No Android Studio. Homebrew only:

    brew install openjdk@17 android-commandlinetools
    sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0"
    flutter config --android-sdk ~/Library/Android/sdk --jdk-dir $(brew --prefix openjdk@17)

The SDK lives in `~/Library/Android/sdk`. `flutter doctor` keeps saying
"Android license status unknown" because the new Android CLI dropped
`sdkmanager --licenses`; the license files are in `~/Library/Android/sdk/licenses`
and builds work, so ignore it. Builds need `JAVA_HOME` pointing at the
Homebrew JDK 17 (`tool/build_android.sh` sets it if unset).

`.env` in the repo root with `APP_SECRET` (the same file `npm run deploy`
uses); `WORKER_URL` defaults to `https://chat.deeploveechoes.com`. The build
runs from the worktree you are in, so copy `.env` there if it is missing (it
is gitignored).

## The Play listing that already exists

Checked in the Play Console on 2026-09-02 (SK Labs LLC, an organization
account, so no closed-testing waiting period): the previous owner had already
published this app as "MyMate: AI Boyfriend Chat" under the package
`com.iosappv2.ai_boyfriend_chat` - 164 installs, last production release
versionCode 22 (1.1.0) on 2026-01-08, Play App Signing on. That is why
`applicationId` is `com.iosappv2.ai_boyfriend_chat` while the Kotlin
namespace is `com.sklabs.mythoslive` (it was `com.aiboyfriend.mymate` before
the rebrand): the package name is the listing's identity and cannot change
without starting a new listing from zero.

Play App Signing means Google holds the app signing key (SHA-256
`CD:3F:EB:5F:...:81:44`) and we only need the *upload* key. Play's upload
certificate is SHA-256 `1E:1B:ED:A0:...:17:8F`; the matching keystore turned
up in the seller's original handover drop
(`Downloads/mymate-origJun23/android/app/upload-keystore.jks`, alias
`upload`, the password that used to be hardcoded in build.gradle.kts). It is
now the project's upload key, so no key reset was needed. That password sat
in git history for a year; after the first successful upload, rotate the key
via Play Console → App integrity → "Request upload key reset".

## Upload key

Lives at `android/app/upload-keystore.jks` with its passwords in
`android/key.properties` (both gitignored). Copies on Adam's Mac at
`~/abldev/mymate/android/app/upload-keystore.jks` and in each worktree that
has built a release - back it up somewhere off that machine. Check it is the
right one with

    keytool -list -keystore android/app/upload-keystore.jks

and compare the SHA-256 against Play Console -> Protected with Play ->
App signing -> "Upload key certificate". If the key is ever lost, the same
page has "Request upload key reset"; it costs a couple of days, not the app.

## Build

    npm run build:android:apk     # release APK, sideload to a phone
    npm run build:android         # release .aab for Play (needs key.properties)

For a debug run on the emulator or a plugged-in phone, `flutter run` does not
read `.env` either, so pass the defines by hand:

    npm run android               # tool/run_android.sh fills the defines in

or the app boots but every chat fails. The script prints "APP_SECRET is
MISSING" in the run log when that happens.

Version comes from `pubspec.yaml`: `version: 1.0.5+97` is versionName 1.0.5,
versionCode 97. Play requires each upload's versionCode to be higher than
the last, so bump `+N` for every upload. Web, iOS and Android share the one
build number: Android went first to 97 (2026-10-09), so the next web/iOS
release uses 98 or higher.

Release builds need `android/key.properties` (see `key.properties.example`);
without it the script refuses to build a bundle and signs an APK with the
debug key.

## First-run checklist on a device

- Launch: splash (Mythos medallion) → app. If it dies instantly, check
  `adb logcat | grep -i "AndroidRuntime\|ClassNotFound"`.
- Notification permission prompt appears on Android 13+ at first launch.
- Send a message; it should get a reply (proves WORKER_URL and APP_SECRET
  were baked in). "Invalid signature" means they were not.
- Background the app for 15 seconds: the "you left mid-thought" nudge should
  arrive (may be a few minutes late on Android 13+ without exact alarms).
- Settings → Google connect returns to the app via `mythoslive://settings?...`.
- Coins: claim the daily coins, open the coins sheet, and confirm "Get more
  coins" is hidden - there is no `REVENUECAT_ANDROID_KEY` yet, so
  `RevenueCatService.isSupported` is false on Android and the store hides
  itself. Free coins and gifts only, for now.
- Profile → change avatar opens the photo picker (no storage permission
  prompt expected on 13+).

## Play Console notes

- Package: `com.iosappv2.ai_boyfriend_chat` (cannot change without a new
  listing). The Kotlin namespace is `com.sklabs.mythoslive` and the iOS bundle
  id is the same; only the Play `applicationId` keeps the old name. Adam chose
  to update the old listing rather than start a new one (2026-10-09).
- Data safety: the app sends chat text and a device-generated user id to the
  worker; no advertising ID; no location; no contacts. The privacy policy is
  `web/privacy.html` on the deployed domain.
- Content: the companions are fiction/mentor-flavoured (see the prompt notes
  in `docs/odysseus-opening-brief-2026-08-10.md`) - rate accordingly in the
  questionnaire.
- Billing: `purchases_flutter` is back in `pubspec.yaml`, and its plugin
  merges the `BILLING` permission in together with the Play Billing Library,
  so the manifest still does not declare it by hand (declaring it without the
  library is what Play rejected the 2.0.0 upload for). The coin store stays
  hidden until a RevenueCat Android app exists: create it, put its `goog_`
  key in `.env` as `REVENUECAT_ANDROID_KEY`, and pass it as a `--dart-define`
  in `tool/build_android.sh` the way `tool/ios_release.sh` passes the iOS key.
- Advertising ID: the listing's declaration (App content -> Advertising ID)
  must say "no" - the app has no ads SDK and no AD_ID permission.
- Internal testing: testers are a list on the track (Test and release ->
  Internal testing -> Testers); a release with no testers publishes to nobody.
