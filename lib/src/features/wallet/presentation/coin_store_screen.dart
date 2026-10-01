import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../../../core/services/revenue_cat_service.dart';
import '../../../core/theme/app_theme.dart';
import '../coin_wallet.dart';

/// The coin store: the packs, priced by the store, credited by the worker.
///
/// Three rules, the same ones the wallet lives by:
///  - the coin count for a pack comes from the wallet response (`packs`),
///    the price from the store product — this screen states neither;
///  - a purchase is never "done" when the store sheet closes. The worker
///    credits the pack when RevenueCat's webhook lands, so after buying we
///    poll the wallet and celebrate only a balance that actually rose;
///  - if the poll runs out, the coins are still coming: say so, and offer
///    the reconcile button rather than a failure the person did not have.
///
/// There is no restore button. Consumables cannot be restored through the
/// store; "Didn't get your coins?" (reconcile) is the honest equivalent.
class CoinStoreScreen extends ConsumerStatefulWidget {
  /// Why the player is here, when something sent them: "Ambrosia costs 150
  /// coins. You have 32." Shown under the balance. Null from the plain
  /// "Get more coins" buttons.
  final String? reason;

  const CoinStoreScreen({super.key, this.reason});

  @override
  ConsumerState<CoinStoreScreen> createState() => _CoinStoreScreenState();
}

enum _Phase { loading, ready, unavailable, buying, waiting, arrived, onItsWay }

class _CoinStoreScreenState extends ConsumerState<CoinStoreScreen> {
  // The light theme's store: white page, gold reserved for fills and the
  // price pills (with ink on them), gold-ink for gold text on white.
  static const Color _gold = AppTheme.secondaryColor;
  static const Color _goldInk = AppTheme.goldInkColor;
  static const Color _ink = AppTheme.inkColor;
  static const Color _page = Colors.white;

  final RevenueCatService _store = RevenueCatService();
  List<Package> _packages = const [];
  _Phase _phase = _Phase.loading;
  int _justAdded = 0;
  int _purchasedAtOpen = 0;

  @override
  void initState() {
    super.initState();
    // Nothing on this screen takes text. Whatever had focus behind it (the
    // chat's message box) must not get it back when the App Store sheet
    // closes and raise a keyboard over the packs.
    FocusManager.instance.primaryFocus?.unfocus();
    _load();
  }

  Future<void> _load() async {
    if (!RevenueCatService.isSupported) {
      setState(() => _phase = _Phase.unavailable);
      return;
    }
    // Make sure the pack sizes are known before the list draws. Read-only.
    await ref.read(coinWalletProvider.notifier).refresh();
    final known = ref.read(coinWalletProvider).value?.packs ?? const <String, int>{};
    _purchasedAtOpen = ref.read(coinWalletProvider).value?.lifetimePurchased ?? 0;
    // Only products the worker knows how to credit. Anything else in the
    // offering (a leftover subscription, a pack added to the dashboard before
    // the worker's catalogue) would take money for nothing — so it is not
    // for sale. With no wallet read at all, nothing can be vouched for.
    final packages = (await _store.coinPackages())
        .where((p) => known.containsKey(p.storeProduct.identifier))
        .toList();
    // Cheapest first, which for a coin ladder is also smallest first.
    packages.sort((a, b) => a.storeProduct.price.compareTo(b.storeProduct.price));
    if (!mounted) return;
    setState(() {
      _packages = packages;
      _phase = packages.isEmpty ? _Phase.unavailable : _Phase.ready;
    });
  }

  Future<void> _buy(Package package) async {
    final wallet = ref.read(coinWalletProvider).value;
    // The paid counter, not the balance: only a pack moves it.
    final before = wallet?.lifetimePurchased ?? 0;
    setState(() => _phase = _Phase.buying);

    final outcome = await _store.purchase(package);
    if (!mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();

    switch (outcome) {
      case PurchaseOutcome.cancelled:
        setState(() => _phase = _Phase.ready);
        return;
      case PurchaseOutcome.failed:
        setState(() => _phase = _Phase.ready);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('The store could not complete that. Nothing was charged.'),
        ));
        return;
      case PurchaseOutcome.pending:
        // Ask to Buy, or a payment the store is still checking: the coins
        // land when it clears, by the same webhook. Nothing to wait on now.
        setState(() => _phase = _Phase.onItsWay);
        return;
      case PurchaseOutcome.purchased:
        break;
    }

