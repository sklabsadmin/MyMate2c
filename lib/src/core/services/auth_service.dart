import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

/// Current login state, derived from the backend's /auth/me endpoint.
class AuthState {
  final bool authenticated;
  final String? provider; // "google" | "instagram"
  final String? username; // display name or email

  const AuthState({
    this.authenticated = false,
    this.provider,
    this.username,
  });

  static const AuthState signedOut = AuthState();
}

/// App-wide auth status. Checks /auth/me (same-origin, cookie included) on
/// first read and can be refreshed after returning from an OAuth redirect.
/// Persists a `has_linked_account` flag once a login ever succeeds, so the
/// UI can distinguish "never linked" from "linked but session expired".
class AuthNotifier extends AsyncNotifier<AuthState> {
  static const String _kHasLinkedKey = 'has_linked_account';

  @override
  Future<AuthState> build() => _fetch();

  Future<AuthState> _fetch() async {
    // Cookie-based sessions only exist on web (same-origin). On mobile the
    // app is always "signed out" for gate purposes until native auth exists.
    if (!kIsWeb) return AuthState.signedOut;
    final url = AppConfig.apiUrl('/auth/me');
    if (url.isEmpty) return AuthState.signedOut;
    try {
      final res = await Dio().get(
        url,
        options: Options(extra: {'withCredentials': true}),
      );
      final data = res.data;
      if (data is Map && data['authenticated'] == true) {
        final user = data['user'];
        if (user is Map) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(_kHasLinkedKey, true);
          return AuthState(
            authenticated: true,
            provider: user['provider'] as String?,
            username: user['username'] as String?,
          );
        }
      }
    } catch (_) {
      // Offline or unreachable - treat as signed out rather than erroring.
    }
    return AuthState.signedOut;
  }

  /// Re-check /auth/me (e.g. after an OAuth redirect completes).
  Future<void> refresh() async {
    state = const AsyncLoading();
    state = AsyncData(await _fetch());
  }

  /// Whether a login has ever succeeded on this device.
  static Future<bool> hasEverLinked() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kHasLinkedKey) ?? false;
  }
}

final authProvider =
    AsyncNotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
