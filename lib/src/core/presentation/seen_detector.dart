import 'dart:async';

import 'package:flutter/widgets.dart';

/// Reports once, when the bubble it wraps has genuinely been in front of the
/// visitor.
///
/// "Rendered" is not the same claim. A bubble can be built, laid out, and
/// painted while sitting below the fold, in a backgrounded tab, or on a route
/// the visitor has already left. Counting those as seen is how a delivery report
/// ends up agreeing that everything arrived while engagement says otherwise, so
/// this insists on three things at once:
///
///   * the surface is frontmost — see [isSurfaceVisible], which the chat screen
///     answers from AppLifecycleState (on web that is the Page Visibility API,
///     which is what makes a hidden tab count as not seen)
///   * at least [_minVisibleFraction] of the bubble's height is inside the
///     scroll viewport
///   * it stays that way for [_dwell]
///
/// The dwell is what separates reading from scrolling past. Without it, a fling
/// through the backlog marks every bubble it flashed over as seen, which would
/// make the numbers worse than having none — they would be confidently wrong
/// rather than absent.
///
/// Deliberately no dependency: visibility_detector would do this, and adding a
/// package for one screen was not worth it when the geometry is a dozen lines of
/// public API. Both checks are plain Flutter, so this behaves the same on mobile
/// if that is ever wanted (docs/mobile-delivery-logging.md).
class SeenDetector extends StatefulWidget {
  const SeenDetector({
    super.key,
    required this.bubbleId,
    required this.revalidate,
    required this.isSurfaceVisible,
    required this.onSeen,
    required this.child,
  });

  /// Which receipt to complete, or null for a bubble that predates delivery
  /// logging — a message restored from local history has no receipt, and
  /// inventing one would report an old message as freshly seen.
  final String? bubbleId;

  /// Fires whenever something that could change the answer happened: a scroll,
  /// or the app moving between foreground and background.
  final Listenable revalidate;

  final bool Function() isSurfaceVisible;
  final void Function(String bubbleId) onSeen;
  final Widget child;

  @override
  State<SeenDetector> createState() => _SeenDetectorState();
}

class _SeenDetectorState extends State<SeenDetector> {
  /// How much of the bubble has to be inside the viewport. Half, because a
  /// bubble cut by the input bar or the top edge has still been read, while one
  /// showing a two-pixel sliver has not.
  static const double _minVisibleFraction = 0.5;

  /// How long it has to stay there. Long enough to exclude a fast scroll,
  /// short enough that a bubble someone genuinely looked at is never missed.
  static const Duration _dwell = Duration(milliseconds: 300);

  /// How many times a dwell may be re-armed after finding the bubble gone when
  /// it elapsed.
  ///
  /// Bounded so a bubble scrolled far away stops costing timers, but generous
  /// enough to cover the case this exists for: a new bubble arriving scrolls the
  /// list, which is exactly when a dwell is most likely to elapse mid-motion.
  /// Ten attempts is three seconds of chances.
  static const int _maxDwellAttempts = 10;

  Timer? _dwellTimer;
  int _dwellAttempts = 0;
  bool _reported = false;

  @override
  void initState() {
    super.initState();
    widget.revalidate.addListener(_check);
    // First chance to be visible is the frame after this one — geometry does not
    // exist until layout has run.
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void didUpdateWidget(SeenDetector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revalidate != widget.revalidate) {
      oldWidget.revalidate.removeListener(_check);
      widget.revalidate.addListener(_check);
    }
    // List items are recycled onto different messages as the list scrolls, so a
    // new id here means this slot is now showing a different bubble and has to
    // earn its sighting again.
    if (oldWidget.bubbleId != widget.bubbleId) {
      _reported = false;
      _dwellAttempts = 0;
      _dwellTimer?.cancel();
      WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    }
  }

  @override
  void dispose() {
    widget.revalidate.removeListener(_check);
    _dwellTimer?.cancel();
    super.dispose();
  }

  void _check() {
    if (_reported || !mounted) return;
    if (widget.bubbleId == null) return;
    if (!_isVisibleNow()) return;
    if (_dwellTimer?.isActive == true) return;
    _armDwell();
  }

  /// Starts the dwell, and re-arms it if the bubble has moved by the time it
  /// elapses.
  ///
  /// The retry is the whole point. A bubble is drawn, the list scrolls to keep
  /// up, and the dwell elapses mid-scroll with the bubble momentarily outside
  /// the band being measured — at which point giving up would be final, because
  /// scrolling then stops and no further notification ever arrives to re-check
  /// it. That lost a bubble that had been on screen the entire time, and it lost
  /// the middle of a run rather than the end, which is exactly the shape that
  /// would have been read as a delivery fault.
  void _armDwell() {
    _dwellTimer = Timer(_dwell, () {
      _dwellTimer = null;
      final bubbleId = widget.bubbleId;
      if (_reported || !mounted || bubbleId == null) return;

      if (_isVisibleNow()) {
        _reported = true;
        widget.onSeen(bubbleId);
        return;
      }

      if (_dwellAttempts++ < _maxDwellAttempts) _armDwell();
    });
  }

  bool _isVisibleNow() {
    try {
      if (!widget.isSurfaceVisible()) return false;

      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) return false;
      if (box.size.height <= 0) return false;

      // The viewport, not the window: the message list does not own the whole
      // screen, and a bubble scrolled under the input bar is not on screen.
      final viewportBox =
          Scrollable.maybeOf(context)?.context.findRenderObject() as RenderBox?;
      if (viewportBox == null || !viewportBox.attached) return false;

      final self = box.localToGlobal(Offset.zero) & box.size;
      final viewport = viewportBox.localToGlobal(Offset.zero) & viewportBox.size;

      final overlap = self.intersect(viewport);
      if (overlap.height <= 0 || overlap.width <= 0) return false;

      // Vertical only. The list scrolls one way, and a bubble is never partly
      // off the side — measuring area instead would just add a term that is
      // always 1.
      return overlap.height / self.height >= _minVisibleFraction;
    } catch (_) {
      // Geometry can be queried mid-teardown. A missed sighting is a gap in a
      // report; a thrown exception here is a broken chat.
      return false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
