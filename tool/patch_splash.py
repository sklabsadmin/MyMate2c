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

# Verbatim mirror of the block in web/index.html — regenerated, not
# hand-edited. Edit web/index.html first, then re-mirror here, or the
# next flutter_native_splash:create + re-patch silently reverts the
# index.html change. The old parameterised copy drifted exactly that
# way: it still carried the pre-visibility beacon and a splash script
# with no splash_cap_timeout marker.
CSS = r'''  <!-- Custom splash. Regenerated away by flutter_native_splash:create —
       re-apply with: python3 tool/patch_splash.py -->
  <style id="splash-extras">
    /* Same colour as AppTheme.backgroundColor, so the splash and the app it
       covers are literally the same surface — the logo lifts away instead of
       the whole screen changing colour under it. */
    #mythos-backdrop { position: fixed; inset: 0; background: #1A0520; z-index: 9998; }
    /* z-index must sit on the img: #splash is a <picture>, which is not
       positioned, so a z-index there does nothing. .center makes the img
       absolute. */
    /* No entrance animation. The logo was fading and rising over 900ms, which
       on a fast connection meant it was still animating in as the app became
       ready — the first thing a visitor saw was motion that then vanished. It
       is now simply present from the first frame. */
    /* The logo art has the backdrop colour baked into it (it is RGB, no
       alpha), so its square edges are invisible against #1A0520 — sampled at
       rgb(26,3,33), within a shade of AppTheme.backgroundColor. Capped so it
       reads as a logo rather than filling a large desktop window. */
    #splash img { z-index: 9999; width: min(62vw, 300px); height: auto; }
    /* Anchored to the logo, not the viewport bottom. The logo is vertically
       centred and square, so its lower edge sits at 50% + half its width;
       28px below that keeps the tagline visually attached to the mark instead
       of stranded near the bottom of a tall phone screen. */
    #splash-tagline {
      position: fixed; left: 50%; transform: translateX(-50%);
      top: calc(50% + min(31vw, 150px) + 28px);
      margin: 0; width: 92%; text-align: center; z-index: 9999;
      font-family: Georgia, "Times New Roman", serif;
      font-size: clamp(15px, 4.2vw, 19px); letter-spacing: .02em;
      /* Light enough to read on the dark backdrop; the old #6B4B7A was picked
         against cream and is near-invisible on #1A0520. */
      color: #C9B3D6;
    }
    #splash-tagline .dots span { opacity: 0; animation: mythos-dot 1.4s infinite; }
    #splash-tagline .dots span:nth-child(2) { animation-delay: .2s; }
    #splash-tagline .dots span:nth-child(3) { animation-delay: .4s; }
    @keyframes mythos-dot { 0%,60%,100% { opacity: 0; } 30% { opacity: 1; } }
    /* pointer-events:none so the app is usable the instant the fade starts.
       These sit at z-index 9999 over Flutter, so without it the first 420ms
       of every session silently swallowed taps on a screen that looks ready. */
    body.mythos-leaving #mythos-backdrop,
    body.mythos-leaving #splash,
    body.mythos-leaving #splash-tagline {
      transition: opacity 420ms ease; opacity: 0; pointer-events: none;
    }
    /* Only the loading dots animate now, so they are all this needs to stop. */
    @media (prefers-reduced-motion: reduce) {
      #splash-tagline .dots span { animation: none; opacity: 1; }
    }
    /* Direct character links: no splash, and the load gap is painted in the
       app's own background (AppTheme.backgroundColor) rather than the splash's
       peach. Without this the visitor gets a light flash then a dark chat,
       which reads as a glitch on exactly the journey we most want to feel
       seamless. The class is set in <head>, so this applies before first paint. */
    html.mythos-direct #mythos-backdrop,
    html.mythos-direct #splash,
    html.mythos-direct #splash-tagline { display: none; }
    html.mythos-direct, html.mythos-direct body { background: #1A0520; }
  </style>
'''

