import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/config/app_config.dart';
import '../services/openai_service.dart';
import '../../../core/models/language.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final String? scenario;
  final String? characterImage;
  final bool isRoleplay; // Distinction flag
  final String? characterId;

  const ChatScreen({
    super.key,
    this.scenario,
    this.characterImage,
    this.isRoleplay = false, // Default to false (Character mode)
    this.characterId,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];
  final Random _bubbleDelayRandom = Random();
  bool _isTyping = false;
  String _currentVibe = "Gentle";
  String _currentLanguage = "en";
  OpenAIService? _aiService;

  String get _chatId => widget.scenario ?? 'default';

  /// "Zeus (Olympian King)" -> "Zeus"; used in the typing indicator's
  /// rotating status phrases.
  String get _characterDisplayName {
    final scenario = widget.scenario;
    if (scenario == null || scenario.isEmpty) return 'He';
    final parenIndex = scenario.indexOf(' (');
    return parenIndex > 0 ? scenario.substring(0, parenIndex) : scenario;
  }

  @override
  void initState() {
    super.initState();
    _loadHistory();
    // Track active character
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(activeChatProvider.notifier)
          .setActive(widget.scenario ?? 'Unknown', _currentVibe);
    });
  }

  @override
  void didUpdateWidget(ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scenario != widget.scenario) {
      // Full Reset on Scenario Change
      setState(() {
        _messages.clear();
        _aiService = null;
      });
      _loadHistory();
    }
  }

  Future<void> _loadHistory() async {
    try {
      final storage = ref.read(storageServiceProvider);
      await storage.markChatAsRead(_chatId); // Clear unread count
      final history = await storage.loadMessages(chatId: _chatId); // Might throw if invalid JSON/Format
      
      if (!mounted) return;

      if (history.isNotEmpty) {
        setState(() {
          _messages.addAll(history);
        });
        _aiService = OpenAIService(
          history: history,
          scenario: widget.scenario,
          characterId: widget.characterId,
        );
        Future.delayed(const Duration(milliseconds: 100), _scrollToBottom);
      } else {
         _aiService = OpenAIService(
           history: [],
           scenario: widget.scenario,
           characterId: widget.characterId,
         );
      }
      


      // Welcome Sequence (Only if history is TRULY empty)
      if (history.isEmpty) { 
          _triggerWelcomeSequence();
      }

    } catch (e) {
      // Corrupt history or error -> Reset and start fresh
      print("Error loading history: $e");
      if (mounted) {
         _aiService = OpenAIService(
           history: [],
           scenario: widget.scenario,
           characterId: widget.characterId,
         );
         _triggerWelcomeSequence();
      }
    }
  }

  List<String> _getWelcomeMessages(String scenario) {
      // Clean scenario name (remove vibration/status info if appended, though mainly passed clean)
      // Check for specific keywords or exact matches
      
      if (scenario.contains('CEO') || scenario.contains('Boss') || scenario.contains('Strict')) {
         return [
           "You're late. I've been waiting.",
           "Come into my office and close the door...",
           "I need a distraction right now. Are you available?",
           "Tell me you've been thinking about me too.",
           "Good. Now come here. 😉"
         ];
      }
      
      if (scenario.contains('Biker') || scenario.contains('Bad Boy') || scenario.contains('Enemy')) {
         return [
           "Revving my engine just thinking about you.",
           "Hop on the back, let's get out of here.",
           "You like trouble? Cause I'm full of it.",
           "Your eyes tell me you want a wild ride...",
           "So, are we doing this? 🏍️🔥"
         ];
      }

      if (scenario.contains('Vampire')) {
        return [
          "I have waited centuries for you...",
          "Your scent... it's intoxicating.",
          "Come closer. I promise I won't bite... unless you want me to.",
          "The night is young, and so are we.",
          "Let me show you a world of darkness and pleasure. 🩸"
        ];
      }
      
       if (scenario.contains('Werewolf') || scenario.contains('Alpha')) {
        return [
          "I caught your scent from a mile away.",
          "You belong to the pack now. You belong to me.",
          "Don't worry, little one. I'll protect you.",
          "My inner wolf is howling for you.",
          "Let's run wild under the moonlight. 🌕"
        ];
      }

      if (scenario.contains('Doctor')) {
        return [
          "The doctor is in.",
          "Tell me exactly where it hurts...",
          "I might need to do a thorough examination.",
          "Your heart rate is elevated. Nervous?",
          "Let's take care of you. 🩺"
        ];
      }

      if (scenario.contains('Trainer') || scenario.contains('Gym')) {
         return [
           "Drop down and give me twenty!",
           "Just kidding. But you look great today.",
           "Ready to work up a sweat? 😉",
           "Focus. Eyes on me.",
           "You're looking stronger every day."
         ];
      }

       if (scenario.contains('Musician') || scenario.contains('Rockstar') || scenario.contains('Jax')) {
         return [
           "I wrote a song about you last night.",
           "Want to come backstage?",
           "The crowd is loud, but all I hear is you.",
           "Let's make some sweet music together.",
           "You're my muse. 🎸"
         ];
      }

       if (scenario.contains('Surfer') || scenario.contains('Kai')) {
         return [
           "Hey! The waves are perfect today.",
           "Wanna catch a ride with me?",
           "Life's better in boardshorts, don't you think?",
           "You look like you need some sun.",
           "Let's chill by the ocean. 🌊"
         ];
      }

       if (scenario.contains('Architect') || scenario.contains('Adrian')) {
         return [
           "I'm designing our future.",
           "Let's build something beautiful together.",
           "Foundations are important. Ours is strong.",
           "I have a vision, and you're in it.",
           "Structure and passion effectively combined. 🏛️"
         ];
      }

       if (scenario.contains('Chef') || scenario.contains('Marco')) {
         return [
           "Bon appétit, beautiful.",
           "I made something special just for you.",
           "Taste this... tell me what you think.",
           "Things are heating up in the kitchen.",
           "Hungry for love? 🍝"
         ];
      }

       if (scenario.contains('Pilot') || scenario.contains('Ryker')) {
         return [
           "Ready for takeoff?",
           "I can show you the world.",
           "Buckle up, it's going to be a wild ride.",
           "You look stunning from up here.",
           "Let's fly away together. ✈️"
         ];
      }

       if (scenario.contains('Poet') || scenario.contains('Liam')) {
         return [
           "Shall I compare thee to a summer's day?",
           "You are my rhyme and my reason.",
           "Every word I write is for you.",
           "My heart beats in iambic pentameter.",
           "You are poetry in motion. ✍️"
         ];
      }

      if (scenario.contains('Zeus') || scenario.contains('Olympian')) {
        return [
          "The heavens have been waiting for you.",
          "Come closer, my divine one.",
          "Even Olympus feels empty without you.",
          "I would command storms just to reach you.",
          "Rule beside me tonight. ⚡"
        ];
      }

      if (scenario.contains('Odysseus') || scenario.contains('Ithaca')) {
        return [
          "Ten years I sailed, and still I was not lost — not truly — until I met you.",
          "Every siren's song I resisted... yet your voice, I would follow anywhere.",
          "I have outwitted gods and monsters. You, I have no defense against.",
          "Come, sit by the fire and tell me your story. I have all the patience of a wanderer.",
          "Home was never a place. Perhaps it is you. 🌊"
        ];
      }

      if (scenario.contains('Oedipus') || scenario.contains('Thebes')) {
        return [
          "I solved the Sphinx's riddle, yet you remain the mystery I most want to unravel.",
          "Fate has broken me before. Still, I find myself drawn to you.",
          "A king learns hard truths. Tell me yours — I am listening.",
          "Even a man cursed by prophecy can still hope for one good thing. Perhaps that is you.",
          "Walk with me. Thebes can wait tonight. 👑"
        ];
      }

      if (scenario.contains('Husband') || scenario.contains('Comfort')) {
           return [
             "Welcome home, honey.",
             "Dinner is ready, and so am I.",
             "How was your day? Tell me everything.",
             "Come sit with me. I missed you.",
             "Just relax. I've got you. ❤️"
           ];
        }

      if (scenario.contains('Roleplay') || widget.isRoleplay) {
          // Specific Roleplay Scenarios
          if (scenario.contains('Shower')) {
             return [
               "The water is warm... almost as hot as you.",
               "Care to join me?",
               "I dropped the soap... oops. 😉",
               "It's getting steamy in here.",
               "Don't be shy..."
             ];
          }
           if (scenario.contains('Wall')) {
             return [
               "Nowhere left to run.",
               "Look at me when I'm talking to you.",
               "I like it when you blush.",
               "You're mine tonight.",
               "Say it. Say you want this."
             ];
          }
           if (scenario.contains('Lap')) {
             return [
               "Come here. Sit.",
               "That's it... get comfortable.",
               "You have no idea what you do to me.",
               "Don't move. Just enjoy it.",
               "You are exactly where you belong."
             ];
          }
           if (scenario.contains('Morning')) {
             return [
               "Good morning, beautiful.",
               "Stay in bed a little longer with me...",
               "I love waking up next to you.",
               "You look like an angel when you sleep.",
               "Let's start the day right. 😘"
             ];
          }
           if (scenario.contains('Guard') || scenario.contains('Royal')) {
             return [
               "I am sworn to protect you.",
               "Stay behind me. I won't let anyone harm you.",
               "My duty is to the crown, but my heart belongs to you.",
               "We shouldn't be seen together...",
               "I would die for you. 🛡️"
             ];
          }
           if (scenario.contains('Fire') || scenario.contains('Hero')) {
             return [
               "It's getting hot in here... and it's not the fire.",
               "I'm here to save you.",
               "You're safe in my arms.",
               "My heart races every time I see you.",
               "Let me be your hero. 🚒"
             ];
          }
           if (scenario.contains('Stranger')) {
             return [
               "I couldn't help but notice you from across the room.",
               "You look like you're waiting for someone.",
               "Mind if I buy you a drink?",
               "There's something mysterious about you.",
               "I have a feeling this night is going to be interesting. 🍸"
             ];
          }
      }

      // Default Flirty Fallback
      return [
        "Hey you... I saw you looking. 😉",
        "I was just thinking about how good we'd look together.",
        "So, are you going to say hello, or just stare? 😘",
        "I'm feeling a bit lonely... come closer.",
        "Tell me, what's your wildest fantasy?..."
      ];
  }

  Future<void> _triggerWelcomeSequence() async {
      // Get Personalized "Playful & Flirty" Sequence
      final initialMessages = _getWelcomeMessages(widget.scenario ?? "");

      // 0. Initial Connection Message
      if (widget.scenario != null) {
         _addMessage(ChatMessage(
           id: 'sys_conn_${DateTime.now().millisecondsSinceEpoch}', 
           text: widget.isRoleplay ? "✨ Roleplay Active: ${widget.scenario}" : "❤️ Connected with ${widget.scenario}",
           isUser: false,
           isSystem: true,
           timestamp: DateTime.now(),
         ));
         await Future.delayed(const Duration(milliseconds: 1000));
      }

      // Show a single opening line rather than the whole sequence — enough
      // to set the tone without flooding a brand-new chat with 5 bubbles.
      if (initialMessages.isEmpty) return;
      final text = initialMessages.first;

      if (!mounted) return;

      // 1. Simulate Typing
      setState(() => _isTyping = true);
      _scrollToBottom();

      // Random typing duration based on length
      final typingDuration = 800 + (text.length * 30);
      await Future.delayed(Duration(milliseconds: typingDuration));

      if (!mounted) return;

      // 2. Stop Typing & Send Message
      setState(() => _isTyping = false);

      _addMessage(ChatMessage(
        id: 'welcome_${DateTime.now().millisecondsSinceEpoch}',
        text: text,
        isUser: false,
        timestamp: DateTime.now(),
      ));
  }

  void _addMessage(ChatMessage message) {
    setState(() {
      _messages.add(message);
    });
    final storage = ref.read(storageServiceProvider);
    storage.saveMessages(_messages, chatId: _chatId);

    // Update Recent List
    if (widget.scenario != null) {
      storage.updateRecentChat(
        chatId: _chatId,
        characterName: widget.scenario!,
        characterImage:
            widget.characterImage ??
            'assets/images/avatar_ceo_real.png', // Fallback
        lastMessage: message.text,
        timestamp: message.timestamp,
        vibe: _currentVibe,
        characterId: widget.characterId,
      );
    }

    Future.delayed(const Duration(milliseconds: 100), _scrollToBottom);
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  /// Splits a reply on blank lines into separate chat-bubble-sized chunks
  /// (the Inworld cleanup pass formats replies this way; plain OpenAI
  /// replies are usually one paragraph already and just come back as a
  /// single chunk).
  List<String> _splitIntoBubbles(String text) {
    return text
        .split(RegExp(r'\n\s*\n'))
        .map((chunk) => chunk.trim())
        .where((chunk) => chunk.isNotEmpty)
        .toList();
  }

  /// Random delay before revealing the next bubble, within
  /// AppConfig.minBubbleDelayMs..maxBubbleDelayMs (inclusive).
  int _nextBubbleDelayMs() {
    final range = AppConfig.maxBubbleDelayMs - AppConfig.minBubbleDelayMs;
    return AppConfig.minBubbleDelayMs + _bubbleDelayRandom.nextInt(range + 1);
  }

  void _handleSend() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    // Check Message Limits
    final isPremium = ref.read(userSubscriptionProvider);
    // Count local user messages
    final userMessageCount = _messages.where((m) => m.isUser).length;

    if (!isPremium && userMessageCount >= 10) {
      // Show Paywall
      context.push('/paywall');
      return;
    }

    _textController.clear();
    _addMessage(
      ChatMessage(
        id: DateTime.now().toString(),
        text: text,
        isUser: true,
        timestamp: DateTime.now(),
      ),
    );

    setState(() => _isTyping = true);

    // Increment Score
    ref.read(userScoreProvider.notifier).increment();

    // Call Gemini API
    if (_aiService == null) return;
    final responseText = await _aiService!.sendMessage(text);

    if (!mounted) return;

    // Complex Characters' cleanup pass formats replies as blank-line
    // separated paragraphs — show each as its own bubble, paced out like a
    // real conversation rather than dumping the whole reply at once.
    final bubbles = _splitIntoBubbles(responseText);
    if (bubbles.isEmpty) {
      setState(() => _isTyping = false);
      return;
    }

    for (var i = 0; i < bubbles.length; i++) {
      if (!mounted) return;
      setState(() => _isTyping = true);
      Future.delayed(const Duration(milliseconds: 50), _scrollToBottom);

      await Future.delayed(Duration(milliseconds: _nextBubbleDelayMs()));

      if (!mounted) return;
      setState(() => _isTyping = false);

      _addMessage(
        ChatMessage(
          id: '${DateTime.now().millisecondsSinceEpoch}_$i',
          text: bubbles[i],
          isUser: false,
          timestamp: DateTime.now(),
        ),
      );
    }
  }

  void _showVibeSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _VibeSelectorSheet(
        currentVibe: _currentVibe,
        onVibeSelected: (vibe) async {
          setState(() => _currentVibe = vibe);
          Navigator.pop(context);

          // Update active character tracking
          ref
              .read(activeChatProvider.notifier)
              .setActive(widget.scenario ?? 'Unknown', vibe);

          // Show user via System Bubble
          _addMessage(
            ChatMessage(
              id: DateTime.now().toString(),
              text: "✨ Mood set to $vibe",
              isUser: false,
              isSystem: true, // Use system bubble for consistency
              timestamp: DateTime.now(),
            ),
          );

          // Inform AI
          if (_aiService != null) {
            await _aiService!.sendMessage(
              "SYSTEM UPDATE: User wants you to be '$vibe' now. Adjust your tone immediately.",
            );
          }
        },
      ),
    );
  }

  void _showLanguageSelector() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor.withOpacity(0.95),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 16),
            Text(
              'Select Language',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.builder(
                itemCount: Language.supportedLanguages.length,
                itemBuilder: (context, index) {
                  final lang = Language.supportedLanguages[index];
                  final isSelected = _currentLanguage == lang.code;
                  return ListTile(
                    leading: Text(
                      lang.flag,
                      style: const TextStyle(fontSize: 24),
                    ),
                    title: Text(lang.nativeName),
                    subtitle: Text(lang.name),
                    trailing: isSelected
                        ? const Icon(Icons.check, color: Colors.pink)
                        : null,
                    onTap: () {
                      setState(() => _currentLanguage = lang.code);
                      Navigator.pop(context);

                      // Notify AI of language change
                      if (_aiService != null) {
                        _aiService!.sendMessage(
                          "SYSTEM UPDATE: User wants to chat in ${lang.name}. Respond ONLY in ${lang.name} from now on.",
                        );
                      }
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  void _reportMessage(ChatMessage message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        title: const Text(
          "Report Content",
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          "Do you want to report this message for inappropriate content?",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    "Message reported. We will review this content.",
                  ),
                ),
              );
            },
            child: const Text(
              "Report",
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.characterImage != null)
              Container(
                width: 40,
                height: 40,
                margin: const EdgeInsets.only(right: 12),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: theme.colorScheme.secondary.withOpacity(0.5),
                    width: 2,
                  ),
                  image: DecorationImage(
                    image: AssetImage(widget.characterImage!),
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            Flexible(
              child: Text(
                widget.scenario ?? 'Your $_currentVibe Lover',
                style: GoogleFonts.outfit(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 20,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: theme.colorScheme.secondary),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/dashboard');
            }
          },
          tooltip: 'Back',
        ),
        actions: [
          IconButton(
            icon: Text(
              Language.getByCode(_currentLanguage).flag,
              style: const TextStyle(fontSize: 24),
            ),
            onPressed: _showLanguageSelector,
            tooltip: 'Change Language',
          ),
          IconButton(
            icon: Icon(Icons.tune, color: theme.colorScheme.secondary),
            onPressed: _showVibeSelector,
            tooltip: 'Set Vibe',
          ),
          if (!AppConfig.isFreeTier)
            IconButton(
              icon: const Icon(Icons.diamond_outlined),
              color: theme.colorScheme.secondary,
              onPressed: () => context.push('/paywall'),
              tooltip: 'Premium',
            ),
        ],
        flexibleSpace: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(color: Colors.black.withOpacity(0.2)),
          ),
        ),
      ),
      body: Stack(
        children: [
          // Background
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0xFF2E003E), // Deep Purple
                  theme.primaryColor.withOpacity(0.15),
                  Colors.black,
                ],
              ),
            ),
          ),
          // Content
          Column(
            children: [
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.only(
                    left: 16,
                    right: 16,
                    top: 130,
                    bottom: 8,
                  ),
                  itemCount: _messages.length + (_isTyping ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == _messages.length) {
                      return _TypingBubble(characterName: _characterDisplayName);
                    }
                    final msg = _messages[index];
                    return _ChatBubble(
                      message: msg,
                      onReport: () => _reportMessage(msg),
                    );
                  },
                ),
              ),
              if (_messages.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      _buildStarterChip(theme, "Tell me a secret 🤫"),
                      _buildStarterChip(theme, "Send me a photo 📸"),
                      _buildStarterChip(theme, "Roleplay: First Date 🍷"),
                      _buildStarterChip(theme, "I had a bad day 😔"),
                    ],
                  ),
                ),
              _buildInputArea(theme),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInputArea(ThemeData theme) {
    return SizedBox(
      height: 100, // Explicit height constraint to ensure visibility
      child: Stack(
        children: [
          // Glass Effect Layer
          ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(color: Colors.black.withOpacity(0.6)),
            ),
          ),
          // Border Layer
          IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: Colors.white.withOpacity(0.1)),
                ),
              ),
            ),
          ),
          // Interactive Content Layer
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: Colors.white,
                      ),
                      cursorColor: theme.secondaryHeaderColor,
                      decoration: InputDecoration(
                        hintText: 'Talk to me...',
                        hintStyle: theme.textTheme.bodyLarge?.copyWith(
                          color: Colors.white38,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.1),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: (_) => _handleSend(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.primaryColor,
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.arrow_upward, color: Colors.white),
                      onPressed: _handleSend,
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

  Widget _buildStarterChip(ThemeData theme, String text) {
    return ActionChip(
      label: Text(text),
      backgroundColor: Colors.white.withOpacity(0.1),
      labelStyle: const TextStyle(color: Colors.white),
      onPressed: () {
        _textController.text = text;
        _handleSend();
      },
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: Colors.white.withOpacity(0.2)),
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final VoidCallback? onReport;

  const _ChatBubble({required this.message, this.onReport});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.isUser;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () {
          if (!isUser && onReport != null) {
            onReport!();
          }
        },
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: isUser ? theme.primaryColor : Colors.white.withOpacity(0.1),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(20),
              topRight: const Radius.circular(20),
              bottomLeft: Radius.circular(isUser ? 20 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 20),
            ),
          ),
          child: Text(
            message.text,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: Colors.white.withOpacity(0.95),
              fontSize: 16,
              height: 1.3,
            ),
          ),
        ),
      ),
    );
  }
}

