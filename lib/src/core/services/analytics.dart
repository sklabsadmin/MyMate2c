/// Reports in-app funnel events to whatever owns the visit on this platform.
///
/// On the web that is the visit beacon in web/index.html: it generates a
/// visit id per page load, keeps it in sessionStorage, and already sent the
/// arrive row before Flutter existed — so these events pair automatically
/// with the arrive/app_ready/leave rows for the same visit, and nothing here
/// needs to know about ids or the endpoint.
///
/// On iOS and Android there is no page and no beacon, so the io
/// implementation IS the beacon: it mints a visit id per app launch, posts
/// the same JSON to the same /api/visit endpoint, declares appPlatform
/// ('ios'/'android' — the web page declares 'web'), and opens the visit
/// itself when main() calls [startVisitFunnel]. Same events, same shapes,
/// one funnel — which is what makes web vs app comparable at all.
///
/// The pure stub remains for any platform that is neither (desktop dev
/// runs resolve to io, but a configured backend is still required before a
/// single byte is sent).
export 'analytics_stub.dart'
    if (dart.library.js_interop) 'analytics_web.dart'
    if (dart.library.io) 'analytics_io.dart';
