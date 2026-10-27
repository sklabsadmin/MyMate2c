import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../features/wallet/coin_wallet.dart';
import '../config/app_config.dart';
import 'delivery_log.dart';
import 'revenue_cat_service.dart';

/// Which account a person signs in with.
enum SignInProvider { google, apple }

/// How a sign-in attempt ended. [redirected] is the web: the page is leaving
/// for the provider and the result arrives on the reload.
enum SignInOutcome { signedIn, cancelled, failed, redirected }

/// Current login state, derived from the backend's /auth/me endpoint.
class AuthState {
  final bool authenticated;
  final String? provider; // "google" | "apple" | "instagram"
  final String? username; // display name or email

  /// The server's user id for this account ("google:<sub>", "apple:<sub>").
  /// The id the wallet, chat logs and RevenueCat are keyed by once signed in.
  final String? userId;
  final String? email;

  /// Google account avatar URL. Null for Apple and Instagram sessions and when
  /// Google returns no picture, so every use has to handle its absence.
  final String? avatarUrl;

  const AuthState({
    this.authenticated = false,
    this.provider,
    this.username,
    this.userId,
    this.email,
    this.avatarUrl,
  });

  static const AuthState signedOut = AuthState();

  factory AuthState.fromUser(Map user) => AuthState(
        authenticated: true,
        provider: user['provider'] as String?,
        username: user['username'] as String?,
        userId: user['id'] as String?,
        email: user['email'] as String?,
        avatarUrl: user['picture'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'provider': provider,
        'username': username,
        'id': userId,
        'email': email,
        'picture': avatarUrl,
      };

  /// "Apple" / "Google", for copy like "Signed in with Apple".
  String get providerLabel => switch (provider) {
        'apple' => 'Apple',
        'google' => 'Google',
        'instagram' => 'Instagram',
        _ => 'your account',
      };
}

/// The app's session token: what the web keeps in an HttpOnly cookie, the app
/// keeps here and sends as `Authorization: Bearer` (the worker accepts
/// either). Native only — on the web this class holds nothing and every
/// request rides the cookie instead.
///
/// Lives in the keychain with the same accessibility as DeviceIdentity, so a
/// reinstall or a new phone restored from backup comes back signed in — which
/// is the point of signing in: the coins are on the account, not the device.
class AuthSession {
  static const String _kToken = 'auth_session_token';
  static const String _kUser = 'auth_user_json';

  static String? _token;
  static bool _restored = false;

  static FlutterSecureStorage? get _vault => kIsWeb
      ? null
      : const FlutterSecureStorage(
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.first_unlock,
          ),
        );

  /// Call once in main(), before anything sends a request. Never throws.
  static Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    try {
      _token = await _vault?.read(key: _kToken);
    } catch (e) {
      if (kDebugMode) debugPrint('AuthSession restore failed: $e');
    }
  }

  static String? get token => (_token == null || _token!.isEmpty) ? null : _token;
  static bool get isSignedIn => token != null;

  /// Spread into every request the worker resolves identity for. Synchronous
  /// so header-building code stays synchronous.
  static Map<String, String> header() {
    final t = token;
    // A fresh, mutable map every time: some callers hand it straight to Dio
    // as Options.headers, and Dio adds to the map it is given.
    return t == null ? <String, String>{} : {'Authorization': 'Bearer $t'};
  }

  /// The account id the token speaks for, read from its payload. Unverified —
  /// the worker is what checks the signature — and used only to key this
  /// device's own RevenueCat customer, so a forged value gains nothing.
  static String? get userId {
    final t = token;
    if (t == null) return null;
    try {
      final payload = t.split('.').first;
      final json = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload))));
      if (json is! Map) return null;
      final provider = json['provider'];
      final sub = json['sub'] ?? json['googleId'];
      if ((provider == 'google' || provider == 'apple') && sub is String) {
        return '$provider:$sub';
      }
    } catch (_) {}
    return null;
  }

  static Future<void> save(String token, AuthState user) async {
    _token = token;
    try {
      await _vault?.write(key: _kToken, value: token);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kUser, jsonEncode(user.toJson()));
    } catch (e) {
      if (kDebugMode) debugPrint('AuthSession save failed: $e');
    }
  }

  static Future<void> clear() async {
    _token = null;
    try {
      await _vault?.delete(key: _kToken);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kUser);
    } catch (e) {
      if (kDebugMode) debugPrint('AuthSession clear failed: $e');
    }
  }

  /// Who we last knew was signed in, for showing the account while offline.
  static Future<AuthState?> cachedUser() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kUser);
      if (raw == null) return null;
      final user = jsonDecode(raw);
      return user is Map ? AuthState.fromUser(user) : null;
    } catch (_) {
      return null;
    }
  }
}

