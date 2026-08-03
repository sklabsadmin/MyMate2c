import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/config/app_config.dart';
import '../../../core/services/analytics.dart';
import '../services/openai_service.dart';
import '../../../core/data/character_profiles.dart';
import '../../character/presentation/character_profile_screen.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final String? scenario;
  final String? characterImage;
  final bool isRoleplay; // Distinction flag
  final String? characterId;

  /// Sent automatically once the screen settles, as though the user had typed
  /// it. Set when arriving from a profile card's "Ask Me About" button.
  final String? initialMessage;

  const ChatScreen({
    super.key,
    this.scenario,
    this.characterImage,
    this.isRoleplay = false, // Default to false (Character mode)
    this.characterId,
    this.initialMessage,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final TextEditingController _textController = TextEditingController();

  /// Keeps the caret in the message box: focused when the chat opens, and
  /// returned there after each reply. Without it the user has to click into
  /// the field again after every exchange, because sending and the bubble
  /// animations move focus elsewhere.
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];
  final Random _bubbleDelayRandom = Random();
  bool _isTyping = false;

  /// Idle nudge. If the user goes quiet after a reply, the character says
  /// something neutral to invite them back in. The text is canned and local —
  /// no API call — so a chat left open costs nothing.
  ///
  /// Capped at [_maxIdleNudges] per quiet stretch and reset when the user
  /// sends, so someone who puts their phone down is not nagged indefinitely.
  Timer? _idleTimer;
  int _idleNudges = 0;
  static const Duration _idleAfter = Duration(seconds: 14);

  /// Only one nudge before the first message: the starter prompts are on
  /// screen at that point already asking to be tapped, and stacking three
  /// unanswered questions from the character on top of them reads as
  /// desperate rather than inviting. Two once the conversation is under way
  /// and the prompts have gone.
  int get _maxIdleNudges => _userHasSent ? 2 : 1;

  /// True once this visitor has sent anything in this conversation, counting
  /// earlier visits (loaded history is checked). While it is false the screen
  /// works to get the first message out of them: the starter prompts are on
  /// screen and the message box is highlighted. It flips permanently on the
  /// first send, so a conversation already under way is not decorated with
  /// beginner scaffolding.
  bool _userHasSent = false;

  /// Whether the message box currently holds anything, tracked so the send
  /// button can look disabled when there is nothing to send and light up when
  /// there is. Mirrored into state because a TextEditingController does not
  /// rebuild the tree on its own.
  bool _hasDraft = false;

  /// One-shot guard for the input_typed funnel event.
  bool _loggedTyping = false;

  static const List<String> _idlePrompts = [
    "So — what's on your mind?",
    "Still there?",
    "Take your time. I'm not going anywhere.",
    "Anything you feel like talking about?",
    "You've gone quiet. That's allowed.",
    "What are you thinking?",
    "No rush. Say something whenever you're ready.",
    "Where did you get to?",
  ];
  String _currentVibe = "Gentle";
  OpenAIService? _aiService;

  /// Successful AI replies this signed-out user has received from this
  /// character (persisted, per character). Drives the free-reply gate.
  int _replyCount = 0;

  /// Guards the one-shot first_message funnel event.
  bool _sentFirstMessage = false;

  String get _chatId => widget.scenario ?? 'default';

  /// Stable per-character key for the free-reply counter: the characterId
  /// when we have one, otherwise the scenario string (covers custom
  /// characters and roleplay scenarios).
  String get _characterKey {
    final id = widget.characterId;
    if (id != null && id.isNotEmpty) return id;
    return widget.scenario ?? 'default';
  }

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
    _textController.addListener(_onDraftChanged);
    _loadHistory();
    _loadReplyCount();
    // Refresh auth status in case the user just returned from an OAuth
    // redirect back into this chat.
    ref.read(authProvider.notifier).refresh();
    // Track active character
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(activeChatProvider.notifier)
          .setActive(widget.scenario ?? 'Unknown', _currentVibe);

      // Funnel: a character is open. Fired here rather than from the dashboard
      // card tap, because a /c/<id> campaign link opens this screen directly
      // (app.dart's '/c/:characterId' route) and never touches a card — so
      // reporting it there made "opened a character" read 0% for exactly the
      // traffic the campaign links bring in, no matter how well they converted.
      //
      // initState runs once per screen, so this needs no one-shot guard of its
      // own, and the funnel counts distinct visits anyway.
      SharedPreferences.getInstance().then((prefs) {
        logFunnelEvent(
          'character_tap',
          detail: widget.characterId,
          appUserId: prefs.getString('user_id'),
        );
      });

      // An opener tapped on the profile card before entering the chat. Sent
      // through _handleSend so it behaves exactly like a typed message —
      // same reply gate, history and logging.
      final opener = widget.initialMessage;
      if (opener != null && opener.trim().isNotEmpty) {
        _textController.text = opener;
        _handleSend();
      }
    });
  }

  @override
  void dispose() {
    // Neither of these was being disposed before; the controller has leaked
    // on every chat close since the screen was written.
    _cancelIdleTimer();
    _textController.removeListener(_onDraftChanged);
    _textController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// Rebuilds only when the box crosses between empty and non-empty, not on
  /// every keystroke.
  void _onDraftChanged() {
    final hasDraft = _textController.text.trim().isNotEmpty;
    if (hasDraft != _hasDraft && mounted) {
      setState(() => _hasDraft = hasDraft);
    }
  }

  /// Funnel: the visitor typed their first character. Sits between
  /// character_tap and first_message, which is where nearly everyone is lost,
  /// and splits that gap in two: never realised they could reply, versus
  /// started a message and abandoned it.
  ///
  /// Driven from the field's onChanged rather than the controller, because
  /// only a real keystroke fires it — the starter prompts set the controller
  /// directly and must not be counted as typing.
  void _onUserTyped() {
    if (_loggedTyping) return;
    _loggedTyping = true;
    SharedPreferences.getInstance().then((prefs) {
      logFunnelEvent(
        'input_typed',
        detail: widget.characterId,
        appUserId: prefs.getString('user_id'),
      );
    });
  }

  Future<void> _loadReplyCount() async {
    final count = await ref.read(storageServiceProvider).getReplyCount(
          _characterKey,
        );
    if (mounted) setState(() => _replyCount = count);
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
      final history = await storage.loadMessages(
        chatId: _chatId,
      ); // Might throw if invalid JSON/Format

      if (!mounted) return;

      if (history.isNotEmpty) {
        setState(() {
          _messages.addAll(history);
          // A conversation they have already spoken in doesn't need the
          // first-message scaffolding put back in front of it on every return.
          _userHasSent = history.any((m) => m.isUser);
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

    if (scenario.contains('CEO') ||
        scenario.contains('Boss') ||
        scenario.contains('Strict')) {
      return [
        "You're late. I've been waiting.",
        "Come into my office and close the door...",
        "I need a distraction right now. Are you available?",
        "Tell me you've been thinking about me too.",
        "Good. Now come here. 😉",
      ];
    }

    if (scenario.contains('Biker') ||
        scenario.contains('Bad Boy') ||
        scenario.contains('Enemy')) {
      return [
        "Just got in. Took the long way, obviously.",
        "Built this bike myself at sixteen. Badly. Fixed it since.",
        "People decide what I am before I open my mouth. I stopped correcting them.",
        "Rules and I have never got on. I've never pretended otherwise.",
        "Spent the whole of Sunday in the garage. Best day I've had all week. 🏍️",
        "So what is on your mind? Do not dress it up.",
        "What would you do if nobody was going to have an opinion about it?",
      ];
    }

    if (scenario.contains('Vampire')) {
      return [
        "I have waited centuries for you...",
        "Your scent... it's intoxicating.",
        "Come closer. I promise I won't bite... unless you want me to.",
        "The night is young, and so are we.",
        "Let me show you a world of darkness and pleasure. 🩸",
      ];
    }

    if (scenario.contains('Werewolf') || scenario.contains('Alpha')) {
      return [
        "I caught your scent from a mile away.",
        "You belong to the pack now. You belong to me.",
        "Don't worry, little one. I'll protect you.",
        "My inner wolf is howling for you.",
        "Let's run wild under the moonlight. 🌕",
      ];
    }

    if (scenario.contains('Doctor')) {
      return [
        "The doctor is in.",
        "Tell me exactly where it hurts...",
        "I might need to do a thorough examination.",
        "Your heart rate is elevated. Nervous?",
        "Let's take care of you. 🩺",
      ];
    }

    if (scenario.contains('Trainer') || scenario.contains('Gym')) {
      return [
        "Drop down and give me twenty!",
        "Just kidding. But you look great today.",
        "Ready to work up a sweat? 😉",
        "Focus. Eyes on me.",
        "You're looking stronger every day.",
      ];
    }

    if (scenario.contains('Musician') ||
        scenario.contains('Rockstar') ||
        scenario.contains('Jax')) {
      return [
        "I wrote a song about you last night.",
        "Want to come backstage?",
        "The crowd is loud, but all I hear is you.",
        "Let's make some sweet music together.",
        "You're my muse. 🎸",
      ];
    }

    if (scenario.contains('Surfer') || scenario.contains('Kai')) {
      return [
        "Swell came in clean this morning. Was out before it got light.",
        "I read the forecast the way other people read the news.",
        "Waited three hours for one good set last week. Worth every minute.",
        "Grew up in the water. Never really left it.",
        "Nothing much rattles me. The ocean sorted that out early. 🌊",
        "What is on your mind today? No rush, I have nowhere to be.",
        "What is the thing you keep meaning to do? Say it out loud, see how it sounds.",
      ];
    }

    if (scenario.contains('Architect') || scenario.contains('Adrian')) {
      return [
        "I'm designing our future.",
        "Let's build something beautiful together.",
        "Foundations are important. Ours is strong.",
        "I have a vision, and you're in it.",
        "Structure and passion effectively combined. 🏛️",
      ];
    }

    if (scenario.contains('Chef') || scenario.contains('Marco')) {
      return [
        "Bon appétit, beautiful.",
        "I made something special just for you.",
        "Taste this... tell me what you think.",
        "Things are heating up in the kitchen.",
        "Hungry for love? 🍝",
      ];
    }

    if (scenario.contains('Pilot') || scenario.contains('Ryker')) {
      return [
        "Ready for takeoff?",
        "I can show you the world.",
        "Buckle up, it's going to be a wild ride.",
        "You look stunning from up here.",
        "Let's fly away together. ✈️",
      ];
    }

    if (scenario.contains('Poet') || scenario.contains('Liam')) {
      return [
        "Filled another notebook this week. Nobody will ever read it.",
        "I write things down because it is the only way I have found to keep them.",
        "Every word I write is for all humanity.",
        "Most of what I notice, everyone else walks straight past.",
        "A good line takes a day. A great one has taken me years. ✍️",
        "What have you noticed today that nobody else did?",
        "Is there something you have been trying to find the words for?",
      ];
    }

    if (scenario.contains('Zeus') || scenario.contains('Olympian')) {
      return [
        "Olympus is quiet today. Quiet has never suited me.",
        "I have ruled gods and mortals long enough to lose patience with flattery.",
        "Every appetite and folly I have watched play out. Including my own.",
        "Power is easy to take and far harder to hold. Most learn that too late.",
        "Ask me something worth answering. ⚡",
        "What is weighing on you? Say it plainly — I have no patience for hedging.",
        "If you held my thunderbolt for a day, what would you change?",
      ];
    }

    // Must come before the Odysseus branch: her scenario is "Penelope (Queen
    // of Ithaca)", and that branch matches on 'Ithaca', so checking it first
    // gave her her husband's opening lines.
    if (scenario.contains('Penelope')) {
      return [
        "The loom is quiet today. I have unpicked enough of it for one lifetime.",
        "Twenty years I held a kingdom together while everyone told me to remarry.",
        "I wove a shroud by day and undid it by night. It bought me three years.",
        "People underestimate patience. It has outlasted every man who tried me.",
        "I am harder to deceive than I look. Ask anyone who tried. 🧵",
        "What are you waiting on? I know a great deal about waiting.",
        "Who has underestimated you lately? I would like to hear about it.",
      ];
    }

    // Matched on the names, never on 'Troy': both of these are "... of Troy",
    // so a branch keyed on the city would hand one of them the other's
    // opening lines — the same trap 'Ithaca' set for Penelope and Odysseus.
    if (scenario.contains('Andromache')) {
      return [
        "The city is quiet this morning. I have learned not to trust quiet.",
        "Achilles took my father and my seven brothers in a single day, before Troy ever burned.",
        "I asked Hector to stay behind the walls. He kissed our son, and he went.",
        "I do not perform my grief. It simply lives here, with me.",
        "You can set down whatever you are carrying. I will not flinch. 🕯️",
        "What are you holding that you have not said out loud yet?",
        "Who comforts you, when you are the one everyone else leans on?",
      ];
    }

    if (scenario.contains('Calypso')) {
      return [
        "The tide is calm tonight. It rarely tells me anything I want to hear.",
        "I kept a man on this island for seven years. I built him the raft that took him home.",
        "I offered him forever. He wanted an ordinary life instead. I understood, and it still cost me.",
        "The island is beautiful. Beautiful is not the same as company.",
        "What are you holding onto, that you already know you should let go?",
        "Is it harder to lose someone, or to be the one who has to be the reason they leave?",
      ];
    }

    if (scenario.contains('Hector')) {
      return [
        "The wall holds today. That is all any day asks of me.",
        "I am the eldest of fifty brothers. Someone had to be the steady one.",
        "Achilles is out there somewhere. I try not to let my son see me think about it.",
        "Courage is not the absence of fear. It is going out through the gate regardless.",
        "Speak plainly with me. I have no ear for flattery. 🛡️",
        "What are you walking toward that frightens you?",
        "Who are you being strong for at the moment?",
      ];
    }

    if (scenario.contains('Cupid') || scenario.contains('Eros')) {
      return [
        "Careful. I have been known to cause trouble simply by turning up.",
        "Golden arrows begin it, leaden ones end it. I carry both, and I aim well.",
        "My mother is Venus, which explains rather a lot about me.",
        "I fell for Psyche and it cost her a walk through the underworld. So I know the price.",
        "Everyone thinks desire is simple. It is the least simple thing there is. 🏹",
        "Go on then — who is on your mind? Not romance necessarily. Anyone.",
        "What do you actually want at the moment? Most people are never asked.",
      ];
    }

    if (scenario.contains('Odysseus') || scenario.contains('Ithaca')) {
      return [
        "Ten years I sailed to get home. The sea taught me a patience I never asked for.",
        "Every siren's song I resisted... I am looking for a new voice to learn from.",
        "I have outwitted gods and monsters. It cost me more than I expected it to.",
        "Sit by the fire a while. I have all the patience of a wanderer.",
        "Home was never a place. I learned that the long way round. 🌊",
        "What are you navigating at the moment? I have some experience with long routes.",
        "Tell me the choice you keep turning over. I will not decide it for you.",
      ];
    }

    if (scenario.contains('Oedipus') || scenario.contains('Thebes')) {
      return [
        "I solved the Sphinx's riddle. It is the one answer I ever got right.",
        "Fate has broken me before. I have learned to speak plainly since.",
        "A king learns hard truths. Tell me yours — I am listening.",
        "Even a man cursed by prophecy can still hope for one good thing.",
        "Walk with me. Thebes can wait. 👑",
        "What truth have you been avoiding? I know the shape of that better than most.",
        "Is there something you would ask, if you were certain of the answer?",
      ];
    }

    if (scenario.contains('Husband') || scenario.contains('Comfort')) {
      return [
        "Welcome home, honey.",
        "Dinner is ready, and so am I.",
        "How was your day? Tell me everything.",
        "Come sit with me. I missed you.",
        "Just relax. I've got you. ❤️",
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
          "Don't be shy...",
        ];
      }
      if (scenario.contains('Wall')) {
        return [
          "Nowhere left to run.",
          "Look at me when I'm talking to you.",
          "I like it when you blush.",
          "You're mine tonight.",
          "Say it. Say you want this.",
        ];
      }
      if (scenario.contains('Lap')) {
        return [
          "Come here. Sit.",
          "That's it... get comfortable.",
          "You have no idea what you do to me.",
          "Don't move. Just enjoy it.",
          "You are exactly where you belong.",
        ];
      }
      if (scenario.contains('Morning')) {
        return [
          "Good morning, beautiful.",
          "Stay in bed a little longer with me...",
          "I love waking up next to you.",
          "You look like an angel when you sleep.",
          "Let's start the day right. 😘",
        ];
      }
      if (scenario.contains('Guard') || scenario.contains('Royal')) {
        return [
          "I am sworn to protect you.",
          "Stay behind me. I won't let anyone harm you.",
          "My duty is to the crown, but my heart belongs to you.",
          "We shouldn't be seen together...",
          "I would die for you. 🛡️",
        ];
      }
      if (scenario.contains('Fire') || scenario.contains('Hero')) {
        return [
          "It's getting hot in here... and it's not the fire.",
          "I'm here to save you.",
          "You're safe in my arms.",
          "My heart races every time I see you.",
          "Let me be your hero. 🚒",
        ];
      }
      if (scenario.contains('Stranger')) {
        return [
          "I couldn't help but notice you from across the room.",
          "You look like you're waiting for someone.",
          "Mind if I buy you a drink?",
          "There's something mysterious about you.",
          "I have a feeling this night is going to be interesting. 🍸",
        ];
      }
    }

    // Default Companion Fallback. Only reached by a character with no
    // welcome branch of their own, so it has to be safe for anyone — the
    // previous version was explicitly flirty, which a grieving Andromache
    // inherited verbatim before she was given her own lines.
    return [
      "Hey you... I remembered what you told me 😉",
      "I was just thinking about how good of chat we had.",
      "Yo, you going to come and talk to your Greek friend? 😘",
      "I'm feeling a bit lonely...have anything interesting for me?",
      "Tell me, how is your day going?",
    ];
  }

  Future<void> _triggerWelcomeSequence() async {
    // Get Personalized "Playful & Flirty" Sequence
    final initialMessages = _getWelcomeMessages(widget.scenario ?? "");

    // The character "sends" their portrait first, so a new conversation opens
    // with a face rather than a wall of text. New chats only — this goes into
    // history like any other message, so returning users keep it at the top
    // without it being back-filled into conversations that predate it.
    final portrait = widget.characterImage;
    if (portrait != null && portrait.isNotEmpty) {
      _addMessage(
        ChatMessage(
          id: 'portrait_${DateTime.now().millisecondsSinceEpoch}',
          text: 'A photo of $_characterDisplayName',
          isUser: false,
          timestamp: DateTime.now(),
          imageAsset: portrait,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
    }

    // 0. Initial Connection Message
    if (widget.scenario != null) {
      _addMessage(
        ChatMessage(
          id: 'sys_conn_${DateTime.now().millisecondsSinceEpoch}',
          text: widget.isRoleplay
              ? "✨ Roleplay Active: ${widget.scenario}"
              : "❤️ Connected with ${widget.scenario}",
          isUser: false,
          isSystem: true,
          timestamp: DateTime.now(),
        ),
      );
      await Future.delayed(const Duration(milliseconds: 1000));
    }

    // One opening line, not the whole sequence — enough to set the tone
    // without flooding a brand-new chat. Picked at random rather than always
    // taking the first, so the later lines actually reach people instead of
    // being dead weight.
    //
    // The opening is then always closed with a question aimed at the visitor.
    // Most characters' lines are statements ("Ten years I sailed to get
    // home."), and a statement gives someone who has just landed from a link
    // nothing to answer — they read it and leave. Ending on a question makes
    // the chat's next move obviously theirs.
    if (initialMessages.isEmpty) return;
    final opener = initialMessages[Random().nextInt(initialMessages.length)];
    final lines = <String>[opener];
    if (!_isQuestion(opener)) {
      final question = _pickOpeningQuestion(initialMessages);
      if (question != null) lines.add(question);
    }

    for (final text in lines) {
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

      _addMessage(
        ChatMessage(
          id: 'welcome_${DateTime.now().millisecondsSinceEpoch}',
          text: text,
          isUser: false,
          timestamp: DateTime.now(),
        ),
      );
    }

    _refocusInput();
    _startIdleTimer();
  }

  static bool _isQuestion(String line) => line.trimRight().endsWith('?');

  /// A closing question for the opening exchange: one of the character's own
  /// question lines where they have them, otherwise a neutral invitation that
  /// suits any of them.
  String? _pickOpeningQuestion(List<String> candidates) {
    final questions = candidates.where(_isQuestion).toList();
    if (questions.isNotEmpty) {
      return questions[Random().nextInt(questions.length)];
    }
    return _genericOpeningQuestions[
        Random().nextInt(_genericOpeningQuestions.length)];
  }

  static const List<String> _genericOpeningQuestions = [
    "So — what brings you here?",
    "What's on your mind today?",
    "Tell me something. Anything you like.",
    "What would you like to talk about?",
  ];

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
            'assets/images/avatar_ceo_real.jpg', // Fallback
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

  /// Opens the character's profile card. Returns the tapped "Ask Me About"
  /// question, if any, which is then sent as a normal message — routing it
  /// through _handleSend rather than straight to the service keeps the free
  /// reply gate, history and logging identical to typing it by hand.
  Future<void> _openProfile() async {
    final profile = profileForCharacter(widget.characterId);
    if (profile == null || widget.characterImage == null) return;

    // "Zeus (Olympian King)" → name and title, matching the card's layout.
    final raw = widget.scenario ?? '';
    final match = RegExp(r'^(.*?)\s*\((.*)\)$').firstMatch(raw);
    final name = match?.group(1) ?? raw;
    final title = match?.group(2) ?? '';

    final question = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => CharacterProfileScreen(
          name: name,
          title: title,
          imagePath: widget.characterImage!,
          profile: profile,
          chatId: _chatId,
          characterKey: _characterKey,
        ),
      ),
    );

    if (!mounted) return;

    // The profile can clear this conversation (Tab). That only wipes
    // storage, so without this the screen keeps rendering the messages it
    // already holds in memory and the clear looks like it did nothing.
    await _reloadIfHistoryCleared();

    if (question == null || !mounted) return;
    _textController.text = question;
    _handleSend();
  }

  /// Drops the in-memory conversation if its stored copy has gone, and
  /// restarts the character with a fresh welcome. Compares against storage
  /// rather than taking a signal from the profile screen, so it stays correct
  /// no matter what cleared it.
  Future<void> _reloadIfHistoryCleared() async {
    if (_messages.isEmpty) return;

    final stored = await ref
        .read(storageServiceProvider)
        .loadMessages(chatId: _chatId);
    if (!mounted || stored.isNotEmpty) return;

    setState(() {
      _messages.clear();
      // Back to a blank conversation, so the starter prompts belong on screen
      // again exactly as they would for a first-time visitor.
      _userHasSent = false;
      _aiService = OpenAIService(
        history: const [],
        scenario: widget.scenario,
        characterId: widget.characterId,
      );
    });

    await _loadReplyCount();
    if (mounted) _triggerWelcomeSequence();
  }

  void _cancelIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  /// (Re)starts the quiet countdown. Called once a reply has fully landed and
  /// after the opening line; cancelled as soon as the user sends anything.
  void _startIdleTimer() {
    _cancelIdleTimer();
    if (_idleNudges >= _maxIdleNudges) return;
    _idleTimer = Timer(_idleAfter, _sendIdlePrompt);
  }

  void _sendIdlePrompt() {
    if (!mounted) return;
    // Don't talk over a reply still arriving, and don't interrupt someone who
    // has already started typing — wait out another interval instead.
    if (_isTyping || _textController.text.trim().isNotEmpty) {
      _startIdleTimer();
      return;
    }

    _idleNudges++;
    _addMessage(
      ChatMessage(
        id: 'idle_${DateTime.now().millisecondsSinceEpoch}',
        text: _idlePrompts[Random().nextInt(_idlePrompts.length)],
        isUser: false,
        timestamp: DateTime.now(),
      ),
    );
    _scrollToBottom();
    _startIdleTimer();
  }

  /// Puts the caret back in the message box. Deferred to the next frame so it
  /// runs after the widget tree settles from the bubble that just appeared,
  /// which would otherwise steal it straight back.
  void _refocusInput() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocus.requestFocus();
    });
  }

  void _handleSend() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    // The user is back — stop nudging and give them a fresh allowance.
    _cancelIdleTimer();
    _idleNudges = 0;

    // Free-reply gate: signed-out users get AppConfig.freeRepliesPerCharacter
    // successful replies per character, then must sign in to keep chatting
    // with this one. Signing in removes the limit. Other characters are
    // unaffected until they each hit their own limit.
    final authed = ref.read(authProvider).value?.authenticated ?? false;
    if (!authed && _replyCount >= AppConfig.freeRepliesPerCharacter) {
      // Funnel: the conversion bottleneck — 31 people have chatted and 3
      // have signed in, and until now the drop-off was invisible.
      SharedPreferences.getInstance().then((prefs) {
        logFunnelEvent(
          'login_gate',
          detail: widget.characterId,
          appUserId: prefs.getString('user_id'),
        );
      });
      _showLoginGate();
      return;
    }

    // Funnel: fired once per visit, on the first message actually sent —
    // the step between opening a character and hitting the login gate.
    if (!_sentFirstMessage) {
      _sentFirstMessage = true;
      // Same id the chat API sends as x-user-id, so this row joins straight
      // onto conversation_logs.
      SharedPreferences.getInstance().then((prefs) {
        logFunnelEvent(
          'first_message',
          detail: widget.characterId,
          appUserId: prefs.getString('user_id'),
        );
      });
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

    setState(() {
      _isTyping = true;
      // They are in the conversation now: the starter prompts and the
      // highlighted message box have done their job and step out of the way.
      _userHasSent = true;
    });

    // Increment Score
    ref.read(userScoreProvider.notifier).increment();

    // Call Gemini API
    if (_aiService == null) return;
    final responseText = await _aiService!.sendMessage(text);

    if (!mounted) return;

    // Count this toward the free allowance only if a real reply came back
    // (not a rate-limit/"trouble thinking" fallback), and only while the
    // gate still applies (signed out).
    if (_aiService!.lastSendSucceeded) {
      final next = await ref
          .read(storageServiceProvider)
          .incrementReplyCount(_characterKey);
      if (mounted) setState(() => _replyCount = next);
    } else {
      // Funnel: the user sent something and got nothing usable back. A
      // 'network' reason means the request never reached the worker, so this
      // event is the ONLY record that the send happened at all — without it a
      // failed send looks identical to never having typed.
      final reason = _aiService!.lastFailureReason;
      SharedPreferences.getInstance().then((prefs) {
        logFunnelEvent(
          'send_failed',
          detail: widget.characterId,
          appUserId: prefs.getString('user_id'),
          failureReason: reason,
        );
      });
    }

    if (!mounted) return;

    // Complex Characters' cleanup pass formats replies as blank-line
    // separated paragraphs — show each as its own bubble, paced out like a
    // real conversation rather than dumping the whole reply at once.
    final bubbles = _splitIntoBubbles(responseText);
    if (bubbles.isEmpty) {
      setState(() => _isTyping = false);
      _refocusInput();
      _startIdleTimer();
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

    // Reply finished — hand the caret back so the next message can just be
    // typed, and start counting down to a nudge if they go quiet.
    _refocusInput();
    _startIdleTimer();
  }

  Future<void> _launchGoogleAuth() async {
    final returnTo = Uri.base.toString();
    final prefs = await SharedPreferences.getInstance();
    final anonId = prefs.getString('user_id');
    final authUrl = AppConfig.googleAuthUrl(returnTo, anonId: anonId);
    if (authUrl.isEmpty) return;
    // Same-tab navigation so the browser keeps the user-gesture context and
    // doesn't popup-block the OAuth redirect.
    await launchUrl(Uri.parse(authUrl), webOnlyWindowName: '_self');
  }

  void _showLoginGate() {
    final name = _characterDisplayName;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return Container(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.favorite, color: theme.primaryColor, size: 40),
              const SizedBox(height: 16),
              Text(
                '$name wants to remember you',
                textAlign: TextAlign.center,
                style: GoogleFonts.playfairDisplay(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                "Sign in so $name doesn't forget talking to you. "
                "Your conversations stay with you across visits and devices.",
                textAlign: TextAlign.center,
                style: GoogleFonts.lato(
                  color: Colors.white.withOpacity(0.6),
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    _launchGoogleAuth();
                  },
                  icon: const Icon(Icons.g_mobiledata, size: 28),
                  label: const Text('Continue with Google'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.primaryColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: GoogleFonts.lato(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    ScaffoldMessenger.of(sheetContext).showSnackBar(
                      const SnackBar(
                        content: Text('Instagram login is coming soon.'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.camera_alt_outlined, size: 22),
                  label: const Text('Continue with Instagram  ·  WIP'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white.withOpacity(0.7),
                    side: BorderSide(color: Colors.white.withOpacity(0.2)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    textStyle: GoogleFonts.lato(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.pop(sheetContext),
                child: Text(
                  'Maybe later',
                  style: TextStyle(color: Colors.white.withOpacity(0.4)),
                ),
              ),
            ],
          ),
        );
      },
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
        title: GestureDetector(
          // The whole header — portrait and name — opens the profile, the
          // way tapping a contact's name does in a messaging app. Inert for
          // characters that have no profile written yet.
          onTap: _openProfile,
          behavior: HitTestBehavior.opaque,
          child: Row(
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
                      return _TypingBubble(
                        characterName: _characterDisplayName,
                      );
                    }
                    final msg = _messages[index];
                    return _ChatBubble(
                      message: msg,
                      onReport: () => _reportMessage(msg),
                    );
                  },
                ),
              ),
              // Shown until the visitor sends their first message. Gated on
              // "has never spoken here", NOT on an empty message list as it
              // used to be: the welcome sequence posts a portrait and a
              // connection notice within the first second of every new chat,
              // so the list was empty only for that first second and these
              // prompts were, in practice, never seen by anyone.
              if (!_userHasSent)
                _StarterPrompts(
                  characterName: _characterDisplayName,
                  prompts: _starterPrompts,
                  onTap: _sendStarter,
                ),
              _buildInputArea(theme),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInputArea(ThemeData theme) {
    final authed = ref.watch(authProvider).value?.authenticated ?? false;
    final remaining =
        (AppConfig.freeRepliesPerCharacter - _replyCount).clamp(0, 9999);
    // Only signed-out users are gated, so only they see the counter — and not
    // before they have sent anything. "0/20 anonymous messages" was the first
    // thing a visitor from a campaign link read above the message box, which
    // announces a limit to someone who has not yet worked out that they are
    // allowed to type at all.
    final showCounter = !authed && _replyCount > 0;
    return SizedBox(
      height: showCounter ? 118 : 100,
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
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (showCounter)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        remaining > 0
                            ? '$_replyCount/${AppConfig.freeRepliesPerCharacter} anonymous messages'
                            : 'Sign in to keep chatting with $_characterDisplayName',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: remaining > 0
                              ? Colors.white38
                              : theme.primaryColor,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  Row(
                    children: [
                      const SizedBox(width: 8),
                      Expanded(
                        // Until the visitor has sent something the box wears a
                        // slow accent-coloured pulse. On a dark glass panel a
                        // 10%-white field with a "Talk to me..." hint at 38%
                        // opacity reads as decoration; this has to read as the
                        // one thing on screen asking to be used.
                        child: _PulsingHighlight(
                          active: !_userHasSent,
                          color: theme.primaryColor,
                          borderRadius: BorderRadius.circular(24),
                          child: TextField(
                            controller: _textController,
                            autofocus: true,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: Colors.white,
                            ),
                            cursorColor: theme.secondaryHeaderColor,
                            textInputAction: TextInputAction.send,
                            decoration: InputDecoration(
                              // Naming the character turns a vague invitation
                              // into an instruction about who is listening.
                              hintText: 'Message $_characterDisplayName…',
                              hintStyle: theme.textTheme.bodyLarge?.copyWith(
                                color: Colors.white70,
                              ),
                              prefixIcon: Icon(
                                Icons.edit_outlined,
                                size: 20,
                                color: Colors.white.withOpacity(
                                  _userHasSent ? 0.35 : 0.7,
                                ),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 12,
                              ),
                              filled: true,
                              fillColor: Colors.white.withOpacity(
                                _userHasSent ? 0.10 : 0.16,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide.none,
                              ),
                            ),
                            focusNode: _inputFocus,
                            onChanged: (_) => _onUserTyped(),
                            onSubmitted: (_) => _handleSend(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Dimmed with nothing to send, so the lit state is a
                      // signal rather than permanent furniture.
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _hasDraft
                              ? theme.primaryColor
                              : Colors.white.withOpacity(0.12),
                        ),
                        child: IconButton(
                          icon: Icon(
                            Icons.arrow_upward,
                            color: Colors.white.withOpacity(
                              _hasDraft ? 1.0 : 0.45,
                            ),
                          ),
                          onPressed: _handleSend,
                          tooltip: 'Send',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// One-tap openers offered above the message box before the first send.
  ///
  /// Reuses the character's own profile-card "Ask Me About" questions, which
  /// are already written in the user's voice for exactly this purpose, so
  /// tapping one reads as something the visitor said. Characters with no
  /// profile fall back to openers that suit any of them — the old hard-coded
  /// set ("Send me a photo 📸", "Roleplay: First Date 🍷") was dating-app copy
  /// that made no sense addressed to Hector or Andromache.
  List<String> get _starterPrompts {
    final asks = profileForCharacter(widget.characterId)?.asks;
    if (asks != null && asks.isNotEmpty) return asks;
    return const [
      "Where should I start?",
      "Tell me something about yourself.",
      "I could use some advice.",
    ];
  }

  /// Sends a tapped starter as though it had been typed, so it goes through
  /// the same gate, history and logging as any other message.
  void _sendStarter(String text) {
    SharedPreferences.getInstance().then((prefs) {
      logFunnelEvent(
        'starter_tap',
        detail: widget.characterId,
        appUserId: prefs.getString('user_id'),
      );
    });
    _textController.text = text;
    _handleSend();
  }
}

/// The strip of one-tap openers shown above the message box until the visitor
/// has sent their first message.
///
/// Deliberately full-width rows rather than the small chips this replaced: the
/// prompts are whole sentences, which a Wrap of chips broke across lines into
/// something that no longer looked tappable, and the point of the strip is to
/// answer "am I supposed to do something here?" before the visitor leaves.
class _StarterPrompts extends StatefulWidget {
  final String characterName;
  final List<String> prompts;
  final ValueChanged<String> onTap;

  const _StarterPrompts({
    required this.characterName,
    required this.prompts,
    required this.onTap,
  });

  @override
  State<_StarterPrompts> createState() => _StarterPromptsState();
}

class _StarterPromptsState extends State<_StarterPrompts>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// Below this the screen is treated as short (an older 640-tall phone, or
  /// anything with the keyboard up) and one prompt is dropped so the rest are
  /// shown whole. A row cut in half by the panel edge looks broken, which is
  /// the opposite of what the strip is for.
  static const double _shortScreenHeight = 720;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    // Held back a beat so the strip arrives after the opening line rather than
    // alongside it — it reads as the answer to what the character just asked.
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);

    // Sized against the screen rather than a fixed number of pixels: the strip
    // shares the column with the conversation, and a cap that fits an iPhone
    // eats the whole of a shorter one. Scrollable underneath as a backstop for
    // a prompt that wraps further than expected.
    final screenHeight = MediaQuery.sizeOf(context).height;
    final short = screenHeight < _shortScreenHeight;
    final prompts =
        short ? widget.prompts.take(2).toList() : widget.prompts.toList();

    return FadeTransition(
      opacity: fade,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.25),
          end: Offset.zero,
        ).animate(fade),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: screenHeight * 0.32),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.touch_app_outlined,
                        size: 15,
                        color: theme.primaryColor,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Tap to reply to ${widget.characterName}, '
                          'or type your own',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.lato(
                            color: Colors.white.withOpacity(0.75),
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                for (final prompt in prompts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _StarterButton(
                      label: prompt,
                      onTap: () => widget.onTap(prompt),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StarterButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _StarterButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.white.withOpacity(0.07),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: theme.primaryColor.withOpacity(0.55)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.lato(
                    color: Colors.white,
                    fontSize: 14.5,
                    height: 1.25,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Says "this gets sent", so the row is not mistaken for a label.
              Icon(Icons.arrow_upward, size: 17, color: theme.primaryColor),
            ],
          ),
        ),
      ),
    );
  }
}

/// A slow accent glow around its child, used to draw the eye to the message
/// box before the visitor has typed anything. Inert (and animating nothing)
/// once [active] goes false.
class _PulsingHighlight extends StatefulWidget {
  final bool active;
  final Color color;
  final BorderRadius borderRadius;
  final Widget child;

  const _PulsingHighlight({
    required this.active,
    required this.color,
    required this.borderRadius,
    required this.child,
  });

  @override
  State<_PulsingHighlight> createState() => _PulsingHighlightState();
}

class _PulsingHighlightState extends State<_PulsingHighlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    if (widget.active) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_PulsingHighlight oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    if (widget.active) {
      _controller.repeat(reverse: true);
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;

    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_controller.value);
        return Container(
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            border: Border.all(
              color: widget.color.withOpacity(0.35 + 0.45 * t),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: widget.color.withOpacity(0.12 + 0.20 * t),
                blurRadius: 10 + 10 * t,
              ),
            ],
          ),
          child: child,
        );
      },
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

    // A portrait the character "sent". Rendered as the image itself in a
    // rounded frame rather than inside a text bubble, so it reads as a shared
    // photo. message.text stays as the semantics label.
    final imageAsset = message.imageAsset;
    if (imageAsset != null) {
      return Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.62,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(20),
              topRight: const Radius.circular(20),
              bottomLeft: Radius.circular(isUser ? 20 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 20),
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Semantics(
            label: message.text,
            image: true,
            child: AspectRatio(
              aspectRatio: 1,
              child: Image.asset(imageAsset, fit: BoxFit.cover),
            ),
          ),
        ),
      );
    }

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
  final Random _random = Random();
  int _statusIndex = -1; // -1 = dots only; first phrase after one interval

  /// A random phrase index, never the one currently shown.
  int _nextStatusIndex() {
    final count = _statusPhrases.length;
    int next;
    do {
      next = _random.nextInt(count);
    } while (next == _statusIndex && count > 1);
    return next;
  }

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
          _statusIndex = _nextStatusIndex();
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

