#!/usr/bin/env python3
"""Re-apply the custom web splash on top of flutter_native_splash's output.

`dart run flutter_native_splash:create` regenerates the <style
id="splash-screen-style"> and <script id="splash-screen-script"> blocks in
web/index.html, silently discarding everything below. It has done so four
times during development — once wiping only the timing while leaving the CSS,
so the splash *looked* right but had lost its dwell.

Run this immediately after every `flutter_native_splash:create`:

    dart run flutter_native_splash:create && python3 tool/patch_splash.py

What it adds, none of which the package supports:
  * an opaque backdrop so the splash sits *above* Flutter's canvas. The app
    never calls FlutterNativeSplash.remove(), so the generated
    removeSplashFromWeb() never fires and the splash was simply painted over
    the instant Flutter rendered — no dwell was possible.
  * a tagline with animated dots
  * dismissal driven by Flutter's first paint, with no minimum dwell — the
    splash lifts the instant the app is usable
"""
import io, re, sys

INDEX = "web/index.html"
# Sampled from mythoslive_logoDark.png's own field colour, rgb(26,3,33) — the
# art is RGB with no alpha, so matching this is what hides its square edges.
BACKDROP = "#1A0520"
APP_BG = "#1A0520"        # AppTheme.backgroundColor — what /c/ links load into
TAGLINE = "Connecting you with the ancient past"
READY_CAP_MS = 15000   # never hold anyone behind the splash longer than this

# Regenerate these from brand/mythoslive_logoDark.png with tool/make_splash_logo.js
PICTURE_SOURCES = (
    '      <source type="image/webp" srcset="'
    'splash/img/logodark-1x.webp 1x, splash/img/logodark-2x.webp 2x, '
    'splash/img/logodark-3x.webp 3x, splash/img/logodark-4x.webp 4x">\n'
    '      <img class="center" aria-hidden="true" src="splash/img/logodark-1x.png" alt="">\n'
)

CSS = f'''  <!-- Custom splash. Regenerated away by flutter_native_splash:create —
       re-apply with: python3 tool/patch_splash.py -->
  <style id="splash-extras">
    #mythos-backdrop {{ position: fixed; inset: 0; background: {BACKDROP}; z-index: 9998; }}
    /* z-index must sit on the img: #splash is a <picture>, which is not
       positioned, so a z-index there does nothing. .center makes the img
       absolute. */
    /* No entrance animation. The logo was fading and rising over 900ms, which
       on a fast connection meant it was still animating in as the app became
       ready — the first thing a visitor saw was motion that then vanished. It
       is now simply present from the first frame. Capped so it reads as a logo
       rather than filling a large desktop window. */
    #splash img {{ z-index: 9999; width: min(62vw, 300px); height: auto; }}
    #splash-tagline {{
      position: fixed; left: 50%; transform: translateX(-50%);
      bottom: 11vh; margin: 0; width: 92%; text-align: center; z-index: 9999;
      font-family: Georgia, "Times New Roman", serif;
      font-size: clamp(15px, 4.2vw, 19px); letter-spacing: .02em;
      /* Light enough to read on the dark backdrop; the old #6B4B7A was picked
         against cream and is near-invisible on {BACKDROP}. */
      color: #C9B3D6;
    }}
    #splash-tagline .dots span {{ opacity: 0; animation: mythos-dot 1.4s infinite; }}
    #splash-tagline .dots span:nth-child(2) {{ animation-delay: .2s; }}
    #splash-tagline .dots span:nth-child(3) {{ animation-delay: .4s; }}
    @keyframes mythos-dot {{ 0%,60%,100% {{ opacity: 0; }} 30% {{ opacity: 1; }} }}
    /* pointer-events:none so the app is usable the instant the fade starts.
       These sit at z-index 9999 over Flutter, so without it the first 420ms
       of every session silently swallowed taps on a screen that looks ready. */
    body.mythos-leaving #mythos-backdrop,
    body.mythos-leaving #splash,
    body.mythos-leaving #splash-tagline {{
      transition: opacity 420ms ease; opacity: 0; pointer-events: none;
    }}
    /* Only the loading dots animate now, so they are all this needs to stop. */
    @media (prefers-reduced-motion: reduce) {{
      #splash-tagline .dots span {{ animation: none; opacity: 1; }}
    }}
    /* Direct character links: no splash, and the load gap is painted in the
       app's own background (AppTheme.backgroundColor) rather than the splash's
       peach. Without this the visitor gets a light flash then a dark chat,
       which reads as a glitch on exactly the journey we most want to feel
       seamless. The class is set in <head>, so this applies before first paint. */
    html.mythos-direct #mythos-backdrop,
    html.mythos-direct #splash,
    html.mythos-direct #splash-tagline {{ display: none; }}
    html.mythos-direct, html.mythos-direct body {{ background: {APP_BG}; }}
  </style>
'''

