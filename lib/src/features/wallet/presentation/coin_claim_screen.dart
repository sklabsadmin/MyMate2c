import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../coin_wallet.dart';

/// The screen that hands over the coins the entry card promised.
///
/// Shown once, over the chat, at the tap that says "Tap to Claim Coins" — and
/// only when there is actually something to claim. The grants themselves
/// happened server-side at wallet sync; this is where the visitor is told.
///
/// It covers the conversation completely and holds it: the same rule the entry
/// card is built on — nothing is said to a screen nobody is looking at — so the
/// character's opening does not play out behind a card the visitor has not
/// dismissed yet.
class CoinClaimScreen extends StatefulWidget {
  /// What was just granted, in the order the server listed it.
  final List<CoinGrant> grants;

  /// The balance after the grants, for the line under the total.
  final int balance;

  /// Dismisses this screen and lets the conversation begin.
  final VoidCallback onCollect;

  const CoinClaimScreen({
    super.key,
    required this.grants,
    required this.balance,
    required this.onCollect,
  });

  @override
  State<CoinClaimScreen> createState() => _CoinClaimScreenState();
}

class _CoinClaimScreenState extends State<CoinClaimScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    // Started in initState rather than on a post-frame callback: this screen is
    // put up by the same setState that hides the entry card, so the first frame
    // it is built into is already the one the visitor sees.
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The staggered entrance, as an interval of the one controller. Returns a
  /// straight 1.0 when the platform asks for stillness, so every child below
  /// can be written the same way whether or not it animates.
  double _phase(double begin, double end, {required bool still}) {
    if (still) return 1.0;
    return Curves.easeOut.transform(
      ((_controller.value - begin) / (end - begin)).clamp(0.0, 1.0),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gold = theme.colorScheme.secondary;
    // Honour the platform's reduce-motion setting — the same courtesy the
    // pulsing entry button pays. Someone who asked for stillness still gets
    // every word of this screen, just all at once.
    final still = MediaQuery.of(context).disableAnimations;
    final total = widget.grants.fold<int>(0, (sum, g) => sum + g.delta);

    return Positioned.fill(
      child: Container(
        key: const ValueKey('coin_claim_surface'),
        // Opaque at every stop, for the reason the entry card documents: a
        // translucent overlay lets the quick-reply strip and the message box
        // read through, and then this stops being a screen at all.
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFF2E003E),
              Color.alphaBlend(gold.withOpacity(0.10), const Color(0xFF1A0520)),
              const Color(0xFF12000F),
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              children: [
                // The celebration scrolls; the button never moves. At 360x560
                // — the small end of the in-app browser band — this content
                // overflowed by 81px, and on a screen whose only exit is one
                // button, that is a visitor with no way forward. Expanded plus
                // a scroll view makes the overflow impossible rather than
                // unlikely; the minHeight keeps everything centred on the
                // taller screens, where there is room to spare.
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(minHeight: constraints.maxHeight),
                        child: Center(
                          child: AnimatedBuilder(
                            animation: _controller,
                            builder: (context, _) => _celebration(
                              gold: gold,
                              still: still,
                              total: total,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Alone at the foot, like the entry card's button: the only
                // thing on this screen that does anything.
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: widget.onCollect,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: gold,
                      // Deep purple on gold, never white: 12.8:1 against this
                      // background versus white's 1.4:1. Same pairing the
                      // entry button uses.
                      foregroundColor: const Color(0xFF2E003E),
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    child: Text(
                      'Collect and begin',
                      style: GoogleFonts.outfit(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Balance: ${widget.balance}',
                  style: GoogleFonts.lato(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 14),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _celebration({
    required Color gold,
    required bool still,
    required int total,
  }) {
    final coin = _phase(0.0, 0.45, still: still);
    final headline = _phase(0.25, 0.7, still: still);
    final rows = _phase(0.45, 0.9, still: still);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        Opacity(
          opacity: coin,
          child: Transform.scale(
            scale: 0.7 + (0.3 * coin),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: gold.withOpacity(0.12),
                border: Border.all(color: gold, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: gold.withOpacity(0.35 * coin),
                    blurRadius: 40,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: Icon(Icons.paid, size: 48, color: gold),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Opacity(
          opacity: headline,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Your coins are yours',
                textAlign: TextAlign.center,
                style: GoogleFonts.playfairDisplay(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '+$total',
                style: GoogleFonts.outfit(
                  color: gold,
                  fontSize: 50,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Opacity(
          opacity: rows,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final grant in widget.grants)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle, size: 15, color: gold),
                      const SizedBox(width: 8),
                      Text(
                        grant.label,
                        style: GoogleFonts.lato(
                          color: Colors.white,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '+${grant.delta}',
                        style: GoogleFonts.lato(
                          color: gold,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                'Spend them on tributes your companions will answer for.',
                textAlign: TextAlign.center,
                style: GoogleFonts.lato(
                  color: Colors.white.withOpacity(0.66),
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ],
    );
  }
}