/// App-wide auth status, plus the sign-in, sign-out and delete-account
/// actions every screen shares.
///
/// Web: the session is the worker's cookie, sign-in is a full-page redirect
/// to Google or Apple, and the result is read back from /auth/me on reload.
/// iOS: the native Google / Apple sheet hands us an ID token, the worker
/// verifies it (POST /auth/native) and returns a session token kept by
/// [AuthSession]. Either way the worker merges this device's anonymous chat
/// history and coin wallet onto the account in the same moment.
///
/// Persists a `has_linked_account` flag once a login ever succeeds, so the UI
/// can distinguish "never linked" from "linked but session expired".
class AuthNotifier extends AsyncNotifier<AuthState> {
  static const String _kHasLinkedKey = 'has_linked_account';

  static bool _googleInitialized = false;

  /// Sign in with Apple is offered wherever Google is (App Review 4.8). On the
  /// web it is the redirect flow; natively, iOS only for now — Android would
  /// need the web flow inside a Custom Tab, which is not wired up.
  static bool get appleAvailable =>
      kIsWeb || defaultTargetPlatform == TargetPlatform.iOS;

  /// Whether this build can sign in at all. Android has no native client yet.
  static bool get signInAvailable =>
      kIsWeb || defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Future<AuthState> build() => _fetch();

