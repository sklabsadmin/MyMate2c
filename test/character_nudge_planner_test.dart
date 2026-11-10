// Notifications from the characters someone talks to most
// (lib/src/core/services/character_nudge_planner.dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:mythos_live/src/core/config/app_config.dart';
import 'package:mythos_live/src/core/data/character_nudges.dart';
import 'package:mythos_live/src/core/data/remote_catalogue.dart';
import 'package:mythos_live/src/core/services/character_nudge_planner.dart';
import 'package:mythos_live/src/core/services/notification_service.dart';

Map<String, dynamic> chat(String name, String? characterId) =>
    {'chatId': 'c_$name', 'name': name, 'characterId': characterId};

final zeus = chat('Zeus (Olympian King)', 'zeus');
final penelope = chat('Penelope (Queen of Ithaca)', 'penelope');
final hector = chat('Hector (Prince of Troy)', 'hector');
final kai = chat('Kai (Surfer)', 'surfer');

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

  test('three from the one they talk to most, one each from the next two',
      () {
    final plan = CharacterNudgePlanner.plan(
      // Newest first: Kai was open last, but is talked to least.
      recentChats: [kai, hector, penelope, zeus],
      messageCounts: {'zeus': 40, 'penelope': 12, 'hector': 5, 'surfer': 1},
      now: noon,
    );
    expect(plan.map((n) => n.characterId),
        ['zeus', 'zeus', 'penelope', 'zeus', 'hector']);
    expect(plan.map((n) => n.title), [
      'Zeus says', 'Zeus says', 'Penelope says', 'Zeus says', 'Hector says',
    ]);
    expect(plan.map((n) => n.when.difference(noon)), const [
      Duration(hours: 4),
      Duration(days: 1),
      Duration(days: 2),
      Duration(days: 3),
      Duration(days: 5),
    ]);
    expect(plan.map((n) => n.id).toSet().length, 5, reason: 'distinct ids');
    expect(plan.any((n) => n.characterId == 'surfer'), isFalse,
        reason: 'most recent is not most talked to');
  });

  test('the favourite never says the same line twice in one plan', () {
    final plan = CharacterNudgePlanner.plan(
      recentChats: [zeus],
      messageCounts: {'zeus': 3},
      // 14:00, so every slot lands at 14:00 or later… except +4h = 18:00.
      now: DateTime(2026, 11, 10, 14),
    );
    expect(plan.map((n) => n.characterId), ['zeus', 'zeus', 'zeus']);
    expect(plan.map((n) => n.body).toSet().length, 3);
  });

  test('fewer characters, fewer notifications — nobody is invented', () {
    expect(
      CharacterNudgePlanner.plan(
        recentChats: [zeus],
        messageCounts: {'zeus': 3},
        now: noon,
      ).map((n) => n.characterId),
      ['zeus', 'zeus', 'zeus'],
    );
    expect(
      CharacterNudgePlanner.plan(
        recentChats: [penelope, zeus],
        messageCounts: {'zeus': 3, 'penelope': 2},
        now: noon,
      ).map((n) => n.characterId),
      ['zeus', 'zeus', 'penelope', 'zeus'],
    );
  });

  test('with no counts, or a tie, the more recent conversation leads', () {
    expect(
      CharacterNudgePlanner.plan(recentChats: [penelope, zeus], now: noon)
          .first
          .characterId,
      'penelope',
    );
    expect(
      CharacterNudgePlanner.plan(
        recentChats: [penelope, zeus],
        messageCounts: {'zeus': 4, 'penelope': 4},
        now: noon,
      ).first.characterId,
      'penelope',
    );
  });

  test('two conversations with one character are one voice', () {
    final plan = CharacterNudgePlanner.plan(
      recentChats: [zeus, zeus, penelope],
      messageCounts: {'zeus': 9, 'penelope': 1},
      now: noon,
    );
    expect(plan.map((n) => n.characterId),
        ['zeus', 'zeus', 'penelope', 'zeus']);
  });

  test('a character somebody made up gets their name and the generic lines',
      () {
    final plan = CharacterNudgePlanner.plan(
      recentChats: [chat('Marcus (My Stoic)', null), chat('', null)],
      messageCounts: {'Marcus (My Stoic)': 7},
      now: noon,
    );
    expect(plan.map((n) => n.title).toSet(), {'Marcus says'});
    expect(plan.every((n) => n.characterId == null), isTrue,
        reason: 'there is no /c/<id> route to open for them');
    for (final nudge in plan) {
      expect(kGenericNudges, contains(nudge.body));
    }
  });

  group('lines about a time of day', () {
    test('the words decide the hours a line may be shown', () {
      expect(nudgeFitsHour('Calm seas tonight.', 10), isFalse);
      expect(nudgeFitsHour('Calm seas tonight.', 16), isFalse);
      expect(nudgeFitsHour('Calm seas tonight.', 17), isTrue);
      expect(nudgeFitsHour('Thebes sleeps. I rarely do.', 10), isFalse);
      expect(nudgeFitsHour('Sunset was unreal.', 20), isTrue);
      expect(nudgeFitsHour('Good morning, traveller.', 10), isTrue);
      expect(nudgeFitsHour('Good morning, traveller.', 12), isFalse);
      expect(nudgeFitsHour('An empty afternoon.', 10), isFalse);
      expect(nudgeFitsHour('An empty afternoon.', 14), isTrue);
      expect(nudgeFitsHour('An empty afternoon.', 19), isFalse);
      expect(nudgeFitsHour('I would rather hear how your day went.', 10), isFalse);
      expect(nudgeFitsHour('I would rather hear how your day went.', 16), isTrue);
      expect(nudgeFitsHour('Olympus is quiet. I distrust quiet.', 3), isTrue);
      // "night" inside another word is not a time of day.
      expect(nudgeFitsHour('A knight notices an empty seat.', 10), isTrue);
    });

    test('every character has three lines for any hour', () {
      // The favourite gets three notifications, and all three can land at
      // 10:30 (anything that would have arrived overnight is moved there).
      // Three any-hour lines is what keeps those from repeating.
      for (final id in AppConfig.visibleCharacterIds) {
        final anyHour = kBundledNudges[id]!.where((l) =>
            const [10, 13, 16, 20].every((h) => nudgeFitsHour(l, h)));
        expect(anyHour.length, greaterThanOrEqualTo(3), reason: id);
      }
      expect(kGenericNudges.where((l) => nudgeFitsHour(l, 10)), isNotEmpty);
    });

    test('no bundled line names a day of the week', () {
      final weekday = RegExp(
          r'\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b',
          caseSensitive: false);
      for (final lines in [...kBundledNudges.values, kGenericNudges]) {
        for (final line in lines) {
          expect(weekday.hasMatch(line), isFalse, reason: line);
        }
      }
    });

    test('what is scheduled always fits the hour it arrives at', () {
      // Every hour of the day someone might leave the app, for every
      // character: no "tonight" before five, no "how your day went" at 10:30.
      for (final id in AppConfig.visibleCharacterIds) {
        for (var hour = 0; hour < 24; hour++) {
          final plan = CharacterNudgePlanner.plan(
            recentChats: [chat('x', id)],
            messageCounts: {id: 1},
            now: DateTime(2026, 11, 10, hour, 20),
          );
          for (final nudge in plan) {
            expect(nudgeFitsHour(nudge.body, nudge.when.hour), isTrue,
                reason: '$id, left at $hour:20 → "${nudge.body}" '
                    'at ${nudge.when.hour}:${nudge.when.minute}');
          }
          expect(plan.map((n) => n.body).toSet().length, 3,
              reason: '$id, left at $hour:20: three different lines');
        }
      }
    });

    test('a character whose every line is about tonight borrows a generic one '
        'in the morning', () {
      RemoteCatalogue.debugSet(RemoteCatalogue.tryParse({
        'schema': 1,
        'nudges': {
          'zeus': ['The stars are out tonight.', 'A quiet night on Olympus.'],
        },
      }));
      // Left at 23:00: every slot is moved to 10:30 the next morning.
      final plan = CharacterNudgePlanner.plan(
        recentChats: [zeus],
        messageCounts: {'zeus': 1},
        now: DateTime(2026, 11, 10, 23),
      );
      for (final nudge in plan) {
        expect(nudge.title, 'Zeus says');
        expect(kGenericNudges, contains(nudge.body));
      }
      // Left at 14:00: +4h is 18:00, and his own evening line is used.
      final evening = CharacterNudgePlanner.plan(
        recentChats: [zeus],
        messageCounts: {'zeus': 1},
        now: DateTime(2026, 11, 10, 14),
      );
      expect(evening.first.body, contains('Olympus'));
    });
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
          'nudges': ['The camp is quiet.'],
        },
      ],
      'nudges': {
        'zeus': ['Olympus is dull without an argument.'],
      },
    }));
    final plan = CharacterNudgePlanner.plan(
      recentChats: [chat('Achilles (Best of the Greeks)', 'achilles'), zeus],
      messageCounts: {'achilles': 5, 'zeus': 2},
      now: noon,
    );
    expect(plan[0].title, 'Achilles says');
    expect(plan[0].body, 'The camp is quiet.');
    expect(plan[2].title, 'Zeus says');
    expect(plan[2].body, 'Olympus is dull without an argument.');
  });

  test('nothing lands in the small hours', () {
    // Left at 23:00: +4h would be 03:00.
    final late = DateTime(2026, 11, 10, 23);
    final plan = CharacterNudgePlanner.plan(
      recentChats: [zeus],
      messageCounts: {'zeus': 1},
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
