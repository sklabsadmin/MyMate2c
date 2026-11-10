import '../data/character_nudges.dart';
import '../data/characters.dart';
import 'notification_service.dart';

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

/// The "come back" notifications scheduled when the app is left.
///
/// Five of them, from the characters this person talks to MOST (by messages
/// exchanged, not by who was open last):
///
///   4 hours     the one they talk to most
///   1 day       the one they talk to most
///   2 days      their second
///   3 days      the one they talk to most
///   5 days      their third
///
/// So three from the favourite and one each from the next two. Someone who
/// has only talked to two characters gets four, to one gets three, and to
/// nobody gets the three app-level lines at 4 hours, 1 day and 3 days, as
/// before any of this existed. The two daily app-level notifications (dawn
/// and nightfall) are separate and unchanged.
///
/// Every time here is the person's own clock: [now] is local, the hours a
/// line is checked against are local, and nothing lands in the small hours.
class CharacterNudgePlanner {
  static const int fourHourId = 101;
  static const int nextDayId = 102;
  static const int threeDayId = 103;
  static const int twoDayId = 104;
  static const int fiveDayId = 105;

  /// (notification id, how long after leaving, whose turn: 0 = the character
  /// they talk to most, 1 = second, 2 = third).
  static const List<(int, Duration, int)> _slots = [
    (fourHourId, Duration(hours: 4), 0),
    (nextDayId, Duration(hours: 24), 0),
    (twoDayId, Duration(days: 2), 1),
    (threeDayId, Duration(days: 3), 0),
    (fiveDayId, Duration(days: 5), 2),
  ];

  static const List<(int, Duration, String, String)> _appLevel = [
    (
      fourHourId,
      Duration(hours: 4),
      'The day moves on',
      'Something in it reminded me of what you said.',
    ),
    (nextDayId, Duration(hours: 24), 'A day has passed', 'Tell me what I missed.'),
    (
      threeDayId,
      Duration(days: 3),
      'Still here',
      'Odysseus took ten years to get home. Take the time you need.',
    ),
  ];

  /// [recentChats] is StorageService.loadRecentChats(): newest first, one
  /// entry per conversation, each with 'name' and (for roster characters)
  /// 'characterId'.
  ///
  /// [messageCounts] is how much they have talked to each, keyed the way the
  /// chat screen keys its reply counter: the character id, or for a
  /// character somebody made up, the chat's name. A character missing from
  /// it counts as zero, and ties go to whoever was talked to more recently.
  static List<PlannedNudge> plan({
    required List<Map<String, dynamic>> recentChats,
    required DateTime now,
    Map<String, int> messageCounts = const {},
  }) {
    final speakers = _speakers(recentChats, messageCounts);
    if (speakers.isEmpty) {
      return [
        for (final (id, delay, title, body) in _appLevel)
          PlannedNudge(
            id: id,
            title: NotificationService.appLevelTitle(title),
            body: body,
            when: outOfQuietHours(now.add(delay)),
          ),
      ];
    }

    final planned = <PlannedNudge>[];
    // The lines each character has already been given in this plan, so the
    // favourite's three notifications are three different lines.
    final used = <int, Set<String>>{};
    for (final (id, delay, rank) in _slots) {
      if (rank >= speakers.length) continue;
      final speaker = speakers[rank];
      final when = outOfQuietHours(now.add(delay));
      final line = _lineFor(
        speaker.characterId,
        when: when,
        startAt: _dayNumber(now) + planned.length,
        used: used.putIfAbsent(rank, () => <String>{}),
      );
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

  /// A line of [characterId]'s that is true at the hour [when] falls on.
  ///
  /// Prefers one this character has not been given yet in this plan; starts
  /// from a different line each day so tomorrow's are not today's. A
  /// character whose every line is about a different time of day (possible
  /// for lines the worker supplied) borrows a generic one rather than say
  /// "tonight" at half past ten in the morning.
  static String _lineFor(
    String? characterId, {
    required DateTime when,
    required int startAt,
    required Set<String> used,
  }) {
    var fitting = nudgesForCharacter(characterId)
        .where((line) => nudgeFitsHour(line, when.hour))
        .toList();
    if (fitting.isEmpty) {
      fitting = kGenericNudges
          .where((line) => nudgeFitsHour(line, when.hour))
          .toList();
    }
    final fresh = fitting.where((line) => !used.contains(line)).toList();
    var pool = fresh.isNotEmpty ? fresh : fitting;
    // A line that only works at this time of day goes first when it fits:
    // "tonight" has few chances to be said, and saying it now keeps the
    // any-hour lines for the slots that can take nothing else.
    final timely = pool.where((line) => !_fitsAnyHour(line)).toList();
    if (timely.isNotEmpty) pool = timely;
    final line = pool[startAt % pool.length];
    used.add(line);
    return line;
  }

  static bool _fitsAnyHour(String line) =>
      const [10, 13, 16, 20].every((hour) => nudgeFitsHour(line, hour));

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

  /// The three characters they talk to most, most-talked-to first.
  static List<({String name, String? characterId})> _speakers(
    List<Map<String, dynamic>> recentChats,
    Map<String, int> messageCounts,
  ) {
    final seen = <String>{};
    final found = <({String name, String? characterId, int count, int recency})>[];
    for (final (index, chat) in recentChats.indexed) {
      final rawId = chat['characterId'];
      final characterId =
          rawId is String && rawId.isNotEmpty ? rawId : null;
      final stored = chat['name'];
      final name = _displayName(stored, characterId);
      if (name == null) continue;
      // One voice per character, however many conversations they have.
      final key = characterId ?? (stored is String ? stored : name);
      if (!seen.add(key)) continue;
      found.add((
        name: name,
        characterId: characterId,
        count: messageCounts[key] ?? 0,
        recency: index,
      ));
    }
    found.sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0 ? byCount : a.recency.compareTo(b.recency);
    });
    return [
      for (final f in found.take(3)) (name: f.name, characterId: f.characterId),
    ];
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
