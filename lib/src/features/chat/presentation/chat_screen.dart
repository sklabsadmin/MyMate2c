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
import '../../../core/services/chime.dart';
import '../../../core/services/delivery_log.dart';
import '../../../core/presentation/seen_detector.dart';
import '../services/openai_service.dart';
import '../../../core/data/character_profiles.dart';
import '../../../core/data/characters.dart';
import '../../character/presentation/character_profile_screen.dart';
import '../../wallet/coin_wallet.dart';
import '../../wallet/presentation/coin_chip.dart';
import '../../wallet/presentation/coin_claim_screen.dart';
import '../../wallet/presentation/coins_sheet.dart';

/// Beat pacing for a scripted opening — see [_ChatScreenState._readablePacing]
/// for what each field does and why there is more than one set of them.
typedef _ScriptPacing = ({int msPerWord, int baseMs, int minMs, int maxMs});

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

class _ChatScreenState extends ConsumerState<ChatScreen>
    with WidgetsBindingObserver {
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

  /// Which delivery receipt belongs to which message, so a bubble that scrolls
  /// into view can complete the record opened when it was first drawn.
  ///
  /// Kept beside the messages rather than on ChatMessage: the model is
  /// serialised into local history, and a receipt id has no meaning on a later
  /// run — a restored message must not look like a bubble still awaiting a
  /// sighting. Absent from this map is exactly the right answer for history.
  final Map<String, String> _bubbleIdByMessageId = {};

  /// Whether this surface is actually in front of the visitor. False for a
  /// backgrounded app and, on web, for a hidden tab — Flutter reports the Page
  /// Visibility API through the same lifecycle callback.
  bool _surfaceVisible = true;

  /// Bumped whenever the answer to "is this bubble visible" could have changed
  /// for reasons a scroll notification would not cover.
  final ValueNotifier<int> _surfaceChanged = ValueNotifier<int>(0);

  /// What SeenDetector listens to: scrolling, plus the lifecycle changes above.
  late final Listenable _seenRevalidate = Listenable.merge([
    _scrollController,
    _surfaceChanged,
  ]);

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

  /// The 1.7.1 interaction gate: the character has spoken its opening turn and
  /// will not say another word until the visitor answers.
  ///
  /// Why this exists at all. Over the 30 days to 2026-08-17 production saw
  /// 5,181 arrivals, 3,490 of which reached this screen, and 49 in which a
  /// human typed a character or tapped a prompt — 0.95%. The screen was
  /// performing at people: 14,067 scripted lines were declared and 1,301 ever
  /// drawn, because the opening keeps talking whether or not anyone is
  /// listening, and a visitor who does nothing is served exactly the same
  /// experience as one who engages. That makes the two indistinguishable in the
  /// data, which is the actual problem this release is about — we cannot tell
  /// "saw the offer and declined" from "never understood there was one".
  ///
  /// Freezing the story on an unanswered question separates them. Whoever
  /// leaves now leaves having been asked something and not answered it, and
  /// that is a measurement rather than an absence.
  ///
  /// Hard by design: nothing releases this but the visitor. No timeout resumes
  /// the script, and [_startIdleTimer] refuses to run under it, so the
  /// character does not fill the silence it just created.
  bool _gateActive = false;

  /// One-shot guard for the gate_shown funnel event.
  ///
  /// gate_shown is the denominator the whole release rests on. Reporting taps
  /// against arrivals is what made `character_tap` useless — it fires in
  /// initState, so for a /c/<id> link it records an arrival wearing the name of
  /// a tap. A rate measured against people who were actually offered the choice
  /// is the only version of this number that survives a 2s median paint on the
  /// traffic that pays for itself.
  /// A rate measured against people who were actually offered the choice is
  /// the only version of this number that survives a 2s median paint on the
  /// traffic that pays for itself: half of QR arrivals are gone by 3s, so a
  /// gate that lands late is not declined, it is unseen.
  ///
  /// The delay itself needs nothing stored here — the beacon stamps every
  /// event with `durationMs` from arrival (web/index.html), which already
  /// counts the paint this is trying to account for.
  bool _gateShownLogged = false;

  /// The entry gate: a card over the chat with one button, which has to be
  /// tapped before the character says anything at all.
  ///
  /// Where the story freeze asks "will you answer him", this asks the shorter
  /// question underneath it — "will you tap anything" — and asks it of a
  /// visitor who has not had to read a word first. The two nest: entry_tap is
  /// the low bar, gate_choice the high one, and the gap between them is how
  /// much of the drop-off is the writing rather than the willingness.
  ///
  /// While it is up the opening does not play. That is deliberate and is half
  /// the point: 14,067 scripted lines were declared to the delivery log in the
  /// 30 days to 2026-08-17 and 1,301 were ever drawn, because the character
  /// talks to whoever is not there. Nothing is declared now until someone has
  /// said they are watching.
  bool _entryGateActive = false;

  /// Whether tapping through the entry card should start the scripted opening.
  ///
  /// True for a genuinely empty chat. False when the card is up over history
  /// the visitor never spoke in — a monologue an older bundle auto-played and
  /// saved. Those visitors get the card (they have never engaged, and that is
  /// what it measures) but tapping it must not replay the opening under lines
  /// that are already on the screen; the model resumes from the history it
  /// was built with, exactly as a reload does.
  bool _entryGateStartsOpening = true;

  /// Scroll position of the entry card's own scroll view, read once per
  /// showing to answer one question: was the Tap to Talk button inside the
  /// first viewport, or below the fold? The card pins the button to the
  /// bottom of its CONTENT, which on a short screen (an in-app browser with
  /// fat chrome) extends past the viewport — reachable by scrolling, but a
  /// visitor who does not know it is there will not scroll to find it. Every
  /// short-viewport tap rate read to date has been unable to separate
  /// "declined" from "never saw the button", which is what this closes.
  ///
  /// Owned by the screen and handed to _EntryGate, because the reader
  /// (_raiseEntryGate's post-frame callback) lives here.
  final ScrollController _entryGateScrollController = ScrollController();

  /// The scenario string split once: "Odysseus (King of Ithaca)" → name
  /// "Odysseus", title "King of Ithaca". Title is null for a scenario written
  /// without one.
  ///
  /// The one parser for that format. There were three — this getter with
  /// indexOf/lastIndexOf, _characterDisplayName with its own indexOf, and a
  /// regex inside _openProfile — which agreed on every string in the roster
  /// today and would disagree on the first title containing a parenthesis.
  /// Name and title come from the same split so the entry card and the profile
  /// screen cannot drift apart on what they call the character.
  ({String name, String? title}) get _scenarioParts {
    final scenario = widget.scenario;
    if (scenario == null || scenario.isEmpty) return (name: 'He', title: null);
    final open = scenario.indexOf(' (');
    if (open <= 0) return (name: scenario, title: null);
    final close = scenario.lastIndexOf(')');
    if (close <= open + 2) return (name: scenario, title: null);
    return (
      name: scenario.substring(0, open),
      title: scenario.substring(open + 2, close),
    );
  }

  /// The parenthetical half of the scenario, or null. See [_scenarioParts].
  String? get _characterTitle => _scenarioParts.title;

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

  /// How many turns of the opening script this conversation actually got
  /// through — the frontier [_setQuickReplyIndex] refuses to walk past while
  /// the script is unfinished.
  ///
  /// The moment the visitor speaks, the rest of the script is dropped and never
  /// said. Its later quick replies are written as answers to those unsaid
  /// turns, so advancing into them puts words in the visitor's mouth about a
  /// conversation that did not happen: interrupt Odysseus at turn 2 and the
  /// strip would offer "Courage." / "Cleverness." — a reply to a captain's
  /// question he never asked. Once someone is talking, the chat is theirs and
  /// the script has nothing further to say about it.
  ///
  /// Only a *finished* script releases the frontier, which is what lets
  /// Calypso's sets 10-16 keep walking: they are an arc past her script rather
  /// than answers to it.
  int _scriptPausesReached = 0;

  /// Ceilings on the welcome sequence's simulated typing, in milliseconds.
  static const int _openerTypingCapMs = 2200;
  static const int _followUpTypingCapMs = 1200;

  /// How long a beat of a scripted opening takes.
  ///
  /// [msPerWord] is the main pacing dial: raise it to slow the whole script
  /// down, lower it to speed it up. A flat interval was the first attempt and
  /// it was wrong — "Those make better songs." and a thirty-word sentence about
  /// the sea got the same one second each, so the short beats felt spat out and
  /// the long ones were gone before they could be read. Time per word keeps a
  /// short line snappy and gives a long one room, which is also just how a
  /// person types.
  ///
  /// [baseMs] is the fixed cost on every beat, for the pause between one line
  /// and the next that has nothing to do with how long either is. [minMs] and
  /// [maxMs] are the floor and ceiling: the floor stops a two-word line
  /// snapping past unread, the ceiling stops the single longest sentence
  /// stalling the script.
  ///
  /// 260ms/word is roughly half of unhurried reading speed: fast enough to
  /// feel live, slow enough to follow. This is what a script gets unless it
  /// asks for something else.
  static const _ScriptPacing _readablePacing =
      (msPerWord: 260, baseMs: 400, minMs: 900, maxMs: 4500);

  /// Roughly 40% faster, for a script whose source document sets a target for
  /// how soon it has to reach a question rather than for how comfortably it
  /// reads.
  ///
  /// The document asks for the first question within 5–8s and another roughly
  /// every 5–8s after it, on the production finding that v1 waited too long to
  /// invite anyone to participate. At [_readablePacing] Odysseus v2 reaches its
  /// first question at 10.0s and the rest 12.6–18.1s apart, so the opening
  /// target is missed outright. These numbers reach it at 6.2s.
  ///
  /// The 5–8s *repeat* target is not met and cannot be, which is worth knowing
  /// before anyone tunes this further: the later questions land 9.2–12.4s
  /// apart. 3s of every gap is the document's own `pause_after_seconds`, and
  /// what remains is a four-to-five bubble turn, so hitting 5–8s end to end
  /// would mean roughly a second per bubble — back to the flat interval this
  /// scheme was written to replace, with the long sentences going past unread.
  /// Cutting bubbles from the turns, not speeding them up, is what would
  /// actually close that gap.
  static const _ScriptPacing _briskPacing =
      (msPerWord: 150, baseMs: 300, minMs: 700, maxMs: 2800);

  /// Scripts paced to a question cadence rather than to unhurried reading.
  ///
  /// Per character rather than global because the two scripts want opposite
  /// things: Calypso is an immortal with nowhere to be and her document makes
  /// silence comfortable on purpose, so speeding her up would be undoing her
  /// design, not fixing it.
  static const Set<String> _briskScriptCharacters = {'odysseus'};

  _ScriptPacing get _scriptPacing =>
      _briskScriptCharacters.contains(widget.characterId)
          ? _briskPacing
          : _readablePacing;

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

  /// The in-flight [_loadHistory], which is the only thing that ever builds
  /// [_aiService] — and does so behind two awaits on storage. Anything that
  /// needs the service has to wait for this rather than read the field and
  /// give up when it is still null, which is what [_handleSend] used to do.
  Future<void>? _historyLoaded;

  /// One-shot guard for [ChatScreen.initialMessage], so a rebuild of the route
  /// cannot send the same opener a second time.
  bool _openerSent = false;

  /// The claim screen: what it is showing, and what the entry tap deferred
  /// until it is dismissed.
  ///
  /// Non-empty [_claimedGrants] is what puts the screen up — it is filled from
  /// takeGrants, which is consume-once, so the screen cannot reappear for the
  /// same coins. [_claimResumeOpening] carries the decision _enterChat had
  /// already made about whether the opening should play, so dismissing the
  /// screen resumes exactly what the tap would have done.
  List<CoinGrant> _claimedGrants = const [];
  int _claimBalance = 0;
  bool _claimResumeOpening = false;

  /// Tribute ids whose ♥ bonus has already been credited. The server charges
  /// once per id (that is the whole idempotency design), so the meter follows
  /// the same rule: a retried tribute that finally lands scores once.
  final Set<String> _scoredTributeIds = {};

  /// Gift rewards already sent in this conversation, keyed "<character>:<item>".
  /// Sent once rather than every time: the photograph is the same photograph,
  /// and receiving it twice in a row reads as the app repeating itself rather
  /// than the character being pleased.
  final Set<String> _sentGiftRewards = {};

  /// A reward photograph waiting for the current reply to finish speaking.
  String? _pendingGiftReward;

  /// True while the claim grant is in flight, so a second tap on the entry
  /// card during the round trip cannot fire a second entry_tap or a second
  /// (idempotent, but wasteful) grant.
  bool _claimInFlight = false;

  /// Successful AI replies this signed-out user has received from this
  /// character (persisted, per character). Drives the free-reply gate.
  int _replyCount = 0;

  /// The signed-in app user id, read once and held.
  ///
  /// Every funnel event used to be logged inside
  /// `SharedPreferences.getInstance().then(...)`, purely to read this one
  /// string — eight call sites, none with an error path. On web SharedPreferences
  /// is localStorage, and an in-app browser with restricted storage rejects that
  /// future, so the `.then` never ran and the event was silently dropped. That is
  /// the worst possible failure for a funnel: `character_tap` is what classifies
  /// a visit as having reached the chat screen, so losing it makes an engaged
  /// visitor indistinguishable from one the app never delivered to — in exactly
  /// the browser that is most of the traffic.
  ///
  /// Read once here, used synchronously everywhere else. An event that fires
  /// before this resolves carries a null id, which is the right trade: visit_id
  /// is what the funnel actually joins on, and an event with no app user id is
  /// worth incomparably more than no event.
  String? _appUserId;

  /// Asks [DeliveryLog] for the id rather than reading storage directly, and
  /// the difference is not cosmetic. This used to be a plain read, and on a
  /// fresh device it ran before anything had created the id — [initState]
  /// starts [DeliveryLog.init] first, but this call's `getInstance()` resolves
  /// ahead of it, because a second waiter on an in-flight future is woken
  /// before the first one's own `await` continues. So the read found nothing,
  /// never looked again, and every funnel event of a first-time visitor went
  /// out with no user id — 92% of screen_ping rows live, and 100% of
  /// character_tap. Creating the id if it is missing makes the answer the same
  /// whichever caller gets there first.
  Future<void> _loadAppUserId() async {
    final id = await DeliveryLog.userId();
    if (!mounted) return;
    _appUserId = id;
  }

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
  String get _characterDisplayName => _scenarioParts.name;

  @override
  void initState() {
    super.initState();
    _textController.addListener(_onDraftChanged);
    // Lifecycle drives two things: whether a bubble on screen counts as seen,
    // and the last-chance flush when the visitor leaves.
    WidgetsBinding.instance.addObserver(this);
    // Picks up any receipts stranded by a previous run and tries them again.
    // Those are the valuable ones — a queue that survived a reload is usually a
    // queue that could not be delivered.
    DeliveryLog.instance.init();
    // Held, not just started: the opener and any early send wait on this rather
    // than reading _aiService and giving up while it is still null.
    _historyLoaded = _loadHistory();
    _loadReplyCount();
    // Track active character
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Refresh auth status in case the user just returned from an OAuth
      // redirect back into this chat.
      //
      // In the post-frame callback rather than directly in initState, where it
      // used to sit: refresh() assigns to the provider's state synchronously,
      // and Riverpod asserts against a provider being modified during a widget
      // life-cycle. It is an assert, so release builds never saw it, but every
      // debug run logged the error and it failed any widget test that mounted
      // this screen. A frame later is soon enough for something that exists to
      // catch an OAuth return.
      ref.read(authProvider.notifier).refresh();

      // Resolve the app user id BEFORE the funnel events, but bounded.
      //
      // character_tap fires once, here, and never again this session — unlike
      // screen_ping, which fires on a timer and so picks up the id on a later
      // tick. Fired synchronously it was raced by _loadAppUserId every time on
      // a fresh device (the id is minted by storage this same frame), so 100%
      // of live character_tap rows carried no app_user_id — which silently
      // limited the bounce->transcript join (migration 0006) to visitors who
      // already had an id from an earlier session.
      //
      // The await is what fixes it; the timeout is what preserves the original
      // guarantee this comment used to make — that a hung or rejecting storage
      // can never hold the funnel hostage. _loadAppUserId swallows its own
      // errors, so this only ever waits out the timeout, and on timeout the id
      // is null and the events fire anyway, exactly the old behaviour for the
      // broken-storage case. On the normal path storage answers in a few ms.
      await _loadAppUserId().timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
      if (!mounted) return;

      _openCharacter();

      // An opener tapped on the profile card before entering the chat. Sent
      // through _handleSend so it behaves exactly like a typed message —
      // same reply gate, history and logging.
      _sendInitialMessage();
    });
  }

  /// Everything that marks a character as opened, done once per character
  /// rather than once per screen.
  ///
  /// This used to live inline in initState, on the reasoning that initState
  /// runs once per screen so nothing needed a guard. True, and beside the
  /// point: the chat branch keeps this State alive in the shell's indexed
  /// stack, so opening a second character from the dashboard arrives through
  /// didUpdateWidget on the SAME State — and initState never runs again. Every
  /// per-character setup below was therefore skipped for the second character
  /// in a session: no character_tap row (the per-character funnel undercounted
  /// every switched-to character), activeChat left naming the previous one
  /// (so the retention notification was titled with the wrong name), and the
  /// screen ping never restarted.
  ///
  /// Called from both paths now, so they cannot drift apart again.
  void _openCharacter() {
    ref
        .read(activeChatProvider.notifier)
        .setActive(widget.scenario ?? 'Unknown', _currentVibe);

    // Funnel: a character is open. Fired here rather than from the dashboard
    // card tap, because a /c/<id> campaign link opens this screen directly
    // (app.dart's '/c/:characterId' route) and never touches a card — so
    // reporting it there made "opened a character" read 0% for exactly the
    // traffic the campaign links bring in, no matter how well they converted.
    logFunnelEvent(
      'character_tap',
      detail: widget.characterId,
      appUserId: _appUserId,
    );
    // The strip's opening set. _quickReplyIndex starts at 0 without going
    // through _setQuickReplyIndex, so the first thing a visitor is offered
    // is the one offer that would otherwise never be recorded — and it is
    // the offer nearly everyone sees, since most leave before the strip
    // ever changes.
    if (_quickRepliesFor(widget.characterId) != null) {
      logFunnelEvent(
        'strip_rotate',
        detail: '${widget.characterId}#0',
        appUserId: _appUserId,
      );
    }
    _startScreenPing();
  }

  /// Puts every piece of per-conversation state back to what a freshly built
  /// screen would have, ahead of loading another character into this one.
  ///
  /// The "Full Reset on Scenario Change" in didUpdateWidget cleared exactly
  /// three things — the messages, the service and the opener guard — and left
  /// everything else describing the character just left. Each survivor was a
  /// bug of its own:
  ///
  ///   _entryGateActive        the card, still up, now over the NEW character's
  ///                           restored conversation; tapping it replayed the
  ///                           opening into that history and logged an
  ///                           entry_tap with no entry_shown to pair it with
  ///   _replyCount             20/20 with one character meant the login gate
  ///                           fired on the FIRST message to the next, and a
  ///                           login_gate row was logged for a character with
  ///                           zero messages — the stored per-character count
  ///                           was right, only the in-memory copy was stale
  ///   _loggedTyping,          one-shot funnel guards, so the second character
  ///   _sentFirstMessage,      in a session got no input_typed, no
  ///   _gateShownLogged        first_message and no gate_shown row at all
  ///   _idleNudges,            the nudge budget and the strip position carried
  ///   _quickReplyIndex,       over, so a conversation could start already out
  ///   _scriptPausesReached    of nudges or with the strip on turn nine
  ///
  /// The screen ping and idle timer are stopped here and restarted by
  /// [_openCharacter] and the opening respectively, so a switch mid-nudge does
  /// not deliver the old character's nudge into the new conversation.
  ///
  /// _userHasSent IS reset, and the test that switches from a spoken-to
  /// character to a fresh one is why: _loadHistory only assigns it on the
  /// non-empty branch, so a fresh character after a spoken one inherited
  /// `true` and lost its card. _hasDraft follows the text controller, which
  /// is shared across characters on purpose (a half-typed message survives a
  /// switch).
  void _resetForNewCharacter() {
    _cancelIdleTimer();
    _stopScreenPing();
    _welcomeAbandoned = true; // stops any script parked mid-burst
    _welcomeRun++;
    setState(() {
      _messages.clear();
      _aiService = null;
      _isTyping = false;
      _userHasSent = false;
      _entryGateActive = false;
      _entryGateStartsOpening = true;
      _gateActive = false;
      _gateShownLogged = false;
      _loggedTyping = false;
      _sentFirstMessage = false;
      _idleNudges = 0;
      _quickReplyIndex = 0;
      _scriptPausesReached = 0;
      _replyCount = 0; // reloaded below from the new character's stored count
    });
    // The ping counts up to a cap and stops for good; carried over, the second
    // character's dwell measurement would start where the first one ended and
    // could hit the cap on its first tick.
    _screenPingTicks = 0;
    _openerSent = false;
    _scoredTributeIds.clear();
    _sentGiftRewards.clear();
    // Per-conversation, like everything else here: one State is reused across
    // characters, and a claim left standing would cover the next one's chat.
    _claimedGrants = const [];
    _claimResumeOpening = false;
    _claimInFlight = false;
  }

  /// Sends [ChatScreen.initialMessage]: the opener tapped on a profile card's
  /// "Ask Me About", or one carried on a /c/<id>?initialMessage= link.
  ///
  /// Waits on [_historyLoaded] rather than sending straight from the first
  /// post-frame callback, which is what it used to do. _loadHistory is
  /// asynchronous and is the only thing that builds [_aiService], so on a cold
  /// load the send got there first: the user's bubble was drawn and saved, the
  /// typing indicator came on, and _handleSend then hit a null service and
  /// returned without ever calling the API — leaving the indicator spinning
  /// under a message that was never answered. Every arrival from a campaign
  /// link took that path, since nothing is cached on a first visit.
  ///
  /// It also raced the history read that was still in flight, which is the
  /// other half of the report: the read could come back holding the bubble
  /// that had just been saved and append it a second time (see the merge in
  /// [_loadHistory], which now drops what is already on screen).
  Future<void> _sendInitialMessage() async {
    final opener = widget.initialMessage?.trim();
    if (opener == null || opener.isEmpty) return;
    if (_openerSent) return;
    // Set before the await, so a rebuild that re-enters here while the load is
    // still running cannot start a second send.
    _openerSent = true;

    await _historyLoaded;
    if (!mounted) return;

    // On the web the opener stays in the address bar, so a reload re-runs this
    // against a conversation that already holds the question — and would ask
    // it again on every refresh. The history has just been merged in above, so
    // this can see it and stand down.
    //
    // Not narrowed to "asked and answered": re-sending would post a second
    // identical bubble, which is the thing this screen should never do, and a
    // question left unanswered is one tap of the quick-reply strip away from
    // being asked again deliberately.
    if (_messages.any((m) => m.isUser && m.text.trim() == opener)) return;

    _textController.text = opener;
    await _handleSend();
  }

  @override
  void dispose() {
    // Neither of these was being disposed before; the controller has leaked
    // on every chat close since the screen was written.
    _cancelIdleTimer();
    _screenPingTimer?.cancel();
    _entryGateScrollController.dispose();
    _textController.removeListener(_onDraftChanged);
    _textController.dispose();
    _inputFocus.dispose();
    WidgetsBinding.instance.removeObserver(this);
    // Leaving the chat is the last moment a bubble drawn a second ago can still
    // be reported. Not awaited — dispose cannot wait — but the receipts are
    // already on disk, so the worst case is that they go out on the next run.
    //
    // Then stand the queue down: with no chat screen left, a pending retry has
    // nothing to serve that the next launch will not pick up anyway.
    DeliveryLog.instance.flush();
    DeliveryLog.instance.stop();
    _surfaceChanged.dispose();
    super.dispose();
  }

  /// Foreground/background, which on web is the browser tab becoming hidden or
  /// visible.
  ///
  /// Two jobs. A bubble painted into a hidden tab must not count as seen, so the
  /// detectors are told to re-evaluate. And going away is the point at which
  /// queued receipts are most likely to be lost, so they are flushed — a tab
  /// being hidden is very often a tab about to be closed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final visible = state == AppLifecycleState.resumed;
    if (visible == _surfaceVisible) return;
    _surfaceVisible = visible;
    _surfaceChanged.value++;
    if (!visible) DeliveryLog.instance.flush();
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
  /// pay the full run.
  ///
  /// The cadence used to be justified by D1's free-tier ceiling of 100k writes
  /// a day, which a flat 500ms would have reached at around 1,600 visits. That
  /// figure no longer applies: this project is on Workers Paid, where the
  /// allowance is ~50M rows a month and overage bills rather than stops. At 78
  /// ticks a visit that is roughly 19,000 visits a day before the included
  /// allowance is touched, against about a hundred today.
  ///
  /// So the cadence is now shaped by what the data is worth rather than by what
  /// it costs: half-second resolution through the window where visitors
  /// actually leave, one second while the script is still asking, and three
  /// seconds across the long tail where the only question is whether they are
  /// still there at all.
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
  static const Duration _screenPingPhase2Interval = Duration(seconds: 1);
  static const Duration _screenPingPhase3Interval = Duration(seconds: 3);
  static const int _screenPingPhase1Ticks = 30; // 30 x 500ms = first 15s
  static const int _screenPingPhase2Ticks = 50; // + 20 x 1s   = 35s
  static const int _maxScreenPingTicks = 78; // + 28 x 3s  = 119s

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
    // detail carries how far the script had got when this tick fired, as
    // "<character>#t<turns delivered>#s<set on the strip>".
    //
    // Without it a tick count only says *when* someone left, and turning that
    // into *what they were looking at* means replaying the pacing arithmetic
    // offline against the script as it is written today — see tool/beat_map.mjs,
    // which exists to do exactly that and is wrong the moment anyone edits a
    // line or retunes _briskPacing. Recording the position instead makes every
    // tick self-describing and costs no extra rows, which matters: the split
    // cadence above exists because a flat 500ms would spend the D1 write quota
    // during a boost.
    //
    // It also survives the thing the offline replay cannot. A backgrounded tab
    // is throttled to roughly 1Hz, so both the ticks and the script's own
    // Future.delayed chain stretch — but not necessarily together, and an
    // inferred position drifts apart from the real one exactly when the visitor
    // was distracted. A logged position is whatever was actually on screen.
    final position =
        '${widget.characterId}#t$_scriptPausesReached#s$_quickReplyIndex';
    logFunnelEvent(
      'screen_ping',
      detail: position,
      appUserId: _appUserId,
    );
    // Step down the cadence at each phase boundary. The timer is replaced
    // rather than left running and skipped, so the device stops waking more
    // often than it needs to.
    if (_screenPingTicks == _screenPingPhase1Ticks) {
      _screenPingTimer?.cancel();
      _screenPingTimer =
          Timer.periodic(_screenPingPhase2Interval, _onScreenPingTick);
    } else if (_screenPingTicks == _screenPingPhase2Ticks) {
      _screenPingTimer?.cancel();
      _screenPingTimer =
          Timer.periodic(_screenPingPhase3Interval, _onScreenPingTick);
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

    // A keystroke answers the gate as surely as a tap does. Released on the
    // first character rather than on the send, deliberately: the question being
    // measured is whether people are willing to engage, and someone who typed
    // three words and thought better of it has answered it. Holding the gate
    // until _handleSend would count them with the visitors who did nothing.
    _releaseGate('typed');

    if (_loggedTyping) return;
    _loggedTyping = true;
    _stopScreenPing();
    logFunnelEvent(
      'input_typed',
      detail: widget.characterId,
      appUserId: _appUserId,
    );
  }

  /// Raises the interaction gate on a conversation that is starting fresh.
  ///
  /// Called where the welcome sequence is triggered, so the two share one
  /// condition — a truly empty history — rather than drifting apart.
  ///
  /// Skipped when [ChatScreen.initialMessage] is set. Those arrivals carry the
  /// visitor's question in the URL and it is sent on their behalf, so there is
  /// no choice left to offer and a gate would only stand between them and the
  /// answer they followed a link for. Keeping them out matters for the
  /// arithmetic as much as the experience: 8 of the 56 first messages in the 30
  /// days to 2026-08-17 were auto-sent like this, and counting them would
  /// credit the gate with taps that no hand made.
  /// Puts the entry card up, or reports that it was skipped.
  ///
  /// Returns true if the caller must hold the opening back. The welcome
  /// sequence is the caller's to start precisely because of this: a script that
  /// began here would be declaring bubbles to the delivery log behind a card
  /// nobody has moved yet.
  bool _raiseEntryGate() {
    if (!AppConfig.requireTapToEnter) return false;
    if (_userHasSent) return false;
    // Same exclusion as the story freeze: an opener link carries the visitor's
    // question and sends it for them, so a card demanding a tap first would
    // stand between them and the answer they followed the link for.
    if ((widget.initialMessage ?? '').trim().isNotEmpty) return false;
    setState(() => _entryGateActive = true);
    // The denominator for the low bar. Its duration_ms is time from arrival, so
    // this row also says how quickly the one tappable thing on the screen got
    // there — the number that decides whether a rate means anything on traffic
    // half of which is gone by 3s.
    //
    // Logged after the frame that paints the card, not at raise: whether the
    // button landed inside the first viewport is only knowable once the
    // card's scroll view has laid out, and #fold is the half of this row that
    // can finally separate a short-screen visitor who declined from one who
    // never had the button on screen. Costs the row one frame of duration_ms.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final scroll = _entryGateScrollController;
      final below = scroll.hasClients && scroll.position.maxScrollExtent > 0;
      logFunnelEvent(
        'entry_shown',
        detail: '${widget.characterId}#fold=${below ? 'below' : 'fit'}',
        appUserId: _appUserId,
      );
    });
    return true;
  }

  /// The visitor came in. Starts everything the card was holding.
  ///
  /// [source] is how they entered — 'button' for the card's own button,
  /// 'profile' for someone who opened the profile and picked a question from
  /// it. Both are entries and both belong in the numerator; which route they
  /// took is worth knowing separately, because one of them means the profile
  /// did the persuading.
  ///
  /// [startOpening] is false when the visitor arrives already having said
  /// something. Playing the scripted opening underneath their own question
  /// would have the character introduce himself after being asked something
  /// specific, and would declare a turn's worth of bubbles to the delivery log
  /// that the send is about to abandon anyway.
  Future<void> _enterChat({String source = 'button', bool startOpening = true}) async {
    if (!_entryGateActive || _claimInFlight) return;
    logFunnelEvent(
      'entry_tap',
      detail: '${widget.characterId}#$source',
      appUserId: _appUserId,
    );
    // Nothing to start over a monologue that is already on screen — see
    // _entryGateStartsOpening. The visitor was still gated and still counted;
    // they simply resume the conversation from where the old bundle left it.
    final shouldOpen = startOpening && _entryGateStartsOpening;

    // THE GRANT HAPPENS HERE, on the tap — never at app load. Gated on the
    // SAME wallet-enabled truth as the button label, so this only claims when
    // the button actually said "Tap to Claim Coins"; when it said "Tap to
    // Talk" (coins off, or the wallet not yet read) the tap grants nothing.
    // claim() calls POST /api/wallet/sync now — app start only ever did a
    // read-only fetch. A fresh visitor gets their coins and the claim screen;
    // a returning visitor with nothing pending gets an empty list and drops
    // straight into the conversation. Awaited so the grant is real before we
    // decide whether to raise the claim screen; the entry card stays up for
    // the brief round trip rather than flashing an empty screen.
    if (AppConfig.coinsUiEnabled &&
        (ref.read(coinWalletProvider).value?.enabled ?? false)) {
      _claimInFlight = true;
      List<CoinGrant> claimed;
      try {
        claimed = await ref.read(coinWalletProvider.notifier).claim();
      } finally {
        _claimInFlight = false;
      }
      if (!mounted) return;
      if (claimed.isNotEmpty) {
        setState(() {
          _entryGateActive = false;
          _claimedGrants = claimed;
          _claimBalance = ref.read(coinWalletProvider).value?.balance ?? 0;
          _claimResumeOpening = shouldOpen;
        });
        logFunnelEvent(
          'claim_shown',
          detail: '${widget.characterId}#'
              '${claimed.fold<int>(0, (sum, g) => sum + g.delta)}',
          appUserId: _appUserId,
        );
        // Deliberately no _raiseGate/_triggerWelcomeSequence here: the claim
        // screen covers the conversation, and the same rule the entry card is
        // built on applies to it — not a line is spoken to a screen nobody is
        // looking at. _dismissCoinClaim resumes both.
        return;
      }
    }

    if (!mounted) return;
    setState(() => _entryGateActive = false);
    if (!shouldOpen) return;
    // Only now does the character have an audience, so only now is anything
    // declared to the delivery log or spoken.
    _raiseGate();
    _triggerWelcomeSequence();
  }

  /// Leaves the claim screen and starts the conversation the entry tap
  /// deferred.
  void _dismissCoinClaim() {
    if (_claimedGrants.isEmpty) return;
    logFunnelEvent(
      'claim_tap',
      detail: '${widget.characterId}#'
          '${_claimedGrants.fold<int>(0, (sum, g) => sum + g.delta)}',
      appUserId: _appUserId,
    );
    final resume = _claimResumeOpening;
    setState(() {
      _claimedGrants = const [];
      _claimResumeOpening = false;
    });
    if (!resume) return;
    _raiseGate();
    _triggerWelcomeSequence();
  }

  void _raiseGate() {
    if (!AppConfig.requireInteractionToContinue) return;
    if (_gateActive || _userHasSent) return;
    if ((widget.initialMessage ?? '').trim().isNotEmpty) return;
    setState(() => _gateActive = true);
    if (_gateShownLogged) return;
    _gateShownLogged = true;
    // The denominator. Its duration_ms comes from the beacon and is measured
    // from arrival, so "was this even on screen before they left" is answerable
    // by joining this row against the visit's leave.
    logFunnelEvent(
      'gate_shown',
      detail: widget.characterId,
      appUserId: _appUserId,
    );
  }

  /// Lowers the gate because the visitor answered it.
  ///
  /// [source] is 'tap' or 'typed' — which of the two routes into a conversation
  /// people actually take, asked of the population that was demonstrably
  /// offered both. input_typed and starter_tap already split this, but against
  /// a denominator of everyone who ever loaded the screen; this one is against
  /// people who were looking at an unanswered question.
  void _releaseGate(String source) {
    if (!_gateActive) return;
    setState(() => _gateActive = false);
    logFunnelEvent(
      'gate_choice',
      detail: '${widget.characterId}#$source',
      appUserId: _appUserId,
    );
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
      // Another character, same State: everything initState did per
      // character has to happen again here, in the same order.
      _resetForNewCharacter();
      _historyLoaded = _loadHistory();
      _loadReplyCount();
      // Post-frame for the same reason initState defers it: _openCharacter
      // writes to activeChatProvider, and Riverpod asserts against modifying
      // a provider during a widget life-cycle — didUpdateWidget included. The
      // assert is debug-only, so release builds never saw it, but it fails
      // any widget test that switches character.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _openCharacter();
        _sendInitialMessage();
      });
      return;
    }

    // Same character, different opener: the chat branch keeps its state in the
    // shell's indexed stack, so going to /c/<id>?initialMessage=... a second
    // time — picking another question off the same profile card — updates this
    // widget instead of building a new one, and initState never runs again.
    // Guarded on the value having actually changed, so an ordinary rebuild
    // carrying the same URL sends nothing.
    if (oldWidget.initialMessage != widget.initialMessage) {
      _openerSent = false;
      _sendInitialMessage();
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
        // Calypso from the Odyssey?" again. Approximate by design — the index
        // is not persisted, so this reconstructs it from what the history can
        // actually show: the pauses the script got through, plus one for each
        // exchange since.
        //
        // It used to assume the whole script had run, on the reasoning that a
        // script only plays into an empty chat so any history means it
        // finished. That is wrong whenever someone closes the tab part-way
        // through one — the script does not resume on their next visit, so
        // their history holds two bubbles and the strip was jumping to the
        // last set in the list. Calypso hid it (her last set, about the sea,
        // is vague enough to survive landing early); Odysseus would not have,
        // since his is "Then I'm glad I stopped here." under a chat where he
        // has said "Well now..." and nothing else.
        final sets = _quickRepliesFor(widget.characterId);
        final spoken = history.where((m) => m.isUser).length;
        final scriptPauses = _scriptPausesIn(history);
        setState(() {
          // In front of anything already on screen, and minus anything that is
          // already there. A send can beat this read home — a starter prompt
          // tapped in the first moments, or the opener before it was chained
          // off this future — and _addMessage saves as it draws, so the history
          // that comes back can hold that same bubble. Appending it blind is
          // how one message came back as two identical ones.
          final shown = _messages.map((m) => m.id).toSet();
          _messages.insertAll(
            0,
            history.where((m) => !shown.contains(m.id)),
          );
          // A conversation they have already spoken in doesn't need the
          // first-message scaffolding put back in front of it on every return.
          _userHasSent = _messages.any((m) => m.isUser);
          // Carries the frontier across the reload too, so a visitor who
          // interrupted the script and came back does not get the sets it
          // stopped them seeing simply because the counter started over.
          _scriptPausesReached = scriptPauses;
          // There is history, so the script will not run on this screen — the
          // welcome sequence is only triggered into an empty chat. Saying so
          // is what lets _setQuickReplyIndex tell a part-heard script from one
          // that is still playing.
          _welcomeAbandoned = true;
        });
        // After the frontier is set, so it can be read here. Left to
        // _setQuickReplyIndex rather than assigned directly: it owns the
        // skipping rule, and a second copy of it is how the two would drift.
        if (sets != null) _setQuickReplyIndex(scriptPauses - 1 + spoken);
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

      // The card comes up for anyone who has never spoken here, empty history
      // or not. It used to require an empty history, which was too narrow by
      // roughly nine to one on the first night: 45 Instagram visits reached a
      // chat screen and 5 saw the card. Devices still serving the 1.7.0 bundle
      // auto-play the monologue, and that writes the character's lines into
      // localStorage — so once those devices update, history is not empty and
      // the card never came up, for a visitor who has never engaged. The
      // measurement was silently limited to fresh devices.
      //
      // _userHasSent is the visitor's side of that history and the actual
      // question the card asks. Restored from storage above, so a returning
      // visitor who did speak is still not gated.
      //
      // The opening itself is still only started into a TRULY empty chat, in
      // _enterChat: a card over an existing monologue must not replay it.
      if (!_userHasSent) {
        _entryGateStartsOpening = history.isEmpty;
        // The entry card comes first and holds everything else back until it
        // is tapped; _enterChat starts the two lines below itself.
        if (!_raiseEntryGate() && history.isEmpty) {
          // Before the sequence, not after it: the prompts are static content
          // and there is no reason to withhold them behind a paced greeting.
          // Calypso's first turn alone lands its last bubble ~2.6s in ("Hello."
          // clamps to 900ms, "I'm genuinely glad you came." earns 1700ms), on
          // top of a ~2s median paint for QR traffic — and half that cohort is
          // gone by 3s. Raising the gate here is what puts something tappable
          // on screen inside the window where anyone is still watching. The
          // story still waits; only the offer is early.
          _raiseGate();
          _triggerWelcomeSequence();
        }
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
        // Corrupt history was discarded, so this really is a fresh chat.
        _entryGateStartsOpening = true;
        if (!_raiseEntryGate()) {
          _raiseGate();
          _triggerWelcomeSequence();
        }
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

  /// How many turns of this character's opening script are present in
  /// [history] — that is, how many of its pause points the visitor actually
  /// reached before whatever ended the script.
  ///
  /// A turn counts once its LAST line is in the history, which is the moment
  /// [_playOpeningScript] treats as that turn's pause. Matching on text is
  /// what makes this work across a reload: message ids are timestamps, so
  /// there is nothing else in a stored message tying it back to the script.
  ///
  /// Returns 0 for a character with no script, and for any chat old enough to
  /// predate the script it opens with — both of which want the strip at the
  /// start of the list rather than the end of it.
  int _scriptPausesIn(List<ChatMessage> history) {
    final script = _openingScriptFor(widget.characterId);
    if (script == null) return 0;
    final said = history
        .where((m) => !m.isUser && !m.isSystem)
        .map((m) => m.text)
        .toSet();
    var pauses = 0;
    for (final segment in script) {
      if (said.contains(segment.lines.last)) pauses++;
    }
    return pauses;
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
    if (characterId == 'odysseus') return _odysseusOpeningScript;
    if (characterId == 'hercules') return _herculesOpeningScript;
    return null;
  }

  /// Whether this character opens with a script rather than the single
  /// question everyone else opens with.
  ///
  /// Gates the behaviour that only a script needs, so adding an opening for
  /// Calypso and then Odysseus changed nothing for anyone else. They keep the
  /// one-bubble
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

  /// Odysseus's scripted opening — "Odysseus Conversation Script v2",
  /// 2026-08-10. Its twelve pause points are the twelve segments below, in
  /// order, and their `pause_id`s are ODY2_P01..P12.
  ///
  /// This replaced v1 outright rather than sitting beside it. v1's shape was a
  /// man telling you about himself for ninety seconds and asking three
  /// questions along the way; v2's is a man who asks something easy in the
  /// first breath and spends the rest of the script getting the visitor to talk
  /// about her own life. Every one of the twelve turns now ends on a question
  /// to her, which is the entire point of the revision — the document's stated
  /// production finding is that v1 waited too long to invite participation.
  ///
  /// Same shape as [_calypsoOpeningScript]: one string per bubble, `pauseMs`
  /// from the document's `pause_after_seconds`.
  ///
  /// Three of the document's four per-pause flags have no field here because
  /// the player already guarantees them for every script: `continue_if_silent`
  /// is what [_playOpeningScript] does by default, `interrupt_on_user_input` is
  /// the abandon check it runs after every await, and `show_quick_replies` is
  /// the strip, which for a scripted character is on screen from the first
  /// frame and never retires. All three are true for all twelve pauses, so
  /// nothing is lost by not storing them.
  ///
  /// The document's timing rules — first question in 5–8s, another every 5–8s
  /// while the visitor stays quiet — are not met by the pacing the rest of the
  /// scripts use, which is why he is in [_briskScriptCharacters]. See
  /// [_briskPacing] for what that buys and where it still falls short.
  ///
  /// He opens by talking, like Calypso and unlike everyone else — but for the
  /// opposite reason. Hers is an immortal with nowhere to be; his is a man who
  /// introduces himself before you can ask, because being underestimated has
  /// never once been his problem.
  static const List<({List<String> lines, int pauseMs})>
      _odysseusOpeningScript = [
    // 1 — ODY2_P01. The question is in the opening turn now; in v1 it was the
    // third, a minute in.
    (
      pauseMs: 2500,
      // Three bubbles, not five. Measured against 74 chat opens, 51% of
      // visitors left before this turn's question arrived at 6.3s — the median
      // stay on the chat screen was 5.5s, so half the audience was gone one
      // beat before being asked anything at all.
      //
      // _briskPacing was already tuned for this and hits its own 6.2s target;
      // the target was simply set later than people stay. The fix is fewer
      // bubbles rather than faster ones, which is what the pacing comment
      // itself concluded — past a point, speeding up just means long sentences
      // go by unread.
      //
      // 'Well now...' went because it is throat-clearing: it costs a beat and
      // says nothing, in the one window where every beat is expensive. The
      // 'old stories' line went as a bubble but not as a thought — it is what
      // makes 'What have you heard?' a fair question rather than a non-sequitur,
      // so it is folded into the question's own bubble instead of deleted.
      lines: [
        "I wasn't expecting company.",
        "I'm Odysseus — sailor, king of Ithaca, occasional troublemaker.",
        'You may already have an opinion of me. What have you heard?',
      ],
    ),
    // 2 — ODY2_P02
    (
      pauseMs: 3000,
      lines: [
        'No verdict yet? Fair enough.',
        'People have been arguing about me for three thousand years. You '
            'deserve at least a few seconds.',
        'Let me make it easier:',
        'Would you rather hear about a monster, a beautiful island... or one '
            'of my truly terrible decisions?',
      ],
    ),
    // 3 — ODY2_P03. He answers his own question so a silent visitor still gets
    // the story, which is the pattern for every choice he offers.
    (
      pauseMs: 3000,
      lines: [
        "Captain's privilege, then. I'll choose the terrible decision.",
        'There are, unfortunately, quite a few candidates.',
        "I've learned something since those days: the choices we regret often "
            'become the stories that teach us the most.',
        'Have you ever made a decision that looked foolish at the time but '
            'changed your life for the better?',
      ],
    ),
    // 4 — ODY2_P04
    (
      pauseMs: 3000,
      lines: [
        "Ah, now we're getting somewhere.",
        'I spent years believing courage meant charging forward.',
        'Age taught me that sometimes courage is leaving, starting again, '
            'changing your mind... or admitting that the life you planned '
            "isn't the life you want.",
        'Which are you better at — starting something new, or knowing when '
            "it's time to let something go?",
      ],
    ),
    // 5 — ODY2_P05
    (
      pauseMs: 3000,
      lines: [
        'That question would have confused the younger me.',
        'I was very good at leaving.',
        'Getting home was another matter.',
        'For twenty years I thought about Ithaca — not because it was the '
            "grandest place I'd seen, but because it was mine.",
        "Is there a place that feels like home to you, even if you don't "
            'live there now?',
      ],
    ),
    // 6 — ODY2_P06
    (
      pauseMs: 3000,
      lines: [
        "That's one thing humans and heroes seem to share: places become "
            'tangled up with people and memories.',
        'Sometimes I can remember a harbor more clearly because of one '
            'conversation I had there than because of anything I saw.',
        "What's a place you still think about?",
      ],
    ),
    // 7 — ODY2_P07
    (
      pauseMs: 3000,
      lines: [
        'I like that question because travel reveals people.',
        'Some want an itinerary. Some want a road and no plan at all.',
        'I was very much the second kind... which explains several monsters.',
        'When you travel, are you the planner or the one who says, '
            '“Let\'s see what happens”?',
      ],
    ),
    // 8 — ODY2_P08
    (
      pauseMs: 3000,
      lines: [
        'A little unpredictability is healthy.',
        'Too much and you end up tied to the mast of your own ship while '
            'Sirens sing at you.',
        'Long story.',
        'What kind of adventure would tempt you today — somewhere beautiful, '
            'somewhere completely new, or simply good company and no schedule?',
      ],
    ),
    // 9 — ODY2_P09
    (
      pauseMs: 3000,
      lines: [
        'Good company is underrated.',
        "After everything I've seen, I've come to think the person beside you "
            'often matters more than the destination.',
        "And the best companions aren't necessarily the loudest. They're the "
            'ones who notice things.',
        'What makes someone genuinely good company for you?',
      ],
    ),
    // 10 — ODY2_P10. The "she"/"her" below is deliberate and should stay.
    //
    // It reads as an assertion about the visitor rather than about a
    // hypothetical third person, because the bubble after it ("I suspect you
    // have a few stories of your own") points the description straight at her
    // — so this is the one place the script tells the reader who she is
    // instead of asking. That looks like it contradicts the document's own
    // rule against assuming things about the audience, and it has been
    // queried once on exactly those grounds. It is not an oversight: he is
    // lightly flirty by design and the funnel is bought against women, so the
    // flirtation is meant to land on the reader. Do not neutralise it to
    // "they" without asking.
    (
      pauseMs: 3000,
      lines: [
        "Now that's something worth knowing about a person.",
        "For me, it's curiosity. I like someone who can tell me what she "
            'thinks, disagree with me, laugh at my worst stories... and then '
            'surprise me with one of her own.',
        'I suspect you have a few stories of your own.',
        "What's something about your life that would surprise me?",
      ],
    ),
    // 11 — ODY2_P11. Written as the answer to set 10's "You'll have to earn
    // that story." — it reads as a graceful retreat to an easier ask, which is
    // also what it is for anyone who said nothing at all.
    (
      pauseMs: 3000,
      lines: [
        'Ah. A little mystery.',
        'I respect that.',
        'People reveal themselves too quickly these days. A good story '
            'deserves its proper moment.',
        "So I'll ask something easier.",
        'What could you happily talk about for an hour if someone were '
            'genuinely interested?',
      ],
    ),
    // 12 — ODY2_P12, last turn, so its pause is never spent.
    (
      pauseMs: 0,
      lines: [
        "That's the kind of thing I'd rather hear than another retelling of "
            'the Trojan Horse.',
        'Everyone knows how that story ends.',
        "I don't know yours yet.",
        "And I think that's considerably more interesting.",
        'Where should we begin?',
      ],
    ),
  ];

  /// Odysseus's pause-point quick replies, from the same document — its "Quick
  /// replies" block for each pause, which specifies exactly three mixing an
  /// easy personal answer, curiosity about him, and a "keep telling me".
  ///
  /// The first twelve line up one-for-one with the twelve turns of
  /// [_odysseusOpeningScript]. Unlike v1's, almost none of them are questions:
  /// every turn now ends by asking her something, so the tappable line is her
  /// *answer* ("Knowing when to let go.", "I like to improvise."). That is the
  /// engagement bet of v2 — a one-tap answer about her own life is a far lower
  /// bar than composing a question to ask a stranger.
  ///
  /// It is also why sets 13–16 exist, and they are not from the document.
  /// [_setQuickReplyIndex] falls back to [_setStandsAlone] sets when a visitor
  /// interrupts the script, because the unplayed turns' replies would otherwise
  /// answer lines he never said. Answer-shaped sets never stand alone, so with
  /// only the document's twelve there would be nothing at all to fall back to
  /// and the strip would freeze on whichever set was showing when she spoke —
  /// v2's own shape breaking the recovery path v1 did not need. Sets 13–16 are
  /// written to be askable cold, so they serve both that fallback and the
  /// conversation past a script that ran to the end, where v1 simply parked on
  /// its last set forever. Their content is the document's post-handoff topic
  /// bank turned back into things she can tap.
  static const List<List<String>> _odysseusQuickReplies = [
    // 1 — ODY2_P01, what have you heard
    [
      'The Trojan Horse, of course.',
      'Mostly your adventures.',
      'I know about you and Penelope.',
    ],
    // 2 — ODY2_P02, monster, island or terrible decision
    [
      'The terrible decision.',
      'Tell me about the island.',
      'Definitely the monster.',
    ],
    // 3 — ODY2_P03, a foolish decision that turned out well
    [
      'Yes — definitely.',
      "I'm usually more careful than that.",
      "I'll tell you if you tell me yours first.",
    ],
    // 4 — ODY2_P04, starting something or letting go
    [
      'Starting something new.',
      'Knowing when to let go.',
      "I'm still learning both.",
    ],
    // 5 — ODY2_P05, a place that feels like home
    [
      'Yes, there is.',
      'Home has changed for me.',
      "I haven't found that place yet.",
    ],
    // 6 — ODY2_P06, a place you still think about
    [
      'A place I used to live.',
      'A favorite trip.',
      'Somewhere I want to return to.',
    ],
    // 7 — ODY2_P07, planner or improviser
    [
      'I plan everything.',
      'I like to improvise.',
      'A little of both.',
    ],
    // 8 — ODY2_P08, what adventure would tempt you today
    [
      'Somewhere beautiful.',
      'Somewhere completely new.',
      'Good company, no schedule.',
    ],
    // 9 — ODY2_P09, what makes good company
    [
      'Someone who really listens.',
      'Someone who makes me laugh.',
      'Someone I can be myself around.',
    ],
    // 10 — ODY2_P10, something that would surprise him
    [
      "I've had a few adventures.",
      "I've reinvented myself more than once.",
      "You'll have to earn that story.",
    ],
    // 11 — ODY2_P11, what you could talk about for an hour
    [
      "Travel and places I've been.",
      'People and relationships.',
      'My work, hobbies, or passions.',
    ],
    // 12 — ODY2_P12, where should we begin
    [
      'Ask me about my life now.',
      "Ask me about an adventure I've had.",
      'You tell me one more story first.',
    ],
    // 13 — past the script. Every line from here on is a question, and asks
    // nothing that depends on a turn he may not have reached.
    [
      'What happened when you finally reached Ithaca?',
      'Will you tell me another story?',
      'What do you want to know about me?',
    ],
    // 14
    [
      'What is the strangest place you ever landed?',
      'What surprises you most about how people live now?',
      'What did the sea teach you that nothing else could?',
    ],
    // 15
    [
      'What have you changed your mind about?',
      'Who did you miss most while you were away?',
      'What are you still proud of?',
    ],
    // 16
    [
      'What should I ask you that nobody ever does?',
      'What are you curious about in my life?',
      'Where would you take me if we set sail tomorrow?',
    ],
  ];

  /// Hercules's scripted opening — "Hercules - 90+ Second Chat Start v1".
  ///
  /// Thirty-three turns, the longest script here. Its own brief is that the
  /// mythology is about gods, family, women, reputation and life experience
  /// rather than monsters, and that the strength is the least interesting thing
  /// about him — which is why the Labors do not arrive until turn 29.
  ///
  /// IMPORTANT, and the reason most of this is currently unreachable: with
  /// AppConfig.requireInteractionToContinue on, the script stops at its first
  /// question (turn 4) and never resumes — answering it abandons the rest and
  /// hands the conversation to the model. Turns 5-33 only ever play with that
  /// switch off. They are written in full so the script is intact and correct
  /// for that case, and so the decision about which design wins is a config
  /// change rather than a rewrite.
  static const List<({List<String> lines, int pauseMs})>
      _herculesOpeningScript = [
    // 1
    (pauseMs: 500, lines: ['Well, hello there.']),
    // 2
    (
      pauseMs: 1500,
      lines: ["I'm Hercules.", 'Yes... that Hercules. 😉'],
    ),
    // 3
    (
      pauseMs: 1000,
      lines: [
        'You probably know about the strength.',
        'Everyone knows about the strength.',
        "Personally, I think it's the least interesting thing about me.",
      ],
    ),
    // 4 — first question, and where the interaction gate holds.
    (
      pauseMs: 4000,
      lines: [
        "I'm much more curious about you.",
        'Tell me...',
        'What usually makes a man interesting to you?',
      ],
    ),
    // 5
    (
      pauseMs: 1500,
      lines: [
        'Hmm.',
        "You're going to make me work for this conversation, aren't you?",
        'I like that. 😉',
      ],
    ),
    // 6
    (
      pauseMs: 1500,
      lines: [
        'Alright.',
        "I'll tell you something about myself first.",
        'My father was Zeus.',
      ],
    ),
    // 7
    (
      pauseMs: 1500,
      lines: [
        'That sounds impressive until you know my family.',
        'Zeus was powerful. Charming. Impossible to ignore.',
        'And absolutely terrible at keeping his personal life uncomplicated.',
      ],
    ),
    // 8
    (
      pauseMs: 4000,
      lines: [
        'Unfortunately...',
        'I may have inherited more than his strength. 😉',
        'Which quality do you think I inherited?',
      ],
    ),
    // 9
    (
      pauseMs: 1500,
      lines: [
        '"Still deciding."',
        "That's probably the sensible answer.",
        'People have been deciding what they think of me for thousands of '
            'years.',
      ],
    ),
    // 10
    (
      pauseMs: 1500,
      lines: [
        "Of course, being Zeus's son came with one rather significant "
            'complication.',
        'Hera.',
        "My father's wife.",
        'And no... she was not pleased about me.',
      ],
    ),
    // 11
    (
      pauseMs: 1500,
      lines: [
        'I spent much of my youth wondering how someone who barely knew me '
            'could dislike me so completely.',
        'Eventually I understood.',
        "She wasn't really looking at me.",
        'She was looking at what I represented.',
      ],
    ),
    // 12
    (
      pauseMs: 4000,
      lines: [
        "People still do that, don't they?",
        "They decide who you are before they've taken the trouble to know you.",
        'Has that ever happened to you?',
      ],
    ),
    // 13
    (
      pauseMs: 1500,
      lines: [
        "Perhaps that's why I've become careful about first impressions.",
        'Although... not too careful.',
        'I still enjoy a good first impression. 😉',
      ],
    ),
    // 14
    (
      pauseMs: 1500,
      lines: [
        'And before you ask - yes, there were women in my life.',
        'Quite a few stories have survived about that.',
        'Some accurate.',
        'Some... enthusiastically improved by poets.',
      ],
    ),
    // 15
    (
      pauseMs: 1500,
      lines: [
        "But the older I've become, the less interested I am in who was "
            'beautiful.',
        "Beauty gets someone's attention.",
        "It doesn't necessarily keep it.",
      ],
    ),
    // 16
    (
      pauseMs: 4000,
      lines: [
        'Humor can.',
        'Kindness can.',
        'Confidence certainly can.',
        "And there's something very attractive about a woman who has lived "
            'enough life to know who she is.',
        'What makes someone unforgettable to you?',
      ],
    ),
    // 17
    (
      pauseMs: 1500,
      lines: [
        'For me?',
        'Someone who surprises me.',
        'Queen Omphale certainly did.',
        'Now there was a woman.',
      ],
    ),
    // 18
    (
      pauseMs: 1500,
      lines: [
        'Imagine Hercules...',
        'the strongest man in Greece...',
        'taking orders from a queen.',
        'People assume I must have hated it.',
        "I didn't. 😉",
      ],
    ),
    // 19
    (
      pauseMs: 1500,
      lines: [
        'Omphale was confident. Clever. Completely unimpressed by my '
            'reputation.',
        'Do you have any idea how refreshing that was?',
        'Everyone else saw Hercules.',
        'She had absolutely no difficulty telling Hercules when he was being '
            'an idiot.',
        'Which, apparently, was reasonably often.',
      ],
    ),
    // 20
    (
      pauseMs: 4000,
      lines: ['Could you handle a man with a reputation like mine?'],
    ),
    // 21
    (
      pauseMs: 1500,
      lines: ['Careful.', 'I might actually enjoy being kept in line. 😉'],
    ),
    // 22
    (
      pauseMs: 1500,
      lines: [
        'But Omphale taught me something important.',
        "Strength isn't always being the person in control.",
        'Sometimes strength is being comfortable enough with yourself that you '
            "don't need to be.",
      ],
    ),
    // 23
    (
      pauseMs: 1500,
      lines: [
        'It took me an embarrassingly long time to learn that.',
        "I've learned quite a few things embarrassingly late.",
        "Perhaps that's the advantage of surviving your mistakes.",
        'Eventually they become wisdom.',
        'Or at least... good stories.',
      ],
    ),
    // 24
    (
      pauseMs: 1500,
      lines: [
        "And I've told you enough about me.",
        'I want to know something about you.',
        'Not where you live.',
        'Not what you do.',
        'Something more interesting.',
      ],
    ),
    // 25
    (
      pauseMs: 4000,
      lines: [
        "What's something life taught you that you wish you'd known twenty "
            'years earlier?',
      ],
    ),
    // 26
    (
      pauseMs: 1500,
      lines: [
        '"That\'s a long story."',
        'Those are usually the ones worth hearing.',
      ],
    ),
    // 27
    (
      pauseMs: 1500,
      lines: [
        'You know what people misunderstand about strength?',
        "They think it's about what you can lift.",
        'What you can defeat.',
        'How much punishment you can take.',
        "I've done enough of all three.",
        "That's not strength.",
      ],
    ),
    // 28
    (
      pauseMs: 1500,
      lines: [
        "Strength is what happens after life doesn't go according to plan.",
        'After someone disappoints you.',
        'After you disappoint yourself.',
        'After something ends that you were certain would last.',
        'And somehow... you begin again.',
      ],
    ),
    // 29
    (
      pauseMs: 1500,
      lines: [
        'Everyone knows my Twelve Labors.',
        "But everyone I've ever met has had labors of their own.",
        'Most simply never had poets following them around to write about it.',
      ],
    ),
    // 30
    (
      pauseMs: 4000,
      lines: [
        "So now I'm genuinely curious.",
        "What's something you've come through that made you stronger than you "
            'were before?',
      ],
    ),
    // 31
    (
      pauseMs: 1500,
      lines: [
        "You don't have to answer immediately.",
        "I'm enjoying your company either way.",
      ],
    ),
    // 32
    (
      pauseMs: 1500,
      lines: [
        'Besides...',
        "I've talked enough.",
        'And between us?',
        "I've heard all of my stories before. 😉",
      ],
    ),
    // 33
    (
      pauseMs: 4000,
      lines: [
        'Yours are new to me.',
        "And that's much more interesting.",
      ],
    ),
  ];

  /// Hercules's quick replies, one entry per turn of his script because
  /// [_setQuickReplyIndex] indexes this by turn number.
  ///
  /// His document specifies a set at nine of the thirty-three turns, so each is
  /// named once below and repeated until the next one is specified — the strip
  /// holds the last thing offered rather than emptying between questions.
  /// [_setQuickReplyIndex] compares the resolved prompts, so a repeat does not
  /// report itself as a new offer.
  static const List<String> _hercSetOpening = [
    'He makes me laugh.',
    "He's confident, but kind.",
    'He actually listens.',
  ];
  static const List<String> _hercSetInherited = [
    'The charm, obviously. 😉',
    'Getting into trouble.',
    "I'm still deciding about you.",
  ];
  static const List<String> _hercSetJudged = [
    "More times than I'd like.",
    'Yes, and I hate it.',
    'What did Hera do to you?',
  ];
  static const List<String> _hercSetUnforgettable = [
    'Making me laugh.',
    'Kindness.',
    'The way they make me feel.',
  ];
  static const List<String> _hercSetReputation = [
    'I think I could manage you. 😉',
    'Depends how well you behave.',
    "I'm more interested in Omphale.",
  ];
  static const List<String> _hercSetLesson = [
    'Not to worry so much.',
    'To trust myself.',
    "That's a long story.",
  ];
  static const List<String> _hercSetStronger = [
    'Starting over.',
    'Losing something important.',
    'I surprised myself.',
  ];
  static const List<String> _hercSetHandover = [
    'Alright. Ask me something.',
    'Tell me about Omphale first.',
    'I have a story for you.',
  ];

  /// Past the script, and the only Hercules sets that survive an interruption.
  ///
  /// Every set his document specifies is an ANSWER to the line before it —
  /// "The charm, obviously.", "Depends how well you behave." — so
  /// [_setStandsAlone] rightly accepts none of them, and once a visitor typed
  /// during his script the cold-safe fallback in [_setQuickReplyIndex] was
  /// empty. The strip then froze for the rest of the conversation on answers
  /// to a question he never asked, and the chosen-row latch never released
  /// because the prompts never changed. Odysseus escaped only because his
  /// sets 13-16 are questions; these are Hercules's equivalent. All questions,
  /// all askable cold, and drawn from the two threads his own script opens —
  /// his father, and Omphale.
  static const List<String> _hercSetCold1 = [
    "What's the story with you and Queen Omphale?",
    'What was it really like having Zeus as your father?',
    'What did Hera actually do to you?',
  ];
  static const List<String> _hercSetCold2 = [
    'Which of the Twelve Labors was the hardest?',
    'What do people get most wrong about you?',
    'What do you wish you had learned sooner?',
  ];

  static const List<List<String>> _herculesQuickReplies = [
    // 1-7: his opening set, respecified at turn 4 with the same three answers.
    _hercSetOpening, _hercSetOpening, _hercSetOpening, _hercSetOpening,
    _hercSetOpening, _hercSetOpening, _hercSetOpening,
    // 8-11
    _hercSetInherited, _hercSetInherited, _hercSetInherited, _hercSetInherited,
    // 12-15
    _hercSetJudged, _hercSetJudged, _hercSetJudged, _hercSetJudged,
    // 16-19
    _hercSetUnforgettable, _hercSetUnforgettable, _hercSetUnforgettable,
    _hercSetUnforgettable,
    // 20-24
    _hercSetReputation, _hercSetReputation, _hercSetReputation,
    _hercSetReputation, _hercSetReputation,
    // 25-29
    _hercSetLesson, _hercSetLesson, _hercSetLesson, _hercSetLesson,
    _hercSetLesson,
    // 30-32
    _hercSetStronger, _hercSetStronger, _hercSetStronger,
    // 33
    _hercSetHandover,
    // 34-35: past the script. Question-form, so they are also what the strip
    // falls back to once the visitor interrupts him.
    _hercSetCold1, _hercSetCold2,
  ];

  /// The pause-point quick replies for [characterId], or null for a character
  /// that has none and therefore keeps the old fixed starter strip.
  ///
  /// Keyed on the id for the same reason as [_openingScriptFor].
  ///
  /// Must stay *below* [_openingScriptFor] in this file: tool/gen_starters.mjs
  /// finds both by the same `characterId == '<id>') return _x;` pattern and
  /// keeps the last match per id, so whichever function comes second is the
  /// one it reads as the quick replies. Swap the order and the admin starts
  /// matching taps against the script's own lines.
  static List<List<String>>? _quickRepliesFor(String? characterId) {
    if (characterId == 'calypso') return _calypsoQuickReplies;
    if (characterId == 'odysseus') return _odysseusQuickReplies;
    if (characterId == 'hercules') return _herculesQuickReplies;
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

  /// Whether every question in [set] can be asked cold.
  ///
  /// The sets are written to sit at a specific pause, and a lot of them are
  /// answers rather than questions — "Courage.", "Give me the blank map.",
  /// "Maybe I am. 😉". Those only read correctly directly after the line they
  /// reply to. The ones written as questions read fine at any point, so the
  /// question mark is the test: it costs nothing to maintain and it has no
  /// false positives, only the odd false negative ("Tell me about the
  /// Cyclops." is fine cold and is skipped anyway), which is the harmless
  /// direction to be wrong in.
  static bool _setStandsAlone(List<String> set) =>
      set.every((q) => q.trimRight().endsWith('?'));

  /// Moves the strip to [index].
  ///
  /// While the script is playing, and for any conversation that heard it out,
  /// [index] is used as given: the sets line up with the turns, and after the
  /// last one they walk whatever the list has past it.
  ///
  /// Once a visitor interrupts, the rest of the script is never said, so its
  /// remaining sets would hand them replies to lines they never saw. Those are
  /// skipped and only the self-contained sets are offered, cycling rather than
  /// running out — a strip that stops changing stops working, because the
  /// chosen-row latch in [_StarterPrompts] is released by a change of prompts.
  void _setQuickReplyIndex(int index) {
    final sets = _quickRepliesFor(widget.characterId);
    if (sets == null || !mounted) return;
    final script = _openingScriptFor(widget.characterId);

    // Mid-playback the script is unfinished but not abandoned, and the exact
    // set is wanted — hence _welcomeAbandoned rather than the pause count
    // alone.
    final interrupted = script != null &&
        _welcomeAbandoned &&
        _scriptPausesReached < script.length;

    int next;
    if (!interrupted) {
      next = index < 0 ? 0 : (index >= sets.length ? sets.length - 1 : index);
    } else {
      final usable = <int>[
        for (var i = 0; i < sets.length; i++)
          if (_setStandsAlone(sets[i])) i,
      ];
      if (usable.isEmpty) return;
      next = usable[(index < 0 ? 0 : index) % usable.length];
    }

    if (next == _quickReplyIndex) return;
    // The index moved but the offer did not. Hercules's script specifies a set
    // at nine of its thirty-three turns and holds each one until the next, so
    // most of his turns land here — and an unchanged strip is not a new offer,
    // which is what the note below says this event is for. Without this, his
    // funnel would carry two dozen strip_rotate rows per visit describing
    // rotations that never happened.
    //
    // Ahead of the assignment, so _quickReplyIndex keeps pointing at the set
    // actually on screen rather than at an equal one further along.
    if (listEquals(sets[next], _quickReplies)) return;
    setState(() => _quickReplyIndex = next);

    // Funnel: the strip now offers a different set.
    //
    // This is the offer half of the offer/take pair the funnel was missing.
    // starter_tap said what was taken and nothing said what was put in front
    // of them, so "nobody tapped anything" could not be told apart from
    // "nobody was offered anything they stayed long enough to see". Logged on
    // the real change rather than on every turn: an unchanged strip is not a
    // new offer, and _setQuickReplyIndex has already returned above when the
    // index did not move.
    //
    // The set index goes in detail so the admin side can pair a rotation with
    // the tap that followed it, and see which sets are ever reached at all.
    logFunnelEvent(
      'strip_rotate',
      detail: '${widget.characterId}#$next',
      appUserId: _appUserId,
    );
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
  /// The turn the interaction gate holds on: the first one that ends by asking
  /// something.
  ///
  /// Not simply turn 1. A gate is a question left unanswered, and holding on a
  /// turn that asks nothing gives the visitor a dead screen and gives us a
  /// refusal that was never actually solicited. Odysseus asks in his first turn
  /// ("What have you heard?") so nothing changes for him; Calypso asks in her
  /// second; Hercules opens with "Well, hello there." and does not ask until
  /// his fourth.
  ///
  /// Derived from the script rather than configured per character, so it cannot
  /// drift when a script is edited — the same reason [_setStandsAlone] tests
  /// for a question mark instead of carrying a list.
  ///
  /// Falls back to the first turn for a script that never asks anything, which
  /// keeps the gate closed rather than letting the whole script play.
  static int _gateHoldTurn(List<({List<String> lines, int pauseMs})> script) {
    for (var i = 0; i < script.length; i++) {
      if (script[i].lines.last.trimRight().endsWith('?')) return i;
    }
    return 0;
  }

  Future<void> _playOpeningScript(
    List<({List<String> lines, int pauseMs})> script,
    int run,
  ) async {
    // Read once: it is fixed for the whole run, and the strip's own rebuilds
    // must not be able to change the pacing halfway through a script.
    final pacing = _scriptPacing;

    // Lines posted so far in the current turn, flushed to the model's history
    // as one assistant message at every exit from this loop.
    final delivered = <String>[];
    void flushTurn() {
      if (delivered.isEmpty) return;
      _aiService?.recordAssistantTurn(delivered.join('\n'));
      delivered.clear();
    }

    // Declare every line of the opening before the first one is drawn.
    //
    // The loop below returns the moment the visitor leaves, sends something, or
    // this run is superseded — and the script can be dozens of lines (Calypso's
    // is 37), so most sessions never reach the end of it. Declaring the whole
    // thing up front is what turns that into a measurement: the lines with no
    // sighting are exactly how far the opening got.
    //
    // This is also the honest test of the competing explanation for low
    // engagement. If people are leaving before the character finishes its
    // opening, that is pacing and entirely ours to fix; until now it was
    // indistinguishable from a delivery failure, because neither left a trace.
    final welcomeTurnId = DeliveryLog.instance.beginTurn();
    final welcomeBubbleIds = <String>[];
    for (final segment in script) {
      for (final line in segment.lines) {
        welcomeBubbleIds.add(
          DeliveryLog.instance.recordIntended(
            turnId: welcomeTurnId,
            seq: welcomeBubbleIds.length,
            origin: DeliveryOrigin.welcomeScript,
            text: line,
            chatId: widget.scenario,
            characterId: widget.characterId,
          ),
        );
      }
    }
    // Walks the flat list above in step with the nested loops below, which visit
    // the same lines in the same order.
    var welcomeSeq = 0;

    for (var s = 0; s < script.length; s++) {
      final segment = script[s];
      final lastSegment = s == script.length - 1;

      for (var i = 0; i < segment.lines.length; i++) {
        final line = segment.lines[i];

        // Beat length comes from the line itself, so a four-word remark and a
        // thirty-word sentence are not given the same second.
        final words = line.trim().split(RegExp(r'\s+')).length;
        final beatMs = (pacing.baseMs + (words * pacing.msPerWord))
            .clamp(pacing.minMs, pacing.maxMs);
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
          origin: DeliveryOrigin.welcomeScript,
          bubbleId: welcomeSeq < welcomeBubbleIds.length
              ? welcomeBubbleIds[welcomeSeq++]
              : null,
        );
        delivered.add(line);

        final lastLine = i == segment.lines.length - 1;
        if (lastLine) {
          flushTurn();
          // The turn is complete, so this is the pause the document names —
          // swap the strip to the questions that follow what she just said.
          // Move the frontier first: _setQuickReplyIndex will not step past it,
          // and this turn is now one the visitor has genuinely heard.
          _scriptPausesReached = s + 1;
          _setQuickReplyIndex(s);
        }
        if (lastLine && lastSegment) return;

        // The gate. The character asks something, then stops and waits to be
        // answered.
        //
        // Returning here rather than setting _welcomeAbandoned: abandoned means
        // the visitor took the turn and the rest is dropped, which is what a tap
        // or a keystroke does further down. Nothing has been dropped yet — the
        // script simply does not continue on its own, and if the visitor never
        // answers, it never continues at all. That silence is the measurement.
        //
        // The frontier and the strip were both moved by the block above, which
        // also flushed the turn — so the questions on offer are the ones
        // written for this pause, and the model already has what he said.
        if (lastLine && _gateActive && s >= _gateHoldTurn(script)) return;

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
        origin: DeliveryOrigin.systemBanner,
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

    // Declared before the typing beat below, for the same reason as the scripted
    // opening: this is a character's first words, it is delayed by up to five
    // seconds, and the loop abandons it if the visitor leaves first. One line
    // today, but the loop is written for more.
    final openerTurnId = DeliveryLog.instance.beginTurn();
    final openerBubbleIds = [
      for (var i = 0; i < lines.length; i++)
        DeliveryLog.instance.recordIntended(
          turnId: openerTurnId,
          seq: i,
          origin: DeliveryOrigin.welcomeScript,
          text: lines[i],
          chatId: widget.scenario,
          characterId: widget.characterId,
        ),
    ];

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
        origin: DeliveryOrigin.welcomeScript,
        bubbleId: openerBubbleIds[i],
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

  /// Adds a message to the conversation and records that it was drawn.
  ///
  /// [origin] is required so that adding a new way for the character to speak
  /// forces a decision about how it is logged — the compiler asks, rather than
  /// the new path quietly going unrecorded, which is how the welcome script and
  /// the portrait came to have no server-side trace at all.
  ///
  /// [bubbleId] is passed by the paths that know their bubbles in advance (an
  /// AI reply split into several, the welcome script) and have already declared
  /// the intent to show them. Those declarations are what make a bubble that was
  /// never drawn visible in the data; a single-bubble path has nothing to gain
  /// from the two steps and declares its intent here.
  void _addMessage(
    ChatMessage message, {
    required DeliveryOrigin origin,
    String? bubbleId,
  }) {
    final receiptId =
        bubbleId ??
        DeliveryLog.instance.recordIntended(
          turnId: DeliveryLog.instance.beginTurn(),
          seq: 0,
          origin: origin,
          text: message.text,
          isUser: message.isUser,
          // The scenario, not _chatId: conversation_logs.chat_id is the scenario
          // string, and these rows are only worth writing if they join to it.
          chatId: widget.scenario,
          characterId: widget.characterId,
        );
    _bubbleIdByMessageId[message.id] = receiptId;
    DeliveryLog.instance.markRendered(receiptId);

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

    // Funnel: the profile was opened. Logged here rather than at either tap
    // site, so the header and the entry card cannot drift apart — and after
    // the early return above, so it counts screens actually shown rather than
    // taps on a header that is inert for a character with no profile written.
    //
    // Worth its own event because it is engagement that leaves no other trace:
    // reading a profile is not a message, not a starter tap and not a
    // keystroke, so until now someone who opened it, read it and left was
    // indistinguishable in the funnel from someone who stared at the chat and
    // did nothing.
    logFunnelEvent(
      'profile_view',
      detail: widget.characterId,
      appUserId: _appUserId,
    );

    // "Zeus (Olympian King)" → name and title, matching the card's layout.
    final parts = _scenarioParts;
    final name = parts.name;
    final title = parts.title ?? '';

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
    // They read the profile and chose what to ask, which is a stronger entry
    // than the button asks for. The card comes down rather than reappearing
    // between them and the answer — being sent back to "Tap to Talk" after
    // committing to a question would read as the app losing their choice.
    //
    // The opening is skipped deliberately: their question is the start of this
    // conversation, and a scripted introduction arriving underneath it would
    // have the character introduce himself to someone who has already asked
    // him something specific.
    if (_entryGateActive) {
      _enterChat(source: 'profile', startOpening: false);
    }
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
      // The script is about to replay from the top, so the frontier goes back
      // with it — otherwise a conversation that finished the script once would
      // let the strip run ahead of the replay.
      _scriptPausesReached = 0;
      _aiService = OpenAIService(
        history: const [],
        scenario: widget.scenario,
        characterId: widget.characterId,
      );
    });

    await _loadReplyCount();
    if (mounted) _restartFromEntry();
  }

  /// Puts a just-cleared conversation back to the state a first-time arrival
  /// gets — which now begins before the tap, not after it.
  ///
  /// Shared by both clears, the header's "Fresh conversation" and the profile
  /// screen's, because they are one event seen from two places and had already
  /// drifted into two copies of the same reset.
  ///
  /// Replaying the opening straight into the chat would stage exactly what this
  /// release exists to prevent: the character talking to a screen nobody has
  /// entered, declaring bubbles to the delivery log as it goes.
  ///
  /// The repeat costs the funnel nothing. Its steps count DISTINCT visit_id, so
  /// a second entry_shown inside one visit cannot inflate the denominator, and
  /// _gateShownLogged still holds the story gate's event to one per screen.
  void _restartFromEntry() {
    // Both callers have just emptied the conversation, so the card is over a
    // genuinely fresh chat again and tapping it should start the opening.
    _entryGateStartsOpening = true;
    if (!_raiseEntryGate()) {
      _raiseGate();
      _triggerWelcomeSequence();
    }
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
      // The script is about to replay from the top, so the frontier goes back
      // with it — otherwise a conversation that finished the script once would
      // let the strip run ahead of the replay.
      _scriptPausesReached = 0;
      _aiService = OpenAIService(
        history: const [],
        scenario: widget.scenario,
        characterId: widget.characterId,
      );
    });

    await _loadReplyCount();
    if (mounted) _restartFromEntry();
  }

  void _cancelIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  /// (Re)starts the quiet countdown. Called once a reply has fully landed and
  /// after the opening line; cancelled as soon as the user sends anything.
  void _startIdleTimer() {
    _cancelIdleTimer();
    // Not while the gate is up. A nudge is the character speaking unprompted,
    // which is exactly what the gate exists to stop: if she fills her own
    // silence after 14s then the story did move without an answer, and a
    // visitor who sat through it has been counted as having declined something
    // that was never actually withheld.
    if (_gateActive) return;
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
      origin: DeliveryOrigin.idleNudge,
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

  void _openCoinsSheet() {
    showCoinsSheet(
      context,
      ref: ref,
      characterName: _characterDisplayName,
      // So the sheet can tell whether THIS character already wears a pendant.
      characterId: widget.characterId,
      onTribute: _sendTribute,
    );
  }

  /// A tribute is an ordinary chat turn with a coin debit attached: the
  /// worker charges before calling the model and tells the character what was
  /// offered, so the reply is the reaction. Mirrors [_handleSend]'s preamble
  /// (gate, funnel, score) because to everything downstream it IS a message —
  /// only the composer text box was never involved.
  Future<void> _sendTribute(String item, int price) async {
    _stopScreenPing();
    _cancelIdleTimer();
    _idleNudges = 0;

    final authed = ref.read(authProvider).value?.authenticated ?? false;
    if (!authed && _replyCount >= AppConfig.freeRepliesPerCharacter) {
      logFunnelEvent(
        'login_gate',
        detail: widget.characterId,
        appUserId: _appUserId,
      );
      _showLoginGate();
      return;
    }

    _welcomeAbandoned = true;
    if (!_sentFirstMessage) {
      _sentFirstMessage = true;
      logFunnelEvent(
        'first_message',
        detail: widget.characterId,
        appUserId: _appUserId,
      );
    }

    final option = kTributeOptions.firstWhere(
      (o) => o.item == item,
      orElse: () => kTributeOptions.first,
    );
    // Reads as a stage direction in the transcript, which is what it is. The
    // worker narrates the same gift to the character separately, in words the
    // model is told to answer rather than echo.
    final text =
        '*gives ${option.label.toLowerCase()} to $_characterDisplayName*';

    _addMessage(
      ChatMessage(
        id: DateTime.now().toString(),
        text: text,
        isUser: true,
        timestamp: DateTime.now(),
        // What was handed over, drawn in the bubble. Persisted with the
        // message, so scrolling back weeks later still shows the roses.
        giftAsset: option.asset,
      ),
      origin: DeliveryOrigin.user,
    );
    setState(() {
      _isTyping = true;
      _userHasSent = true;
    });
    ref.read(userScoreProvider.notifier).increment();

    final gift = <String, dynamic>{
      // Client-chosen so a retry replays the same id and cannot pay twice;
      // shape must satisfy the worker's [A-Za-z0-9_-]{8,64} guard. A
      // once-per-character gift ignores this and keys on (user, character)
      // server-side, so a pendant cannot be bought twice however this id
      // comes out.
      'id': 'tribute_${DateTime.now().millisecondsSinceEpoch}',
      'item': item,
    };
    try {
      await _deliverReply(text, gift: gift);
    } finally {
      if (mounted && _isTyping) setState(() => _isTyping = false);
    }
  }

  Future<void> _handleSend() async {
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
      logFunnelEvent(
        'login_gate',
        detail: widget.characterId,
        appUserId: _appUserId,
      );
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
      logFunnelEvent(
        'first_message',
        detail: widget.characterId,
        appUserId: _appUserId,
      );
    }

    _textController.clear();
    _addMessage(
      ChatMessage(
        id: DateTime.now().toString(),
        text: text,
        isUser: true,
        timestamp: DateTime.now(),
      ),
      origin: DeliveryOrigin.user,
    );

    setState(() {
      _isTyping = true;
      // They are in the conversation now: the starter prompts and the
      // highlighted message box have done their job and step out of the way.
      _userHasSent = true;
    });

    // Increment Score
    ref.read(userScoreProvider.notifier).increment();

    try {
      await _deliverReply(text);
    } finally {
      // The indicator is switched on above, before anything that can fail, so
      // clearing it cannot be left to the happy path — every early return
      // below used to be a way to strand it, and the null-service one did
      // exactly that on every cold load. By here a completed reply has already
      // turned it off and this is a no-op.
      if (mounted && _isTyping) setState(() => _isTyping = false);
    }
  }

  /// Everything after the user's own bubble is on screen: the canned portrait
  /// reply, or the API call and the bubbles it comes back as.
  ///
  /// Split out of [_handleSend] so that one `finally` there covers every way
  /// out of it, the indicator included.
  Future<void> _deliverReply(String text, {Map<String, dynamic>? gift}) async {
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
    //
    // The service is built by _loadHistory, behind two awaits on storage, so a
    // send can arrive before it exists — which is every send made from a cold
    // load, the profile card's opener and /c/<id>?initialMessage= included.
    // This used to be a bare `if (_aiService == null) return;`: the user's
    // message was drawn and saved, no POST /api/chat was ever made, and the
    // typing indicator sat there for as long as the tab was open. Wait for the
    // load already in flight instead of giving up on it.
    if (_aiService == null) await _historyLoaded;
    if (!mounted) return;
    final ai = _aiService;
    // Only reachable if the load failed outright; the caller's finally clears
    // the indicator.
    if (ai == null) return;

    final responseText = await ai.sendMessage(text, gift: gift);

    if (!mounted) return;

    // The wallet block riding on the response, whatever the outcome: the chip
    // should move with the conversation, not on the next app start.
    final walletUpdate = ai.lastWallet;
    if (AppConfig.coinsUiEnabled && walletUpdate != null) {
      ref.read(coinWalletProvider.notifier).applyFromChat(walletUpdate);
    }
    if (ai.lastFailureReason == 'insufficient_coins') {
      // Nothing was charged and nothing went upstream. Say so plainly rather
      // than letting the silence read as the character ignoring the gift —
      // the sheet disables unaffordable tributes, so this is the rare race,
      // not the normal path.
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('Not enough coins for that tribute.'),
      ));
      return;
    }
    if (gift != null &&
        ai.lastSendSucceeded &&
        walletUpdate != null &&
        walletUpdate['gift'] is Map) {
      final applied = walletUpdate['gift'] as Map;
      final giftId = gift['id'];
      // charged:false is the pendant they already wear — the reply is real,
      // but nothing was spent, so nothing is scored either.
      if (applied['charged'] != false &&
          giftId is String &&
          !_scoredTributeIds.contains(giftId)) {
        _scoredTributeIds.add(giftId);
        ref.read(userScoreProvider.notifier).add(
              AppConfig.tributeHeartScore[gift['item']] ?? 0,
            );
      }
      // Some characters answer a gift with a photograph as well as words.
      // Queued here and sent after the reply's bubbles below, so it arrives
      // as the last thing in the turn rather than interrupting the sentence
      // it belongs to.
      final item = gift['item'];
      if (applied['charged'] != false && item is String) {
        final reward = giftRewardAsset(widget.characterId, item);
        final key = '${widget.characterId}:$item';
        if (reward != null && !_sentGiftRewards.contains(key)) {
          _sentGiftRewards.add(key);
          _pendingGiftReward = reward;
        }
      }
    }

    // Count this toward the free allowance only if a real reply came back
    // (not a rate-limit/"trouble thinking" fallback), and only while the
    // gate still applies (signed out).
    if (ai.lastSendSucceeded) {
      final next = await ref
          .read(storageServiceProvider)
          .incrementReplyCount(_characterKey);
      if (mounted) setState(() => _replyCount = next);
    } else {
      // Funnel: the user sent something and got nothing usable back. A
      // 'network' reason means the request never reached the worker, so this
      // event is the ONLY record that the send happened at all — without it a
      // failed send looks identical to never having typed.
      final reason = ai.lastFailureReason;
      logFunnelEvent(
        'send_failed',
        detail: widget.characterId,
        appUserId: _appUserId,
        failureReason: reason,
      );
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

    // Declare the whole reply before pacing out any of it.
    //
    // This is the measurement the loop below would otherwise destroy: the
    // bubbles are revealed over several seconds, so anyone who leaves mid-reply
    // never sees the rest — and recording each one only as it was drawn would
    // leave no trace that the others were ever meant to arrive. Every bubble is
    // declared now; those that make it to the screen are stamped as they go.
    //
    // A fallback ("having trouble thinking", the rate-limit line, the local
    // translation refusal) reaches this same code path and reads as the
    // character speaking, so it is tagged for what it is and carries the reason
    // it happened. lastFailureReason is also the only signal for a send that
    // never reached the worker, which by definition has no row server-side.
    final failureReason = _aiService?.lastFailureReason;
    final fromServer = _aiService?.lastSendSucceeded == true;
    final turnId = DeliveryLog.instance.beginTurn();
    final bubbleIds = [
      for (var i = 0; i < bubbles.length; i++)
        DeliveryLog.instance.recordIntended(
          turnId: turnId,
          seq: i,
          origin: fromServer
              ? DeliveryOrigin.aiReply
              : DeliveryOrigin.localFallback,
          text: bubbles[i],
          chatId: widget.scenario,
          characterId: widget.characterId,
          // Names the conversation_logs row this was cut from, so the text on
          // screen can be compared against the text we sent. Null for a
          // fallback, which no reply row exists for.
          conversationLogId: fromServer ? _aiService?.lastLogId : null,
          failureReason: failureReason,
        ),
    ];

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
        origin: fromServer
            ? DeliveryOrigin.aiReply
            : DeliveryOrigin.localFallback,
        bubbleId: bubbleIds[i],
      );
    }

    // A gift's reward photograph, if this turn earned one — after the words,
    // never instead of them: the character answers the gesture in their own
    // voice first, and the photo is the flourish on the end.
    final reward = _pendingGiftReward;
    if (reward != null) {
      _pendingGiftReward = null;
      await _sendGiftReward(reward);
      if (!mounted) return;
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
  /// The photograph a character sends back for a gift. Paced like the
  /// portrait — a typing beat, then the image — so it reads as them choosing
  /// to send it rather than an attachment the app stapled on.
  Future<void> _sendGiftReward(String asset) async {
    if (!mounted) return;
    setState(() => _isTyping = true);
    await Future.delayed(const Duration(milliseconds: 1100));
    if (!mounted) return;
    setState(() => _isTyping = false);
    _addMessage(
      ChatMessage(
        id: 'giftreward_${DateTime.now().millisecondsSinceEpoch}',
        text: 'A photo from $_characterDisplayName',
        isUser: false,
        timestamp: DateTime.now(),
        imageAsset: asset,
      ),
      origin: DeliveryOrigin.giftReward,
    );
  }

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
      origin: DeliveryOrigin.portrait,
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
              // Only when the wallet is live: a promise about coins must not
              // appear in a build where coins do not exist.
              if (AppConfig.coinsUiEnabled &&
                  (ref.read(coinWalletProvider).value?.enabled ?? false)) ...[
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.paid,
                        size: 14, color: theme.colorScheme.secondary),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Your coins come with you — signing in adds +100.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.lato(
                          color: theme.colorScheme.secondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
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

    // The surface the bubbles are actually being drawn onto, recorded with each
    // receipt. Read here rather than from the window so it is the same number on
    // both platforms, and because a resize should be reflected — a visitor who
    // shrank the window is a plausible reason for a bubble never coming into
    // view, and site_visits.viewport_w only ever captured arrival.
    final viewport = MediaQuery.sizeOf(context);
    DeliveryLog.instance.setViewport(
      viewport.width.round(),
      viewport.height.round(),
    );

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
          // The coin balance, in the slot the premium diamond was drawn for.
          // Tapping it opens the wallet sheet, which in a chat also offers
          // the tribute sizes for this character.
          if (AppConfig.coinsUiEnabled &&
              (ref.watch(coinWalletProvider).value?.enabled ?? false))
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: CoinChip(
                  compact: true,
                  balance: ref.watch(coinWalletProvider).value?.balance ?? 0,
                  onTap: _openCoinsSheet,
                ),
              ),
            ),
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
          // Content. Wrapped so that while the entry card is up the chat is
          // out of the focus traversal as well as out of reach of a pointer:
          // the card is opaque and swallows taps, but Tab on desktop web
          // walked straight past it to the message field, and a keystroke
          // there logged input_typed for a visit whose entry_shown stood
          // untapped — "engaged but never entered", which the funnel cannot
          // express. Same for a screen reader landing on controls the card is
          // meant to be withholding.
          ExcludeFocus(
            excluding: _entryGateActive,
            child: Column(
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
                    // Wrapped so a bubble reports when it has genuinely been in
                    // front of the visitor, rather than merely built. The id is
                    // null for anything restored from local history, which has
                    // no receipt and must not be reported as freshly seen.
                    return SeenDetector(
                      bubbleId: _bubbleIdByMessageId[msg.id],
                      revalidate: _seenRevalidate,
                      isSurfaceVisible: () => _surfaceVisible,
                      onSeen: DeliveryLog.instance.markSeen,
                      child: _ChatBubble(
                        message: msg,
                        groupedWithNext:
                            next != null && next.isUser == msg.isUser,
                        onReport: () => _reportMessage(msg),
                      ),
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
                  teach: !_userHasSent,
                  // Only offered where there is actually a portrait to send.
                  onPhoto: (widget.characterImage?.isNotEmpty ?? false)
                      ? () => _sendStarter(_photoPrompt)
                      : null,
                  onGift: (AppConfig.coinsUiEnabled &&
                          (ref.watch(coinWalletProvider).value?.enabled ??
                              false))
                      ? _openCoinsSheet
                      : null,
                ),
              _buildInputArea(theme),
            ],
            ),
          ),
          // The entry gate, over everything in the body.
          //
          // Deliberately inside the body Stack rather than over the whole
          // Scaffold, so the app bar stays live: the back arrow and the
          // character's name have to keep working. Someone who decides not to
          // come in must be able to leave in the ordinary way — a card they
          // cannot escape would turn a measurement into a trap, and "left
          // rather than tap" is a result we want recorded, not prevented.
          // Above the entry card in the stack because it replaces it: the
          // card is already hidden by the time this is up, and if both were
          // ever active the claim is the one the visitor just asked for.
          if (_claimedGrants.isNotEmpty)
            CoinClaimScreen(
              grants: _claimedGrants,
              balance: _claimBalance,
              // The server recounts the streak on every claim, so the state
              // the claim() just wrote already carries today's run.
              streakDays:
                  ref.read(coinWalletProvider).value?.streakDays ?? 0,
              onCollect: _dismissCoinClaim,
            ),
          if (_entryGateActive)
            _EntryGate(
              name: _characterDisplayName,
              title: _characterTitle,
              characterId: widget.characterId,
              imagePath: widget.characterImage,
              onEnter: () => _enterChat(),
              onOpenProfile: _openProfile,
              // Same truth the chip and claim screen use: only promise coins
              // when the server says the wallet is live.
              coinsClaim: AppConfig.coinsUiEnabled &&
                  (ref.watch(coinWalletProvider).value?.enabled ?? false),
              scrollController: _entryGateScrollController,
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
    _releaseGate('tap');
    logFunnelEvent(
      'starter_tap',
      detail: widget.characterId,
      appUserId: _appUserId,
    );
    _textController.text = text;
    _handleSend();
  }
}

