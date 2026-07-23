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
    'zeus',
    'odysseus',
    'oedipus',
    'penelope',
    'cupid',
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
