import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config/app_config.dart';
import '../../core/services/auth_service.dart';
import '../../core/services/delivery_log.dart';
import '../../core/services/device_identity.dart';
import '../../core/theme/app_theme.dart';

/// One row of a board. [name] is whatever the worker says that person goes
/// by: a generated user number ("User 482913") as things ship, or the display
/// name they chose once the worker's leaderboard_names switch is on. No user
/// id is ever sent. [you] marks the row that is this
/// person, which the sheet labels "You".
class LeaderboardEntry {
  final int rank;
  final String name;
  final int spent;
  final bool you;

  /// Present only on someone ELSE's chosen name: the opaque token a report
  /// names. A generated handle has none, because there is nothing to object
  /// to in a name we made up.
  final String? ref;

  const LeaderboardEntry({
    required this.rank,
    required this.name,
    required this.spent,
    this.you = false,
    this.ref,
  });
}

/// Where this person stands on a board, whether or not they are in the rows
/// shown.
class LeaderboardStanding {
  final int rank;
  final int spent;
  final int gifts;

  const LeaderboardStanding({
    required this.rank,
    required this.spent,
    required this.gifts,
  });
}

class Leaderboard {
  final List<LeaderboardEntry> entries;
  final LeaderboardStanding? you;

  const Leaderboard({this.entries = const [], this.you});

  static Leaderboard? tryParse(dynamic json) {
    if (json is! Map) return null;
    final entries = <LeaderboardEntry>[];
    final raw = json['entries'];
    if (raw is List) {
      for (final row in raw) {
        if (row is! Map) continue;
        final rank = row['rank'];
        final name = row['name'];
        final spent = row['spent'];
        if (rank is! int || name is! String || spent is! int) continue;
        final ref = row['ref'];
        entries.add(LeaderboardEntry(
          rank: rank,
          name: name,
          spent: spent,
          you: row['you'] == true,
          ref: ref is String && ref.isNotEmpty ? ref : null,
        ));
      }
    }
    final you = json['you'];
    LeaderboardStanding? standing;
    if (you is Map &&
        you['rank'] is int &&
        you['spent'] is int &&
        you['gifts'] is int) {
      standing = LeaderboardStanding(
        rank: you['rank'] as int,
        spent: you['spent'] as int,
        gifts: you['gifts'] as int,
      );
    }
    return Leaderboard(entries: entries, you: standing);
  }
}

/// GET /api/leaderboard for one character (backend/src/leaderboard.js).
///
/// [global] is the all-characters board, and is null until the worker says
/// this person has unlocked it (two gifts given). The app then shows no sign
/// that it exists — not a locked tab, not a teaser.
class LeaderboardResult {
  /// False when the worker has leaderboards (or coins) switched off.
  final bool enabled;
  final Leaderboard character;
  final Leaderboard? global;

  /// The display name the worker has on file for this person, or null when
  /// they have never sent one.
  final String? yourName;

  const LeaderboardResult({
    required this.enabled,
    this.character = const Leaderboard(),
    this.global,
    this.yourName,
  });

  static LeaderboardResult? tryParse(dynamic json) {
    if (json is! Map) return null;
    if (json['enabled'] != true) return const LeaderboardResult(enabled: false);
    final character = Leaderboard.tryParse(json['character']);
    if (character == null) return null;
    final rawGlobal = json['global'];
    final global = rawGlobal is Map && rawGlobal['unlocked'] == true
        ? Leaderboard.tryParse(rawGlobal)
        : null;
    final yourName = json['your_name'];
    return LeaderboardResult(
      enabled: true,
      character: character,
      global: global,
      yourName: yourName is String && yourName.isNotEmpty ? yourName : null,
    );
  }
}

/// Talks to /api/leaderboard. Same request shape as a wallet read: HMAC over
/// the empty body + timestamp, the device id in x-user-id, and the session
/// header so a signed-in account is who is asking.
class LeaderboardService {
  final Dio _dio;
  LeaderboardService({Dio? dio}) : _dio = dio ?? Dio();

