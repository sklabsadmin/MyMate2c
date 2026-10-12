# Handoff: iOS App Clip for Mythos Live

Written 2026-10-12 from a Linux session (no Xcode, no Mac). Everything that
can be done in files is done on branch `claude/wonderful-bell-fscjat`; what
remains needs a Mac, the SK Labs signing identity, and App Store Connect.

## What the Clip is

Tap a campaign link (`https://chat.deeploveechoes.com/c/odysseus`) on an
iPhone without the app and iOS shows an App Clip card; "Open" launches a
cut-down Mythos Live straight into that character's chat, no install. A strip
under the whole app says it is a preview and opens the App Store overlay for
the full app.

The Clip is the **same Dart code** as the app, built as a second Xcode target
that shares `App.framework`. There is no second entrypoint; Dart learns it is
inside the Clip at startup (`AppClip.detect()` in `lib/main.dart`, which asks
a channel only the Clip's AppDelegate registers). In Clip mode:

- the router opens on the invocation link's `/c/<id>` (`routeForInvocation`,
  tested in `test/app_clip_invocation_test.dart`), else the dashboard;
- `RevenueCatService.isSupported` is false, so every "Get coins" affordance
  hides itself (in-app purchase is reserved for the full app by Apple);
- notifications are never initialised or scheduled;
- the custom URL scheme is absent from the Clip's Info.plist (not allowed);
- `AppClipStrip` sits under the UI and calls `SKOverlay` (AppClipConfiguration).

## Files on this branch

| Path | What |
|---|---|
| `ios/MythosLiveClip/AppDelegate.swift` | Clip app delegate: plugin registration, `mythoslive/app_clip` channel (`invocationUrl`, `showAppStoreOverlay`) |
| `ios/MythosLiveClip/ClipSceneDelegate.swift` | `FlutterSceneDelegate` subclass that catches the invocation `NSUserActivity` |
| `ios/MythosLiveClip/Info.plist` | Runner's plist minus `CFBundleURLTypes`, plus `NSAppClip`, scene delegate swapped |
| `ios/MythosLiveClip/MythosLiveClip.entitlements` | on-demand-install-capable, parent app id, `appclips:` domains |
| `ios/Runner/Runner.entitlements` | **new for the full app**: `applinks:` for both domains (Apple wants the domains on both targets) |
| `ios/Flutter/AppClip-{Debug,Release,Profile}.xcconfig` | base configs for the Clip target, same shape as Runner's |
| `ios/Podfile` | `target 'MythosLiveClip'` with `flutter_install_all_ios_pods` |
| `ios/Runner.xcodeproj/project.pbxproj` | the Clip target, Runner's "Embed App Clips" phase and dependency, `CODE_SIGN_ENTITLEMENTS` on Runner |
| `ios/Runner.xcodeproj/xcshareddata/xcschemes/MythosLiveClip.xcscheme` | scheme with `_XCAppClipURL` preset to the Odysseus link |
| `tool/ios_add_app_clip.rb` | the script that produced the pbxproj changes (xcodeproj gem). Idempotent; only needed again if the target is deleted |
| `lib/src/core/services/app_clip.dart` | `AppClip` (detect, isActive, invocationUrl, showAppStoreOverlay) and `routeForInvocation` |
| `lib/src/features/app_clip/presentation/app_clip_strip.dart` | the "Get the full app" strip |
| `lib/main.dart`, `lib/src/app.dart`, `revenue_cat_service.dart` | the Clip-mode branches described above |
| `web/.well-known/apple-app-site-association` | `appclips` + `applinks` entries. **Contains the placeholder `TEAMID`** |
| `web/_headers` | serves the association file as `application/json` |
| `web/index.html` | Smart App Banner meta with `app-clip-bundle-id` |

`flutter analyze` adds nothing new (pre-existing warnings only), `flutter test`
100/100.

## Not verified, because there is no Xcode here

The project file was written by script, not by Xcode, and has never been
built. Expect the first open to need small corrections. The things most
likely to need a hand:

1. **`pod install` must run** before the workspace builds, so the
   `Pods-MythosLiveClip.*.xcconfig` files the new xcconfigs include exist.
   `tool/ios_release.sh` does this; so does a plain `cd ios && pod install`.
   `Podfile.lock` will gain a `MythosLiveClip` section; commit it.
