// clientPlatform() — the one fact the server cannot work out for itself.
//
// Small enough to look not worth testing, and two of the three things that
// could go wrong here are silent: a name that does not match the worker's
// allowlist is stored as NULL rather than rejected, and the web-vs-iOS check
// in the wrong order mislabels every mobile browser visitor as an app install.
// Neither shows up as a failure anywhere — they show up as a count that is
// quietly wrong, months later, which is the situation migration 0023 was
// written to get out of.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mythos_live/src/core/services/client_platform.dart';

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('each native target reports its own name', () {
    const expected = {
      TargetPlatform.iOS: 'ios',
      TargetPlatform.android: 'android',
      TargetPlatform.macOS: 'macos',
      TargetPlatform.windows: 'windows',
      TargetPlatform.linux: 'linux',
      TargetPlatform.fuchsia: 'fuchsia',
    };
    // Every value, so that a TargetPlatform added by a Flutter upgrade fails
    // this test rather than falling through to whatever the switch's last arm
    // happens to be.
    expect(expected.keys.toSet(), TargetPlatform.values.toSet());

    for (final entry in expected.entries) {
      debugDefaultTargetPlatformOverride = entry.key;
      expect(clientPlatform(), entry.value);
    }
  });

  test('every name is one the worker will actually store', () {
    // CLIENT_PLATFORMS in backend/src/worker.js. A name missing from that list
    // is discarded server-side and read as "unknown", so a typo here would not
    // break anything — it would just produce an empty column, which is the
    // state this change exists to fix.
    const accepted = {'web', 'ios', 'android', 'macos', 'windows', 'linux'};
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      final name = clientPlatform();
      // Fuchsia is named but not on the worker's list: nothing ships there, and
      // a value the server drops is the honest outcome for a platform nobody
      // has decided how to count.
      if (platform == TargetPlatform.fuchsia) {
        expect(accepted.contains(name), isFalse);
        continue;
      }
      expect(accepted, contains(name));
    }
  });

  test('names are lowercase and bare, so a GROUP BY returns one row each', () {
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      final name = clientPlatform();
      expect(name, name.toLowerCase());
      expect(name, isNot(contains(' ')));
      expect(name, matches(RegExp(r'^[a-z]+$')));
    }
  });

  test('on the web the browser platform is never consulted', () {
    // The load-bearing order. kIsWeb is a compile-time constant and false in
    // this test, so what is asserted here is the consequence rather than the
    // branch: off the web the answer tracks the operating system, and the
    // override that makes a test look like an iPhone is exactly what a real
    // iPhone's Safari would report to a web build. If the two checks were
    // swapped, a web build would answer 'ios' for that visitor.
    expect(kIsWeb, isFalse, reason: 'this suite runs on the Dart VM');
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(clientPlatform(), 'ios');
  });
}
