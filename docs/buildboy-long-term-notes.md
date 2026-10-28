# Build Boy: long-term notes

Written 2026-10-28 by Build Boy 2 (Windows session); corrected and extended
the same day by Build Boy (the Mac session, which did the deploys and
releases described here). Corrections are marked **[Mac]**.

**Where this came from.** The original "buildboy" session runs on the **Mac**
(`/Users/adam/abldev/mymate2c`). The Windows draft was rebuilt from git
history, the runbooks, and what the Windows sessions said; the Mac session
then went through it against what it actually ran.

---

## 1. What Build Boy is for

- It is the **deploy and release machine**. Feature sessions (Windows and cloud)
  stop at commit and push. Build Boy pulls, deploys from the branch Adam names,
  and keeps `main` fast-forwarded to whatever is live.
- It works on the Mac because only the Mac has all of these: `.env`
  (`APP_SECRET`, `CLOUDFLARE_ACCOUNT_ID`, `MYMATE_ADMIN_TOKEN`,
  `REVENUECAT_IOS_KEY`; `WORKER_URL` is defaulted by the scripts), an
  **authenticated wrangler**, Xcode with the SK Labs signing identity, and
  (since 2026-10-09) the Android SDK.
- Wrangler is **not** logged in on Windows. Cloud sessions can't reach
  `api.cloudflare.com` at all. So anything touching Cloudflare, App Store
  Connect or TestFlight goes through the Mac.
- Hand work to it with a pasted brief, and include the commit you expect it to
  land on so it can check (e.g. "Expect to land on 7f1fde6"). Before pushing
  or deploying it checks for other sessions' commits on the branch first; one
  deploy in October shipped another session's commit by accident because that
  check was skipped.

## 2. The deploy procedure

**Always `npm run deploy`. Never a bare `wrangler deploy`**, because a bare
deploy republishes whatever stale bundle is in `build/web`. The npm script runs
these in order:

```
preflight_deploy.sh            # refuses: worker name != mythoslive, dirty tree, --name override
wrangler d1 migrations apply mymate2_db --remote
build_web.sh release
wrangler deploy
verify_deploy.sh https://chat.deeploveechoes.com
log_deploy.sh                  # writes the deploy_log row
assert_domains.sh              # checks all three custom domains point at mythoslive
smoke_test.sh https://chat.deeplovepoems.com
```

- **[Mac]** `assert_domains.sh` is *not* a no-op on the Mac: every deploy since
  August has printed `ok: all 3 custom domains served by 'mythoslive'`. The
  account id is in `.env` and the token comes from the wrangler login.
- `ALLOW_DIRTY=1` overrides the dirty-tree check. Don't. **[Mac]** The right
  move is `git stash push -- <other session's file>` around the deploy, or
  `git checkout -- macos/ ios/Runner.xcworkspace ios/Runner.xcodeproj` for the
  SPM `Package.resolved` churn that every iOS/macOS build leaves behind.