/// The entry card's button: sized to its own text, and beating.
///
/// A separate widget rather than an AnimationController on the chat screen's
/// state, which owns enough already and would have to carry a ticker for the
/// life of every conversation to drive something that exists for a few seconds
/// at the start of one.
///
/// The amplitude is deliberately past what a "tasteful" pulse would be. This is
/// the whole release: on traffic where half of arrivals leave within 3s of a
/// ~2s paint, a button that waits politely to be noticed has already lost. It
/// swells and drops far enough to be caught in peripheral vision, which is the
/// only kind of attention a visitor mid-scroll has to give it.
class _PulsingEnterButton extends StatefulWidget {
  final VoidCallback onPressed;
  final String label;

  const _PulsingEnterButton({required this.onPressed, required this.label});

  @override
  State<_PulsingEnterButton> createState() => _PulsingEnterButtonState();
}

class _PulsingEnterButtonState extends State<_PulsingEnterButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// Bottom and top of the beat. ±10% either side of resting size is roughly
  /// four times the amplitude of [_PulsingHighlight]'s glow, which is the point
  /// — that one decorates something already being looked at, this one has to
  /// interrupt.
  static const double _minScale = 0.90;
  static const double _maxScale = 1.10;

  /// One beat per 900ms. Slower reads as breathing and stops registering as a
  /// request; much faster reads as a rendering fault.
  static const Duration _period = Duration(milliseconds: 900);

  /// Label colour on the gold button. See the note at its use site — this is a
  /// contrast fix, not a preference.
  static const Color _labelColor = Color(0xFF2E003E);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _period)
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.secondary;

    final button = ElevatedButton(
      onPressed: widget.onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: accent,
        // The app's own deep purple, not white. White on the gold accent
        // (#FFD700) is about 1.4:1 — below every legibility threshold there
        // is, which is why the label washed out into the button instead of
        // standing on it. This is 12.8:1 against the same gold, and it is a
        // colour already in the palette rather than a new one: it is the
        // background this card's gradient starts from.
        foregroundColor: _labelColor,
        // Horizontal padding rather than a width: the label decides how wide
        // this is, so a longer one in another language cannot clip.
        padding: const EdgeInsets.symmetric(horizontal: 44, vertical: 18),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
        ),
      ),
      child: Text(
        widget.label,
        style: GoogleFonts.outfit(
          fontSize: 19,
          fontWeight: FontWeight.w700,
        ),
      ),
    );

    // Honour the platform's reduce-motion setting. A button pulsing 10% on a
    // two-second cycle is exactly what that setting exists for, and someone who
    // has asked for stillness should still get a button — just a still one.
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return button;

    return AnimatedBuilder(
      animation: _controller,
      child: button,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_controller.value);
        return Transform.scale(
          scale: _minScale + (_maxScale - _minScale) * t,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              // The glow swells with the scale rather than on its own beat, so
              // the two read as one gesture instead of two things happening.
              boxShadow: [
                BoxShadow(
                  color: accent.withOpacity(0.20 + 0.45 * t),
                  blurRadius: 12 + 26 * t,
                  spreadRadius: 1 + 3 * t,
                ),
              ],
            ),
            child: child,
          ),
        );
      },
    );
  }
}

