/// Which client this build is: "web", "ios" or "android".
///
/// Sent on sign-in and on every logged request, because the server cannot work
/// it out afterwards. The long version is in backend/migrations/0023, but the
/// short version is that none of the obvious candidates answers: the app
/// writes no site_visits row at all (analytics_stub.dart makes logFunnelEvent
/// a no-op off the web), the `platform` column that does exist on site_visits
/// means traffic source rather than device, and app_version is the same string
/// on all three because they are built from one pubspec.yaml.
library;

import 'package:flutter/foundation.dart';

/// This build's platform name, matching the worker's CLIENT_PLATFORMS
/// allowlist — anything not on that list is stored as NULL, so a name invented
/// here would be silently discarded rather than loudly wrong.
///
/// [kIsWeb] is tested first and that order is load-bearing, not stylistic:
/// off the web [defaultTargetPlatform] reports the real operating system, but
/// on the web it reports the platform the BROWSER is running on — Safari on an
/// iPhone answers [TargetPlatform.iOS]. Checked the other way round, every
/// mobile web visitor would be filed as an app install, which is the single
/// distinction this function exists to make.
///
/// [defaultTargetPlatform] rather than `Platform.isIOS`, which would be the
/// more usual spelling, because `dart:io` does not exist on the web and
/// importing it here would break the web build outright — [kIsWeb] guards the
/// value, not the import. The same substitution is already made in
/// `AuthNotifier.appleAvailable` for the same reason. Off the web the two are
/// the same answer: Flutter derives one from the other.
///
/// Desktop names are returned rather than collapsed to a single "other" so
/// that a build from one of the scaffolded desktop targets says what it is
/// instead of being counted as a phone. The worker accepts them; none ships.
String clientPlatform() {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS => 'ios',
    TargetPlatform.android => 'android',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.windows => 'windows',
    TargetPlatform.linux => 'linux',
    // Fuchsia, and anything Flutter adds later. Deliberately not a guess: the
    // worker stores an unrecognised name as NULL, and NULL is the honest value
    // for a platform this function has never been taught about.
    TargetPlatform.fuchsia => 'fuchsia',
  };
}
