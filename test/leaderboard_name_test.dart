// The display name someone has before they give a gift
// (lib/src/features/leaderboard/leaderboard_name.dart), and the report flag
// on other people's names. The worker's half — the filter, the store, the
// hiding — is backend/test/leaderboard.test.mjs.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mythos_live/src/features/leaderboard/leaderboard.dart';
import 'package:mythos_live/src/features/leaderboard/leaderboard_name.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A worker that answers what the test tells it to, and remembers what it
/// was asked.
class FakeService extends LeaderboardService {
  NameResult Function(String name) onSetName =
      (name) => NameResult(NameOutcome.saved, name: name);
  final List<String> namesSent = [];
  final List<String> reports = [];

  @override
  Future<NameResult> setName(String name) async {
    namesSent.add(name);
    return onSetName(name);
  }

  @override
  Future<bool> report(String ref) async {
    reports.add(ref);
    return true;
  }

  @override
  Future<LeaderboardResult?> fetch(String characterId) async =>
      throw StateError('not expected to fetch');
}

class Harness {
  final FakeService service = FakeService();
  String profileName;
  bool? outcome;

  Harness({this.profileName = ''});

  LeaderboardNameGate get gate => LeaderboardNameGate(
        service: service,
        loadName: () async => profileName,
        saveName: (name) async => profileName = name,
      );

  /// Pumps a button that runs the gate the way a gift does.
  Future<void> giveGift(WidgetTester tester) async {
    outcome = null;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async =>
                  outcome = await gate.ensureBeforeGift(context),
              child: const Text('give'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('give'));
    await tester.pumpAndSettle();
  }
}

