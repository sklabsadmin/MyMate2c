# For Build Boy 2: answers from the Mac, 2026-10-28

Short version of what the Mac session found when it reviewed
`docs/buildboy-long-term-notes.md`. The full corrected notes are in that file;
this is just the three things you asked about, plus what still needs a human.

## 1. Cloudflare Email Sending has never been enabled

- `npx wrangler email sending list` on the Mac (2026-10-28):
  "No sending subdomains found in this account."
- `npx wrangler email sending enable deeplovepoems.com` has not been run from
  the Mac (no wrangler log of it; the only email-related runs were a `list` on
  2026-09-17 and an OAuth token with `email_sending` scope on 2026-09-09).
- The alert code (`b906276`, now `e2b1f36` on `main`) is **not live** either:
  production worker is still 1.0.5+96. Until both happen, an out-of-credit
  response produces no email.
- To do: Adam (account owner) runs the `enable` command on the Mac, then
  Build Boy deploys `main` and forces one out-of-credit reply to prove the
  email arrives at `adamlang@me.com`.

## 2. The Play package name is settled

- `applicationId` = **`com.iosappv2.ai_boyfriend_chat`** — the existing Play
  listing's identity (164 installs, Play App Signing on). A Play package can
  never change. Adam chose this on 2026-10-09 over starting a new listing.
- Kotlin namespace and the iOS bundle id stay **`com.sklabs.mythoslive`**.
  The mismatch is deliberate; never "fix" it.
- `docs/android-release-runbook.md` already states this correctly. Its
  mention of `com.aiboyfriend.mymate` is history (the Gradle namespace before
  the rebrand), not a contradiction.
- The real gap: that runbook and that `applicationId` exist only on
  `origin/claude/competent-mendel-a4d1d2` (commit `5e2aed5`, 1.0.5+97).
  **`main` still says `com.sklabs.mythoslive`** in `android/app/build.gradle.kts`,
  so a build from `main` would not install over the Play listing. Merging
  `5e2aed5` into `main` conflicts only in `pubspec.yaml` (keep `main`'s
  1.0.6+98). Next Android versionCode is 99+ (97 used, 98 is `main`).

## 3. Corrections to the Windows draft

| Draft said | Actually |
|---|---|
| `assert_domains.sh` is a no-op until Cloudflare vars are set | It runs on every Mac deploy and reports all three domains on `mythoslive` |
| `mymate-v2` and `mymate2c` are frozen rollback copies | Both were deleted on 2026-08-20 at Adam's request; rollback = checkout the previous tag/`refs/archive/*` and `npm run deploy`, or the dashboard's version rollback |
| `TG5RWCPY3K` and `LZWE743LS4` are the old owner's team ids | `TG5RWCPY3K` **is** SK Labs (the distribution cert says so); `LZWE743LS4` is a leftover on RunnerTests only |
| Secrets: `APP_SECRET`, `OPENAI_API_KEY`, `GOOGLE_CLIENT_SECRET`, `INWORLD_API_KEY`, `ADMIN_TOKEN` | Plus `COIN_ALLOWLIST`, `RC_SECRET_KEY` (RevenueCat V1), `RC_WEBHOOK_AUTH`. And the plain var `RC_SANDBOX_CREDITS` is `"true"` in production until Apple approves |
| Screenshots: only the 6.5" set | The required slot is now "iPhone with Dynamic Island (medium)", 1179×2556 or 1206×2622; 6.5" is optional. Captured via `xcrun simctl io … screenshot` on an iPhone 17 |
| Upload via Transporter | Uploads were done with `xcodebuild -exportArchive … destination=upload`; they fail every few days with "Failed to Use Accounts" until Adam re-signs in to Xcode |
| "2026-10-09, on `main`: ship under the existing Play listing (1.0.5+97)" | That commit is on `claude/competent-mendel-a4d1d2`, not `main` |
| Android keys exist only on ablegion7 | Keystore copies are also on the Mac at `~/abldev/mymate/android/app/` |

## What still needs a human

1. Apple's decision on **1.0.5 (96)** (submitted 2026-10-09, `ca684bb0`) is
   unknown from the Mac — Chrome's App Store Connect session expired.
2. After approval: `RC_SANDBOX_CREDITS` → `"false"`, deploy, Release.
3. `wrangler email sending enable deeplovepoems.com` (item 1 above).
4. Merge `5e2aed5` into `main` (item 2 above) — Build Boy can do it on request.
5. `1.0.6+98` on `main` is unbuilt and undeployed.
6. Rotate `ADMIN_TOKEN`.
