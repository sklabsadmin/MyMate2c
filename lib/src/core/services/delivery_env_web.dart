import 'dart:js_interop';

extension type _Navigator._(JSObject _) implements JSObject {
  external _NetworkInformation? get connection;
}

extension type _NetworkInformation._(JSObject _) implements JSObject {
  external String? get effectiveType;
}

@JS('navigator')
external _Navigator get _navigator;

/// The browser's own estimate of the connection quality: "4g", "3g", "2g",
/// "slow-2g", and occasionally absent.
///
/// This is a throughput estimate rather than a statement about the radio — a
/// throttled wifi connection can report "2g" — which is exactly what makes it
/// useful for the question being asked. A visitor whose bubbles never arrive
/// while the browser is calling the connection "slow-2g" is a different finding
/// from one whose bubbles never arrive on "4g", and only the second implicates
/// anything at our end.
///
/// Null on any browser without the API (all of Safari, at time of writing),
/// which is a large enough share that a query grouping on this column has to
/// treat NULL as a real bucket rather than as an outlier.
String? connectionType() {
  try {
    return _navigator.connection?.effectiveType;
  } catch (_) {
    // Never let a telemetry read break a chat. Same rule as logFunnelEvent.
    return null;
  }
}
