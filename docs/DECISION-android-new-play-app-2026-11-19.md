# Decision: Mythos Live is a NEW Google Play app (2026-11-19)

**This supersedes the 2026-10-09 decision** recorded in
`android-release-runbook.md`, `play-submission-1.0.7.md`,
`HANDOFF-android-port-2026-10-09.md`, `HANDOFF-android-2026-10-28.md`,
`buildboy-long-term-notes.md`, `buildboy-2-summary-2026-10-28.md` and
`RELEASE-CHECKLIST-2026-11-18.md`. Where those say the Android app ships
under `com.iosappv2.ai_boyfriend_chat` "on purpose, never fix it", they are
out of date.

## What Adam decided

Adam, 2026-11-19: "we don't want Mythos Live to use mymate, we want it to be
new app."

Mythos Live does not ship as an update to the previous owner's listing
"MyMate: AI Boyfriend Chat". It gets its own Play app, the same way iOS got
a new App Store app (`com.sklabs.mythoslive`, 2026-09-29).

## What changed in the code (build 1.0.8+106)

| | Before | Now |
|---|---|---|
| `applicationId` (`android/app/build.gradle.kts`) | `com.iosappv2.ai_boyfriend_chat` | `com.sklabs.mythoslive` |
| Kotlin namespace | `com.sklabs.mythoslive` | unchanged |
| Android update link (`backend/src/catalogue.js`) | old listing | `…details?id=com.sklabs.mythoslive` |

A Play package can never change once an app exists under it, so this is the
last time this id moves.

## What it means

- **A listing from zero.** Store text, icon, feature graphic, phone
  screenshots, content rating, data safety, target audience, privacy policy
  URL (`https://chat.deeplovepoems.com/privacy`). The text in
  `play-submission-1.0.7.md` step 4 still applies.
- **New signing identity.** A new Play app gets a new Play app-signing key,
  so the Android OAuth client for Google sign-in needs the NEW app's SHA-1
  and package `com.sklabs.mythoslive`. The fingerprints read from the MyMate
  listing on 2026-11-19 do not apply.
- **Upload key.** The first upload to the new app registers its upload key.
  The old keystore's password was in git history until October, so use a
  freshly generated keystore for the new app rather than carrying the old
  one over.
- **Existing MyMate users (about 179 monthly active devices) do not get
  Mythos Live as an update.** The MyMate listing stays as it is unless Adam
  decides to retire it or point it at the new app.
- **The MyMate listing was not changed.** Build 105 (1.0.8) was uploaded to
  its Internal testing track on 2026-11-19 and saved as a DRAFT only, never
  rolled out. That draft should be discarded.
- SK Labs LLC is an organization account, so the new app has no
  closed-testing waiting period before production.

## Still to do

1. Create the app in Play Console (SK Labs LLC): name "Mythos Live",
   package set by the first upload. Adam accepts the declarations.
2. Generate the new upload keystore; update `android/key.properties`.
3. Build 1.0.8 (106), upload to Internal testing, add testers.
4. Android OAuth client(s) in Google Cloud with the new SHA-1.
5. Fill in the listing and app-content forms before production.