  Future<AuthState> _fetch() async {
    final url = AppConfig.apiUrl('/auth/me');
    if (url.isEmpty) return AuthState.signedOut;
    if (!kIsWeb && !AuthSession.isSignedIn) return AuthState.signedOut;
    try {
      final res = await Dio().get(
        url,
        options: Options(
          headers: AuthSession.header(),
          extra: {'withCredentials': true},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final data = res.data;
      if (res.statusCode == 200 && data is Map) {
        if (data['authenticated'] == true && data['user'] is Map) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool(_kHasLinkedKey, true);
          return AuthState.fromUser(data['user'] as Map);
        }
        // The worker answered and does not accept the token: expired, or the
        // account was deleted elsewhere. Forget it so the app stops sending
        // it, and move RevenueCat and the coin chip back to the device id —
        // main() configured RevenueCat under the account at launch.
        if (!kIsWeb && AuthSession.isSignedIn) {
          await _forgetLocalSession();
          final prefs = await SharedPreferences.getInstance();
          await _afterIdentityChange(DeliveryLog.ensureUserId(prefs));
        }
        return AuthState.signedOut;
      }
      // Any other answer (rate limit, a captive-portal page) says nothing
      // about the token: keep it, and keep showing the account.
      if (!kIsWeb && AuthSession.isSignedIn) {
        return await AuthSession.cachedUser() ?? AuthState.signedOut;
      }
    } catch (_) {
      // Offline or unreachable. Natively the token is still good as far as
      // we know, so keep showing the account rather than flashing signed out.
      if (!kIsWeb && AuthSession.isSignedIn) {
        return await AuthSession.cachedUser() ?? AuthState.signedOut;
      }
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

  // --- Sign in ----------------------------------------------------------------

  /// Signs in with [provider]. On the web this navigates away (same tab, so
  /// the browser keeps the user gesture and does not popup-block it) and
  /// returns [SignInOutcome.redirected]; [returnTo] is where to land after.
  Future<SignInOutcome> signIn(SignInProvider provider, {String? returnTo}) async {
    final prefs = await SharedPreferences.getInstance();
    final anonId = DeliveryLog.ensureUserId(prefs);

    if (kIsWeb) {
      final ticket = await CoinWalletService().mergeTicket();
      final back = returnTo ?? Uri.base.toString();
      final authUrl = provider == SignInProvider.google
          ? AppConfig.googleAuthUrl(back, anonId: anonId, ticket: ticket)
          : AppConfig.appleAuthUrl(back, anonId: anonId, ticket: ticket);
      if (authUrl.isEmpty) return SignInOutcome.failed;
      await launchUrl(Uri.parse(authUrl), webOnlyWindowName: '_self');
      return SignInOutcome.redirected;
    }

    if (!signInAvailable) return SignInOutcome.failed;

    final Map<String, dynamic> body;
    try {
      final credential = provider == SignInProvider.google
          ? await _googleCredential()
          : await _appleCredential();
      if (credential == null) return SignInOutcome.cancelled;
      body = credential;
    } catch (e) {
      debugPrint('[Auth] ${provider.name} sheet failed: $e');
      return SignInOutcome.failed;
    }

    // Proof this device owns its (claimed) wallet, so the coins follow the
    // sign-in. Fetched after the sheet so it cannot go stale while the person
    // is choosing an account. Null for an unclaimed wallet, which merges
    // without one.
    final ticket = await CoinWalletService().mergeTicket();

    final url = AppConfig.apiUrl('/auth/native');
    if (url.isEmpty) return SignInOutcome.failed;
    try {
      final res = await Dio().post(
        url,
        data: jsonEncode({
          ...body,
          'anon_id': anonId,
          'anon_ticket': ?ticket,
        }),
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final data = res.data is String ? jsonDecode(res.data as String) : res.data;
      if (res.statusCode != 200 || data is! Map || data['token'] is! String || data['user'] is! Map) {
        debugPrint('[Auth] /auth/native refused (${res.statusCode}): $data');
        return SignInOutcome.failed;
      }
      final user = AuthState.fromUser(data['user'] as Map);
      await AuthSession.save(data['token'] as String, user);
      await prefs.setBool(_kHasLinkedKey, true);
      state = AsyncData(user);
      await _afterIdentityChange(user.userId ?? AuthSession.userId);
      return SignInOutcome.signedIn;
    } catch (e) {
      debugPrint('[Auth] /auth/native failed: $e');
      return SignInOutcome.failed;
    }
  }

  /// The native Google sheet. Null when the person closes it.
  Future<Map<String, dynamic>?> _googleCredential() async {
    final google = GoogleSignIn.instance;
    if (!_googleInitialized) {
      // Client ids come from Info.plist (GIDClientID, GIDServerClientID).
      await google.initialize();
      _googleInitialized = true;
    }
    try {
      final account = await google.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw StateError('Google returned no ID token');
      }
      return {'provider': 'google', 'id_token': idToken};
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }

  /// The native Apple sheet. Null when the person closes it.
  Future<Map<String, dynamic>?> _appleCredential() async {
    // The raw nonce goes to the worker; Apple embeds its SHA-256 in the token.
    // A match proves the token was minted for this sign-in, not lifted from
    // another app's.
    final rawNonce = _randomNonce();
    try {
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: sha256.convert(utf8.encode(rawNonce)).toString(),
      );
      final idToken = credential.identityToken;
      if (idToken == null || idToken.isEmpty) {
        throw StateError('Apple returned no identity token');
      }
      return {
        'provider': 'apple',
        'id_token': idToken,
        'raw_nonce': rawNonce,
        // Exchanged by the worker for the refresh token that account deletion
        // must revoke.
        'authorization_code': credential.authorizationCode,
        // Apple shares the name on the first sign-in only, and only here.
        if (credential.givenName != null) 'given_name': credential.givenName,
        if (credential.familyName != null) 'family_name': credential.familyName,
      };
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) return null;
      rethrow;
    }
  }

  static String _randomNonce([int length = 32]) {
    const chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(length, (_) => chars[random.nextInt(chars.length)]).join();
  }

  // --- Sign out / delete -----------------------------------------------------------

  /// Signs out. On the web the worker clears the cookie and lands on
  /// /signed-out. Natively the token is forgotten and this device goes back
  /// to its anonymous id — the coins stay on the account, ready for the next
  /// sign-in.
  Future<void> signOut() async {
    if (kIsWeb) {
      final url = AppConfig.apiUrl('/auth/logout');
      if (url.isNotEmpty) await launchUrl(Uri.parse(url), webOnlyWindowName: '_self');
      return;
    }
    await _forgetLocalSession();
    state = const AsyncData(AuthState.signedOut);
    final prefs = await SharedPreferences.getInstance();
    await _afterIdentityChange(DeliveryLog.ensureUserId(prefs));
  }

  /// Deletes the signed-in account and everything stored with it (App Review
  /// 5.1.1(v)); Apple's token is revoked server-side. Returns false when the
  /// worker could not do it — the person is still signed in and can retry.
  Future<bool> deleteAccount() async {
    final url = AppConfig.apiUrl('/api/account/delete');
    if (url.isEmpty) return false;
    try {
      final res = await Dio().post(
        url,
        data: '{}',
        options: Options(
          headers: {'Content-Type': 'application/json', ...AuthSession.header()},
          extra: {'withCredentials': true},
          validateStatus: (s) => s != null && s < 600,
        ),
      );
      if (res.statusCode != 200) {
        debugPrint('[Auth] delete refused (${res.statusCode}): ${res.data}');
        return false;
      }
    } catch (e) {
      debugPrint('[Auth] delete failed: $e');
      return false;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kHasLinkedKey);
    if (kIsWeb) {
      // The worker already expired the cookie; reload signed out.
      await launchUrl(Uri.parse('${Uri.base.origin}/signed-out?deleted=1'), webOnlyWindowName: '_self');
      return true;
    }
    await _forgetLocalSession();
    state = const AsyncData(AuthState.signedOut);
    await _afterIdentityChange(DeliveryLog.ensureUserId(prefs));
    return true;
  }

  Future<void> _forgetLocalSession() async {
    await AuthSession.clear();
    if (_googleInitialized) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {}
    }
  }

  /// Everything keyed by "who is this" follows the identity: RevenueCat buys
  /// under the account (or back under the device id), and the coin chip
  /// re-reads the wallet the worker now resolves.
  Future<void> _afterIdentityChange(String? userId) async {
    if (userId != null && userId.isNotEmpty) {
      // init() hands back the configure still in flight from main() (it is
      // not awaited there), so identify() cannot run against an
      // unconfigured SDK and silently do nothing.
      await RevenueCatService().init(userId);
      await RevenueCatService().identify(userId);
    }
    if (AppConfig.coinsUiEnabled) {
      try {
        await ref.read(coinWalletProvider.notifier).refresh();
      } catch (_) {}
    }
  }
}

final authProvider =
    AsyncNotifierProvider<AuthNotifier, AuthState>(AuthNotifier.new);
