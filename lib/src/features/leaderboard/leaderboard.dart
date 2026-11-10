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
import '../../core/theme/app_theme.dart';

/// One row of a board. [name] is a made-up handle the worker derives for
/// every user — nobody's real name or id is ever sent. [you] marks the row
/// that is this person, which the sheet labels "You".
class LeaderboardEntry {
  final int rank;
  final String name;
  final int spent;
  final bool you;

  const LeaderboardEntry({
    required this.rank,
    required this.name,
    required this.spent,
    this.you = false,
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
        entries.add(LeaderboardEntry(
          rank: rank,
          name: name,
          spent: spent,
          you: row['you'] == true,
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

  const LeaderboardResult({
    required this.enabled,
    this.character = const Leaderboard(),
    this.global,
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
    return LeaderboardResult(enabled: true, character: character, global: global);
  }
}

/// Talks to /api/leaderboard. Same request shape as a wallet read: HMAC over
/// the empty body + timestamp, the device id in x-user-id, and the session
/// header so a signed-in account is who is asking.
class LeaderboardService {
  final Dio _dio;
  LeaderboardService({Dio? dio}) : _dio = dio ?? Dio();

  /// The boards for [characterId], or null when they could not be read.
  Future<LeaderboardResult?> fetch(String characterId) async {
    final url = AppConfig.apiUrl(
      '/api/leaderboard',
      queryParameters: {'character': characterId},
    );
    if (url.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final secret = AppConfig.appSecret;
      final signature = secret.isEmpty
          ? ''
          : Hmac(sha256, utf8.encode(secret))
              .convert(utf8.encode(timestamp))
              .toString();
      final res = await _dio.get(
        url,
        options: Options(
          headers: {
            'x-signature': signature,
            'x-timestamp': timestamp,
            'x-user-id': DeliveryLog.ensureUserId(prefs),
            ...AuthSession.header(),
          },
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
                  'Ranked by coins spent on gifts. Names are aliases; '
                  'only you can see which one is yours.',
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

  const _Board({required this.board, required this.emptyText});

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
        for (final entry in board.entries) _Row(entry: entry),
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
  const _Row({required this.entry});

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
        ],
      ),
    );
  }
}
