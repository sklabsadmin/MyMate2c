import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'src/app.dart';
import 'src/core/config/app_config.dart';
import 'src/core/services/revenue_cat_service.dart';
import 'src/core/services/notification_service.dart';

Future<void> main() async {
  // Use a guarded zone to capture uncaught async errors.
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Capture Flutter framework errors.
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      try {
        // Print details so they appear in the flutter run log.
        print('Uncaught Flutter error: ${details.exceptionAsString()}');
        print(details.stack);
      } catch (_) {}
    };

    // Web builds use --dart-define values. Loading .env on web would request
    // /assets/.env, which should never be shipped as a public asset.
    if (!kIsWeb) {
      try {
        await dotenv.load(fileName: ".env");
      } catch (_) {}
      print("Debug: All keys found in .env: ${dotenv.env.keys.toList()}");
    }
    if (AppConfig.workerUrl.isEmpty) {
      print("❌ CRITICAL: WORKER_URL is MISSING! The app cannot connect to the backend.");
    }
    if (AppConfig.appSecret.isEmpty) {
      print("❌ CRITICAL: APP_SECRET is MISSING! HMAC signatures will fail.");
    }

    if (!AppConfig.isFreeTier) {
      await RevenueCatService().init();
    }

    // Initialize Local Notifications
    await NotificationService().init();

    final prefs = await SharedPreferences.getInstance();
    final bool onboardingCompleted = prefs.getBool('onboarding_complete') ?? false;

    runApp(ProviderScope(child: AIApp(onboardingCompleted: onboardingCompleted)));
  }, (error, stack) async {
    // Log uncaught errors from the zone.
    print('Uncaught zone error: $error');
    print(stack);
  });
}
