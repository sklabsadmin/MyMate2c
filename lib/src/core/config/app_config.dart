import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConfig {
  // CONFIGURATION
  // --------------------------------------------------------------------------

  /// Toggle this to TRUE for the initial release to hide all payment features.
  /// When ready for monetization, set this to FALSE.
  static const bool isFreeTier = true;

  /// Shows a holding page instead of the app on launch, so casual visitors to
  /// the live URL don't wander through a work-in-progress build. Set to FALSE
  /// to launch straight into the app.
  ///
  /// It is a soft gate, not access control: pressing Tab (or long-pressing the
  /// artwork on touch devices, which have no Tab key) enters the real app with
  /// everything working normally. Anyone who knows the trick — or who reads the
  /// shipped JavaScript — gets in, which is the point. It filters the casual,
  /// nothing more, so don't rely on it to hide anything sensitive.
  static const bool showMaintenanceGate = false;

  /// Set once the user has tabbed past the gate. Deliberately in-memory only:
  /// a reload shows the holding page again, which is the desired behaviour for
  /// a page whose whole job is to greet new arrivals.
  static bool maintenanceGateBypassed = false;

  /// Where the visitor was headed when the gate intercepted them, so passing
  /// it resumes that route. In-memory alongside the bypass flag: a reload
  /// shows the holding page again, which is the point of it.
  static String? gatedDestination;

  /// The 1.7.1 entry gate: a card over the chat naming the character, with one
  /// button, that has to be tapped before the conversation begins.
  ///
  /// The bluntest possible form of the question this release exists to ask.
  /// [requireInteractionToContinue] measures whether a visitor will engage with
  /// what the character said, which confounds willingness with whether the
  /// opening was any good; this measures whether they will tap anything at all.
  /// One unambiguous target, on screen at first paint, with nothing to read
  /// first — if this does not get a tap, no amount of writing was going to.
  ///
  /// It also holds the opening back until it is tapped, which is the part that
  /// matters for the receipts: nothing is declared to the delivery log until
  /// someone is actually watching, so "intended but never drawn" stops counting
  /// lines said into an empty room.
  ///
  /// Separate switch from the story freeze on purpose. They are two different
  /// claims and this codebase changes one variable at a time at this traffic
  /// level; either can run without the other.
  static bool requireTapToEnter = true;

  /// The 1.7.1 interaction gate. The character speaks its opening turn and
  /// then stops, saying nothing further until the visitor answers — no timeout
  /// resumes it and the idle nudge is suppressed under it.
  ///
  /// What it buys is a measurement we have never had. In the 30 days to
  /// 2026-08-17, 3,490 visits reached a chat screen and 49 contained a
  /// keystroke or a tap; the screen performed at all 3,490 identically, so
  /// "was offered something and declined" and "never understood there was an
  /// offer" were the same row in the table. A story that will not move without
  /// an answer separates them: gate_choice / gate_shown is engagement measured
  /// against people demonstrably asked.
  ///
  /// Set to FALSE to restore 1.7.0 behaviour — the opening plays itself out —
  /// without reverting code. This freezes the first screen on the path every
  /// campaign link lands on, which is the whole of the paid traffic, so the way
  /// back needs to be one constant rather than an unpick across the release.
  ///
  /// OFF, deliberately, while [requireTapToEnter] is on.
  ///
  /// The two gates ask the same question and only one of them needs to. The
  /// goal is a pulse — any deliberate act at all from a population where 3,457
  /// of 3,506 visitors who reached a chat screen in the 30 days to 2026-08-17
  /// did nothing whatsoever. One unmissable ask is how you take a pulse;
  /// stacking a second gate behind the first spends the same scarce attention
  /// twice and makes a null result harder to read, not easier.
  ///
  /// So the entry card takes the reading, and once it is answered the
  /// experience is the one that was already written: the opening plays through
  /// as its authors intended. That also makes the scripts whole again —
  /// Hercules has 33 turns and Calypso 37, and with this on, everything past
  /// the first question was unreachable.
  ///
  /// Turn it back on to freeze the story on an unanswered question, which is
  /// the sharper instrument if the entry card turns out to get taps from people
  /// who then sit through the opening without engaging.
  ///
  /// Not `const`: the gate tests turn it on to exercise the freeze.
  static bool requireInteractionToContinue = false;

  /// Which built-in characters (by id) to show on the dashboard, and in
  /// what order. Hides the rest without deleting their definitions. Does
  /// not affect user-created custom characters, which are always shown
  /// after this list.
  static const List<String> visibleCharacterIds = [
    ...greekCharacterIds,
    ...modernCharacterIds,
  ];

  /// Dashboard groups, rendered as labelled sections in this order. An id
  /// listed here must exist in dashboard_screen.dart's _characters list.
  /// Moving an id between groups only changes where its card appears — the
  /// character itself, and which engine the worker picks for it, is
  /// unaffected.
  static const List<String> greekCharacterIds = [
    'odysseus',
    'penelope',
    'hercules',
    'zeus',
    'andromache',
    'hector',
    'calypso',
    'cupid',
    'oedipus',
  ];

  static const List<String> modernCharacterIds = [
    'badboy',
    'poet',
    'surfer',
  ];

  /// Section headings for the two groups above.
  static const String greekSectionTitle = 'Greek';
  static const String modernSectionTitle = 'Modern';

  /// Whether the dashboard offers user-created custom characters: the
  /// "Create Custom" card and any already-created ones. Set to TRUE to
  /// bring the feature back.
  static const bool enableCustomCharacters = false;

  /// Range (inclusive) for the randomized pause, in milliseconds, before
  /// each chat bubble is revealed when a reply is split into multiple
  /// bubbles (see ChatScreen._splitIntoBubbles). Must have
  /// minBubbleDelayMs <= maxBubbleDelayMs.
  static const int minBubbleDelayMs = 2000;
  static const int maxBubbleDelayMs = 5000;

  /// While waiting on a slow AI reply, the typing indicator cycles through
  /// short status phrases ("Zeus is thinking…", "still writing…") so the
  /// user sees visible progress. A new phrase fades in every interval; the
  /// first one appears after one interval, so fast replies only ever show
  /// the animated dots.
  static const int typingStatusIntervalMs = 4000;

  /// How many successful AI replies a signed-out user gets per character
  /// before the login gate appears. Counted per character and persisted
  /// on-device; welcome messages and failed/"trouble thinking" replies do
  /// not count. Signing in removes the limit entirely.
  static const int freeRepliesPerCharacter = 20;

  /// The app is designed as a portrait, phone-shaped experience — two card
  /// columns, one chat column. Left unconstrained, a desktop window stretches
  /// the header and nav bar to the full width while the grid stays centred at
  /// its own cap, which reads as a layout bug rather than a wide layout.
  ///
  /// So the whole shell is capped and centred at this width and the rest of
  /// the window becomes surround. Resizing still does whatever the user wants;
  /// this only decides how it opens. Comfortably above the grid's own 560 cap
  /// so the grid, not this, stays the thing deciding card size.
  static const double maxShellWidth = 640;

  /// The model to use.
  static const String openAiModel = 'gpt-4o-mini';

  /// Backend Worker Configuration
  static const String _workerUrlFromDefine = String.fromEnvironment(
    'WORKER_URL',
  );
  static const String _appSecretFromDefine = String.fromEnvironment(
    'APP_SECRET',
  );

  static String get workerUrl {
    if (_workerUrlFromDefine.isNotEmpty) {
      return _workerUrlFromDefine;
    }

    if (kIsWeb) {
      return Uri.base.origin;
    }

    return dotenv.env['WORKER_URL'] ?? '';
  }

  static String get appSecret {
    if (_appSecretFromDefine.isNotEmpty) return _appSecretFromDefine;
    if (kIsWeb || !dotenv.isInitialized) return '';
    return dotenv.env['APP_SECRET'] ?? ''; // For HMAC
  }

  static String apiUrl(String path, {Map<String, String>? queryParameters}) {
    if (workerUrl.isEmpty) return '';
    final base = Uri.parse(workerUrl);
    return base
        .replace(path: path, queryParameters: queryParameters)
        .toString();
  }

  static String chatUrl() => apiUrl('/api/chat');

  /// Where delivery receipts go — what the client actually drew on screen.
  ///
  /// Signed with the same HMAC as chatUrl() where a secret exists, which on web
  /// is nowhere: appSecret is deliberately empty there, so REQUIRE_SIGNATURE is
  /// off in production and this endpoint is as unauthenticated as /api/visit
  /// already is. What keeps the table clean is the worker's user-id guard and
  /// its batch cap, not the signature.
  static String deliveryUrl() => apiUrl('/api/delivery');

  /// How long the client waits after a receipt changes before flushing, so the
  /// several bubbles of one reply leave together instead of as one request each.
  ///
  /// "Instantly" in the sense that matters — a quarter second is far below the
  /// pacing between bubbles (minBubbleDelayMs is 2000), so a receipt is still
  /// on its way before the next bubble is drawn. Per-bubble requests were the
  /// alternative and would have meant five in-flight posts during a single
  /// reply on a connection already suspected of dropping them.
  static const int deliveryFlushDebounceMs = 250;

  /// Receipts per request. Matches DELIVERY_BATCH_MAX in the worker, which
  /// refuses anything larger — a queue that drained after a long outage is
  /// split into batches of this size rather than sent as one oversized post
  /// that can never succeed.
  static const int deliveryBatchMax = 200;

  /// How many receipts the local queue holds before it starts discarding the
  /// oldest.
  ///
  /// A bound is necessary — the queue lives in SharedPreferences (localStorage
  /// on web) and an unbounded one would eventually throw and take the chat down
  /// with it. Set high enough that only a genuinely long outage reaches it: a
  /// busy session produces tens of receipts, not thousands. Reaching this cap is
  /// itself a finding, and the count of what was dropped rides along on the next
  /// flush so it does not vanish silently.
  static const int deliveryQueueMax = 1000;

  static String instagramAuthUrl(String returnTo) {
    return apiUrl(
      '/auth/instagram/start',
      queryParameters: {'return_to': returnTo},
    );
  }

  static String googleAuthUrl(String returnTo, {String? anonId}) {
    return apiUrl(
      '/auth/google/start',
      queryParameters: {
        'return_to': returnTo,
        if (anonId != null && anonId.isNotEmpty) 'anon_id': anonId,
      },
    );
  }
}
