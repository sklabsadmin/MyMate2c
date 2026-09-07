import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

/// The native half of the visit funnel. On the web the page script in
/// index.html is the beacon; an installed app has no page, so this file does
/// what the page does: mints one visit id per app launch, opens the visit
/// (arrive, app_ready), reports the same lifecycle edges (hide/show/leave),
/// and posts every in-app funnel event to the same unauthenticated
/// /api/visit endpoint with the same field names.
///
/// What it deliberately does differently:
///  - appPlatform declares 'ios' or 'android' (the page declares 'web'),
///    which is the whole point — one funnel, comparable across surfaces.
///  - visibleMs/touchCount stay unsent. The page measures them; here they
///    would be guesses, and an absent number reads as unknown, never zero.
///  - variant stays unsent: only the page draws an A/B arm, so native
///    visits are simply outside any copy experiment (and get the default
///    card, exactly as AppConfig.coinsPromiseHeldBack(null) decides).
///  - isDev rides kDebugMode: every `flutter run` session marks itself,
///    the same way ?dev=1 marks a browser.
///
/// Silent on every failure, and entirely dead when no backend is configured
/// (AppConfig.apiUrl answers '' — which is also what keeps widget tests,
/// whose conditional import resolves here on the VM, from ever touching a
/// network: same observable behavior as the old no-op stub).
class _NativeFunnel {
  _NativeFunnel()
      : visitId = 'n${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
            '${Random().nextInt(0x7fffffff).toRadixString(36)}';

  /// One visit per app process, minted eagerly so chat requests can carry
  /// x-visit-id (via [currentVisitId]) even for a send racing the arrive.
  /// The 'n' prefix makes native rows recognisable at a glance in the raw
  /// export; nothing parses it.
  final String visitId;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    sendTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
  ));

  final DateTime _startedAt = DateTime.now();
  bool _started = false;
  int? _isReturn;
  String? _appVersion;

  /// All sends ride one chain so order is preserved: arrive lands before
  /// app_ready lands before the first in-app event, whatever the network
  /// does. Each link swallows its own failure, so one lost beacon never
  /// stalls the rest.
  Future<void> _chain = Future.value();

  bool get alive => AppConfig.apiUrl('/api/visit').isNotEmpty;

  void ensureStarted() {
    if (_started || !alive) return;
    _started = true;
    _chain = _chain.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        // Same name the page keeps in localStorage; a different store, so a
        // person who used both surfaces reads as new once on each — the same
        // blind spot the web's own per-browser flag already has.
        _isReturn = prefs.getBool('mythos_seen') == true ? 1 : 0;
        await prefs.setBool('mythos_seen', true);
      } catch (_) {}
      try {
        final info = await PackageInfo.fromPlatform();
        _appVersion = '${info.version}+${info.buildNumber}';
      } catch (_) {}
      await _post('arrive');
      await _post('app_ready');
    });
    // The visit's lifecycle edges. `paused` is the app going to background —
    // the web's visibilitychange — and `detached` is as close to pagehide as
    // a process that can be killed without warning ever gets; like the web,
    // the hide checkpoints are the trustworthy record of how far the visit
    // really ran.
    WidgetsBinding.instance.addObserver(_FunnelLifecycleObserver(this));
  }

  void log(String event,
      {String? detail, String? appUserId, String? failureReason}) {
    if (!alive) return;
    ensureStarted();
    _chain = _chain.then((_) =>
        _post(event, detail: detail, appUserId: appUserId, failureReason: failureReason));
  }

  Future<void> _post(String event,
      {String? detail, String? appUserId, String? failureReason}) async {
    try {
      await _dio.post(
        AppConfig.apiUrl('/api/visit'),
        data: {
          'visitId': visitId,
          'event': event,
          'durationMs': DateTime.now().difference(_startedAt).inMilliseconds,
          'detail': ?detail,
          'appUserId': ?appUserId,
          'failureReason': ?failureReason,
          'appVersion': ?_appVersion,
          if (Platform.isIOS) 'appPlatform': 'ios',
          if (Platform.isAndroid) 'appPlatform': 'android',
          if (_isReturn != null) 'isReturn': _isReturn,
          if (kDebugMode) 'isDev': 1,
        },
        options: Options(validateStatus: (_) => true),
      );
    } catch (_) {
      // Analytics must never be able to break the app. Same rule as the web
      // beacon, same silence.
    }
  }
}

class _FunnelLifecycleObserver with WidgetsBindingObserver {
  _FunnelLifecycleObserver(this._funnel);
  final _NativeFunnel _funnel;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
        _funnel.log('hide');
      case AppLifecycleState.resumed:
        _funnel.log('show');
      case AppLifecycleState.detached:
        _funnel.log('leave');
      default:
        break;
    }
  }
}

final _NativeFunnel _funnel = _NativeFunnel();

/// Opens the visit: arrive + app_ready, and the lifecycle edges from here on.
/// Called once from main() on every platform; the web and stub versions
/// no-op (the page already opened the visit before Flutter existed).
void startVisitFunnel() => _funnel.ensureStarted();

/// Fires one funnel event, tagging it with the app's own user id where known
/// so a visit can be joined to its chat transcripts. Same contract as the
/// web version; fire-and-forget, silent on failure.
void logFunnelEvent(
  String event, {
  String? detail,
  String? appUserId,
  String? failureReason,
}) {
  _funnel.log(event,
      detail: detail, appUserId: appUserId, failureReason: failureReason);
}

/// This app launch's visit id — sent as x-visit-id on chat requests so
/// conversation_logs, message_delivery and coin_ledger rows join onto the
/// same visit the funnel events belong to, exactly as on the web. Null when
/// no backend is configured (tests, unconfigured dev runs), where nothing
/// is being recorded to join onto.
String? currentVisitId() => _funnel.alive ? _funnel.visitId : null;

/// Null off the web: only the page script draws an A/B arm.
String? currentVariant() => null;
