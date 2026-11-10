import '../data/character_nudges.dart';
import '../data/characters.dart';

/// One notification to schedule.
class PlannedNudge {
  final int id;
  final String title;
  final String body;
  final DateTime when;

  /// What a tap opens — see [NotificationService.characterPayload]. Null for
  /// the app-level fallbacks, which open the app wherever it was.
  final String? characterId;

  const PlannedNudge({
    required this.id,
    required this.title,
    required this.body,
    required this.when,
    this.characterId,
  });
}

/// The three "come back" notifications scheduled when the app is left: four
/// hours on, a day on, three days on.
///
/// They used to be written in the app's own voice whoever the person had been
/// talking to. Now each is handed to a character they have actually talked
/// with — the most recent conversation gets the first slot, the one before it
/// the second, and so on, going round again when there are fewer than three.
/// Someone who has never opened a chat gets the app-level lines as before.
///
/// Deliberately the SAME three slots, not three more. The app already
/// schedules a dawn and a nightfall line every day; adding to the count is
/// how a notification permission gets revoked.
class CharacterNudgePlanner {
  static const int fourHourId = 101;
  static const int nextDayId = 102;
  static const int threeDayId = 103;

  static const List<(int, Duration)> _slots = [
    (fourHourId, Duration(hours: 4)),
    (nextDayId, Duration(hours: 24)),
    (threeDayId, Duration(days: 3)),
  ];

  static const List<(String, String)> _appLevel = [
    ('The day moves on', 'Something in it reminded me of what you said.'),
    ('A day has passed', 'Tell me what I missed.'),
    (
      'Still here',
      'Odysseus took ten years to get home. Take the time you need.',
    ),
  ];

  /// [recentChats] is StorageService.loadRecentChats(): newest first, one
  /// entry per conversation, each with 'name' and (for roster characters)
  /// 'characterId'.
  static List<PlannedNudge> plan({
    required List<Map<String, dynamic>> recentChats,
    required DateTime now,
  }) {
    final speakers = _speakers(recentChats);
    final planned = <PlannedNudge>[];
    for (var i = 0; i < _slots.length; i++) {
      final (id, delay) = _slots[i];
      final when = outOfQuietHours(now.add(delay));
      if (speakers.isEmpty) {
        final (title, body) = _appLevel[i];
        planned.add(PlannedNudge(id: id, title: title, body: body, when: when));
        continue;
      }
      final speaker = speakers[i % speakers.length];
      final lines = nudgesForCharacter(speaker.characterId);
      // Starts from a different line each day the app is left, and moves on
      // by one each time the same character takes a later slot — so three
      // notifications from one character are three different lines (given
      // three to choose from), and tomorrow's are not today's.
      final turn = i ~/ speakers.length;
      final line = lines[(_dayNumber(now) + turn) % lines.length];
      planned.add(PlannedNudge(
        id: id,
        // "Zeus says" over the line, so the lock screen reads as the
        // character speaking rather than as a message that arrived from them.
        title: '${speaker.name} says',
        body: line,
        when: when,
        characterId: speaker.characterId,
      ));
    }
    return planned;
  }

  /// Nobody wants Zeus at three in the morning. A time that lands between
  /// 21:30 and 09:30 is moved to 10:30 that morning — clear of the 09:00
  /// dawn line, so the two do not arrive together.
  static DateTime outOfQuietHours(DateTime when) {
    final minutes = when.hour * 60 + when.minute;
    if (minutes >= 9 * 60 + 30 && minutes < 21 * 60 + 30) return when;
    final morning = DateTime(when.year, when.month, when.day, 10, 30);
    // Late evening belongs to the next day's morning; small hours to today's.
    return minutes >= 21 * 60 + 30
        ? morning.add(const Duration(days: 1))
        : morning;
  }

  static List<({String name, String? characterId})> _speakers(
    List<Map<String, dynamic>> recentChats,
  ) {
    final seen = <String>{};
    final speakers = <({String name, String? characterId})>[];
    for (final chat in recentChats) {
      final rawId = chat['characterId'];
      final characterId =
          rawId is String && rawId.isNotEmpty ? rawId : null;
      final name = _displayName(chat['name'], characterId);
      if (name == null) continue;
      // One voice per character, however many conversations they have.
      if (!seen.add(characterId ?? 'name:$name')) continue;
      speakers.add((name: name, characterId: characterId));
      if (speakers.length == _slots.length) break;
    }
    return speakers;
  }

  /// The name to put on the notification. A recent chat stores the chat's
  /// scenario — "Zeus (Olympian King)" — so the roster's own name is used
  /// when the character is one of ours, and the bracketed part is dropped
  /// when it is not.
  static String? _displayName(dynamic stored, String? characterId) {
    final roster = characterById(characterId)?['name'];
    if (roster is String && roster.isNotEmpty) return roster;
    if (stored is! String) return null;
    final name = stored.replaceFirst(RegExp(r'\s*\([^)]*\)\s*$'), '').trim();
    return name.isEmpty ? null : name;
  }

  static int _dayNumber(DateTime when) =>
      DateTime(when.year, when.month, when.day)
          .difference(DateTime(2026))
          .inDays
          .abs();
}
