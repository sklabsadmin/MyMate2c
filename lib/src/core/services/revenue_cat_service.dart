import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class RevenueCatService {
  static final RevenueCatService _instance = RevenueCatService._internal();

  factory RevenueCatService() {
    return _instance;
  }

  RevenueCatService._internal();

  // RevenueCat API keys are loaded from environment variables so they
  // are not committed to source control. Set these in your `.env` file
  static const String _iosApiKeyFromDefine =
      String.fromEnvironment('REVENUECAT_IOS_KEY');
  static const String _androidApiKeyFromDefine =
      String.fromEnvironment('REVENUECAT_ANDROID_KEY');
  static const String _webApiKeyFromDefine =
      String.fromEnvironment('REVENUECAT_WEB_KEY');
  static const String _disableRevenueCatFromDefine =
      String.fromEnvironment('DISABLE_REVENUECAT');

  static String get _iosApiKey => _iosApiKeyFromDefine.isNotEmpty
      ? _iosApiKeyFromDefine
      : dotenv.env['REVENUECAT_IOS_KEY'] ?? 'test_AhcCFLAjjFKRVAaRvosMUvctyew';
  static String get _androidApiKey => _androidApiKeyFromDefine.isNotEmpty
      ? _androidApiKeyFromDefine
      : dotenv.env['REVENUECAT_ANDROID_KEY'] ?? 'your_android_api_key_here';
  static String get _webApiKey => _webApiKeyFromDefine.isNotEmpty
      ? _webApiKeyFromDefine
      : dotenv.env['REVENUECAT_WEB_KEY'] ?? '';
  static bool get _revenueCatDisabled =>
      (_disableRevenueCatFromDefine.isNotEmpty
              ? _disableRevenueCatFromDefine
              : dotenv.env['DISABLE_REVENUECAT'] ?? '')
          .toLowerCase() ==
      'true';

  static const String _entitlementId = 'premium_access'; // Set this in RevenueCat dashboard

  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;

    if (_revenueCatDisabled) {
      _isInitialized = true;
      debugPrint('[RevenueCat] DISABLED via .env (DISABLE_REVENUECAT=true)');
      return;
    }

    if (kDebugMode) {
      await Purchases.setLogLevel(LogLevel.debug);
    }

    PurchasesConfiguration? configuration;

    if (kIsWeb) {
      if (_webApiKey.isEmpty) {
        debugPrint('[RevenueCat] Web key missing; skipping web configuration.');
        _isInitialized = true;
        return;
      }
      configuration = PurchasesConfiguration(_webApiKey);
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      configuration = PurchasesConfiguration(_androidApiKey);
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      configuration = PurchasesConfiguration(_iosApiKey);
    }

    if (configuration != null) {
      await Purchases.configure(configuration);
      _isInitialized = true;
      debugPrint('[RevenueCat] Service Initialized');
      
      // Log initial customer info
      try {
        CustomerInfo customerInfo = await Purchases.getCustomerInfo();
         debugPrint('[RevenueCat] Initial Customer Info: ${customerInfo.toString()}');
         debugPrint('[RevenueCat] Active Entitlements: ${customerInfo.entitlements.active.keys}');
      } catch (e) {
        debugPrint('[RevenueCat] Failed to get initial customer info: $e');
      }
    }
  }

  Future<Offerings?> getOfferings() async {
    if (_revenueCatDisabled) {
      debugPrint('[RevenueCat] getOfferings() skipped because DISABLE_REVENUECAT=true');
      return null;
    }

    try {
      Offerings offerings = await Purchases.getOfferings();
      debugPrint('[RevenueCat] Offerings fetched: ${offerings.current?.availablePackages.length ?? 0} packages available.');
      if (offerings.current != null) {
          for (var package in offerings.current!.availablePackages) {
             debugPrint('[RevenueCat] Package: ${package.identifier} - Product: ${package.storeProduct.identifier} - Price: ${package.storeProduct.priceString}');
          }
      }
      return offerings;
    } on PlatformException catch (e) {
      debugPrint('[RevenueCat] Error fetching offerings: $e');
      return null;
    }
  }

Future<bool> purchasePackage(Package package) async {
  if (_revenueCatDisabled) {
    debugPrint('[RevenueCat] purchasePackage() skipped because DISABLE_REVENUECAT=true');
    return false;
  }

  try {
    debugPrint('[RevenueCat] Initiating purchase for package: ${package.identifier} (${package.storeProduct.identifier})');
    final PurchaseResult purchaseResult = await Purchases.purchasePackage(package);
    final CustomerInfo customerInfo = purchaseResult.customerInfo;
    debugPrint('[RevenueCat] Purchase completed. Active entitlements: ${customerInfo.entitlements.active.keys}');
    
    final isPro = customerInfo.entitlements.all[_entitlementId]?.isActive ?? false;
    if (isPro) {
      debugPrint('[RevenueCat] User is now PREMIUM.');
    }
    return isPro;
  } on PlatformException catch (e) {
    var errorCode = PurchasesErrorHelper.getErrorCode(e);
    if (errorCode != PurchasesErrorCode.purchaseCancelledError) {
      debugPrint('[RevenueCat] Purchase failed: $e');
    } else {
      debugPrint('[RevenueCat] Purchase cancelled by user.');
    }
    return false;
  }
}

  Future<bool> restorePurchases() async {
    if (_revenueCatDisabled) {
      debugPrint('[RevenueCat] restorePurchases() skipped because DISABLE_REVENUECAT=true');
      return false;
    }

    try {
      debugPrint('[RevenueCat] Restoring purchases...');
      CustomerInfo customerInfo = await Purchases.restorePurchases();
      debugPrint('[RevenueCat] Restore completed. Active entitlements: ${customerInfo.entitlements.active.keys}');
      
      final isPro = customerInfo.entitlements.all[_entitlementId]?.isActive ?? false;
      return isPro;
    } on PlatformException catch (e) {
      debugPrint('[RevenueCat] Restore failed: $e');
      return false;
    }
  }
  
  Future<bool> checkSubscriptionStatus() async {
      if (_revenueCatDisabled) {
      debugPrint('[RevenueCat] checkSubscriptionStatus() skipped because DISABLE_REVENUECAT=true');
      return false;
      }

      try {
        CustomerInfo customerInfo = await Purchases.getCustomerInfo();
        final isPro = customerInfo.entitlements.all[_entitlementId]?.isActive ?? false;
        debugPrint('[RevenueCat] Subscription check: ${isPro ? "ACTIVE" : "INACTIVE"}');
        return isPro;
      } on PlatformException catch (e) {
        debugPrint('[RevenueCat] Error checking subscription status: $e');
        return false;
      }
  }
}
