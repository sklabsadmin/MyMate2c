import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/data/characters.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/theme/app_theme.dart';
import '../coin_wallet.dart';

/// The tribute a player can offer a character, priced by the server.
/// One gift in the catalogue. The price is NOT here: it arrives with every
/// wallet read, because the server owns what things cost.
class TributeOption {
  /// The API key the worker prices — roses | ambrosia | pendant | laurel.
  final String item;
  final String label;
  final String detail;

  /// The painted gift. Prepared from the source art at 256px and quantised —
  /// 50KB for all three — because `assets/images/` is globbed into every
  /// deploy and this app has had a payload emergency before.
  final String asset;

  /// A keepsake: given once per character and kept from then on, rather than
  /// consumed.
  final bool once;

  /// What a keepsake's row says once the character holds it, in place of the
  /// price and the description. Only read when [once].
  final String heldBadge;
  final String heldDetail;

  /// The gift as the stage direction names it — "*gives [giving] to Zeus*".
  /// Null reads the label in lower case, which suits a plural or a mass noun
  /// (roses, ambrosia) but not a single thing (a pendant).
  final String? giving;

  const TributeOption(
    this.item,
    this.label,
    this.detail,
    this.asset, {
    this.once = false,
    this.heldBadge = 'Given',
    this.heldDetail = 'Theirs since you gave it.',
    this.giving,
  });

  String get givingPhrase => giving ?? label.toLowerCase();
}

/// The catalogue, in ascending price. The asset names match the item keys the
/// worker prices, so the mapping is mechanical rather than remembered.
const List<TributeOption> kTributeOptions = [
  TributeOption('roses', 'Roses', 'A small kindness — they will notice.',
      'assets/images/gift_roses.png'),
  TributeOption('ambrosia', 'Ambrosia', 'Food of the gods, offered by hand.',
      'assets/images/gift_ambrosia.png'),
  TributeOption('pendant', 'Pendant', 'Theirs to wear. Given once.',
      'assets/images/gift_pendant.png',
      once: true,
      heldBadge: 'Worn',
      heldDetail: 'Worn since you gave it.',
      giving: 'a pendant'),
  // gift_laurel.png is a drawn stand-in until Adam's artwork replaces it.
  TributeOption('laurel', 'Golden Laurel',
      'The crown of gods and heroes. Given once.',
      'assets/images/gift_laurel.png',
      once: true,
      heldBadge: 'Crowned',
      heldDetail: 'Crowned with it since you gave it.',
      giving: 'a golden laurel'),
];

/// The name a gift goes by in the history and on a profile: "Golden Laurel
/// for Penelope". [characterName] is null for a character the roster does not
/// know (a custom one), which drops the name.
String tributeHistoryLabel(String item, String? characterName) {
  final option = kTributeOptions.where((o) => o.item == item).firstOrNull;
  if (option == null) return 'Tribute';
  return characterName == null
      ? option.label
      : '${option.label} for $characterName';
}

/// What a character sends back for a gift, by character then gift.
///
/// Per-character on purpose: these are photographs of a specific person, and
/// Hercules flexing in answer to roses given to Penelope would be a bug you
/// could see from space. A character with no entry simply answers in words,
/// which is what every one of them did before this existed.
const Map<String, Map<String, String>> kGiftRewards = {
  'hercules': {'roses': 'assets/images/hercules_flex.jpg'},
};

/// The reward for [item] from [characterId], or null when there isn't one.
String? giftRewardAsset(String? characterId, String item) =>
    characterId == null ? null : kGiftRewards[characterId]?[item];

