# Mythos Live — fresh App Store submission

Written 2026-09-29. Decision: ship Mythos Live as a **new** App Store Connect
record with a new bundle ID, and retire the MyMate record we inherited with the
account. No live users, so nothing to migrate.

## What changed in the repo (this branch)

| | Before | After |
|---|---|---|
| Bundle ID (iOS + Android) | `com.aiboyfriend.mymate` | `com.sklabs.mythoslive` |
| Display name | MyMate | Mythos Live |
| Dart package | `ai_boyfriend_chat` | `mythos_live` |
| Version | 2.1.0+88 | 1.0.0+1 |
| Deep-link scheme | `mymate://` | `mythoslive://` |
| Android Kotlin package | `com.iosappv2.ai_boyfriend_chat` | `com.sklabs.mythoslive` |

Icons and splash were already Mythos Live (`assets/images/app_icon.png`,
`brand/mythoslive_splash.png`); nothing regenerated.

Things deliberately **not** changed, because they need a decision or an
external resource:

- **Privacy Policy / Terms links** in Settings still point at
  `sites.google.com/view/mymateapp` and `…/mymate-terms`. Apple requires a
  working privacy policy URL that matches the app name. Replace both once a
  Mythos Live page exists.
- **Apple team ID.** The Xcode project carries `TG5RWCPY3K` on the app target
  and `LZWE743LS4` on the test target. Confirm which is SK Labs in Xcode →
  Signing & Capabilities and set both to it.
- **Android upload keystore.** `android/app/build.gradle.kts` embeds the
  keystore passwords in plain text and the `.jks` is untracked. For the new
  Play listing generate a fresh keystore and move the passwords to
  `key.properties` (gitignored).
- **Session cookie names** on the Worker (`mymate_session`, `mymate_google_state`)
  are internal; renaming them would log every web user out. Left alone.
- **Worker name / D1 name** (`mymate2_db`) are infrastructure, not user-facing.

## Why Sign in with Apple is not needed

Google sign-in is rendered only when `kIsWeb` is true
(`settings_screen.dart`), and `AuthNotifier` returns signed-out on every
non-web platform. The native app is anonymous-only, so Guideline 4.8 does not
apply. If native Google login is ever added, Sign in with Apple must ship in
the same build.

## App Store Connect: steps in order

1. **Rename the old record.** Apps → *MythosLive: Chat to Greek Gods* → App
   Information → Name → e.g. `MyMate (retired)`. Save. The name is now free.
   Then Pricing and Availability → Remove from Sale (if any version is live).
2. **Register the App ID.** developer.apple.com → Certificates, Identifiers &
   Profiles → Identifiers → `+` → App IDs → App. Description `Mythos Live`,
   Bundle ID explicit `com.sklabs.mythoslive`. No capabilities needed.
3. **Create the new app.** App Store Connect → Apps → `+` → New App.
   Platforms iOS. Name `MythosLive: Chat to Greek Gods` (or the final
   choice). Primary language English (U.S.). Bundle ID: pick
   `com.sklabs.mythoslive`. SKU `mythoslive-ios`. Full access.
4. **Build and upload** on the Mac:
   ```
   flutter clean && flutter pub get
   flutter build ipa --release
   ```
   Then Xcode → Window → Organizer → Distribute App → App Store Connect, or
   `xcrun altool`/Transporter with the generated `.ipa` in `build/ios/ipa/`.
   Xcode automatic signing creates the provisioning profile for the new
   bundle ID the first time you archive.
5. **App Information.** Category: Entertainment (secondary: Social
   Networking or Lifestyle). Content rights: confirm you own or license all
   character art. Age rating questionnaire: answer honestly for AI chat with
   romantic themes; expect 17+ ("Unrestricted Web Access" no, "Mature/Suggestive
   Themes" frequent/intense if the characters flirt). Fill the new social-media
   questions (the banner on the Apps page): no user-to-user contact.
6. **App Privacy.** Data collected: User Content (chat messages, linked to
   user via anonymous id, used for App Functionality and Analytics), Identifiers
   (device/user ID), Usage Data. Not used for tracking. Privacy policy URL
   required here.
7. **Version 1.0 page.** Screenshots for 6.9" and 6.5" iPhone (6.9" mandatory)
   plus 13" iPad if iPad is supported (the plist supports iPad orientations, so
   either supply iPad screenshots or set iPad off in Build → General → Supported
   Destinations before archiving). Description, keywords, support URL,
   marketing URL, promotional text.
8. **App Review Information.** Contact name/phone/email. Notes: explain it is
   an AI companion chat with fictional Greek-myth characters, that responses
   are generated server-side by an LLM with a content filter, and that no
   account is required. Attach a demo video if the reviewer would otherwise
   need to chat for a while to see the features.
9. **Select the build**, submit for review.

## Google Play (if shipping Android)

New app in Play Console with package `com.sklabs.mythoslive`. Google Play
App Signing enrol with the new upload key. Data safety form mirrors the App
Privacy answers above. The `BILLING` permission in `AndroidManifest.xml` is
declared but no IAP exists; remove it to avoid the "why do you declare
billing" question, or leave it if coins-for-money is imminent.

## Likely review questions to have answers for

- **1.1.4 / 1.2 objectionable content.** What stops sexual or abusive
  generated content? Point at the Worker's system prompt and moderation.
- **5.1.1 data collection.** Chats are logged to D1. Say so in the policy.
- **2.1 completeness.** Every button must work: Instagram "coming soon" toast
  is borderline; either hide the Instagram tile on iOS or make it functional.
- **4.0 design.** iPad support must look right if left enabled.
