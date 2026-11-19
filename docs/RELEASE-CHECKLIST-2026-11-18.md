# Release checklist — 2026-11-18

For whoever runs the next deploy. Everything here is either an action or a
number to check afterwards; the reasoning lives in the commits.

## Where things stand

| | |
|---|---|
| `main` | `3325b74` (PRs #20 and #21 merged ~13:42 UTC) |
| Version | `1.0.7+104` |
| Last deploy | `1.0.7+103`, commit `3715dcc`, 12:51 UTC |
| Undeployed | the version bump (#20) and the `/admin/platforms` page (#21) |

**Deploys are manual.** `deploy_log` shows every entry as "auto-logged by
`npm run deploy`" — that is the log line writing itself, not the deploy
triggering itself. Merging to `main` ships nothing.

## 1. Deploy

```bash
npm run deploy
```

That script already does the right things in the right order — preflight,
`wrangler d1 migrations apply --remote`, web build, `wrangler deploy`, verify,
log, domain assert, smoke test. **Migrations run before the worker goes live**,
which is what keeps a new column from taking down the write path for the gap
between the two. Use the script rather than running `wrangler deploy` by hand.

### Afterwards, check these

```bash
curl -s -o /dev/null -w "%{http_code}\n" -u "admin:$ADMIN_TOKEN" \
  https://logs.deeplovepoems.com/admin/platforms
```

- `/admin/platforms` → **200**. It returns **405 right now**, because the
  deployed worker predates the merge. That 405 is the current symptom and the
  single best check that the deploy landed.
- `/api/admin/platforms?hours=24` → **200** with JSON.
- The other admin pages → still 200 (`/admin`, `/api/admin/first30`,
  `/api/admin/delivery` were all 200 before this deploy).

## 2. Migrations — nothing to do by hand

`0023_client_platform` and `0024_platform_repair` are **already applied to the
remote D1**, verified against production:

- `message_delivery` and `conversation_logs` both have a `client_platform`
  column.
- `site_visits.platform` reads `direct` and no longer contains
  `chat.deeplovepoems.com` / `chat.deeploveechoes.com`, so 0024's repair ran.

`npm run deploy` applies anything new before deploying, so there is no separate
step. Do not run `wrangler d1 execute` by hand to "fix" a column.

## 3. Store builds — needed before the new page says much

`/admin/platforms` can only report what a client tells it, and only clients
built after `0023` say anything.

- **Web** is already wired: the deployed `main.dart.js` sends
  `x-client-platform`, so web traffic starts being attributed as soon as
  step 1 is done.
- **iOS and Android** report nothing until new store builds ship. Until then
  all app traffic lands in `(unattributed)` on the page.

So expect **low coverage at first** — the big number at the top of the page
will be well under 100%, and the banner explains why in the actual row counts.
That is the page working, not a fault. Do not read an early per-platform count
as "we have few iOS users"; it is a lower bound.

### 3a. Who builds, and from what (added by Build Boy, 2026-11-18)

The Android session was closed on 2026-11-18. **Build Boy (the Mac deploy
session) now owns the web deploy, the iOS build and the Android build.** One
build number for all three, cut from the same commit.

| Platform | In the store / live now | Next | Blocked on |
|---|---|---|---|
| Web + worker | 1.0.7+103 (`3715dcc`) | 1.0.7+104 from `main` | Adam's go |
| iOS | **1.0.7 (102), released 2026-11-12** | see "iOS version" below | a decision |
| Android | old listing still on versionCode 22 (Jan 2026). Nothing from the port has ever been uploaded | first upload | Adam: OAuth clients, Play upload |

**iOS version: 1.0.7 cannot be reused.** 1.0.7 is "Ready for Distribution" on
the App Store. Apple accepts a 1.0.7 (104) binary into TestFlight but will not
let a second 1.0.7 go to review; a new App Store version needs a higher
version string. So the store release has to be **1.0.8**, and since web, iOS
and Android share one `pubspec.yaml` line, the choice is:

- bump `main` to `1.0.8+105` and ship all three under it (recommended: one
  number everywhere, Settings reads the same on every client), or
- ship web as 1.0.7+104 today and bump to 1.0.8+105 only when the store
  builds are cut.

**iOS build** (`bash tool/ios_release.sh --ipa`, then `xcodebuild
-exportArchive` with the upload plist, team `TG5RWCPY3K`):

- Run it with `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` from a non-interactive
  shell, or CocoaPods dies with "Unicode Normalization not appropriate for
  ASCII-8BIT".
- Xcode's Apple account session expires every few days ("Failed to Use
  Accounts"). Adam re-signs in; rerun only the upload.
- The build rewrites four `Package.resolved` files. Commit them or the next
  `npm run deploy` preflight refuses the dirty tree.
- Submission: + Version, What's New, select the build, **Manually release**.
  The Chrome session for App Store Connect expires overnight.
- `RC_SANDBOX_CREDITS` is already `"false"`. Leave it.

**Android build** (`npm run build:android` → `tool/build_android.sh`):

- Signing files are now in the main checkout, gitignored:
  `android/key.properties` and `android/app/upload-keystore.jks` (copied from
  the closed session's worktree on 2026-11-18; master copy at
  `~/abldev/mymate/android/app/`). Upload cert SHA-256 starts `1E:1B:ED:A0`.
- `~/Downloads/mythos-live-1.0.7-103.aab` exists but was never uploaded and
  predates `client_platform`. **Do not upload it**; build fresh.
- Package stays `com.iosappv2.ai_boyfriend_chat`. Never "fix" it.
- Still Adam's, from `docs/play-submission-1.0.7.md`: (1) three Android OAuth
  clients in Google Cloud, or Google sign-in fails after the account picker;
  (2) the first upload to Play Internal testing, with a tester list;
  (3) the phone checklist. Build Boy can drive Play Console in Chrome once
  Adam allows `play.google.com` for the extension and signs in.
- Coin store stays hidden on Android (no RevenueCat Android app yet).

### 3b. One deployer

Three production deploys ran on 2026-11-18 (11:41, 12:03, 12:51 UTC) from the
shared checkout at `~/abldev/mymate2c`, none of them from the deploy session,
and the first two re-shipped a week-old commit. Nothing broke, but two
sessions building in one checkout can ship each other's half-finished tree.

- Deploys go through Build Boy, on Adam's word in that session. Other sessions
  hand over a brief (branch, expected commit, checks) rather than running
  `npm run deploy`.
- Other sessions work in a worktree, not in the main checkout. On 2026-11-18
  the main checkout had an uncommitted `pubspec.yaml` edit left in it.

## 4. Known-wrong, deliberately not in this release

**The dwell buckets across the admin pages read `duration_ms`, which is wall
clock, not attention.** On this traffic ~91% of exits are a backgrounded tab
rather than a close, and the clock keeps running in a browser nobody is looking
at. It reports a real 5.2s median as 32.7s. `visible_ms` is the honest column.

Nothing in this release touches it, so every dwell figure on the admin pages is
still wrong in the same flattering direction. Worth fixing next; not a reason
to hold this deploy.

## 5. There is no CI

No `.github/workflows`, no check runs on PRs. Verification is whatever a person
runs locally:

```bash
npm test          # 251 worker tests
flutter test      # 190 tests
flutter analyze   # 102 pre-existing infos, no errors — unchanged is the pass
```

All three were green on `main` at `3325b74` before this was written.
