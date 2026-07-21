import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/services/storage_service.dart';

class RoleplayScreen extends ConsumerStatefulWidget {
  const RoleplayScreen({super.key});

  @override
  ConsumerState<RoleplayScreen> createState() => _RoleplayScreenState();
}

class _RoleplayScreenState extends ConsumerState<RoleplayScreen> {
  final List<Map<String, dynamic>> scenarios = [
      // Wild & Sexy Scenarios (New)
      {
        'title': 'Against the Wall',
        'desc': 'Pressed tight, nowhere to run. Just you, him, and the heat between you.',
        'image': 'assets/images/roleplay_wall.png',
        'color': Colors.indigoAccent,
      },
      {
        'title': 'Lap Sitting',
         'desc': 'He claims you right there. Pure ownership and dominance.',
        'image': 'assets/images/roleplay_lap.png',
        'color': Colors.deepOrange,
      },
      {
        'title': 'Morning Intimacy',
        'desc': 'Waking up to his touch. Soft, slow, and incredibly deep.',
        'image': 'assets/images/roleplay_morning.png',
        'color': Colors.amber.shade900,
      },
      {
        'title': 'Steamy Shower',
        'desc': 'Wet, wild, and hot enough to fog up every window.',
        'image': 'assets/images/roleplay_shower.png',
        'color': Colors.cyan.shade900,
      },
      // Classic Scenarios
      {
        'title': 'The Stranger',
        'desc': 'You meet a mysterious, handsome stranger at a hotel bar...',
        'image': 'assets/images/avatar_badboy_real.png',
        'color': Colors.amber,
      },
      {
        'title': 'Strict Professor',
        'desc': 'You stayed after class to discuss your... extra credit.',
        'image': 'assets/images/avatar_ceo_real.png',
        'color': Colors.blueGrey,
      },
      {
        'title': 'Possessive CEO',
        'desc': "He doesn't like when you talk to other men in the office.",
        'image': 'assets/images/avatar_ceo_real.png',
        'color': Colors.deepPurple,
      },
       {
        'title': 'Comforting Husband',
        'desc': 'A gentle night in after a long, hard day.',
        'image': 'assets/images/avatar_artist_real.png',
        'color': Colors.teal,
      },
      {
        'title': 'Vampire Lord',
        'desc': 'He has waited centuries for a love like yours. Dark & Seductive.',
        'image': 'assets/images/avatar_vampire_real.png', 
        'color': Colors.redAccent,
      },
      {
        'title': 'Personal Trainer',
        'desc': 'He\'s going to make you sweat. "Good form, keep going..."',
        'image': 'assets/images/avatar_trainer_real.png',
        'color': Colors.orangeAccent,
      },
      {
        'title': 'Royal Guard',
        'desc': 'Sworn to protect you, but forbidden to love you.',
        'image': 'assets/images/avatar_bodyguard_real.png',
        'color': Colors.indigo,
      },
      {
        'title': 'Childhood Enemy',
        'desc': "You used to hate him. Now he's back and hotter than ever.",
        'image': 'assets/images/avatar_badboy_real.png',
        'color': Colors.yellow,
      },
      {
        'title': 'Bad Boy Biker',
        'desc': 'Leather jacket, roar of an engine, and trouble written all over him.',
        'image': 'assets/images/avatar_biker_real.png',
        'color': Colors.grey,
      },
      {
        'title': 'Mafia Boss',
        'desc': 'Dangerous, powerful, and you are his only weakness.',
        'image': 'assets/images/avatar_ceo_real.png',
        'color': Colors.black,
      },
      {
        'title': 'Famous Musician',
        'desc': 'He writes songs about you. Front row seat to his world.',
        'image': 'assets/images/avatar_rockstar_real.png',
        'color': Colors.pinkAccent,
      },
      {
        'title': 'Doctor',
        'desc': '"Tell me where it hurts." Late night rounds just got interesting.',
        'image': 'assets/images/avatar_doctor_real.png',
        'color': Colors.cyan,
      },
      {
        'title': 'Firefighter',
        'desc': 'He saves lives, but can you save his heart? Heroic & Strong.',
        'image': 'assets/images/avatar_pilot_real.png',
        'color': Colors.deepOrange,
      },
       {
        'title': 'Werewolf Alpha',
        'desc': 'Wild, primal, and fiercely protective of his mate.',
        'image': 'assets/images/avatar_artist_real.png',
        'color': Colors.brown,
      },
  ];

  @override
  void initState() {
    super.initState();
    // Precache scenario images for smooth performance
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final scenario in scenarios) {
        precacheImage(AssetImage(scenario['image'] as String), context);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Roleplay',
          style: theme.textTheme.headlineSmall,
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(20),
        itemCount: scenarios.length,
        itemBuilder: (context, index) {
          final scenario = scenarios[index];
          return Container(
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () {
                   final isPremium = ref.read(userSubscriptionProvider);
                   if (!isPremium) {
                     context.push('/paywall');
                     return;
                   }
                   context.push('/chat/session?scenario=${Uri.encodeComponent(scenario['title']!)}&characterImage=${Uri.encodeComponent(scenario['image']!)}&isRoleplay=true');
                },
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: (scenario['color'] as Color).withOpacity(0.5), width: 2),
                          image: DecorationImage(
                             image: AssetImage(scenario['image'] as String),
                             fit: BoxFit.cover,
                          ),
                        ),
                      ),

                      const SizedBox(width: 20),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              scenario['title'] as String,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              scenario['desc'] as String,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.white60,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      
                      const SizedBox(width: 8),

                      if (!ref.watch(userSubscriptionProvider))
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                             color: Colors.black54,
                             shape: BoxShape.circle,
                             border: Border.all(color: Colors.white24),
                          ),
                          child: const Icon(Icons.lock, color: Colors.amber, size: 20),
                        )
                      else 
                        const Icon(Icons.arrow_forward_ios, color: Colors.white24, size: 16),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
