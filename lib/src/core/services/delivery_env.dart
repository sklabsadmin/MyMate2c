/// The one part of delivery logging that cannot be written once for both
/// platforms.
///
/// @docImport 'delivery_log.dart';
library;
///
/// Everything else about deciding whether a bubble was seen is done in Dart —
/// the render box against the scroll viewport, and AppLifecycleState for whether
/// the surface is frontmost — so it behaves identically on web and mobile. That
/// was forced rather than chosen: the app renders through Flutter's canvas on
/// web, so a chat bubble is not a DOM element and IntersectionObserver was never
/// an option. The upshot is that only the network hint below needs a per-platform
/// implementation.
///
/// See docs/mobile-delivery-logging.md for why the mobile equivalent is not a
/// drop-in swap: connectivity_plus reports which interface is in use, while the
/// browser reports an estimate of observed throughput, and writing both into one
/// column would produce groupings that cannot be compared.
export 'delivery_env_stub.dart'
    if (dart.library.js_interop) 'delivery_env_web.dart';