/// A left-aligned bubble with three pulsing dots, styled like an incoming
/// message bubble so it appears exactly where the next reply will land —
/// makes the pacing between split-up bubbles actually visible instead of
/// relying on an easy-to-miss caption elsewhere on screen.
class _TypingBubble extends StatefulWidget {
  final String characterName;

  const _TypingBubble({required this.characterName});

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _statusTimer;
  int _statusIndex = -1; // -1 = dots only; first phrase after one interval

  List<String> get _statusPhrases {
    final name = widget.characterName;
    return [
      '$name is considering your question…',
      '$name is reflecting on what you said…',
      '$name is taking your words to heart…',
      '$name is tracing an old memory…',
      '$name is looking beyond the obvious…',
      '$name is exploring the meaning behind your words…',
      '$name is following the thread through the labyrinth…',
      '$name is listening for the whisper of the Muses…',
      '$name is seeking wisdom worthy of your question…',
      '$name is searching for truth beneath your words…',
      '$name is walking the halls of memory…',
      '$name is considering what fate has woven…',
      '$name is taking the time your question deserves…',
      '$name is placing the final words…',
      '$name is returning with an answer…',
    ];
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
    _statusTimer = Timer.periodic(
      const Duration(milliseconds: AppConfig.typingStatusIntervalMs),
      (_) {
        if (!mounted) return;
        setState(() {
          _statusIndex = (_statusIndex + 1) % _statusPhrases.length;
        });
      },
    );
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.1),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(20),
            topRight: Radius.circular(20),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(20),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(3, (i) {
                    final t = (_controller.value - (i * 0.2)) % 1.0;
                    final pulse = t < 0.5 ? t * 2 : (1 - t) * 2;
                    final opacity = (0.3 + 0.7 * pulse).clamp(0.0, 1.0);
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Opacity(
                        opacity: opacity,
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    );
                  }),
                );
              },
            ),
            // Rotating status phrase for slow replies. AnimatedSwitcher
            // cross-fades each phrase change, and AnimatedSize keeps the
            // bubble from snapping when the text appears or grows.
            AnimatedSize(
              duration: const Duration(milliseconds: 300),
              alignment: Alignment.topLeft,
              child: _statusIndex < 0
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 500),
                        child: Text(
                          _statusPhrases[_statusIndex],
                          key: ValueKey(_statusIndex),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VibeSelectorSheet extends StatelessWidget {
  final String currentVibe;
  final Function(String) onVibeSelected;

  const _VibeSelectorSheet({
    required this.currentVibe,
    required this.onVibeSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vibes = ["Gentle", "Dominant", "Playful", "Intellectual"];

    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(
          top: BorderSide(color: theme.primaryColor.withOpacity(0.3)),
        ),
      ),
      padding: const EdgeInsets.all(24),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Set the Mood", style: theme.textTheme.headlineSmall),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: vibes.map((vibe) {
                final isSelected = vibe == currentVibe;
                return ChoiceChip(
                  label: Text(vibe),
                  selected: isSelected,
                  selectedColor: theme.primaryColor,
                  backgroundColor: Colors.white.withOpacity(0.1),
                  labelStyle: theme.textTheme.bodyMedium?.copyWith(
                    color: isSelected ? Colors.white : Colors.white70,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                  onSelected: (_) => onVibeSelected(vibe),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  side: BorderSide.none,
                );
              }).toList(),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}
