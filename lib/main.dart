import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'src/app.dart';
import 'src/core/config/app_config.dart';
// import 'src/core/services/revenue_cat_service.dart'; // RevenueCat disabled
import 'src/core/services/notification_service.dart';

Future<void> main() async {
  // Use a guarded zone to capture uncaught async errors.
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Real path URLs (/settings) instead of hash URLs (/#/settings). The
    // fragment is never sent to the server, so hash routing makes it
    // impossible to serve per-character link previews or see which page was
    // requested — both of which the Instagram campaign links depend on.
    // Requires the server to serve index.html for unknown paths; wrangler.jsonc
    // already does via not_found_handling: "single-page-application".
    usePathUrlStrategy();

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

    // RevenueCat disabled - not monetizing currently. Uncomment to re-enable.
    // if (!AppConfig.isFreeTier) {
    //   await RevenueCatService().init();
    // }

    // Initialize Local Notifications
    await NotificationService().init();

    runApp(const ProviderScope(child: AIApp()));
  }, (error, stack) async {
    // Log uncaught errors from the zone.
    print('Uncaught zone error: $error');
    print(stack);
  });
}