# Verbatim mirror of the block in web/index.html — regenerated, not
# hand-edited. Edit web/index.html first, then re-mirror here, or the
# next flutter_native_splash:create + re-patch silently reverts the
# index.html change. The old parameterised copy drifted exactly that
# way: it still carried the pre-visibility beacon and a splash script
# with no splash_cap_timeout marker.
SCRIPT = r'''  <script id="splash-screen-script">
    // Direct character links get no splash at all.
    //
    // Someone tapping /c/odysseus came for Odysseus, not for a logo — a brand
    // moment they did not ask for is pure friction on the one journey where
    // intent is already known. Runs here in <head>, before the body paints, so
    // the splash never appears rather than appearing and being torn down.
    //
    // Normal arrivals at / still get it: there the splash is doing real work,
    // covering a ~3MB bundle load that would otherwise be a blank page.
    if (location.pathname.indexOf("/c/") === 0) {
      document.documentElement.className += " mythos-direct";
    }

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
    function mythosDismissSplash() {
      document.body.classList.add("mythos-leaving");
      setTimeout(function () {
        var ids = ["mythos-backdrop", "splash", "splash-tagline", "splash-branding"];
        for (var i = 0; i < ids.length; i++) {
          var el = document.getElementById(ids[i]);
          if (el) el.remove();
        }
        document.body.style.background = "transparent";
      }, 420);
    }

    // Longest we will ever hold someone behind the splash waiting for
    // Flutter. Past this we drop it regardless — a stuck bundle should show
    // whatever the app managed rather than an indefinite logo.
    var MYTHOS_READY_CAP_MS = 15000;

    // Resolves when Flutter has actually put a frame on screen. Three
    // detectors, because no single one is reliable across Flutter versions:
    // the flutter-first-frame event, the view element appearing, and a hard
    // cap. First to fire wins; the rest become no-ops.
    function mythosOnFlutterReady(cb) {
      var fired = false, observer = null;
      // Whether the app actually painted, or we simply stopped waiting. The
      // beacon reports the same event either way, so without this an app_ready
      // at 15s is indistinguishable from an app that loaded in 15s — a failure
      // wearing a success's clothes, and one that drags every load average with
      // it. Two of 25 lost sessions on 10 Aug were this.
      function fire(timedOut) {
        if (fired) return;
        fired = true;
        try { if (observer) observer.disconnect(); } catch (e) {}
        cb(!!timedOut);
      }
      var sel = "flt-glass-pane, flutter-view, flt-scene-host";
      if (document.querySelector(sel)) return fire();
      // Wrapped, not passed directly: addEventListener hands the listener an
      // Event object, which as fire's first argument would read as timedOut
      // and mark every successful paint a timeout.
      window.addEventListener("flutter-first-frame", function () { fire(false); });
      try {
        observer = new MutationObserver(function () {
          if (document.querySelector(sel)) fire();
        });
        observer.observe(document.documentElement, { childList: true, subtree: true });
      } catch (e) {}
      setTimeout(function () { fire(true); }, MYTHOS_READY_CAP_MS);
    }

    document.addEventListener("DOMContentLoaded", function () {
      // Readiness is the only gate. The splash still covers the whole load —
      // it is dismissed by Flutter painting, not by a timer — so a slow
      // connection never gets dropped onto a blank page, which was the
      // original reason a dwell was introduced. It just no longer holds
      // anyone back once the app is actually there.
      mythosOnFlutterReady(function (timedOut) {
        // How long the visitor actually waited for a usable app — the number
        // that separates "left during load" from "saw the app and left".
        //
        // failureReason marks the ones where Flutter never painted and the cap
        // fired instead, so those can be excluded from load averages rather
        // than silently inflating them.
        try {
          if (window.mythosVisitBeacon) {
            window.mythosVisitBeacon(
              "app_ready", undefined, undefined,
              timedOut ? "splash_cap_timeout" : undefined);
          }
        } catch (e) {}
        mythosDismissSplash();
      });
    });

    function removeSplashFromWeb() {}
  </script>'''