Future<String?> sentName() async =>
    (await SharedPreferences.getInstance()).getString(LeaderboardNameGate.sentKey);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('before a gift', () {
    testWidgets('no name: they are asked, and the gift waits on the answer',
        (tester) async {
      final h = Harness();
      await h.giveGift(tester);
      expect(find.text('Choose a display name'), findsOneWidget);
      expect(h.outcome, isNull, reason: 'the gift has not gone ahead');

      await tester.enterText(
          find.byKey(const ValueKey('leaderboard-name-field')), 'Telemachus');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(h.outcome, isTrue);
      expect(h.service.namesSent, ['Telemachus']);
      expect(h.profileName, 'Telemachus',
          reason: 'it becomes the profile name — one name, not two');
      expect(await sentName(), 'Telemachus');
    });

    testWidgets('"Not now" is a gift not given, and nothing is stored',
        (tester) async {
      final h = Harness();
      await h.giveGift(tester);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(h.outcome, isFalse);
      expect(h.service.namesSent, isEmpty);
      expect(h.profileName, '');
    });

    testWidgets('the prompt cannot be dismissed by tapping outside it',
        (tester) async {
      final h = Harness();
      await h.giveGift(tester);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('Choose a display name'), findsOneWidget);
      expect(h.outcome, isNull);
    });

    testWidgets('a name already in the profile is sent without asking',
        (tester) async {
      final h = Harness(profileName: ' Anna ');
      await h.giveGift(tester);
      expect(find.text('Choose a display name'), findsNothing);
      expect(h.outcome, isTrue);
      expect(h.service.namesSent, ['Anna']);
      expect(await sentName(), 'Anna');
    });

    testWidgets('a name already on the leaderboards costs no request',
        (tester) async {
      SharedPreferences.setMockInitialValues(
          {LeaderboardNameGate.sentKey: 'Anna'});
      final h = Harness(profileName: 'Anna');
      await h.giveGift(tester);
      expect(h.outcome, isTrue);
      expect(h.service.namesSent, isEmpty);
    });

    testWidgets('a profile name the worker refuses: they are asked for another',
        (tester) async {
      final h = Harness(profileName: 'Rude Word');
      h.service.onSetName = (name) => name == 'Rude Word'
          ? const NameResult(NameOutcome.rejected, reason: 'not_allowed')
          : NameResult(NameOutcome.saved, name: name);
      await h.giveGift(tester);
      expect(find.text('Choose a display name'), findsOneWidget);
      expect(find.text('That name cannot be used. Please choose another.'),
          findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('leaderboard-name-field')), 'Anna');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(h.outcome, isTrue);
      expect(h.profileName, 'Anna');
    });

    testWidgets('a refusal in the prompt keeps it open and says why',
        (tester) async {
      final h = Harness();
      h.service.onSetName =
          (_) => const NameResult(NameOutcome.rejected, reason: 'characters');
      await h.giveGift(tester);
      await tester.enterText(
          find.byKey(const ValueKey('leaderboard-name-field')), 'a@b.co');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.textContaining('letters, numbers, spaces'), findsOneWidget);
      expect(h.outcome, isNull);
      expect(h.profileName, '');
    });

    testWidgets('one character is stopped before it is sent', (tester) async {
      final h = Harness();
      await h.giveGift(tester);
      await tester.enterText(
          find.byKey(const ValueKey('leaderboard-name-field')), 'A');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(h.service.namesSent, isEmpty);
      expect(find.textContaining('between 2 and 20'), findsOneWidget);
    });

    testWidgets('an unreachable worker never blocks a name they already have',
        (tester) async {
      final h = Harness(profileName: 'Anna');
      h.service.onSetName = (_) => const NameResult(NameOutcome.unreachable);
      await h.giveGift(tester);
      expect(h.outcome, isTrue);
      expect(await sentName(), isNull, reason: 'so it is tried again next time');
    });

    testWidgets('leaderboards switched off: no name is asked for',
        (tester) async {
      final h = Harness();
      h.service.onSetName = (_) => const NameResult(NameOutcome.disabled);
      await h.giveGift(tester);
      await tester.enterText(
          find.byKey(const ValueKey('leaderboard-name-field')), 'Anna');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(h.outcome, isTrue);
      expect(await sentName(), isNull);
    });
  });

  group('after the profile is saved', () {
    test('someone who has never given a gift: the name stays private',
        () async {
      final h = Harness();
      expect(await h.gate.afterProfileSaved('Anna'), isNull);
      expect(h.service.namesSent, isEmpty);
    });

    test('someone on the leaderboards: a new name follows them there',
        () async {
      SharedPreferences.setMockInitialValues(
          {LeaderboardNameGate.sentKey: 'Anna'});
      final h = Harness();
      expect(await h.gate.afterProfileSaved('Anna'), isNull);
      expect(h.service.namesSent, isEmpty, reason: 'unchanged');
      expect(await h.gate.afterProfileSaved('Annabel'), isNull);
      expect(h.service.namesSent, ['Annabel']);
      expect(await sentName(), 'Annabel');
    });

    test('a refused new name leaves the old one showing, and says so',
        () async {
      SharedPreferences.setMockInitialValues(
          {LeaderboardNameGate.sentKey: 'Anna'});
      final h = Harness();
      h.service.onSetName =
          (_) => const NameResult(NameOutcome.rejected, reason: 'not_allowed');
      final message = await h.gate.afterProfileSaved('Rude Word');
      expect(message, contains('still show "Anna"'));
      expect(await sentName(), 'Anna');
    });
  });

  group('reporting a name on a board', () {
    LeaderboardResult board() => LeaderboardResult.tryParse({
          'enabled': true,
          'character': {
            'id': 'zeus',
            'entries': [
              {'rank': 1, 'name': 'Chosen Name', 'spent': 900, 'ref': 'a' * 24},
              {'rank': 2, 'name': 'Wine-Dark Navigator 47', 'spent': 500},
              {'rank': 3, 'name': 'Mine', 'spent': 50, 'you': true},
            ],
            'you': {'rank': 3, 'spent': 50, 'gifts': 1},
          },
          'global': {'unlocked': false},
          'your_name': 'Mine',
        })!;

    Future<FakeService> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final service = FakeService();
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showLeaderboardSheet(
                context,
                characterId: 'zeus',
                characterName: 'Zeus',
                preloaded: board(),
                service: service,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return service;
    }

    testWidgets('only someone else\'s chosen name carries a flag',
        (tester) async {
      await open(tester);
      expect(board().yourName, 'Mine');
      // One flag: not on the generated handle, not on your own row.
      expect(find.byIcon(Icons.outlined_flag), findsOneWidget);
    });

    testWidgets('a report is confirmed first, sent once, and then marked',
        (tester) async {
      final service = await open(tester);
      await tester.tap(find.byIcon(Icons.outlined_flag));
      await tester.pumpAndSettle();
      expect(find.text('Report this name?'), findsOneWidget);
      expect(service.reports, isEmpty, reason: 'nothing sent before they confirm');

      await tester.tap(find.text('Report'));
      await tester.pumpAndSettle();
      expect(service.reports, ['a' * 24]);
      expect(find.byIcon(Icons.flag), findsOneWidget);
      expect(find.byIcon(Icons.outlined_flag), findsNothing);
    });

    testWidgets('cancelling sends nothing', (tester) async {
      final service = await open(tester);
      await tester.tap(find.byIcon(Icons.outlined_flag));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(service.reports, isEmpty);
    });
  });
}
