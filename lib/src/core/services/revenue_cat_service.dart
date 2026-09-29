import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

/// How a purchase attempt ended, as far as the client can tell. Note what is
/// NOT here: "coins credited". The store settles the payment, RevenueCat
/// verifies it and tells the worker by webhook, and the worker writes the
/// ledger row — the app learns about its coins by reading the wallet back,
/// never by believing its own purchase call. docs/coin-packs-brief-2026-09-16.md.
enum PurchaseOutcome {
  /// The store took the payment. Coins follow by webhook; poll the wallet.
  purchased,

  /// The user backed out of the store sheet. Nothing happened, say nothing.
  cancelled,

  /// The store has not decided yet (Ask to Buy, or a payment under review).
  /// Coins arrive later if it clears; the wallet will show them.
  pending,

  /// Anything else: no products, network, store error.
  failed,
}

/// The RevenueCat SDK, kept to the one job it has here: talking to the store.
///
/// The customer id handed to RevenueCat is OUR user id (the device id, or the
/// account id once signed in) — that is the join key the worker uses when the
/// webhook arrives, and the only reason a purchase can follow a person to a
/// new device. RevenueCat never mints an identity the app depends on, so the
/// provider is replaceable without touching the ledger.
///
/// iOS only for now. Android needs a Play key, web needs Web Billing (Stripe);
/// both are decisions, not code, and [isSupported] keeps the UI honest until
/// they are made.
class RevenueCatService {
  static final RevenueCatService _instance = RevenueCatService._internal();

  factory RevenueCatService() => _instance;

  RevenueCatService._internal();

  // Public SDK keys, not secrets. --dart-define first, then the bundled .env.
  // The iOS fallback is the project's RevenueCat Test Store key, so a debug
  // build without a .env can still walk the whole purchase path against the
  // sandbox (and the worker refuses to credit those onto a real wallet).
  static const String _iosKeyFromDefine =
      String.fromEnvironment('REVENUECAT_IOS_KEY');
  static const String _androidKeyFromDefine =
      String.fromEnvironment('REVENUECAT_ANDROID_KEY');
  static const String _disableFromDefine =
      String.fromEnvironment('DISABLE_REVENUECAT');

  static String _defineOrEnv(String fromDefine, String key, String fallback) {
    if (fromDefine.isNotEmpty) return fromDefine;
    if (kIsWeb || !dotenv.isInitialized) return fallback;
    final v = dotenv.env[key];
    return (v == null || v.isEmpty) ? fallback : v;
  }

  // The Test Store key of the "MyMate: AI Boyfriend Chat" project (public
  // SDK key, sandbox only). The previous fallback belonged to a different
  // project and served that project's offering — the app then hid every
  // product it offered, which is the right behaviour but a confusing one.
  static String get _iosKey => _defineOrEnv(
      _iosKeyFromDefine, 'REVENUECAT_IOS_KEY', 'test_qfHyinKWkdvuacpnesKLglkFvsH');
  static String get _androidKey =>
      _defineOrEnv(_androidKeyFromDefine, 'REVENUECAT_ANDROID_KEY', '');
  static bool get _disabled =>
      _defineOrEnv(_disableFromDefine, 'DISABLE_REVENUECAT', '').toLowerCase() ==
      'true';

  /// The offering that lists the coin packs in the RevenueCat dashboard. The
  /// current offering is used when it exists; this is the fallback name.
  static const String coinsOffering = 'coins';

  bool _configured = false;
  String? _appUserId;

  /// The configure call in flight, so a store screen opened before it has
  /// finished waits for it instead of reporting the store closed.
  Future<void>? _initFuture;

  /// Whether purchases can happen on this platform in this build.
  static bool get isSupported {
    if (kIsWeb || _disabled) return false;
    if (defaultTargetPlatform == TargetPlatform.iOS) return true;
    if (defaultTargetPlatform == TargetPlatform.android) {
      return _androidKey.isNotEmpty;
    }
    return false;
  }

