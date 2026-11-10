// The Leaderboards menu (lib/src/features/leaderboard/leaderboards_screen.dart),
// opened from the trophy in the dashboard header.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mythos_live/src/core/config/app_config.dart';
import 'package:mythos_live/src/core/data/remote_catalogue.dart';
import 'package:mythos_live/src/features/leaderboard/leaderboard.dart';
import 'package:mythos_live/src/features/leaderboard/leaderboards_screen.dart';

class FakeService extends LeaderboardService {
  LeaderboardSummary? summary;
  final List<String> boardsOpened = [];
  int summaries = 0;

  FakeService(this.summary);

  @override
  Future<LeaderboardSummary?> fetchSummary() async {
    summaries++;
    return summary;
  }

  @override
  Future<LeaderboardResult?> fetch(String characterId) async {
    boardsOpened.add(characterId);
    return const LeaderboardResult(enabled: true);
  }
}

Map<String, dynamic> response({bool unlocked = false}) => {
      'enabled': true,
      'characters': [
        {
          'id': 'zeus',
          'givers': 3,
          'top': {'name': 'User 935372', 'spent': 1500},
          'you': {'rank': 4, 'spent': 50},
        },
        {
          'id': 'penelope',
          'givers': 1,
          'top': {'name': 'User 111111', 'spent': 150, 'you': true},
          'you': {'rank': 1, 'spent': 150},
        },
        // A character this build has never heard of is simply not listed.
        {
          'id': 'nobody_knows',
          'givers': 1,
          'top': {'name': 'User 222222', 'spent': 5},
        },
        'junk',
      ],
      'global': unlocked
          ? {
              'unlocked': true,
              'entries': [
                {'rank': 1, 'name': 'User 310207', 'spent': 9000},
                {'rank': 2, 'name': 'User 111111', 'spent': 200, 'you': true},
              ],
              'you': {'rank': 2, 'spent': 200, 'gifts': 2},
            }
          : {'unlocked': false},
    };

Future<FakeService> open(WidgetTester tester, LeaderboardSummary? summary) async {
  tester.view.physicalSize = const Size(900, 5200);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final service = FakeService(summary);
  await tester.pumpWidget(MaterialApp(home: LeaderboardsScreen(service: service)));
  await tester.pumpAndSettle();
  return service;
}

void main() {
  setUp(RemoteCatalogue.debugReset);
  tearDown(RemoteCatalogue.debugReset);

  test('reading the summary', () {
    final s = LeaderboardSummary.tryParse(response(unlocked: true))!;
    expect(s.characters.keys, containsAll(['zeus', 'penelope', 'nobody_knows']));
    expect(s.characters['zeus']!.topSpent, 1500);
    expect(s.characters['zeus']!.yourRank, 4);
    expect(s.characters['zeus']!.topIsYou, isFalse);
    expect(s.characters['penelope']!.topIsYou, isTrue);
    expect(s.characters['nobody_knows']!.yourRank, isNull);
    expect(s.global!.entries.length, 2);

    expect(LeaderboardSummary.tryParse(response())!.global, isNull);
    expect(LeaderboardSummary.tryParse({'enabled': false})!.enabled, isFalse);
    expect(LeaderboardSummary.tryParse('<html>'), isNull);
  });

  testWidgets('one row per dashboard character, with leader and your place',
      (tester) async {
    await open(tester, LeaderboardSummary.tryParse(response()));
    // Every character on the dashboard is listed, given to or not.
    for (final id in AppConfig.visibleCharacterIds) {
      expect(find.byKey(ValueKey('leaderboards-row-$id')), findsOneWidget,
          reason: id);
    }
    expect(find.byKey(const ValueKey('leaderboards-row-nobody_knows')),
        findsNothing);

    expect(find.text('Led by User 935372 · 1500'), findsOneWidget);
    expect(find.text('You #4'), findsOneWidget);
    expect(find.text('You lead with 150'), findsOneWidget);
    expect(find.text('You #1'), findsOneWidget);
    // Hector has no gifts in this response.
    expect(find.text('No gifts yet. Yours would be the first.'), findsWidgets);
  });

  testWidgets('no all-characters board, and no sign of one, until unlocked',
      (tester) async {
    await open(tester, LeaderboardSummary.tryParse(response()));
    expect(find.text('All characters'), findsNothing);
    expect(find.textContaining('unlock'), findsNothing);
    expect(find.text('By character'), findsOneWidget);
  });

  testWidgets('unlocked: the all-characters board leads the page',
      (tester) async {
    await open(tester, LeaderboardSummary.tryParse(response(unlocked: true)));
    expect(find.text('All characters'), findsOneWidget);
    expect(find.text('User 310207'), findsOneWidget);
    expect(find.text('9000'), findsOneWidget);
    expect(find.text('You'), findsOneWidget);
    final board = tester.getTopLeft(find.text('All characters')).dy;
    final list = tester.getTopLeft(find.text('By character')).dy;
    expect(board, lessThan(list));
  });

  testWidgets('a row opens that character\'s own board', (tester) async {
    final service = await open(tester, LeaderboardSummary.tryParse(response()));
    await tester.tap(find.byKey(const ValueKey('leaderboards-row-zeus')));
    await tester.pumpAndSettle();
    expect(service.boardsOpened, ['zeus']);
    expect(find.text('Who has given Zeus the most'), findsOneWidget);
  });

  testWidgets('a character added by the worker is listed too', (tester) async {
    RemoteCatalogue.debugSet(RemoteCatalogue.tryParse({
      'schema': 1,
      'characters': [
        {
          'id': 'ada',
          'name': 'Ada',
          'vibe': 'Girl Power Programmer',
          'desc': 'd',
          'image': 'https://x.test/ada.jpg',
          'color': '#1F8A8A',
          'group': 'modern',
        },
      ],
    }));
    await open(tester, LeaderboardSummary.tryParse(response()));
    expect(find.byKey(const ValueKey('leaderboards-row-ada')), findsOneWidget);
    expect(find.text('Ada'), findsOneWidget);
  });

  testWidgets('unreachable offers another try; switched off says so',
      (tester) async {
    final service = await open(tester, null);
    expect(find.text('The leaderboards could not be reached.'), findsOneWidget);
    service.summary = const LeaderboardSummary(enabled: false);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(service.summaries, 2);
    expect(find.text('Leaderboards are not available right now.'),
        findsOneWidget);
  });
}