- **[Mac]** A **transient D1 error 7403** ("account is not valid or is not
  authorized") hits `migrations list/apply` now and then. It aborts *before*
  anything ships; a straight re-run is the fix, not a rollback.
- **Migrations:** the script applies D1 migrations itself. The 2026-08-11
  runbook first said to avoid `migrations apply`. Build Boy corrected that in
  `3fd1256`: the tracking table exists, so already-applied migrations don't
  re-run. Check first with `wrangler d1 migrations list mymate2_db --remote`.
  Applied so far: 0001–0015, 0017 (coin packs, 2026-09-29), 0019 (gift
  reactions, 2026-10-07). 0016 belongs to the sign-in branch and 0018 is unused.
- **Order for a release that touches the worker:** web/worker first, iOS
  second, so the server is never behind the app.
- **Version bump on every release** (`Bump to X+N for <reason>`). It is the
  cheapest way to prove which build is live, because `verify_deploy.sh` compares
  `main.dart.js` only. Live `version.json` is the ground truth.
- Build numbers are **monotonic across web, iOS and Android** (one `+N` line).
  The version *string* can differ per platform when the App Store Connect
  version page demands it (web shipped 1.0.4+96, then the identical code was
  relabelled 1.0.5+96 for the submission).

## 3. Production facts

- The live Worker is **`mythoslive`**. It owns `chat.deeploveechoes.com`,
  `chat.deeplovepoems.com` and `logs.deeplovepoems.com`, and binds D1
  `mymate2_db`.
- **[Mac]** `mymate-v2` and `mymate2c` were **deleted** at Adam's request on
  2026-08-20 after the split-brain was fixed; they are not rollback copies any
  more. Rollback is: check out the previous tag/commit (every release is
  tagged or archived under `refs/archive/*`) and `npm run deploy`, or the
  Cloudflare dashboard's version rollback for the worker alone.
  `mymate-api` (old App Store build 1.39) was not touched from the Mac.
- **Cloudflare has no rename.** Changing `name` in `wrangler.jsonc` creates a new
  Worker and leaves the old one holding the domains. That caused the 21 July
  split-brain. See `docs/worker-migration-runbook.md`.
- **Secrets on the Worker** (`wrangler secret list`, 2026-10-28): `ADMIN_TOKEN`,
  `APP_SECRET`, `COIN_ALLOWLIST`, `GOOGLE_CLIENT_SECRET`, `INWORLD_API_KEY`,
  `OPENAI_API_KEY`, `RC_SECRET_KEY`, `RC_WEBHOOK_AUTH`.
  - **`APP_SECRET` is the dangerous one.** It is baked into the client at
    build time, so rotating it means rebuilding web *and* iOS in the same
    step. It also signs sessions, because `SESSION_SECRET` is unset.
  - `ADMIN_TOKEN` is still the value that leaked into a wrangler log on
    2026-08-08. Rotate it (Adam's action; `/admin/coins` now shows revenue).
  - `RC_SECRET_KEY` must be a RevenueCat **V1** secret key: the reconcile path
    calls `/v1/subscribers/<id>`. Verified working 2026-09-30 (a reconcile
    returned 200).
  - `RC_WEBHOOK_AUTH` is the Authorization value RevenueCat's webhook sends to
    `POST /api/rc/webhook`; wrong or missing → 401. Adam pasted the same value
    into the RevenueCat dashboard.
  - `wrangler secret put` only takes effect on the next deploy, and then needs
    time to propagate.
  - `INWORLD_API_KEY` is base64 of `key:secret`. A key from the wrong workspace
    returns a bare 403.
- **Plain vars** in `wrangler.jsonc`: `REQUIRE_CHAT_LOGS`, `REQUIRE_SIGNATURE`,
  `DELIVERY_LOGGING`, `COIN_LEDGER`, `RC_SANDBOX_CREDITS`, `PERSONA_TIGHTEN`,
  `APP_ORIGIN`, `ALERT_EMAIL_TO`, `ALERT_EMAIL_FROM`, `GOOGLE_CLIENT_ID`.
  - `COIN_LEDGER` is the coins kill switch. Live since 2026-08-24 (migration
    0014). `"false"` hides the UI and keeps balances.
  - **`RC_SANDBOX_CREDITS` is `"true"` in production** (since 2026-10-01) so
    App Review's sandbox purchases credit coins. **Set it to `"false"` and
    redeploy once Mythos Live is approved** — while it is on, anyone on
    TestFlight can mint coins for free.
- **Don't hand-verify with curl.** The edge serves a stale `main.dart.js` for a
  while, and a default curl user agent gets `403 error 1010`. Use
  `verify_deploy.sh`.
- Run `grep -a` on `backend/src/worker.js`. Without `-a`, grep treats the file as
  binary and reports false "no match". **[Mac]** The cause was two raw NUL
  bytes inside string literals; they are `\u0000` escapes since `bbe5b57`, but
  the `grep` in Claude's shell is a wrapper that still skips files it thinks
  are binary — use `/usr/bin/grep -a` before concluding code is missing.
- **Email alerts: NOT enabled.** **[Mac, confirmed 2026-10-28]**
  `npx wrangler email sending list` → "No sending subdomains found in this
  account." `npx wrangler email sending enable deeplovepoems.com` has never
  been run (no wrangler log of it on the Mac; the only email-related runs were
  a `list` on 2026-09-17 and a token scope on 09-09). The alert code is on
  `main` as `e2b1f36` but the live worker is still 1.0.5+96, so today
  `raiseOpsAlert` does nothing at all; after the next deploy it will log an
  `ops_alert` line and still send no email until the domain is enabled.
- Coin packs (RevenueCat, live on the worker since 2026-09-30): webhook
  `POST /api/rc/webhook` credits `purchase:<txn>` rows idempotently;
  `POST /api/wallet/reconcile` back-fills from RevenueCat; refunds write a
  negative row and the balance may go negative on purpose. Two sandbox test
  purchases on 2026-10-01 credited +300 each, so the whole path is proven.

Full detail is in `docs/operational-notes.md`, which this summarises.

## 4. iOS release (Mac only)

From `docs/HANDOFF-ios-build-2026-09-29.md` and `tool/ios_release.sh`, as run.

- Bundle ID **`com.sklabs.mythoslive`**. The old `com.aiboyfriend.mymate` is
  retired (its 2.0.0 build 86 is still sitting in App Store Connect — withdraw
  it, and plan to remove the old app from sale once Mythos Live is approved,
  or Apple may call the new one a duplicate under guideline 4.3). App Store
  Connect record "Mythos Live", Apple ID 6817279097, team SK Labs Limited
  Liability Company.
- `bash tool/ios_release.sh` does the following: pull, clean, pub get, precache,
  `pod install` (needs `LANG=en_US.UTF-8`), bake the release config into
  `Generated.xcconfig` and verify it, then open the workspace. It refuses to
  build without `APP_SECRET` and an `appl_` `REVENUECAT_IOS_KEY`, because
  native never loads `.env` and the fallback is the old project's sandbox key.
- **Don't run `flutter build` or `flutter run` between the script and Product →
  Archive.** Either one rewrites the config.
- **[Mac] Signing:** automatic, team **`TG5RWCPY3K` = SK Labs** (the
  distribution certificate is "Apple Distribution: SK Labs Limited Liability
  Company (TG5RWCPY3K)"). `LZWE743LS4` is the other team id left on the
  RunnerTests target; harmless. The Windows draft had these the wrong way
  round.
- **[Mac] How uploads were actually done:** `bash tool/ios_release.sh --ipa`
  builds and verifies the IPA, then
  ```
  xcodebuild -exportArchive -archivePath build/ios/archive/Runner.xcarchive \
    -exportOptionsPlist ExportOptions-upload.plist -exportPath <dir> \
    -allowProvisioningUpdates
  ```
  with a plist of `method=app-store-connect`, `destination=upload`,
  `teamID=TG5RWCPY3K`, `signingStyle=automatic`, `uploadSymbols=true`,
  `manageAppVersionAndBuildNumber=false`. Keep that plist somewhere
  permanent (it lived in a scratch dir and got wiped once). Transporter is the
  fallback.
- **Xcode's Apple-account session expires every few days.** The upload then
  fails with "Failed to Use Accounts … App Store Connect access for
  TG5RWCPY3K is required". Adam re-signs in (Xcode ▸ Settings ▸ Apple
  Accounts), then re-run only the `exportArchive` — no rebuild. An App Store
  Connect API key would remove this dependency; the `AuthKey_TQS4N73K74.p8`
  in `~/.appstoreconnect/private_keys/` is **not** on the SK Labs team's API
  keys page, so a new key is needed if we go that way.
- Apple's "Sending SPI analysis" step sometimes takes 10+ minutes; it is not
  stuck.
- **[Mac] Screenshots:** App Store Connect's *required* slot is now "iPhone
  with Dynamic Island (medium display)" — 1179×2556 or 1206×2622. The 6.5"
  set (1242×2688) is optional. `flutter build ios --simulator` fails on this
  Mac ("Failed to copy Flutter framework", exit 255); what works is
  `xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration
  Debug -sdk iphonesimulator -derivedDataPath build/ios/DerivedData build`
  after `flutter build ios --release --config-only <dart-defines>`, then
  `xcrun simctl install`/`launch`, and `xcrun simctl io <udid> screenshot`
  on an iPhone 17 (1206×2622). Xcode 27 ships no Simulator.app, so devices
  are headless and the software keyboard can't be toggled off. The seven
  shots are in `~/Desktop/mythoslive-shots-1206x2622/`.
- **[Mac] App Store Connect automation** (Chrome extension): long text fields
  must be set with `focus(); select(); document.execCommand('insertText', …)`
  then a real Save click — simulated keystrokes freeze the page and the save
  silently reverts. File inputs live in shadow DOM: give one an id via JS,
  `find` it, then `file_upload`. "Add for Review" on the version shows a red
  "Unable to Add for Review" banner for a few seconds listing what is
  missing (it was the Privacy Policy URL under App Privacy and a price tier).
  First-time consumables: "Add for Review" on the *version* creates the draft
  submission; each product's "Add for Review" ▸ pick that draft (the first
  click after a page load often does nothing — click again). Reload after
  every save and read the field back; this page lies.
- Releases are set to manual, so approval does not publish. Adam presses
  release.
- **[Mac] Release line:** 1.0.0+89 and +90 (TestFlight) → 1.0.2+92 → 1.0.2+93
  (iPhone-only, `TARGETED_DEVICE_FAMILY=1`) → 1.0.3+94 → 1.0.4+95 "Golden
  Laurel" → **1.0.5+96 submitted 2026-10-09 12:36** (submission `ca684bb0`:
  the app plus the three coin products, all "Waiting for Review"; outcome not
  visible from the Mac since — the Chrome session expired). Deployment floor
  stayed iOS 16.0 (Adam leaned 17; undecided). Native Google/Apple sign-in was
  merged for 1.0.6+98 on 2026-10-28 — **not built or deployed yet**; live web
  is still 1.0.5+96.

