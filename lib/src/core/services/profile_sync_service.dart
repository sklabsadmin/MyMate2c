import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../models/user_profile.dart';

final profileSyncServiceProvider = Provider<ProfileSyncService>((ref) {
  return ProfileSyncService();
});

/// Syncs the player's profile with the worker for signed-in users.
///
/// The worker resolves identity from the signed session cookie, so every call
/// here must send credentials — there is no user id in the request, by design.
/// A signed-out user gets 401 and keeps the device-local copy; that is the
/// normal path, not an error worth surfacing.
class ProfileSyncService {
  final Dio _dio = Dio();

  Options get _authed => Options(
        extra: {'withCredentials': true},
        // 401 is expected for signed-out users, so don't let Dio throw on it.
        validateStatus: (status) => status != null && status < 500,
      );

  /// Returns the server copy, or null if signed out, absent, or unreachable.
  Future<UserProfile?> fetch() async {
    final url = AppConfig.apiUrl('/api/profile');
    if (url.isEmpty) return null;
    try {
      final res = await _dio.get(url, options: _authed);
      if (res.statusCode != 200) return null;
      final data = res.data;
      if (data is! Map) return null;
      final profile = data['profile'];
      if (profile is! Map) return null;
      return UserProfile.fromJson(Map<String, dynamic>.from(profile));
    } catch (e) {
      if (kDebugMode) debugPrint('Profile fetch failed: $e');
      return null;
    }
  }

  /// Pushes the profile up. Returns true only on a confirmed save, so the
  /// caller can tell "synced" apart from "kept locally".
  Future<bool> push(UserProfile profile) async {
    final url = AppConfig.apiUrl('/api/profile');
    if (url.isEmpty) return false;
    try {
      final res = await _dio.put(
        url,
        data: {'profile': profile.toJson()},
        options: _authed,
      );
      return res.statusCode == 200;
    } catch (e) {
      if (kDebugMode) debugPrint('Profile push failed: $e');
      return false;
    }
  }
}
