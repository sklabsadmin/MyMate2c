import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The iOS App Clip, as far as Dart can tell.
///
/// The Clip (`ios/MythosLiveClip`) and the full app are two Xcode targets
/// built from the same Dart code, so there is no separate entrypoint. What
/// differs is the native side: only the Clip's AppDelegate registers the
/// `mythoslive/app_clip` channel. [detect] asks it for the invocation URL; a
/// MissingPluginException means "this is the full app" (or web, Android, a
/// test), and [isActive] stays false.
///
/// Call [detect] once in main() before anything that reads [isActive].
class AppClip {
  AppClip._();

  static const MethodChannel _channel = MethodChannel('mythoslive/app_clip');

  static bool _active = false;
  static Uri? _invocationUrl;

  /// True when running inside the App Clip target.
  static bool get isActive => _active;

  /// The link the Clip was invoked from, e.g.
  /// https://chat.deeploveechoes.com/c/odysseus. Null in the full app, and in
  /// a Clip launched without one (the App Clip card's default link, or Xcode
  /// without `_XCAppClipURL`).
  static Uri? get invocationUrl => _invocationUrl;

  /// Where the router should start: the character chat the link names, or
  /// the dashboard when the link names nothing the app knows.
  static String get initialLocation => routeForInvocation(_invocationUrl);

  static Future<void> detect() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      final raw = await _channel.invokeMethod<String>('invocationUrl');
      _active = true;
      _invocationUrl = raw == null ? null : Uri.tryParse(raw);
    } on MissingPluginException {
      _active = false;
    } on PlatformException {
      _active = false;
    }
  }

  /// Shows the App Store overlay for the full app (SKOverlay). No-op outside
  /// the Clip.
  static Future<void> showAppStoreOverlay() async {
    if (!_active) return;
    try {
      await _channel.invokeMethod<void>('showAppStoreOverlay');
    } on PlatformException {
      // Nothing to do: the overlay is a nicety, not a step the flow needs.
    }
  }

  /// Visible for tests; pure.
  @visibleForTesting
  static void debugSet({required bool active, Uri? invocationUrl}) {
    _active = active;
    _invocationUrl = invocationUrl;
  }
}

/// Maps an invocation URL onto an app route. Only campaign links (/c/<id>)
/// are honoured, with the id cleaned the way app.dart's route does it (leading
/// id characters only, lower-cased), and the query kept so ?initialMessage=
/// survives. Anything else lands on the dashboard; the /c/ route itself turns
/// an unknown id into a dashboard redirect.
String routeForInvocation(Uri? url) {
  if (url == null) return '/dashboard';
  final segments = url.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length < 2 || segments.first != 'c') return '/dashboard';
  final id = RegExp(r'^[a-z0-9_-]+').stringMatch(segments[1].trim().toLowerCase());
  if (id == null) return '/dashboard';
  final route = Uri(path: '/c/$id', query: url.hasQuery ? url.query : null);
  return route.toString();
}
