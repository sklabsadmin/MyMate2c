import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/services/storage_service.dart';

class CreateCharacterScreen extends ConsumerStatefulWidget {
  const CreateCharacterScreen({super.key});

  @override
  ConsumerState<CreateCharacterScreen> createState() => _CreateCharacterScreenState();
}

class _CreateCharacterScreenState extends ConsumerState<CreateCharacterScreen> {
  final PageController _pageController = PageController();
  final TextEditingController _nameController = TextEditingController();
  
  int _currentStep = 0;
  
  // State for selections
  String _selectedVibe = '';
  String _selectedEyes = '';
  String _selectedHair = '';
  String _selectedStyle = '';
  String _selectedImage = 'assets/images/avatar_ceo_real.png'; // Default

  final List<String> _availableAvatars = [
    'assets/images/custom_avatar_01.png',
    'assets/images/custom_avatar_02.png',
    'assets/images/custom_avatar_03.png',
    'assets/images/custom_avatar_04.png',
    'assets/images/custom_avatar_05.png',
    'assets/images/custom_avatar_06.png',
    'assets/images/custom_avatar_07.png',
    'assets/images/custom_avatar_08.png',
    'assets/images/custom_avatar_09.png',
    'assets/images/custom_avatar_10.png',
    'assets/images/custom_avatar_11.png',
    'assets/images/custom_avatar_12.png',
    'assets/images/custom_avatar_13.png',
    'assets/images/custom_avatar_14.png',
    'assets/images/custom_avatar_15.png',
    'assets/images/avatar_ceo_real.png',
    'assets/images/avatar_architect_real.png',
    'assets/images/avatar_artist_real.png',
    'assets/images/avatar_badboy_real.png',
    'assets/images/avatar_biker_real.png',
    'assets/images/avatar_bodyguard_real.png',
    'assets/images/avatar_ceo_real.png',
    'assets/images/avatar_chef_real.png',
    'assets/images/avatar_doctor_real.png',
    'assets/images/avatar_pilot_real.png',
    'assets/images/avatar_poet_real.png',
    'assets/images/avatar_rockstar_real.png',
    'assets/images/avatar_vampire_real.png',
    'assets/images/avatar_trainer_real.png',
  ];
  