/// The entry card: portrait, name, title, one button, over the chat until it
/// is tapped.
///
/// Everything here is static — no image to fetch, no history to wait on, no
/// paced beat — so it is on screen the moment Flutter paints. That is the
/// whole design constraint: for the QR traffic that is two thirds of arrivals
/// the app paints at a ~2s median and half are gone by 3s, so anything the
/// visitor has to wait for is not something they declined, it is something
/// they never saw.
///
/// A widget of its own, like [_StarterPrompts] and [_PulsingEnterButton], rather
/// than a builder on the chat screen's State — which is where it started, and
/// where every copy tweak was landing in the largest and hottest file in the
/// repo. It holds nothing: whether it is up, and what tapping it does, both
/// belong to the screen and arrive as arguments.
class _EntryGate extends StatelessWidget {
  final String name;
  final String? title;
  final String? characterId;
  final String? imagePath;

  /// Tapping the button.
  final VoidCallback onEnter;

  /// Tapping the portrait/name block. The card decides for itself whether to
  /// wire and advertise this — see hasProfile in [build] — so a caller passes
  /// it unconditionally.
  final VoidCallback onOpenProfile;

  /// The screen's controller for this card's scroll view, so the screen can
  /// read maxScrollExtent one frame after raising the gate — that is how
  /// entry_shown learns whether the button was inside the first viewport
  /// (#fold=fit) or below it (#fold=below). Owned and disposed by the screen;
  /// this widget only attaches it.
  final ScrollController? scrollController;

