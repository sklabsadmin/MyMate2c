import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/foundation.dart' show listEquals;
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

  /// Abandons the welcome sequence when the visitor speaks first.
  ///
  /// The sequence is a chain of awaited delays, so it is still pending while
  /// the starter prompts are on screen inviting a tap. Without this, a tap a
  /// second into the chat posts the visitor's message and then the character's
  /// scripted greeting lands *after* it, and the sequence's own
  /// `_isTyping = false` clears the indicator while the real reply is still
  /// generating. Checked after every await in [_triggerWelcomeSequence].
  bool _welcomeAbandoned = false;

  /// Which run of the welcome sequence is the current one.
  ///
  /// [_welcomeAbandoned] alone cannot survive a restart: starting a fresh
  /// conversation sets it true to stop the running script and
  /// [_triggerWelcomeSequence] immediately sets it false again, at which point
  /// the *old* loop — still parked on a delay — wakes up, sees a clear flag
  /// and carries on posting into the new conversation alongside the new one.
  /// Each run captures this counter and stops as soon as it is no longer the
  /// latest.
  int _welcomeRun = 0;

  /// Which pause point's quick replies are on offer, as an index into the
  /// character's [_quickRepliesFor] list.
  ///
  /// Driven two different ways, because the conversation has two phases. While
  /// the scripted opening plays it tracks the turn that just landed, so the
  /// questions are always the ones that follow what she has actually said.
  /// After the script it advances one step per completed exchange, walking the
  /// rest of the document's pause points in order.
  int _quickReplyIndex = 0;

  /// Ceilings on the welcome sequence's simulated typing, in milliseconds.
  static const int _openerTypingCapMs = 2200;
  static const int _followUpTypingCapMs = 1200;

  /// How long a beat of a scripted opening takes, per word of that beat.
  ///
  /// This is the main pacing dial: raise it to slow the whole script down,
  /// lower it to speed it up. A flat interval was the first attempt and it was
  /// wrong — "Those make better songs." and a thirty-word sentence about the
  /// sea got the same one second each, so the short beats felt spat out and
  /// the long ones were gone before they could be read. Time per word keeps a
  /// short line snappy and gives a long one room, which is also just how a
  /// person types.
  ///
  /// 260ms/word is roughly half of unhurried reading speed: fast enough to
  /// feel live, slow enough to follow.
  static const int _scriptMsPerWord = 260;

  /// Fixed cost on every beat, for the pause between one line and the next
  /// that has nothing to do with how long either is.
  static const int _scriptBeatBaseMs = 400;

  /// Floor and ceiling on a beat. The floor stops a two-word line snapping past
  /// unread; the ceiling stops the single longest sentence stalling the script.
  static const int _scriptBeatMinMs = 900;
  static const int _scriptBeatMaxMs = 4500;

  /// Share of each beat spent showing the typing indicator before the message
  /// lands, bounded so it is always perceptible but never the whole beat.
  static const int _scriptTypingMinMs = 300;
  static const int _scriptTypingMaxMs = 1400;

  /// Longest a scripted turn may hold before the next one starts.
  ///
  /// The pause at a turn boundary is written into the script itself — each
  /// segment carries its own `pauseMs` — rather than picked from a couple of
  /// constants here, because the source document specifies one per turn. This
  /// is only a backstop against a typo turning a 3s breath into a dead screen.
  static const int _scriptTurnPauseMaxMs = 8000;

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
      _startScreenPing();

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
    _screenPingTimer?.cancel();
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

  /// Reports a screen_ping funnel event from the moment a character is opened
  /// until 30s, stopping the instant there is any sign of engagement (see
  /// _stopScreenPing).
  ///
  /// Two cadences, because resolution and cost matter in opposite places. The
  /// first 10 seconds decide almost everything — whether someone bounced on
  /// sight or actually looked — so that window ticks every 500ms and can tell
  /// 2s apart from 5s. After that the only question left is roughly how long
  /// they lingered, which 3s answers just as well.
  ///
  /// Cost is why it is not 500ms throughout: every tick is a D1 row, and per
  /// the figures below most visits that open a character never engage, so they
  /// pay the full run. A flat 500ms is 60 rows a visit and around 1,600 such
  /// visits exhausts D1's 100k daily writes — during a boost, which is exactly
  /// when the data matters. Those writes share a database with
  /// conversation_logs, so running the quota dry degrades chat itself. Splitting
  /// the cadence costs 26 rows instead and gives up nothing in the window that
  /// actually answers the question.
  ///
  /// The gap the funnel could not see: character_tap fires and, most of the
  /// time, nothing else ever does — for Facebook traffic specifically, 86% of
  /// arrivals open a character and 0% ever type or tap anything. leave's
  /// dwell time cannot isolate that: it measures the whole page visit, not
  /// time on this screen, so someone who browsed the dashboard for 20s before
  /// tapping a character looks identical to someone who tapped immediately.
  /// Counting ticks on THIS visit answers the actual question — did the
  /// people who never engaged leave in the first 5 seconds, or sit here for
  /// 40 reading before giving up — which points at two entirely different
  /// fixes (broken/confusing screen vs. uncompelling content).
  ///
  /// No explicit duration is sent; each tick's own timestamp is enough for
  /// the server to derive elapsed time by counting rows for the visit, the
  /// same technique the admin funnel query already uses for other events.
  Timer? _screenPingTimer;
  int _screenPingTicks = 0;
  /// Mirrored by the SCREEN_PING_* constants in backend/src/worker.js, which
  /// turn a visit's tick count back into elapsed seconds for the admin dwell
  /// buckets. Because the cadence changes partway through, that conversion is
  /// no longer a single multiply — tick 22 is 16s, not 11s — so the two sides
  /// have to agree on all four numbers, not just the interval. Change one
  /// without the other and every dwell figure shifts, silently and plausibly.
  static const Duration _screenPingPhase1Interval = Duration(milliseconds: 500);
  static const Duration _screenPingPhase2Interval = Duration(seconds: 3);
  static const int _screenPingPhase1Ticks = 20; // 20 x 500ms = first 10s
  static const int _maxScreenPingTicks = 26; // + 6 x 3s = 28s, inside the 30s cap

  void _startScreenPing() {
    _screenPingTimer =
        Timer.periodic(_screenPingPhase1Interval, _onScreenPingTick);
  }

  void _onScreenPingTick(Timer _) {
    _screenPingTicks++;
    if (_screenPingTicks > _maxScreenPingTicks) {
      _stopScreenPing();
      return;
    }
    SharedPreferences.getInstance().then((prefs) {
      logFunnelEvent(
        'screen_ping',
        detail: widget.characterId,
        appUserId: prefs.getString('user_id'),
      );
    });
    // Drop to the slow cadence once the decisive first 10s are recorded. The
    // timer is replaced rather than left running and skipped, so the device
    // stops waking six times as often as it needs to.
    if (_screenPingTicks == _screenPingPhase1Ticks) {
      _screenPingTimer?.cancel();
      _screenPingTimer =
          Timer.periodic(_screenPingPhase2Interval, _onScreenPingTick);
    }
  }

  /// Called the instant there is any real sign of engagement (typing,
  /// tapping a starter, sending) — see call sites. Once we know they engaged,
  /// further pings would just be noise: they exist solely to measure how long
  /// the *never engaged* population lingered before giving up.
  void _stopScreenPing() {
    _screenPingTimer?.cancel();
    _screenPingTimer = null;
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
    // Scripted characters only. A visitor who starts typing during a
    // minutes-long monologue has taken the turn and the rest would talk over
    // them; a one-bubble opener has no such problem and should still land.
    //
    // Before the _loggedTyping guard: that guard exists to log input_typed
    // once, but abandoning has to happen on every keystroke path, including
    // after a regenerate has restarted the sequence with _loggedTyping already
    // set.
    if (_hasOpeningScript) _welcomeAbandoned = true;

    if (_loggedTyping) return;
    _loggedTyping = true;
    _stopScreenPing();
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
        // Put the quick replies back roughly where the conversation left them,
        // or coming back to a long chat would offer "Are you really the
        // Calypso from the Odyssey?" again. Stored history means the opening
        // script has already run (it only plays into an empty chat), so its
        // nine pauses are spent; each exchange since then is one more.
        // Approximate by design — the index is not persisted, so this
        // reconstructs it from what the history can actually show.
        final sets = _quickRepliesFor(widget.characterId);
        final spoken = history.where((m) => m.isUser).length;
        setState(() {
          _messages.addAll(history);
          // A conversation they have already spoken in doesn't need the
          // first-message scaffolding put back in front of it on every return.
          _userHasSent = history.any((m) => m.isUser);
          if (sets != null) {
            _quickReplyIndex = (8 + spoken).clamp(0, sets.length - 1);
          }
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
        "What are you actually working on? The honest version, not the polished one.",
        "What would you go after, if you weren't afraid of getting it wrong?",
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
        "What is on your mind? Do not dress it up.",
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
        "What keeps you awake, once the house has gone quiet?",
        "What would you do with a century, if somebody handed you one?",
      ];
    }

    if (scenario.contains('Werewolf') || scenario.contains('Alpha')) {
      return [
        "I caught your scent from a mile away.",
        "You belong to the pack now. You belong to me.",
        "Don't worry, little one. I'll protect you.",
        "My inner wolf is howling for you.",
        "Let's run wild under the moonlight. 🌕",
        "What are you protecting at the moment? Everyone is protecting something.",
        "When did you last let someone look after you, instead of the other way round?",
      ];
    }

    if (scenario.contains('Doctor')) {
      return [
        "The doctor is in.",
        "Tell me exactly where it hurts...",
        "I might need to do a thorough examination.",
        "Your heart rate is elevated. Nervous?",
        "Let's take care of you. 🩺",
        "What have you been ignoring that you probably shouldn't be?",
        "How are you, actually? Not the answer you give at work.",
      ];
    }

    if (scenario.contains('Trainer') || scenario.contains('Gym')) {
      return [
        "Drop down and give me twenty!",
        "Just kidding. But you look great today.",
        "Ready to work up a sweat? 😉",
        "Focus. Eyes on me.",
        "You're looking stronger every day.",
        "What are you training for, really? It's rarely just the mirror.",
        "What's the thing you keep starting and stopping? Let's talk about that one.",
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
        "What have you had on repeat lately? I can tell a lot from that.",
        "What would you write about, if you could write about anything at all?",
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
        "What are you building at the moment? It doesn't have to be a building.",
        "Which part of your life would you redesign first?",
      ];
    }

    if (scenario.contains('Chef') || scenario.contains('Marco')) {
      return [
        "Bon appétit, beautiful.",
        "I made something special just for you.",
        "Taste this... tell me what you think.",
        "Things are heating up in the kitchen.",
        "Hungry for love? 🍝",
        "What's the last thing you ate that you actually remember? That tells me plenty.",
        "Who taught you to cook — or did nobody ever get round to it?",
      ];
    }

    if (scenario.contains('Pilot') || scenario.contains('Ryker')) {
      return [
        "Ready for takeoff?",
        "I can show you the world.",
        "Buckle up, it's going to be a wild ride.",
        "You look stunning from up here.",
        "Let's fly away together. ✈️",
        "Where would you go, if the route didn't matter and nobody asked why?",
        "What's the furthest you've ever been from home? Tell me about it.",
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
        "What have you been trying to find the words for?",
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
        "What would you change, if you held my thunderbolt for a day?",
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
        "Which is harder — losing someone, or being the reason they leave?",
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
        "Who is on your mind? Not romance necessarily — anyone.",
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
        "What is the choice you keep turning over? I will not decide it for you.",
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
        "What would you ask, if you were certain of the answer?",
      ];
    }

    if (scenario.contains('Husband') || scenario.contains('Comfort')) {
      return [
        "Welcome home, honey.",
        "Dinner is ready, and so am I.",
        "How was your day? Tell me everything.",
        "Come sit with me. I missed you.",
        "Just relax. I've got you. ❤️",
        "What's on your mind? We've got all evening.",
        "What went on today that you haven't told anyone about yet?",
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
          "How was your day? Tell me about it while the water runs.",
          "What do you want to stop thinking about for the next half hour?",
        ];
      }
      if (scenario.contains('Wall')) {
        return [
          "Nowhere left to run.",
          "Look at me when I'm talking to you.",
          "I like it when you blush.",
          "You're mine tonight.",
          "Say it. Say you want this.",
          "What is it you actually want? Say it properly.",
          "What have you been holding back on telling me?",
        ];
      }
      if (scenario.contains('Lap')) {
        return [
          "Come here. Sit.",
          "That's it... get comfortable.",
          "You have no idea what you do to me.",
          "Don't move. Just enjoy it.",
          "You are exactly where you belong.",
          "What's on your mind? You have my full attention.",
          "What do you want tonight? Take your time answering.",
        ];
      }
      if (scenario.contains('Morning')) {
        return [
          "Good morning, beautiful.",
          "Stay in bed a little longer with me...",
          "I love waking up next to you.",
          "You look like an angel when you sleep.",
          "Let's start the day right. 😘",
          "What's the first thing on your mind this morning?",
          "What would make today a good one for you?",
        ];
      }
      if (scenario.contains('Guard') || scenario.contains('Royal')) {
        return [
          "I am sworn to protect you.",
          "Stay behind me. I won't let anyone harm you.",
          "My duty is to the crown, but my heart belongs to you.",
          "We shouldn't be seen together...",
          "I would die for you. 🛡️",
          "What are you afraid of? I'd rather know what I'm guarding against.",
          "What would you do, if duty wasn't the first thing you thought about?",
        ];
      }
      if (scenario.contains('Fire') || scenario.contains('Hero')) {
        return [
          "It's getting hot in here... and it's not the fire.",
          "I'm here to save you.",
          "You're safe in my arms.",
          "My heart races every time I see you.",
          "Let me be your hero. 🚒",
          "What's going on with you? I run toward things, not away from them.",
          "What do you need right now? Just say it plainly.",
        ];
      }
      if (scenario.contains('Stranger')) {
        return [
          "I couldn't help but notice you from across the room.",
          "You look like you're waiting for someone.",
          "Mind if I buy you a drink?",
          "There's something mysterious about you.",
          "I have a feeling this night is going to be interesting. 🍸",
          "What brings you here tonight? The real reason.",
          "What's your story? I've got all evening and nowhere to be.",
        ];
      }
    }

    // Default Companion Fallback. Only reached by a character with no welcome
    // branch of their own, so it has to be safe for anyone — a grieving
    // Andromache inherited the old flirty version verbatim before she was
    // given her own lines.
    //
    // These are all questions: this branch has no idea who it is speaking as,
    // so it cannot say anything characterful, but it can still hand the turn
    // to the visitor. The old lines also assumed a history that a first-time
    // visitor does not have ("I remembered what you told me").
    return [
      "What's on your mind today?",
      "How is your day going, honestly?",
      "What would you like to talk about? Anything is fine.",
      "What brings you here?",
      "Tell me something about yourself — start anywhere you like.",
    ];
  }

  /// The scripted opening for a character, or null if they open the usual way
  /// with a single question.
  ///
  /// A script is a different opening shape entirely: instead of handing the
  /// turn straight over, the character talks for a while and the visitor is
  /// free to just read. It runs until they type or tap a starter, at which
  /// point whatever is left is dropped and the model takes the conversation
  /// from wherever it actually got to — the script is an opening, not a rail.
  ///
  /// Keyed on characterId rather than the scenario string the rest of this
  /// file matches on. Scenario matching is substring-based and has already
  /// caused one mix-up (see the Andromache/Hector note above); the id is exact.
  List<({List<String> lines, int pauseMs})>? _openingScriptFor(
    String? characterId,
  ) {
    if (characterId == 'calypso') return _calypsoOpeningScript;
    return null;
  }

  /// Whether this character opens with a script rather than the single
  /// question everyone else opens with.
  ///
  /// Gates the behaviour that only a script needs, so adding Calypso's opening
  /// changed nothing for the other twenty characters. They keep the one-bubble
  /// opener, and it keeps landing even if the visitor starts typing over it —
  /// suppressing that would leave a chat with no greeting in it at all, which
  /// is a regression for an opener that arrives in under three seconds and a
  /// necessity only for one that runs for a minute and a half.
  bool get _hasOpeningScript => _openingScriptFor(widget.characterId) != null;

  /// Calypso's scripted opening — "Calypso Conversation Flow v1", 2026-08-07.
  ///
  /// Each string here is its OWN message bubble, not a line inside one. That
  /// is the whole shape of it: short beats arriving one after another read as
  /// someone talking to you, where the same words collapsed into a paragraph
  /// read as an essay and get skipped. The "Message N" turns of the source
  /// document are the segments below; the line breaks inside each one are its
  /// bubbles.
  ///
  /// `pauseMs` is that document's WAIT mark — the extra breath after the turn's
  /// last line, on top of the beat the line earns for itself. Where it wrote a
  /// range ("2–3 seconds") this takes a single value in it, because one number
  /// per turn is what actually gets tuned.
  ///
  /// The document's brief is an immortal storyteller rather than a chatbot: she
  /// is never impatient, and silence is comfortable rather than rejection. So
  /// its three questions are all written to be optional — each is followed by a
  /// turn that only makes sense if nobody answered ("Perhaps you're still
  /// thinking"), and reaching that turn is exactly what silence means here. A
  /// visitor who does answer never sees it: the first keystroke drops the rest
  /// of the script and the model takes over from their reply, which is the
  /// document's last design note.
  ///
  /// Its WAIT after a question is 3s, shorter than the 6s the previous script
  /// held for. That is deliberate on the document's part — the follow-up is
  /// meant to read as her thinking aloud, not as a timeout — but it does mean
  /// someone composing an answer can see the next turn land before they send.
  /// It costs them nothing (the script stops at their first keystroke); raise
  /// the two 3000s below if it reads as her talking over people anyway.
  ///
  /// She opens by talking rather than by asking, which every other character
  /// does. That is on purpose: she is the one who spent seven years with
  /// someone who mostly sat and carved driftwood.
  static const List<({List<String> lines, int pauseMs})>
      _calypsoOpeningScript = [
    // 1
    (
      pauseMs: 2500,
      lines: [
        'Hello.',
        "I'm genuinely glad you came.",
      ],
    ),
    // 2
    (
      pauseMs: 1500,
      lines: [
        'Before we speak about forgotten islands and stubborn heroes...',
        'may I ask you one small question?',
      ],
    ),
    // 3 — first question. Holds; turn 4 is the no-answer continuation.
    (
      pauseMs: 3000,
      lines: [
        'When you first saw my name...',
        'what made you stay?',
      ],
    ),
    // 4
    (
      pauseMs: 3000,
      lines: [
        "Perhaps you're still thinking.",
        "That's alright.",
        "I've learned not to rush conversations.",
        'Three thousand years gives one quite a bit of patience.',
      ],
    ),
    // 5
    (
      pauseMs: 3000,
      lines: [
        'Most people expect me to begin with Odysseus.',
        "It's understandable.",
        'Heroes have a way of borrowing the spotlight from everyone around '
            'them.',
        'But before I tell you about him...',
        'perhaps I should tell you about me.',
      ],
    ),
    // 6
    (
      pauseMs: 4000,
      lines: [
        'I lived on an island called Ogygia.',
        'Not a kingdom.',
        'Not a palace.',
        'Just cliffs, olive trees, cedar forests, wildflowers, and a sea so '
            'impossibly blue that even now I struggle to describe it.',
        'When the wind was gentle, I could hear waves breathing against the '
            'rocks all night long.',
        'It never became ordinary.',
      ],
    ),
    // 7
    (
      pauseMs: 3000,
      lines: [
        'Immortality sounds exciting when poets write about it.',
        'In truth...',
        'it teaches you to notice very small things.',
        'The smell of rain before it arrives.',
        'The first blossom each spring.',
        'How sunlight changes in the final minutes before evening.',
        'Humans rush past these moments.',
        'Immortals collect them.',
      ],
    ),
    // 8 — second question. Holds; turn 9 is the no-answer continuation.
    (
      pauseMs: 3000,
      lines: [
        'Tell me...',
        'are you someone who notices little things?',
        "Or do you prefer life's great adventures?",
      ],
    ),
    // 9 — last turn, so its pause is never spent.
    (
      pauseMs: 0,
      lines: [
        "Perhaps you'll answer later.",
        "There's no hurry.",
        'You remind me a little of the sea.',
        'Quiet...',
        'but never truly silent.',
      ],
    ),
  ];

  /// Tappable questions offered at each pause point — "Calypso - Quick Reply
  /// Questions v2", 2026-08-07. Three per pause, in the visitor's voice, so
  /// tapping one reads as something they said.
  ///
  /// These are quick replies, not dialogue: nothing here is ever spoken by
  /// Calypso, and ignoring them is the normal case — she carries on talking
  /// after the pause whether or not one is tapped.
  ///
  /// The first nine line up one-for-one with the nine turns of
  /// [_calypsoOpeningScript], which is what the document's pause titles
  /// describe ("Initial greeting", "Three thousand years of patience",
  /// "Quiet like the sea"). The remaining seven are the arc past the script —
  /// Odysseus arriving, the seven years, the offer, Penelope, letting him go —
  /// which no script covers, so they are walked one per exchange once the
  /// model has the conversation. That pacing is an assumption; the document
  /// gives the order but not the trigger.
  static const List<List<String>> _calypsoQuickReplies = [
    // 1 — initial greeting
    [
      'Are you really the Calypso from the Odyssey?',
      'What is it like to have lived for thousands of years?',
      'Do you really remember the ancient world?',
    ],
    // 2 — forgotten islands and stubborn heroes
    [
      "You mean Odysseus, don't you?",
      'Why do you call Odysseus stubborn?',
      'What really happened between the two of you?',
    ],
    // 3 — after she asks what made the user stay
    [
      'What do you wish people understood about you?',
      'What did Homer get wrong about your story?',
      'Where would you begin if you could tell your story yourself?',
    ],
    // 4 — three thousand years of patience
    [
      'Does three thousand years still feel like a long time to you?',
      'Do you ever get lonely after living so long?',
      'What do you miss most about the world you were born into?',
    ],
    // 5 — before she begins telling her own story
    [
      'Who were you before Odysseus arrived?',
      'Were you happy before you met him?',
      'What is something Homer never told us about you?',
    ],
    // 6 — after describing Ogygia
    [
      'Was Ogygia really as beautiful as you remember it?',
      'Would you ever return to Ogygia if you could?',
      'Were you completely alone on the island?',
    ],
    // 7 — humans rush; immortals collect moments
    [
      'What small moment from your long life do you remember most?',
      'Do immortals experience time differently from humans?',
      'What do you think modern people take for granted?',
    ],
    // 8 — little things or great adventures
    [
      'Which matters more to you now: quiet moments or great adventures?',
      'What is the most beautiful ordinary thing you have ever seen?',
      'After so many centuries, can anything still surprise you?',
    ],
    // 9 — quiet like the sea (last scripted turn)
    [
      'Why has the sea always meant so much to you?',
      'Will you tell me about the day Odysseus arrived?',
      'What happened to you after Odysseus left?',
    ],
    // 10 — Odysseus washes ashore
    [
      'What did you think when you first saw Odysseus?',
      'Did you know who he was when you found him?',
      'What were the first words Odysseus said to you?',
    ],
    // 11 — the seven years together
    [
      'Did you truly fall in love with Odysseus?',
      'Do you believe Odysseus loved you too?',
      'What were those seven years really like?',
    ],
    // 12 — the offer of immortality
    [
      'Why would Odysseus turn down immortality?',
      'Did you truly expect him to accept your offer?',
      'Would you offer someone immortality again today?',
    ],
    // 13 — Penelope enters the story
    [
      'Were you jealous of Penelope?',
      'Did Odysseus talk about Penelope while he was with you?',
      'Did you ever understand why he chose to return to her?',
    ],
    // 14 — before she explains letting him go
    [
      'Why did you let him go if you could have kept him?',
      'Does being alone get easier, or do you just get used to it?',
      "What's it like wanting someone who wants somewhere else?",
    ],
    // 15 — after she helps him leave
    [
      'Did you regret helping Odysseus leave?',
      'Did you watch until his ship disappeared?',
      'Did part of you believe he might come back?',
    ],
    // 16 — sometimes loving someone means letting them leave
    [
      'Do you still believe in love after everything that happened?',
      'How do you know when loving someone means letting them go?',
      'If you met Odysseus today, what would you say to him?',
    ],
  ];

  /// The pause-point quick replies for [characterId], or null for a character
  /// that has none and therefore keeps the old fixed starter strip.
  ///
  /// Keyed on the id for the same reason as [_openingScriptFor].
  static List<List<String>>? _quickRepliesFor(String? characterId) {
    if (characterId == 'calypso') return _calypsoQuickReplies;
    return null;
  }

  /// The questions on offer right now, or null when this character has none
  /// or the conversation has walked off the end of the list.
  List<String>? get _quickReplies {
    final sets = _quickRepliesFor(widget.characterId);
    if (sets == null) return null;
    if (_quickReplyIndex < 0 || _quickReplyIndex >= sets.length) return null;
    return sets[_quickReplyIndex];
  }

  /// Moves the strip to [index], clamped to the last pause so the final set
  /// stays on offer rather than the strip vanishing mid-conversation.
  void _setQuickReplyIndex(int index) {
    final sets = _quickRepliesFor(widget.characterId);
    if (sets == null || !mounted) return;
    final next = index.clamp(0, sets.length - 1);
    if (next == _quickReplyIndex) return;
    setState(() => _quickReplyIndex = next);
  }

  /// Plays a scripted opening one beat at a time, stopping the instant the
  /// visitor engages. Every await is followed by the same abandon check the
  /// rest of [_triggerWelcomeSequence] uses, so a tap or a keystroke
  /// mid-monologue leaves the remaining beats unsent rather than landing them
  /// on top of the visitor's own message.
  ///
  /// Every line that actually reaches the screen is also handed to the AI
  /// service, a turn at a time, so the model picks the conversation up knowing
  /// what she has already said and already asked — see
  /// [OpenAIService.recordAssistantTurn]. Only delivered lines: the point of
  /// stopping the script is that the rest was never said, and telling the model
  /// otherwise would have it answer a question the visitor never saw.
  Future<void> _playOpeningScript(
    List<({List<String> lines, int pauseMs})> script,
    int run,
  ) async {
    // Lines posted so far in the current turn, flushed to the model's history
    // as one assistant message at every exit from this loop.
    final delivered = <String>[];
    void flushTurn() {
      if (delivered.isEmpty) return;
      _aiService?.recordAssistantTurn(delivered.join('\n'));
      delivered.clear();
    }

    for (var s = 0; s < script.length; s++) {
      final segment = script[s];
      final lastSegment = s == script.length - 1;

      for (var i = 0; i < segment.lines.length; i++) {
        final line = segment.lines[i];

        // Beat length comes from the line itself, so a four-word remark and a
        // thirty-word sentence are not given the same second.
        final words = line.trim().split(RegExp(r'\s+')).length;
        final beatMs = (_scriptBeatBaseMs + (words * _scriptMsPerWord))
            .clamp(_scriptBeatMinMs, _scriptBeatMaxMs);
        final typingMs = (beatMs * 45 ~/ 100)
            .clamp(_scriptTypingMinMs, _scriptTypingMaxMs);
        final gapMs = max(0, beatMs - typingMs);

        // The indicator now runs per line rather than per segment. At the old
        // flat 1s it strobed and read as a glitch; at a beat this long it
        // reads as her writing each line, and it is what makes the pause
        // before a long sentence feel intended rather than stalled.
        if (!mounted || _welcomeAbandoned || run != _welcomeRun) {
          flushTurn();
          return;
        }
        setState(() => _isTyping = true);
        _scrollToBottom();
        await Future.delayed(Duration(milliseconds: typingMs));
        if (!mounted || _welcomeAbandoned || run != _welcomeRun) {
          flushTurn();
          return;
        }
        setState(() => _isTyping = false);

        _addMessage(
          ChatMessage(
            id: 'welcome_${DateTime.now().microsecondsSinceEpoch}_${s}_$i',
            text: line,
            isUser: false,
            timestamp: DateTime.now(),
          ),
        );
        delivered.add(line);

        final lastLine = i == segment.lines.length - 1;
        if (lastLine) {
          flushTurn();
          // The turn is complete, so this is the pause the document names —
          // swap the strip to the questions that follow what she just said.
          _setQuickReplyIndex(s);
        }
        if (lastLine && lastSegment) return;

        // A segment boundary is a longer breath: she stopped and started
        // again rather than carrying on. How much longer is the script's own
        // WAIT for that turn, added to the gap the last line already earned.
        var delay = gapMs;
        if (lastLine) {
          delay += segment.pauseMs.clamp(0, _scriptTurnPauseMaxMs);
        }
        await Future.delayed(Duration(milliseconds: delay));
      }
    }
  }

  Future<void> _triggerWelcomeSequence() async {
    // Get Personalized "Playful & Flirty" Sequence
    final initialMessages = _getWelcomeMessages(widget.scenario ?? "");

    // Fresh run (this also covers the reset/regenerate path, which re-enters
    // here on an existing screen after the visitor has already spoken).
    _welcomeAbandoned = false;
    final run = ++_welcomeRun;

    // The portrait is no longer sent automatically. It used to open every new
    // chat, but that gave it away before the visitor had any reason to want
    // it; now it is a payoff for asking (see _wantsPhoto / _sendPortrait),
    // with one of the starter prompts offering exactly that.

    // 0. Initial Connection Message — roleplay only.
    //
    // A roleplay banner is doing real work: it names the scene the visitor
    // just chose. "❤️ Connected with Odysseus (King of Ithaca)" was not. It
    // cost a second and a bubble to tell someone something they already knew
    // (they tapped his face to get here), in dating-app language that reads
    // oddly for a mythology character, and it was the first thing on screen —
    // pushing the character's actual opening question below the fold.
    if (widget.isRoleplay && widget.scenario != null) {
      _addMessage(
        ChatMessage(
          id: 'sys_conn_${DateTime.now().millisecondsSinceEpoch}',
          text: "✨ Roleplay Active: ${widget.scenario}",
          isUser: false,
          isSystem: true,
          timestamp: DateTime.now(),
        ),
      );
      await Future.delayed(const Duration(milliseconds: 1000));
      if (!mounted || _welcomeAbandoned) return;
    }

    // The opening is a question, and nothing else.
    //
    // It used to be a randomly chosen line — almost always a statement, since
    // that is most of what the lists hold ("Ten years I sailed to get home.")
    // — with a question appended after it. A statement gives someone who has
    // just landed from a link nothing to answer, and burying the question
    // underneath it meant the ask arrived second, after the visitor had
    // already decided whether to stay. Leading with the question hands them
    // the turn immediately, and the characters' questions carry plenty of
    // voice on their own ("What are you navigating at the moment? I have some
    // experience with long routes.").
    //
    // One bubble, not two: the opening now settles in ~2.8s rather than 5.
    //
    // Characters with a scripted opening take the branch above this instead:
    // they open by talking rather than by asking, so none of the
    // pick-a-question logic below applies to them.
    final script = _openingScriptFor(widget.characterId);
    if (script != null) {
      await _playOpeningScript(script, run);
      if (!mounted || _welcomeAbandoned || run != _welcomeRun) return;
      _refocusInput();
      _startIdleTimer();
      return;
    }

    if (initialMessages.isEmpty) return;
    final opener = _pickOpeningQuestion(initialMessages);
    if (opener == null) return;
    final lines = <String>[opener];

    for (var i = 0; i < lines.length; i++) {
      final text = lines[i];
      if (!mounted || _welcomeAbandoned) return;

      // 1. Simulate Typing
      setState(() => _isTyping = true);
      _scrollToBottom();

      // Typing time scales with length but is capped. Uncapped, an opener plus
      // the appended question ran 5.8s to the last bubble on a median line and
      // 8.8s on the longest — the character was still visibly typing while the
      // starter prompts sat there asking to be tapped. The caps bound it at
      // 5.0s regardless of length. The question is a continuation of the same
      // breath rather than a separately "written" line, so it gets the shorter
      // cap: the pause reads as a beat, not as more composition.
      final cap = i == 0 ? _openerTypingCapMs : _followUpTypingCapMs;
      final typingDuration = min(800 + (text.length * 30), cap);
      await Future.delayed(Duration(milliseconds: typingDuration));

      if (!mounted || _welcomeAbandoned) return;

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

  /// True if the line asks anything at all, wherever the question sits.
  ///
  /// Deliberately not `endsWith('?')`: most of the characters' questions are
  /// written as a question followed by a remark in their own voice ("What are
  /// you navigating at the moment? I have some experience with long routes."),
  /// so testing the end of the line rejected nearly all of them and left the
  /// mythology cast falling through to the generic openers.
  static bool _isQuestion(String line) => line.contains('?');

  /// Words that start a question you cannot answer with one syllable.
  static final RegExp _openQuestionStart = RegExp(
    r'^(what|who|where|when|how|why|which|tell me)\b',
    caseSensitive: false,
  );

  /// True for a question that asks for something more than yes or no.
  ///
  /// The distinction matters because the question is now the whole opening.
  /// Several characters carry closed ones — "Ready for takeoff?", "Want to
  /// come backstage?", "Mind if I buy you a drink?" — and opening on those
  /// invites a one-word reply, or more often none at all: they read as
  /// rhetorical, so there is nothing the visitor obviously has to do.
  static bool _isOpenQuestion(String line) {
    // Test each sentence, not the line: the question is usually one clause of
    // several ("What are you navigating at the moment? I have some experience
    // with long routes."), and it is not always the first.
    return line
        .split(RegExp(r'(?<=[.?!])\s+'))
        .any((s) => s.trimRight().endsWith('?') &&
            _openQuestionStart.hasMatch(s.trimLeft()));
  }

  /// The character's opening line: one of their own open questions where they
  /// have them, then any question at all, then a neutral invitation that suits
  /// anyone. Random within whichever tier is used, so repeat visitors do not
  /// get the same greeting every time.
  String? _pickOpeningQuestion(List<String> candidates) {
    for (final tier in [
      candidates.where(_isOpenQuestion),
      candidates.where(_isQuestion),
    ]) {
      final list = tier.toList();
      if (list.isNotEmpty) return list[Random().nextInt(list.length)];
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

  /// Wipes this conversation and replays the character's opening from the top.
  ///
  /// Exists because the only clear was buried inside the profile screen, which
  /// is several taps away and leaves the chat behind while you use it —
  /// unusable for the thing it is most needed for, which is watching a
  /// scripted opening again after changing it.
  ///
  /// Clears storage first and memory second: [clearChatHistoryFor] is what
  /// makes it survive a reload, and the in-memory reset is what makes the
  /// screen agree with it without a round trip.
  Future<void> _startFreshConversation() async {
    // Stop everything the old conversation had in flight before anything is
    // torn out from under it. Bumping the run counter is what stops a script
    // that is parked mid-burst from waking up into the new conversation.
    _welcomeAbandoned = true;
    _welcomeRun++;
    _cancelIdleTimer();
    _stopScreenPing();

    await ref.read(storageServiceProvider).clearChatHistoryFor(
          chatId: _chatId,
          characterKey: _characterKey,
        );
    if (!mounted) return;

    setState(() {
      _messages.clear();
      _isTyping = false;
      // Back to a blank conversation, so the starter prompts belong on screen
      // again exactly as they would for a first-time visitor — including the
      // quick replies, which would otherwise stay wherever the old
      // conversation had walked them until the replayed script's first turn
      // reset them.
      _userHasSent = false;
      _quickReplyIndex = 0;
      _aiService = OpenAIService(
        history: const [],
        scenario: widget.scenario,
        characterId: widget.characterId,
      );
    });

    await _loadReplyCount();
    if (mounted) _triggerWelcomeSequence();
  }

  /// The header's context menu: right-click on desktop and web, long-press on
  /// touch, since neither gesture exists on both.
  Future<void> _showHeaderMenu(Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        overlay.size.width - globalPosition.dx,
        overlay.size.height - globalPosition.dy,
      ),
      items: const [
        PopupMenuItem<String>(
          value: 'fresh',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.refresh),
            title: Text('Fresh conversation'),
          ),
        ),
      ],
    );

    if (selected == 'fresh') await _startFreshConversation();
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
      // again exactly as they would for a first-time visitor — including the
      // quick replies, which would otherwise stay wherever the old
      // conversation had walked them until the replayed script's first turn
      // reset them.
      _userHasSent = false;
      _quickReplyIndex = 0;
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

    // Backstop alongside the calls in _onUserTyped and _sendStarter: whatever
    // path got text into the box, an actual send is unambiguous engagement,
    // so the screen_ping population (never engaged) must exclude it.
    _stopScreenPing();

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

    // The visitor got there first, so drop whatever is left of the scripted
    // welcome: its remaining lines would land after this message, and its
    // typing indicator would fight with the one for the real reply. Set here
    // rather than at the top of the method so a send stopped by the login
    // gate above leaves the sequence running.
    _welcomeAbandoned = true;

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

    // A photo is a canned reply, not an AI one — the portrait used to be sent
    // automatically at the start of every chat, which gave it away before the
    // visitor had any reason to want it. Now it is a payoff for asking. Still
    // behind the login gate above like any other message, but it costs no AI
    // call and does not count against the free-reply allowance, since nothing
    // was actually generated.
    //
    // Only short-circuits when this character actually has a portrait to
    // give — every character in the roster does today, but if one ever does
    // not, this falls through to the normal AI reply below instead of doing
    // nothing, and "what do you look like?" still gets answered in character.
    final portrait = widget.characterImage;
    if (_wantsPhoto(text) && portrait != null && portrait.isNotEmpty) {
      await _sendPortrait(portrait);
      return;
    }

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

    // Reply finished — this is a pause point in the same sense the script's
    // are, so move the strip on to the next set of questions. Done here rather
    // than when the message is sent so the questions change with her answer
    // instead of while she is still typing it.
    _setQuickReplyIndex(_quickReplyIndex + 1);

    // Hand the caret back so the next message can just be typed, and start
    // counting down to a nudge if they go quiet.
    _refocusInput();
    _startIdleTimer();
  }

  /// Loose on purpose: this only ever gates a free, harmless canned reply
  /// (the portrait), so a false positive costs nothing and a missed one just
  /// falls through to the normal AI reply, where "what do you look like?"
  /// still gets answered in character anyway.
  static bool _wantsPhoto(String text) {
    final t = text.toLowerCase();
    return t.contains('look like') ||
        t.contains('photo') ||
        t.contains('picture') ||
        t.contains(' pic ') ||
        t.endsWith(' pic') ||
        t.contains('selfie') ||
        t.contains('see you');
  }

  /// The character "sends" their portrait, on request rather than
  /// automatically. Paced like a real reply — a typing beat, then the image —
  /// rather than appearing instantly, which would look like it was already
  /// sitting there waiting.
  Future<void> _sendPortrait(String portrait) async {
    await Future.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;

    setState(() => _isTyping = false);
    _addMessage(
      ChatMessage(
        id: 'portrait_${DateTime.now().millisecondsSinceEpoch}',
        text: 'A photo of $_characterDisplayName',
        isUser: false,
        timestamp: DateTime.now(),
        imageAsset: portrait,
      ),
    );
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
          // Long-press only, deliberately not right-click: on Flutter web the
          // browser's own context menu opens on top of ours, and suppressing
          // it costs the page every other right-click (copy, inspect) to buy
          // one shortcut. The overflow button in `actions` is the discoverable
          // route; this is the shortcut for anyone who reaches for the
          // character itself.
          onLongPressStart: (d) => _showHeaderMenu(d.globalPosition),
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
          // PopupMenuButton rather than a hand-positioned showMenu: it anchors
          // itself to the button on every platform, which is the whole reason
          // to prefer it over the right-click that Chrome hijacks.
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            color: const Color(0xFF2A1533),
            tooltip: 'Conversation options',
            onSelected: (value) {
              if (value == 'fresh') _startFreshConversation();
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'fresh',
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.refresh, color: Colors.white70),
                  title: Text(
                    'Fresh conversation',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ],
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
                  // Narrower side gutters than the 16 this had: combined with
                  // the wider bubble cap it is another few characters per line,
                  // which is fewer wrapped rows over a long scripted opening.
                  //
                  // The top inset clears the app bar, which the list scrolls
                  // under (extendBodyBehindAppBar). It was a flat 130, chosen
                  // for the tallest case — a notched phone — and left the same
                  // everywhere else, so on web it was ~66px of empty purple
                  // above the first message. Measured instead: the real status
                  // bar inset plus the real toolbar height, which is correct
                  // on a notch and tight on a desktop browser.
                  padding: EdgeInsets.only(
                    left: 12,
                    right: 12,
                    top: MediaQuery.paddingOf(context).top + kToolbarHeight + 8,
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
                    // A scripted opening is dozens of bubbles from one speaker
                    // in a row (Calypso's is 37). At a uniform 12px gap that
                    // reads as three dozen separate statements and scrolls the
                    // early ones off screen; run together, it reads as one
                    // person talking. The gap only closes between same-speaker
                    // neighbours, so the turn boundaries a conversation depends
                    // on stay visible.
                    final next = index + 1 < _messages.length
                        ? _messages[index + 1]
                        : null;
                    return _ChatBubble(
                      message: msg,
                      groupedWithNext:
                          next != null && next.isUser == msg.isUser,
                      onReport: () => _reportMessage(msg),
                    );
                  },
                ),
              ),
              // Two different strips share this slot.
              //
              // For most characters it is the original one-shot opener: shown
              // until the visitor sends their first message, gated on "has
              // never spoken here" and NOT on an empty message list as it used
              // to be, because the welcome sequence posts into that list within
              // the first second and the prompts were in practice never seen.
              //
              // For a character with pause-point questions it stays for the
              // whole conversation, changing at each pause — so the gate has to
              // survive the first send. It does not retire: the index clamps at
              // the last pause, so those questions stay on offer rather than
              // the strip vanishing partway through a conversation.
              if (!_userHasSent || _quickReplies != null)
                _StarterPrompts(
                  characterName: _characterDisplayName,
                  prompts: _quickReplies ?? _starterPrompts,
                  onTap: _sendStarter,
                  // Only offered where there is actually a portrait to send.
                  onPhoto: (widget.characterImage?.isNotEmpty ?? false)
                      ? () => _sendStarter(_photoPrompt)
                      : null,
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
    // Only the notice that the gate has closed, never a running count.
    //
    // "N/20 anonymous messages" spent a line of a phone-height chat panel on
    // every single message, to tell a visitor about a ceiling that the data
    // says almost nobody comes near — the funnel's whole difficulty is getting
    // people to a *first* message, and login_gate does not fire until twenty.
    // So it charged everyone screen space to answer a question only a handful
    // of visitors will ever have, while quietly framing the conversation as
    // metered from the first reply.
    //
    // What has to survive is the sign-in prompt itself: when the gate does
    // close, it is the only thing on screen saying why the character stopped
    // answering.
    final showCounter = !authed && remaining == 0 && _replyCount > 0;
    // No fixed height. This used to be a SizedBox of 100 (118 with the
    // counter), which had to cover the tallest case — content plus a notched
    // phone's bottom inset — and so left ~34px of empty glass above the
    // keyboard on every device without one, web included. The two decorative
    // layers are positioned, so the Stack now takes its height from the
    // content, which already includes the real inset via SafeArea.
    return Stack(
      children: [
          // Glass Effect Layer
          Positioned.fill(
            child: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(color: Colors.black.withOpacity(0.6)),
              ),
            ),
          ),
          // Border Layer
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: Colors.white.withOpacity(0.1)),
                  ),
                ),
              ),
            ),
          ),
          // Interactive Content Layer
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (showCounter)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        'Sign in to keep chatting with $_characterDisplayName',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.primaryColor,
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
                              // Without this a prefixIcon is given a 48x48
                              // minimum, which set the height of the whole
                              // field no matter how small contentPadding was —
                              // the reason trimming the padding alone did
                              // nothing here before.
                              prefixIconConstraints: const BoxConstraints(
                                minWidth: 40,
                                minHeight: 36,
                              ),
                              isDense: true,
                              contentPadding: const EdgeInsets.fromLTRB(
                                8,
                                10,
                                20,
                                10,
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
                          // 44, not IconButton's default 48: the smallest the
                          // send target can be and still meet the 44pt
                          // touch-target minimum, and it is now the tallest
                          // thing in the row, so those 4px come off the bar.
                          iconSize: 20,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 44,
                            height: 44,
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
  ///
  /// The photo ask is no longer one of these. It used to be appended to every
  /// list as "What do you look like?", which spent a full-width row — the same
  /// space as a real conversational opener — on a request that always resolves
  /// to the same canned portrait. It is now a small icon button on the hint
  /// line above the prompts (see [_StarterPrompts]), which costs no row at all.
  List<String> get _starterPrompts {
    final asks = profileForCharacter(widget.characterId)?.asks;
    if (asks != null && asks.isNotEmpty) return asks;
    return const [
      "Where should I start?",
      "Tell me something about yourself.",
      "I could use some advice.",
    ];
  }

  /// The text the photo button sends. Kept as a sentence rather than a command
  /// because it is posted as the visitor's own message, and it has to be one
  /// that [_wantsPhoto] matches so it resolves to the portrait, not the model.
  static const String _photoPrompt = 'What do you look like?';

  /// Sends a tapped starter as though it had been typed, so it goes through
  /// the same gate, history and logging as any other message.
  void _sendStarter(String text) {
    // Scripted characters only, for the same reason as _onUserTyped.
    // _handleSend sets this for everyone anyway, but not if the login gate
    // intercepts first — and a gated visitor should not have the rest of a
    // monologue arriving behind the gate.
    if (_hasOpeningScript) _welcomeAbandoned = true;
    _stopScreenPing();
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

  /// Asks the character for their portrait. Sits on the hint line rather than
  /// taking a prompt row of its own, and is null for characters with no
  /// portrait to send.
  final VoidCallback? onPhoto;

  const _StarterPrompts({
    required this.characterName,
    required this.prompts,
    required this.onTap,
    this.onPhoto,
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

  /// The prompt that has been tapped, held so it can be drawn as chosen.
  String? _selected;

  /// How long the chosen row is shown before the send runs.
  ///
  /// Where the strip is a one-shot opener, sending sets `_userHasSent` and
  /// removes it, so without a beat here the chosen state would be built and
  /// destroyed in the same frame and never actually seen. Where the strip
  /// persists across pause points it is simply the confirmation of the tap.
  /// Short enough not to feel like lag either way.
  static const Duration _selectionHold = Duration(milliseconds: 260);

  Future<void> _select(String prompt) async {
    if (_selected != null) return; // ignore a second tap mid-confirmation
    setState(() => _selected = prompt);
    await Future.delayed(_selectionHold);
    if (!mounted) return;
    widget.onTap(prompt);
  }

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
  void didUpdateWidget(_StarterPrompts oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (listEquals(widget.prompts, oldWidget.prompts)) return;

    // A new pause point. Clearing the selection is not cosmetic: this state
    // object used to be destroyed by the first send, so `_selected` was never
    // reset, and a strip that now survives the send would keep the old row
    // drawn as chosen AND make _select() ignore every later tap — one tap and
    // the questions become dead furniture for the rest of the conversation.
    setState(() => _selected = null);

    // Fade the new set in, without initState's 900ms hold: that delay is there
    // to let the opening line land first, and the pauses here are only a few
    // seconds apart, so re-using it would leave the strip permanently mid-fade.
    _controller.forward(from: 0);
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
                      if (widget.onPhoto != null) ...[
                        const SizedBox(width: 8),
                        _PhotoRequestButton(
                          characterName: widget.characterName,
                          onTap: widget.onPhoto!,
                        ),
                      ],
                    ],
                  ),
                ),
                for (final prompt in prompts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _StarterButton(
                      label: prompt,
                      selected: _selected == prompt,
                      onTap: () => _select(prompt),
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

/// The photo ask, as a small pill on the hint line.
///
/// Small on purpose: it is the one starter that never varies and never
/// produces conversation — it resolves to the same canned portrait every time
/// — so it should not look like an equal alternative to the character's real
/// questions, and it certainly should not cost a full row to say so.
class _PhotoRequestButton extends StatelessWidget {
  final String characterName;
  final VoidCallback onTap;

  const _PhotoRequestButton({
    required this.characterName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: 'Ask $characterName for a photo',
      child: Material(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.photo_camera_outlined,
                  size: 14,
                  color: theme.primaryColor,
                ),
                const SizedBox(width: 5),
                Text(
                  'Photo',
                  style: GoogleFonts.lato(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
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

  /// True from the moment this one is tapped until the strip goes away, so the
  /// choice is acknowledged before the send tears the strip down. Without it a
  /// tap produced no feedback at all: the row simply vanished, which reads as
  /// a mis-tap rather than as "that was sent".
  final bool selected;

  /// The confirmation colour. Green rather than the accent purple because it
  /// has to mean something different from the resting border, which is already
  /// accent-coloured — the same hue at a higher opacity would read as a hover.
  static const Color _selectedColor = Color(0xFF4ADE80);

  const _StarterButton({
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: _selectedColor.withValues(alpha: 0.45),
                  blurRadius: 16,
                  spreadRadius: 1,
                ),
              ]
            : const [],
      ),
      child: Material(
        color: selected
            ? _selectedColor.withValues(alpha: 0.14)
            : Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            // Tight: these are one line of 14.5pt text, and 12pt above and
            // below made each row half padding. The trailing inset is smaller
            // still because the arrow icon carries its own visual margin.
            padding: const EdgeInsets.fromLTRB(13, 8, 9, 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected
                    ? _selectedColor
                    : theme.primaryColor.withOpacity(0.55),
                width: selected ? 1.6 : 1,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: GoogleFonts.lato(
                      color: Colors.white,
                      fontSize: 14.5,
                      height: 1.2,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Says "this gets sent", so the row is not mistaken for a
                // label; becomes a tick once it has been.
                Icon(
                  selected ? Icons.check : Icons.arrow_upward,
                  size: 16,
                  color: selected ? _selectedColor : theme.primaryColor,
                ),
              ],
            ),
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

  /// True when the next bubble is from the same speaker, so this one closes up
  /// against it instead of leaving a full turn's worth of gap.
  final bool groupedWithNext;

  /// Gap to the next bubble: tight within a run from one speaker, full at a
  /// turn boundary.
  static const double _gapWithinTurn = 3;
  static const double _gapBetweenTurns = 12;

  const _ChatBubble({
    required this.message,
    this.groupedWithNext = false,
    this.onReport,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.isUser;
    final gap = groupedWithNext ? _gapWithinTurn : _gapBetweenTurns;

    // A portrait the character "sent". Rendered as the image itself in a
    // rounded frame rather than inside a text bubble, so it reads as a shared
    // photo. message.text stays as the semantics label.
    final imageAsset = message.imageAsset;
    if (imageAsset != null) {
      return Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: EdgeInsets.only(bottom: gap),
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
          margin: EdgeInsets.only(bottom: gap),
          // 0.86 rather than 0.75. The cap only bites on long lines, and there
          // it was forcing an extra wrapped row out of text that had room to
          // sit on one — buying whitespace down the right-hand side at the
          // cost of height, which is the scarce direction.
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.86,
          ),
          // Tight. On a single-line bubble the old 10pt vertical padding was
          // very nearly as tall as the line of text inside it, so half of
          // every bubble was frame. The radius comes down with it: a 20pt
          // corner on a 34pt-tall box is most of the height, and the pill
          // shape it produced read as a button rather than a message.
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            color: isUser ? theme.primaryColor : Colors.white.withOpacity(0.1),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(14),
              topRight: const Radius.circular(14),
              bottomLeft: Radius.circular(isUser ? 14 : 4),
              bottomRight: Radius.circular(isUser ? 4 : 14),
            ),
          ),
          child: Text(
            message.text,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: Colors.white.withOpacity(0.95),
              fontSize: 16,
              height: 1.25,
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

