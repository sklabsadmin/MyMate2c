import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps the anonymous identity alive across a reinstall.
///
/// The device id (`user_<ms>`, minted by DeliveryLog.ensureUserId) and the
/// wallet claim token both live in SharedPreferences, because every caller
/// reads them synchronously. On iOS and Android this class mirrors both into
/// the keychain / keystore, which survives deleting the app and, on iOS, rides
/// along in encrypted backups and device migration. Before coins cost money a
/// reinstall losing the id was a fresh start; now it would be a paid wallet
/// left behind — docs/coin-packs-brief-2026-09-16.md, C1.
///
/// The keychain is a backup, not the source: [restore] runs once at startup,
/// before anything mints an id, and reconciles the two stores in whichever
/// direction has something the other lacks. Prefs win when both disagree,
/// because prefs is what the running app has been using. On web there is no
/// keychain and this class does nothing beyond caching the claim token.
class DeviceIdentity {
  static const String _kUserId = 'user_id';
  static const String _kClaim = 'wallet_claim_token';

  static String? _claim;
  static bool _restored = false;

  static FlutterSecureStorage? get _vault => kIsWeb
      ? null
      : const FlutterSecureStorage(
          // After first unlock, not "this device only": the id must travel
          // in a backup to a new phone, or the coins stay on the old one.
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.first_unlock,
          ),
        );

  /// Call once, early in main(), before any service can mint a user id.
  /// Never throws: a broken keychain must not stop the app launching.
  static Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _claim = prefs.getString(_kClaim);
      final vault = _vault;
      if (vault == null) return;

      final prefId = prefs.getString(_kUserId);
      final keptId = await vault.read(key: _kUserId);
      if ((prefId == null || prefId.isEmpty) &&
          keptId != null &&
          keptId.isNotEmpty) {
        // A reinstall: prefs were wiped, the keychain remembers who we were.
        await prefs.setString(_kUserId, keptId);
      } else if (prefId != null && prefId.isNotEmpty && keptId != prefId) {
        await vault.write(key: _kUserId, value: prefId);
      }

      final keptClaim = await vault.read(key: _kClaim);
      if ((_claim == null || _claim!.isEmpty) &&
          keptClaim != null &&
          keptClaim.isNotEmpty) {
        _claim = keptClaim;
        await prefs.setString(_kClaim, keptClaim);
      } else if (_claim != null && _claim!.isNotEmpty && keptClaim != _claim) {
        await vault.write(key: _kClaim, value: _claim!);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('DeviceIdentity restore failed: $e');
    }
  }

  /// The secret that proves this device owns its anonymous wallet, or null if
  /// the wallet has never been claimed. Sent as `x-wallet-claim` on every
  /// wallet call and every gift; the server refuses a claimed wallet without
  /// it. Synchronous so header-building code stays synchronous.
  static String? get claimToken =>
      (_claim == null || _claim!.isEmpty) ? null : _claim;

  /// Forgets a token the server no longer accepts (a 403). The next sync then
  /// asks for a fresh one; the server grants that only if the old token was
  /// never used — the lost-response case — so this cannot help a stranger.
  static Future<void> clearClaimToken() async {
    _claim = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kClaim);
      await _vault?.delete(key: _kClaim);
    } catch (e) {
      if (kDebugMode) debugPrint('DeviceIdentity claim clear failed: $e');
    }
  }

  /// Stores the token the server returned exactly once, in both places.
  static Future<void> saveClaimToken(String token) async {
    if (token.isEmpty) return;
    _claim = token;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kClaim, token);
      await _vault?.write(key: _kClaim, value: token);
    } catch (e) {
      if (kDebugMode) debugPrint('DeviceIdentity claim save failed: $e');
    }
  }
}
