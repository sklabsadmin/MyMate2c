# Mythos Live 1.0.7 on Google Play: submission pack

Written 2026-11-12. The Android counterpart of
`docs/app-store-submission-1.0.7.md`. Build: **1.0.7 (103)**, bundle at
`~/Downloads/mythos-live-1.0.7-103.aab` on Adam's Mac.

Play listing: the existing app **"MyMate: AI Boyfriend Chat"**, package
`com.iosappv2.ai_boyfriend_chat`, SK Labs LLC. It gets renamed, not replaced.

## What is in this build

Everything iOS 1.0.7 has, except two things that are off on purpose:

| | Android 1.0.7 (103) |
|---|---|
| Chat, personalities, remote catalogue, Ada | yes |
| Earned coins, daily claim, gifts, leaderboards | yes |
| Notifications from personalities | yes |
| Sign in with Google, account section, delete account | yes, needs step 1 below |
| Sign in with Apple | no, hidden on Android |
| Buying coins | no, store hidden until RevenueCat has an Android app |

## Step 1 — Google Cloud: three Android OAuth clients

Without these the Google button opens its sheet and then fails. Same Google
Cloud project as the existing web client (`791029751937-vf4kbp…`), APIs &
Services ▸ Credentials ▸ Create credentials ▸ OAuth client ID ▸ Android.
One client per certificate. Package name for all three:

    com.iosappv2.ai_boyfriend_chat

| Client name (suggested) | SHA-1 | Covers |
|---|---|---|
| Mythos Live Android (Play signing) | from Play Console ▸ Test and release ▸ App integrity ▸ App signing ▸ "App signing key certificate" | everyone who installs from Play, including Internal testing |
| Mythos Live Android (upload key) | `E5:AB:1B:1B:1F:B4:CE:CB:CB:EE:82:97:BB:60:B4:C1:E9:33:45:43` | release APKs sideloaded from the Mac |
| Mythos Live Android (debug) | `3F:03:97:E6:C8:E7:CB:80:61:37:C4:2F:98:C3:11:2B:A2:A9:71:6C` | `npm run android` on this Mac's emulator |

Nothing to paste back into the code or the worker: the app already asks for
a token addressed to the web client, and the worker already accepts it.
The first row is the one that matters for testers.

## Step 2 — Play Console: Internal testing

1. Test and release ▸ Testing ▸ Internal testing ▸ Create new release.
2. Upload `mythos-live-1.0.7-103.aab`.
3. Release name: `1.0.7 (103)`. Release notes: "What's new" below.
4. Testers tab: add a list with your own Google account. A release with no
   testers reaches nobody.
5. Save ▸ Review ▸ Start rollout to Internal testing.
6. Open the opt-in link from the Testers tab on your phone, accept, install.

If Play raises a warning or blocks the upload, copy the exact text back to
the Android session.

## Step 3 — Phone checklist

All of this passed on the emulator (Android 16) on 2026-11-12 except the
items marked ★, which need a real phone or a real Google account.

- [ ] Icon on the home screen is the medallion on cream, no black ring.
- [ ] Launch: cream splash with the medallion, then the home screen. The
      notification prompt appears over the home screen, not over the splash.
- [ ] Open a personality, claim coins, send a message, get a reply.
- [ ] Coin chip ▸ sheet shows "Sign in with Google" in How to earn, and no
      "Get more coins" button.
- [ ] Send Roses. Coins drop by 50, the rose appears.
- [ ] Trophy ▸ Leaderboards open and show "You #n" where you gave a gift.
- [ ] Settings ▸ Version reads `1.0.7 build 103 · server build …`.
- [ ] ★ Settings ▸ Continue with Google: pick your account, land back in
      Settings signed in, coins +100.
- [ ] ★ Sign out, sign back in: coins and chats come back.
- [ ] ★ Uninstall, reinstall, sign in: coins come back. (Without sign-in a
      reinstall starts from zero on Android. That is expected.)
- [ ] ★ Delete account from Settings works and returns to signed-out.
- [ ] ★ Leave the app for a few hours with notifications allowed: a
      "<Name> says" notification arrives with a small speech-bubble icon.
      Tap it: that conversation opens.

## Step 4 — Listing, before promoting to Production

Not needed for Internal testing. Needed before the public sees it.

**App name (30):** `Mythos Live`

**Short description (80):**

    Talk with the heroes and gods of Greek myth. Pick a legend and start a story.

**Full description (4000):** use the Description from
`docs/app-store-listing-1.0.md` plus the leaderboard bullet from
`docs/app-store-submission-1.0.7.md`, with three edits for Play:
- remove the sentence that states an age;
- "No sign-up, no waiting" stays true (sign-in is optional);
- say "personalities" where it reads naturally.

**What's new (500):**

    Mythos Live arrives on Android.
    • Talk with Odysseus, Penelope, Zeus and more, plus a modern roster.
    • The personalities you talk to most send you a line of their own.
    • Leaderboards: see where you stand with each one.
    • Sign in with Google to keep your coins and chats across devices.

**Graphics:** new icon (512), feature graphic (1024×500), at least two phone
screenshots. The Android session can capture screenshots from the emulator
on request.

**Store settings:** category Entertainment. Contact `admin@sklabs.us`.
Privacy policy: `https://chat.deeplovepoems.com/privacy`.

**App content:**
- Ads: No.
- Advertising ID: No (no ads SDK, no AD_ID permission in the bundle).
- In-app purchases: the bundle includes Play Billing (via RevenueCat) but
  sells nothing yet. Declare none until products exist.
- Content rating: redo the questionnaire. AI-generated fictional
  personalities, no user-to-user messaging, no user content visible to
  others, mild suggestive themes at most.
- Target audience: adults only.
- Data safety, collected and linked to the user, not shared, not for ads:
  - Messages (chat text) — app functionality.
  - User IDs (device-generated id; Google account id when signed in) — app
    functionality, account management.
  - Name (profile name, sent with gifts; Google name when signed in) — app
    functionality.
  - Email address (from Google, when signed in) — account management.
  - Purchase history: none on Android yet.
  - Data is encrypted in transit. Users can request deletion: in-app
    Settings ▸ Delete account.
- Account deletion URL (Play requires one when sign-in exists): the support
  page, stating that deletion is in Settings ▸ Delete account.

## After the first successful upload

1. Play Console ▸ App integrity ▸ request an **upload key reset**. The old
   key's password was in git history until October. Generate the new key on
   the Mac, update `android/key.properties`, and replace the SHA-1 in the
   "upload key" OAuth client above.
2. Raise `min_build.android` in `backend/src/catalogue.js` only once a
   build is live in Production. The update link now points at the right
   Play page (it pointed at a package that does not exist until this build's
   branch); that fix goes live with the next worker deploy.

## Still open after this build

- Coin store on Android: RevenueCat Android app (`goog_` key), Play
  products `mythos_coins_300/1000/3000`, service account, then pass
  `REVENUECAT_ANDROID_KEY` in `tool/build_android.sh`.
- Sign in with Apple on Android (web flow + worker redirect).
- The home header truncates the greeting ("Welcome, Good After…") on a
  1080-wide phone. Cosmetic, shared layout.
- An Android 8 (minimum supported) run: the emulator image would not boot on
  Apple Silicon. Verified on Android 16 only.
