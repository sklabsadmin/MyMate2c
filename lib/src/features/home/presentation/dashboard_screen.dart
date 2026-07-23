import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/config/app_config.dart';
import '../../../core/services/storage_service.dart';

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
      'desc': 'Regal, magnetic. Let him light a storm in your desires.',
      'image': 'assets/images/avatar_zeus_real.png',
      'color': Colors.amber,
    },
    {
      'id': 'surfer',
      'name': 'Kai',
      'vibe': 'Surfer',
      'desc': 'Sun, salt, and endless chill vibes.',
      'image': 'assets/images/avatar_badboy_real.png',
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
    // entry in the worker), so their persona comes from 'vibe'/'desc' alone
    // rather than a dedicated system prompt — same as Zeus.
    // Cupid still uses placeholder art: drop in
    // assets/images/avatar_cupid_real.png and update its 'image' line below.
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
      'image': 'assets/images/avatar_zeus_real.png', // TODO: placeholder
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

  /// Greeting that tracks the viewer's own clock rather than being fixed to
  /// evening. Boundaries: morning until noon, afternoon until 17:00.
  String _timeOfDayGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning,';
    if (hour < 17) return 'Good Afternoon,';
    return 'Good Evening,';
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
               padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
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
                            Text(
                              'Titillating Mortal',
                              style: theme.textTheme.displayLarge?.copyWith(fontSize: 28, color: Colors.white),
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
                      style: theme.textTheme.headlineSmall,
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
                               ),
                               unselectedLabelStyle: const TextStyle(
                                 fontSize: 12,
                                 fontWeight: FontWeight.w600,
                               ),
                               tabs: [
                                 _buildTab(
                                   AppConfig.greekSectionTitle,
                                   _charactersForGroup(
                                     AppConfig.greekCharacterIds,
                                   ).length,
                                 ),
                                 _buildTab(
                                   AppConfig.modernSectionTitle,
                                   _charactersForGroup(
                                     AppConfig.modernCharacterIds,
                                   ).length,
                                 ),
                                 if (AppConfig.enableCustomCharacters)
                                   _buildTab('Yours', customChars.length),
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

  /// A tab label with its character count, so both tabs advertise how much
  /// is behind them even while the other one is selected.
  Widget _buildTab(String title, int count) {
    return Tab(
      height: 25,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title),
          const SizedBox(width: 5),
          Text(
            '$count',
            style: const TextStyle(fontSize: 10, color: Colors.white70),
          ),
        ],
      ),
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
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: LayoutBuilder(
          builder: (context, constraints) {
            const spacing = 16.0;
            const aspectRatio = 0.75;
            const peekFraction = 0.2;

            final cardWidth = (constraints.maxWidth - spacing) / 2;
            final cardHeight = cardWidth / aspectRatio;

            // Two full rows, plus a peek at the third only when there is
            // actually more to reveal.
            var desiredHeight = (cardHeight * 2) + spacing;
            if (itemCount > 4) {
              desiredHeight += spacing + (cardHeight * peekFraction);
            }

            final height = desiredHeight.clamp(0.0, constraints.maxHeight);

            return Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                height: height,
                child: GridView.builder(
                  padding: EdgeInsets.zero,
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
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
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCharacterCard(Map<String, dynamic> character, ThemeData theme, {required bool compact}) {
    final isCustom = character['isCustom'] == true;
    
    return GestureDetector(
      onTap: () {
        // Navigate to Chat
        final characterId = character['id'] as String?;
        final characterIdParam = (characterId != null && characterId.isNotEmpty)
            ? '&characterId=${Uri.encodeComponent(characterId)}'
            : '';
        context.push('/chat/session?scenario=${Uri.encodeComponent(character['name'] + " (" + character['vibe'] + ")")}&characterImage=${Uri.encodeComponent(character['image'])}&isRoleplay=false$characterIdParam');
      },
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