/// "Your Coins": balance, a way to buy more, tributes (in a chat), how to
/// earn, recent history.
///
/// Same sheet language as the login gate (chat_screen's _showLoginGate):
/// transparent barrier, white container with a 24px top radius, Playfair
/// title, Lato body, and a quiet way out — the app's one established way of
/// asking for something.
///
/// [onGetCoins] opens the coin store, called AFTER the sheet has closed. Null
/// where nothing can be bought (web), which hides every buy affordance and
/// leaves unaffordable tributes disabled as before. With it, an unaffordable
/// tribute is no longer a dead end: tapping it goes to the store, carrying a
/// line that says what it costs and what the player has.
Future<void> showCoinsSheet(
  BuildContext context, {
  required WidgetRef ref,
  String? characterName,
  String? characterId,
  void Function(String item, int price)? onTribute,
  void Function(String? reason)? onGetCoins,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    // Keeps a tall sheet (three tributes and a history) clear of the status
    // bar and Dynamic Island; it scrolls inside instead of sliding under them.
    useSafeArea: true,
    builder: (sheetContext) => Consumer(
      builder: (context, sheetRef, _) {
        final theme = Theme.of(context);
        final gold = theme.colorScheme.secondary;
        final wallet = sheetRef.watch(coinWalletProvider).value;
        final balance = wallet?.balance ?? 0;
        final prices = wallet?.tributePrices ?? const <String, int>{};
        final grants = wallet?.grantValues ?? const <String, int>{};

        // Closes the sheet, then hands over to the store — in that order, so
        // the store is pushed from the chat, not stacked on a closing sheet.
        void getCoins([String? reason]) {
          Navigator.of(sheetContext).pop();
          onGetCoins?.call(reason);
        }

        return Container(
          padding: EdgeInsets.fromLTRB(
            24, 28, 24, 32 + MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: AppTheme.hairlineColor),
            boxShadow: [
              BoxShadow(
                color: AppTheme.inkColor.withOpacity(0.10),
                blurRadius: 24,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.paid, color: gold, size: 34),
                const SizedBox(height: 10),
                Text(
                  'Your Coins',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.playfairDisplay(
                    color: AppTheme.inkColor,
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$balance',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.lato(
                    color: AppTheme.goldInkColor,
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                // The ♥ meter lives here now: the chip took its header slot
                // (decision 2026-08-20), and tributes move it, so the level
                // belongs beside the thing that raises it.
                Builder(builder: (context) {
                  final score = sheetRef.watch(userScoreProvider);
                  final level = 1 + (score ~/ 10);
                  return Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.favorite,
                            size: 13, color: theme.primaryColor),
                        const SizedBox(width: 4),
                        Text(
                          'Level $level',
                          style: GoogleFonts.lato(
                            color: AppTheme.mutedInkColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                // Buying, right under the number it changes. Every coin moment
                // reaches the store from here: the chip opens this sheet, and
                // so does a tribute the player cannot afford.
                if (onGetCoins != null) ...[
                  const SizedBox(height: 14),
                  ElevatedButton.icon(
                    key: const ValueKey('coins_sheet_get_more'),
                    onPressed: () => getCoins(),
                    icon: const Icon(Icons.add_circle_outline, size: 20),
                    label: Text(
                      'Get more coins',
                      style: GoogleFonts.outfit(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      elevation: 1,
                    ),
                  ),
                ],
                if (onTribute != null && characterName != null) ...[
                  const SizedBox(height: 18),
                  Text(
                    'Offer a tribute to $characterName',
                    style: GoogleFonts.lato(
                      color: AppTheme.mutedInkColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final option in kTributeOptions)
                    Builder(builder: (context) {
                      final price = prices[option.item] ?? 0;
                      final affordable = price > 0 && balance >= price;
                      return _TributeRow(
                        option: option,
                        price: price,
                        // A keepsake already given reads "Worn"/"Given"
                        // instead of a price — it cannot be bought twice, and
                        // offering it again would look like a way to waste
                        // the coins.
                        held: option.once &&
                            (wallet?.holds(option.item, characterId) ?? false),
                        enabled: affordable,
                        // Priced but unaffordable, where coins can be bought:
                        // the row stays live and leads to the store, saying
                        // how many more it needs. Unpriced (no wallet read
                        // yet), or nowhere to buy, it stays disabled.
                        shortfall: !affordable && price > 0 &&
                                onGetCoins != null
                            ? price - balance
                            : 0,
                        onTap: () {
                          if (affordable) {
                            Navigator.of(sheetContext).pop();
                            onTribute(option.item, price);
                          } else {
                            getCoins('${option.label} costs $price coins. '
                                'You have $balance.');
                          }
                        },
                      );
                    }),
                ],
                const SizedBox(height: 18),
                Text(
                  'HOW TO EARN',
                  style: GoogleFonts.lato(
                    color: AppTheme.faintInkColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                // Every figure below comes off the wire. None are written
                // down here, because the last time they were, replyGrant was
                // retuned server-side from 1 to 8 and this list carried on
                // advertising the old number to everyone who opened it.
                _EarnRow(Icons.wb_twilight, 'Return each day',
                    _grant(grants, 'daily')),
                _EarnRow(
                  Icons.chat_bubble_outline,
                  'Every reply in a conversation'
                  '${wallet != null && wallet.replyGrantCap > 0 ? ' (${wallet.replyGrantsToday}/${wallet.replyGrantCap} today)' : ''}',
                  _grant(grants, 'reply'),
                ),
                if (kIsWeb)
                  _EarnRow(Icons.account_circle_outlined, 'Sign in with Google',
                      _grant(grants, 'link')),
                _EarnRow(Icons.badge_outlined, 'Complete your profile',
                    _grant(grants, 'profile')),
                if (wallet != null && wallet.recent.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text(
                    'RECENT',
                    style: GoogleFonts.lato(
                      color: AppTheme.faintInkColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final row in wallet.recent.take(5))
                    _RecentRow(row: row),
                ],
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  child: Text(
                    'Close',
                    style: GoogleFonts.lato(color: AppTheme.mutedInkColor),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// A faucet's amount as the server states it, or an em dash when the wallet
/// has not been read yet — never a number this file made up.
String _grant(Map<String, int> grants, String key) {
  final value = grants[key];
  return value == null ? '—' : '+$value';
}

class _TributeRow extends StatelessWidget {
  final TributeOption option;
  final int price;
  final bool enabled;
  final bool held;

  /// Coins still needed, when the row is unaffordable but can lead to the
  /// store. 0 means "not that case" (affordable, held, or nowhere to buy).
  final int shortfall;
  final VoidCallback onTap;

  const _TributeRow({
    required this.option,
    required this.price,
    required this.enabled,
    required this.onTap,
    this.held = false,
    this.shortfall = 0,
  });

  @override
  Widget build(BuildContext context) {
    final gold = Theme.of(context).colorScheme.secondary;
    // A keepsake already given is not a disabled row — it is a finished one.
    // Same gold as an affordable gift, so the sheet reads as an achievement
    // rather than something switched off.
    final toStore = shortfall > 0 && !held;
    final live = (enabled || toStore) && !held;
    final ink = held
        ? AppTheme.goldInkColor
        : enabled || toStore
            ? AppTheme.inkColor
            : AppTheme.faintInkColor;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: held
            ? gold.withOpacity(0.10)
            : enabled
                ? gold.withOpacity(0.14)
                : AppTheme.panelColor,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: live ? onTap : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: held
                    ? gold.withOpacity(0.45)
                    : enabled
                        ? gold.withOpacity(0.7)
                        : AppTheme.hairlineColor,
              ),
            ),
            child: Row(
              children: [
                // Fixed box, BoxFit.contain: the three pieces have different
                // aspect ratios, and left to themselves the tall pendant would
                // sit taller than the rose and unbalance the list. Dimmed
                // rather than greyed when unaffordable — the art is the
                // advertisement.
                SizedBox(
                  width: 40,
                  height: 40,
                  child: Opacity(
                    opacity: held || enabled ? 1.0 : toStore ? 0.6 : 0.35,
                    child: Image.asset(option.asset, fit: BoxFit.contain),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        option.label,
                        style: GoogleFonts.lato(
                          color: ink,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        held
                            ? option.heldDetail
                            : toStore
                                ? 'Needs $shortfall more coins — tap to get them'
                                : option.detail,
                        style: GoogleFonts.lato(
                          color: toStore
                              ? AppTheme.primaryColor
                              : enabled || held
                                  ? AppTheme.mutedInkColor
                                  : AppTheme.faintInkColor,
                          fontSize: 12,
                          fontWeight:
                              toStore ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
                if (held)
                  Text(
                    option.heldBadge,
                    style: GoogleFonts.lato(
                      color: AppTheme.goldInkColor,
                      fontWeight: FontWeight.w800,
                    ),
                  )
                else ...[
                  Icon(Icons.paid,
                      size: 14,
                      color: enabled
                          ? AppTheme.goldInkColor
                          : AppTheme.faintInkColor),
                  const SizedBox(width: 4),
                  Text(
                    price > 0 ? '$price' : '—',
                    style: GoogleFonts.lato(
                      color: enabled
                          ? AppTheme.goldInkColor
                          : AppTheme.faintInkColor,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EarnRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String amount;
  const _EarnRow(this.icon, this.label, this.amount);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppTheme.faintInkColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.lato(
                  color: AppTheme.mutedInkColor, fontSize: 13.5),
            ),
          ),
          Text(
            amount,
            style: GoogleFonts.lato(
              color: AppTheme.goldInkColor,
              fontWeight: FontWeight.w700,
              fontSize: 13.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  final Map<String, dynamic> row;
  const _RecentRow({required this.row});

  @override
  Widget build(BuildContext context) {
    final delta = row['delta'] is int
        ? row['delta'] as int
        : int.tryParse('${row['delta']}') ?? 0;
    final label = delta < 0 && '${row['reason']}' == 'gift'
        ? _giftRowLabel(row)
        : CoinGrant('${row['reason']}', delta).label;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.lato(
                  color: AppTheme.mutedInkColor, fontSize: 12.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            delta > 0 ? '+$delta' : '$delta',
            style: GoogleFonts.lato(
              color: delta > 0
                  ? AppTheme.goldInkColor
                  : AppTheme.mutedInkColor,
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// "Roses for Penelope" for a gift row in the history. The ledger row carries
/// the item in meta_json and the character in ref; a row missing either (or
/// written before items were recorded) still reads as a plain "Tribute".
String _giftRowLabel(Map<String, dynamic> row) {
  String? item;
  final meta = row['meta_json'];
  try {
    final decoded = meta is String ? jsonDecode(meta) : meta;
    if (decoded is Map && decoded['item'] is String) {
      item = decoded['item'] as String;
    }
  } catch (_) {
    item = null;
  }
  if (item == null) return 'Tribute';
  final name = characterById(row['ref'] as String?)?['name'] as String?;
  return tributeHistoryLabel(item, name);
}
