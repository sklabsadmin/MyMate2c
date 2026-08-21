import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/services/storage_service.dart';
import '../coin_wallet.dart';

/// The tribute a player can offer a character, priced by the server.
/// One gift in the catalogue. The price is NOT here: it arrives with every
/// wallet read, because the server owns what things cost.
class TributeOption {
  /// The API key the worker prices — roses | ambrosia | pendant.
  final String item;
  final String label;
  final String detail;

  /// The painted gift. Prepared from the source art at 256px and quantised —
  /// 50KB for all three — because `assets/images/` is globbed into every
  /// deploy and this app has had a payload emergency before.
  final String asset;

  /// Given once per character and worn from then on, rather than consumed.
  final bool once;

  const TributeOption(
    this.item,
    this.label,
    this.detail,
    this.asset, {
    this.once = false,
  });
}

/// The MVP catalogue, in ascending price. The asset names match the item keys
/// the worker prices, so the mapping is mechanical rather than remembered.
const List<TributeOption> kTributeOptions = [
  TributeOption('roses', 'Roses', 'A small kindness — they will notice.',
      'assets/images/gift_roses.png'),
  TributeOption('ambrosia', 'Ambrosia', 'Food of the gods, offered by hand.',
      'assets/images/gift_ambrosia.png'),
  TributeOption('pendant', 'Pendant', 'Theirs to wear. Given once.',
      'assets/images/gift_pendant.png', once: true),
];

/// "Your Coins": balance, tributes (in a chat), how to earn, recent history.
///
/// Same sheet language as the login gate (chat_screen's _showLoginGate):
/// transparent barrier, 0xFF1A1A1A container, 24px top radius, Playfair title,
/// Lato body, and a "Maybe later" way out — the app's one established way of
/// asking for something.
Future<void> showCoinsSheet(
  BuildContext context, {
  required WidgetRef ref,
  String? characterName,
  String? characterId,
  void Function(String item, int price)? onTribute,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) => Consumer(
      builder: (context, sheetRef, _) {
        final theme = Theme.of(context);
        final gold = theme.colorScheme.secondary;
        final wallet = sheetRef.watch(coinWalletProvider).value;
        final balance = wallet?.balance ?? 0;
        final prices = wallet?.tributePrices ?? const <String, int>{};

        return Container(
          padding: EdgeInsets.fromLTRB(
            24, 28, 24, 32 + MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
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
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$balance',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.lato(
                    color: gold,
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
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                if (onTribute != null && characterName != null) ...[
                  const SizedBox(height: 18),
                  Text(
                    'Offer a tribute to $characterName',
                    style: GoogleFonts.lato(
                      color: Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final option in kTributeOptions)
                    _TributeRow(
                      option: option,
                      price: prices[option.item] ?? 0,
                      // A pendant already given reads "Worn" instead of a
                      // price — it cannot be bought twice, and offering it
                      // again would look like a way to waste 500 coins.
                      worn: option.once &&
                          (wallet?.pendants ?? const []).contains(characterId),
                      // Unpriced (no wallet read yet) or unaffordable rows
                      // stay visible but disabled: the goal is legible, not
                      // hidden.
                      enabled: (prices[option.item] ?? 0) > 0 &&
                          balance >= (prices[option.item] ?? 0),
                      onTap: () {
                        final price = prices[option.item] ?? 0;
                        Navigator.of(sheetContext).pop();
                        onTribute(option.item, price);
                      },
                    ),
                ],
                const SizedBox(height: 18),
                Text(
                  'HOW TO EARN',
                  style: GoogleFonts.lato(
                    color: Colors.white38,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 8),
                const _EarnRow(Icons.wb_twilight, 'Return each day', '+25'),
                _EarnRow(
                  Icons.chat_bubble_outline,
                  'Every reply in a conversation'
                  '${wallet != null && wallet.replyGrantCap > 0 ? ' (${wallet.replyGrantsToday}/${wallet.replyGrantCap} today)' : ''}',
                  '+1',
                ),
                const _EarnRow(Icons.account_circle_outlined, 'Sign in with Google', '+100'),
                const _EarnRow(Icons.badge_outlined, 'Complete your profile', '+200'),
                if (wallet != null && wallet.recent.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Text(
                    'RECENT',
                    style: GoogleFonts.lato(
                      color: Colors.white38,
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
                    style: GoogleFonts.lato(color: Colors.white54),
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

class _TributeRow extends StatelessWidget {
  final TributeOption option;
  final int price;
  final bool enabled;
  final bool worn;
  final VoidCallback onTap;

  const _TributeRow({
    required this.option,
    required this.price,
    required this.enabled,
    required this.onTap,
    this.worn = false,
  });

  @override
  Widget build(BuildContext context) {
    final gold = Theme.of(context).colorScheme.secondary;
    // A worn pendant is not a disabled row — it is a finished one. Same gold
    // as an affordable gift, so the sheet reads as an achievement rather than
    // something switched off.
    final live = enabled && !worn;
    final ink = worn
        ? gold
        : enabled
            ? Colors.white
            : Colors.white38;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: worn
            ? gold.withOpacity(0.07)
            : enabled
                ? gold.withOpacity(0.10)
                : Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: live ? onTap : null,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: worn
                    ? gold.withOpacity(0.35)
                    : enabled
                        ? gold.withOpacity(0.5)
                        : Colors.white12,
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
                    opacity: worn || enabled ? 1.0 : 0.35,
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
                        worn
                            ? 'Worn since you gave it.'
                            : option.detail,
                        style: GoogleFonts.lato(
                          color: enabled || worn
                              ? Colors.white54
                              : Colors.white24,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (worn)
                  Text(
                    'Worn',
                    style: GoogleFonts.lato(
                      color: gold,
                      fontWeight: FontWeight.w800,
                    ),
                  )
                else ...[
                  Icon(Icons.paid,
                      size: 14, color: enabled ? gold : Colors.white24),
                  const SizedBox(width: 4),
                  Text(
                    price > 0 ? '$price' : '—',
                    style: GoogleFonts.lato(
                      color: enabled ? gold : Colors.white38,
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
    final gold = Theme.of(context).colorScheme.secondary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.white38),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.lato(color: Colors.white70, fontSize: 13.5),
            ),
          ),
          Text(
            amount,
            style: GoogleFonts.lato(
              color: gold,
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
    final gold = Theme.of(context).colorScheme.secondary;
    final delta = row['delta'] is int
        ? row['delta'] as int
        : int.tryParse('${row['delta']}') ?? 0;
    final label = CoinGrant('${row['reason']}', delta).label;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              delta < 0 && '${row['reason']}' == 'gift' ? 'Tribute' : label,
              style: GoogleFonts.lato(color: Colors.white54, fontSize: 12.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            delta > 0 ? '+$delta' : '$delta',
            style: GoogleFonts.lato(
              color: delta > 0 ? gold : Colors.white54,
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
            ),
          ),
        ],
      ),
    );
  }
}
