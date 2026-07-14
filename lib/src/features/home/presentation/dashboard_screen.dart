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
    final customChars = ref.watch(customCharactersProvider);
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
                     child: GridView.builder(
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          childAspectRatio: 0.75,
                          crossAxisSpacing: 16,
                          mainAxisSpacing: 16,
                        ),
                        itemCount: allCharacters.length + 1, // +1 for "Create Custom"
                        itemBuilder: (context, index) {
                          if (index == allCharacters.length) {
                            return _buildCreateNewCard(theme);
                          }
                          final character = allCharacters[index];
                          return _buildCharacterCard(character, theme);
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

  Widget _buildCharacterCard(Map<String, dynamic> character, ThemeData theme) {
    final isCustom = character['isCustom'] == true;
    
    return GestureDetector(
      onTap: () {
        // Navigate to Chat
        context.push('/chat/session?scenario=${Uri.encodeComponent(character['name'] + " (" + character['vibe'] + ")")}&characterImage=${Uri.encodeComponent(character['image'])}&isRoleplay=false'); 
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
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: theme.primaryColor.withOpacity(0.3)),
          image: DecorationImage(
             image: AssetImage(character['image']), 
             fit: BoxFit.cover,
             // Removed opacity to make image clear
          ),
        ),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
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
          padding: const EdgeInsets.all(12),
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
                      style: theme.textTheme.titleMedium,
                    ),
                    Text(
                      character['vibe'],
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.secondary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      character['desc'],
                      style: theme.textTheme.bodyMedium?.copyWith(fontSize: 10, color: Colors.white70),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (isCustom)
                Align(
                  alignment: Alignment.topRight,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.pink.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text(
                      'CUSTOM',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
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

  Widget _buildCreateNewCard(ThemeData theme) {
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
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.2), style: BorderStyle.solid),
        ),
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.primaryColor.withOpacity(0.2),
                    ),
                    child: Icon(Icons.add, color: theme.primaryColor, size: 32),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Create Custom',
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ),
            ),
            if (!isPremium)
              Positioned(
                top: 12,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.lock, color: Colors.amber, size: 16),
                ),
              ),
          ],
        ),
      ),
    );
  }


}
