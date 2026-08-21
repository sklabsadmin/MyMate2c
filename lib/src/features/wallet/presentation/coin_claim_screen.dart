import 'dart:ui' show FontFeature;

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
      // Long enough for the purse to visibly fill. The coins land across the
      // middle of it; the button is on screen throughout, so nobody is ever
      // waiting on the animation to leave.
      duration: const Duration(milliseconds: 2200),
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
    final coin = _phase(0.0, 0.22, still: still);
    final headline = _phase(0.18, 0.45, still: still);
    final rows = _phase(0.62, 0.9, still: still);
    // The purse fills while the coins are in the air, and the number counts
    // with it — the figure and the picture must not disagree mid-animation.
    final fill = _phase(0.12, 0.7, still: still);
    final drop = still ? 1.0 : ((_controller.value - 0.1) / 0.62).clamp(0.0, 1.0);
    final counted = (total * fill).round();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        Opacity(
          opacity: coin,
          child: _CoinPurse(fill: fill, drop: drop, gold: gold),
        ),
        const SizedBox(height: 14),
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
                '+$counted',
                style: GoogleFonts.outfit(
                  color: gold,
                  fontSize: 50,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                  // Tabular, or the whole line jitters as the count runs.
                  fontFeatures: const [FontFeature.tabularFigures()],
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

/// A Greek drawstring purse, filling with coins.
///
/// Drawn rather than shipped: `assets/images/` is globbed into every deploy
/// and this app has already had one payload emergency, so a picture of a purse
/// would cost more than the whole coins feature. Everything here is paths and
/// arithmetic — it costs nothing and scales to any screen.
///
/// [fill] runs 0 → 1 as the coins land: the purse plumps, its glow comes up,
/// and the pile inside its mouth rises. [drop] is the same clock for the coins
/// falling in, kept separate so a still (reduced-motion) render can show a
/// full purse with nothing in mid-air.
class _CoinPurse extends StatelessWidget {
  final double fill;
  final double drop;
  final Color gold;
  final int coinCount;

  const _CoinPurse({
    required this.fill,
    required this.drop,
    required this.gold,
    this.coinCount = 7,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 190,
      height: 206,
      child: CustomPaint(
        painter: _PursePainter(
          fill: fill,
          drop: drop,
          gold: gold,
          coinCount: coinCount,
        ),
      ),
    );
  }
}

class _PursePainter extends CustomPainter {
  final double fill;
  final double drop;
  final Color gold;
  final int coinCount;

  _PursePainter({
    required this.fill,
    required this.drop,
    required this.gold,
    required this.coinCount,
  });

  // Authored in a 100 x 110 box and scaled, so the drawing reads the same on a
  // 360pt phone and a desktop window.
  //
  // Shape notes, because the first attempt got this wrong: a round body with a
  // band across its equator and a cap on top is a Christmas bauble, not a
  // purse. What makes it a pouch is the silhouette — a narrow gathered neck,
  // shoulders that flare below it, a heavy uneven bottom that looks like it is
  // resting on something — plus the cord and the fabric folds. The Greek key
  // sits low, as an embroidered hem, rather than ringing the middle.
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 100.0;
    canvas.save();
    canvas.translate(0, size.height - 110 * s);
    canvas.scale(s);

    // The purse SWELLS as it fills, from about two thirds up to full size.
    // An empty bag that is already the size of a full one has nothing left to
    // say when the coins land, and reads as oversized while it waits.
    //
    // Anchored at the base, not the middle, because a bag on a surface fills
    // upward and outward — the bottom stays where it is and the body grows
    // around it.
    final swell = 0.66 + 0.34 * fill;
    canvas.save();
    canvas.translate(50, 107);
    canvas.scale(swell);
    canvas.translate(-50, -107);

    _paintGlow(canvas);
    _paintBody(canvas);
    _paintHem(canvas);
    _paintFolds(canvas);
    _paintCord(canvas);
    _paintNeck(canvas);
    // Inside the swell, so the coins fall into the neck wherever the neck has
    // grown to rather than at a fixed height it has moved away from.
    _paintFallingCoins(canvas);

    canvas.restore();
    canvas.restore();
  }

  void _paintGlow(Canvas canvas) {
    if (fill <= 0) return;
    canvas.drawCircle(
      const Offset(50, 84),
      42,
      Paint()
        ..color = gold.withOpacity(0.18 * fill)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24),
    );
  }

  /// A sack, and the shape is the whole argument: the widest point sits LOW
  /// (around y 90, not halfway) and the base is broad and flat, because a
  /// heavy bag settles onto what it rests on. Put the widest point in the
  /// middle and give it a curved base and you have drawn a bauble — which is
  /// exactly what the first version looked like.
  Path _bodyPath() {
    return Path()
      ..moveTo(41, 39)
      ..cubicTo(30, 48, 19, 66, 15, 84)
      ..cubicTo(12, 97, 23, 107, 39, 107)
      ..lineTo(61, 107)
      ..cubicTo(77, 107, 88, 97, 85, 84)
      ..cubicTo(81, 66, 70, 48, 59, 39)
      ..close();
  }

  void _paintBody(Canvas canvas) {
    final body = _bodyPath();
    canvas.drawPath(
      body,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF8A4260), Color(0xFF3A1A2D), Color(0xFF24101D)],
          stops: [0.0, 0.55, 1.0],
        ).createShader(const Rect.fromLTWH(8, 34, 84, 74)),
    );
    canvas.drawPath(
      body,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..color = gold.withOpacity(0.5 + 0.4 * fill),
    );
  }

  /// The fabric, gathered at the neck and falling away. Three creases, uneven,
  /// because even folds read as a printed pattern.
  void _paintFolds(Canvas canvas) {
    final fold = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withOpacity(0.10);
    canvas.save();
    canvas.clipPath(_bodyPath());
    canvas.drawPath(
      Path()
        ..moveTo(45, 41)
        ..cubicTo(36, 58, 30, 74, 29, 94),
      fold,
    );
    canvas.drawPath(
      Path()
        ..moveTo(52, 41)
        ..cubicTo(50, 60, 52, 78, 55, 100),
      fold,
    );
    canvas.drawPath(
      Path()
        ..moveTo(57, 41)
        ..cubicTo(67, 56, 74, 72, 73, 92),
      fold,
    );
    canvas.restore();
  }

  /// The Greek key, low on the body like embroidery on a hem — this is what
  /// makes it a Greek purse rather than a moneybag, but ringing the middle
  /// with it is what made it look like an ornament.
  void _paintHem(Canvas canvas) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeJoin = StrokeJoin.miter
      ..color = gold.withOpacity(0.62);

    canvas.save();
    canvas.clipPath(_bodyPath());
    const unit = 13.0;
    for (double x = 8; x < 96; x += unit) {
      canvas.drawPath(
        Path()
          ..moveTo(x, 98)
          ..lineTo(x, 88)
          ..lineTo(x + 9, 88)
          ..lineTo(x + 9, 96)
          ..lineTo(x + 4, 96)
          ..lineTo(x + 4, 92),
        paint,
      );
    }
    for (final y in const [85.0, 100.0]) {
      canvas.drawLine(Offset(4, y), Offset(96, y), paint);
    }
    canvas.restore();
  }

  /// The drawstring: wrapped twice at the cinch, with both ends hanging down
  /// the left side and a knot on each. A pouch without a cord is a pot.
  void _paintCord(Canvas canvas) {
    final cord = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..color = gold.withOpacity(0.85);
    // Two turns around the gathered neck.
    canvas.drawLine(const Offset(37, 39), const Offset(63, 39), cord);
    canvas.drawLine(const Offset(38, 43), const Offset(62, 43), cord);
    // The ends, falling away and forward.
    canvas.drawPath(
      Path()
        ..moveTo(38, 43)
        ..cubicTo(30, 50, 24, 56, 22, 65),
      cord,
    );
    canvas.drawPath(
      Path()
        ..moveTo(40, 44)
        ..cubicTo(34, 54, 31, 61, 31, 70),
      cord,
    );
    canvas.drawCircle(const Offset(22, 66), 2.2, Paint()..color = gold);
    canvas.drawCircle(const Offset(31, 71), 2.0, Paint()..color = gold);
  }

  /// The gathered top, and the coins heaped in it.
  ///
  /// Painted back to front — dark opening, far edge, heap, near edge — so the
  /// coins sit INSIDE the purse. Clipping them into the opening instead (the
  /// first attempt) sliced every coin in half and read as a progress bar.
  void _paintNeck(Canvas canvas) {
    final mouth = Rect.fromCenter(
      center: const Offset(50, 34),
      width: 30 + 3 * fill,
      height: 12,
    );
    canvas.drawOval(mouth, Paint()..color = const Color(0xFF190A15));

    final rim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..color = gold.withOpacity(0.65 + 0.35 * fill);
    canvas.drawArc(mouth, 3.14159, 3.14159, false, rim);

    if (fill > 0) {
      // A heap: overlapping, uneven, rising out of the neck as it fills, so a
      // full purse is visibly fuller than an empty one in a still frame.
      const seats = [
        Offset(43, 33), Offset(57, 33), Offset(50, 31),
        Offset(46, 27), Offset(55, 26.5),
      ];
      const radii = [5.0, 4.8, 5.4, 4.4, 4.0];
      for (var i = 0; i < seats.length; i++) {
        final t = ((fill - i * 0.16) / 0.36).clamp(0.0, 1.0);
        if (t <= 0) continue;
        _paintCoin(canvas, seats[i].translate(0, (1 - t) * 5), radii[i], t);
      }
    }

    // Near edge last, so the heap is held inside the purse rather than
    // floating on top of it.
    canvas.drawArc(mouth, 0, 3.14159, false, rim);

    // The frill of gathered fabric standing above the cord.
    final frill = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = gold.withOpacity(0.5);
    canvas.drawPath(
      Path()
        ..moveTo(37, 39)
        ..cubicTo(35, 32, 36, 28, 39, 26),
      frill,
    );
    canvas.drawPath(
      Path()
        ..moveTo(63, 39)
        ..cubicTo(65, 32, 64, 28, 61, 26),
      frill,
    );
  }

  void _paintFallingCoins(Canvas canvas) {
    if (drop <= 0 || drop >= 1) return;
    for (var i = 0; i < coinCount; i++) {
      // Staggered so they arrive as a stream rather than a single clump.
      final start = i / (coinCount + 2);
      final t = ((drop - start) / 0.42).clamp(0.0, 1.0);
      if (t <= 0 || t >= 1) continue;
      final eased = t * t; // ease-in, because they are falling
      final x = 50 + (i.isEven ? -1 : 1) * (3.0 + (i % 3) * 2.5) * (1 - eased);
      final y = -34 + eased * 66;
      // Fades through the opening rather than vanishing on the rim, which
      // reads as landing rather than being deleted.
      final opacity = t > 0.82 ? (1 - t) / 0.18 : 1.0;
      _paintCoin(canvas, Offset(x, y), 5.2 - (i % 2) * 0.7, opacity);
    }
  }

  void _paintCoin(Canvas canvas, Offset centre, double r, double opacity) {
    if (opacity <= 0) return;
    canvas.drawCircle(centre, r, Paint()..color = gold.withOpacity(0.95 * opacity));
    canvas.drawCircle(
      centre,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xFF8A6500).withOpacity(0.9 * opacity),
    );
    // The struck face — a tiny arc, enough to read as a coin and not a dot.
    canvas.drawArc(
      Rect.fromCircle(center: centre, radius: r * 0.45),
      2.4,
      3.0,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xFF8A6500).withOpacity(0.75 * opacity),
    );
  }

  @override
  bool shouldRepaint(_PursePainter old) =>
      old.fill != fill || old.drop != drop || old.gold != gold;
}
