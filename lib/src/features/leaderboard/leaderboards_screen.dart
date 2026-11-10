import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/data/characters.dart';
import '../../core/data/remote_catalogue.dart';
import '../../core/theme/app_theme.dart';
import 'leaderboard.dart';

/// The Leaderboards menu, opened from the trophy in the dashboard header.
///
/// Top to bottom: the all-characters board — only for someone who has
/// unlocked it by giving two gifts; before that there is no sign of it here
/// either — and then one row per character on the dashboard, in dashboard
/// order, saying who leads and where this person stands. A row opens that
/// character's own board.
class LeaderboardsScreen extends StatefulWidget {
  final LeaderboardService? service;
  const LeaderboardsScreen({super.key, this.service});

  @override
  State<LeaderboardsScreen> createState() => _LeaderboardsScreenState();
}

class _LeaderboardsScreenState extends State<LeaderboardsScreen> {
  late final LeaderboardService _service =
      widget.service ?? LeaderboardService();
  late Future<LeaderboardSummary?> _summary = _service.fetchSummary();

  void _reload() {
    // A block, not an arrow: an arrow would hand setState the Future.
    setState(() {
      _summary = _service.fetchSummary();
    });
  }

  Future<void> _open(Map<String, dynamic> character) async {
    await showLeaderboardSheet(
      context,
      characterId: character['id'] as String,
      characterName: character['name'] as String,
      service: _service,
    );
  }

  @override
  Widget build(BuildContext context) {
    final gold = Theme.of(context).colorScheme.secondary;
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: AppTheme.inkColor,
        centerTitle: true,
        title: Text(
          'Leaderboards',
          style: GoogleFonts.playfairDisplay(
            color: AppTheme.inkColor,
            fontSize: 22,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: FutureBuilder<LeaderboardSummary?>(
              future: _summary,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                final summary = snapshot.data;
                if (summary == null) {
                  return _Notice(
                    text: 'The leaderboards could not be reached.',
                    action: 'Try again',
                    onAction: _reload,
                  );
                }
                if (!summary.enabled) {
                  return const _Notice(
                    text: 'Leaderboards are not available right now.',
                  );
                }
                final roster = kCharacters;
                final characters = [
                  for (final id in visibleCharacterIds)
                    ...roster.where((c) => c['id'] == id),
                ];
                final global = summary.global;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
                  children: [
                    if (global != null) ...[
                      _Heading(
                        icon: Icons.emoji_events,
                        color: gold,
                        title: 'All characters',
                        subtitle: 'Who has given the most, to anyone',
                      ),
                      const SizedBox(height: 10),
                      LeaderboardBoardView(
                        board: global,
                        emptyText: 'No one is on this board yet.',
                        scrollable: false,
                        // Names here are user numbers as shipped; reporting
                        // lives on the character sheets, where chosen names
                        // appear if they are ever switched on.
                        onReport: (_) {},
                        reported: const {},
                      ),
                      const SizedBox(height: 22),
                    ],
                    _Heading(
                      icon: Icons.groups_2_outlined,
                      color: gold,
                      title: 'By character',
                      subtitle: 'Tap one to see its board',
                    ),
                    const SizedBox(height: 10),
                    for (final character in characters)
                      _CharacterRow(
                        character: character,
                        row: summary.characters[character['id']],
                        onTap: () => _open(character),
                      ),
                    const SizedBox(height: 12),
                    Text(
                      'Ranked by coins spent on gifts.',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.lato(
                        color: AppTheme.faintInkColor,
                        fontSize: 12,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;

  const _Heading({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.lato(
                  color: AppTheme.inkColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                subtitle,
                style: GoogleFonts.lato(
                  color: AppTheme.mutedInkColor,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  final String text;
  final String? action;
  final VoidCallback? onAction;

  const _Notice({required this.text, this.action, this.onAction});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
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

class _CharacterRow extends StatelessWidget {
  final Map<String, dynamic> character;

  /// Null when nobody has given this character anything yet.
  final LeaderboardSummaryRow? row;
  final VoidCallback onTap;

  const _CharacterRow({
    required this.character,
    required this.row,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final gold = Theme.of(context).colorScheme.secondary;
    final r = row;
    final leader = r == null
        ? 'No gifts yet. Yours would be the first.'
        : r.topIsYou
            ? 'You lead with ${r.topSpent}'
            : 'Led by ${r.topName} · ${r.topSpent}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppTheme.panelColor,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: ValueKey('leaderboards-row-${character['id']}'),
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.hairlineColor),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (character['color'] as Color?) ?? gold,
                    image: DecorationImage(
                      image: catalogueImageProvider(character['image'] as String),
                      fit: BoxFit.cover,
                      onError: (_, _) {},
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        character['name'] as String,
                        style: GoogleFonts.lato(
                          color: AppTheme.inkColor,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        leader,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.lato(
                          color: AppTheme.mutedInkColor,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                // Their own place, when they have one here.
                if (r?.yourRank != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: gold.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: gold.withValues(alpha: 0.7)),
                    ),
                    child: Text(
                      'You ${leaderboardPlace(r!.yourRank!)}',
                      style: GoogleFonts.lato(
                        color: AppTheme.goldInkColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right,
                    size: 20, color: AppTheme.mutedInkColor),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
