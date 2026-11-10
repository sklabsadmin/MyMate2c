// The two ways the worker can hold the app (lib/src/core/presentation/
// app_gate.dart): "please update" and "back shortly". Both can lock every
// user out, so most of this file is about when they must NOT fire.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mythos_live/src/core/data/remote_catalogue.dart';
import 'package:mythos_live/src/core/presentation/app_gate.dart';

RemoteCatalogue parse(Map<String, dynamic> app) =>
    RemoteCatalogue.tryParse({'schema': 1, 'app': app})!;

Future<void> mount(WidgetTester tester, {int? build = 100, String? store = 'ios'}) =>
    tester.pumpWidget(MaterialApp(
      home: AppGate(
        debugUseOverrides: true,
        debugBuildNumber: build,
        debugStore: store,
        child: const Scaffold(body: Text('the app')),
      ),
    ));

void main() {
  setUp(RemoteCatalogue.debugReset);
  tearDown(RemoteCatalogue.debugReset);

  group('the decision', () {
    AppStop decide(Map<String, dynamic> app,
            {bool live = true, int? build = 100, String? store = 'ios'}) =>
        appStop(catalogue: parse(app), live: live, buildNumber: build, store: store);

    test('nothing set, nothing stops', () {
      expect(decide({}), AppStop.none);
      expect(decide({'min_build': {'ios': 0, 'android': 0}, 'maintenance': false}),
          AppStop.none);
      expect(
          appStop(
              catalogue: RemoteCatalogue.empty,
              live: false,
              buildNumber: 1,
              store: 'ios'),
          AppStop.none,
          reason: 'first launch with no network');
    });

    test('a build below the minimum for its own store is asked to update', () {
      expect(decide({'min_build': {'ios': 101}}), AppStop.update);
      expect(decide({'min_build': {'ios': 100}}), AppStop.none,
          reason: 'the minimum itself is supported');
      expect(decide({'min_build': {'android': 500}}), AppStop.none,
          reason: 'another store\'s minimum is not ours');
      expect(decide({'min_build': {'ios': 101}}, store: 'android'), AppStop.none);
    });

    test('doubt never asks for an update', () {
      expect(decide({'min_build': {'ios': 101}}, build: null), AppStop.none,
          reason: 'build number unknown');
      expect(decide({'min_build': {'ios': 101}}, store: null), AppStop.none,
          reason: 'the web is always current');
      expect(decide({'min_build': {'ios': '101'}}), AppStop.none,
          reason: 'not a number');
      expect(decide({'min_build': 'everything'}), AppStop.none);
    });

    test('update is honoured from a remembered catalogue', () {
      // An unsupported build that goes offline is still unsupported.
      expect(decide({'min_build': {'ios': 101}}, live: false), AppStop.update);
    });

    test('maintenance needs a live answer, and exactly true', () {
      expect(decide({'maintenance': true}), AppStop.maintenance);
      expect(decide({'maintenance': true}, live: false), AppStop.none,
          reason: 'a hold remembered from yesterday must not lock anyone out');
      for (final junk in ['true', 1, 'yes', null]) {
        expect(decide({'maintenance': junk}), AppStop.none, reason: '$junk');
      }
      expect(decide({'maintenance': true}, store: null), AppStop.maintenance,
          reason: 'the web holds too');
    });

    test('update outranks maintenance', () {
      expect(decide({'maintenance': true, 'min_build': {'ios': 101}}),
          AppStop.update);
    });

    test('an update link is only ever a store', () {
      final c = parse({
        'update_url': {
          'ios': 'https://apps.apple.com/app/id1234567890',
          'android': 'https://evil.example/steal',
        },
      });
      expect(c.updateUrl, {'ios': 'https://apps.apple.com/app/id1234567890'});
      expect(parse({'update_url': {'ios': 'http://apps.apple.com/app/id1'}}).updateUrl,
          isEmpty);
    });
  });

  group('the screen', () {
    testWidgets('normally the app is simply the app', (tester) async {
      await mount(tester);
      expect(find.text('the app'), findsOneWidget);
    });

    testWidgets('an unsupported build sees only the update screen',
        (tester) async {
      RemoteCatalogue.debugSet(parse({
        'min_build': {'ios': 101},
        'update_url': {'ios': 'https://apps.apple.com/app/id1234567890'},
      }));
      await mount(tester);
      expect(find.text('the app'), findsNothing);
      expect(find.text('Time to update'), findsOneWidget);
      expect(find.text('Update'), findsOneWidget);
    });

    testWidgets('with no store link there is no button, and it says where to go',
        (tester) async {
      RemoteCatalogue.debugSet(parse({'min_build': {'ios': 101}}));
      await mount(tester);
      expect(find.text('Update'), findsNothing);
      expect(find.textContaining('Open the App Store'), findsOneWidget);
    });

    testWidgets('maintenance shows the worker\'s message and lifts on its own',
        (tester) async {
      RemoteCatalogue.fetchedThisLaunch = true;
      RemoteCatalogue.debugSet(parse({
        'maintenance': true,
        'maintenance_message': 'Back at noon.',
      }));
      await mount(tester);
      expect(find.text('Back shortly'), findsOneWidget);
      expect(find.text('Back at noon.'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('the app'), findsNothing);

      // The worker says it is over: the app comes back without a restart.
      RemoteCatalogue.debugSet(parse({'maintenance': false}));
      await tester.pump();
      expect(find.text('the app'), findsOneWidget);
      // And the once-a-minute re-check has stopped with it.
      await tester.pump(const Duration(minutes: 3));
    });

    testWidgets('a remembered hold does not show until the worker confirms it',
        (tester) async {
      RemoteCatalogue.debugSet(parse({'maintenance': true}));
      await mount(tester);
      expect(find.text('the app'), findsOneWidget);

      // The live answer arrives, and it is the same: now it holds.
      RemoteCatalogue.fetchedThisLaunch = true;
      RemoteCatalogue.revision.value++;
      await tester.pump();
      expect(find.text('Back shortly'), findsOneWidget);

      // Unmount with the hold still on, so the re-check timer is cancelled
      // by dispose rather than left running.
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the default maintenance wording says their things are safe',
        (tester) async {
      RemoteCatalogue.fetchedThisLaunch = true;
      RemoteCatalogue.debugSet(parse({'maintenance': true}));
      await mount(tester);
      expect(find.textContaining('chats and coins are safe'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