  /// Whether to make the coins promise — "Tap to Claim Coins" and the claim
  /// tagline — or fall back to the original "Tap to Talk" invitation. Gated on
  /// the SAME wallet-enabled truth as the chip and the claim screen, so a dark
  /// build (COIN_LEDGER off, wallet enabled:false) reverts to the pre-coins
  /// card and never advertises a claim it cannot pay. The card, not just the
  /// payoff, tracks the flag.
  final bool coinsClaim;

  const _EntryGate({
    required this.name,
    required this.title,
    required this.characterId,
    required this.imagePath,
    required this.onEnter,
    required this.onOpenProfile,
    required this.coinsClaim,
    this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = this.title;
    final tagline = characterById(characterId)?['tagline'] as String?;
    // Exactly the condition _openProfile bails on, so the hint is never shown
    // for a tap that would do nothing.
    final hasProfile =
        profileForCharacter(characterId) != null && imagePath != null;
    return Positioned.fill(
      // Opaque, and every stop of it. This gradient is copied from the chat
      // background below, where a translucent middle stop is free because
      // there is nothing behind it — over the chat it is not: at 0.25 the
      // quick-reply strip, a starter row and the message box all read straight
      // through the card, so the "one button" screen arrived with four other
      // tappable-looking things on it and did not read as a new screen at all.
      //
      // alphaBlend rather than a hand-picked hex so the tone still follows
      // theme.primaryColor, composited onto the black it would have been
      // sitting on anyway.
      child: Container(
        key: _entryGateKey,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFF2E003E),
              Color.alphaBlend(
                theme.primaryColor.withOpacity(0.25),
                Colors.black,
              ),
              Colors.black,
            ],
          ),
        ),
        child: SafeArea(
          // Identity at the top, button at the bottom, gap between — rather
          // than one centred stack.
          //
          // Still inside a scroll view, and that is the part worth keeping:
          // the button is pinned to the bottom of the CONTENT, not to the
          // viewport, so on a short screen (an older phone, or a browser with
          // a fat in-app toolbar) it goes on being reachable by scrolling
          // instead of being pushed off the edge. minHeight is what makes it
          // sit at the bottom when there is room to spare, and yield when
          // there is not.
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              // Read once post-frame by _raiseEntryGate: maxScrollExtent > 0
              // here means the button starts below the fold.
              controller: scrollController,
              // The top inset clears the app bar, which this body extends
              // behind (extendBodyBehindAppBar). Centred content never needed
              // it; top-aligned content slides under the header without it.
              padding: const EdgeInsets.fromLTRB(
                32,
                kToolbarHeight + 24,
                32,
                28,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  // Clamped: an in-app browser with the soft keyboard up can
                  // hand this builder less than the padding it subtracts, and
                  // a negative minHeight fails BoxConstraints' own assert.
                  minHeight: max(0, constraints.maxHeight - (kToolbarHeight + 52)),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                  // Portrait, name, title and tagline are one tap target, not
                  // four. They read as a single block, so a visitor who tries
                  // the name after the photo did nothing would conclude the
                  // whole thing is inert — and the hint below promises both.
                  //
                  // Inert, with no hint shown, for a character who has no
                  // profile written: _openProfile returns early in that case,
                  // and advertising a tap that does nothing is worse than not
                  // advertising it.
                  GestureDetector(
                    onTap: hasProfile ? onOpenProfile : null,
                    behavior: HitTestBehavior.opaque,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (imagePath != null)
                          Container(
                            // 190, up from 132. It is the only image on the
                            // first screen anyone sees, and at 132 it read as
                            // an avatar next to the name rather than as the
                            // portrait the screen is built around.
                            width: 190,
                            height: 190,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: theme.colorScheme.secondary
                                    .withOpacity(0.6),
                                width: 2,
                              ),
                              image: DecorationImage(
                                image: AssetImage(imagePath!),
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        const SizedBox(height: 24),
                        Text(
                          name,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.outfit(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 30,
                          ),
                        ),
                        if (title != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            title,
                            textAlign: TextAlign.center,
                            style: GoogleFonts.outfit(
                              color: Colors.white.withOpacity(0.65),
                              fontSize: 17,
                            ),
                          ),
                        ],
                        if (tagline != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            tagline,
                            textAlign: TextAlign.center,
                            style: GoogleFonts.outfit(
                              color: Colors.white.withOpacity(0.55),
                              fontSize: 15,
                            ),
                          ),
                        ],
                        if (hasProfile) ...[
                          const SizedBox(height: 12),
                          // The hint. Says which things are tappable and what
                          // arrives if you tap them, because "tap to learn
                          // more" on a screen that already has a big button
                          // saying "Tap to continue" would just compete with
                          // it. The icon carries most of the work at a glance.
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.touch_app_outlined,
                                size: 15,
                                color: theme.colorScheme.secondary
                                    .withOpacity(0.75),
                              ),
                              const SizedBox(width: 6),
                              // Flexible, not bare. A Row sizes its children
                              // to their natural width, so this line overflowed
                              // the 390px reference phone by 252px — clipped
                              // text in release, overflow stripes in debug.
                              // Letting it wrap costs a second line on a narrow
                              // screen and nothing on a wide one.
                              Flexible(
                                child: Text(
                                  'Tap the photo or name for the full profile',
                                  textAlign: TextAlign.center,
                                  style: GoogleFonts.outfit(
                                    color: theme.colorScheme.secondary
                                        .withOpacity(0.75),
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  // Three children, so spaceBetween puts one at the top, one
                  // in the middle and one at the foot. The invitation used to
                  // travel with the button as a caption under it, which left
                  // it stranded at the very bottom of the screen, a long way
                  // under the profile hint it reads on from.
                  //
                  // An invitation rather than a label for the button. The line
                  // this replaced ("to speak with the King of Ithaca") only
                  // restated the title printed two rows above it, so it spent
                  // the last line on the screen saying nothing new. This one
                  // gives a reason to press.
                  //
                  // Sized close to the title above it rather than as fine
                  // print. It is the only sentence on the card doing any
                  // persuading, and at 14px against a 30px name it read as a
                  // caption for the button — the opacity goes up with it,
                  // because bigger but still faint is half a change.
                  //
                  // The break after "talk to you," is deliberate and hard,
                  // not left to the wrap: it splits the sentence at its own
                  // comma, so the two halves read as two thoughts rather than
                  // wherever the phone's width happens to cut them.
                  //
                  // No gendered word left in it. Shortening the second half
                  // dropped the "how he can help" clause, so this line is now
                  // identical for every character on the roster — which is
                  // why the per-character pronoun helper this used to call is
                  // gone from characters.dart rather than sitting there
                  // uncalled.
                  Text(
                    coinsClaim
                        ? 'Claim your coins for the Greek-themed\n'
                            'Mythos Live interactive story adventure'
                        : '$name would like to talk to you,\n'
                            'and understand your journey',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.outfit(
                      color: Colors.white.withOpacity(0.75),
                      fontSize: 17,
                      height: 1.4,
                    ),
                  ),
                  // Alone at the foot. The only thing on the screen that does
                  // anything, and nothing rides along under it.
                  //
                  // Not full width: stretched to the card's gutters it read as
                  // a banner, a thing the layout happened to end on, and a
                  // button that is obviously a button beats a bigger one that
                  // is not. Sized to its text instead, and pulsing, so it is
                  // the only moving thing on an otherwise still screen.
                  _PulsingEnterButton(
                    onPressed: onEnter,
                    // 'Tap to Claim Coins' only when coins are live; the
                    // original 'Tap to Talk' otherwise, so a dark build does
                    // not promise a claim. entry_tap's meaning changes when
                    // this flips — compare funnel rates across the boundary.
                    label: coinsClaim ? 'Tap to Claim Coins' : 'Tap to Talk',
                  ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Identifies the entry card's backing container so a test can assert it is
/// actually opaque. It shipped once with a translucent middle stop under a
/// comment claiming otherwise, and no test could have caught it: a widget test
/// searches the tree, where the chat is still present whether or not anything
/// is painted over it.
const Key _entryGateKey = ValueKey('entry_gate_surface');

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

  /// Opens the gift catalogue. Null when coins are switched off, so a build
  /// with no wallet shows no gift button at all.
  final VoidCallback? onGift;

  /// Whether the strip still has to teach itself.
  ///
  /// The staggered entrance, the green pass down the rows and the flashing
  /// instruction all exist to get a first tap out of someone who has not
  /// realised the rows are tappable. Once they have sent anything — tapped a
  /// row or typed their own — they have demonstrably understood, and running
  /// the sequence at every subsequent question is nagging rather than
  /// teaching. It stops for good at that point.
  ///
  /// Driven by `_userHasSent`, which is restored from history on mount, so a
  /// returning visitor is not taught again either. Same signal already retires
  /// the [_PulsingHighlight] on the message box.
  final bool teach;

  const _StarterPrompts({
    required this.characterName,
    required this.prompts,
    required this.onTap,
    required this.teach,
    this.onPhoto,
    this.onGift,
  });

  @override
  State<_StarterPrompts> createState() => _StarterPromptsState();
}

class _StarterPromptsState extends State<_StarterPrompts>
    with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final AnimationController _attention;
  late final AnimationController _flash;

  /// Below this the screen is treated as short (an older 640-tall phone, or
  /// anything with the keyboard up) and the hint line is dropped so all three
  /// prompts are shown whole. A row cut in half by the panel edge looks
  /// broken, which is the opposite of what the strip is for.
  static const double _shortScreenHeight = 720;

  /// Below this there is not room for three prompts either, and the third one
  /// goes as well. Separate from [_shortScreenHeight] because dropping a
  /// prompt and dropping the hint are very different costs — see the note in
  /// [build] on which yields first.
  static const double _veryShortScreenHeight = 560;

  /// The rows arrive one after another, and a single highlight then travels
  /// down them once, on each new set.
  ///
  /// Why this shape rather than a steady glow: the strip is on screen from
  /// t=0 and never moves, while bubbles keep arriving above it, so it reads as
  /// furniture — 58% of visitors who open a character stay past five seconds
  /// and tap nothing (`docs/odysseus-opening-brief-2026-08-10.md` §3.3 names
  /// this as the untested lever). Motion is the fix, but only at the beat
  /// where the character has stopped talking and just asked something.
  /// v2 ends every turn on a question, so one pass per set lands roughly every
  /// ten seconds without ever looping in place.
  ///
  /// The two effects are separately switchable on purpose. The brief allows
  /// one changed variable at a time at this traffic level: set
  /// [_entranceStagger] to 0 for the old all-at-once fade, or
  /// [_attentionPasses] to false to drop the highlight, and the other still
  /// stands on its own.
  static const bool _attentionPasses = true;

  /// Sound, separable from the light for the same one-variable-at-a-time
  /// reason as everything else here — and because it is the one part of this
  /// most visitors will never receive. Audio needs a prior gesture (the
  /// character tap supplies one), and on iOS the hardware silent switch mutes
  /// Web Audio outright, which a large share of phone visitors will have on.
  static const bool _chimes = true;
  static const Duration _entranceDuration = Duration(milliseconds: 820);
  static const double _entranceStagger = 0.16;
  static const double _entranceSpan = 0.55;

  /// The highlight starts after the entrance has settled rather than during
  /// it. Two things moving on the same three rows is noise; the point of the
  /// pass is to be the only thing moving once the bubbles have stopped.
  static const Duration _attentionDuration = Duration(milliseconds: 2400);
  static const Duration _attentionDelay = Duration(milliseconds: 260);

  /// Each row owns a third of the pass — 800ms — and they do not overlap, so
  /// the strip lights one, then the next, then the next. Overlapping humps
  /// read as a single wave washing over the strip; discrete slots read as
  /// three separate things being pointed at, which is the whole intent.
  ///
  /// 800ms rather than the 500 this started at. At 500 the three rows ran
  /// together into one gesture; the extra 300ms is what makes them read as
  /// three separate invitations, which is the point of lighting them
  /// one at a time at all.
  static const double _glowSlot = 1 / 3;

  /// Within its slot a row rises, holds, then releases, rather than pulsing.
  /// A sine over 500ms is a blip; the hold is what makes it read as "lit".
  static const double _glowRamp = 0.3;

  /// The colour a lit row moves to.
  ///
  /// Deliberately the same green as [_StarterButton._selectedColor], which
  /// normally means "this one was sent". They stay apart because selection
  /// also fills the row, thickens the border and swaps the arrow for a tick,
  /// none of which the pass does — but if the two ever do get confused, this
  /// is the constant to pull apart.
  static const Color _attentionColor = Color(0xFF4ADE80);

  /// The instruction flashes after the three rows have been lit, not during —
  /// it is the summary of what just happened, so it has to land last.
  static const Duration _flashDuration = Duration(milliseconds: 1100);

  /// How much bigger the instruction gets at the top of each flash beat.
  ///
  /// Applied as a [Transform.scale] rather than an animated `fontSize`: font
  /// size is a layout property, so growing it re-lays out the row every frame
  /// and shoves the three prompts below it up and down. The transform paints
  /// bigger without touching layout, which is the difference between a pop and
  /// a jitter.
  static const double _flashGrowth = 0.22;

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

    // Release the latch here rather than leaving it to didUpdateWidget.
    //
    // That only fires when the prompt list actually changes, which is not
    // guaranteed: the strip parks on its last set once the conversation walks
    // off the end of the list, and then the same three prompts are rebuilt
    // forever. With the latch still set, the tapped row stays drawn as chosen
    // and the guard above rejects every later tap — one tap and the strip is
    // dead furniture, which is exactly what didUpdateWidget's comment was
    // written to prevent and could not, from where it sits.
    if (mounted) setState(() => _selected = null);
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _entranceDuration,
    );
    _attention = AnimationController(
      vsync: this,
      duration: _attentionDuration,
    );
    _flash = AnimationController(
      vsync: this,
      duration: _flashDuration,
    );
    // Held back a beat so the strip arrives after the opening line rather than
    // alongside it — it reads as the answer to what the character just asked.
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) _runEntrance();
    });
  }

