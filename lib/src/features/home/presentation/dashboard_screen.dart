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
  ];

  /// Built-in characters allowed by AppConfig.visibleCharacterIds, in that
  /// list's order.
  List<Map<String, dynamic>> get _visibleCharacters {
    return AppConfig.visibleCharacterIds
        .map((id) => _characters.firstWhere((c) => c['id'] == id))
        .toList();
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
    final allCharacters = [..._visibleCharacters, ...customChars];

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
                              'Good Evening,',
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: Colors.white70,
                              ),
                            ),
                            Text(
                              'Beautiful',
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
                      'Select Your Partner',
                      style: theme.textTheme.headlineSmall,
                   ),
                   const SizedBox(height: 16),
                   
                   // Grid of Boyfriends
                   Expanded(
                     child: LayoutBuilder(
                       builder: (context, constraints) {
                         // Mobile screens keep the original large cards;
                         // wider (desktop/PC) viewports get more, smaller
                         // cards instead of stretching each one huge.
                         final isWide = constraints.maxWidth > 600;
                         return GridView.builder(
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: isWide ? 4 : 2,
                              childAspectRatio: 0.75,
                              crossAxisSpacing: isWide ? 12 : 16,
                              mainAxisSpacing: isWide ? 12 : 16,
                            ),
                            // +1 for the "Create Custom" card when enabled
                            itemCount: allCharacters.length +
                                (AppConfig.enableCustomCharacters ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index == allCharacters.length) {
                                return _buildCreateNewCard(theme, compact: isWide);
                              }
                              final character = allCharacters[index];
                              return _buildCharacterCard(character, theme, compact: isWide);
                            },
                          );
                       },
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
