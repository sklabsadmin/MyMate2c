# Handoff: Android, for Build Boy 2

Written 2026-10-28 by the Android port session, which is closing. This
supersedes `docs/HANDOFF-android-port-2026-10-09.md` (keep that for the
history and the reasoning; this file is the current state).

## What exists

| | |
|---|---|
| The Android port | branch `claude/competent-mendel-a4d1d2`, commit `5e2aed5`, built on main as of 2026-10-09 (1.0.5). Pushed, no PR, never merged. |
| What is in it | `applicationId = com.iosappv2.ai_boyfriend_chat` (namespace stays `com.sklabs.mythoslive`); signing from gitignored `android/key.properties`; `tool/build_android.sh` + `tool/run_android.sh` with `npm run build:android`, `build:android:apk`, `android`; manifest permissions and receivers for reminders; `NotificationService` asks for Android 13 permission and falls back to inexact alarms; `docs/android-release-runbook.md`; README build section; pubspec 1.0.5+97. |
| Main today | 1.0.6+98 (Google/Apple sign-in, content sweep, analyzer fixes). `android/app/build.gradle.kts` on main still says `com.sklabs.mythoslive` and still has the keystore passwords in plain text. |
| Merge state | `5e2aed5` merges into main with a conflict only in `pubspec.yaml`. Keep main's 1.0.6 and set the build number to 99 (97 went to Android, 98 to iOS/web). |
| The bundle | `~/Downloads/mythos-live-1.0.5-97.aab` on Adam's Mac. Signed with the right upload key, backend config baked in, verified. It is 1.0.5: no sign-in, no content sweep. Treat it as a throwaway unless Adam already uploaded it. |
| Toolchain | Finished on Adam's Mac 2026-10-09: Homebrew `openjdk@17` + `android-commandlinetools`, SDK at `~/Library/Android/sdk` (platforms 34/35/36, build-tools 35/36, CMake, NDK pulled in by Gradle). `flutter doctor` says "license status unknown" — cosmetic, builds work. No emulator image, no phone. |
| Keys | `android/app/upload-keystore.jks` + `android/key.properties` in the competent-mendel worktree (gitignored). Master copy `~/abldev/mymate/android/app/upload-keystore.jks`. Alias `upload`. SHA-256 starts `1E:1B:ED:A0`, matches Play's upload cert. The password is the one that was hardcoded in git history; rotate the upload key in Play Console after the first successful upload. |
| Backend config | `.env` in the repo root (copy it into whatever worktree you build from; it is gitignored). `APP_SECRET` is required, `WORKER_URL` defaults to `https://chat.deeploveechoes.com`. No `REVENUECAT_ANDROID_KEY` exists, so the coin store hides itself on Android. |

## Decisions already made (do not reopen)

- Adam chose on 2026-10-09 to update the old Play listing ("MyMate: AI
  Boyfriend Chat", 164 installs) rather than start a new one. Hence the
  `applicationId` / namespace mismatch. Never "fix" it.
- No hand-declared `BILLING` permission in the manifest: `purchases_flutter`
  merges it in with the Play Billing Library. Declaring it alone is what Play
  rejected in September.
- No `AD_ID` permission: there is no ads SDK.
- One build number across web, iOS and Android, always going up.

## What to do, in order

1. From a checkout of `claude/competent-mendel-a4d1d2`: `git merge origin/main`,
   resolve `pubspec.yaml` to `version: 1.0.6+99`, run `flutter analyze`.
2. Copy `.env` into the worktree if missing. Check `android/key.properties`
   and `android/app/upload-keystore.jks` are present (copy from the master
   paths above if not).
3. `npm run build:android`. The script refuses to build without the secret
   or the key, and checks that the defines landed in `libapp.so`. Expect
   3–8 minutes.
4. Verify the bundle before uploading:

       AAB=build/app/outputs/bundle/release/app-release.aab
       unzip -p $AAB base/manifest/AndroidManifest.xml | strings | grep -E 'iosappv2|1\.0\.6'
       unzip -p $AAB base/manifest/AndroidManifest.xml | xxd | grep -A1 versionCode   # look for "99"
       /opt/homebrew/opt/openjdk@17/bin/keytool -printcert -jarfile $AAB | grep SHA256  # 1E:1B:ED:A0…

5. Hand the `.aab` to Adam for Play Console → Internal testing. The Chrome
   extension is blocked from `play.google.com` unless Adam allows the domain.
   A release with no testers reaches nobody: add Adam's Google account on the
   track.
6. First-run checks on the internal build (nobody has run this app on a
   device yet): launch, notification permission prompt, send one chat and
   get a reply, claim coins, confirm "Get more coins" is hidden, Settings →
   Google connect returns via `mythoslive://settings?...`, Google/Apple
   sign-in work.
7. Open the PR for the branch and merge to main so main stops building the
   wrong package. Then tell the next web/iOS release to use 100+.

## Known gaps

- Nothing on Android has been run on a device or emulator. If you want an
  emulator: `sdkmanager "system-images;android-36;google_apis;arm64-v8a"`
  then `avdmanager create avd`, and `npm run android` with it booted.
- The Play listing is still the old MyMate store page (name, screenshots,
  description, content rating, data safety). Updating it is Adam's job in
  Play Console; the runbook has the data-safety and content notes.
- `REVENUECAT_ANDROID_KEY`: create the Android app in RevenueCat, put its
  `goog_` key in `.env`, pass it as a `--dart-define` in
  `tool/build_android.sh` the way `tool/ios_release.sh` passes the iOS key.
  Until then, free coins and gifts only on Android.
- Upload key rotation after the first upload (password was in git history).

## Where to read more

- `docs/android-release-runbook.md` (on the branch): listing history, key,
  build, first-run checklist, Play Console notes.
- `docs/HANDOFF-android-port-2026-10-09.md`: the original brief and the
  session log from 2026-10-09.
- `docs/buildboy-2-summary-2026-10-28.md` section 2: Build Boy's own read of
  the package situation, which agrees with this file.
