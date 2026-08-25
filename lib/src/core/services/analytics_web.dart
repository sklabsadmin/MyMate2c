import 'dart:js_interop';

@JS('mythosVisitBeacon')
external JSFunction? get _beacon;

@JS('mythosVisitId')
external String? get _visitId;

@JS('mythosVariant')
external String? get _variant;

/// Fires one funnel event, tagging it with the app's own user id where known
/// so a visit can be joined to its chat transcripts. The splash beacon cannot
/// supply that id — it runs before Flutter exists — which is why only the
/// in-app events carry it.
///
/// [failureReason] is only meaningful for the send_failed event, where it says
/// why the send failed; every other event leaves it null.
///
/// Silent on failure by design: analytics must never be able to break a tap,
/// and the beacon is absent from any index.html predating it (or if a future
/// flutter_native_splash:create wipes it before tool/patch_splash.py re-runs).
void logFunnelEvent(
  String event, {
  String? detail,
  String? appUserId,
  String? failureReason,
}) {
  try {
    final fn = _beacon;
    if (fn == null) return;
    fn.callAsFunction(
      null,
      event.toJS,
      detail?.toJS,
      appUserId?.toJS,
      failureReason?.toJS,
    );
  } catch (_) {
    // Deliberately swallowed.
  }
}

/// The current page load's visit id, or null off the web (or on an
/// index.html predating the beacon).
///
/// Sent as x-visit-id on chat requests so conversation_logs rows join onto the
/// arrive/app_ready/leave rows for the same visit — which is what makes
/// "how far into a conversation did this session get" answerable.
String? currentVisitId() {
  try {
    return _visitId;
  } catch (_) {
    return null;
  }
}

/// This device's A/B assignment as "experiment:arm", or null when no
/// experiment is running (or on an index.html predating the rig). Drawn once
/// per device by the page script and kept in localStorage; the same string
/// rides every funnel beacon, which is what makes the arm the UI branches on
/// and the arm the admin split reports provably the same coin flip.
String? currentVariant() {
  try {
    return _variant;
  } catch (_) {
    return null;
  }
}