SCRIPT = f'''  <script id="splash-screen-script">
    // Direct character links get no splash at all.
    //
    // Someone tapping /c/odysseus came for Odysseus, not for a logo — a brand
    // moment they did not ask for is pure friction on the one journey where
    // intent is already known. Runs here in <head>, before the body paints, so
    // the splash never appears rather than appearing and being torn down.
    //
    // Normal arrivals at / still get it: there the splash is doing real work,
    // covering a ~3MB bundle load that would otherwise be a blank page.
    if (location.pathname.indexOf("/c/") === 0) {{
      document.documentElement.className += " mythos-direct";
    }}

    // The app never calls FlutterNativeSplash.remove(), so the generated
    // removeSplashFromWeb() never fires. We layer the splash above Flutter
    // and dismiss it ourselves.
    // There is deliberately no minimum dwell. The splash lifts the moment
    // Flutter paints, and not a millisecond later.
    //
    // It used to hold for 3000ms on a first visit (1500ms on a return), on
    // top of waiting for Flutter. With app_ready averaging ~1.5s, that meant
    // a first-time visitor sat looking at the logo for a second and a half
    // AFTER the app was ready to use — and anyone who left before the 3s mark
    // never saw the app at all, only the logo. Half of all Instagram arrivals
    // left inside 3s. Someone following a /c/<character> link is here for a
    // specific character, so any hold is pure cost.
    function mythosDismissSplash() {{
      document.body.classList.add("mythos-leaving");
      setTimeout(function () {{
        var ids = ["mythos-backdrop", "splash", "splash-tagline", "splash-branding"];
        for (var i = 0; i < ids.length; i++) {{
          var el = document.getElementById(ids[i]);
          if (el) el.remove();
        }}
        document.body.style.background = "transparent";
      }}, 420);
    }}

    // Longest we will ever hold someone behind the splash waiting for
    // Flutter. Past this we drop it regardless — a stuck bundle should show
    // whatever the app managed rather than an indefinite logo.
    var MYTHOS_READY_CAP_MS = {READY_CAP_MS};

    // Resolves when Flutter has actually put a frame on screen. Three
    // detectors, because no single one is reliable across Flutter versions:
    // the flutter-first-frame event, the view element appearing, and a hard
    // cap. First to fire wins; the rest become no-ops.
    function mythosOnFlutterReady(cb) {{
      var fired = false, observer = null;
      function fire() {{
        if (fired) return;
        fired = true;
        try {{ if (observer) observer.disconnect(); }} catch (e) {{}}
        cb();
      }}
      var sel = "flt-glass-pane, flutter-view, flt-scene-host";
      if (document.querySelector(sel)) return fire();
      window.addEventListener("flutter-first-frame", fire);
      try {{
        observer = new MutationObserver(function () {{
          if (document.querySelector(sel)) fire();
        }});
        observer.observe(document.documentElement, {{ childList: true, subtree: true }});
      }} catch (e) {{}}
      setTimeout(fire, MYTHOS_READY_CAP_MS);
    }}

    document.addEventListener("DOMContentLoaded", function () {{
      // Readiness is the only gate. The splash still covers the whole load —
      // it is dismissed by Flutter painting, not by a timer — so a slow
      // connection never gets dropped onto a blank page, which was the
      // original reason a dwell was introduced. It just no longer holds
      // anyone back once the app is actually there.
      mythosOnFlutterReady(function () {{
        // How long the visitor actually waited for a usable app — the number
        // that separates "left during load" from "saw the app and left".
        try {{
          if (window.mythosVisitBeacon) window.mythosVisitBeacon("app_ready");
        }} catch (e) {{}}
        mythosDismissSplash();
      }});
    }});

    function removeSplashFromWeb() {{}}
  </script>'''

