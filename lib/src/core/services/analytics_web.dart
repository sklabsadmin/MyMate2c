import 'dart:js_interop';

@JS('mythosVisitBeacon')
external JSFunction? get _beacon;

/// Fires one funnel event. Silent on failure by design: analytics must never
/// be able to break a tap, and the beacon is absent in any build whose
/// index.html predates it (or if a future flutter_native_splash:create wipes
/// it before tool/patch_splash.py is re-run).
void logFunnelEvent(String event, {String? detail}) {
  try {
    final fn = _beacon;
    if (fn == null) return;
    fn.callAsFunction(null, event.toJS, detail?.toJS);
  } catch (_) {
    // Deliberately swallowed.
  }
}
