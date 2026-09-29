# Handoff: build and upload Mythos Live 1.0 for iOS

Written 2026-09-29. For whoever has the Mac with Xcode and the SK Labs
signing identity. Everything on the App Store Connect side is already done
except the build itself and the screenshots. This is the Mac half.

## Where things stand

| | |
|---|---|
| Branch | `claude/mythos-live-apple-connect-xamzaj` |
| Bundle ID | `com.sklabs.mythoslive` (new; the old `com.aiboyfriend.mymate` is retired) |
| Version | 1.0.0, build 1 (`pubspec.yaml` → `1.0.0+1`) |
| Apple team | SK Labs Limited Liability Company |
| App Store Connect record | "Mythos Live", Apple ID 6817279097, status "1.0 Prepare for Submission" |
| App ID in developer portal | registered, no capabilities |
| Tests | `flutter analyze` clean (164 pre-existing infos), `flutter test` 90/90 |

Metadata, age rating (18+), privacy labels, DSA trader status and the
encryption declaration are all done in App Store Connect / the plist. The
record is waiting on a build and on screenshots.

## What changed on this branch (so nothing surprises you)

- Bundle ID, display name ("Mythos Live"), Dart package (`mythos_live`),
  deep-link scheme (`mythoslive://`) and Android package all renamed.
- `ITSAppUsesNonExemptEncryption = false` added to `ios/Runner/Info.plist`.
- Google sign-in prompts are now web-only. On iOS the 20-reply login gate,
  the post-profile-save "Continue with Google" sheet and the "Sign in with
  Google" coins row no longer appear. Native has no auth in 1.0; it ships
  anonymous-only. Sign in with Apple is planned for 1.1.
- `tool/ios_release.sh` added (see below).

## Do this

```
cd /Users/adam/abldev/mymate2c        # or wherever the checkout is
git fetch origin claude/mythos-live-apple-connect-xamzaj
git checkout claude/mythos-live-apple-connect-xamzaj
bash tool/ios_release.sh
```

The script pulls, `flutter clean`, `flutter pub get`, `flutter precache --ios`,
wipes and re-runs `pod install --repo-update`, then opens
`ios/Runner.xcworkspace`. If `pod` is missing: `sudo gem install cocoapods`
or `brew install cocoapods`.

Then in Xcode:

1. Runner target → **Signing & Capabilities**.
   - Team: **SK Labs Limited Liability Company**.
   - Bundle Identifier must read `com.sklabs.mythoslive`.
   - "Automatically manage signing" on. Xcode creates the provisioning
     profile for the new App ID the first time.
   - The project file carries two team IDs from the previous owner
     (`TG5RWCPY3K` on Runner, `LZWE743LS4` on RunnerTests). Pick the SK Labs
     team in the dropdown for **both** targets and let Xcode rewrite them.
     Commit the pbxproj change afterwards.
2. Device selector at the top: **Any iOS Device (arm64)**.
3. **Product → Archive**.
4. Organizer → **Distribute App → App Store Connect → Upload**. Accept the
   defaults (include symbols, manage version automatically is fine).
5. Wait for the "processing complete" email (5–30 min).

Alternative without Xcode UI: `bash tool/ios_release.sh --ipa` produces
`build/ios/ipa/mythos_live.ipa`; upload it with Transporter.app.

## Screenshots (needed before submit, only one size)

App Store Connect only asks for the **6.5" iPhone** set now. Use the
simulator **iPhone 11 Pro Max** or **iPhone 15 Plus**:

```
open -a Simulator
flutter run -d "iPhone 15 Plus" --release
```

Take **Cmd+S** in the Simulator on each of these (saves 1242×2688 PNGs to
the Desktop, which is the exact size Apple wants):

1. Dashboard with the Greek roster
2. A chat a few messages in (Odysseus or Calypso)
3. A character profile card (tap the portrait in a chat)
4. The coins sheet with a gift row visible (tap the gold coin chip)
5. The daily "Claim Coins" screen

Note the simulator build talks to the production Worker, so chat replies
are real. If chat shows "Invalid signature", the build lacks `APP_SECRET`;
run instead with the value from `.env`:

```
flutter run -d "iPhone 15 Plus" --release --dart-define=APP_SECRET=$(grep APP_SECRET .env | cut -d= -f2)
```

Send the PNGs to Adam, or upload them yourself on the 1.0 version page under
Previews and Screenshots → iPhone.

## Sanity checks on the device before uploading

Run once on a real iPhone or the simulator and confirm:

- Home screen shows the ship medallion icon and the name "Mythos Live".
- Chatting past 20 replies with one character does **not** show a Google
  sign-in wall.
- Saving a profile shows "Saved on this device" and no Google sheet.
- The coins sheet has no "Sign in with Google" row.
- Settings → Contact Support opens Mail to `admin@sklabs.us`.

## After the build shows in App Store Connect

Adam does this part, but for completeness: 1.0 version page → Build section
→ **+** → pick build 1 → Save → **Add for Review** → Submit. Version release
is set to manual, so approval does not publish automatically.

## Known leftovers, not blocking

- Settings still links to the old MyMate privacy/terms pages on Google
  Sites. Needs a Mythos Live page and a two-line swap in
  `lib/src/features/settings/presentation/settings_screen.dart`.
- Android keystore passwords are plain text in `android/app/build.gradle.kts`.
  Fix before the Play submission, not needed for iOS.
- iPad: the plist declares iPad orientations, so Apple may ask for iPad
  screenshots if iPad is a supported destination. If you would rather not
  supply them, untick iPad under Runner → General → Supported Destinations
  before archiving.
