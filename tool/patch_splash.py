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
  * a dwell measured from when the logo actually paints (the image is
    several hundred KB; timing from script-parse spent most of it blank)
  * 3s on a first visit, 1.5s after, tracked in localStorage
"""
import io, re, sys

INDEX = "web/index.html"
BACKDROP = "#FCECE5"      # sampled from the logo's own field colour
TAGLINE = "Connecting you with the ancient past"
FIRST_MS, RETURN_MS = 3000, 1500
READY_CAP_MS = 15000   # never hold anyone behind the splash longer than this

CSS = f'''  <!-- Custom splash. Regenerated away by flutter_native_splash:create —
       re-apply with: python3 tool/patch_splash.py -->
  <style id="splash-extras">
    #mythos-backdrop {{ position: fixed; inset: 0; background: {BACKDROP}; z-index: 9998; }}
    /* z-index must sit on the img: #splash is a <picture>, which is not
       positioned, so a z-index there does nothing. .center makes the img
       absolute. */
    #splash img {{ animation: mythos-rise 900ms ease-out both; z-index: 9999; }}
    @keyframes mythos-rise {{
      from {{ opacity: 0; transform: translate(-50%, -46%) scale(.96); }}
      to   {{ opacity: 1; transform: translate(-50%, -50%) scale(1); }}
    }}
    #splash-tagline {{
      position: fixed; left: 50%; transform: translateX(-50%);
      bottom: 11vh; margin: 0; width: 92%; text-align: center; z-index: 9999;
      font-family: Georgia, "Times New Roman", serif;
      font-size: clamp(15px, 4.2vw, 19px); letter-spacing: .02em;
      color: #6B4B7A; opacity: 0; animation: mythos-fade 900ms ease-out 600ms both;
    }}
    #splash-tagline .dots span {{ opacity: 0; animation: mythos-dot 1.4s infinite; }}
    #splash-tagline .dots span:nth-child(2) {{ animation-delay: .2s; }}
    #splash-tagline .dots span:nth-child(3) {{ animation-delay: .4s; }}
    @keyframes mythos-fade {{ to {{ opacity: 1; }} }}
    @keyframes mythos-dot {{ 0%,60%,100% {{ opacity: 0; }} 30% {{ opacity: 1; }} }}
    body.mythos-leaving #mythos-backdrop,
    body.mythos-leaving #splash,
    body.mythos-leaving #splash-tagline {{ transition: opacity 420ms ease; opacity: 0; }}
    @media (prefers-reduced-motion: reduce) {{
      #splash img, #splash-tagline, #splash-tagline .dots span {{ animation: none; opacity: 1; }}
    }}
  </style>
'''

SCRIPT = f'''  <script id="splash-screen-script">
    // The app never calls FlutterNativeSplash.remove(), so the generated
    // removeSplashFromWeb() never fires. We layer the splash above Flutter
    // and dismiss it ourselves.
    var MYTHOS_FIRST_RUN_MS = {FIRST_MS};
    var MYTHOS_RETURN_MS = {RETURN_MS};

    function mythosDwellMs() {{
      try {{
        var seen = window.localStorage.getItem("mythos_splash_seen");
        window.localStorage.setItem("mythos_splash_seen", "1");
        return seen ? MYTHOS_RETURN_MS : MYTHOS_FIRST_RUN_MS;
      }} catch (e) {{
        return MYTHOS_RETURN_MS;   // private mode: prefer the short dwell
      }}
    }}

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
      var img = document.querySelector("#splash img");
      var dwell = mythosDwellMs();

      // The splash now lifts on the LATER of two things: the dwell, and
      // Flutter actually being ready. It used to be the dwell alone, so on a
      // slow connection — the ~3.7MB critical path is ~7s on 4G — the logo
      // vanished at 3s and left the visitor on a blank page for seconds. That
      // reads as a dead site, and in the logs it is indistinguishable from
      // junk ad traffic.
      var dwellDone = false, ready = false;
      function maybeDismiss() {{ if (dwellDone && ready) mythosDismissSplash(); }}

      // Measured from when the logo paints, not when this parses.
      var start = function () {{
        setTimeout(function () {{ dwellDone = true; maybeDismiss(); }}, dwell);
      }};
      if (!img || img.complete) {{ start(); }}
      else {{
        img.addEventListener("load", start);
        img.addEventListener("error", start);
      }}

      mythosOnFlutterReady(function () {{
        ready = true;
        // How long the visitor actually waited for a usable app — the number
        // that separates "left during load" from "saw the app and left".
        try {{
          if (window.mythosVisitBeacon) window.mythosVisitBeacon("app_ready");
        }} catch (e) {{}}
        maybeDismiss();
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
s = s.replace('  </picture>',
    '  </picture>\n  <p id="splash-tagline">' + TAGLINE +
    '<span class="dots"><span>.</span><span>.</span><span>.</span></span></p>', 1)
# Re-add the beacon, replacing any existing copy so re-running is safe.
s = re.sub(r'  <!-- Arrival/exit beacon\..*?</script>\n', '', s, count=1, flags=re.S)
if '</head>' not in s:
    sys.exit("no </head> to anchor the visit beacon to")
s = s.replace('</head>', BEACON + '</head>', 1)

io.open(INDEX, "w", encoding="utf-8").write(s)
print(f"patched {INDEX}: backdrop {BACKDROP}, dwell {FIRST_MS}/{RETURN_MS}ms, visit beacon restored")