# Verbatim mirror of the block in web/index.html — regenerated, not
# hand-edited. Edit web/index.html first, then re-mirror here, or the
# next flutter_native_splash:create + re-patch silently reverts the
# index.html change. The old parameterised copy drifted exactly that
# way: it still carried the pre-visibility beacon and a splash script
# with no splash_cap_timeout marker.
CHIME = r'''  <!-- Quick-reply chime.
       Three ascending notes as the quick-reply rows light up, then the chord
       they spell as the instruction flashes. Synthesised with oscillators
       rather than shipped as audio files: the build is already 52MB and 8% of
       Instagram arrivals give up before it finishes loading, so four notes are
       not worth a single kilobyte of payload.

       Lives here rather than in Dart for the same reason the beacon does, plus
       one of its own: unlocking audio has to happen inside a real user-gesture
       task, and that is far easier to guarantee from a plain DOM listener than
       from inside the Flutter engine's event dispatch.

       Silent on every failure. A chime must never be able to break a tap. -->
  <script>
  (function () {
    var ctx = null;

    // A major triad climbing, then the whole triad plus its octave as the
    // resolution — so the fourth sound is heard as the answer to the three
    // before it rather than as a fourth ding.
    var STEPS = [1046.50, 1318.51, 1567.98];
    var FINAL = [1046.50, 1318.51, 1567.98, 2093.00];

    function ensure() {
      if (ctx) return ctx;
      var AC = window.AudioContext || window.webkitAudioContext;
      if (!AC) return null;
      try { ctx = new AC(); } catch (e) { return null; }
      return ctx;
    }

    // Browsers refuse to play audio until the visitor has interacted with the
    // page, and on iOS the context must be resumed inside the gesture's own
    // task rather than any time after it. The character tap that opens the
    // chat is that gesture, and it lands well before the strip ever chimes.
    function unlock() {
      var c = ensure();
      if (c && c.state === 'suspended') { try { c.resume(); } catch (e) {} }
    }
    ['pointerdown', 'touchend', 'click'].forEach(function (name) {
      window.addEventListener(name, unlock, { capture: true, passive: true });
    });

    // Exponential ramps, never linear, and never to a true zero: gain of 0 is
    // undefined for exponentialRampToValueAtTime, and a linear cut to silence
    // clicks audibly at these frequencies.
    function voice(c, freq, at, peak, decay) {
      var osc = c.createOscillator();
      var gain = c.createGain();
      osc.type = 'sine';
      osc.frequency.value = freq;
      gain.gain.setValueAtTime(0.0001, at);
      gain.gain.exponentialRampToValueAtTime(peak, at + 0.008);
      gain.gain.exponentialRampToValueAtTime(0.0001, at + decay);
      osc.connect(gain);
      gain.connect(c.destination);
      osc.start(at);
      osc.stop(at + decay + 0.02);
    }

    // step 0-2 are the rows, 3 is the instruction.
    window.mythosChime = function (step) {
      try {
        var c = ensure();
        if (!c || c.state !== 'running') return;
        var at = c.currentTime;
        if (step === 3) {
          for (var i = 0; i < FINAL.length; i++) {
            voice(c, FINAL[i], at + i * 0.045, 0.085, 0.90);
          }
          return;
        }
        var f = STEPS[step];
        if (!f) return;
        voice(c, f, at, 0.12, 0.45);
      } catch (e) {
        // Deliberately swallowed.
      }
    };
  })();
  </script>
'''

