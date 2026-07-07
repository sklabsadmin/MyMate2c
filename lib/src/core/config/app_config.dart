import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConfig {
  // CONFIGURATION
  // --------------------------------------------------------------------------

  /// Toggle this to TRUE for the initial release to hide all payment features.
  /// When ready for monetization, set this to FALSE.
  static const bool isFreeTier = true;

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
}