  final List<Map<String, dynamic>> _steps = [
    {
      'title': 'First Impressions',
      'subtitle': 'What do you call the man of your dreams?',
    },
    {
       'title': 'His Look',
       'subtitle': 'Select the appearance that captivates you.',
    },
    {
      'title': 'His Gaze',
      'subtitle': 'What kind of eyes make you weak at the knees?',
    },
    {
      'title': 'His Vibe',
      'subtitle': 'How does he make you feel?',
    },
    {
      'title': 'His Style',
      'subtitle': 'How does he dress to impress you?',
    },
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () {
            if (_currentStep > 0) {
              _pageController.previousPage(
                duration: const Duration(milliseconds: 300), 
                curve: Curves.easeInOut
              );
            } else {
              context.pop();
            }
          },
        ),
      ),
      body: Stack(
        children: [
          // Background with romantic gradient
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0xFF2E003E), // Deep Purple
                  theme.primaryColor.withOpacity(0.3),
                  Colors.black,
                ],
              ),
            ),
          ),
          
          // Subtle animated overlay (could be particles in future, static for now)
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(color: Colors.black.withOpacity(0.2)),
            ),
          ),

          SafeArea(
            child: Column(
              children: [
                // Progress Indicator
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                  child: LinearProgressIndicator(
                    value: (_currentStep + 1) / _steps.length,
                    backgroundColor: Colors.white10,
                    valueColor: AlwaysStoppedAnimation<Color>(theme.primaryColor),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),

                // Step Title & Subtitle
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      Text(
                        _steps[_currentStep]['title'],
                        style: theme.textTheme.headlineSmall?.copyWith(fontSize: 28),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _steps[_currentStep]['subtitle'],
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white70,
                          fontSize: 16,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 40),

                // Main Content Area
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    physics: const NeverScrollableScrollPhysics(), // Disable swipe to enforce selection
                    onPageChanged: (index) => setState(() => _currentStep = index),
                    children: [
                      _buildNameStep(theme),
                      _buildImageGrid(theme),
                      _buildEyesHairStep(theme),
                      _buildVibeStep(theme),
                      _buildStyleStep(theme),
                    ],
                  ),
                ),

                // Next / Finish Button
                Padding(
                  padding: const EdgeInsets.all(32.0),
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      boxShadow: [
                        BoxShadow(
                          color: theme.primaryColor.withOpacity(0.5),
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: theme.primaryColor,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                      ),
                      onPressed: _handleNextStep,
                      child: Text(
                        _currentStep == _steps.length - 1 ? 'Bring Him to Life' : 'Continue',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageGrid(ThemeData theme) {
    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.8,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: _availableAvatars.length,
      itemBuilder: (context, index) {
        final imagePath = _availableAvatars[index];
        final isSelected = _selectedImage == imagePath;
        
        return GestureDetector(
          onTap: () => setState(() => _selectedImage = imagePath),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isSelected ? theme.primaryColor : Colors.white12,
                width: isSelected ? 3 : 1,
              ),
              image: DecorationImage(
                image: AssetImage(imagePath),
                fit: BoxFit.cover,
                colorFilter: isSelected ? null : ColorFilter.mode(Colors.black.withOpacity(0.5), BlendMode.darken),
              ),
              boxShadow: isSelected ? [
                BoxShadow(
                  color: theme.primaryColor.withOpacity(0.5),
                  blurRadius: 12,
                  spreadRadius: 2,
                )
              ] : null,
            ),
            child: isSelected ? Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: theme.primaryColor,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check, size: 16, color: Colors.white),
                ),
              ),
            ) : null,
          ),
        );
      },
    );
  }

  Widget _buildNameStep(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Center(
        child: TextField(
          controller: _nameController,
          style: GoogleFonts.playfairDisplay(
            fontSize: 32,
            color: Colors.white,
            fontWeight: FontWeight.bold
          ),
          textAlign: TextAlign.center,
          decoration: InputDecoration(
            hintText: 'Enter his name',
            hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
            border: InputBorder.none,
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: theme.primaryColor)),
          ),
        ),
      ),
    );
  }

  Widget _buildEyesHairStep(ThemeData theme) {
    // Combining Eyes and Hair for flow
    final eyeColors = [
      'Ocean Blue', 'Deep Hazel', 'Emerald Green', 'Mysterious Black',
      'Golden Amber', 'Ice Blue', 'Warm Brown', 'Seductive Grey'
    ];
    final hairStyles = [
      'Messy Curls', 'Sleek & Dark', 'Rugged Stubble', 'Long & Wavy',
      'Short & Neat', 'Man Bun', 'Bald & Bold', 'Silver Fox'
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Eyes', style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: eyeColors.map((color) => _buildSelectionChip(
              label: color,
              isSelected: _selectedEyes == color,
              onTap: () => setState(() => _selectedEyes = color),
            )).toList(),
          ),
          const SizedBox(height: 32),
          Text('Hair', style: theme.textTheme.titleMedium),
          const SizedBox(height: 16),
           Wrap(
            spacing: 12,
            runSpacing: 12,
            children: hairStyles.map((style) => _buildSelectionChip(
              label: style,
              isSelected: _selectedHair == style,
              onTap: () => setState(() => _selectedHair = style),
            )).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildVibeStep(ThemeData theme) {
    final vibes = [
      {'label': 'Dominant', 'desc': 'Takes control, possessive'},
      {'label': 'Gentle', 'desc': 'Sweet, caring, listener'},
      {'label': 'Playful', 'desc': 'Fun, teasing, energetic'},
      {'label': 'Intellectual', 'desc': 'Deep, mysterious, smart'},
      {'label': 'Protective', 'desc': 'Keeps you safe at all costs'},
      {'label': 'Rebellious', 'desc': 'Rules are made to be broken'},
      {'label': 'Flirty', 'desc': 'Always has a wink ready'},
      {'label': 'Sophisticated', 'desc': 'Classy, refined, timeless'},
    ];

    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      itemCount: vibes.length,
      separatorBuilder: (_, __) => const SizedBox(height: 16),
      itemBuilder: (context, index) {
        final vibe = vibes[index];
        final isSelected = _selectedVibe == vibe['label'];
        
        return GestureDetector(
          onTap: () => setState(() => _selectedVibe = vibe['label']!),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: isSelected ? theme.primaryColor.withOpacity(0.2) : Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isSelected ? theme.primaryColor : Colors.white10,
                width: isSelected ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(vibe['label']!, style: theme.textTheme.titleMedium?.copyWith(
                        color: isSelected ? Colors.white : Colors.white70,
                      )),
                      const SizedBox(height: 4),
                      Text(vibe['desc']!, style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white54,
                        fontSize: 12,
                      )),
                    ],
                  ),
                ),
                if (isSelected) 
                  Icon(Icons.check_circle, color: theme.primaryColor),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildStyleStep(ThemeData theme) {
      final styles = [
      {'label': 'Suits & Formal', 'icon': Icons.business},
      {'label': 'Streetwear & Cool', 'icon': Icons.checkroom},
      {'label': 'Cozy & Casual', 'icon': Icons.weekend},
      {'label': 'Leather & Edge', 'icon': Icons.motorcycle},
      {'label': 'Uniform & Tactical', 'icon': Icons.shield},
      {'label': 'Preppy & Smart', 'icon': Icons.school},
      {'label': 'Gym & Sporty', 'icon': Icons.fitness_center},
      {'label': 'Vintage & Retro', 'icon': Icons.watch},
    ];

    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 1.1,
      ),
      itemCount: styles.length,
      itemBuilder: (context, index) {
        final style = styles[index];
        final isSelected = _selectedStyle == style['label'];
        
        return GestureDetector(
          onTap: () => setState(() => _selectedStyle = style['label'] as String),
          child: AnimatedContainer(
             duration: const Duration(milliseconds: 200),
             decoration: BoxDecoration(
               color: isSelected ? theme.primaryColor.withOpacity(0.2) : Colors.white.withOpacity(0.05),
               borderRadius: BorderRadius.circular(20),
               border: Border.all(
                 color: isSelected ? theme.primaryColor : Colors.white10,
                 width: isSelected ? 2 : 1,
               ),
             ),
             child: Column(
               mainAxisAlignment: MainAxisAlignment.center,
               children: [
                 Icon(style['icon'] as IconData, size: 32, color: isSelected ? Colors.white : Colors.white54),
                 const SizedBox(height: 12),
                 Text(
                   style['label'] as String, 
                   style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      color: isSelected ? Colors.white : Colors.white70,
                   ),
                   textAlign: TextAlign.center,
                 ),
               ],
             ),
          ),
        );
      },
    );
  }

  Widget _buildSelectionChip({required String label, required bool isSelected, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? Theme.of(context).primaryColor : Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(25),
          border: Border.all(color: isSelected ? Colors.transparent : Colors.white24),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  void _handleNextStep() async {
    // Dismiss keyboard
    FocusScope.of(context).unfocus();

    // Validation
    if (_currentStep == 0 && _nameController.text.isEmpty) return;
    if (_currentStep == 1 && _selectedImage.isEmpty) return; // New Image step
    if (_currentStep == 2 && (_selectedEyes.isEmpty || _selectedHair.isEmpty)) return;
    if (_currentStep == 3 && _selectedVibe.isEmpty) return;
    if (_currentStep == 4 && _selectedStyle.isEmpty) return;

    if (_currentStep < _steps.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    } else {
      // Finish
      final name = _nameController.text.trim();
      final desc = '$_selectedVibe with $_selectedEyes eyes, $_selectedHair hair, $_selectedStyle style';
      
      // Save custom character
      final customCharacter = {
        'id': 'custom_${DateTime.now().millisecondsSinceEpoch}',
        'name': name,
        'vibe': _selectedVibe,
        'desc': desc,
        'image': _selectedImage, // Use selected image
        'color': 'pink',
        'isCustom': true,
      };
      
      await ref.read(customCharactersProvider.notifier).addCharacter(customCharacter);
      
      if (!mounted) return;
      // We pass the new persona details via URL query params or encoded string
      context.go('/chat?scenario=${Uri.encodeComponent("$name ($desc)")}');
    }
  }
}