  /// Signed headers for a request whose body is [body] ('' for a GET).
  Future<Map<String, String>> _headers(String body) async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final secret = AppConfig.appSecret;
    final claim = DeviceIdentity.claimToken;
    return {
      'x-signature': secret.isEmpty
          ? ''
          : Hmac(sha256, utf8.encode(secret))
              .convert(utf8.encode(body + timestamp))
              .toString(),
      'x-timestamp': timestamp,
      'x-user-id': DeliveryLog.ensureUserId(prefs),
      // A claimed wallet's name is set only by the device holding its claim.
      'x-wallet-claim': ?claim,
      ...AuthSession.header(),
    };
  }

  /// Sends [name] as this person's leaderboard display name — PUT
  /// /api/leaderboard/name. The worker is the judge of what is allowed; a
  /// refusal comes back as [NameOutcome.rejected] with its reason.
  ///
  /// [public] says the person has just been told the name is shown on
  /// leaderboards. False sends it to be kept only — which is all that
  /// happens while the boards show user numbers.
  Future<NameResult> setName(String name, {bool public = true}) async {
    final url = AppConfig.apiUrl('/api/leaderboard/name');
    if (url.isEmpty) return const NameResult(NameOutcome.unreachable);
    try {
      final body = jsonEncode({'name': name, 'public': public});
      final res = await _dio.put(
        url,
        data: body,
        options: Options(
          headers: {
            'content-type': 'application/json',
            ...await _headers(body),
          },
          extra: {'withCredentials': true},
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          validateStatus: (status) => status == 200 || status == 422,
        ),
      );
      final data = res.data;
      if (data is! Map) return const NameResult(NameOutcome.unreachable);
      if (data['enabled'] != true) return const NameResult(NameOutcome.disabled);
      if (data['ok'] == true && data['name'] is String) {
        return NameResult(NameOutcome.saved, name: data['name'] as String);
      }
      return NameResult(
        NameOutcome.rejected,
        reason: data['reason'] is String ? data['reason'] as String : null,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('Leaderboard name failed: $e');
      return const NameResult(NameOutcome.unreachable);
    }
  }

  /// Reports the display name behind [ref] — POST /api/leaderboard/report.
  /// True once the worker has answered; it says the same thing whatever it
  /// did with the report.
  Future<bool> report(String ref) async {
    final url = AppConfig.apiUrl('/api/leaderboard/report');
    if (url.isEmpty) return false;
    try {
      final body = jsonEncode({'ref': ref});
      final res = await _dio.post(
        url,
        data: body,
        options: Options(
          headers: {
            'content-type': 'application/json',
            ...await _headers(body),
          },
          extra: {'withCredentials': true},
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          validateStatus: (status) => status == 200,
        ),
      );
      return res.statusCode == 200;
    } catch (e) {
      if (kDebugMode) debugPrint('Leaderboard report failed: $e');
      return false;
    }
  }

  /// The boards for [characterId], or null when they could not be read.
  Future<LeaderboardResult?> fetch(String characterId) async {
    final url = AppConfig.apiUrl(
      '/api/leaderboard',
      queryParameters: {'character': characterId},
    );
    if (url.isEmpty) return null;
    try {
      final res = await _dio.get(
        url,
        options: Options(
          headers: await _headers(''),
          extra: {'withCredentials': true},
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          validateStatus: (status) => status == 200,
        ),
      );
      return LeaderboardResult.tryParse(res.data);
    } catch (e) {
      if (kDebugMode) debugPrint('Leaderboard fetch failed: $e');
      return null;
    }
  }
}

/// What came of sending a display name to the worker.
enum NameOutcome {
  /// Stored. [NameResult.name] is it as the worker tidied it.
  saved,

  /// Refused; [NameResult.reason] is "length" | "characters" | "not_allowed".
  rejected,

  /// Leaderboards (or coins) are switched off: there is nothing to name.
  disabled,

  /// No answer. Not a verdict on the name.
  unreachable,
}

class NameResult {
  final NameOutcome outcome;
  final String? name;
  final String? reason;
  const NameResult(this.outcome, {this.name, this.reason});
}

/// "#3", for a place on a board.
String leaderboardPlace(int rank) => '#$rank';

/// The line offered after a gift: where it left this person on the
/// character's board. Null when there is nothing worth saying (no standing
/// came back).
String? leaderboardGiftLine(LeaderboardResult? result, String characterName) {
  final you = result?.character.you;
  if (result == null || !result.enabled || you == null) return null;
  return you.rank == 1
      ? "You lead $characterName's leaderboard."
      : "You are ${leaderboardPlace(you.rank)} on $characterName's leaderboard.";
}

