/// No-op on non-web platforms, where there is no page and no beacon.
void logFunnelEvent(
  String event, {
  String? detail,
  String? appUserId,
  String? failureReason,
}) {}

/// Null off the web: a visit id belongs to a page load, and there isn't one.
String? currentVisitId() => null;