# Verbatim mirror of the block in web/index.html — regenerated, not
# hand-edited. Edit web/index.html first, then re-mirror here, or the
# next flutter_native_splash:create + re-patch silently reverts the
# index.html change. The old parameterised copy drifted exactly that
# way: it still carried the pre-visibility beacon and a splash script
# with no splash_cap_timeout marker.
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
    // One id per page load. This script only runs on a real page load, never
    // on an in-app route change, so a plain variable gives exactly the
    // semantics migration 0004 describes: "a reload starts a new visit but an
    // in-page route change does not."
    //
    // It used to be read from sessionStorage first, which broke that — session
    // storage survives a reload, so a reload reused the id and wrote a SECOND
    // arrive and leave under it. The admin joins then multiplied those rows
    // together (2 arrives x 2 leaves = 4), inflating visit counts and skewing
    // every dwell and load average. sessionStorage was there so a browser-
    // retried beacon would not look like a second visitor, but it never
    // actually did that: each row is inserted with its own fresh UUID, so
    // nothing deduplicated on visit id anyway.
    var visitId = Date.now().toString(36) + Math.random().toString(36).slice(2, 10);

    // Read by the Flutter app so /api/chat requests can be tagged with the
    // visit they belong to (x-visit-id) — that join is what makes "how many
    // messages did this session send before quitting" answerable.
    window.mythosVisitId = visitId;

    // Which bundle this page load ran. tool/build_web.sh stamps the real
    // version over the placeholder after every release build; a dev serve or
    // a bare `flutter build web` leaves the token, and it is sent as nothing
    // rather than as a literal placeholder. It rides on EVERY event, not only
    // arrive, so a visit is versionable from any row it managed to write —
    // segmenting the entry rate across a deploy previously meant
    // reconstructing versions from delivery receipts, and most visits render
    // no bubble to receipt (docs/EVAL-2026-08-18-entry-rate-by-bundle.md).
    var APP_VERSION = '%MYTHOS_APP_VERSION%';
    if (APP_VERSION.indexOf('%') !== -1) APP_VERSION = '';

    // The visibility accumulator, above send() because every event now
    // reports the visible time at the moment it fired. That turns "how long
    // was the card actually watched" from an approximation (visible-at-leave
    // minus wall-clock-at-shown) into subtraction between two rows of the
    // same visit. hide and leave still pass their own settled figure, which
    // wins over this running one via Object.assign.
    var visibleMs = 0;
    var visibleSince = document.visibilityState === 'visible' ? Date.now() : null;
    var hiddenAt = null;
    var hideCount = 0;
    var left = false;
    // Chrome that shows and hides on scroll can flap visibility. The counter
    // keeps counting past this so the total stays true; only the rows stop.
    var MAX_VISIBILITY_EVENTS = 20;
    function currentVisibleMs() {
      return visibleMs + (visibleSince !== null ? Date.now() - visibleSince : 0);
    }

    // Did they ever touch the glass? A decliner who pressed or scrolled was
    // considering; one whose screen was never touched was never deciding —
    // and 234 decliners in one 45h window watched the card 5s+ with nothing
    // recorded to tell those apart. pointerdown covers mouse and touch alike
    // in every browser this traffic arrives in; the count rides every event,
    // so entry_shown carries touches-before-the-card and leave the total.
    var touchCount = 0;
    window.addEventListener('pointerdown', function () { touchCount++; }, { capture: true, passive: true });

    // Whether this device has been here before, one bit. Only engaged visits
    // carry a user id, so the return rate of the other ~98% has been
    // unknowable. localStorage on purpose: it lives exactly as long as the
    // stored chat history that makes a return visit behave differently.
    var IS_RETURN = 0;
    try {
      if (localStorage.getItem('mythos_seen')) IS_RETURN = 1;
      else localStorage.setItem('mythos_seen', String(Date.now()));
    } catch (e) {}

    // A/B plumbing, dormant until an experiment is named here. To run one:
    // set EXPERIMENT (e.g. 'card-copy-oct'), ship, and read the split on the
    // visits page. Each device draws an arm once and keeps it across visits;
    // every event then carries "name:arm". The app branches its UI on
    // window.mythosVariant. Dormant sends nothing, so no column fills with a
    // constant. At ~245 cards shown/day only bold variants are readable:
    // 1.5%->3% needs ~13 days with two arms, 1.5%->2% ~97.
    var EXPERIMENT = '';
    var VARIANT = '';
    try {
      if (EXPERIMENT) {
        var armKey = 'mythos_arm_' + EXPERIMENT;
        VARIANT = localStorage.getItem(armKey) || '';
        if (VARIANT !== 'a' && VARIANT !== 'b') {
          VARIANT = Math.random() < 0.5 ? 'a' : 'b';
          localStorage.setItem(armKey, VARIANT);
        }
        window.mythosVariant = EXPERIMENT + ':' + VARIANT;
      }
    } catch (e) {}

    function send(event, extra) {
      var body = JSON.stringify(Object.assign({
        visitId: visitId,
        event: event,
        path: location.pathname,
        query: location.search,
        referer: document.referrer || '',
        appVersion: APP_VERSION || undefined,
        visibleMs: currentVisibleMs(),
        touchCount: touchCount,
        isReturn: IS_RETURN,
        variant: EXPERIMENT && VARIANT ? EXPERIMENT + ':' + VARIANT : undefined
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
    window.mythosVisitBeacon = function (event, detail, appUserId, failureReason) {
      send(event, {
        durationMs: Date.now() - ARRIVED_AT,
        detail: detail || undefined,
        appUserId: appUserId || undefined,
        failureReason: failureReason || undefined
      });
    };

    // Viewport is only meaningful at arrival: it is what the visitor actually
    // saw, before any rotation or window resize.
    //
    // Height matters as much as width and for a sharper reason. The
    // quick-reply strip drops from three prompts to two below 720 logical
    // pixels (_shortScreenHeight in chat_screen.dart), and an in-app browser
    // spends a good part of a phone's height on its own chrome — so whether a
    // visitor was offered three options or two is decided here, and without
    // this we cannot tell which of them saw what.
    send('arrive', {
      viewportW: window.innerWidth || undefined,
      viewportH: window.innerHeight || undefined,
      // navigate / reload / back_forward. A reload is a fresh visit id and so
      // a second arrival for the same person, which is the inflation
      // docs/ANALYTICS_HANDOFF.md 4.1 describes; until now that could only be
      // inferred from timestamps sitting suspiciously close together.
      navType: (function () {
        try {
          var nav = performance.getEntriesByType('navigation')[0];
          return nav && nav.type ? nav.type : undefined;
        } catch (e) { return undefined; }
      })()
    });

    // How the visit ended, and how much of it they actually watched.
    //
    // "hidden" and "gone" are different things and used to be the same event.
    // leave() fired on the first visibilitychange as well as on pagehide, and
    // latched, so a visitor who backgrounded the app for a moment — or began
    // an interruptible swipe-to-dismiss on a Meta in-app browser sheet and
    // thought better of it — was recorded as having left at that instant and
    // never corrected. Measured on production data, 24 of 68 sessions kept
    // firing screen_ping ticks after their own "leave": one was recorded as a
    // 1.2s bounce while demonstrably still on the chat screen 28 seconds later.
    //
    // So visibility now accumulates rather than terminates:
    //   hide   each time the page is backgrounded, carrying the visible time
    //          so far. A checkpoint, not an ending — and the reason a session
    //          whose pagehide never arrives still reports something, which is
    //          how a third of the lost sessions currently vanish entirely.
    //   show   on return, carrying how long they were away. A hide/show pair a
    //          few hundred ms apart is an aborted swipe; forty seconds apart is
    //          an app switch they came back from.
    //   leave  on pagehide only — the page is genuinely going away.
    //
    // What cannot be captured, and is not guessed at anywhere below: which
    // control they used. The X button, the swipe and the system back gesture
    // are the host app's own chrome, and a webview is never told which one
    // dismissed it.
    function settleVisible() {
      if (visibleSince !== null) {
        visibleMs += Date.now() - visibleSince;
        visibleSince = null;
      }
    }

    function onHidden() {
      if (left || hiddenAt !== null) return;
      settleVisible();
      hiddenAt = Date.now();
      hideCount++;
      if (hideCount <= MAX_VISIBILITY_EVENTS) {
        // The running count rides along on every checkpoint, not only on
        // leave. A visit killed while backgrounded never sends a leave at all
        // — the population this whole change exists to see — and counting the
        // hide rows instead would stop at MAX_VISIBILITY_EVENTS and quietly
        // report a flapping visit as exactly 20 backgroundings.
        send('hide', {
          durationMs: Date.now() - ARRIVED_AT,
          visibleMs: visibleMs,
          hideCount: hideCount
        });
      }
    }

    function onVisible() {
      if (left) return;
      if (visibleSince === null) visibleSince = Date.now();
      if (hiddenAt !== null) {
        if (hideCount <= MAX_VISIBILITY_EVENTS) {
          send('show', { durationMs: Date.now() - hiddenAt });
        }
        hiddenAt = null;
      }
    }

    function leave(persisted) {
      if (left) return;
      left = true;
      // Read before settling: settleVisible() does not touch visibilityState,
      // but the order is the thing that decides whether this reads as ending
      // while on screen or ending after having been put away.
      var wasHidden = document.visibilityState === 'hidden';
      settleVisible();
      send('leave', {
        // Unchanged: wall-clock since arrival, so every historical dwell stays
        // comparable with every new one. visibleMs is the honest figure and is
        // reported alongside it rather than in place of it.
        durationMs: Date.now() - ARRIVED_AT,
        visibleMs: visibleMs,
        hideCount: hideCount,
        // bfcache means the page was frozen, not destroyed, and a back gesture
        // can bring this very visit back — which is why it is not "dismissed".
        exitMode: persisted ? 'bfcache' : (wasHidden ? 'hidden' : 'dismissed')
      });
    }

    window.addEventListener('pagehide', function (e) {
      leave(!!(e && e.persisted));
    });
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'hidden') onHidden();
      else onVisible();
    });
    // Restored from bfcache: the same visit is live again, so the terminal
    // guard is released and the clock restarts. Without this the returning
    // visitor would look like someone who left and never came back, which is
    // the population most worth being able to see.
    window.addEventListener('pageshow', function (e) {
      if (e && e.persisted) {
        left = false;
        hiddenAt = hiddenAt === null ? Date.now() : hiddenAt;
        onVisible();
      }
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
# Same again for the chime, for the same reason: a flutter_native_splash:create
# regenerates index.html from scratch and would otherwise drop it silently.
s = re.sub(r'  <!-- Quick-reply chime\..*?</script>\n', '', s, count=1, flags=re.S)
s = s.replace('</head>', CHIME + '</head>', 1)

io.open(INDEX, "w", encoding="utf-8").write(s)
print(f"patched {INDEX}: backdrop {BACKDROP}, no dwell (lifts on first paint), visit beacon + chime restored")