/// The leaderboard sheet: who has given [characterName] the most, and — once
/// this person has given two gifts — who has given the most to anyone.
///
/// Same sheet language as the coins sheet (white, 24px top radius, Playfair
/// title, Lato body). [preloaded] is a result the caller already has (the
/// post-gift prompt fetched one to know the rank), saving a second request.
Future<void> showLeaderboardSheet(
  BuildContext context, {
  required String characterId,
  required String characterName,
  LeaderboardResult? preloaded,
  LeaderboardService? service,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _LeaderboardSheet(
      characterId: characterId,
      characterName: characterName,
      preloaded: preloaded,
      service: service ?? LeaderboardService(),
    ),
  );
}

class _LeaderboardSheet extends StatefulWidget {
  final String characterId;
  final String characterName;
  final LeaderboardResult? preloaded;
  final LeaderboardService service;

  const _LeaderboardSheet({
    required this.characterId,
    required this.characterName,
    required this.preloaded,
    required this.service,
  });

  @override
  State<_LeaderboardSheet> createState() => _LeaderboardSheetState();
}

class _LeaderboardSheetState extends State<_LeaderboardSheet> {
  late Future<LeaderboardResult?> _result = widget.preloaded != null
      ? Future.value(widget.preloaded)
      : widget.service.fetch(widget.characterId);

  /// 0 = this character, 1 = all characters.
  int _tab = 0;

  void _retry() {
    setState(() => _result = widget.service.fetch(widget.characterId));
  }

  /// Refs reported from this sheet, so a flag reads as done once tapped.
  final Set<String> _reported = {};

