// The gift leaderboards, app side (lib/src/features/leaderboard/). The
// ranking itself is the worker's and is tested there
// (backend/test/leaderboard.test.mjs); this holds the app to reading the
// answer correctly and to the one rule that is the app's to keep: the
// all-characters board is not shown, or hinted at, until it is unlocked.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mythos_live/src/features/leaderboard/leaderboard.dart';

Map<String, dynamic> entry(int rank, String name, int spent, {bool you = false}) =>
    {'rank': rank, 'name': name, 'spent': spent, if (you) 'you': true};

Map<String, dynamic> response({bool unlocked = false, bool belowFold = false}) => {
      'enabled': true,
      'character': {
        'id': 'zeus',
        'entries': [
          entry(1, 'User 482913', 1500),
          entry(2, 'User 120044', 500, you: !belowFold),
          entry(3, 'User 880321', 150),
        ],
        'you': belowFold
            ? {'rank': 14, 'spent': 50, 'gifts': 1}
            : {'rank': 2, 'spent': 500, 'gifts': 2},
      },
      'global': unlocked
          ? {
              'unlocked': true,
              'entries': [
                entry(1, 'User 310207', 9000),
                entry(2, 'User 120044', 650, you: true),
              ],
              'you': {'rank': 2, 'spent': 650, 'gifts': 3},
            }
          : {'unlocked': false},
    };

/// A service that never touches the network: the sheet is handed its result.
class _NoNetwork extends LeaderboardService {
  @override
  Future<LeaderboardResult?> fetch(String characterId) async =>
      throw StateError('the sheet was given a preloaded result');
}

Future<void> openSheet(WidgetTester tester, LeaderboardResult result) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => showLeaderboardSheet(
              context,
              characterId: 'zeus',
              characterName: 'Zeus',
              preloaded: result,
              service: _NoNetwork(),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('reading the worker\'s answer', () {
    test('a character board, with this person\'s row and standing', () {
      final result = LeaderboardResult.tryParse(response())!;
      expect(result.enabled, isTrue);
      expect(result.character.entries.map((e) => e.spent), [1500, 500, 150]);
      expect(result.character.entries.map((e) => e.you), [false, true, false]);
      expect(result.character.you!.rank, 2);
      expect(result.global, isNull, reason: 'locked is the same as absent');
    });

    test('the global board only when the worker says it is unlocked', () {
      final result = LeaderboardResult.tryParse(response(unlocked: true))!;
      expect(result.global!.entries.length, 2);
      expect(result.global!.you!.gifts, 3);
      // Entries without the flag are not a board: a worker bug must not
      // leak one to someone who has not earned it.
      final sneaky = response();
      sneaky['global'] = {
        'unlocked': false,
        'entries': [entry(1, 'Someone', 1)],
      };
      expect(LeaderboardResult.tryParse(sneaky)!.global, isNull);
    });

    test('switched off, junk, and malformed rows', () {
      expect(LeaderboardResult.tryParse({'enabled': false})!.enabled, isFalse);
      expect(LeaderboardResult.tryParse('<html>'), isNull);
      expect(LeaderboardResult.tryParse({'enabled': true}), isNull);
      final ragged = LeaderboardResult.tryParse({
        'enabled': true,
        'character': {
          'entries': [
            entry(1, 'Fine', 10),
            {'rank': 'two', 'name': 'x', 'spent': 5},
            'nope',
          ],
          'you': {'rank': 1},
        },
      })!;
      expect(ragged.character.entries.map((e) => e.name), ['Fine']);
      expect(ragged.character.you, isNull);
    });
  });

  group('the line offered after a gift', () {
    test('says where the gift left them', () {
      final second = LeaderboardResult.tryParse(response());
      expect(leaderboardGiftLine(second, 'Zeus'),
          "You are #2 on Zeus's leaderboard.");
      final first = response();
      (first['character'] as Map)['you'] = {'rank': 1, 'spent': 9, 'gifts': 1};
      expect(leaderboardGiftLine(LeaderboardResult.tryParse(first), 'Zeus'),
          "You lead Zeus's leaderboard.");
    });

    test('says nothing rather than something wrong', () {
      expect(leaderboardGiftLine(null, 'Zeus'), isNull);
      expect(
          leaderboardGiftLine(
              const LeaderboardResult(enabled: false), 'Zeus'),
          isNull);
      final noStanding = response();
      (noStanding['character'] as Map).remove('you');
      expect(
          leaderboardGiftLine(LeaderboardResult.tryParse(noStanding), 'Zeus'),
          isNull);
    });
  });

  group('the sheet', () {
    testWidgets('lists the board, and calls this person "You"', (tester) async {
      await openSheet(tester, LeaderboardResult.tryParse(response())!);
      expect(find.text('Who has given Zeus the most'), findsOneWidget);
      expect(find.text('User 482913'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('User 120044'), findsNothing,
          reason: 'their own alias is replaced, not shown beside "You"');
      expect(find.text('#1'), findsOneWidget);
      expect(find.text('1500'), findsOneWidget);
    });

    testWidgets('shows no second board, and no sign of one, while locked',
        (tester) async {
      await openSheet(tester, LeaderboardResult.tryParse(response())!);
      expect(find.text('All characters'), findsNothing);
      expect(find.textContaining('unlock'), findsNothing);
    });

    testWidgets('offers the all-characters board once unlocked',
        (tester) async {
      await openSheet(
          tester, LeaderboardResult.tryParse(response(unlocked: true))!);
      expect(find.text('All characters'), findsOneWidget);
      await tester.tap(find.text('All characters'));
      await tester.pumpAndSettle();
      expect(find.text('Who has given the most, to anyone'), findsOneWidget);
      expect(find.text('User 310207'), findsOneWidget);
      expect(find.text('9000'), findsOneWidget);
      expect(find.text('User 482913'), findsNothing);
    });

    testWidgets('below the rows shown, their own place is added at the foot',
        (tester) async {
      await openSheet(
          tester, LeaderboardResult.tryParse(response(belowFold: true))!);
      expect(find.text('#14'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('User 120044'), findsOneWidget);
    });

    testWidgets('an empty board invites the first gift', (tester) async {
      await openSheet(
        tester,
        const LeaderboardResult(enabled: true),
      );
      expect(find.textContaining('Yours would be the first'), findsOneWidget);
    });

    testWidgets('switched off says so', (tester) async {
      await openSheet(tester, const LeaderboardResult(enabled: false));
      expect(find.text('Leaderboards are not available right now.'),
          findsOneWidget);
    });
  });
}
