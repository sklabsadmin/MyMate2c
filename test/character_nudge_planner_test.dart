// Notifications from the characters someone has talked to
// (lib/src/core/services/character_nudge_planner.dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:mythos_live/src/core/data/character_nudges.dart';
import 'package:mythos_live/src/core/data/remote_catalogue.dart';
import 'package:mythos_live/src/core/services/character_nudge_planner.dart';
import 'package:mythos_live/src/core/services/notification_service.dart';

Map<String, dynamic> chat(String name, String? characterId) =>
    {'chatId': 'c_$name', 'name': name, 'characterId': characterId};

void main() {
  setUp(RemoteCatalogue.debugReset);
  tearDown(RemoteCatalogue.debugReset);

  // A Tuesday at noon: +4h is 16:00, comfortably inside waking hours.
  final noon = DateTime(2026, 11, 10, 12);

  test('nobody talked to: the three app-level lines, as before', () {
    final plan = CharacterNudgePlanner.plan(recentChats: const [], now: noon);
    expect(plan.map((n) => n.id), [101, 102, 103]);
    expect(plan.map((n) => n.title), [
      'In the Greek World · The day moves on',
      'In the Greek World · A day has passed',
      'In the Greek World · Still here',
    ]);
    expect(plan.every((n) => n.characterId == null), isTrue);
    expect(plan.map((n) => n.when), [
      noon.add(const Duration(hours: 4)),
      noon.add(const Duration(hours: 24)),
      noon.add(const Duration(days: 3)),
    ]);
  });

  test('each slot goes to a character they talked to, newest first', () {
    final plan = CharacterNudgePlanner.plan(
      recentChats: [
        chat('Zeus (Olympian King)', 'zeus'),
        chat('Penelope (Queen of Ithaca)', 'penelope'),
        chat('Hector (Prince of Troy)', 'hector'),
        chat('Kai (Surfer)', 'surfer'),
      ],
      now: noon,
    );
    // Still three notifications, not three more.
    expect(plan.map((n) => n.id), [101, 102, 103]);
    expect(plan.map((n) => n.characterId), ['zeus', 'penelope', 'hector']);
    // The roster's name, not the stored "Zeus (Olympian King)".
    expect(plan.map((n) => n.title),
        ['Zeus says', 'Penelope says', 'Hector says']);
    for (final nudge in plan) {
      expect(kBundledNudges[nudge.characterId], contains(nudge.body));
    }
  });

  test('one character takes all three slots with three different lines', () {
    final plan = CharacterNudgePlanner.plan(
      recentChats: [chat('Zeus (Olympian King)', 'zeus')],
      now: noon,
    );
    expect(plan.map((n) => n.characterId), ['zeus', 'zeus', 'zeus']);
    expect(plan.map((n) => n.body).toSet().length, 3);
  });

  test('two conversations with one character are one voice', () {
    final plan = CharacterNudgePlanner.plan(
      recentChats: [
        chat('Zeus (Olympian King)', 'zeus'),
        chat('Zeus (Olympian King)', 'zeus'),
        chat('Penelope (Queen of Ithaca)', 'penelope'),
      ],
      now: noon,
    );
    expect(plan.map((n) => n.characterId), ['zeus', 'penelope', 'zeus']);
  });

  test('a character somebody made up gets their name and the generic lines',
      () {
    final plan = CharacterNudgePlanner.plan(
      recentChats: [chat('Marcus (My Stoic)', null), chat('', null)],
      now: noon,
    );
    expect(plan.map((n) => n.title).toSet(), {'Marcus says'});
    expect(plan.every((n) => n.characterId == null), isTrue,
        reason: 'there is no /c/<id> route to open for them');
    for (final nudge in plan) {
      expect(kGenericNudges, contains(nudge.body));
    }
  });

  test('the worker can rewrite a character\'s lines, and supply a new one\'s',
      () {
    RemoteCatalogue.debugSet(RemoteCatalogue.tryParse({
      'schema': 1,
      'characters': [
        {
          'id': 'achilles',
          'name': 'Achilles',
          'vibe': 'Best of the Greeks',
          'desc': 'd',
          'image': 'https://x.test/a.jpg',
          'color': '#B03A2E',
          'group': 'greek',
          'nudges': ['The camp is quiet tonight.'],
        },
      ],
      'nudges': {
        'zeus': ['Olympus is dull without an argument.'],
      },
    }));
    final plan = CharacterNudgePlanner.plan(
      recentChats: [
        chat('Achilles (Best of the Greeks)', 'achilles'),
        chat('Zeus (Olympian King)', 'zeus'),
      ],
      now: noon,
    );
    expect(plan[0].title, 'Achilles says');
    expect(plan[0].body, 'The camp is quiet tonight.');
    expect(plan[1].body, 'Olympus is dull without an argument.');
  });

  test('nothing lands in the small hours', () {
    // Left at 23:00: +4h would be 03:00.
    final late = DateTime(2026, 11, 10, 23);
    final plan = CharacterNudgePlanner.plan(
      recentChats: [chat('Zeus (Olympian King)', 'zeus')],
      now: late,
    );
    expect(plan[0].when, DateTime(2026, 11, 11, 10, 30));
    // +24h is 23:00 the next evening: moved to the morning after.
    expect(plan[1].when, DateTime(2026, 11, 12, 10, 30));
    for (final nudge in plan) {
      expect(nudge.when.isAfter(late), isTrue);
    }

    final q = CharacterNudgePlanner.outOfQuietHours;
    expect(q(DateTime(2026, 11, 10, 9, 29)), DateTime(2026, 11, 10, 10, 30));
    expect(q(DateTime(2026, 11, 10, 9, 30)), DateTime(2026, 11, 10, 9, 30));
    expect(q(DateTime(2026, 11, 10, 21, 29)), DateTime(2026, 11, 10, 21, 29));
    expect(q(DateTime(2026, 11, 10, 21, 30)), DateTime(2026, 11, 11, 10, 30));
  });

  test('a tap payload names a character, and only a character', () {
    final payload = NotificationService.characterPayload('zeus');
    expect(NotificationService.characterIdFrom(payload), 'zeus');
    expect(NotificationService.characterIdFrom(null), isNull);
    expect(NotificationService.characterIdFrom('zeus'), isNull);
    expect(NotificationService.characterIdFrom('character:../settings'), isNull);
    expect(NotificationService.characterIdFrom('character:'), isNull);
  });
}