BEACON = r'''  <!-- Arrival/exit beacon.
       Runs here, in the document head, rather than inside the Flutter app:
       main.dart.js is ~3MB, and a visitor arriving from an Instagram in-app
       browser on mobile data can easily give up before it finishes. Anything
       that waits for Flutter therefore misses exactly the people we most need
       to count — which is why ~1000 reported ad clicks showed up as single
       digits in the logs.

       The paired "leave" beacon carries a duration, which is what separates
       "bounced while loading" from "actually looked around". -->
  <script>
  (function () {
    var ARRIVED_AT = Date.now();
    // One id per page load, kept so the leave event can be paired with its
    // arrival. sessionStorage rather than a fresh id each time, so a beacon
    // retried by the browser does not look like a second visitor.
    var visitId;
    try {
      visitId = sessionStorage.getItem('mythos_visit_id');
      if (!visitId) {
        visitId = (Date.now().toString(36) + Math.random().toString(36).slice(2, 10));
        sessionStorage.setItem('mythos_visit_id', visitId);
      }
    } catch (e) {
      visitId = Date.now().toString(36) + Math.random().toString(36).slice(2, 10);
    }

    function send(event, extra) {
      var body = JSON.stringify(Object.assign({
        visitId: visitId,
        event: event,
        path: location.pathname,
        query: location.search,
        referer: document.referrer || ''
      }, extra || {}));
      try {
        // sendBeacon survives the page being torn down, which a fetch() does
        // not — that is the whole reason the leave event is measurable at all.
        if (navigator.sendBeacon) {
          navigator.sendBeacon('/api/visit', new Blob([body], { type: 'application/json' }));
          return;
        }
      } catch (e) {}
      try {
        fetch('/api/visit', { method: 'POST', body: body, keepalive: true });
      } catch (e) {}
    }

    // Exposed so the splash script can report app_ready at the moment Flutter
    // paints its first frame. Takes the elapsed time from arrival, which is
    // the real "time to usable app" for this visitor on their real connection.
    window.mythosVisitBeacon = function (event, detail, appUserId) {
      send(event, {
        durationMs: Date.now() - ARRIVED_AT,
        detail: detail || undefined,
        appUserId: appUserId || undefined
      });
    };

    send('arrive');

    var left = false;
    function leave() {
      if (left) return;
      left = true;
      send('leave', { durationMs: Date.now() - ARRIVED_AT });
    }
    // pagehide is the one that fires reliably on mobile Safari and inside
    // in-app browsers; visibilitychange catches tab-switching and app
    // backgrounding. Both funnel through the same once-only guard.
    window.addEventListener('pagehide', leave);
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'hidden') leave();
    });
  })();
  </script>
'''

s = io.open(INDEX, encoding="utf-8").read()
s = re.sub(r'  <!-- Custom splash.*?</style>\n', '', s, count=1, flags=re.S)
s = s.replace('  <style id="splash-screen-style">', CSS + '  <style id="splash-screen-style">', 1)
s, n = re.subn(r'  <script id="splash-screen-script">.*?</script>', lambda _: SCRIPT, s, count=1, flags=re.S)
if n != 1:
    sys.exit("could not find the generated splash script block")
s = re.sub(r'\s*<div id="mythos-backdrop"></div>', '', s)
s = re.sub(r'\s*<p id="splash-tagline">.*?</p>', '', s, flags=re.S)
s = s.replace('  <picture id="splash">', '  <div id="mythos-backdrop"></div>\n  <picture id="splash">', 1)
# flutter_native_splash regenerates <picture> pointing at its own light-/dark-
# PNG exports. Swap in the WebP logo variants instead: the same art at roughly
# a tenth of the bytes (79KB vs 886KB at 3x, on a splash whose entire job is to
# appear fast), and a single dark logo rather than a light/dark pair, since the
# backdrop is now dark regardless of the visitor's colour-scheme preference.
s, n = re.subn(r'(  <picture id="splash">).*?(  </picture>)',
               lambda m: m.group(1) + "\n" + PICTURE_SOURCES + m.group(2),
               s, count=1, flags=re.S)
if n != 1:
    sys.exit("could not find the generated <picture id=\"splash\"> block")
s = s.replace('  </picture>',
    '  </picture>\n  <p id="splash-tagline">' + TAGLINE +
    '<span class="dots"><span>.</span><span>.</span><span>.</span></span></p>', 1)
# Re-add the beacon, replacing any existing copy so re-running is safe.
s = re.sub(r'  <!-- Arrival/exit beacon\..*?</script>\n', '', s, count=1, flags=re.S)
if '</head>' not in s:
    sys.exit("no </head> to anchor the visit beacon to")
s = s.replace('</head>', BEACON + '</head>', 1)

io.open(INDEX, "w", encoding="utf-8").write(s)
print(f"patched {INDEX}: backdrop {BACKDROP}, no dwell (lifts on first paint), visit beacon restored")