  /// Fade the rows in, light them one at a time, then flash the instruction.
  ///
  /// The whole sequence is ~3.8s. v2's questions land 9.2-12.4s apart, so it
  /// finishes with room to spare before the next set replaces it and the strip
  /// still spends most of its life at rest. It also stops for good once
  /// [_StarterPrompts.teach] goes false.
  void _runEntrance() {
    // Reduce-motion: land the rows and stop. The entry button already honours
    // this setting (_PulsingEnterButton) and it was inconsistent for the very
    // next thing on the same screen to stagger in, run a travelling glow and
    // flash — the exact motion class the preference exists to suppress. The
    // strip is fully usable at rest; only the teaching flourish is skipped.
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _controller.value = 1;
      _attention.value = 0;
      _flash.value = 0;
      return;
    }
    _controller.forward(from: 0);
    _attention.value = 0;
    _flash.value = 0;
    if (!_attentionPasses || !widget.teach) return;

    // Not while a row is mid-confirmation: the tapped row is already drawn as
    // chosen, and lighting the others would argue with it.
    Future.delayed(_attentionDelay, () {
      if (mounted && _selected == null) _attention.forward(from: 0);
    });
    Future.delayed(_attentionDelay + _attentionDuration, () {
      if (mounted && _selected == null) _flash.forward(from: 0);
    });

