import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/config/app_config.dart';
import '../../core/services/delivery_log.dart';

/// Mythos Coins, client side.
///
/// Everything that involves trust lives on the worker: amounts, prices, caps,
/// idempotency. This file only asks, caches, and draws — the client never
/// decides what anything costs (it reads prices out of every wallet response)
/// and never computes a balance (it shows the one the server said).
///
/// The server may also say the feature is off (`enabled: false`), which is a
/// normal answer, not an error: the UI hides and nothing retries. That is the
/// DELIVERY_LOGGING off-switch contract, seen from this side.

/// One grant the server just made, for the "+10 Dawn offering" moment.
class CoinGrant {
  final String reason;
  final int delta;
  const CoinGrant(this.reason, this.delta);

  /// Player-facing name for a grant reason. Server vocabulary on the left so
  /// a new reason shows up as itself rather than crashing a toast.
  String get label => switch (reason) {
        'welcome' => 'Welcome gift',
        'daily' => 'Dawn offering',
        'reply' => 'Conversation',
        'link' => 'Account linked',
        'profile' => 'Profile complete',
        _ => reason,
      };
}

class CoinWalletState {
  final bool enabled;
  final int balance;
  final int lifetimeEarned;
  final int lifetimeSpent;
  final int replyGrantsToday;
  final int replyGrantCap;

  /// Gift prices by catalogue key (roses/ambrosia/pendant), straight from the
  /// server. Empty until a full wallet read has happened — the client never
  /// invents a price, so an empty map means "not priced yet", not "free".
  final Map<String, int> tributePrices;

  /// The most recent ledger rows, newest first, as the server sent them.
  final List<Map<String, dynamic>> recent;

  /// Character ids this person has already given a pendant to. Derived by the
  /// server from the ledger, so it cannot drift from what was charged.
  final List<String> pendants;

  /// What each faucet pays, by server key (daily/reply/link/profile). Like
  /// [tributePrices], the client holds no opinion of its own — an empty map
  /// means "not read yet", and the earn list simply shows no figures.
  final Map<String, int> grantValues;

  /// What the latest sync or chat turn granted — consumed once by the UI for
  /// a toast (see [CoinWalletNotifier.takeGrants]), never persisted.
  final List<CoinGrant> lastGranted;

  const CoinWalletState({
    required this.enabled,
    this.balance = 0,
    this.lifetimeEarned = 0,
    this.lifetimeSpent = 0,
    this.replyGrantsToday = 0,
    this.replyGrantCap = 0,
    this.tributePrices = const {},
    this.recent = const [],
    this.pendants = const [],
    this.grantValues = const {},
    this.lastGranted = const [],
  });

  CoinWalletState copyWith({
    int? balance,
    List<CoinGrant>? lastGranted,
    List<Map<String, dynamic>>? recent,
    List<String>? pendants,
  }) {
    return CoinWalletState(
      enabled: enabled,
      balance: balance ?? this.balance,
      lifetimeEarned: lifetimeEarned,
      lifetimeSpent: lifetimeSpent,
      replyGrantsToday: replyGrantsToday,
      replyGrantCap: replyGrantCap,
      tributePrices: tributePrices,
      recent: recent ?? this.recent,
      pendants: pendants ?? this.pendants,
      grantValues: grantValues,
      lastGranted: lastGranted ?? this.lastGranted,
    );
  }

  /// Parses a /api/wallet response body. Returns null for shapes that carry
  /// no wallet at all (unrecognised id → `wallet: null`), and a disabled
  /// state for `enabled: false`.
  static CoinWalletState? fromResponse(Map<String, dynamic> data) {
    if (data['enabled'] == false) return const CoinWalletState(enabled: false);
    final wallet = data['wallet'];
    if (wallet is! Map) return null;
    final today = wallet['today'];
    final prices = wallet['prices'];
    final gift = prices is Map ? prices['gift'] : null;
    return CoinWalletState(
      enabled: true,
      balance: _asInt(wallet['balance']),
      lifetimeEarned: _asInt(wallet['lifetime_earned']),
      lifetimeSpent: _asInt(wallet['lifetime_spent']),
      replyGrantsToday: today is Map ? _asInt(today['reply_grants']) : 0,
      replyGrantCap: today is Map ? _asInt(today['reply_grant_cap']) : 0,
      tributePrices: gift is Map
          ? gift.map((k, v) => MapEntry(k.toString(), _asInt(v)))
          : const {},
      recent: (wallet['recent'] is List)
          ? [
              for (final row in wallet['recent'] as List)
                if (row is Map) Map<String, dynamic>.from(row),
            ]
          : const [],
      pendants: (wallet['pendants'] is List)
          ? [for (final id in wallet['pendants'] as List) '$id']
          : const [],
      grantValues: wallet['grants'] is Map
          ? (wallet['grants'] as Map)
              .map((k, v) => MapEntry(k.toString(), _asInt(v)))
          : const {},
      lastGranted: parseGrants(data['granted']),
    );
  }

  static List<CoinGrant> parseGrants(dynamic granted) {
    if (granted is! List) return const [];
    return [
      for (final g in granted)
        if (g is Map) CoinGrant(g['reason'].toString(), _asInt(g['delta'])),
    ];
  }

  static int _asInt(dynamic v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);
}

/// Talks to /api/wallet on the worker. Same request shape as OpenAIService:
/// HMAC over body + timestamp, the canonical device id in x-user-id, and
/// credentials sent so a signed-in session's cookie decides identity instead.
class CoinWalletService {
  final Dio _dio = Dio();