  /// Asks before reporting [entry]'s name, then sends the report. The thanks
  /// is shown whether or not the worker could be reached being honest about
  /// only one thing: that it was sent.
  Future<void> _report(LeaderboardEntry entry) async {
    final ref = entry.ref;
    if (ref == null || _reported.contains(ref)) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Report this name?'),
        content: Text(
          '"${entry.name}" will be sent for review. Names that break the '
          'rules are removed from the leaderboards.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Report'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final sent = await widget.service.report(ref);
    if (!mounted) return;
    if (sent) setState(() => _reported.add(ref));
    messenger?.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text(sent
          ? 'Thanks. That name has been reported.'
          : 'The report could not be sent. Please try again.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final gold = Theme.of(context).colorScheme.secondary;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: AppTheme.hairlineColor),
        boxShadow: [
          BoxShadow(
            color: AppTheme.inkColor.withValues(alpha: 0.10),
            blurRadius: 24,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: FutureBuilder<LeaderboardResult?>(
        future: _result,
        builder: (context, snapshot) {
          final loading = snapshot.connectionState != ConnectionState.done;
          final result = snapshot.data;
          final global = result?.global;
          final showGlobal = global != null && _tab == 1;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.emoji_events, color: gold, size: 34),
              const SizedBox(height: 10),
              Text(
                'Leaderboard',
                textAlign: TextAlign.center,
                style: GoogleFonts.playfairDisplay(
                  color: AppTheme.inkColor,
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                showGlobal
                    ? 'Who has given the most, to anyone'
                    : 'Who has given ${widget.characterName} the most',
                textAlign: TextAlign.center,
                style: GoogleFonts.lato(
                  color: AppTheme.mutedInkColor,
                  fontSize: 14,
                ),
              ),
              // The second board appears only once it has been earned.
              if (global != null) ...[
                const SizedBox(height: 16),
                _Tabs(
                  labels: [widget.characterName, 'All characters'],
                  selected: _tab,
                  onSelect: (i) => setState(() => _tab = i),
                ),
              ],
              const SizedBox(height: 16),
              if (loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 36),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (result == null)
                _Message(
                  text: 'The leaderboard could not be reached.',
                  action: 'Try again',
                  onAction: _retry,
                )
              else if (!result.enabled)
                const _Message(text: 'Leaderboards are not available right now.')
              else
                Flexible(
                  child: _Board(
                    onReport: _report,
                    reported: _reported,
                    board: showGlobal ? global : result.character,
                    emptyText: showGlobal
                        ? 'No one is on this board yet.'
                        : 'No one has given ${widget.characterName} a gift '
                            'yet. Yours would be the first.',
                  ),
                ),
              if (!loading && result != null && result.enabled) ...[
                const SizedBox(height: 14),
                Text(
                  // The flag only exists beside a name somebody chose; while
                  // every row is a user number there is nothing to report.
                  [result.character, ?result.global]
                          .any((b) => b.entries.any((e) => e.ref != null))
                      ? 'Ranked by coins spent on gifts. Tap the flag beside '
                          'a name to report it.'
                      : 'Ranked by coins spent on gifts.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.lato(
                    color: AppTheme.faintInkColor,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;

  const _Tabs({
    required this.labels,
    required this.selected,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppTheme.panelColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.hairlineColor),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelect(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: i == selected ? Colors.white : Colors.transparent,
                    borderRadius: BorderRadius.circular(19),
                    border: Border.all(
                      color: i == selected
                          ? AppTheme.hairlineColor
                          : Colors.transparent,
                    ),
                  ),
                  child: Text(
                    labels[i],
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.lato(
                      color: i == selected
                          ? AppTheme.inkColor
                          : AppTheme.mutedInkColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  final String? action;
  final VoidCallback? onAction;

  const _Message({required this.text, this.action, this.onAction});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: GoogleFonts.lato(color: AppTheme.mutedInkColor, fontSize: 14),
          ),
          if (action != null)
            TextButton(onPressed: onAction, child: Text(action!)),
        ],
      ),
    );
  }
}

class _Board extends StatelessWidget {
  final Leaderboard board;
  final String emptyText;
  final void Function(LeaderboardEntry entry) onReport;
  final Set<String> reported;

  const _Board({
    required this.board,
    required this.emptyText,
    required this.onReport,
    required this.reported,
  });

  @override
  Widget build(BuildContext context) {
    if (board.entries.isEmpty) return _Message(text: emptyText);
    final you = board.you;
    // Their own place, when it is below the rows shown.
    final belowFold = you != null && !board.entries.any((e) => e.you);
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: [
        for (final entry in board.entries)
          _Row(
            entry: entry,
            reported: reported.contains(entry.ref),
            onReport: entry.ref == null ? null : () => onReport(entry),
          ),
        if (belowFold) ...[
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 2),
            child: Center(
              child: Text('⋯', style: TextStyle(color: AppTheme.faintInkColor)),
            ),
          ),
          _Row(
            entry: LeaderboardEntry(
              rank: you.rank,
              name: 'You',
              spent: you.spent,
              you: true,
            ),
          ),
        ],
      ],
    );
  }
}

class _Row extends StatelessWidget {
  final LeaderboardEntry entry;

  /// Null where there is nothing to report: this person's own row, and a
  /// generated handle.
  final VoidCallback? onReport;
  final bool reported;

  const _Row({required this.entry, this.onReport, this.reported = false});

  @override
  Widget build(BuildContext context) {
    final gold = Theme.of(context).colorScheme.secondary;
    final top = entry.rank <= 3;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: entry.you ? gold.withValues(alpha: 0.14) : AppTheme.panelColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: entry.you ? gold.withValues(alpha: 0.7) : AppTheme.hairlineColor,
        ),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: Text(
              leaderboardPlace(entry.rank),
              // Lato, not the Playfair of the title: Playfair draws "#" so
              // lightly beside a bold numeral that the place reads as "1".
              style: GoogleFonts.lato(
                color: top ? AppTheme.goldInkColor : AppTheme.mutedInkColor,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: Text(
              entry.you ? 'You' : entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.lato(
                color: AppTheme.inkColor,
                fontSize: 14,
                fontWeight: entry.you ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Icon(Icons.paid, color: gold, size: 16),
          const SizedBox(width: 4),
          Text(
            '${entry.spent}',
            style: GoogleFonts.lato(
              color: AppTheme.inkColor,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (onReport != null) ...[
            const SizedBox(width: 6),
            InkResponse(
              onTap: reported ? null : onReport,
              radius: 18,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Tooltip(
                  message: reported ? 'Reported' : 'Report this name',
                  child: Icon(
                    reported ? Icons.flag : Icons.outlined_flag,
                    size: 16,
                    color: AppTheme.faintInkColor,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
