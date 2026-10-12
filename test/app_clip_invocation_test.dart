import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mythos_live/src/core/services/app_clip.dart';

void main() {
  group('routeForInvocation', () {
    test('campaign link opens that character', () {
      expect(
        routeForInvocation(Uri.parse('https://chat.deeploveechoes.com/c/odysseus')),
        '/c/odysseus',
      );
    });

    test('keeps the query so a starter question still sends', () {
      expect(
        routeForInvocation(
            Uri.parse('https://chat.deeploveechoes.com/c/zeus?initialMessage=hi')),
        '/c/zeus?initialMessage=hi',
      );
    });

    test('cleans the id the way the /c/ route does', () {
      expect(
        routeForInvocation(Uri.parse('https://x.test/c/Hector%0Ahttps:')),
        '/c/hector',
      );
    });

    test('anything else lands on the dashboard', () {
      expect(routeForInvocation(null), '/dashboard');
      expect(routeForInvocation(Uri.parse('https://x.test/')), '/dashboard');
      expect(routeForInvocation(Uri.parse('https://x.test/settings')), '/dashboard');
      expect(routeForInvocation(Uri.parse('https://x.test/c/')), '/dashboard');
      expect(routeForInvocation(Uri.parse('https://x.test/c/%0A')), '/dashboard');
    });
  });

  test('full app: detect leaves the Clip inactive when no channel answers', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // The channel exists only in the Clip's AppDelegate; the full app's
    // iOS build has no handler, which is exactly what a test has too.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      AppClip.debugSet(active: false);
      await AppClip.detect();
      expect(AppClip.isActive, isFalse);
      expect(AppClip.initialLocation, '/dashboard');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
