import 'package:flutter/material.dart';

/// The coin balance, as a small gold pill: ● 120.
///
/// Gold because gold is already this app's "the one thing that does anything"
/// colour — the Tap to Talk button, the epithets, the avatar ring — and a
/// currency should borrow exactly that. Tabular digits so the chip does not
/// wobble as the number moves.
class CoinChip extends StatelessWidget {
  final int balance;
  final VoidCallback? onTap;
  final bool compact;

  const CoinChip({
    super.key,
    required this.balance,
    this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final gold = Theme.of(context).colorScheme.secondary;
    return Semantics(
      button: onTap != null,
      label: '$balance coins',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 10,
            vertical: compact ? 4 : 6,
          ),
          decoration: BoxDecoration(
            color: gold.withOpacity(0.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: gold.withOpacity(0.55)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.paid, size: compact ? 14 : 16, color: gold),
              const SizedBox(width: 5),
              // AnimatedSwitcher so a grant reads as the number changing,
              // not the whole header repainting.
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, -0.4),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: Text(
                  '$balance',
                  key: ValueKey<int>(balance),
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: compact ? 13 : 14,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