    if (!_chimes) return;
    // The notes ride the same slot boundaries as the glow, derived from the
    // same two constants, so retuning the pace cannot leave the sound playing
    // against a row that is no longer lighting.
    final slot = _attentionDuration * _glowSlot;
    for (var i = 0; i < 3; i++) {
      Future.delayed(_attentionDelay + slot * i, () {
        if (mounted && _selected == null && widget.teach) playChime(i);
      });
    }
    Future.delayed(_attentionDelay + _attentionDuration, () {
      if (mounted && _selected == null && widget.teach) playChime(3);
    });
  }

  /// Entrance for row [i] — a fade and a short rise, offset from the row above
  /// so the set reads as an enumeration rather than as a panel appearing.
  Animation<double> _entranceFor(int i) {
    final begin = (i * _entranceStagger).clamp(0.0, 1.0);
    return CurvedAnimation(
      parent: _controller,
      curve: Interval(
        begin,
        (begin + _entranceSpan).clamp(0.0, 1.0),
        curve: Curves.easeOut,
      ),
    );
  }

  /// How lit row [i] is during the attention pass, 0–1.
  ///
  /// One 500ms slot per row, back to back, so the strip lights 1, then 2, then
  /// 3 and stops — the controller rests at 1.0, where every slot has closed
  /// and this returns 0 for all rows.
  ///
  /// Deliberately not [_PulsingHighlight]'s `repeat(reverse: true)`: that
  /// marks one persistent target (the message box) and can afford to keep
  /// breathing. Three rows blinking on a loop is the thing that would look
  /// cheap.
  /// Both ramp arguments are clamped rather than trusted. The slot boundaries
  /// are thirds and the ramp is 0.3, so `1 - local` lands on values like
  /// 0.30000000000000004 — divided by the ramp that is 1.0000000000000002, and
  /// [Curve.transform] asserts on anything outside [0, 1].
  double _glowFor(int i) {
    if (!_attentionPasses || !widget.teach) return 0;
    final local = (_attention.value - i * _glowSlot) / _glowSlot;
    if (local <= 0 || local >= 1) return 0;
    if (local < _glowRamp) {
      return Curves.easeOut.transform((local / _glowRamp).clamp(0.0, 1.0));
    }
    if (local < 1 - _glowRamp) return 1;
    return Curves.easeIn.transform(((1 - local) / _glowRamp).clamp(0.0, 1.0));
  }

  /// How hard the instruction is flashing, 0–1 — two beats, then still.
  ///
  /// Two rather than a loop for the same reason the rows do not pulse: a line
  /// that keeps blinking stops being an instruction and becomes an advert.
  double get _flashAmount {
    if (!_attentionPasses || !widget.teach) return 0;
    final v = _flash.value;
    if (v <= 0 || v >= 1) return 0;
    final beat = v * 2;
    return sin((beat - beat.floorToDouble()) * pi);
  }

  /// Wraps a row in its own entrance, so the strip animates per row rather
  /// than as one block.
  Widget _row(int i, Widget child) {
    final t = _entranceFor(i);
    return FadeTransition(
      opacity: t,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.25),
          end: Offset.zero,
        ).animate(t),
        child: child,
      ),
    );
  }

  @override
  void didUpdateWidget(_StarterPrompts oldWidget) {
    super.didUpdateWidget(oldWidget);

    // The lesson is over — they have sent something, so they know the rows are
    // tappable. Handled before the prompt check below, because `teach` flips
    // on the send and the set does not necessarily change with it, and because
    // both controllers have delayed continuations already queued that would
    // otherwise play out over the top of the reply now arriving.
    if (oldWidget.teach && !widget.teach) {
      _attention.stop();
      _attention.value = 0;
      _flash.stop();
      _flash.value = 0;
    }

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
    //
    // This is also what gives the highlight its cadence. Every v2 turn ends on
    // a question and each question brings a new set, so the pass re-runs once
    // per question — roughly every ten seconds — without the strip ever
    // animating on a loop of its own.
    _runEntrance();
  }

  @override
  void dispose() {
    _controller.dispose();
    _attention.dispose();
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Sized against the screen rather than a fixed number of pixels: the strip
    // shares the column with the conversation, and a cap that fits an iPhone
    // eats the whole of a shorter one. Scrollable underneath as a backstop for
    // a prompt that wraps further than expected.
    final screenHeight = MediaQuery.sizeOf(context).height;

    // What yields on a short screen, and why the order changed.
    //
    // This used to drop the third prompt and keep the hint line. That is the
    // wrong way round: the prompt is the functional element and the hint is
    // commentary on it. The screens that trip this threshold are mostly phones
    // with the keyboard up, which is exactly when a one-tap reply is worth
    // most — and v2 bets the whole opening on one-tap answers, so hiding a
    // third of them there defeats the change it was built for.
    //
    // So the hint yields first, and only below [_veryShortScreenHeight], where
    // there is genuinely no room for both, does the third prompt still go.
    final showHint = screenHeight >= _shortScreenHeight;
    final prompts = screenHeight < _veryShortScreenHeight
        ? widget.prompts.take(2).toList()
        : widget.prompts.toList();

    // Row 0 is the hint when it is shown, so the prompts start one later and
    // the highlight begins on the first thing that can actually be tapped.
    final firstPromptRow = showHint ? 1 : 0;

    // "Choose a question" is only true for some sets, so it is not hardcoded.
    //
    // v2's twelve scripted sets are answer-shaped — "Knowing when to let go.",
    // "I like to improvise." — and only the cold-safe fallback sets 13-16 are
    // questions. Telling someone to choose a question above three statements
    // is the kind of small wrongness that makes an interface feel untrustworthy
    // exactly when it is asking for a tap. Same test the fallback pool uses
    // (_ChatScreenState._setStandsAlone): every entry ending in '?'.
    final asksQuestions =
        prompts.every((p) => p.trimRight().endsWith('?'));
    final directive = asksQuestions ? 'Choose a question' : 'Choose your reply';

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: screenHeight * 0.32),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHint)
              _row(
                0,
                AnimatedBuilder(
                  animation: _flash,
                  builder: (context, _) {
                    final f = _flashAmount;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Only the instruction grows. The photo pill sits
                          // outside the transform so it is not swept along by
                          // a flash that is not about it.
                          Flexible(
                            child: Transform.scale(
                              scale: 1 + _flashGrowth * f,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.touch_app_outlined,
                                    size: 15,
                                    color: Color.lerp(theme.primaryColor,
                                        _attentionColor, f),
                                  ),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text.rich(
                                      TextSpan(children: [
                                        TextSpan(
                                          text: directive,
                                          style: GoogleFonts.lato(
                                            color: Color.lerp(
                                                Colors.white.withOpacity(0.75),
                                                _attentionColor,
                                                f),
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        // Kept, and kept uncoloured: typing is
                                        // the other way through and should stay
                                        // offered, but it is not what the flash
                                        // is arguing for.
                                        TextSpan(
                                          text: ' · or type your own',
                                          style: GoogleFonts.lato(
                                            color:
                                                Colors.white.withOpacity(0.55),
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ]),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (widget.onGift != null) ...[
                            const SizedBox(width: 10),
                            _GiftButton(
                              characterName: widget.characterName,
                              onTap: widget.onGift!,
                            ),
                          ],
                          if (widget.onPhoto != null) ...[
                            const SizedBox(width: 10),
                            _PhotoRequestButton(
                              characterName: widget.characterName,
                              onTap: widget.onPhoto!,
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
              ),
            for (var i = 0; i < prompts.length; i++)
              _row(
                firstPromptRow + i,
                AnimatedBuilder(
                  animation: _attention,
                  builder: (context, _) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _StarterButton(
                      label: prompts[i],
                      selected: _selected == prompts[i],
                      // Indexed off the prompts rather than the row, so the
                      // highlight starts on the first thing that can actually
                      // be tapped instead of on the hint above them.
                      glow: _glowFor(i),
                      onTap: () => _select(prompts[i]),
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

/// The photo ask, as a small pill on the hint line.
///
/// Small on purpose: it is the one starter that never varies and never
/// produces conversation — it resolves to the same canned portrait every time
/// — so it should not look like an equal alternative to the character's real
/// questions, and it certainly should not cost a full row to say so.
/// "Gift" — the way into the catalogue from inside the conversation.
///
/// Sits beside the photo button because that is where an in-chat action
/// already lives, and because the coin chip in the app bar was the only door
/// before this: findable if you were looking for it, invisible if you were
/// not. Gold rather than pink, like every other coin surface.
class _GiftButton extends StatelessWidget {
  final String characterName;
  final VoidCallback onTap;

  const _GiftButton({required this.characterName, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final gold = Theme.of(context).colorScheme.secondary;
    return Semantics(
      button: true,
      label: 'Give $characterName a gift',
      child: Material(
        color: gold.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.card_giftcard, size: 14, color: gold),
                const SizedBox(width: 5),
                Text(
                  'Gift',
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

  /// How lit this row is by the strip's one-shot attention pass, 0–1.
  ///
  /// Lifts the existing accent border and adds a soft shadow behind it rather
  /// than introducing a new colour: at rest the row is unchanged, and at full
  /// the difference is about the same as a hover. It has to be noticed at the
  /// edge of vision without ever reading as a separate element that arrived.
  final double glow;

  /// The confirmation colour. Green rather than the accent purple because it
  /// has to mean something different from the resting border, which is already
  /// accent-coloured — the same hue at a higher opacity would read as a hover.
  static const Color _selectedColor = Color(0xFF4ADE80);

  const _StarterButton({
    required this.label,
    required this.onTap,
    this.selected = false,
    this.glow = 0,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // The confirmation wins over the pass. A row that has just been tapped is
    // already saying something with colour, and lighting it accent-purple at
    // the same time would blur the one piece of feedback that matters.
    final lit = selected ? 0.0 : glow.clamp(0.0, 1.0);

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
            : lit > 0
                ? [
                    BoxShadow(
                      color: _selectedColor.withValues(alpha: 0.26 * lit),
                      blurRadius: 6 + 12 * lit,
                    ),
                  ]
                : const [],
      ),
      child: Material(
        color: selected
            ? _selectedColor.withValues(alpha: 0.14)
            : Color.lerp(
                Colors.white.withValues(alpha: 0.07),
                _selectedColor.withValues(alpha: 0.09),
                lit,
              )!,
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
                // Accent purple at rest, green at the top of the pass. The
                // colour change is doing most of the work here — an opacity
                // lift alone was too easy to miss at the edge of vision, which
                // is where this has to be caught.
                color: selected
                    ? _selectedColor
                    : Color.lerp(
                        theme.primaryColor.withOpacity(0.55),
                        _selectedColor.withOpacity(0.95),
                        lit,
                      )!,
                width: selected ? 1.6 : 1 + 0.6 * lit,
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

    // A gift is shown as the thing itself, with no bubble and no words.
    //
    // message.text still carries the stage direction, and deliberately so: it
    // is what the model is answering, and _loadHistory rebuilds the model's
    // view of the conversation from these stored messages — blank it and
    // reopening the chat loses the fact that anything was ever given. It is
    // also the accessibility label. It simply is not drawn, because the
    // picture says it better than "*gives roses to Odysseus*" did.
    //
    // No frame, unlike the portrait above: the art is a cut-out with its own
    // glow, and a rounded box around it reads as a photo of a gift rather
    // than a gift.
    final giftAsset = message.giftAsset;
    if (giftAsset != null) {
      return Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: EdgeInsets.only(bottom: gap),
          child: Semantics(
            label: message.text,
            image: true,
            child: SizedBox(
              width: 104,
              height: 104,
              child: Image.asset(giftAsset, fit: BoxFit.contain),
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