  Future<CoinWalletState?> sync() async {
    final url = AppConfig.apiUrl('/api/wallet/sync');
    if (url.isEmpty) return null;
    try {
      // The one true minting path for the device id — reading the pref
      // directly is how 100% of character_tap rows lost their user id.
      final prefs = await SharedPreferences.getInstance();
      final userId = DeliveryLog.ensureUserId(prefs);

      final now = DateTime.now();
      final localDate = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final body = jsonEncode({
        'local_date': localDate,
        'app_version': await _appVersion(),
      });
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();

      final res = await _dio.post(
        url,
        data: body,
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'x-signature': _sign(body, timestamp),
            'x-timestamp': timestamp,
            'x-user-id': userId,
          },
          extra: {'withCredentials': true},
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      final data = res.data;
      if (res.statusCode != 200 || data is! Map) return null;
      return CoinWalletState.fromResponse(Map<String, dynamic>.from(data));
    } catch (e) {
      // Offline, blocked storage, mid-deploy — all normal here. The cached
      // state stays on screen and the next sync tells the truth.
      if (kDebugMode) debugPrint('Coin sync failed: $e');
      return null;
    }
  }

  /// The version the beacon and delivery receipts already report; absent is
  /// fine (the ledger stores NULL, which means "not measured"). Short timeout
  /// for the same reason DeliveryLog has one: on web this is a fetch of
  /// version.json, and a sync must not wait on it.
  Future<String?> _appVersion() async {
    try {
      final info = await PackageInfo.fromPlatform()
          .timeout(const Duration(seconds: 3));
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return null;
    }
  }

  String _sign(String body, String timestamp) {
    final secret = AppConfig.appSecret;
    if (secret.isEmpty) return '';
    return Hmac(sha256, utf8.encode(secret))
        .convert(utf8.encode(body + timestamp))
        .toString();
  }
}

final coinWalletServiceProvider = Provider<CoinWalletService>((ref) {
  return CoinWalletService();
});

final coinWalletProvider =
    AsyncNotifierProvider<CoinWalletNotifier, CoinWalletState?>(
        CoinWalletNotifier.new);

/// Holds the wallet the UI draws.
///
/// Two rules learned from the counters that came before it:
///  - build() returns the cached copy first, so the chip never flashes 0 (or
///    pops into existence) on every launch the way user_score_v1 does;
///  - the fresh truth arrives from the network afterwards and replaces it.
///
/// null state = nothing known yet AND nothing cached — the UI shows the old
/// ♥ Level column, which is also what a disabled wallet shows. The flag can
/// therefore flip off in production and the header simply goes back to what
/// it was.
class CoinWalletNotifier extends AsyncNotifier<CoinWalletState?> {
  static const String _kCacheKey = 'coin_wallet_cache_v1';

  @override
  Future<CoinWalletState?> build() async {
    if (!AppConfig.coinsUiEnabled) return null;
    final cached = await _readCache();
    // Deliberately un-awaited: the cached paint must not wait on the network.
    _refresh();
    return cached;
  }

  Future<void> _refresh() async {
    final fresh = await ref.read(coinWalletServiceProvider).sync();
    if (fresh == null) return; // keep whatever we had
    state = AsyncData(fresh);
    await _writeCache(fresh);
  }

  /// Public nudge for moments identity changes under us (returning from
  /// Google sign-in) or the user asks to see the latest.
  Future<void> refresh() => _refresh();

  /// Applies the `wallet` block that rides on every /api/chat response, so
  /// the chip moves with the conversation without a second request.
  void applyFromChat(Map<String, dynamic> wallet) {
    if (wallet['enabled'] == false) {
      state = const AsyncData(CoinWalletState(enabled: false));
      return;
    }
    final current = state.value;
    if (current == null || !current.enabled) {
      // First sight of an enabled wallet mid-chat: take the balance now, let
      // the next sync fill in prices and history.
      state = AsyncData(CoinWalletState(
        enabled: true,
        balance: CoinWalletState._asInt(wallet['balance']),
        lastGranted: CoinWalletState.parseGrants(wallet['granted']),
      ));
      return;
    }
    final next = current.copyWith(
      balance: CoinWalletState._asInt(wallet['balance']),
      lastGranted: CoinWalletState.parseGrants(wallet['granted']),
    );
    state = AsyncData(next);
    _writeCache(next);
  }

  /// Hands the pending grant toasts to the UI exactly once.
  List<CoinGrant> takeGrants() {
    final current = state.value;
    final grants = current?.lastGranted ?? const [];
    if (current != null && grants.isNotEmpty) {
      state = AsyncData(current.copyWith(lastGranted: const []));
    }
    return grants;
  }

  Future<CoinWalletState?> _readCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCacheKey);
      if (raw == null) return null;
      final data = jsonDecode(raw);
      if (data is! Map) return null;
      if (data['enabled'] != true) return null;
      return CoinWalletState(
        enabled: true,
        balance: CoinWalletState._asInt(data['balance']),
        tributePrices: (data['prices'] is Map)
            ? (data['prices'] as Map)
                .map((k, v) => MapEntry(k.toString(), CoinWalletState._asInt(v)))
            : const {},
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(CoinWalletState s) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCacheKey, jsonEncode({
        'enabled': s.enabled,
        'balance': s.balance,
        'prices': s.tributePrices,
      }));
    } catch (_) {
      // Restricted storage: the chip just re-syncs next launch.
    }
  }
}