## 5. Android release

From `docs/android-release-runbook.md`, which exists only on
`origin/android/play-parity` and `origin/claude/competent-mendel-a4d1d2`, not
on `main`.

- **[Mac]** Builds also run on the Mac now: `npm run build:android`
  (`tool/build_android.sh`) produced `mythos-live-1.0.5-97.aab` on
  2026-10-09 (handed to Adam in `~/Downloads`; Internal testing; not
  device-tested — no emulator image or device on the Mac yet).
- **Upload key:** `android/app/upload-keystore.jks`, alias `upload`, plus
  `android/key.properties`. Gitignored. **[Mac]** Copies of the keystore are
  at `~/abldev/mymate/android/app/` (and two `MyMate1.3x` checkouts) on the
  Mac, not only on ablegion7. The password was committed in plain text in
  `build.gradle.kts` up to `feat/star-gift`; after the first good upload,
  consider Play Console ▸ App integrity ▸ "Request upload key reset".
- Play App Signing is on, so Google holds the app signing key. Play's upload
  cert SHA-256 starts `1E:1B:ED:A0`.
- **[Mac] The settled package name:** `applicationId` =
  **`com.iosappv2.ai_boyfriend_chat`** (the existing listing's identity; a Play
  package can never change; Adam's decision 2026-10-09). Kotlin namespace and
  the iOS bundle id stay `com.sklabs.mythoslive`. Never "fix" the mismatch.
  The runbook's mention of `com.aiboyfriend.mymate` is history (the Gradle
  namespace *before* the rebrand), not a contradiction. The runbook says this
  correctly as of `5e2aed5`.
