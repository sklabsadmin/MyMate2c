import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/config/app_config.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/data/character_profiles.dart';
import '../../character/presentation/character_profile_screen.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  final List<Map<String, dynamic>> _characters = [
    {
      'id': 'ceo',
      'name': 'Christian',
      'vibe': 'The CEO',
      'desc': 'Dominant, wealthy, and possessive.',
      'image': 'assets/images/avatar_ceo_real.png', 
      'color': const Color(0xFF1A237E),
    },
    {
      'id': 'badboy',
      'name': 'Damon',
      'vibe': 'Bad Boy',
      'desc': 'Rebellious, passionate, and dangerous.',
      'image': 'assets/images/avatar_badboy_real.png',
      'color': const Color(0xFFB71C1C),
    },
    {
      'id': 'artist',
      'name': 'Julian',
      'vibe': 'The Artist',
      'desc': 'Sensitive, romantic, and attentive.',
      'image': 'assets/images/avatar_artist_real.png',
      'color': const Color(0xFF4A148C),
    },
    // New Boyfriends
    {
      'id': 'architect',
      'name': 'Adrian',
      'vibe': 'Architect',
      'desc': 'Structured, visionary, and builds a future with you.',
      'image': 'assets/images/avatar_architect_real.png', 
      'color': Colors.teal,
    },
    {
      'id': 'rockstar',
      'name': 'Jax',
      'vibe': 'Rockstar',
      'desc': 'Wild concerts, late nights, and songs about you.',
      'image': 'assets/images/avatar_rockstar_real.png', 
      'color': Colors.purpleAccent,
    },
    {
      'id': 'chef',
      'name': 'Marco',
      'vibe': 'The Chef',
      'desc': 'Passionate, fiery, and knows how to taste.',
      'image': 'assets/images/avatar_chef_real.png', 
      'color': Colors.orange,
    },
    {
      'id': 'doctor',
      'name': 'Dr. Ethan',
      'vibe': 'The Doctor',
      'desc': 'Intelligent, caring, and knows anatomy well.',
      'image': 'assets/images/avatar_doctor_real.png', 
      'color': Colors.cyan,
    },
    {
      'id': 'pilot',
      'name': 'Captain Ryker',
      'vibe': 'The Pilot',
      'desc': 'Adventure, uniforms, and taking you to new heights.',
      'image': 'assets/images/avatar_pilot_real.png', 
      'color': Colors.indigo,
    },
    {
      'id': 'biker',
      'name': 'Spike',
      'vibe': 'Biker',
      'desc': 'Leather, chrome, and the open road.',
      'image': 'assets/images/avatar_biker_real.png', 
      'color': Colors.grey,
    },
    {
      'id': 'poet',
      'name': 'Liam',
      'vibe': 'The Poet',
      'desc': 'Words are his weapon, and he writes them for you.',
      'image': 'assets/images/avatar_poet_real.png', 
      'color': Colors.brown,
    },
    {
      'id': 'vampire',
      'name': 'Lucien',
      'vibe': 'Vampire',
      'desc': 'Eternal love, dark secrets, and a dangerous bite.',
      'image': 'assets/images/avatar_vampire_real.png', 
      'color': Colors.red,
    },
    {
      'id': 'guard',
      'name': 'Silas',
      'vibe': 'Bodyguard',
      'desc': 'He fails at nothing, especially protecting you.',
      'image': 'assets/images/avatar_bodyguard_real.png', 
      'color': Colors.black,
    },
    {
      'id': 'zeus',
      'name': 'Zeus',
      'vibe': 'Olympian King',
      'desc': "Regal, magnetic. He'll tell you what you need to hear.",
      'image': 'assets/images/avatar_zeus_real.png',
      'color': Colors.amber,
    },
    {
      'id': 'surfer',
      'name': 'Kai',
      'vibe': 'Surfer',
      'desc': 'Sun, salt, and endless chill vibes.',
      'image': 'assets/images/custom_avatar_02.png',
      'color': Colors.cyanAccent,
    },
    // Imported from SKLabChat — these two run on the Inworld pipeline
    // instead of the direct-OpenAI one every character above uses. The
    // worker decides the engine from 'id'; this 'engine' field is just
    // local documentation of that choice, not something sent to the
    // backend. Placeholder art — needs real portraits before shipping.
    {
      'id': 'odysseus',
      'name': 'Odysseus',
      'vibe': 'King of Ithaca',
      'desc': 'A strategist, wanderer, and survivor who speaks with cunning and hard-earned wisdom.',
      'image': 'assets/images/avatar_odysseus_real.png',
      'color': const Color(0xFF9D4F2F),
      'engine': 'inworld',
    },
    {
      'id': 'oedipus',
      'name': 'Oedipus',
      'vibe': 'King of Thebes',
      'desc': 'A tragic king carrying prophecy, pride, grief, and hard-won self-knowledge.',
      'image': 'assets/images/avatar_oedipus_real.png',
      'color': const Color(0xFF7D3F25),
      'engine': 'inworld',
    },
    // These two run on the default direct-OpenAI path (no INWORLD_CHARACTERS
    // entry in the worker), so their persona comes from CHARACTER_PERSONAS
    // in backend/src/worker.js rather than from the fields here.
    {
      'id': 'penelope',
      'name': 'Penelope',
      'vibe': 'Queen of Ithaca',
      'desc': 'Patient, sharp-witted, and unbreakably loyal through twenty years of waiting.',
      'image': 'assets/images/avatar_penelope_real.png',
      'color': const Color(0xFF6A4C93),
    },
    {
      'id': 'cupid',
      'name': 'Cupid',
      'vibe': 'God of Desire',
      'desc': 'Mischievous and disarming, with an aim no mortal heart survives.',
      // 4:3 rather than the square every other portrait uses; the card
      // crops with BoxFit.cover, so the sides are trimmed rather than
      // letterboxed.
      'image': 'assets/images/avatar_cupid_real.png',
      'color': const Color(0xFFD81B60),
    },
  ];

  /// Built-in characters allowed by AppConfig.visibleCharacterIds, in that
  /// list's order.
  List<Map<String, dynamic>> get _visibleCharacters {
    return AppConfig.visibleCharacterIds
        .map((id) => _characters.firstWhere((c) => c['id'] == id))
        .toList();
  }

  /// Characters for one dashboard group, in the group list's order. Ids with
  /// no matching entry are skipped rather than throwing, so a typo in
  /// AppConfig hides one card instead of taking down the whole dashboard.
  List<Map<String, dynamic>> _charactersForGroup(List<String> ids) {
    return ids
        .map((id) => _characters.where((c) => c['id'] == id).firstOrNull)
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  /// Greeting driven by the viewer's own device clock — DateTime.now() is
  /// local time, so this follows whatever timezone they are actually in.
  ///
  ///   05:00 – 11:59  Good Morning
  ///   12:00 – 16:59  Good Afternoon
  ///   17:00 – 21:59  Good Evening
  ///   22:00 – 04:59  Still awake?
  ///
  /// No trailing commas: these used to run into the viewer's name on the next
  /// line ("Good Afternoon, Clever Creature"). That line is gone, so a comma
  /// would now point at nothing.
  ///
  /// The late band exists because the naive version greeted someone at 2am
  /// with "Good Morning" — technically true, but it reads as a bug. "Still
  /// awake" suits the hour and the app's tone better than a fourth
  /// "Good ..." variant.
  String _timeOfDayGreeting() {
    final hour = DateTime.now().hour;
    if (hour >= 22 || hour < 5) return 'Still awake?';
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  @override
  void initState() {
    super.initState();
    // Precache all character images for smooth scrolling
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final character in _visibleCharacters) {
        precacheImage(AssetImage(character['image'] as String), context);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final customChars = AppConfig.enableCustomCharacters
        ? ref.watch(customCharactersProvider)
        : const <Map<String, dynamic>>[];

    final theme = Theme.of(context);
    final score = ref.watch(userScoreProvider);
    final level = 1 + (score ~/ 10);

    return Scaffold(
      body: Stack(
        children: [
           // Background
           Container(
             decoration: BoxDecoration(
               gradient: LinearGradient(
                 begin: Alignment.topLeft,
                 end: Alignment.bottomRight,
                 colors: [
                   theme.scaffoldBackgroundColor,
                   Colors.black,
                   theme.primaryColor.withOpacity(0.1),
                 ],
               ),
             ),
           ),
           
           SafeArea(
             child: Padding(
               // No bottom padding: the character grid runs to the edge of
               // the body so its clipped last row meets the nav bar directly.
               // Padding there left a band of background between the fade and
               // the bar, which read as the grid floating short of the bottom.
               padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
               child: Column(
                 crossAxisAlignment: CrossAxisAlignment.start,
                 children: [
                   // Header
                   Row(
                     mainAxisAlignment: MainAxisAlignment.spaceBetween,
                     children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _timeOfDayGreeting(),
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: Colors.white70,
                              ),
                            ),
                          ],
                        ),
                         // Relationship Level Indicator AND Settings
                         Row(
                           children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                   Row(
                                     children: [
                                       Icon(Icons.favorite, size: 14, color: theme.primaryColor),
                                       const SizedBox(width: 4),
                                       Text(
                                         'Level $level',
                                         style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold, color: Colors.white),
                                       ),
                                     ],
                                   ),
                                   const SizedBox(height: 4),
                                   // Progress Bar
                                   Container(
                                     width: 80,
                                     height: 4,
                                     decoration: BoxDecoration(
                                       color: Colors.white.withOpacity(0.1),
                                       borderRadius: BorderRadius.circular(2),
                                     ),
                                     alignment: Alignment.centerLeft,
                                     child: FractionallySizedBox(
                                       widthFactor: (score % 10) / 10.0, // Mock progress for level
                                       child: Container(
                                         decoration: BoxDecoration(
                                           color: theme.primaryColor,
                                           borderRadius: BorderRadius.circular(2),
                                         ),
                                       ),
                                     ),
                                   ),
                                ],
                              ),
                             const SizedBox(width: 16),
                             GestureDetector(
                               onTap: () => context.push('/settings'),
                               child: Container(
                                 padding: const EdgeInsets.all(8),
                                 decoration: BoxDecoration(
                                   color: Colors.white.withOpacity(0.1),
                                   shape: BoxShape.circle,
                                   border: Border.all(color: Colors.white.withOpacity(0.2)),
                                 ),
                                 child: const Icon(Icons.settings, color: Colors.white, size: 20),
                               ),
                             ),
                           ],
                         ),
                     ],
                   ),
                   const SizedBox(height: 32),
                   
                   Text(
                      'Select your ChatMate',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.normal,
                      ),
                   ),
                   const SizedBox(height: 16),

                   // One tab per character group, Greek first. Custom
                   // characters get their own trailing tab so they never
                   // mix into the built-in groups.
                   Expanded(
                     child: DefaultTabController(
                       length: AppConfig.enableCustomCharacters ? 3 : 2,
                       child: Column(
                         crossAxisAlignment: CrossAxisAlignment.start,
                         children: [
                           // Styled as a filled segmented control rather than
                           // underlined text: on first open the Greek tab is
                           // selected, and the unselected segments need to
                           // read clearly as "there is more here", not as
                           // decoration above the grid.
                           Container(
                             padding: const EdgeInsets.all(3),
                             decoration: BoxDecoration(
                               color: Colors.white.withOpacity(0.07),
                               borderRadius: BorderRadius.circular(22),
                               border: Border.all(
                                 color: Colors.white.withOpacity(0.12),
                               ),
                             ),
                             child: TabBar(
                               labelColor: Colors.white,
                               unselectedLabelColor: Colors.white70,
                               dividerColor: Colors.transparent,
                               indicatorSize: TabBarIndicatorSize.tab,
                               splashBorderRadius: BorderRadius.circular(18),
                               indicator: BoxDecoration(
                                 color: theme.primaryColor,
                                 borderRadius: BorderRadius.circular(18),
                               ),
                               labelPadding: EdgeInsets.zero,
                               labelStyle: const TextStyle(
                                 fontSize: 12,
                                 fontWeight: FontWeight.bold,
                                 letterSpacing: 1.1,
                               ),
                               unselectedLabelStyle: const TextStyle(
                                 fontSize: 12,
                                 fontWeight: FontWeight.w600,
                                 letterSpacing: 1.1,
                               ),
                               tabs: [
                                 _buildTab(AppConfig.greekSectionTitle),
                                 _buildTab(AppConfig.modernSectionTitle),
                                 if (AppConfig.enableCustomCharacters)
                                   _buildTab('Yours'),
                               ],
                             ),
                           ),
                           const SizedBox(height: 10),
                           Expanded(
                             child: TabBarView(
                               children: [
                                 _buildCharacterGrid(
                                   _charactersForGroup(AppConfig.greekCharacterIds),
                                   theme,
                                 ),
                                 _buildCharacterGrid(
                                   _charactersForGroup(AppConfig.modernCharacterIds),
                                   theme,
                                 ),
                                 if (AppConfig.enableCustomCharacters)
                                   _buildCharacterGrid(
                                     customChars,
                                     theme,
                                     trailingCreateCard: true,
                                   ),
                               ],
                             ),
                           ),
                         ],
                       ),
                     ),
                   ),
                 ],
               ),
             ),
           ),
        ],
      ),
    );
  }

  /// A tab label, uppercased for display. In mixed case at this size the
  /// "rn" in "Modern" runs together and reads as "Modem"; caps plus letter
  /// spacing removes the ambiguity, which is what lets the label sit at
  /// 12pt. The config values stay in normal case so they read naturally in
  /// code.
  Widget _buildTab(String title) {
    return Tab(
      height: 22,
      child: Text(title.toUpperCase()),
    );
  }

  /// The card grid for one tab. Empty groups show a short placeholder
  /// rather than a blank pane, so an empty tab still reads as intentional.
  Widget _buildCharacterGrid(
    List<Map<String, dynamic>> characters,
    ThemeData theme, {
    bool trailingCreateCard = false,
  }) {
    if (characters.isEmpty && !trailingCreateCard) {
      return Center(
        child: Text(
          'Nobody here yet.',
          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white38),
        ),
      );
    }

    final itemCount = characters.length + (trailingCreateCard ? 1 : 0);

    // Always two across, on every viewport width, and sized to show exactly
    // one 2x2 screenful. When a group holds more than four, the grid is made
    // slightly taller so the next row peeks in underneath — that sliver of
    // artwork is what tells people to keep scrolling. The width cap stops
    // two columns from stretching into full-screen cards on desktop.
    // Align rather than Center: the grid is pinned to the top of whatever
    // space it is given, so any shortfall shows up as one gap at the bottom
    // that the fill logic below can close, not as two half-gaps.
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: LayoutBuilder(
          builder: (context, constraints) {
            const spacing = 16.0;

            // Half a card of the next row stays in view, which together with
            // the two full rows above it is the 2.5 rows the grid is sized
            // for. Must match minRowsVisible below — a smaller peek would
            // size cards for 2.5 rows but only ever reveal 2.2 of them.
            const peekFraction = 0.5;

            // At least two and a half rows should be in view, so the grid
            // never reads as a single row of cards with space beneath. On a
            // short window that means shorter cards rather than fewer rows:
            // the height is derived from the space available, not fixed.
            const minRowsVisible = 2.5;

            // Card proportions stay between these bounds so the adaptive
            // height can't produce something absurd — 0.75 is the original
            // portrait shape and the tallest allowed; 0.6 lets cards go
            // wide-ish on a short window, which is what buys the 2.5 rows
            // there. A tighter floor left cards too tall to fit 2.5 and the
            // grid quietly fell back to two.
            const tallestRatio = 0.75;
            const squattestRatio = 0.6;

            final available = constraints.maxHeight;
            final cardWidth = (constraints.maxWidth - spacing) / 2;

            final fitHeight =
                (available - (2 * spacing)) / minRowsVisible;
            final cardHeight = fitHeight.clamp(
              cardWidth * squattestRatio,
              cardWidth / tallestRatio,
            );
            final aspectRatio = cardWidth / cardHeight;
            final rowStride = cardHeight + spacing;

            final totalRows = (itemCount / 2).ceil();
            final contentHeight =
                (totalRows * cardHeight) + ((totalRows - 1) * spacing);

            // When the group overflows, the grid fills the whole space it has
            // been given rather than stopping at a computed row boundary.
            //
            // Two reasons. Cards are already sized so ~2.5 rows fit, so
            // filling lands the cut mid-card without extra arithmetic. And
            // leaving dead space below meant the fade ended in mid-air with
            // its own bottom edge showing against the purple backdrop — a
            // floating band. Reaching the bottom puts that edge flush against
            // the nav bar, where there is nothing to see it against.
            //
            // When the whole group already fits, none of this applies: the
            // grid takes its natural height and nothing is clipped, because
            // faking a cut-off row when there is nothing below reads as a
            // rendering bug rather than an invitation.
            final double height;
            final bool scrollable;
            if (contentHeight <= available) {
              height = contentHeight;
              scrollable = false;
            } else {
              height = available;
              scrollable = true;
            }

            return Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                height: height,
                child: Stack(
                  children: [
                    GridView.builder(
                      padding: EdgeInsets.zero,
                      gridDelegate:
                          SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        childAspectRatio: aspectRatio,
                        crossAxisSpacing: spacing,
                        mainAxisSpacing: spacing,
                      ),
                      itemCount: itemCount,
                      itemBuilder: (context, index) {
                        if (index == characters.length) {
                          return _buildCreateNewCard(theme, compact: false);
                        }
                        return _buildCharacterCard(
                          characters[index],
                          theme,
                          compact: false,
                        );
                      },
                    ),
                    // Softens the clipped row into a fade rather than a hard
                    // cut.
                    //
                    // Fades to black rather than to scaffoldBackgroundColor:
                    // the page behind sits on a purple gradient, so a solid
                    // scaffold colour ended in a hue that did not match its
                    // surroundings and the gradient's own bottom edge became
                    // visible as a floating band. Black shares the backdrop's
                    // darkest tone, so the ramp reads as the artwork dimming
                    // out instead of a rectangle laid over it.
                    //
                    // IgnorePointer so it never swallows a scroll or a tap on
                    // the card underneath.
                    if (scrollable)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: cardHeight * peekFraction,
                        child: IgnorePointer(
                          child: Container(
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                stops: [0.0, 0.45, 1.0],
                                colors: [
                                  Color(0x00000000),
                                  Color(0x33000000),
                                  Color(0xF2000000),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Opens a character's profile from the dashboard.
  ///
  /// Backing out returns here, to the character list — the profile was opened
  /// from the dashboard, so that is where "back" belongs. Chat is only opened
  /// when the user actually taps an "Ask Me About" opener, which arrives as
  /// the pop result and is then sent as the first message.
  Future<void> _openProfileFor(Map<String, dynamic> character) async {
    final profile = profileForCharacter(character['id'] as String?);
    if (profile == null) return;

    final question = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => CharacterProfileScreen(
          name: character['name'] as String,
          title: character['vibe'] as String,
          imagePath: character['image'] as String,
          profile: profile,
          // Messages are keyed by the scenario string the chat screen uses.
          chatId: '${character['name']} (${character['vibe']})',
          characterKey: character['id'] as String?,
        ),
      ),
    );

    // Null means the user backed out rather than picking an opener — stay on
    // the dashboard instead of pushing them into a chat they didn't ask for.
    if (!mounted || question == null || question.isEmpty) return;
    _openChat(character, initialMessage: question);
  }

  void _openChat(Map<String, dynamic> character, {String? initialMessage}) {
    final characterId = character['id'] as String?;
    final characterIdParam = (characterId != null && characterId.isNotEmpty)
        ? '&characterId=${Uri.encodeComponent(characterId)}'
        : '';
    final openerParam = (initialMessage != null && initialMessage.isNotEmpty)
        ? '&initialMessage=${Uri.encodeComponent(initialMessage)}'
        : '';
    context.push(
      '/chat/session?scenario=${Uri.encodeComponent('${character['name']} (${character['vibe']})')}'
      '&characterImage=${Uri.encodeComponent(character['image'])}'
      '&isRoleplay=false$characterIdParam$openerParam',
    );
  }

  Widget _buildCharacterCard(Map<String, dynamic> character, ThemeData theme, {required bool compact}) {
    final isCustom = character['isCustom'] == true;
    final hasProfile = profileForCharacter(character['id'] as String?) != null;

    return _HoverRegion(
      builder: (hovering) => Stack(
        children: [
          _buildCardBody(character, theme, compact: compact, isCustom: isCustom),
          // Profile affordance. Always rendered when a profile exists — not
          // hover-only — because touch devices have no hover state and would
          // otherwise never see it. Pointer devices get a stronger version
          // on hover; touch users get a permanently tappable target.
          if (hasProfile)
            Positioned(
              top: compact ? 6 : 10,
              right: compact ? 6 : 10,
              child: _ProfileBadge(
                highlighted: hovering,
                onTap: () => _openProfileFor(character),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCardBody(
    Map<String, dynamic> character,
    ThemeData theme, {
    required bool compact,
    required bool isCustom,
  }) {
    return GestureDetector(
      onTap: () => _openChat(character),
      onLongPress: isCustom ? () {
        // Show delete dialog for custom characters
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete Custom Character?'),
            content: Text('Are you sure you want to delete ${character['name']}?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () async {
                  await ref.read(customCharactersProvider.notifier).deleteCharacter(character['id']);
                  // No need to setState, provider will update UI
                  if (context.mounted) Navigator.pop(context);
                },
                child: const Text('Delete', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        );
      } : null,
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withOpacity(0.5),
          borderRadius: BorderRadius.circular(compact ? 14 : 20),
          border: Border.all(color: theme.primaryColor.withOpacity(0.3)),
          image: DecorationImage(
             image: AssetImage(character['image']),
             fit: BoxFit.cover,
             // Removed opacity to make image clear
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(compact ? 14 : 20),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0.5, 1.0], // Gradient starts halfway down
              colors: [
                Colors.transparent,
                Colors.black.withOpacity(0.9),
              ],
            ),
          ),
          padding: EdgeInsets.all(compact ? 6 : 12),
          child: Stack(
            children: [
              Align(
                alignment: Alignment.bottomLeft,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      character['name'],
                      style: compact
                          ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold)
                          : theme.textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      character['vibe'],
                      style: (compact ? theme.textTheme.bodySmall : theme.textTheme.bodyMedium)?.copyWith(
                        color: theme.colorScheme.secondary,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (!compact) ...[
                      const SizedBox(height: 4),
                      Text(
                        character['desc'],
                        style: theme.textTheme.bodyMedium?.copyWith(fontSize: 10, color: Colors.white70),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (isCustom)
                Align(
                  alignment: Alignment.topRight,
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8, vertical: compact ? 2 : 4),
                    decoration: BoxDecoration(
                      color: Colors.pink.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(compact ? 10 : 12),
                    ),
                    child: Text(
                      'CUSTOM',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: compact ? 8 : 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCreateNewCard(ThemeData theme, {required bool compact}) {
    final isPremium = ref.read(userSubscriptionProvider);

    return GestureDetector(
      onTap: () {
        if (!isPremium) {
           context.push('/paywall');
           return;
        }
        context.push('/create-character');
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(compact ? 14 : 20),
          border: Border.all(color: Colors.white.withOpacity(0.2), style: BorderStyle.solid),
        ),
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: EdgeInsets.all(compact ? 8 : 16),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.primaryColor.withOpacity(0.2),
                    ),
                    child: Icon(Icons.add, color: theme.primaryColor, size: compact ? 20 : 32),
                  ),
                  SizedBox(height: compact ? 6 : 12),
                  Text(
                    'Create Custom',
                    style: compact ? theme.textTheme.bodySmall : theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            if (!isPremium)
              Positioned(
                top: compact ? 6 : 12,
                right: compact ? 6 : 12,
                child: Container(
                  padding: EdgeInsets.all(compact ? 4 : 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.lock, color: Colors.amber, size: compact ? 12 : 16),
                ),
              ),
          ],
        ),
      ),
    );
  }


}

/// Tracks pointer hover so a child can render a stronger affordance on
/// desktop. On touch devices onEnter/onExit never fire, so `hovering` stays
/// false and the child must still be usable in that state.
class _HoverRegion extends StatefulWidget {
  final Widget Function(bool hovering) builder;

  const _HoverRegion({required this.builder});

  @override
  State<_HoverRegion> createState() => _HoverRegionState();
}

class _HoverRegionState extends State<_HoverRegion> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: widget.builder(_hovering),
    );
  }
}

/// The "open profile" affordance on a character card.
///
/// Visible at all times so touch users have something to tap, but quiet
/// enough not to compete with the artwork: a small translucent dot. On hover
/// it brightens and grows a "Profile" label, which is the desktop cue that
/// the card holds more than a chat.
class _ProfileBadge extends StatelessWidget {
  final bool highlighted;
  final VoidCallback onTap;

  const _ProfileBadge({required this.highlighted, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(
            horizontal: highlighted ? 10 : 6,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            color: highlighted
                ? theme.primaryColor.withOpacity(0.95)
                : Colors.black.withOpacity(0.45),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white.withOpacity(highlighted ? 0.9 : 0.35),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.person_outline,
                size: 14,
                color: Colors.white,
              ),
              // The label only appears on hover; on a phone the icon alone
              // has to carry it, which is why the dot is always present.
              if (highlighted) ...[
                const SizedBox(width: 4),
                const Text(
                  'Profile',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