2. **`FlutterSceneDelegate` subclassing.** `ClipSceneDelegate` overrides
   `scene(_:willConnectTo:options:)` and `scene(_:continue:)` and calls
   `super`. If the Flutter 3.44 engine's header does not expose those as
   overridable, delete the subclass, set `UISceneDelegateClassName` in the
   Clip's Info.plist back to `FlutterSceneDelegate`, and rely on the
   `application(_:continue:)` fallback in `AppDelegate.swift` plus Flutter's
   own deep-link handling (`FlutterDeepLinkingEnabled` is on, and go_router
   accepts the platform's initial route, so `/c/odysseus` should still land).
3. **`engineBridge.pluginRegistry.registrar(forPlugin:)`** is how the channel
   gets its messenger. If that API differs, any `FlutterPluginRegistrar`
   from the bridge will do.
4. **Signing.** Runner target → Signing & Capabilities → pick the SK Labs
   team for Runner, RunnerTests **and MythosLiveClip**; let Xcode rewrite
   the three `DEVELOPMENT_TEAM` values (still the previous owner's
   `TG5RWCPY3K`). Xcode will also want to register the new App ID
   `com.sklabs.mythoslive.Clip` and turn on **Associated Domains** on both
   App IDs in the developer portal; with automatic signing it offers to.
5. **Icon.** The Clip's Resources phase reuses `Runner/Assets.xcassets`, so
   it gets the same `AppIcon`. If Xcode insists on a Clip-owned asset
   catalog, add one with an `AppIcon` set copied from Runner's.

## Do this on the Mac

```
git fetch origin claude/wonderful-bell-fscjat
git checkout claude/wonderful-bell-fscjat
flutter pub get
cd ios && pod install && cd ..
open ios/Runner.xcworkspace
```

1. Fix signing as in item 4 above. Commit the pbxproj if Xcode changed it.
2. Scheme **MythosLiveClip**, a simulator or device → Run. The scheme carries
   `_XCAppClipURL=https://chat.deeploveechoes.com/c/odysseus`, so it should
   open straight into Odysseus with the strip underneath. Tapping the strip
   should raise the App Store overlay (on a simulator it may be blank; the
   full app is not in the store on that device).
3. Scheme **Runner** → Product → Archive. In the Organizer, Distribute →
   **Development** or Ad Hoc with App Thinning → read
   `App Thinning Size Report.txt`. The Clip's uncompressed size must be under
   **15 MB** on iOS 16 (our floor). Flutter alone is close to that; see
   "Size" below before spending time on anything else.
4. Upload as usual (`tool/ios_release.sh` still works; the Clip rides inside
   the app archive). Bump `pubspec.yaml` first; the Clip's version and build
   are the app's by construction (`$(FLUTTER_BUILD_NAME)`/`NUMBER`).

## Size

Apple's limits for the uncompressed Clip binary: 10 MB (iOS 15), **15 MB
(iOS 16)**, 100 MB (iOS 17+, digital invocations only, and only if the Clip
does not support iOS 16 or earlier).

A release Flutter app with this plugin set is likely **over 15 MB**. The Clip
links every plugin the app does (RevenueCat, local notifications, image
picker, secure storage...) because they are registered from the shared
`GeneratedPluginRegistrant`. Two honest options if the size report says no:

- Raise the Clip's `IPHONEOS_DEPLOYMENT_TARGET` to 17.0 (the app stays at
  16) and take the 100 MB limit. Costs nothing but iOS 16 Clip users, who
  simply get the Smart App Banner instead. This is the recommended first move.
- Strip plugins from the Clip. Needs a Clip-only plugin registrant and
  Podfile target that omits the heavy pods; a real piece of work.

Also note the app's own assets (`assets/images/`) ship in `App.framework`'s
`flutter_assets` and count toward the limit.

## App Store Connect and the web

1. **Team ID into the association file.** Replace `TEAMID` in
   `web/.well-known/apple-app-site-association` with the SK Labs team id
   (Developer portal → Membership). Deploy web (`npm run build:web` + the
   usual deploy). Check `https://chat.deeploveechoes.com/.well-known/apple-app-site-association`
   returns the JSON with `Content-Type: application/json` (that is what
   `web/_headers` is for). Apple fetches it through its CDN, so allow a few
   hours. Note the `applinks` section means campaign links will start
   opening the **installed full app** on iPhones too, once a build with
   `Runner.entitlements` is live; that is intended.
2. After the build with the Clip is processed: the app version page gets an
   **App Clip** section. Fill the default experience (header image
   1800×1200, subtitle ≤ 56 chars, verb "Open" or "Play").
3. **Edit Advanced Experiences** → add `https://chat.deeploveechoes.com/c/`
   (and the `deeplovepoems` twin) so every campaign link invokes the Clip.
   Keep it to the prefix; the Clip reads the full URL.
4. TestFlight: a build's App Clip section lets you define up to three test
   experiences; testers launch them from the TestFlight app (no card).
5. Safari: once the Clip is live, the Smart App Banner meta in
   `web/index.html` shows the Clip card on every `/c/` page. The App Store
   Apple ID in that tag is 6817279097.

## Leftovers

- Keychain is not shared between Clip and app; a visitor who later installs
  the app starts with a fresh device id. Fixing it needs a shared keychain
  access group on both targets and `DeviceIdentity` reading it. Not blocking.
- `UIDevice.identifierForVendor` is empty in a Clip; nothing here uses it.
- The Clip inherits `NSPhotoLibraryUsageDescription`; Photos returns nothing
  inside a Clip, so the profile avatar picker will silently do nothing there.
