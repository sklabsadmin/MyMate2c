import 'dart:js_interop';

@JS('mythosChime')
external JSFunction? get _chime;

/// Sounds one note of the quick-reply strip's sequence.
///
/// [step] 0-2 are the three rows, climbing a major triad as each lights up; 3
/// is the instruction flash, which sounds the whole triad plus its octave.
///
/// Silent on failure by design, exactly as the analytics beacon is: the script
/// is absent from any index.html predating it (or if a future
/// flutter_native_splash:create wipes it before tool/patch_splash.py re-runs),
/// the browser may have no Web Audio at all, and none of that is worth an
/// exception on a decorative sound.
///
/// It is also silent whenever the visitor has not yet interacted with the
/// page, because browsers refuse to start audio before a gesture. In practice
/// the tap that opens the chat is that gesture, so by the time the strip
/// chimes the context has been unlocked — but a visitor who somehow reaches
/// the chat without one simply gets no sound rather than an error.
void playChime(int step) {
  try {
    final fn = _chime;
    if (fn == null) return;
    fn.callAsFunction(null, step.toJS);
  } catch (_) {
    // Deliberately swallowed.
  }
}