- **[Mac] Not on `main` yet:** `5e2aed5` ("ship Mythos Live under the existing
  Play listing, 1.0.5+97") is on `claude/competent-mendel-a4d1d2`, not `main`.
  `main`'s `android/app/build.gradle.kts` still says `com.sklabs.mythoslive`,
  which would not install over the Play listing. Merging it conflicts only in
  `pubspec.yaml` (keep `main`'s 1.0.6+98). The email-alert commit `b906276`
  from `android/play-parity` is already on `main` as `e2b1f36`.
- **Don't declare `BILLING`** until a Play Billing Library (RevenueCat) is
  actually in. Play rejected the first 2.0.0 upload for it. There is no
  `REVENUECAT_ANDROID_KEY` yet, so the coin store hides itself on Android.
- No `AD_ID` and no ads SDK, so answer "no" on the advertising ID declaration.
- Every upload needs a higher versionCode: 97 is taken; next is 99+ (98 is
  `main`'s 1.0.6).

## 6. Working habits worth keeping

- **Several sessions push to the same branch.** Expect rejected pushes. Read
  what landed before rebasing, and never force-push.
- Before a merge, Build Boy reviewed the other sessions' commits and kept
  trivial differences, such as comments on the Mac side.
- Don't create synthetic prod traffic for verification. **[Mac]** The
  supported probe is a signed request with `x-synthetic-test: 1` and a
  non-real user id (`smoke-test-manual`): the worker answers normally but
  writes nothing to `conversation_logs` or the coin ledger. That is what
  `smoke_test.sh` does too.
- `ADMIN_TOKEN` in Windows `.env` is a dev value, so prod admin returns 401
  from here. Treat the Worker as authoritative.
- **[Mac]** Chrome's App Store Connect login and Xcode's Apple-account session
  both expire on their own schedule; the first sign of either is a failed save
  or a "Failed to Use Accounts" upload. Adam has to re-sign in; nothing in the
  repo can.

## 7. Mac-only setup (so it can be rebuilt)

- Flutter 3.44.6 (Homebrew), Xcode 27.0, CocoaPods 1.16.2, `node`/`npm` for
  wrangler 4.x, `wrangler login` done.
- Android: Homebrew `openjdk@17` and the cask `android-commandlinetools`;
  SDK at `~/Library/Android/sdk` with platform-tools, platforms android-35
  and android-36, build-tools 35.0.0 and 36.0.0; `flutter config
  --android-sdk … --jdk-dir …` set. `flutter doctor` reports "Android license
  status unknown" — cosmetic (Google deprecated `sdkmanager --licenses`;
  Gradle reads `~/Library/Android/sdk/licenses`).
- The MCP iOS Simulator panel streams the headless simulators; Claude in
  Chrome is what drives App Store Connect, and it refuses `play.google.com`
  until Adam allows that domain in the extension.

## 8. Open items (as of 2026-10-28)

1. **Apple review of 1.0.5 (96)** — submitted 2026-10-09; outcome unknown from
   the Mac. Check App Store Connect ▸ App Review. Release is manual.
2. **After approval:** `RC_SANDBOX_CREDITS` → `"false"`, `npm run deploy`, then
   Release. Then withdraw/remove the old `com.aiboyfriend.mymate` app.
3. **1.0.6+98** (sign-in, content sweep, ops alert) is on `main` but not built
   or deployed; needs the usual web → iOS order, a new TestFlight build and a
   new submission.
4. **Email alerts:** run `npx wrangler email sending enable deeplovepoems.com`
   on the Mac (account owner), deploy, then test with a forced out-of-credit
   response.
5. **Android:** merge `5e2aed5` into `main` (keep 1.0.6+98), back up the
   upload key off both machines, next versionCode 99+.
6. **Rotate `ADMIN_TOKEN`.**
7. Decide the iOS deployment floor (16 vs 17).
8. Entry-card A/B `entry-cta-20260825` is still running — retire it if there is
   no clear winner.
9. `logs.deeplovepoems.com` still serves the app for non-admin paths. Known
   and deliberate.
