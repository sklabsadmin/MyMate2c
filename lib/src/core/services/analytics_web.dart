import 'dart:js_interop';

@JS('mythosVisitBeacon')
external JSFunction? get _beacon;

/// Fires one funnel event, tagging it with the app's own user id where known
/// so a visit can be joined to its chat transcripts. The splash beacon cannot
/// supply that id — it runs before Flutter exists — which is why only the
/// in-app events carry it.
///
/// Silent on failure by design: analytics must never be able to break a tap,
/// and the beacon is absent from any index.html predating it (or if a future
/// flutter_native_splash:create wipes it before tool/patch_splash.py re-runs).
void logFunnelEvent(String event, {String? detail, String? appUserId}) {
  try {
    final fn = _beacon;
    if (fn == null) return;
    fn.callAsFunction(null, event.toJS, detail?.toJS, appUserId?.toJS);
  } catch (_) {
    // Deliberately swallowed.
  }
}
