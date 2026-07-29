/// Reports in-app funnel events to the visit beacon in web/index.html.
///
/// The beacon already owns the visit id (it generates one per page load and
/// keeps it in sessionStorage), so these events pair automatically with the
/// arrive/app_ready/leave rows for the same visit. Nothing here needs to know
/// about ids, signing, or the endpoint.
///
/// Web-only by nature — the beacon is a browser thing. The stub keeps mobile
/// builds compiling without a single `if (kIsWeb)` at the call sites.
export 'analytics_stub.dart' if (dart.library.js_interop) 'analytics_web.dart';
