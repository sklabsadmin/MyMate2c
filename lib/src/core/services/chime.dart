/// Plays the quick-reply strip's four notes through the oscillator chime in
/// web/index.html.
///
/// The notes are synthesised in the browser rather than shipped as audio
/// assets — see the comment on the chime block in tool/patch_splash.py, which
/// holds the canonical copy of that script.
///
/// Web-only by nature, and the stub keeps mobile and desktop builds compiling
/// without an `if (kIsWeb)` at the call site — same arrangement as
/// [logFunnelEvent] in analytics.dart.
export 'chime_stub.dart' if (dart.library.js_interop) 'chime_web.dart';