  bool get isReady => _configured;

  /// Configures the SDK under [appUserId]. Call once at startup with the
  /// device id; call again (it becomes a logIn) when the person signs in, so
  /// anything bought anonymously is merged onto the account.
  Future<void> init(String appUserId) {
    if (!isSupported || appUserId.isEmpty) return Future.value();
    return _initFuture ??= _init(appUserId);
  }

  Future<void> _init(String appUserId) async {
    try {
      if (_configured) {
        if (_appUserId != appUserId) await identify(appUserId);
        return;
      }
      if (kDebugMode) await Purchases.setLogLevel(LogLevel.debug);
      final key = defaultTargetPlatform == TargetPlatform.iOS
          ? _iosKey
          : _androidKey;
      final configuration = PurchasesConfiguration(key)..appUserID = appUserId;
      await Purchases.configure(configuration);
      _configured = true;
      _appUserId = appUserId;
      debugPrint('[RevenueCat] configured for $appUserId');
    } on PlatformException catch (e) {
      debugPrint('[RevenueCat] configure failed: $e');
    } catch (e) {
      debugPrint('[RevenueCat] configure failed: $e');
    }
  }

  /// Switches the customer to [userId] — the sign-in moment. RevenueCat merges
  /// the anonymous customer's purchases into the new id when the new id has
  /// none of its own; the worker's wallet merge handles the coins themselves.
  Future<void> identify(String userId) async {
    if (!_configured || userId.isEmpty || userId == _appUserId) return;
    try {
      await Purchases.logIn(userId);
      _appUserId = userId;
      debugPrint('[RevenueCat] now $userId');
    } on PlatformException catch (e) {
      debugPrint('[RevenueCat] logIn failed: $e');
    }
  }

  /// The purchasable coin packs, as the store prices them. Empty when the
  /// SDK is not configured, the offering is missing, or the store is
  /// unreachable — all of which the store screen shows as "not right now",
  /// never as a price it made up.
  Future<List<Package>> coinPackages() async {
    if (_initFuture != null) await _initFuture;
    if (!_configured) return const [];
    try {
      final offerings = await Purchases.getOfferings();
      final offering = offerings.current ??
          offerings.all[coinsOffering] ??
          (offerings.all.isNotEmpty ? offerings.all.values.first : null);
      final packages = List<Package>.from(offering?.availablePackages ?? const []);
      if (kDebugMode) {
        for (final p in packages) {
          debugPrint('[RevenueCat] ${p.identifier}: '
              '${p.storeProduct.identifier} ${p.storeProduct.priceString}');
        }
      }
      return packages;
    } on PlatformException catch (e) {
      debugPrint('[RevenueCat] offerings failed: $e');
      return const [];
    }
  }

  /// Runs the store's purchase sheet for [package]. See [PurchaseOutcome] for
  /// what the answer does and does not mean.
  Future<PurchaseOutcome> purchase(Package package) async {
    if (_initFuture != null) await _initFuture;
    if (!_configured) return PurchaseOutcome.failed;
    try {
      final result = await Purchases.purchasePackage(package);
      debugPrint('[RevenueCat] purchased ${package.storeProduct.identifier} '
          'tx=${result.storeTransaction.transactionIdentifier}');
      return PurchaseOutcome.purchased;
    } on PlatformException catch (e) {
      final code = PurchasesErrorHelper.getErrorCode(e);
      if (code == PurchasesErrorCode.purchaseCancelledError) {
        return PurchaseOutcome.cancelled;
      }
      if (code == PurchasesErrorCode.paymentPendingError) {
        debugPrint('[RevenueCat] purchase pending: $e');
        return PurchaseOutcome.pending;
      }
      debugPrint('[RevenueCat] purchase failed ($code): $e');
      return PurchaseOutcome.failed;
    }
  }
}