    setState(() => _phase = _Phase.waiting);
    final arrived =
        await ref.read(coinWalletProvider.notifier).awaitCredit(before);
    if (!mounted) return;
    final after = ref.read(coinWalletProvider).value?.lifetimePurchased ?? before;
    setState(() {
      _justAdded = after - before;
      _phase = arrived ? _Phase.arrived : _Phase.onItsWay;
    });
  }

  Future<void> _checkAgain() async {
    // Against the paid counter as it stood when the store opened: a purchase
    // that landed while the person was reading "on the way" must count.
    final before = _purchasedAtOpen;
    setState(() => _phase = _Phase.waiting);
    final notifier = ref.read(coinWalletProvider.notifier);
    // A plain wallet read first: the webhook has usually landed by the time
    // anyone taps this, and a read needs nothing but the worker. Reconcile
    // (which asks RevenueCat) only when the read still shows nothing.
    await notifier.refresh();
    var after = ref.read(coinWalletProvider).value?.lifetimePurchased ?? before;
    var ok = after > before;
    if (!ok) {
      ok = await notifier.reconcile(beforePurchased: before);
      after = ref.read(coinWalletProvider).value?.lifetimePurchased ?? before;
    }
    if (!mounted) return;
    setState(() {
      _justAdded = after - before;
      _phase = ok ? _Phase.arrived : _Phase.onItsWay;
    });
  }

  @override
  Widget build(BuildContext context) {
    final wallet = ref.watch(coinWalletProvider).value;
    final balance = wallet?.balance ?? 0;
    final packs = wallet?.packs ?? const <String, int>{};

    return Scaffold(
      backgroundColor: _page,
      appBar: AppBar(
        backgroundColor: _page,
        foregroundColor: _ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('Mythos Coins',
            style: GoogleFonts.outfit(fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _balanceLine(balance, wallet),
              const SizedBox(height: 20),
              Expanded(child: _body(packs)),
              const SizedBox(height: 12),
              Text(
                'Coins are kept on this device. To keep them between devices, '
                'sign in with Google or Apple when it is offered.',
                textAlign: TextAlign.center,
                style: GoogleFonts.lato(
                  color: AppTheme.mutedInkColor,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _balanceLine(int balance, CoinWalletState? wallet) {
    final debt = (wallet?.paidUnspent ?? 0) < 0 && balance < 0;
    return Column(
      children: [
        Text(
          '$balance',
          style: GoogleFonts.outfit(
            color: _goldInk,
            fontSize: 44,
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Text(
          debt
              ? 'A refund left this wallet owing. The next pack settles it first.'
              : 'coins in your purse',
          style: GoogleFonts.lato(
            color: AppTheme.mutedInkColor,
            fontSize: 13,
          ),
          textAlign: TextAlign.center,
        ),
        // What sent them here, when something did — the tribute they reached
        // for. Rose rather than muted: it is the reason for the whole screen.
        // Only while choosing: once a pack lands, "You have 100" is wrong.
        if (widget.reason != null &&
            !debt &&
            (_phase == _Phase.ready || _phase == _Phase.buying)) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              widget.reason!,
              textAlign: TextAlign.center,
              style: GoogleFonts.lato(
                color: AppTheme.primaryColor,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _body(Map<String, int> packs) {
    switch (_phase) {
      case _Phase.loading:
        return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
      case _Phase.unavailable:
        return _notice(
          'The store is not open on this device right now.',
          'Coin packs are bought through the App Store. Please try again later.',
        );
      case _Phase.buying:
        return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
      case _Phase.waiting:
        return _notice('Adding your coins…', 'This usually takes a moment.',
            spinner: true);
      case _Phase.arrived:
        return _notice(
          _justAdded > 0 ? '+$_justAdded coins' : 'Your coins are here',
          'Thank you. Go and spoil someone.',
          action: TextButton(
            onPressed: () => context.pop(),
            child: Text('Back to the conversation',
                style: GoogleFonts.lato(
                    color: AppTheme.primaryColor, fontWeight: FontWeight.w600)),
          ),
        );
      case _Phase.onItsWay:
        return _notice(
          'Your coins are on the way',
          'The store has confirmed your purchase. Your coins will appear '
              'shortly — you can leave this screen and carry on.',
          action: TextButton(
            onPressed: _checkAgain,
            child: Text("Didn't get your coins? Check again",
                style: GoogleFonts.lato(
                    color: AppTheme.primaryColor, fontWeight: FontWeight.w600)),
          ),
        );
      case _Phase.ready:
        return ListView.separated(
          itemCount: _packages.length,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, i) => _packCard(_packages[i], packs),
        );
    }
  }

  Widget _packCard(Package package, Map<String, int> packs) {
    final product = package.storeProduct;
    final coins = packs[product.identifier];
    // The middle of a three-pack ladder is the one to nudge towards.
    final highlight = _packages.length >= 3 && _packages.indexOf(package) == 1;
    return Material(
      color: highlight ? _gold.withOpacity(0.16) : AppTheme.panelColor,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => _buy(package),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: highlight ? _gold : AppTheme.hairlineColor,
              width: highlight ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      coins != null ? '$coins coins' : 'Coin pack',
                      style: GoogleFonts.outfit(
                        color: _ink,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (highlight)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text('Most popular',
                            style: GoogleFonts.lato(
                                color: _goldInk, fontSize: 12, fontWeight: FontWeight.w600)),
                      ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: _gold,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  product.priceString,
                  style: GoogleFonts.outfit(
                    color: _ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _notice(String title, String body, {bool spinner = false, Widget? action}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (spinner) ...[
            const CircularProgressIndicator(color: AppTheme.primaryColor),
            const SizedBox(height: 20),
          ],
          Text(title,
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(
                  color: _ink, fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(body,
              textAlign: TextAlign.center,
              style: GoogleFonts.lato(
                  color: AppTheme.mutedInkColor, fontSize: 14)),
          if (action != null) ...[const SizedBox(height: 16), action],
        ],
      ),
    );
  }
}
