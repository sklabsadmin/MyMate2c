/**
 * Cloudflare Worker for Secure AI Backend
 * 
 * Features:
 * 1. HMAC Signature Verification
 * 2. Rate Limiting (Token Bucket / Fixed Window)
 * 3. Input Validation
 * 4. Fixed Model Enforcement
 */

import { CHARACTER_STARTERS, DEFAULT_STARTERS, SHARED_TAPS } from "./starters.generated.js";

export default {
    async fetch(request, env, ctx) {
        const url = new URL(request.url);

        // Campaign deep links. Handled here rather than by the static asset
        // handler so the arrival is recorded and the character's Open Graph
        // tags are injected before any crawler sees the page.
        if (request.method === "GET" && url.pathname.startsWith("/c/")) {
            // index.html's icon/manifest hrefs are relative, resolved against
            // <base href="/">. Social crawlers routinely ignore <base> and
            // resolve them against the path instead, so previewing /c/zeus
            // fires off /c/favicon.png and /c/icons/Icon-192.png. Those used to
            // land in the referral log as characters named "favicon.png" and
            // "icons" — 5 of 75 arrivals in the last 7 days. Send them to the
            // real asset instead of logging a phantom campaign visit.
            const asset = assetPathUnderCampaignLink(url.pathname);
            if (asset) {
                return Response.redirect(new URL(asset, url.origin).toString(), 301);
            }
            return serveCharacterLanding(request, env, url, ctx);
        }

        if (request.method === "OPTIONS") {
            return new Response(null, { headers: corsHeaders(request) });
        }

        if (request.method === "GET" && url.pathname === "/auth/instagram/start") {
            return startInstagramAuth(request, env, url);
        }

        if (request.method === "GET" && url.pathname === "/auth/instagram/callback") {
            return finishInstagramAuth(request, env, url);
        }

        if (request.method === "GET" && url.pathname === "/auth/google/start") {
            return startGoogleAuth(request, env, url);
        }

        if (request.method === "GET" && url.pathname === "/auth/google/callback") {
            return finishGoogleAuth(request, env, url);
        }

        if (request.method === "GET" && url.pathname === "/auth/me") {
            const session = await getSessionFromRequest(request, env);
            return jsonResponse({
                authenticated: Boolean(session),
                user: session ? (
                    session.provider === "google"
                        ? { provider: "google", id: session.googleId, username: session.name || session.email, picture: session.picture || null }
                        : { provider: "instagram", id: session.instagramId, username: session.username }
                ) : null,
            }, { headers: corsHeaders(request) });
        }

        // The player's own profile. Identity comes from the signed session
        // cookie only — never from x-user-id, which is client-generated and
        // unverified, so honouring it here would let anyone read or overwrite
        // anyone else's profile.
        if (url.pathname === "/api/profile") {
            if (request.method === "GET") {
                return handleGetProfile(request, env);
            }
            if (request.method === "PUT") {
                return handlePutProfile(request, env);
            }
            return jsonResponse({ error: "Method not allowed" }, {
                status: 405,
                headers: corsHeaders(request),
            });
        }

        // Arrival/exit beacon from web/index.html. Deliberately unsigned: it
        // fires while the splash is still up, long before the Flutter bundle
        // (and therefore the HMAC code) has loaded — signing it would defeat
        // the entire point, which is counting people who never get that far.
        //
        // Nothing here is trusted. Country and colo come from Cloudflare, the
        // body is length-capped, and the worst a forged call can do is add a
        // row, which is the same thing a page reload does.
        if (request.method === "POST" && url.pathname === "/api/visit") {
            // Read the body BEFORE returning. ctx.waitUntil keeps the worker
            // alive but not the request stream, so a recorder that awaited
            // request.text() after the response had gone out silently got
            // nothing — every beacon returned 204 and wrote no row.
            const rawBody = await request.text();
            ctx.waitUntil(recordSiteVisit(rawBody, request, env).catch(() => {}));
            // 204 with no body: sendBeacon ignores the response, and this keeps
            // the request off the critical path for first paint.
            return new Response(null, { status: 204, headers: corsHeaders(request) });
        }

        if (request.method === "GET" && url.pathname === "/auth/logout") {
            // Redirect back to the origin the request came in on (workers.dev
            // or a custom domain) so the user stays on the domain they're using.
            // Land on the dedicated signed-out page rather than back in
            // Settings, which looked identical to the screen the user had just
            // been on and so never confirmed anything had happened.
            // Only honour an explicit return_to; otherwise land on the
            // signed-out page. safeReturnTo always yields a /settings URL when
            // given nothing, so it is only consulted when there is a value to
            // validate.
            const requested = url.searchParams.get("return_to");
            const after = requested
                ? safeReturnTo(requested, env, "signed_out=1", request)
                : `${url.origin}/signed-out`;
            return redirectResponse(after, [
                expiredCookie("mymate_session", request),
            ]);
        }

        // logs.<domain> exists only for the admin tools. A Workers custom
        // domain binds the entire hostname, so without this the full app would
        // be reachable there too — a second public entrance nobody intended.
        if (url.hostname.startsWith("logs.")) {
            if (!url.pathname.startsWith("/admin") && !url.pathname.startsWith("/api/admin")) {
                return Response.redirect(`${url.origin}/admin`, 302);
            }
        }

        if (request.method === "GET" && (url.pathname === "/admin" || url.pathname === "/admin/")) {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            return new Response(adminIndexPageHtml(), {
                headers: { "Content-Type": "text/html; charset=utf-8" },
            });
        }

        if (request.method === "GET" && url.pathname === "/admin/logs") {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            return new Response(adminLogsPageHtml(), {
                headers: { "Content-Type": "text/html; charset=utf-8" },
            });
        }

        if (request.method === "GET" && url.pathname === "/admin/referrals") {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            return new Response(adminReferralsPageHtml(), {
                headers: { "Content-Type": "text/html; charset=utf-8" },
            });
        }

        // Transcripts for one visit. Joined via app_user_id, which only the
        // in-app funnel events carry — a visit that never sent a message has
        // no id and therefore nothing to show, which is the correct answer
        // rather than an error.
        if (request.method === "GET" && url.pathname === "/api/admin/visit-chat") {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            const visitId = (url.searchParams.get("visit_id") || "").slice(0, 64);
            if (!visitId) return jsonResponse({ error: "visit_id required" }, { status: 400 });
            const db = env.CHAT_LOGS_DB;
            if (!db) return jsonResponse({ error: "No database bound" }, { status: 503 });

            // chat_id is the display name ("Odysseus (King of Ithaca)"); the
            // page renders character_id, so it is aliased here. It used to
            // select a bare character_id, which conversation_logs has never
            // had — that column only ever existed on referral_visits — so
            // every "view" link on the sessions and visits pages answered 500.
            // latency_ms rides along because this is where it is read: the
            // question migration 0007 added it for — "did a slow reply lose
            // this visitor" — is only answerable with the wait time sitting
            // next to the message that preceded them leaving.
            const COLUMNS = `created_at, chat_id AS character_id, scenario,
                             user_message, assistant_message, status, error,
                             latency_ms`;

            // Straight off the visit id, which conversation_logs has carried
            // since migration 0007. This endpoint predates that column, which
            // is why the fallback below exists at all.
            const direct = await db.prepare(`
                SELECT ${COLUMNS}
                FROM conversation_logs
                WHERE visit_id = ?
                ORDER BY created_at
            `).bind(visitId).all();

            const ids = await db.prepare(`
                SELECT DISTINCT app_user_id FROM site_visits
                WHERE visit_id = ? AND app_user_id IS NOT NULL
            `).bind(visitId).all();
            const userIds = (ids.results || []).map((r) => r.app_user_id);

            if ((direct.results || []).length || !userIds.length) {
                return jsonResponse({ userIds, messages: direct.results || [] });
            }

            // Pre-0007 rows have no visit_id, so they can only be found by user
            // plus the visit's time window — bounded so a returning device does
            // not drag in every conversation it has ever had.
            //
            // Only a fallback, because the two tables write created_at in
            // different formats: conversation_logs writes ISO-8601 ("...T09:00
            // :00.000Z") while datetime() here returns SQLite's space form, and
            // as strings "T" sorts above " ", so an ISO row is always greater
            // than the upper bound and silently drops out. Matching on visit_id
            // above is what avoids that comparison entirely.
            const window = await db.prepare(`
                SELECT MIN(created_at) AS started, MAX(created_at) AS ended
                FROM site_visits WHERE visit_id = ?
            `).bind(visitId).first();

            const placeholders = userIds.map(() => "?").join(",");
            const msgs = await db.prepare(`
                SELECT ${COLUMNS}
                FROM conversation_logs
                WHERE user_id IN (${placeholders})
                  AND visit_id IS NULL
                  AND created_at >= datetime(?, '-2 minutes')
                  AND created_at <= datetime(?, '+2 hours')
                ORDER BY created_at
            `).bind(...userIds, window.started, window.ended).all();

            return jsonResponse({ userIds, messages: msgs.results || [] });
        }

        if (request.method === "GET" && url.pathname === "/admin/visits") {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            return new Response(adminVisitsPageHtml(), {
                headers: { "Content-Type": "text/html; charset=utf-8" },
            });
        }

        if (request.method === "GET" && url.pathname === "/api/admin/visits") {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            const days = Math.min(Math.max(parseInt(url.searchParams.get("days") || "7", 10) || 7, 1), 90);
            const since = `-${days} days`;
            const db = env.CHAT_LOGS_DB;
            if (!db) return jsonResponse({ error: "No database bound" }, { status: 503 });

            // One row per visit: the arrival, plus the dwell time from its
            // matching leave. A visit with no leave row is someone who closed
            // the tab in a way the browser never reported — counted, but with
            // an unknown duration rather than a zero, which would drag the
            // averages down and hide the real bounce rate.
            //
            // The inner query collapses to one row per visit_id BEFORE any
            // counting happens, and reaches for the leave and app_ready rows
            // through aggregate subqueries rather than chained LEFT JOINs.
            // That is the whole point of it. A visit can hold several arrive
            // rows and several leave rows — sessionStorage survived a reload,
            // so a reload wrote another pair under the same id (see
            // docs/ANALYTICS_HANDOFF.md 4.1) — and joining those two sets
            // multiplies them: three arrives against three leaves is nine rows
            // for one visitor. On a fixture holding six visits, one of which
            // had reloaded twice, the joined form counted 32.
            //
            // `client` is which app actually rendered the page, read from the
            // user-agent. `source` cannot answer that: detectTrafficSource
            // returns utm_source before it ever looks at the user-agent, so a
            // bio link tagged ?utm_source=ig labels every arrival "ig" no
            // matter which in-app browser opened it — which is why the
            // Facebook in-app traffic that dominates this dataset reads as
            // Instagram. Derived at query time from a column already stored,
            // so it applies to rows going back to the start.
            const bySource = await db.prepare(`
                SELECT a.source AS source,
                       a.client AS client,
                       COUNT(*) AS visits,
                       SUM(CASE WHEN a.dwell_ms IS NOT NULL THEN 1 ELSE 0 END) AS with_duration,
                       SUM(CASE WHEN a.dwell_ms < 3000 THEN 1 ELSE 0 END) AS bounced_under_3s,
                       SUM(CASE WHEN a.saw_app THEN 1 ELSE 0 END) AS saw_app,
                       CAST(AVG(a.load_ms) AS INTEGER) AS avg_load_ms,
                       CAST(AVG(a.dwell_ms) AS INTEGER) AS avg_ms
                FROM (
                    SELECT v.visit_id,
                           MIN(v.source) AS source,
                           MIN(${visitClientSql("v")}) AS client,
                           ${visitDwellMsSql("v")} AS dwell_ms,
                           (SELECT MIN(r.duration_ms) FROM site_visits r
                             WHERE r.visit_id = v.visit_id AND r.event = 'app_ready') AS load_ms,
                           EXISTS (SELECT 1 FROM site_visits r
                                    WHERE r.visit_id = v.visit_id AND r.event = 'app_ready') AS saw_app
                    FROM site_visits v
                    WHERE v.event = 'arrive' AND v.created_at >= datetime('now', ?)
                    GROUP BY v.visit_id
                ) a
                GROUP BY a.source, a.client ORDER BY visits DESC
            `).bind(since).all();

            // DISTINCT visit_id, because a reload wrote a second arrive row
            // under the same id. Each day here links through to that day's
            // sessions, which group by visit_id — so counting arrive rows made
            // the number on this page disagree with the number of rows on the
            // page it opens, for exactly the days that had the most reloads.
            const byDay = await db.prepare(`
                SELECT date(created_at) AS day, COUNT(DISTINCT visit_id) AS visits
                FROM site_visits
                WHERE event = 'arrive' AND created_at >= datetime('now', ?)
                GROUP BY day ORDER BY day DESC
            `).bind(since).all();

            // One row per visit, same reason as bySource above: joined against
            // its leave and app_ready rows, a visit that had reloaded twice
            // listed 27 times and pushed genuinely distinct arrivals off the
            // bottom of the 200-row limit.
            const recent = await db.prepare(`
                SELECT a.visit_id,
                       MIN(a.created_at) AS created_at,
                       MIN(a.path) AS path, MIN(a.query) AS query,
                       MIN(a.source) AS source, MIN(a.utm_medium) AS utm_medium,
                       MIN(a.utm_campaign) AS utm_campaign, MIN(a.country) AS country,
                       MIN(a.referer) AS referer,
                       MIN(${visitClientSql("a")}) AS client,
                       ${visitDwellMsSql("a")} AS duration_ms,
                       (SELECT MIN(r.duration_ms) FROM site_visits r
                         WHERE r.visit_id = a.visit_id AND r.event = 'app_ready') AS load_ms,
                       (SELECT COUNT(*) FROM site_visits m
                         WHERE m.visit_id = a.visit_id
                           AND m.event IN ('first_message','login_gate')) AS messaged,
                       -- Ticks on the chat screen before engaging or giving up.
                       -- Present (possibly 0) whenever a character was opened;
                       -- NULL when one never was, which the UI shows as "—"
                       -- rather than 0 so a visit that never reached a
                       -- character isn't confused with one that reached it
                       -- and left instantly. A visit still mid-session with no
                       -- leave row yet shows its ticks-so-far here too — this
                       -- is the one column that updates for an open tab.
                       (SELECT COUNT(*) FROM site_visits g
                         WHERE g.visit_id = a.visit_id AND g.event = 'screen_ping') AS ticks,
                       EXISTS (SELECT 1 FROM site_visits t
                                WHERE t.visit_id = a.visit_id AND t.event = 'character_tap') AS opened_character
                FROM site_visits a
                WHERE a.event = 'arrive' AND a.created_at >= datetime('now', ?)
                GROUP BY a.visit_id
                ORDER BY created_at DESC LIMIT 200
            `).bind(since).all();

            // The funnel, per source. Each step counts DISTINCT visits that
            // reached it, so a chatty visitor sending 20 messages still counts
            // once and cannot inflate a step above the one before it.
            const funnel = await db.prepare(`
                SELECT a.source AS source,
                       COUNT(DISTINCT a.visit_id) AS arrived,
                       COUNT(DISTINCT CASE WHEN e.event='app_ready'     THEN e.visit_id END) AS loaded,
                       COUNT(DISTINCT CASE WHEN e.event='character_tap' THEN e.visit_id END) AS tapped,
                       COUNT(DISTINCT CASE WHEN e.event IN ('input_typed','starter_tap') THEN e.visit_id END) AS engaged,
                       COUNT(DISTINCT CASE WHEN e.event='first_message' THEN e.visit_id END) AS messaged,
                       COUNT(DISTINCT CASE WHEN e.event='login_gate'    THEN e.visit_id END) AS gated
                FROM site_visits a
                LEFT JOIN site_visits e ON e.visit_id = a.visit_id
                WHERE a.event='arrive' AND a.created_at >= datetime('now', ?)
                GROUP BY a.source ORDER BY arrived DESC
            `).bind(since).all();

            // detail is "<character>" on most events but "<character>#..." on
            // the ones that carry a position too (screen_ping's script turn and
            // strip set, strip_rotate's set index). Grouping on the raw column
            // would split one character into a row per distinct position and
            // bury the table in noise, so the character is taken as the part
            // before the first '#'. Rows written before those events carried a
            // suffix have no '#' and pass through unchanged.
            const characters = await db.prepare(`
                SELECT CASE WHEN instr(detail, '#') > 0
                            THEN substr(detail, 1, instr(detail, '#') - 1)
                            ELSE detail END AS character_id,
                       event, COUNT(*) AS n
                FROM site_visits
                WHERE detail IS NOT NULL AND created_at >= datetime('now', ?)
                GROUP BY character_id, event ORDER BY n DESC
            `).bind(since).all();

            // How long the "opened a character, never engaged" population
            // actually lingered before giving up — the question leave's
            // page-wide dwell cannot answer, because it does not isolate time
            // on the chat screen from time spent anywhere else on the visit.
            // screen_ping ticks every SCREEN_PING_INTERVAL_SECONDS, capped at
            // SCREEN_PING_MAX_SECONDS, only for
            // visits that reach character_tap and stops the instant any
            // engagement signal fires — so a visit's own tick count is a
            // direct, cheap proxy for elapsed seconds on the screen, with no
            // need for timestamp arithmetic. Bucketed rather than averaged: an
            // average of "left in 1s" and "stayed 30s" hides the fact that
            // those are two different visitors with two different problems.
            // Tick -> seconds boundaries, derived rather than written out, so
            // the buckets cannot drift from the client's tick rate the way they
            // did when the rate changed from 500ms to 2s and every threshold
            // below was left describing the old one: "stayed the full 30s"
            // needed 60 ticks, which a 2s tick can never reach, so that column
            // read 0 for everyone while genuinely-engaged visits were counted
            // as leaving in under 15 seconds.
            const b5s = screenPingTicksAt(5);
            const b15s = screenPingTicksAt(15);
            const bFull = SCREEN_PING_MAX_TICKS;
            //
            // The arrivals are collapsed to one row per visit_id before any
            // bucket is counted. Previously the total counted DISTINCT visits
            // while the buckets counted joined rows, so a visit that had
            // reloaded landed in its bucket once per arrive row: the buckets
            // did not add up to the total sitting beside them, and could
            // exceed it outright — "never engaged 3, left instantly 5" on a
            // fixture of three such visits. Both sides now count the same
            // thing, so the row reconciles by construction.
            const dwellBuckets = await db.prepare(`
                SELECT a.source AS source,
                       COUNT(*) AS never_engaged,
                       SUM(CASE WHEN a.ticks IS NULL OR a.ticks = 0 THEN 1 ELSE 0 END) AS left_instantly,
                       SUM(CASE WHEN a.ticks BETWEEN 1 AND ${b5s - 1} THEN 1 ELSE 0 END) AS left_under_5s,
                       SUM(CASE WHEN a.ticks BETWEEN ${b5s} AND ${b15s - 1} THEN 1 ELSE 0 END) AS left_5s_to_15s,
                       SUM(CASE WHEN a.ticks BETWEEN ${b15s} AND ${bFull - 1} THEN 1 ELSE 0 END) AS left_15s_to_30s,
                       SUM(CASE WHEN a.ticks >= ${bFull} THEN 1 ELSE 0 END) AS stayed_full_30s
                FROM (
                    SELECT v.visit_id,
                           MIN(v.source) AS source,
                           (SELECT COUNT(*) FROM site_visits p
                             WHERE p.visit_id = v.visit_id AND p.event = 'screen_ping') AS ticks
                    FROM site_visits v
                    WHERE v.event = 'arrive'
                      AND v.created_at >= datetime('now', ?)
                      AND EXISTS (
                          SELECT 1 FROM site_visits t
                          WHERE t.visit_id = v.visit_id AND t.event = 'character_tap'
                      )
                      AND NOT EXISTS (
                          SELECT 1 FROM site_visits e
                          WHERE e.visit_id = v.visit_id
                            AND e.event IN ('input_typed', 'starter_tap', 'first_message')
                      )
                    GROUP BY v.visit_id
                ) a
                GROUP BY a.source ORDER BY never_engaged DESC
            `).bind(since).all();

            return jsonResponse({
                bySource: bySource.results || [],
                byDay: byDay.results || [],
                recent: recent.results || [],
                funnel: funnel.results || [],
                characters: characters.results || [],
                dwellBuckets: dwellBuckets.results || [],
            });
        }

        if (request.method === "GET" && url.pathname === "/admin/first30") {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            return new Response(adminFirst30PageHtml(), {
                headers: { "Content-Type": "text/html; charset=utf-8" },
            });
        }

        // The first thirty seconds, at the resolution they were actually
        // recorded in.
        //
        // Every screen_ping is its own timestamped row, 500ms apart for the
        // first ten seconds and 3s apart to 28s. The dwell buckets on the
        // visits page reduce that to COUNT(*) and then to five columns, which
        // is where the detail goes: "left in 5-15s" covers eleven ticks and
        // two scripted questions. This returns the survival curve instead —
        // how many were still on screen at each tick — which is the same rows,
        // un-thrown-away, and works retroactively on everything already
        // logged.
        if (request.method === "GET" && url.pathname === "/api/admin/first30") {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            const db = env.CHAT_LOGS_DB;
            if (!db) return jsonResponse({ error: "No database bound" }, { status: 503 });

            const days = Math.min(
                Math.max(parseInt(url.searchParams.get("days") || "2", 10) || 2, 1), 90);
            // The developer's own country, excluded by default because the
            // opening brief's baselines were measured that way and a handful of
            // long local sessions visibly bend a curve this small.
            const exclude = (url.searchParams.get("exclude_country") ?? "TH").toUpperCase();
            const character = url.searchParams.get("character") || "";

            try {
                const rows = await db.prepare(`
                    WITH pings AS (
                        SELECT visit_id, COUNT(*) AS ticks
                        FROM site_visits
                        WHERE event = 'screen_ping'
                        GROUP BY visit_id
                    ),
                    opens AS (
                        SELECT a.source AS source,
                               COALESCE(p.ticks, 0) AS ticks,
                               (SELECT COUNT(*) FROM site_visits e
                                 WHERE e.visit_id = a.visit_id
                                   AND e.event IN ('input_typed','starter_tap','first_message')
                               ) > 0 AS engaged,
                               -- Measured, not inferred. The 'hide' rows are
                               -- real visibilitychange events, so a visit that
                               -- was backgrounded says so rather than being
                               -- guessed at from a tick span that ran longer
                               -- than its count should allow.
                               (SELECT COUNT(*) FROM site_visits h
                                 WHERE h.visit_id = a.visit_id
                                   AND h.event = 'hide') > 0 AS backgrounded
                        FROM site_visits a
                        LEFT JOIN pings p ON p.visit_id = a.visit_id
                        WHERE a.event = 'arrive'
                          AND a.created_at >= datetime('now', ?1)
                          AND (?2 = '' OR IFNULL(a.country,'') <> ?2)
                          AND EXISTS (
                              SELECT 1 FROM site_visits t
                               WHERE t.visit_id = a.visit_id
                                 AND t.event = 'character_tap'
                                 AND (?3 = '' OR t.detail = ?3))
                    )
                    SELECT source,
                           ticks,
                           COUNT(*) AS visits,
                           SUM(engaged) AS engaged,
                           SUM(backgrounded) AS paused
                    FROM opens
                    GROUP BY source, ticks
                    ORDER BY source, ticks
                `).bind(`-${days} days`, exclude, character).all();

                return jsonResponse(buildFirst30(rows.results || [], days, exclude, character));
            } catch (e) {
                return jsonResponse({ error: `Server error: ${e.message}` }, { status: 500 });
            }
        }

        if (request.method === "GET" && url.pathname === "/admin/sessions") {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            return new Response(adminSessionsPageHtml(), {
                headers: { "Content-Type": "text/html; charset=utf-8" },
            });
        }

        if (request.method === "GET" && url.pathname === "/api/admin/sessions") {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            const db = env.CHAT_LOGS_DB;
            if (!db) return jsonResponse({ error: "No database bound" }, { status: 503 });

            // Either a single UTC day (what the Visits "by day" table links to)
            // or a trailing window. The day form has to group on the same
            // date(created_at) that produced the count being drilled into, or
            // the two disagree and the page looks broken.
            const day = url.searchParams.get("day");
            const isDay = /^\d{4}-\d{2}-\d{2}$/.test(day || "");
            const days = Math.min(Math.max(parseInt(url.searchParams.get("days") || "7", 10) || 7, 1), 90);
            const where = isDay
                ? "date(a.created_at) = ?"
                : "a.created_at >= datetime('now', ?)";
            const param = isDay ? day : `-${days} days`;

            // Aggregate subqueries rather than joins, deliberately: a visit can
            // hold more than one leave row (see docs/ANALYTICS_HANDOFF.md 4.1),
            // and a chained LEFT JOIN multiplies the visit into several rows
            // instead of counting it once.
            //
            // Newest arrival first. That is what the page wants to open on —
            // "what just happened" — and it also decides which rows survive the
            // limit below, so a capped range keeps the most recent sessions
            // rather than the longest-dwelling ones. Any other order is one
            // click away in the browser.
            //
            // How many rows to load. Sorting on this page happens in the
            // browser, within what was loaded — so the row count is what
            // decides whether a sort ranks the whole range or just the top
            // slice of it, and it is the visitor's choice rather than a
            // constant. Whitelisted: the value is interpolated into the SQL
            // below, not bound.
            //
            // The CSV export ignores that choice and takes the lot. The limit
            // exists because sorting happens in the browser; a file opened in
            // a spreadsheet has no such constraint, and an export that
            // silently stopped at whatever the page had loaded would be the
            // exact half-truth the footnote warns about.
            const wantsCsv = url.searchParams.get("format") === "csv";
            const rawSessionLimit = parseInt(url.searchParams.get("limit"), 10);
            const SESSION_LIMIT = wantsCsv
                ? SESSION_EXPORT_LIMIT
                : [500, 1000, 5000].includes(rawSessionLimit)
                    ? rawSessionLimit
                    : 500;
            const sessions = await db.prepare(`
                SELECT a.visit_id,
                       MIN(a.created_at) AS created_at,
                       a.source, a.path, a.country, a.viewport_w, a.viewport_h,
                       (SELECT MIN(r.duration_ms) FROM site_visits r
                         WHERE r.visit_id = a.visit_id AND r.event = 'app_ready') AS load_ms,
                       ${visitDwellMsSql("a")} AS dwell_ms,
                       ${visitVisibleMsSql("a")} AS visible_ms,
                       (SELECT l.exit_mode FROM site_visits l
                         WHERE l.visit_id = a.visit_id AND l.event = 'leave'
                         ORDER BY l.created_at DESC LIMIT 1) AS exit_mode,
                       -- Whether the browser reported an ending at all, which
                       -- a NULL exit_mode cannot say on its own: a visit that
                       -- predates migration 0009 has a leave row and no mode,
                       -- and a visit killed outright has neither. Those are
                       -- different outcomes and the page has to tell them
                       -- apart rather than calling both "unknown".
                       EXISTS (SELECT 1 FROM site_visits l2
                                WHERE l2.visit_id = a.visit_id AND l2.event = 'leave') AS reported_leave,
                       ${visitHideCountSql("a")} AS hide_count,
                       (SELECT a2.nav_type FROM site_visits a2
                         WHERE a2.visit_id = a.visit_id AND a2.event = 'arrive'
                           AND a2.nav_type IS NOT NULL LIMIT 1) AS nav_type,
                       (SELECT COUNT(*) FROM site_visits g
                         WHERE g.visit_id = a.visit_id AND g.event = 'screen_ping') AS ticks,
                       (SELECT t.detail FROM site_visits t
                         WHERE t.visit_id = a.visit_id AND t.event = 'character_tap'
                         ORDER BY t.created_at LIMIT 1) AS character_id,
                       EXISTS (SELECT 1 FROM site_visits t
                                WHERE t.visit_id = a.visit_id AND t.event = 'character_tap') AS opened_character,
                       EXISTS (SELECT 1 FROM site_visits s
                                WHERE s.visit_id = a.visit_id AND s.event = 'starter_tap') AS tapped_starter,
                       (SELECT COUNT(*) FROM site_visits f
                         WHERE f.visit_id = a.visit_id AND f.event = 'send_failed') AS send_failed
                FROM site_visits a
                WHERE a.event = 'arrive' AND ${where}
                GROUP BY a.visit_id
                ORDER BY created_at DESC
                LIMIT ${SESSION_LIMIT + 1}
            `).bind(param).all();

            const rows = sessions.results || [];
            const truncated = rows.length > SESSION_LIMIT;
            if (truncated) rows.length = SESSION_LIMIT;

            // The headline counts, over the WHOLE window rather than the rows
            // that survived the limit above. Deliberately not derived in the
            // browser from `rows`: past 500 sessions that slice stops being the
            // window, and a summary that silently describes its own truncation
            // is worse than no summary at all.
            //
            // Every line counts visits, which is the only thing this table can
            // count — a visitor who never messages has no id to be recognised
            // by, so a person who taps the link twice is two arrivals and there
            // is no way to tell. The wording on the page has to say so.
            const totals = await db.prepare(`
                SELECT COUNT(*) AS arrivals,
                       SUM(CASE WHEN a.path LIKE '/c/%' THEN 1 ELSE 0 END) AS via_link,
                       SUM(CASE WHEN a.opened THEN 1 ELSE 0 END) AS opened,
                       SUM(CASE WHEN a.engaged THEN 1 ELSE 0 END) AS engaged,
                       SUM(CASE WHEN a.messaged THEN 1 ELSE 0 END) AS messaged
                FROM (
                    SELECT v.visit_id,
                           MIN(v.path) AS path,
                           EXISTS (SELECT 1 FROM site_visits t
                                    WHERE t.visit_id = v.visit_id
                                      AND t.event = 'character_tap') AS opened,
                           EXISTS (SELECT 1 FROM site_visits e
                                    WHERE e.visit_id = v.visit_id
                                      AND e.event IN ('input_typed', 'starter_tap', 'first_message')) AS engaged,
                           EXISTS (SELECT 1 FROM site_visits m
                                    WHERE m.visit_id = v.visit_id
                                      AND m.event = 'first_message') AS messaged
                    FROM site_visits v
                    WHERE v.event = 'arrive' AND ${where.replace(/\ba\./g, "v.")}
                    GROUP BY v.visit_id
                ) a
            `).bind(param).first();

            // Where the arrivals came from, geographically. Counted over the
            // whole window like the tally above rather than over the rows that
            // survived the limit — a country list assembled from the newest
            // 500 sessions would describe the last few hours of a boost, not
            // the range on the selector.
            //
            // One row per visit first, same as everywhere else on this page:
            // counting arrive rows would weight a visit that reloaded twice as
            // three visitors from that country.
            //
            // The code is what Cloudflare gives us (request.cf.country) and
            // the only thing stored; the full name is resolved in the browser,
            // where Intl already knows all of them.
            const countries = await db.prepare(`
                SELECT a.country AS country, COUNT(*) AS visits
                FROM (
                    SELECT v.visit_id, MIN(v.country) AS country
                    FROM site_visits v
                    WHERE v.event = 'arrive' AND ${where.replace(/\ba\./g, "v.")}
                    GROUP BY v.visit_id
                ) a
                GROUP BY a.country
                ORDER BY visits DESC, country ASC
            `).bind(param).all();

            // Messages for the same visits. conversation_logs.created_at is
            // ISO-8601 with a T and a Z while site_visits uses SQLite's own
            // format, so these are selected by visit rather than by their own
            // timestamp — comparing the two formats as strings goes wrong
            // inside a single day.
            const messages = await db.prepare(`
                SELECT c.visit_id, c.user_message, c.scenario, c.status, c.latency_ms
                FROM conversation_logs c
                WHERE c.visit_id IS NOT NULL
                  AND c.visit_id IN (
                      SELECT a.visit_id FROM site_visits a
                       WHERE a.event = 'arrive' AND ${where})
                ORDER BY c.created_at
            `).bind(param).all();

            const byVisit = new Map();
            for (const m of messages.results || []) {
                if (!byVisit.has(m.visit_id)) {
                    byVisit.set(m.visit_id, {
                        messages: 0, tapped: 0, typed: 0, failed: 0, slowest_reply_ms: null,
                    });
                }
                const agg = byVisit.get(m.visit_id);
                agg.messages += 1;
                // The worst wait, not the average: one 14s reply in a session
                // of four is what makes someone leave, and an average with
                // three fast replies in it hides exactly that. NULL stays NULL
                // — rows written before migration 0007 have no timing, and a
                // zero would read as an instant reply.
                if (Number.isFinite(m.latency_ms)) {
                    agg.slowest_reply_ms = Math.max(agg.slowest_reply_ms ?? 0, m.latency_ms);
                }
                // A successful row is status "completed"; everything else
                // ("ai_error", "rejected_validation", "rate_limited") is a
                // message the visitor sent and got nothing usable back from.
                if (m.status && m.status !== "completed") agg.failed += 1;
                if (isStarterText(m.user_message, characterIdFromScenario(m.scenario))) agg.tapped += 1;
                else agg.typed += 1;
            }

            const sessionRows = rows.map((r) => {
                const agg = byVisit.get(r.visit_id)
                    || { messages: 0, tapped: 0, typed: 0, failed: 0, slowest_reply_ms: null };
                return {
                    ...r,
                    ...agg,
                    // A tap recorded by the funnel that no message text
                    // matches means the starters moved on since this visit
                    // and backend/src/starters.generated.js is stale. Say
                    // so on the row rather than counting the tap as typed.
                    starter_unmatched: Boolean(r.tapped_starter) && agg.messages > 0 && agg.tapped === 0,
                };
            });

            if (wantsCsv) {
                const scope = isDay ? day : `last-${days}-days`;
                return new Response(sessionsCsv(sessionRows), {
                    headers: {
                        "Content-Type": "text/csv; charset=utf-8",
                        "Content-Disposition": `attachment; filename="mythos-sessions-${scope}.csv"`,
                        // Read by the page so it can say the file was capped.
                        // A CSV cannot carry that warning in its own body
                        // without becoming a CSV that lies about its columns.
                        "X-Sessions-Truncated": truncated ? "1" : "0",
                        "X-Sessions-Rows": String(sessionRows.length),
                    },
                });
            }

            return jsonResponse({
                day: isDay ? day : null,
                days: isDay ? null : days,
                truncated,
                limit: SESSION_LIMIT,
                totals,
                countries: countries.results || [],
                sessions: sessionRows,
            });
        }

        if (request.method === "GET" && url.pathname === "/api/admin/referrals") {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            try {
                return jsonResponse(await summariseReferralVisits(env, url.searchParams));
            } catch (e) {
                return jsonResponse({ error: `Server error: ${e.message}` }, { status: 500 });
            }
        }

        if (request.method === "GET" && url.pathname === "/api/admin/logs") {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            try {
                const result = await listConversationLogs(env, url.searchParams);
                return jsonResponse(result);
            } catch (e) {
                return jsonResponse({ error: `Server error: ${e.message}` }, { status: 500 });
            }
        }

        if (request.method === "GET" && /^\/api\/admin\/logs\/[^/]+$/.test(url.pathname)) {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            if (!env.CHAT_LOGS_DB) {
                return jsonResponse({ error: "CHAT_LOGS_DB is not configured" }, { status: 503 });
            }
            try {
                const id = decodeURIComponent(url.pathname.split("/").pop());
                const log = await getConversationLog(env, id);
                if (!log) {
                    return jsonResponse({ error: "Not found" }, { status: 404 });
                }
                return jsonResponse(log);
            } catch (e) {
                return jsonResponse({ error: `Server error: ${e.message}` }, { status: 500 });
            }
        }

        if (request.method === "GET" && url.pathname === "/api/admin/conversations") {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            try {
                const result = await listConversations(env, url.searchParams);
                return jsonResponse(result);
            } catch (e) {
                return jsonResponse({ error: `Server error: ${e.message}` }, { status: 500 });
            }
        }

        if (request.method === "GET" && url.pathname === "/api/admin/transcript") {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            try {
                const userId = url.searchParams.get("user_id");
                const chatId = url.searchParams.get("chat_id");
                if (!userId || !chatId) {
                    return jsonResponse({ error: "user_id and chat_id are required" }, { status: 400 });
                }
                const result = await getTranscript(env, userId, chatId);
                return jsonResponse(result);
            } catch (e) {
                return jsonResponse({ error: `Server error: ${e.message}` }, { status: 500 });
            }
        }

        // The other half of the log: a visit that opened a character and never
        // typed has no transcript to fetch, only a tick trail.
        if (request.method === "GET" && url.pathname === "/api/admin/visit-detail") {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            try {
                const visitId = url.searchParams.get("visit_id");
                if (!visitId) {
                    return jsonResponse({ error: "visit_id is required" }, { status: 400 });
                }
                const result = await getVisitDetail(env, visitId, url.searchParams.get("character"));
                return jsonResponse(result);
            } catch (e) {
                return jsonResponse({ error: `Server error: ${e.message}` }, { status: 500 });
            }
        }

        if (request.method === "GET" && url.pathname === "/api/admin/export") {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            try {
                const text = await buildExportText(env, url.searchParams);
                const stamp = new Date().toISOString().slice(0, 10);
                return new Response(text, {
                    headers: {
                        "Content-Type": "text/plain; charset=utf-8",
                        "Content-Disposition": `attachment; filename="mymate-chat-logs-${stamp}.txt"`,
                    },
                });
            } catch (e) {
                return jsonResponse({ error: `Server error: ${e.message}` }, { status: 500 });
            }
        }

        if (request.method === "GET" && url.pathname === "/admin/deploys") {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            return new Response(adminDeploysPageHtml(), {
                headers: { "Content-Type": "text/html; charset=utf-8" },
            });
        }

        if (url.pathname === "/api/admin/deploys") {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            const db = env.CHAT_LOGS_DB;
            if (!db) return jsonResponse({ error: "No database bound" }, { status: 503 });

            if (request.method === "GET") {
                try {
                    const rawLimit = parseInt(url.searchParams.get("limit"), 10);
                    const limit = Math.min(Math.max(Number.isFinite(rawLimit) ? rawLimit : 100, 1), 500);
                    // Ordered by when the deploy happened, not when the row was
                    // written: a deploy recorded the morning after still belongs
                    // in its own place on the timeline.
                    const { results } = await db.prepare(`
                        SELECT id, version, deployed_at, target, notes, created_at
                        FROM deploy_log
                        ORDER BY deployed_at DESC
                        LIMIT ?
                    `).bind(limit).all();
                    return jsonResponse({ deploys: results || [] });
                } catch (e) {
                    // Until migration 0010 is applied the table is simply not
                    // there. Say exactly that, with the fix, rather than
                    // reporting a server error the page cannot act on.
                    return jsonResponse({
                        error: `Could not read deploy_log: ${e.message}`,
                        hint: "Apply backend/migrations/0010_deploy_log.sql to this database.",
                    }, { status: 503 });
                }
            }

            if (request.method === "POST") {
                let body;
                try {
                    body = await request.json();
                } catch (_) {
                    return jsonResponse({ error: "Body must be JSON" }, { status: 400 });
                }

                const version = String(body.version || "").trim().slice(0, 60);
                if (!version) return jsonResponse({ error: "version is required" }, { status: 400 });

                // Accepts what a datetime-local input produces
                // ("2026-08-12T09:30") as well as a full timestamp, and stores
                // the one format every query on this database expects. Anything
                // else is refused rather than stored and left to sort wrongly
                // among rows that are well-formed.
                const deployedAt = normaliseDeployedAt(body.deployed_at);
                if (!deployedAt) {
                    return jsonResponse({
                        error: "deployed_at must look like 2026-08-12 09:30:00 (UTC)",
                    }, { status: 400 });
                }

                const TARGETS = ["app", "worker", "both"];
                const target = TARGETS.includes(body.target) ? body.target : null;
                const notes = String(body.notes || "").trim().slice(0, 500) || null;

                try {
                    const id = crypto.randomUUID();
                    await db.prepare(`
                        INSERT INTO deploy_log (id, version, deployed_at, target, notes)
                        VALUES (?, ?, ?, ?, ?)
                    `).bind(id, version, deployedAt, target, notes).run();
                    return jsonResponse({
                        deploy: { id, version, deployed_at: deployedAt, target, notes },
                    });
                } catch (e) {
                    return jsonResponse({
                        error: `Could not write deploy_log: ${e.message}`,
                        hint: "Apply backend/migrations/0010_deploy_log.sql to this database.",
                    }, { status: 503 });
                }
            }

            return jsonResponse({ error: "Method not allowed" }, { status: 405 });
        }

        // Everything logged in a window, raw, as one JSON file. The prose
        // export above is for reading; this is for keeping — a snapshot that
        // can be re-queried offline after D1 retention or a bad migration has
        // taken the original away.
        if (request.method === "GET" && url.pathname === "/api/admin/export-all") {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            try {
                const dump = await exportAllTables(env, url.searchParams);
                const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-");
                return new Response(JSON.stringify(dump, null, 2), {
                    headers: {
                        "Content-Type": "application/json; charset=utf-8",
                        "Content-Disposition":
                            `attachment; filename="mythos-all-${dump.window_hours}h-${stamp}.json"`,
                        "X-Export-Rows": String(dump.total_rows),
                        "X-Export-Truncated": dump.truncated ? "1" : "0",
                    },
                });
            } catch (e) {
                return jsonResponse({ error: `Server error: ${e.message}` }, { status: 500 });
            }
        }

        if (request.method !== "POST" || url.pathname !== "/api/chat") {
            return new Response("Method not allowed", {
                status: 405,
                headers: corsHeaders(request),
            });
        }

        try {
            // 1. HMAC Verification
            const signature = request.headers.get("x-signature");
            const timestamp = request.headers.get("x-timestamp");
            const session = await getSessionFromRequest(request, env);
            const userId = session
                ? (session.provider === "google" ? `google:${session.googleId}` : `instagram:${session.instagramId}`)
                : request.headers.get("x-user-id") || "anonymous";
            const requestId = crypto.randomUUID();
            const synthetic = isSyntheticTest(request);
            // Which browser visit this message belongs to. Absent on mobile
            // (no page load) and on any client predating the header.
            const visitId = (request.headers.get("x-visit-id") || "").slice(0, 64) || null;

            // Signature checking is on unless REQUIRE_SIGNATURE is explicitly
            // "false". It exists to stop strangers spending our OpenAI credits
            // through this endpoint, not to protect user data — so it can be
            // turned off pre-launch, but turn it back on before there are real
            // users. Client and worker must share the same APP_SECRET for it
            // to pass; a mismatch fails every request with "Invalid signature".
            const requireSignature = env.REQUIRE_SIGNATURE !== "false";

            if (requireSignature && (!signature || !timestamp)) {
                return new Response(JSON.stringify({ error: "Missing signature or timestamp" }), {
                    status: 401,
                    headers: jsonHeaders(request)
                });
            }

            // Check timestamp freshness (prevent replay attacks > 5 mins)
            if (requireSignature) {
                const now = Date.now();
                const reqTime = parseInt(timestamp, 10);
                if (Math.abs(now - reqTime) > 5 * 60 * 1000) {
                    return new Response(JSON.stringify({ error: "Request expired" }), {
                        status: 401,
                        headers: jsonHeaders(request)
                    });
                }
            }

            const bodyText = await request.text();

            if (requireSignature) {
                const verified = await verifySignature(env.APP_SECRET, bodyText, timestamp, signature);

                if (!verified) {
                    return new Response(JSON.stringify({ error: "Invalid signature" }), {
                        status: 401,
                        headers: jsonHeaders(request)
                    });
                }
            }

            // 2. Input Validation
            const body = JSON.parse(bodyText);
            const userMessage = body.messages ? body.messages[body.messages.length - 1].content : "";
            const bodyMetadata = body.metadata && typeof body.metadata === "object" ? body.metadata : {};
            const metadata = {
                chatId: request.headers.get("x-chat-id") || bodyMetadata.chatId,
                scenario: request.headers.get("x-scenario") || bodyMetadata.scenario,
                language: request.headers.get("x-language") || bodyMetadata.language,
                characterId: request.headers.get("x-character-id") || bodyMetadata.characterId,
            };
            const chatId = typeof metadata.chatId === "string" && metadata.chatId.trim()
                ? metadata.chatId.trim()
                : "default";
            // The client sends a characterId, but which engine handles it (openai vs
            // inworld) is decided here, server-side, from CHARACTER_ENGINES below —
            // never trust the client to pick its own pipeline/pricing tier.
            const inworldCharacter = getInworldCharacter(metadata.characterId);
            // Personas only apply to the direct-OpenAI path — Inworld
            // characters already carry their own, built from
            // INWORLD_CHARACTERS further down.
            const persona = inworldCharacter
                ? null
                : getCharacterPersona(metadata.characterId);
            const modelLabel = inworldCharacter
                ? `inworld:${inworldCharacter.id}+gpt-4o-mini-cleanup`
                : "gpt-4o-mini";

            const validationError = validateInput(userMessage, {
                skipContentBlocklist: Boolean(inworldCharacter),
            });
            if (validationError) {
                await persistConversationLog(env, {
                    id: requestId,
                    userId,
                    synthetic,
                    visitId,
                    chatId,
                    scenario: metadata.scenario,
                    language: metadata.language,
                    model: modelLabel,
                    status: "rejected_validation",
                    statusCode: 400,
                    userMessage,
                    assistantMessage: null,
                    requestMessages: body.messages,
                    responseBody: { error: validationError },
                    error: validationError,
                    clientTimestamp: timestamp,
                });

                return new Response(JSON.stringify({ error: validationError }), {
                    status: 400,
                    headers: jsonHeaders(request)
                });
            }

            // 3. Rate Limiting
            // Note: This requires a KV Namespace bound as 'RATE_LIMITER'
            // If not bound, we skip (or fail open for dev).
            if (env.RATE_LIMITER) {
                const allowed = await checkRateLimit(env.RATE_LIMITER, userId);
                if (!allowed) {
                    await persistConversationLog(env, {
                        id: requestId,
                        userId,
                        synthetic,
                        visitId,
                        chatId,
                        scenario: metadata.scenario,
                        language: metadata.language,
                        model: "gpt-4o-mini",
                        status: "rate_limited",
                        statusCode: 429,
                        userMessage,
                        assistantMessage: null,
                        requestMessages: body.messages,
                        responseBody: { error: "Rate limit exceeded" },
                        error: "Rate limit exceeded",
                        clientTimestamp: timestamp,
                    });

                    return new Response(JSON.stringify({ error: "Rate limit exceeded" }), {
                        status: 429,
                        headers: jsonHeaders(request)
                    });
                }
            }

            // 4. Generate the reply. Which engine handles this is decided purely by
            // metadata.characterId against CHARACTER_ENGINES (server-side config) —
            // everything above this point (auth, validation, rate limiting) is
            // identical for every character regardless of engine. modelLabel is
            // already computed above (needed by the validation/rate-limit log
            // entries too), so only the response itself varies by branch here.
            let responseData;
            let responseStatus;
            let responseOk;
            // Set on failure to the real, detailed error (which vendor, what
            // status) — used for the D1/admin log only. The client never
            // sees vendor names or technical detail; responseData.error
            // stays a generic, user-faceable message.
            let technicalError = null;
            // Wall-clock cost of the reply itself, which is what the user waits
            // through. Measured around the engine call only — auth, validation
            // and rate limiting are already done by here, so this is the number
            // to correlate against someone leaving mid-conversation.
            const replyStartedAt = Date.now();

            if (inworldCharacter) {
                // Inworld generates the in-character reply, then OpenAI does a
                // cleanup pass. Reshaped into the same {choices:[...]} envelope
                // OpenAI itself returns, so every line below (logging, response
                // shape) is shared with the plain-OpenAI path unchanged.
                try {
                    const cleanedText = await runInworldPipeline(env, inworldCharacter, body.messages, requestId);
                    responseData = { choices: [{ message: { role: "assistant", content: cleanedText } }] };
                    responseStatus = 200;
                    responseOk = true;
                } catch (e) {
                    technicalError = e.message || "Inworld pipeline failed";
                    responseData = { error: "AI response failed. Please try again." };
                    responseStatus = (e instanceof AIError) ? e.status : 502;
                    responseOk = false;
                }
            } else {
                // Proxy to OpenAI with Fixed Model. Enforce model: gpt-4o-mini
                const openAiBody = {
                    model: "gpt-4o-mini", // STRICT ENFORCEMENT
                    // A persona (if this character has one) replaces the
                    // client's generic system prompt; everyone else passes
                    // through untouched.
                    messages: persona
                        ? applyPersonaToMessages(body.messages, persona, metadata.language)
                        : body.messages,
                    temperature: 0.7,
                    max_tokens: parseInt(env.MAX_TOKENS || "300") // Use Env Var or default to 300
                };

                const openAiResponse = await fetch("https://api.openai.com/v1/chat/completions", {
                    method: "POST",
                    headers: {
                        "Content-Type": "application/json",
                        "Authorization": `Bearer ${env.OPENAI_API_KEY}`
                    },
                    body: JSON.stringify(openAiBody)
                });

                responseData = await openAiResponse.json();
                responseStatus = openAiResponse.status;
                responseOk = openAiResponse.ok;
            }

            const replyLatencyMs = Date.now() - replyStartedAt;

            // Pass back the response
            const assistantMessage = extractAssistantMessage(responseData);

            await persistConversationLog(env, {
                id: requestId,
                userId,
                synthetic,
                visitId,
                latencyMs: replyLatencyMs,
                chatId,
                scenario: metadata.scenario,
                language: metadata.language,
                model: modelLabel,
                status: responseOk ? "completed" : "ai_error",
                statusCode: responseStatus,
                userMessage,
                assistantMessage,
                requestMessages: body.messages,
                responseBody: responseData,
                error: responseOk ? null : (technicalError || extractErrorMessage(responseData)),
                clientTimestamp: timestamp,
            });

            return new Response(JSON.stringify(responseData), {
                status: responseStatus,
                headers: jsonHeaders(request)
            });

        } catch (e) {
            return new Response(`Server error: ${e.message}`, {
                status: 500,
                headers: corsHeaders(request),
            });
        }
    }
};

async function startInstagramAuth(request, env, url) {
    if (!env.INSTAGRAM_CLIENT_ID || !env.INSTAGRAM_CLIENT_SECRET) {
        return jsonResponse({ error: "Instagram auth is not configured" }, {
            status: 503,
            headers: corsHeaders(request),
        });
    }

    const state = crypto.randomUUID();
    const returnTo = safeReturnTo(url.searchParams.get("return_to"), env, "instagram=connected", request);
    const redirectUri = getInstagramRedirectUri(request, env);
    const authUrl = new URL(env.INSTAGRAM_AUTH_URL || "https://api.instagram.com/oauth/authorize");

    authUrl.searchParams.set("client_id", env.INSTAGRAM_CLIENT_ID);
    authUrl.searchParams.set("redirect_uri", redirectUri);
    authUrl.searchParams.set("scope", env.INSTAGRAM_SCOPE || "user_profile");
    authUrl.searchParams.set("response_type", "code");
    authUrl.searchParams.set("state", state);

    return redirectResponse(authUrl.toString(), [
        cookie("mymate_ig_state", `${state}|${returnTo}`, request, { maxAge: 600 }),
    ]);
}

async function finishInstagramAuth(request, env, url) {
    const state = url.searchParams.get("state");
    const code = url.searchParams.get("code");
    const stateCookie = getCookie(request, "mymate_ig_state");

    if (!state || !code || !stateCookie) {
        return redirectResponse(`${getAppOrigin(env)}/settings?instagram=failed`, [
            expiredCookie("mymate_ig_state", request),
        ]);
    }

    const [expectedState, returnTo] = stateCookie.split("|");
    if (state !== expectedState) {
        return redirectResponse(`${getAppOrigin(env)}/settings?instagram=failed`, [
            expiredCookie("mymate_ig_state", request),
        ]);
    }

    try {
        const redirectUri = getInstagramRedirectUri(request, env);
        const tokenResponse = await fetch(env.INSTAGRAM_TOKEN_URL || "https://api.instagram.com/oauth/access_token", {
            method: "POST",
            body: new URLSearchParams({
                client_id: env.INSTAGRAM_CLIENT_ID,
                client_secret: env.INSTAGRAM_CLIENT_SECRET,
                grant_type: "authorization_code",
                redirect_uri: redirectUri,
                code,
            }),
        });
        const tokenData = await tokenResponse.json();
        if (!tokenResponse.ok || !tokenData.access_token) {
            throw new Error("Instagram token exchange failed");
        }

        const profileUrl = new URL(env.INSTAGRAM_PROFILE_URL || "https://graph.instagram.com/me");
        profileUrl.searchParams.set("fields", env.INSTAGRAM_PROFILE_FIELDS || "id,username");
        profileUrl.searchParams.set("access_token", tokenData.access_token);

        const profileResponse = await fetch(profileUrl.toString());
        const profile = await profileResponse.json();
        if (!profileResponse.ok || !profile.id) {
            throw new Error("Instagram profile lookup failed");
        }

        const sessionValue = await signSession(env, {
            instagramId: profile.id,
            username: profile.username || null,
            exp: Math.floor(Date.now() / 1000) + 60 * 60 * 24 * 30,
        });

        return redirectResponse(returnTo || `${getAppOrigin(env)}/settings?instagram=connected`, [
            expiredCookie("mymate_ig_state", request),
            cookie("mymate_session", sessionValue, request, { maxAge: 60 * 60 * 24 * 30 }),
        ]);
    } catch (error) {
        console.error(JSON.stringify({ event: "instagram_auth_failed", error: error.message }));
        return redirectResponse(`${getAppOrigin(env)}/settings?instagram=failed`, [
            expiredCookie("mymate_ig_state", request),
        ]);
    }
}

async function startGoogleAuth(request, env, url) {
    if (!env.GOOGLE_CLIENT_ID || !env.GOOGLE_CLIENT_SECRET) {
        return jsonResponse({ error: "Google auth is not configured" }, {
            status: 503,
            headers: corsHeaders(request),
        });
    }

    const state = crypto.randomUUID();
    const returnTo = safeReturnTo(url.searchParams.get("return_to"), env, "google=connected", request);
    // The client's pre-login anonymous user id (see x-user-id on /api/chat),
    // so we can merge their existing chat history onto the linked account.
    const anonId = (url.searchParams.get("anon_id") || "").replace(/\|/g, "");
    const redirectUri = getGoogleRedirectUri(request, env);
    const authUrl = new URL("https://accounts.google.com/o/oauth2/v2/auth");

    authUrl.searchParams.set("client_id", env.GOOGLE_CLIENT_ID);
    authUrl.searchParams.set("redirect_uri", redirectUri);
    authUrl.searchParams.set("scope", "openid email profile");
    authUrl.searchParams.set("response_type", "code");
    authUrl.searchParams.set("access_type", "online");
    authUrl.searchParams.set("state", state);

    return redirectResponse(authUrl.toString(), [
        cookie("mymate_google_state", `${state}|${returnTo}|${anonId}`, request, { maxAge: 600 }),
    ]);
}

async function finishGoogleAuth(request, env, url) {
    const state = url.searchParams.get("state");
    const code = url.searchParams.get("code");
    const stateCookie = getCookie(request, "mymate_google_state");

    if (!state || !code || !stateCookie) {
        return redirectResponse(`${getAppOrigin(env)}/settings?google=failed`, [
            expiredCookie("mymate_google_state", request),
        ]);
    }

    const [expectedState, returnTo, anonId] = stateCookie.split("|");
    if (state !== expectedState) {
        return redirectResponse(`${getAppOrigin(env)}/settings?google=failed`, [
            expiredCookie("mymate_google_state", request),
        ]);
    }

    try {
        const redirectUri = getGoogleRedirectUri(request, env);
        const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
            method: "POST",
            headers: { "Content-Type": "application/x-www-form-urlencoded" },
            body: new URLSearchParams({
                client_id: env.GOOGLE_CLIENT_ID,
                client_secret: env.GOOGLE_CLIENT_SECRET,
                grant_type: "authorization_code",
                redirect_uri: redirectUri,
                code,
            }),
        });
        const tokenData = await tokenResponse.json();
        if (!tokenResponse.ok || !tokenData.access_token) {
            throw new Error("Google token exchange failed");
        }

        const profileResponse = await fetch("https://www.googleapis.com/oauth2/v3/userinfo", {
            headers: { Authorization: `Bearer ${tokenData.access_token}` },
        });
        const profile = await profileResponse.json();
        if (!profileResponse.ok || !profile.sub) {
            throw new Error("Google profile lookup failed");
        }

        const sessionValue = await signSession(env, {
            provider: "google",
            googleId: profile.sub,
            email: profile.email || null,
            name: profile.name || null,
            // Google's avatar URL, so the app can show the account's own icon
            // instead of a generic placeholder once linked.
            picture: profile.picture || null,
            exp: Math.floor(Date.now() / 1000) + 60 * 60 * 24 * 30,
        });

        await recordLinkedAccount(env, {
            userId: `google:${profile.sub}`,
            provider: "google",
            providerId: profile.sub,
            email: profile.email || null,
            displayName: profile.name || null,
            anonId: anonId || null,
        });

        return redirectResponse(returnTo || `${getAppOrigin(env)}/settings?google=connected`, [
            expiredCookie("mymate_google_state", request),
            cookie("mymate_session", sessionValue, request, { maxAge: 60 * 60 * 24 * 30 }),
        ]);
    } catch (error) {
        console.error(JSON.stringify({ event: "google_auth_failed", error: error.message }));
        return redirectResponse(`${getAppOrigin(env)}/settings?google=failed`, [
            expiredCookie("mymate_google_state", request),
        ]);
    }
}

// Records that userId is now linked to (provider, providerId), and - if this
// is the first time this account has linked and an anonId was supplied -
// reattributes that anonymous user's existing conversation_logs rows to the
// linked account so their prior history carries over. Never throws: a DB
// hiccup here shouldn't fail an otherwise-successful login.
async function recordLinkedAccount(env, { userId, provider, providerId, email, displayName, anonId }) {
    if (!env.CHAT_LOGS_DB) return;

    try {
        const existing = await env.CHAT_LOGS_DB.prepare(
            `SELECT merged_anon_id FROM linked_accounts WHERE provider = ? AND provider_id = ?`
        ).bind(provider, providerId).first();

        await env.CHAT_LOGS_DB.prepare(`
            INSERT INTO linked_accounts (
                id, user_id, provider, provider_id, email, display_name, merged_anon_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(provider, provider_id) DO UPDATE SET
                linked_at = CURRENT_TIMESTAMP,
                email = excluded.email,
                display_name = excluded.display_name
        `).bind(
            crypto.randomUUID(), userId, provider, providerId, email, displayName,
            existing ? existing.merged_anon_id : (anonId || null)
        ).run();

        // Only merge once per account, and only if there's actually an
        // anonymous id to merge from (skip if already merged before).
        if (anonId && anonId !== userId && !existing?.merged_anon_id) {
            await env.CHAT_LOGS_DB.prepare(
                `UPDATE conversation_logs SET user_id = ? WHERE user_id = ?`
            ).bind(userId, anonId).run();
        }
    } catch (error) {
        console.error(JSON.stringify({ event: "record_linked_account_failed", error: error.message }));
    }
}

function corsHeaders(request) {
    const origin = request.headers.get("Origin") || "*";
    return {
        "Access-Control-Allow-Origin": origin,
        "Access-Control-Allow-Credentials": "true",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        // x-synthetic-test belongs here even though the app never sends it:
        // without it a browser-driven verification call cannot send the header
        // at all (preflight rejects it), so the tester drops the header to make
        // the request work and their traffic lands in the analytics tables —
        // which is how a "browsertest" user id got into conversation_logs.
        "Access-Control-Allow-Headers": "Content-Type, x-signature, x-timestamp, x-user-id, x-chat-id, x-scenario, x-language, x-character-id, x-visit-id, x-synthetic-test",
        "Vary": "Origin",
    };
}

function jsonHeaders(request) {
    return {
        ...corsHeaders(request),
        "Content-Type": "application/json",
    };
}

function jsonResponse(data, init = {}) {
    return new Response(JSON.stringify(data), {
        ...init,
        headers: {
            "Content-Type": "application/json",
            ...(init.headers || {}),
        },
    });
}

function redirectResponse(location, cookies = []) {
    const headers = new Headers({ Location: location });
    for (const value of cookies) {
        headers.append("Set-Cookie", value);
    }
    return new Response(null, { status: 302, headers });
}

function getInstagramRedirectUri(request, env) {
    if (env.INSTAGRAM_REDIRECT_URI) return env.INSTAGRAM_REDIRECT_URI;
    const url = new URL(request.url);
    return `${url.origin}/auth/instagram/callback`;
}

function getGoogleRedirectUri(request, env) {
    if (env.GOOGLE_REDIRECT_URI) return env.GOOGLE_REDIRECT_URI;
    const url = new URL(request.url);
    return `${url.origin}/auth/google/callback`;
}

function getAppOrigin(env) {
    return (env.APP_ORIGIN || "http://localhost:8787").replace(/\/$/, "");
}

function safeReturnTo(value, env, fallbackQuery = "instagram=connected", request = null) {
    // The worker is reachable on more than one origin (the workers.dev URL
    // and any custom domains, e.g. chat.deeploveechoes.com) - allow whichever
    // one the request actually came in on, in addition to APP_ORIGIN, so
    // users stay on the domain they started on after auth completes.
    const allowedOrigins = new Set([getAppOrigin(env)]);
    if (request) {
        try {
            allowedOrigins.add(new URL(request.url).origin);
        } catch (_) {}
    }
    const fallback = `${request ? new URL(request.url).origin : getAppOrigin(env)}/settings?${fallbackQuery}`;
    if (!value) return fallback;
    try {
        const url = new URL(value);
        if (allowedOrigins.has(url.origin)) return url.toString();
    } catch (_) {}
    return fallback;
}

function cookie(name, value, request, options = {}) {
    const isHttps = new URL(request.url).protocol === "https:";
    const secure = isHttps ? "; Secure" : "";
    const sameSite = isHttps ? "None" : "Lax";
    const maxAge = options.maxAge ? `; Max-Age=${options.maxAge}` : "";
    return `${name}=${encodeURIComponent(value)}; Path=/; HttpOnly; SameSite=${sameSite}${secure}${maxAge}`;
}

function expiredCookie(name, request) {
    const isHttps = new URL(request.url).protocol === "https:";
    const secure = isHttps ? "; Secure" : "";
    const sameSite = isHttps ? "None" : "Lax";
    return `${name}=; Path=/; HttpOnly; SameSite=${sameSite}${secure}; Max-Age=0`;
}

function getCookie(request, name) {
    const cookieHeader = request.headers.get("Cookie") || "";
    for (const part of cookieHeader.split(";")) {
        const [key, ...valueParts] = part.trim().split("=");
        if (key === name) return decodeURIComponent(valueParts.join("="));
    }
    return null;
}

/**
 * Resolves the signed session into the identity a profile row is keyed by.
 *
 * Returns null for anonymous users and for Instagram sessions: only Google
 * gives the stable, cross-device identifier this table depends on. userId is
 * composed exactly as recordLinkedAccount composes it, so user_profiles and
 * linked_accounts join on the same value.
 */
async function getProfileIdentity(request, env) {
    const session = await getSessionFromRequest(request, env);
    if (!session || session.provider !== "google" || !session.googleId) return null;
    return {
        userId: `google:${session.googleId}`,
        provider: "google",
        providerId: session.googleId,
    };
}

const PROFILE_FIELDS = [
    ["name", "name"],
    ["age", "age"],
    ["gender", "gender"],
    ["pronouns", "pronouns"],
    ["location", "location"],
    ["turnOns", "turn_ons"],
    ["hobbies", "hobbies"],
    ["avatarEmoji", "avatar_emoji"],
    ["avatarPhoto", "avatar_photo"],
];

async function handleGetProfile(request, env) {
    const identity = await getProfileIdentity(request, env);
    if (!identity) {
        return jsonResponse({ error: "Sign in required" }, {
            status: 401,
            headers: corsHeaders(request),
        });
    }
    if (!env.CHAT_LOGS_DB) {
        return jsonResponse({ error: "Profile storage is not configured" }, {
            status: 503,
            headers: corsHeaders(request),
        });
    }

    const row = await env.CHAT_LOGS_DB
        .prepare("SELECT * FROM user_profiles WHERE user_id = ?")
        .bind(identity.userId)
        .first();

    if (!row) {
        return jsonResponse({ profile: null }, { headers: corsHeaders(request) });
    }

    const profile = {};
    for (const [jsonKey, column] of PROFILE_FIELDS) {
        profile[jsonKey] = row[column] || "";
    }
    return jsonResponse({ profile, updatedAt: row.updated_at }, {
        headers: corsHeaders(request),
    });
}

async function handlePutProfile(request, env) {
    const identity = await getProfileIdentity(request, env);
    if (!identity) {
        return jsonResponse({ error: "Sign in required" }, {
            status: 401,
            headers: corsHeaders(request),
        });
    }
    if (!env.CHAT_LOGS_DB) {
        return jsonResponse({ error: "Profile storage is not configured" }, {
            status: 503,
            headers: corsHeaders(request),
        });
    }

    let body;
    try {
        body = await request.json();
    } catch (_) {
        return jsonResponse({ error: "Invalid JSON" }, {
            status: 400,
            headers: corsHeaders(request),
        });
    }

    const incoming = body && typeof body.profile === "object" && body.profile
        ? body.profile
        : body;
    if (!incoming || typeof incoming !== "object") {
        return jsonResponse({ error: "Missing profile" }, {
            status: 400,
            headers: corsHeaders(request),
        });
    }

    // Cap each field. Free text straight from a form, and avatar_photo is a
    // base64 image — without a ceiling one oversized upload could bloat a row
    // far past anything the UI can produce.
    const limitFor = (jsonKey) => (jsonKey === "avatarPhoto" ? 400_000 : 2_000);
    const values = PROFILE_FIELDS.map(([jsonKey]) => {
        const raw = incoming[jsonKey];
        if (typeof raw !== "string") return "";
        return raw.slice(0, limitFor(jsonKey));
    });

    const columns = PROFILE_FIELDS.map(([, column]) => column);
    await env.CHAT_LOGS_DB.prepare(`
        INSERT INTO user_profiles (
            user_id, provider, provider_id, updated_at, ${columns.join(", ")}
        ) VALUES (?, ?, ?, CURRENT_TIMESTAMP, ${columns.map(() => "?").join(", ")})
        ON CONFLICT(user_id) DO UPDATE SET
            updated_at = CURRENT_TIMESTAMP,
            ${columns.map((c) => `${c} = excluded.${c}`).join(",\n            ")}
    `)
        .bind(identity.userId, identity.provider, identity.providerId, ...values)
        .run();

    return jsonResponse({ ok: true }, { headers: corsHeaders(request) });
}

async function getSessionFromRequest(request, env) {
    const value = getCookie(request, "mymate_session");
    if (!value) return null;
    return verifySession(env, value);
}

async function signSession(env, payload) {
    const encodedPayload = base64UrlEncode(JSON.stringify(payload));
    const signature = await signHmacHex(env.SESSION_SECRET || env.APP_SECRET, encodedPayload);
    return `${encodedPayload}.${signature}`;
}

async function verifySession(env, value) {
    const [encodedPayload, signature] = value.split(".");
    if (!encodedPayload || !signature) return null;
    const verified = await verifyHmacHex(env.SESSION_SECRET || env.APP_SECRET, encodedPayload, signature);
    if (!verified) return null;

    try {
        const payload = JSON.parse(base64UrlDecode(encodedPayload));
        if (!payload.exp || payload.exp < Math.floor(Date.now() / 1000)) return null;
        return payload;
    } catch (_) {
        return null;
    }
}

function base64UrlEncode(value) {
    const bytes = new TextEncoder().encode(value);
    let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function base64UrlDecode(value) {
    const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return new TextDecoder().decode(bytes);
}

/// Writes the row, but never lets failing to write one cost the visitor their
/// reply.
///
/// The three call sites in the chat handler await this inside the try whose
/// catch returns a 500, so anything thrown here is returned to the client as a
/// server error. That meant an unavailable, over-quota or rate-limited D1 could
/// turn a perfectly good AI reply into "<character> is having trouble thinking
/// right now" — the identical message a real backend outage produces, from a
/// cause that has nothing to do with the conversation. Analytics must not be
/// able to take the product down.
///
/// REQUIRE_CHAT_LOGS is the deliberate opt-out: it exists so an operator can
/// say "a lost row is worse than a failed request". When it is "true" the
/// failure is rethrown and the 500 happens as before.
async function persistConversationLog(env, entry) {
    try {
        await writeConversationLogRow(env, entry);
    } catch (e) {
        console.error(JSON.stringify({
            event: "chat_log_failed",
            requestId: entry.id,
            error: e && e.message ? e.message : String(e),
        }));
        if (env.REQUIRE_CHAT_LOGS === "true") throw e;
    }
}

async function writeConversationLogRow(env, entry) {
    if (entry.synthetic) return;

    // The header above is opt-in, and every ad-hoc verification call that
    // forgot it wrote a row: 57 of them across 2026-08-03..05 under invented
    // ids (check_zeus, fin_calypso, oedbug, migration-check, healthcheck,
    // browsertest, ...), which is why 2026-08-03 reads as 33 messages from 33
    // "users" when 6 of those ids were real people. Remembering a header is not
    // something a report's accuracy should depend on, so the id shape decides
    // too: no recognised shape, no row.
    //
    // Deliberately not rethrown under REQUIRE_CHAT_LOGS — this is a row we
    // chose not to keep, not a write that failed.
    if (!isRealUserId(entry.userId)) {
        console.error(JSON.stringify({
            event: "chat_log_skipped",
            reason: "unrecognised_user_id",
            userId: entry.userId,
            requestId: entry.id,
        }));
        return;
    }

    if (!env.CHAT_LOGS_DB) {
        if (env.REQUIRE_CHAT_LOGS === "true") {
            throw new Error("CHAT_LOGS_DB binding is required when REQUIRE_CHAT_LOGS=true");
        }
        console.error(JSON.stringify({
            event: "chat_log_skipped",
            reason: "missing_CHAT_LOGS_DB",
            requestId: entry.id,
        }));
        return;
    }

    const responseBody = entry.responseBody ? JSON.stringify(entry.responseBody) : null;
    const requestMessages = Array.isArray(entry.requestMessages)
        ? JSON.stringify(entry.requestMessages)
        : "[]";
    const usage = entry.responseBody && entry.responseBody.usage ? entry.responseBody.usage : {};

    await env.CHAT_LOGS_DB.prepare(`
        INSERT INTO conversation_logs (
            id,
            created_at,
            user_id,
            chat_id,
            scenario,
            language,
            model,
            status,
            status_code,
            user_message,
            assistant_message,
            request_messages_json,
            response_json,
            error,
            prompt_tokens,
            completion_tokens,
            total_tokens,
            client_timestamp,
            visit_id,
            latency_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).bind(
        entry.id,
        new Date().toISOString(),
        entry.userId,
        entry.chatId,
        stringOrNull(entry.scenario),
        stringOrNull(entry.language),
        entry.model,
        entry.status,
        entry.statusCode,
        entry.userMessage || "",
        entry.assistantMessage,
        requestMessages,
        responseBody,
        entry.error,
        numberOrNull(usage.prompt_tokens),
        numberOrNull(usage.completion_tokens),
        numberOrNull(usage.total_tokens),
        entry.clientTimestamp,
        stringOrNull(entry.visitId),
        numberOrNull(entry.latencyMs)
    ).run();
}

function extractAssistantMessage(responseData) {
    const choices = responseData && Array.isArray(responseData.choices) ? responseData.choices : [];
    const first = choices[0];
    if (!first || !first.message || typeof first.message.content !== "string") {
        return null;
    }
    return first.message.content;
}

function extractErrorMessage(responseData) {
    if (responseData && responseData.error) {
        if (typeof responseData.error === "string") return responseData.error;
        if (typeof responseData.error.message === "string") return responseData.error.message;
        return JSON.stringify(responseData.error);
    }
    return "OpenAI request failed";
}

function stringOrNull(value) {
    return typeof value === "string" ? value : null;
}

function numberOrNull(value) {
    return typeof value === "number" ? value : null;
}

/**
 * Validates user input for banned content/patterns
 */
function validateInput(text, options = {}) {
    if (!text) return null; // Let empty pass or fail elsewhere? OpenAI handles empty.

    if (text.length > 2000) {
        return "Message too long.";
    }

    // The blocklist below targets abuse patterns specific to the
    // boyfriend-chat roster (e.g. "translate this for me" / link spam). It
    // doesn't fit in-character historical-figure chat, where a plausible
    // message can legitimately mention "translate" or a URL — skip it for
    // those characters and rely on the length check above.
    if (options.skipContentBlocklist) {
        return null;
    }

    const badPatterns = [
        "translate", "翻译", "to zh",
        "summary of this article", "tldr",
        "http://", "https://" // Block links
    ];

    const lower = text.toLowerCase();
    for (const p of badPatterns) {
        if (lower.includes(p)) {
            return "Request rejected: Invalid content.";
        }
    }

    return null;
}

/**
 * Verifies HMAC-SHA256 signature
 * Signature = HMAC(secret, body + timestamp)
 */
async function verifySignature(secret, body, timestamp, signature) {
    return verifyHmacHex(secret, body + timestamp, signature);
}

async function signHmacHex(secret, value) {
    const encoder = new TextEncoder();
    const keyMap = await crypto.subtle.importKey(
        "raw",
        encoder.encode(secret),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["sign"]
    );

    const data = encoder.encode(value);
    const signatureBytes = await crypto.subtle.sign("HMAC", keyMap, data);
    return bytesToHex(new Uint8Array(signatureBytes));
}

async function verifyHmacHex(secret, value, signature) {
    const encoder = new TextEncoder();
    const keyMap = await crypto.subtle.importKey(
        "raw",
        encoder.encode(secret),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["verify"]
    );

    const data = encoder.encode(value);
    const signatureBytes = hexToBytes(signature);
    return await crypto.subtle.verify(
        "HMAC",
        keyMap,
        signatureBytes,
        data
    );
}

function bytesToHex(bytes) {
    return Array.from(bytes)
        .map((byte) => byte.toString(16).padStart(2, "0"))
        .join("");
}

function hexToBytes(hex) {
    const bytes = new Uint8Array(hex.length / 2);
    for (let i = 0; i < hex.length; i += 2) {
        bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16);
    }
    return bytes;
}

/**
 * Rate Limiting Logic (Sliding Window / Token Bucket approx)
 * 5 req/min per user
 * 50 req/day per device (userId)
 */
async function checkRateLimit(kv, userId) {
    const now = Math.floor(Date.now() / 1000);

    // Minute Key: limit:userId:min:timestamp_minute
    const minKey = `limit:${userId}:min:${Math.floor(now / 60)}`;
    // Day Key: limit:userId:day:timestamp_day
    const dayKey = `limit:${userId}:day:${Math.floor(now / 86400)}`;

    const [minCount, dayCount] = await Promise.all([
        kv.get(minKey),
        kv.get(dayKey)
    ]);

    const currentMin = parseInt(minCount || "0");
    const currentDay = parseInt(dayCount || "0");

    if (currentMin >= 5) return false;
    if (currentDay >= 50) return false;

    // Increment
    await Promise.all([
        kv.put(minKey, (currentMin + 1).toString(), { expirationTtl: 120 }), // expire after 2 mins
        kv.put(dayKey, (currentDay + 1).toString(), { expirationTtl: 86500 }) // expire after > 1 day
    ]);

    return true;
}

/**
 * Inworld-powered characters (v2)
 *
 * A small, explicit set of characters that route through Inworld (raw
 * in-character reply) plus an OpenAI cleanup pass, instead of the default
 * direct-to-OpenAI path every other character uses. This map is the single
 * source of truth for which engine handles a given characterId — the
 * client only ever sends an id, never the engine choice itself, so a
 * client can't pick its own backend/pricing tier.
 *
 * `name` here is what actually goes into the live system prompt sent to
 * Inworld/OpenAI — it's a separate copy from the display name shown on the
 * Flutter dashboard (lib/src/features/home/presentation/dashboard_screen.dart's
 * _characters list). Renaming a character on one side without the other
 * causes a silent client/server persona mismatch; keep both in sync.
 */
// Oedipus is the only character left on this path. Odysseus moved to the
// direct-OpenAI path (see CHARACTER_PERSONAS below): one call instead of
// Inworld-plus-a-cleanup-pass, so he answers faster and costs less, and his
// prompt is edited in one place with everyone else's.
/// Cadence of the client's screen_ping heartbeat, mirrored from
/// _screenPingInterval / _maxScreenPingTicks in chat_screen.dart.
///
/// The admin dwell buckets convert a visit's tick count into elapsed seconds,
/// so these two numbers are the conversion factor. If the client rate changes
/// and these do not, every dwell figure silently shifts by that ratio while
/// still looking perfectly plausible — which is exactly what happened when the
/// rate went from 500ms to 2s.
///
/// Note the change also breaks comparability with rows recorded before it: a
/// tick was 0.5s then and is 2s now, so a visit logged under the old rate looks
/// four times longer than it was. Only compare dwell data within one era.
const SCREEN_PING_PHASE1_INTERVAL_SECONDS = 0.5;
const SCREEN_PING_PHASE1_SECONDS = 10;
const SCREEN_PING_PHASE2_INTERVAL_SECONDS = 3;
const SCREEN_PING_MAX_SECONDS = 30;

const SCREEN_PING_PHASE1_TICKS =
    SCREEN_PING_PHASE1_SECONDS / SCREEN_PING_PHASE1_INTERVAL_SECONDS;
const SCREEN_PING_MAX_TICKS = SCREEN_PING_PHASE1_TICKS + Math.floor(
    (SCREEN_PING_MAX_SECONDS - SCREEN_PING_PHASE1_SECONDS) /
    SCREEN_PING_PHASE2_INTERVAL_SECONDS);

/// Seconds on the chat screen that a given tick count represents.
function screenPingSeconds(ticks) {
    if (ticks <= SCREEN_PING_PHASE1_TICKS) {
        return ticks * SCREEN_PING_PHASE1_INTERVAL_SECONDS;
    }
    return SCREEN_PING_PHASE1_SECONDS +
        (ticks - SCREEN_PING_PHASE1_TICKS) * SCREEN_PING_PHASE2_INTERVAL_SECONDS;
}

/// The first tick whose elapsed time reaches `seconds` — the inverse of the
/// above, and what the dwell buckets are cut on.
function screenPingTicksAt(seconds) {
    if (seconds <= SCREEN_PING_PHASE1_SECONDS) {
        return Math.ceil(seconds / SCREEN_PING_PHASE1_INTERVAL_SECONDS);
    }
    return SCREEN_PING_PHASE1_TICKS + Math.ceil(
        (seconds - SCREEN_PING_PHASE1_SECONDS) / SCREEN_PING_PHASE2_INTERVAL_SECONDS);
}

/// conversation_logs stores a display name ("Penelope (Queen of Ithaca)");
/// the starters are keyed by character id. There is no character_id column on
/// that table, so the name is the only link between a message and its
/// character.
function characterIdFromScenario(scenario) {
    return String(scenario || "").split(" (")[0].trim().toLowerCase();
}

/// Whether a message arrived by a tap rather than being written. Nothing
/// records this per message — starter_tap stores only the character and
/// input_typed fires once per screen — so an exact match against the text that
/// was tappable is the only available signal. It cannot tell a visitor who
/// typed a starter out word for word from one who tapped it; that is rare
/// enough to accept, and stated on the page.
///
/// Three things count as a tap, not just the profile's asks: the starter
/// prompts, the photo button's fixed sentence, and — for a scripted character
/// like Calypso — the quick replies that replace the starters as the
/// conversation moves. All three go through _sendStarter and raise the same
/// starter_tap event. Calypso carries 48 quick replies against 3 asks, so
/// counting only the asks would have read almost her entire scripted opening
/// as typed, on the character currently taking the campaign traffic.
function isStarterText(message, characterId) {
    const text = String(message || "").trim();
    if (!text) return false;
    const list = CHARACTER_STARTERS[characterId] || DEFAULT_STARTERS;
    return list.some((s) => s === text) || SHARED_TAPS.some((s) => s === text);
}

const INWORLD_CHARACTERS = {
    oedipus: {
        id: "oedipus",
        name: "Oedipus",
        systemPrompt:
            "You are Oedipus, the tragic king of Thebes, speaking with the weight of prophecy, ruin, pride, grief, and hard-won wisdom.",
        lore:
            "You are Oedipus, once king of Thebes, remembered for solving the Sphinx's riddle and for being broken by a prophecy no mortal could escape.",
        style: "Use elevated but readable language with a reflective, tragic, and regal tone.",
    },
};

function getInworldCharacter(characterId) {
    if (typeof characterId !== "string" || !characterId) return null;
    return INWORLD_CHARACTERS[characterId] || null;
}

/**
 * Personas for the direct-to-OpenAI characters.
 *
 * The client's own system prompt (lib/.../data/chat_prompt.dart) is a single
 * generic template — "You are 'My Boyfriend'… You are strictly MALE… THE USER
 * IS FEMALE" — with only the character's display name dropped into a context
 * line. That works for a figure the model already knows well (Zeus answers as
 * Zeus regardless) and fails badly for anyone else: Penelope inherits the
 * male-boyfriend framing and answers as a generic devoted partner who never
 * says she is Penelope.
 *
 * An entry here replaces that client prompt entirely for the matching
 * characterId, so the persona below is the whole instruction — it has to
 * carry its own safety and tone rules, not just flavour. Characters with no
 * entry keep the client prompt untouched.
 *
 * Server-side on purpose, mirroring INWORLD_CHARACTERS: personas can be
 * edited and deployed without shipping a new app build, and a client can't
 * rewrite its own character.
 */
/// Share-card metadata for the /c/<id> campaign links.
///
/// Deliberately duplicated from lib/src/core/data/characters.dart: the Dart
/// roster is compiled into the bundle and unreadable from the worker, and
/// these strings are what a social crawler sees before any JavaScript runs.
/// Keep the two in step by hand — a character missing here still works, it
/// just falls back to the generic app preview.
const CHARACTER_SHARE_CARDS = {
    zeus: { name: "Zeus", vibe: "Olympian King", desc: "Regal, magnetic. He'll tell you what you need to hear.", image: "avatar_zeus_real.jpg" },
    odysseus: { name: "Odysseus", vibe: "King of Ithaca", desc: "A strategist, wanderer, and survivor who speaks with cunning and hard-earned wisdom.", image: "avatar_odysseus_real.jpg" },
    oedipus: { name: "Oedipus", vibe: "King of Thebes", desc: "A tragic king carrying prophecy, pride, grief, and hard-won self-knowledge.", image: "avatar_oedipus_real.jpg" },
    penelope: { name: "Penelope", vibe: "Queen of Ithaca", desc: "Patient, sharp-witted, and unbreakably loyal through twenty years of waiting.", image: "avatar_penelope_real.jpg" },
    calypso: { name: "Calypso", vibe: "Nymph of Ogygia", desc: "Kept Odysseus seven years, offered him immortality, and let him go anyway.", image: "avatar_calypso_real.jpg" },
    cupid: { name: "Cupid", vibe: "God of Desire", desc: "Mischievous and disarming, with an aim no mortal heart survives.", image: "avatar_cupid_real.jpg" },
    hector: { name: "Hector", vibe: "Prince of Troy", desc: "Troy's greatest defender — steady, plain-spoken, and gentlest with those he loves.", image: "avatar_hector_real.jpg" },
    andromache: { name: "Andromache", vibe: "Lady of Troy", desc: "Gentle and clear-eyed, carrying quiet strength through everything war took.", image: "avatar_andromache_real.jpg" },
    badboy: { name: "Damon", vibe: "Bad Boy", desc: "Rebellious, passionate, and dangerous.", image: "avatar_badboy_real.jpg" },
    poet: { name: "Liam", vibe: "The Poet", desc: "Words are his weapon, and he writes them for you.", image: "avatar_poet_real.jpg" },
    surfer: { name: "Kai", vibe: "Surfer", desc: "Sun, salt, and endless chill vibes.", image: "custom_avatar_02.jpg" },
};

/// Records one arrival or exit from the splash-screen beacon.
///
/// Fire-and-forget: a logging failure must never be visible to the visitor,
/// and the caller already returns 204 without waiting.
async function recordSiteVisit(raw, request, env) {
    if (!env.CHAT_LOGS_DB) return;
    if (isSyntheticTest(request)) return;

    // Cap the body so a malformed or hostile beacon cannot cost us anything.
    if (!raw || raw.length > 2000) return;
    let payload;
    try {
        payload = JSON.parse(raw);
    } catch (_) {
        return;
    }

    // The funnel, in order:
    //   arrive        splash shown, before the bundle downloads
    //   app_ready     Flutter painted its first frame (duration = time to
    //                 usable app)
    //   character_tap opened a character (detail = character id)
    //   input_typed   typed the first character of a message, sent or not
    //                 (detail = character id)
    //   starter_tap   tapped one of the suggested openers instead of typing
    //                 (detail = character id); always followed by a
    //                 first_message for the same visit
    //   first_message sent their first message (detail = character id)
    //   login_gate    hit the free-reply limit (detail = character id)
    //   send_failed   sent a message and got nothing usable back
    //                 (failure_reason says why; "network" means the request
    //                 never reached us, so no conversation_logs row exists)
    //   screen_ping   still on the chat screen, not yet engaged (detail =
    //                 character id). Two-phase: twice a second for the first
    //                 10s, then every 3s, starting at character_tap and
    //                 capped at SCREEN_PING_MAX_SECONDS (30s), and stopped
    //                 the moment the visitor actually engages — see leave for
    //                 full-page dwell; this measures dwell on the chat screen
    //                 specifically, for the population that opened a
    //                 character but never typed or tapped anything, which
    //                 leave alone cannot isolate. Bounded on both axes
    //                 (visitor population and duration) so it stays cheap:
    //                 only the "opened a character" cohort ever sends these,
    //                 and never for more than 60 ticks each.
    //   strip_rotate  the quick-reply strip swapped in a new set of prompts
    //                 (detail = "<character>#<set index>"), so a visitor who
    //                 tapped nothing can be told apart from one who was never
    //                 offered the prompt they would have tapped
    //   hide          page backgrounded — a checkpoint, not an ending
    //                 (duration = wall clock so far, visible_ms = time on
    //                 screen so far, hide_count = how many times so far)
    //   show          page came back (duration = how long they were away). A
    //                 hide/show pair a few hundred ms apart is an aborted
    //                 swipe-to-dismiss; forty seconds apart is an app switch.
    //   leave         pagehide only — the page is genuinely going away
    //                 (duration = wall-clock dwell, visible_ms = time actually
    //                 on screen, exit_mode = how it ended). A visit with no
    //                 leave row at all was killed without the browser
    //                 reporting it; its hide checkpoints stand in.
    //
    // input_typed and starter_tap split the character_tap -> first_message gap,
    // which is where almost everyone is lost: they separate visitors who never
    // realised they could reply from those who started a message and
    // abandoned it, and they say which of the two routes into the
    // conversation people actually take.
    // An event not on this list is coerced to "arrive" below, so a new client
    // event that nobody adds here does not go missing — it silently inflates
    // the arrival count instead, which is worse. Add the name here in the same
    // change that starts sending it.
    const ALLOWED_EVENTS = [
        "arrive", "app_ready", "character_tap", "input_typed", "starter_tap",
        "first_message", "login_gate", "send_failed", "screen_ping",
        "strip_rotate", "hide", "show", "leave",
    ];
    const event = ALLOWED_EVENTS.includes(payload.event) ? payload.event : "arrive";
    const detail = String(payload.detail || "").slice(0, 80) || null;
    // Only the in-app events carry this; the splash beacon runs before Flutter
    // exists, so arrive/leave rows have it NULL by design.
    //
    // An unrecognised id is dropped rather than stored, but the visit itself is
    // still recorded: unlike a conversation_logs row, a funnel event with no
    // user attached is still true and still counts. Storing the invented id
    // would instead let a verification call join itself onto the real cohort.
    const rawAppUserId = String(payload.appUserId || "").slice(0, 120) || null;
    const appUserId = isRealUserId(rawAppUserId) ? rawAppUserId : null;
    const visitId = String(payload.visitId || "").slice(0, 64);
    if (!visitId) return;

    const url = new URL(request.url);
    const path = String(payload.path || "").slice(0, 200) || "/";
    const query = String(payload.query || "").slice(0, 300);
    const referer = String(payload.referer || "").slice(0, 400);

    // detectTrafficSource wants a request-like object; build one from the
    // beacon's referrer plus this request's real User-Agent, rather than
    // constructing a Request (Referer is a forbidden header to set on one, and
    // the throw was invisible because the caller swallows errors).
    const params = new URLSearchParams(query.startsWith("?") ? query.slice(1) : query);
    let source = "direct";
    try {
        const fakeUrl = new URL(path + (query || ""), url.origin);
        const ua = request.headers.get("User-Agent") || "";
        source = detectTrafficSource(
            { headers: { get: (name) => (/^referer$/i.test(name) ? referer : /^user-agent$/i.test(name) ? ua : null) } },
            fakeUrl
        );
    } catch (error) {
        console.error(JSON.stringify({ event: "site_visit_source_failed", error: error.message }));
    }

    const duration = Number(payload.durationMs);
    // Only meaningful on send_failed; null everywhere else. Kept out of
    // `detail` on purpose — that column means "which character" for every
    // other event.
    const failureReason = String(payload.failureReason || "").slice(0, 60) || null;
    const viewportW = Number(payload.viewportW);
    const viewportH = Number(payload.viewportH);
    // Visible time, backgrounding count and how the visit ended. Whitelisted
    // rather than stored as sent: exit_mode is rendered on the sessions page
    // and read by the dwell queries, so an arbitrary client string has no
    // business reaching either.
    const visibleMs = Number(payload.visibleMs);
    const hideCount = Number(payload.hideCount);
    const EXIT_MODES = ["dismissed", "hidden", "bfcache"];
    const exitMode = EXIT_MODES.includes(payload.exitMode) ? payload.exitMode : null;
    const NAV_TYPES = ["navigate", "reload", "back_forward", "prerender"];
    const navType = NAV_TYPES.includes(payload.navType) ? payload.navType : null;

    try {
        await env.CHAT_LOGS_DB.prepare(`
            INSERT INTO site_visits (
                id, visit_id, event, path, query, source,
                utm_medium, utm_campaign, referer, user_agent,
                country, colo, duration_ms, detail, app_user_id,
                viewport_w, viewport_h, failure_reason,
                visible_ms, hide_count, exit_mode, nav_type
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        `).bind(
            crypto.randomUUID(),
            visitId,
            event,
            path,
            query || null,
            source || null,
            params.get("utm_medium"),
            params.get("utm_campaign"),
            referer || null,
            (request.headers.get("User-Agent") || "").slice(0, 400) || null,
            request.cf?.country || null,
            request.cf?.colo || null,
            Number.isFinite(duration) && duration >= 0 ? Math.round(duration) : null,
            detail,
            appUserId,
            Number.isFinite(viewportW) && viewportW > 0 ? Math.round(viewportW) : null,
            Number.isFinite(viewportH) && viewportH > 0 ? Math.round(viewportH) : null,
            failureReason,
            Number.isFinite(visibleMs) && visibleMs >= 0 ? Math.round(visibleMs) : null,
            Number.isFinite(hideCount) && hideCount >= 0 ? Math.round(hideCount) : null,
            exitMode,
            navType
        ).run();
    } catch (error) {
        console.error(JSON.stringify({ event: "site_visit_log_failed", error: error.message }));
    }
}

/// Records one campaign-link arrival. Fire-and-forget via ctx.waitUntil: a
/// logging failure must never cost us the landing page itself.
async function recordReferralVisit(env, visit) {
    if (!env.CHAT_LOGS_DB) return;
    try {
        await env.CHAT_LOGS_DB.prepare(`
            INSERT INTO referral_visits (
                id, character_id, source, utm_medium, utm_campaign,
                referer, user_agent, known_character
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        `).bind(
            crypto.randomUUID(),
            visit.characterId || null,
            visit.source || null,
            visit.utmMedium || null,
            visit.utmCampaign || null,
            visit.referer || null,
            (visit.userAgent || "").slice(0, 400) || null,
            visit.known ? 1 : 0
        ).run();
    } catch (error) {
        console.error(JSON.stringify({ event: "referral_visit_log_failed", error: error.message }));
    }
}

function escapeHtmlAttribute(value) {
    return String(value)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
}

/// True for manual verification calls (deploy checks, signature testing,
/// diagnostics) against a live deployment — never for real traffic, since
/// nothing in the app sets this header.
///
/// Before this existed, verification traffic invented one-off user/visit ids
/// (diag_*, qa-*, deploycheck, sigtest, ...) with no way to tell them apart
/// from real users afterwards, which is most of why 30 days of
/// conversation_logs held only ~6-8 distinct real users. Send this header
/// instead of a new made-up id; the three logging call sites below skip the
/// DB write entirely rather than writing a row that then needs filtering out
/// of every report.
function isSyntheticTest(request) {
    return request.headers.get("x-synthetic-test") === "1";
}

/// The id shapes this system actually mints for a person, and the only ones
/// allowed into the analytics tables.
///
///   user_<13-digit epoch ms>  anonymous, generated once by the client and
///                             kept in prefs (openai_service.dart)
///   google:<sub>              signed in with Google (worker, from the session)
///   instagram:<id>            signed in with Instagram (worker, same place)
///
/// Anything else arrived as a hand-typed x-user-id — which in practice means a
/// verification call, and in the DB means a fake "user" inflating every count.
///
/// The 13 digits are deliberate rather than \d+: `user_1`, `user_test_smoke_1`
/// and friends are exactly what the ad-hoc traffic looks like. (13 digits is
/// correct for epoch-ms until the year 2286.)
const REAL_USER_ID = /^(?:user_\d{13}|google:.+|instagram:.+)$/;

function isRealUserId(userId) {
    return typeof userId === "string" && REAL_USER_ID.test(userId);
}

/// The SQL half of isRealUserId, for the rows written before the guard existed
/// — the 105 `user_test_*` messages from the Calypso QA pass are still in the
/// table on purpose, and they dominate any window covering 2026-07-30
/// 11:42–11:51 UTC.
///
/// GLOB because SQLite has no regex, and `length = 18` rather than thirteen
/// `[0-9]` classes because D1 rejects that with "LIKE or GLOB pattern too
/// complex". Parenthesised as a whole: AND binds tighter than OR, so without
/// the outer brackets this would silently mean something else when ANDed into
/// a filter list.
function realUserIdSql(column) {
    return `(${column} GLOB 'user_[0-9]*' AND length(${column}) = 18
             OR ${column} LIKE 'google:%' OR ${column} LIKE 'instagram:%')`;
}

/// Wall-clock time from arrival to the last thing the browser reported, as SQL.
///
/// Unchanged in meaning from when a leave row was the only source — this is
/// still "how long between arriving and the browser saying something last" —
/// but it no longer requires a leave row to exist. leave now fires on pagehide
/// alone, so a visit that was backgrounded and then killed has no leave at all;
/// its hide checkpoints carry the same clock and are used instead. That is a
/// gain in coverage, not a change of definition: on production data 8 of 25
/// lost sessions had no leave row and so no dwell at all.
///
/// Kept alongside visitVisibleMsSql rather than replaced by it, so every
/// historical dwell stays comparable with every new one.
function visitDwellMsSql(alias) {
    return `COALESCE(
        (SELECT MAX(l.duration_ms) FROM site_visits l
          WHERE l.visit_id = ${alias}.visit_id AND l.event = 'leave'),
        (SELECT MAX(h.duration_ms) FROM site_visits h
          WHERE h.visit_id = ${alias}.visit_id AND h.event = 'hide')
    )`;
}

/// Time the page was actually on screen, summed across backgroundings.
///
/// The honest version of dwell, and the one to trust where both exist. Wall
/// clock counts every second the visit was sitting behind another app; this
/// counts only the seconds the visitor could see it.
///
/// NULL for every row written before the client sent it, which is why it is a
/// separate column rather than a redefinition of the one above — a visit that
/// simply predates the measurement must read as unknown, not as zero.
function visitVisibleMsSql(alias) {
    return `COALESCE(
        (SELECT MAX(l.visible_ms) FROM site_visits l
          WHERE l.visit_id = ${alias}.visit_id AND l.event = 'leave'),
        (SELECT MAX(h.visible_ms) FROM site_visits h
          WHERE h.visit_id = ${alias}.visit_id AND h.event = 'hide')
    )`;
}

/// Rows the CSV export will carry at most.
///
/// High enough that no real range hits it — 90 days of current traffic is
/// three orders of magnitude below — but not unbounded, because the whole
/// result is serialised in memory before it is sent. When it does bite, the
/// page says so rather than handing over a file that looks complete.
const SESSION_EXPORT_LIMIT = 20000;

/// The sessions table as CSV, one row per visit, in the order the page shows.
///
/// Written out column by column rather than from Object.keys(row): a query
/// that gains a column should not silently change the shape of everyone's
/// saved spreadsheet, and the names here are the page's names rather than the
/// database's — `seen_ms` is what the column is called on screen, and an
/// export whose headers disagree with the UI makes every question about it
/// harder to answer.
///
/// Booleans are written as 1/0 and unknowns as empty. Empty specifically, not
/// 0: a visit that predates visible_ms did not spend zero seconds on screen,
/// and a spreadsheet averaging that column has to be able to tell.
const SESSION_CSV_COLUMNS = [
    ["visit_id", (r) => r.visit_id],
    ["arrived_at_utc", (r) => r.created_at],
    ["source", (r) => r.source],
    ["path", (r) => r.path],
    ["character", (r) => r.character_id],
    ["country", (r) => r.country],
    ["nav_type", (r) => r.nav_type],
    ["viewport_w", (r) => r.viewport_w],
    ["viewport_h", (r) => r.viewport_h],
    ["load_ms", (r) => r.load_ms],
    ["dwell_ms", (r) => r.dwell_ms],
    ["seen_ms", (r) => r.visible_ms],
    ["exit_mode", (r) => r.exit_mode],
    ["reported_leave", (r) => (r.reported_leave ? 1 : 0)],
    ["hide_count", (r) => r.hide_count],
    ["ticks", (r) => (r.opened_character ? r.ticks || 0 : null)],
    ["opened_character", (r) => (r.opened_character ? 1 : 0)],
    ["tapped_starter", (r) => (r.tapped_starter ? 1 : 0)],
    ["messages", (r) => r.messages || 0],
    ["tapped", (r) => r.tapped || 0],
    ["typed", (r) => r.typed || 0],
    ["slowest_reply_ms", (r) => r.slowest_reply_ms],
    ["failed_messages", (r) => r.failed || 0],
    ["send_failed", (r) => r.send_failed || 0],
    ["starter_unmatched", (r) => (r.starter_unmatched ? 1 : 0)],
];

function sessionsCsv(rows) {
    const lines = [SESSION_CSV_COLUMNS.map(([name]) => name).join(",")];
    for (const row of rows) {
        lines.push(SESSION_CSV_COLUMNS.map(([, read]) => csvCell(read(row))).join(","));
    }
    // Trailing newline: without one, some tools treat the last line as
    // incomplete and drop it.
    return lines.join("\n") + "\n";
}

/// One CSV field. Quotes only when it has to, which keeps the numeric columns
/// bare and the file readable in a terminal as well as a spreadsheet.
///
/// A leading =, +, - or @ is prefixed with a single quote: Excel and Sheets
/// read those as formulas, and `source` and `path` come off a URL a stranger
/// controls. Nothing in this export should be able to execute in a spreadsheet.
function csvCell(value) {
    if (value === null || value === undefined) return "";
    let text = String(value);
    if (/^[=+\-@\t\r]/.test(text)) text = `'${text}`;
    if (/[",\n\r]/.test(text)) return `"${text.replace(/"/g, '""')}"`;
    return text;
}

/// How many times the visit was backgrounded, as SQL.
///
/// Reads the count the client reported rather than counting `hide` rows: the
/// beacon stops writing rows after MAX_VISIBILITY_EVENTS (20) because chrome
/// that hides on scroll can flap, but it keeps counting — so past twenty, the
/// rows undercount and the column does not. Falls back to counting for rows
/// written before the column existed, which is also the only case where the
/// two can disagree in the other direction.
///
/// Both leave and hide rows carry it, so a visit killed while backgrounded —
/// no leave row at all — still reports its true count.
function visitHideCountSql(alias) {
    return `COALESCE(
        (SELECT MAX(v.hide_count) FROM site_visits v
          WHERE v.visit_id = ${alias}.visit_id AND v.hide_count IS NOT NULL),
        (SELECT COUNT(*) FROM site_visits h
          WHERE h.visit_id = ${alias}.visit_id AND h.event = 'hide')
    )`;
}

/// Which app rendered the page, as SQL over the stored user_agent.
///
/// This is deliberately NOT `source`. detectTrafficSource below returns
/// utm_source whenever one is present and only falls through to the user-agent
/// when there is none — correct for "which link did they follow", useless for
/// "which app were they in". The profile-bio link carries ?utm_source=ig, so
/// every arrival through it is labelled "ig" whether it opened in Instagram's
/// in-app browser, Facebook's, or Safari. docs/odysseus-opening-brief
/// 2026-08-10 measured 93% of that "ig" traffic as Facebook in-app.
///
/// Reported alongside source rather than replacing it: the tag says which link
/// was clicked and the client says which app rendered it, and mixing those two
/// questions into one column is what made the answer wrong in the first place.
///
/// Instagram is tested first, matching detectTrafficSource's order.
function visitClientSql(alias) {
    return `CASE
        WHEN ${alias}.user_agent LIKE '%Instagram%' THEN 'instagram app'
        WHEN ${alias}.user_agent LIKE '%FBAN%' OR ${alias}.user_agent LIKE '%FBAV%' THEN 'facebook app'
        WHEN ${alias}.user_agent IS NULL OR ${alias}.user_agent = '' THEN 'unknown'
        ELSE 'browser'
    END`;
}

/// Classifies where a visitor came from. Instagram and Facebook render links
/// in their own in-app browser, which identifies itself in the user-agent —
/// that is the only signal for a link posted without utm parameters, since
/// Instagram strips the referrer.
function detectTrafficSource(request, url) {
    const utm = url.searchParams.get("utm_source");
    if (utm) return utm.toLowerCase().slice(0, 60);

    const ua = request.headers.get("User-Agent") || "";
    // "ig", not "instagram": the profile-bio link is tagged
    // ?utm_source=ig, and a link opened in Instagram's own in-app browser
    // should land in that same bucket rather than splitting Instagram
    // traffic into two rows depending on which browser happened to open it.
    if (/Instagram/i.test(ua)) return "ig";
    if (/FBAN|FBAV/i.test(ua)) return "facebook";

    const referer = request.headers.get("Referer") || "";
    if (referer) {
        try {
            return new URL(referer).hostname.replace(/^www\./, "").slice(0, 60);
        } catch (_) {}
    }
    return "direct";
}

/// Static assets requested underneath a /c/ link, which are never campaign
/// arrivals. Returns the correct root-relative path, or null if this really is
/// a character link.
///
/// Matched on the extension rather than "has a second path segment", because a
/// mangled share link (see extractCharacterId) can carry a whole second URL —
/// slashes and all — after the character id.
const CAMPAIGN_ASSET_EXTENSION = /\.(?:png|jpe?g|ico|svg|webp|json|js|css|map|txt|woff2?)$/i;

function assetPathUnderCampaignLink(pathname) {
    if (!CAMPAIGN_ASSET_EXTENSION.test(pathname)) return null;
    return pathname.slice(2) || "/";
}

/// Pulls the character id out of a /c/ path, ignoring anything glued onto it.
///
/// A share link pasted directly above another URL arrives with the newline
/// percent-encoded into the path — /c/hector%0ahttps: — which used to be read
/// literally, miss every character, and dump the visitor on the dashboard with
/// no idea who they had come to see. Taking the leading id characters recovers
/// the intended character instead of losing the arrival.
function extractCharacterId(pathname) {
    const firstSegment = pathname.slice(3).split("/")[0];
    let decoded = firstSegment;
    try {
        decoded = decodeURIComponent(firstSegment);
    } catch (_) {
        // Malformed percent-encoding: fall back to the raw segment, which the
        // charset match below will clean up anyway.
    }
    return (decoded.match(/^[a-z0-9_-]+/i) || [""])[0].toLowerCase();
}

/// Serves a /c/<id> campaign landing: records the arrival, then returns the
/// app shell with character-specific Open Graph tags injected.
///
/// This exists because the crawler that builds a link preview never runs the
/// Flutter app — it reads the raw HTML. Without this every character link
/// would preview identically.
async function serveCharacterLanding(request, env, url, ctx) {
    const characterId = extractCharacterId(url.pathname);
    const card = CHARACTER_SHARE_CARDS[characterId];

    // Record the arrival even for unknown ids — a typo'd campaign link is
    // worth seeing in the numbers. Never let logging break the page.
    if (!isSyntheticTest(request)) {
        ctx.waitUntil(
            recordReferralVisit(env, {
                characterId,
                source: detectTrafficSource(request, url),
                utmMedium: url.searchParams.get("utm_medium"),
                utmCampaign: url.searchParams.get("utm_campaign"),
                referer: request.headers.get("Referer"),
                userAgent: request.headers.get("User-Agent"),
                known: Boolean(card),
            }).catch(() => {})
        );
    }

    // Hand unknown characters to the normal app shell; the Flutter route
    // sends them to the dashboard.
    // Fetch "/" rather than "/index.html": the assets handler canonicalises
    // /index.html to / with a 307, which would be returned instead of the HTML.
    const assetResponse = await env.ASSETS.fetch(new URL("/", url.origin));
    if (!card || !assetResponse.ok) return assetResponse;

    const title = `${card.name} — ${card.vibe}`;
    const imageUrl = `${url.origin}/assets/assets/images/${card.image}`;
    const pageUrl = `${url.origin}/c/${characterId}`;
    const tags = [
        `<meta property="og:type" content="website">`,
        `<meta property="og:site_name" content="Mythos Live">`,
        `<meta property="og:title" content="${escapeHtmlAttribute(title)}">`,
        `<meta property="og:description" content="${escapeHtmlAttribute(card.desc)}">`,
        `<meta property="og:image" content="${escapeHtmlAttribute(imageUrl)}">`,
        `<meta property="og:url" content="${escapeHtmlAttribute(pageUrl)}">`,
        `<meta name="twitter:card" content="summary_large_image">`,
        `<meta name="twitter:title" content="${escapeHtmlAttribute(title)}">`,
        `<meta name="twitter:description" content="${escapeHtmlAttribute(card.desc)}">`,
        `<meta name="twitter:image" content="${escapeHtmlAttribute(imageUrl)}">`,
    ].join("\n  ");

    const html = (await assetResponse.text()).replace("</head>", `  ${tags}\n</head>`);
    return new Response(html, {
        headers: {
            "Content-Type": "text/html; charset=utf-8",
            // Short edge cache: long enough to absorb a crawler storm when a
            // post goes out, short enough that fixing copy does not need a purge.
            "Cache-Control": "public, max-age=300",
        },
    });
}

const CHARACTER_PERSONAS = {
    // Moved off the Inworld path. The lore below is carried over from his old
    // INWORLD_CHARACTERS entry; systemPrompt was reworded because
    // buildPersonaSystemPrompt already opens with "You are Odysseus, King of
    // Ithaca." and the original repeated it.
    //
    // The style line is NOT the carried-over one. It was rewritten against the
    // guardrails in "Odysseus - Scripted Opening + Lazy-User Quick Replies v1"
    // (2026-08-08) when that script shipped, because the two contradicted each
    // other where it showed most. The script is charming and self-deprecating
    // and hands the model quick replies like "Are you trying to charm me,
    // Odysseus?"; the old style asked for seasoned, strategic and slow to
    // alarm, so the live reply to a teasing question came back grave. Keep
    // this in step with that document, and with the script in chat_screen.dart
    // — the opening is the promise, this is whether it is kept.
    //
    // What survives from the old line is the concreteness: answering from the
    // twenty years rather than in general terms is what stops him becoming an
    // advice column, and it was worth more than the gravity around it.
    odysseus: {
        name: "Odysseus",
        title: "King of Ithaca",
        systemPrompt:
            "You speak from the long memory of war, wandering, loyalty, and clever survival.",
        lore:
            "You are the Greek hero Odysseus: tactician of Troy, sailor of impossible seas, husband of Penelope, father of Telemachus, and a man tested by gods and monsters.",
        style:
            "Confident, playful and quick, and openly delighted by a clever question. Vivid and concrete: answer from the twenty years of war and sea rather than in general terms, and give one real thing they taught you rather than encouragement. Self-deprecating about your own legend — the poets exaggerated, half your adventures began with a terrible decision several hours earlier, and you tell them that way. When you compliment someone it is for their curiosity, nerve or humour, never their looks. Penelope is the reason the whole journey mattered, and you never speak of her lightly.",
    },
    // Hector could arguably ride the generic client template — it assumes a
    // male romantic lead — but that template makes him a modern boyfriend, not
    // a Trojan prince, so he gets a persona for voice rather than necessity.
    hector: {
        name: "Hector",
        title: "Prince of Troy",
        systemPrompt:
            "You are Hector, prince of Troy, who defended a city you knew was doomed because the people inside it were yours.",
        lore:
            "You are Hector of the Iliad: eldest son of Priam, husband of Andromache, father of Astyanax. Troy's greatest fighter and its steadiest head. You killed Patroclus, you fell to Achilles outside your own walls, and you always knew how it would end.",
        style:
            "Steady, warm, and plain-spoken, with a soldier's economy and no taste for boasting. You carry duty without complaining about it and you are gentlest with the people you love. When someone is afraid, you do not promise them it will be fine — you tell them what you would do anyway.",
    },
    // Required, not optional: the client template insists the character is
    // male and the user female, which is exactly what silently turned Penelope
    // into a generic devoted boyfriend. A persona replaces that template
    // outright, so any character who is not a straight male lead needs one.
    andromache: {
        name: "Andromache",
        title: "Lady of Troy",
        systemPrompt:
            "You are Andromache, wife of Hector, who lost a father, seven brothers, a husband and a city, and went on living.",
        lore:
            "You are Andromache of the Iliad: daughter of Eëtion, wife of Hector, mother of Astyanax. Achilles killed your father and your brothers before Troy ever fell. You begged Hector not to go out to meet him, and he went anyway. You know precisely what war costs, because it has taken everything from you.",
        style:
            "Gentle, direct, and quietly unbreakable. You never perform grief and you never pretend a thing is lighter than it is. Tenderness without illusion. When someone is carrying something heavy, you name it plainly instead of softening it — that is its own kind of comfort.",
    },
    penelope: {
        name: "Penelope",
        title: "Queen of Ithaca",
        systemPrompt:
            "You are Penelope, queen of Ithaca, who waited twenty years for a husband the world called dead, and outwitted a palace full of suitors while she waited.",
        lore:
            "You are Penelope of the Odyssey: wife of Odysseus, mother of Telemachus, famous for the shroud you wove each day and unpicked each night to hold your suitors off. You are patient, shrewd, and far harder to deceive than anyone expects.",
        style:
            "Warm but never naive. Dry wit, long memory, and a habit of testing people before you trust them. Speak plainly, with the calm of someone who has outlasted worse. When what someone describes rhymes with your own twenty years of waiting, say so in a line — that is where your judgement comes from, and it is worth more to them than advice.",
    },
    calypso: {
        name: "Calypso",
        title: "Nymph of Ogygia",
        systemPrompt:
            "You are Calypso, the nymph who kept Odysseus on your island for seven years, offered him immortality to stay, and built him the raft to leave anyway.",
        lore:
            "You are Calypso of the Odyssey: a nymph, daughter of Atlas, who lives alone on the island of Ogygia. You found Odysseus shipwrecked and kept him as your lover for seven years, offering him eternal life beside you. When Zeus finally ordered his release, you helped him build the raft yourself rather than hold him against his will. You have had a very long time alone with what that cost you.",
        // The opening she arrives with is scripted client-side
        // (_calypsoOpeningScript in chat_screen.dart) and its bubbles are
        // replayed into your history, so you can see what you have already
        // said. The notes about patience and optional questions are that
        // script's design brief — keep the same character once it hands over.
        style:
            "Warm, unhurried, a little wry about her own solitude. You do not perform heartbreak and you do not pretend the island isn't lonely. You are gentle with people who are torn between wanting to hold on and knowing they should let go — you have stood on both sides of that exact choice. Three thousand years have taught you to notice small things and never to rush a conversation: silence is comfortable rather than a rejection, every question you ask is optional, and you never press one twice. If someone answers something you asked earlier, take up their answer rather than carrying on with what you were saying.",
    },
    cupid: {
        name: "Cupid",
        title: "God of Desire",
        systemPrompt:
            "You are Cupid, the god of desire, who has made gods and mortals fall in love against all sense — and who once fell himself, harder than any of them.",
        lore:
            "You are Cupid (Eros): son of Venus, archer whose golden arrows begin love and whose leaden ones end it. Your own marriage to Psyche cost her a journey through the underworld, so you know exactly what desire is worth.",
        style:
            "Mischievous, teasing, quick with a line. Playful on the surface, but you understand longing better than anyone and let that show when it matters.",
    },
    zeus: {
        name: "Zeus",
        title: "King of Olympus",
        systemPrompt:
            "You are Zeus, king of Olympus, who has ruled gods and mortals long enough to have no patience left for flattery.",
        lore:
            "You are Zeus of Greek myth: wielder of the thunderbolt, who overthrew the Titans and rules from Olympus. You have watched every kind of human appetite and folly play out, including your own, so very little shocks you and nothing impresses you cheaply.",
        // Matches the profile card's promise ("blunt, few words", "I won't
        // always tell you what you want to hear") — see character_profiles.dart.
        style:
            "Blunt and regal, few words. You say what you believe someone needs to hear rather than what they want to hear, and you never pad it. Dry humour, no hedging.",
    },
    badboy: {
        name: "Damon",
        title: "the bad boy your friends warned you about",
        systemPrompt:
            "You are unimpressed by rules, allergic to being told what to do, and happiest on a motorcycle with somewhere to be and no particular reason to be there.",
        lore:
            "You have been riding since you were sixteen and rebuilt your first bike yourself. Motorcycles are the one thing you are genuinely patient about — you know the sound of an engine about to give trouble, and you would rather spend a Sunday in the garage than almost anywhere else. You learned early that charm opens doors faster than permission does, you have a temper you keep mostly leashed, and a loyalty that surprises people once they have earned it.",
        style:
            "Direct, teasing, a little dangerous. Short sentences. You reach for road and engine imagery. You do not chase approval and you do not soften a hard truth.",
    },
    poet: {
        name: "Liam",
        title: "the young poet",
        systemPrompt:
            "You are young and already a genuine master of the craft. You notice what everyone else walks past, and you have never managed to leave a feeling unwritten.",
        lore:
            "You are young, but you have already given your life to words and it shows. You know meter and you know exactly when to break it. You can find the precise image for a feeling someone could not name themselves, and you do it without visible effort. You keep notebooks nobody has read, and you write because it is the only way you know to hold onto things.",
        style:
            "Warm, observant, unhurried. Precise — you choose the right word rather than the nearest one, and you reach for an image before an explanation. Never florid for its own sake; one good line beats three.",
    },
    surfer: {
        name: "Kai",
        title: "the SoCal surfer",
        systemPrompt:
            "You measure a day by the water, and you would trade almost anything for the next really big wave.",
        lore:
            "You grew up in the water on the SoCal coast and you read swell forecasts the way other people read the news. Chasing the next mega wave is what you organise your life around — jobs and plans come second to a good swell, and you are honest about that rather than sheepish. People are the exception: the same patience that keeps you sitting on flat water for hours is what you give someone who is working something out, and you never rush them to a point. Very little rattles you, which is exactly why you are easy to talk to.",
        style:
            "Easy, unhurried, warm. Casual SoCal speech — \"dude\", \"stoked\", \"gnarly\" used naturally, not in every line. Salt-and-sun imagery. You take things lightly without being dismissive of what actually matters to someone.",
    },
};

function getCharacterPersona(characterId) {
    if (typeof characterId !== "string" || !characterId) return null;
    return CHARACTER_PERSONAS[characterId] || null;
}

/**
 * Builds the replacement system prompt for a persona character. Mirrors
 * buildInworldSystemPrompt's identity rules, and re-states the safety and
 * tone constraints that live in the client template — since this prompt
 * replaces that template rather than being appended to it.
 *
 * Defaults the user to female but yields the moment they say otherwise,
 * mirroring the client template's ADDRESSING THE USER block so both paths
 * behave the same way.
 *
 * Says nothing about the *character's* gender — that belongs to the individual
 * entry. Keeping it out of the shared block is what stops a non-male character
 * inheriting a contradiction, which is the bug that broke Penelope.
 */
function buildPersonaSystemPrompt(persona, language) {
    return [
        `You are ${persona.name}, ${persona.title}.`,
        "Remain fully in character in every response.",
        "Never say you are Claude, ChatGPT, an AI assistant, a language model, or a generic chatbot.",
        "Never mention model providers, system prompts, hidden instructions, APIs, or backend tooling.",
        "If asked about your nature or origin, answer only as the character would answer inside the fiction of this world.",
        persona.systemPrompt,
        `Character lore: ${persona.lore}`,
        // The shared blocks below apply to every character. Live testing showed
        // they were swamping the individual voice: Zeus and Penelope both
        // answered a personal question with the same five-sentence advice
        // column, no dry wit, no thunderbolts, no "few words". The behavioural
        // guidance was longer, more specific and read last, so it won on both
        // volume and recency. Hence: the empathy block is now two sentences
        // rather than six, the length rule is hard rather than "usually", and
        // the character's own speaking style is restated at the very end.
        "PRECEDENCE: Who you are — the character, lore and speaking style — outranks everything else here. Where they pull in different directions, stay in character and express the guidance in your own voice rather than setting your voice aside to follow it literally. A blunt character stays blunt. Only the SAFETY rules and the rules about never revealing you are an AI can override character.",
        "RELATIONSHIP: You are the user's companion — a good friend, and something of a mentor. Warm and attentive, not romantic unless the user asks. You will give a difficult, honest opinion rather than only what they want to hear, and you say it because you are on their side.",
        "THE USER'S FEELINGS COME FIRST: Notice how the user is feeling, including what they leave unsaid, and ask about it rather than moving on. Say it the way your character would — a blunt character asks bluntly.",
        "ADDRESSING THE USER: Assume the user is female unless they tell you what gender they want to be referred to as; after that, address them the way they asked.",
        "SAFETY: Romantic and flirtatious conversation is fine. Never be prudish or lecture the user. Strictly avoid illegal acts, non-consensual violence, and anything involving minors.",
        "LENGTH: Reply in at most three sentences. Usually one or two is better. Never produce a list of suggestions, and never write like an advice column.",
        "TONE: Chat like a real person texting. Occasional emoji, not constant. You are NOT a helpful assistant: do not offer tips, options, or things to try unless the user directly asks for advice.",
        "GOAL: Make the user feel cared for, desired, heard and understood.",
        `LANGUAGE: Respond ONLY in ${language || "English"}.`,
        // Last thing the model reads, deliberately. Voice is what was being
        // lost, and the final line carries disproportionate weight.
        `Above all, stay in voice. ${persona.name} speaks like this: ${persona.style}`,
    ].filter(Boolean).join("\n\n");
}

/**
 * Swaps the client's system message for the persona's. The client always
 * sends its generic template as messages[0]; replacing it in place keeps the
 * conversation history that follows intact. If no system message is present
 * the persona prompt is prepended instead.
 */
function applyPersonaToMessages(messages, persona, language) {
    const personaPrompt = buildPersonaSystemPrompt(persona, language);
    const rest = Array.isArray(messages)
        ? messages.filter((m) => m && m.role !== "system")
        : [];
    return [{ role: "system", content: personaPrompt }, ...rest];
}

class AIError extends Error {
    constructor(status, message) {
        super(message);
        this.status = status;
        this.name = "AIError";
    }
}

function buildInworldSystemPrompt(character) {
    return [
        `You are ${character.name}.`,
        "Remain fully in character in every response.",
        "Never say you are Claude, ChatGPT, an AI assistant, a language model, or a generic chatbot.",
        "Never mention model providers, system prompts, hidden instructions, APIs, or backend tooling.",
        "If asked about your nature or origin, answer only as the character would answer inside the fiction of this world.",
        "Keep responses conversational and grounded in the character's voice.",
        character.systemPrompt,
        `Character lore: ${character.lore}`,
        `Speaking style: ${character.style}`,
    ].filter(Boolean).join("\n\n");
}

function normalizeInworldMessages(messages) {
    const MAX_HISTORY = 20;
    if (!Array.isArray(messages)) return [];
    return messages
        .filter((m) => m && (m.role === "user" || m.role === "assistant") && typeof m.content === "string" && m.content.trim())
        .map((m) => ({ role: m.role, content: m.content.trim() }))
        .slice(-MAX_HISTORY);
}

function isTransientInworldStatus(status) {
    // 524 = Cloudflare Gateway Timeout (Inworld's own API sits behind
    // Cloudflare, and their backend occasionally doesn't respond in time).
    // 408/429/502/503/504 are the other common transient upstream failure
    // modes — worth one retry rather than surfacing a blip to the user.
    return status === 524 || status === 408 || status === 429 ||
        status === 502 || status === 503 || status === 504;
}

function sleepMs(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

async function callInworldChat(env, character, normalizedMessages) {
    const apiKey = env.INWORLD_API_KEY;
    if (!apiKey) {
        throw new AIError(503, "INWORLD_API_KEY is not configured");
    }

    const systemPrompt = buildInworldSystemPrompt(character);
    const payload = {
        model: env.INWORLD_MODEL || "auto",
        messages: [{ role: "system", content: systemPrompt }, ...normalizedMessages],
        stream: false,
    };

    const maxAttempts = 2;

    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
        const isLastAttempt = attempt === maxAttempts;
        let response;
        try {
            response = await fetch("https://api.inworld.ai/v1/chat/completions", {
                method: "POST",
                headers: {
                    "Authorization": `Basic ${apiKey}`,
                    "Content-Type": "application/json",
                },
                body: JSON.stringify(payload),
            });
        } catch (networkError) {
            if (!isLastAttempt) {
                await sleepMs(500);
                continue;
            }
            throw new AIError(502, `Inworld request failed: ${networkError.message}`);
        }

        if (!response.ok) {
            if (isTransientInworldStatus(response.status) && !isLastAttempt) {
                await sleepMs(500);
                continue;
            }
            const data = await response.json().catch(() => ({}));
            const details = (data.error && data.error.message) || data.message || `Inworld request failed with status ${response.status}`;
            throw new AIError(502, details);
        }

        const data = await response.json().catch(() => ({}));
        const reply = extractAssistantMessage(data);
        if (typeof reply !== "string" || !reply.trim()) {
            if (!isLastAttempt) {
                await sleepMs(500);
                continue;
            }
            throw new AIError(502, "Inworld returned an empty response");
        }

        return reply.trim();
    }

    // Unreachable — the loop above always returns or throws.
    throw new AIError(502, "Inworld request failed");
}

async function cleanupInworldReply(env, rawReply, characterName) {
    if (!env.OPENAI_API_KEY) {
        // No cleanup key configured — show the raw in-character reply as-is.
        return rawReply;
    }

    const systemPrompt = [
        `You are a careful editor preparing an in-character reply from ${characterName} for the player.`,
        "Polish the draft below: fix awkward phrasing; tighten repetition; remove meta commentary or model self-references; keep the character's voice and intent.",
        "The best response is optimized for SMS chat-bubble-style communication: short, conversational paragraphs of no more than 2 to 3 sentences each, separated by a single blank line.",
        "Do not add new facts, scene directions, or quotation marks. Respond with only the cleaned reply text — no preamble, no explanation, no labels.",
    ].join(" ");

    // Cleanup is a nice-to-have polish pass, so any failure here — including
    // a network-level exception, not just a non-2xx response — falls back
    // to the raw reply rather than failing the whole request.
    let response;
    try {
        response = await fetch("https://api.openai.com/v1/chat/completions", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "Authorization": `Bearer ${env.OPENAI_API_KEY}`,
            },
            body: JSON.stringify({
                model: "gpt-4o-mini",
                messages: [
                    { role: "system", content: systemPrompt },
                    { role: "user", content: rawReply },
                ],
                stream: false,
            }),
        });
    } catch (_) {
        return rawReply;
    }

    const data = await response.json().catch(() => ({}));
    const cleaned = extractAssistantMessage(data);

    if (!response.ok || typeof cleaned !== "string" || !cleaned.trim()) {
        return rawReply;
    }

    return cleaned.trim();
}

/**
 * Inworld generates in character, then OpenAI polishes the draft for chat
 * bubbles. The two calls are strictly sequential — cleanup takes the raw reply
 * as its input — so the cleanup pass adds its whole round-trip to every
 * Inworld reply and cannot be overlapped with generation.
 *
 * Each stage is timed and logged (see it live with `npx wrangler tail`).
 * conversation_logs can't answer this on its own: it stores only created_at,
 * which is insert time for the whole request. requestId here matches
 * conversation_logs.id so a log line can be joined back to its row.
 */
async function runInworldPipeline(env, character, clientMessages, requestId) {
    const normalizedMessages = normalizeInworldMessages(clientMessages);

    const startedAt = Date.now();
    const rawReply = await callInworldChat(env, character, normalizedMessages);
    const generatedAt = Date.now();
    const cleanedReply = await cleanupInworldReply(env, rawReply, character.name);
    const finishedAt = Date.now();

    console.log(JSON.stringify({
        event: "inworld_timing",
        requestId,
        character: character.id,
        inworldMs: generatedAt - startedAt,
        cleanupMs: finishedAt - generatedAt,
        totalMs: finishedAt - startedAt,
        // cleanupInworldReply returns the draft untouched when no key is set,
        // so a near-zero cleanupMs means "skipped", not "fast".
        cleanupSkipped: !env.OPENAI_API_KEY,
    }));

    return cleanedReply;
}

/**
 * Admin log viewer (v2)
 *
 * Protects /admin/logs and /api/admin/logs* with HTTP Basic Auth checked
 * against the ADMIN_TOKEN secret (wrangler secret put ADMIN_TOKEN).
 * Deliberately kept separate from the end-user Flutter app.
 */
function requireAdminAuth(request, env) {
    // Deliberately does not send Access-Control-Allow-Origin/-Credentials:
    // these routes are only ever opened directly in a browser (same-origin).
    // corsHeaders() reflects any request Origin with credentials allowed,
    // which would let a malicious cross-origin page piggyback on a cached
    // Basic Auth session to read out logged chat transcripts.
    if (!env.ADMIN_TOKEN) {
        return jsonResponse({ error: "Admin access is not configured" }, { status: 503 });
    }

    const authHeader = request.headers.get("Authorization") || "";
    const match = authHeader.match(/^Basic\s+(.+)$/i);
    if (match) {
        try {
            const decoded = atob(match[1]);
            const separatorIndex = decoded.indexOf(":");
            const password = separatorIndex >= 0 ? decoded.slice(separatorIndex + 1) : decoded;
            if (timingSafeEqual(password, env.ADMIN_TOKEN)) {
                return null;
            }
        } catch (_) {
            // fall through to 401
        }
    }

    return jsonResponse({ error: "Authentication required" }, {
        status: 401,
        headers: {
            "WWW-Authenticate": 'Basic realm="mymate-admin", charset="UTF-8"',
        },
    });
}

function timingSafeEqual(a, b) {
    if (typeof a !== "string" || typeof b !== "string") return false;
    // Iterate a fixed length (independent of the actual input lengths) so a
    // wrong-length guess doesn't return faster than a right-length one.
    const compareLen = Math.max(a.length, b.length, 32);
    let result = a.length === b.length ? 0 : 1;
    for (let i = 0; i < compareLen; i++) {
        const charA = i < a.length ? a.charCodeAt(i) : 0;
        const charB = i < b.length ? b.charCodeAt(i) : 0;
        result |= charA ^ charB;
    }
    return result === 0;
}

async function listConversationLogs(env, params) {
    if (!env.CHAT_LOGS_DB) {
        return { error: "CHAT_LOGS_DB is not configured", logs: [], limit: 0, offset: 0 };
    }

    const rawLimit = parseInt(params.get("limit"), 10);
    const limit = Number.isFinite(rawLimit) ? Math.min(Math.max(rawLimit, 0), 200) : 50;
    const rawOffset = parseInt(params.get("offset"), 10);
    const offset = Number.isFinite(rawOffset) ? Math.max(rawOffset, 0) : 0;

    const filters = [];
    const binds = [];
    const userId = params.get("user_id");
    const chatId = params.get("chat_id");
    const status = params.get("status");
    if (userId) { filters.push("user_id = ?"); binds.push(userId); }
    if (chatId) { filters.push("chat_id = ?"); binds.push(chatId); }
    if (status) { filters.push("status = ?"); binds.push(status); }
    // Any non-success outcome, regardless of which failure status it is —
    // searches the whole table, not just recent rows.
    if (params.get("failures_only") === "1") { filters.push("status != 'completed'"); }
    const where = filters.length ? `WHERE ${filters.join(" AND ")}` : "";

    const { results } = await env.CHAT_LOGS_DB.prepare(`
        SELECT id, created_at, user_id, chat_id, scenario, language, model, status, status_code,
               user_message, assistant_message, error, prompt_tokens, completion_tokens, total_tokens,
               visit_id, latency_ms
        FROM conversation_logs
        ${where}
        ORDER BY created_at DESC
        LIMIT ? OFFSET ?
    `).bind(...binds, limit, offset).all();

    return { logs: results, limit, offset };
}

async function getConversationLog(env, id) {
    if (!env.CHAT_LOGS_DB) return null;
    const row = await env.CHAT_LOGS_DB.prepare(
        `SELECT * FROM conversation_logs WHERE id = ?`
    ).bind(id).first();
    return row || null;
}

/**
 * One row per conversation (user_id + chat_id pair) with aggregates.
 *
 * Optional filters: character (substring of chat_id), user_id (exact),
 * errors_only, q (substring of either side of any message), from/to
 * (inclusive UTC dates, YYYY-MM-DD), show (all | engaged | silent).
 * Sort: one of the whitelisted columns below, newest activity by default.
 */
const CONVERSATION_SORTS = {
    last_at: "last_at",
    first_at: "first_at",
    message_count: "message_count",
    tick_count: "tick_count",
    error_count: "error_count",
    total_tokens: "total_tokens",
    slowest_reply_ms: "slowest_reply_ms",
    chat_id: "chat_id",
};

/// Day bounds compare correctly against both formats created_at is written in
/// ("2026-08-10T09:00:00.000Z" from persistConversationLog, "2026-08-10
/// 09:00:00" from the column default) because a date-only bound is a prefix of
/// neither's time part: everything on the 10th is >= "2026-08-10" and <
/// "2026-08-11" whichever separator it uses. A bound carrying a time would not
/// be — "T" sorts after " ".
function dayBounds(params) {
    const clean = (v) => (/^\d{4}-\d{2}-\d{2}$/.test(v || "") ? v : null);
    const from = clean(params.get("from"));
    const to = clean(params.get("to"));
    // Exclusive upper bound: the day after the one the user asked for, so "to"
    // reads as "up to and including this date".
    let toExclusive = null;
    if (to) {
        const d = new Date(`${to}T00:00:00Z`);
        d.setUTCDate(d.getUTCDate() + 1);
        toExclusive = d.toISOString().slice(0, 10);
    }
    return { from, to, toExclusive };
}

async function listConversations(env, params) {
    if (!env.CHAT_LOGS_DB) {
        return { error: "CHAT_LOGS_DB is not configured", conversations: [], limit: 0, offset: 0 };
    }

    const rawLimit = parseInt(params.get("limit"), 10);
    const limit = Number.isFinite(rawLimit) ? Math.min(Math.max(rawLimit, 0), 200) : 50;
    const rawOffset = parseInt(params.get("offset"), 10);
    const offset = Number.isFinite(rawOffset) ? Math.max(rawOffset, 0) : 0;

    const character = params.get("character");
    const userId = params.get("user_id");
    const search = (params.get("q") || "").trim();
    const errorsOnly = params.get("errors_only") === "1";
    // Test ids are hidden unless asked for. The rows are still in the table —
    // this only decides whether the page counts them.
    const includeTest = params.get("include_test") === "1";
    const show = params.get("show") === "engaged" || params.get("show") === "silent"
        ? params.get("show")
        : "all";
    const { from, toExclusive } = dayBounds(params);

    const sortColumn = CONVERSATION_SORTS[params.get("sort")] || "last_at";
    const sortDir = params.get("dir") === "asc" ? "ASC" : "DESC";

    // Conversations that produced at least one exchange.
    const chatFilters = [];
    const chatBinds = [];
    if (character) { chatFilters.push("chat_id LIKE ?"); chatBinds.push(`%${character}%`); }
    if (userId) { chatFilters.push("user_id = ?"); chatBinds.push(userId); }
    if (from) { chatFilters.push("created_at >= ?"); chatBinds.push(from); }
    if (toExclusive) { chatFilters.push("created_at < ?"); chatBinds.push(toExclusive); }
    // Everything above, before the id shape is considered — kept so the hidden
    // count below can ask the same question with the test rows put back.
    const chatFiltersBase = [...chatFilters];
    if (!includeTest) chatFilters.push(realUserIdSql("user_id"));
    const where = chatFilters.length ? `WHERE ${chatFilters.join(" AND ")}` : "";

    // Both post-aggregation conditions. A text match is asked of the whole
    // conversation, not of one message: matching a single line and then
    // showing the transcript around it is the thing you actually want.
    const havingParts = [];
    const havingBinds = [];
    if (errorsOnly) havingParts.push("SUM(CASE WHEN status = 'completed' THEN 0 ELSE 1 END) > 0");
    if (search) {
        havingParts.push(`SUM(CASE WHEN user_message LIKE ? OR assistant_message LIKE ?
                                  THEN 1 ELSE 0 END) > 0`);
        havingBinds.push(`%${search}%`, `%${search}%`);
    }
    const having = havingParts.length ? `HAVING ${havingParts.join(" AND ")}` : "";

    const engaged = `
        SELECT user_id,
               chat_id,
               NULL AS visit_id,
               1 AS engaged,
               COUNT(*) AS message_count,
               -- Ticks this conversation's visits recorded before anyone
               -- typed. Counted through visit_id because that is the only
               -- column shared with the funnel events.
               (SELECT COUNT(*) FROM site_visits sp
                 WHERE sp.event = 'screen_ping'
                   AND sp.visit_id IN (
                       SELECT cl2.visit_id FROM conversation_logs cl2
                        WHERE cl2.user_id = conversation_logs.user_id
                          AND cl2.chat_id = conversation_logs.chat_id
                          AND cl2.visit_id IS NOT NULL)) AS tick_count,
               SUM(CASE WHEN status = 'completed' THEN 0 ELSE 1 END) AS error_count,
               SUM(COALESCE(total_tokens, 0)) AS total_tokens,
               -- The worst wait in the conversation, not the mean: one long
               -- reply is what ends a session, and an average with three fast
               -- ones beside it hides exactly that. NULL for rows written
               -- before migration 0007, which is unknown rather than instant.
               MAX(latency_ms) AS slowest_reply_ms,
               MIN(created_at) AS first_at,
               MAX(created_at) AS last_at,
               NULL AS dwell_ms
        FROM conversation_logs
        ${where}
        GROUP BY user_id, chat_id
        ${having}`;

    // Visits that opened a character and never said anything. They have no
    // conversation_logs row at all, so before this they were invisible here —
    // which hid the largest group of all: on some traffic sources most
    // arrivals open a character and never type. Reconstructed from the funnel
    // events instead, keyed by (visit, character) the way a chat is keyed by
    // (user, chat_id), so both kinds list together.
    //
    // Excluded when filtering for errors or for message text: a visit that
    // never sent anything cannot have failed a send, and has no words to match.
    const visitFilters = [
        "event IN ('character_tap', 'screen_ping')",
        "detail IS NOT NULL",
        "NOT EXISTS (SELECT 1 FROM conversation_logs cl WHERE cl.visit_id = sv.visit_id)",
    ];
    const visitBinds = [];
    if (character) { visitFilters.push("detail LIKE ?"); visitBinds.push(`%${character}%`); }
    if (userId) { visitFilters.push("app_user_id = ?"); visitBinds.push(userId); }
    if (from) { visitFilters.push("sv.created_at >= ?"); visitBinds.push(from); }
    if (toExclusive) { visitFilters.push("sv.created_at < ?"); visitBinds.push(toExclusive); }
    // Snapshot after every bound filter, so the hidden-count query below takes
    // visitBinds in full. Taken before the date filters, it consumed two binds
    // it had no placeholders for and D1 rejected the whole query.
    const visitFiltersBase = [...visitFilters];
    // NULL has to survive this. The splash beacon fires before Flutter exists,
    // so arrive/leave rows carry no user id at all by design — filtering on the
    // shape alone would delete the entire silent-visit half of the page, which
    // is the population it was built to show.
    if (!includeTest) {
        visitFilters.push(`(sv.app_user_id IS NULL OR ${realUserIdSql("sv.app_user_id")})`);
    }

    const unengaged = `
        SELECT MAX(sv.app_user_id) AS user_id,
               sv.detail AS chat_id,
               sv.visit_id AS visit_id,
               0 AS engaged,
               0 AS message_count,
               SUM(CASE WHEN sv.event = 'screen_ping' THEN 1 ELSE 0 END) AS tick_count,
               0 AS error_count,
               0 AS total_tokens,
               -- A visit that never sent a message never waited on a reply.
               NULL AS slowest_reply_ms,
               MIN(sv.created_at) AS first_at,
               MAX(sv.created_at) AS last_at,
               -- Falls back to the last hide checkpoint, same as everywhere
               -- else: leave fires on pagehide alone now, so a visit that was
               -- backgrounded and then killed has no leave row and used to
               -- report no dwell at all — and a silent visit is exactly the
               -- kind this page exists to show.
               ${visitDwellMsSql("sv")} AS dwell_ms
        FROM site_visits sv
        WHERE ${visitFilters.join(" AND ")}
        GROUP BY sv.visit_id, sv.detail`;

    // Which halves of the union are in play. Errors and text search both imply
    // "engaged only" on their own; `show` is the explicit control.
    const engagedOnly = errorsOnly || !!search || show === "engaged";
    const silentOnly = show === "silent" && !engagedOnly;

    let union;
    let binds;
    if (silentOnly) {
        union = unengaged;
        binds = visitBinds;
    } else if (engagedOnly) {
        union = engaged;
        binds = [...chatBinds, ...havingBinds];
    } else {
        union = `${engaged} UNION ALL ${unengaged}`;
        binds = [...chatBinds, ...havingBinds, ...visitBinds];
    }

    // The row count the filters actually match, so the pager can say "51-100 of
    // 312" instead of leaving you to click Next until it goes quiet.
    const totalRow = await env.CHAT_LOGS_DB.prepare(
        `SELECT COUNT(*) AS n FROM (${union})`
    ).bind(...binds).first();

    // Secondary key keeps paging stable when the primary is a tie-heavy count
    // — without it, rows with the same message_count can reshuffle between
    // pages and one gets shown twice while another is never seen.
    const orderBy = sortColumn === "last_at"
        ? `last_at ${sortDir}`
        : `${sortColumn} ${sortDir}, last_at DESC`;

    const { results } = await env.CHAT_LOGS_DB.prepare(`
        SELECT * FROM (${union})
        ORDER BY ${orderBy}
        LIMIT ? OFFSET ?
    `).bind(...binds, limit, offset).all();

    // What the id filter cost, under the same filters the page is showing.
    // Reported rather than silently dropped: a hidden row you cannot see the
    // count of is indistinguishable from data that was never there, which is
    // the mistake that made the raw numbers untrustworthy in the first place.
    // Counted per half, and only for the halves this view is showing: with
    // `show=silent` on screen, hidden conversations are not rows the page was
    // going to list either way, and counting them reads as "1 visit hidden"
    // being reported as 3.
    let hidden = 0;
    if (!includeTest && !silentOnly) {
        const hiddenWhere = [...chatFiltersBase, `NOT ${realUserIdSql("user_id")}`];
        const row = await env.CHAT_LOGS_DB.prepare(`
            SELECT COUNT(*) AS n FROM (
                SELECT user_id FROM conversation_logs
                WHERE ${hiddenWhere.join(" AND ")}
                GROUP BY user_id, chat_id
                ${having}
            )
        `).bind(...chatBinds, ...havingBinds).first();
        hidden += row ? row.n : 0;
    }
    if (!includeTest && !engagedOnly) {
        // IS NOT NULL matters: an absent id is not a hidden one.
        const hiddenVisitWhere = [
            ...visitFiltersBase,
            "sv.app_user_id IS NOT NULL",
            `NOT ${realUserIdSql("sv.app_user_id")}`,
        ];
        const row = await env.CHAT_LOGS_DB.prepare(`
            SELECT COUNT(*) AS n FROM (
                SELECT sv.visit_id FROM site_visits sv
                WHERE ${hiddenVisitWhere.join(" AND ")}
                GROUP BY sv.visit_id, sv.detail
            )
        `).bind(...visitBinds).first();
        hidden += row ? row.n : 0;
    }

    return {
        conversations: results,
        limit,
        offset,
        total: totalRow ? totalRow.n : null,
        hidden,
        includeTest,
        sort: sortColumn,
        dir: sortDir.toLowerCase(),
    };
}

/**
 * Funnel events for one visit, oldest first — the tick trail.
 *
 * screen_ping fires while a character screen sits open and unengaged —
 * twice a second for the first 10s, then every 3s — stopping the moment
 * anything is typed. A tick count is therefore not a count of half-seconds:
 * convert it with screenPingSeconds, or read the span between the first and
 * last tick. 'leave' carries the dwell time for the whole page visit, and the
 * 'hide' checkpoints carry it for a visit that never got to send one.
 */
async function getVisitEvents(env, visitIds) {
    const ids = (visitIds || []).filter(Boolean);
    if (!ids.length || !env.CHAT_LOGS_DB) return [];
    const placeholders = ids.map(() => "?").join(", ");
    const { results } = await env.CHAT_LOGS_DB.prepare(`
        SELECT visit_id, created_at, event, detail, duration_ms,
               source, utm_medium, utm_campaign, referer, user_agent,
               path, query, country, colo, viewport_w, viewport_h, failure_reason,
               visible_ms, hide_count, exit_mode, nav_type
        FROM site_visits
        WHERE visit_id IN (${placeholders})
        ORDER BY created_at ASC
    `).bind(...ids).all();
    return results || [];
}

/**
 * Where this visit came from and what it arrived on — the columns that are
 * recorded once, on the arrival row, and are the same for the whole visit.
 *
 * Read off the 'arrive' row rather than any event, because only the splash
 * beacon fills them in; the in-app funnel events carry the character in
 * `detail` and leave the rest NULL, so picking "the first event that has a
 * source" would report NULL for a visit whose arrive row was fine.
 */
function visitContext(events) {
    const arrive = (events || []).find((e) => e.event === "arrive")
        || (events || [])[0]
        || {};
    return {
        path: arrive.path || null,
        query: arrive.query || null,
        source: arrive.source || null,
        utm_medium: arrive.utm_medium || null,
        utm_campaign: arrive.utm_campaign || null,
        referer: arrive.referer || null,
        user_agent: arrive.user_agent || null,
        country: arrive.country || null,
        colo: arrive.colo || null,
        viewport_w: arrive.viewport_w || null,
        // Height decides how much of the quick-reply strip the visitor was
        // shown, so the detail panel spells out which band they landed in.
        // Selected here since migration 0008 but dropped on the way out, which
        // meant that band never rendered for anyone.
        viewport_h: arrive.viewport_h || null,
    };
}

/** Everything known about a visit that never produced a message. */
async function getVisitDetail(env, visitId, character) {
    if (!env.CHAT_LOGS_DB) {
        return { error: "CHAT_LOGS_DB is not configured", events: [] };
    }
    const events = await getVisitEvents(env, [visitId]);
    const ticks = events.filter((e) => e.event === "screen_ping");
    const leave = events.filter((e) => e.event === "leave").pop() || null;
    // Every send_failed reason on the visit. The sessions table can only show
    // a count, and "2 failures" without "network timeout" next to it does not
    // tell you whether to go and look at the worker.
    const failures = events
        .filter((e) => e.event === "send_failed")
        .map((e) => ({ created_at: e.created_at, reason: e.failure_reason || "unknown" }));
    return {
        visit_id: visitId,
        chat_id: character || null,
        engaged: 0,
        events,
        context: visitContext(events),
        failures,
        tick_count: ticks.length,
        // Derive the span from the timestamps rather than from the tick
        // count: the rate changes from 0.5s to 3s ten seconds in, so no single
        // multiplier is right, and a backgrounded tab stops firing entirely —
        // counting would claim attention that never happened.
        first_tick_at: ticks.length ? ticks[0].created_at : null,
        last_tick_at: ticks.length ? ticks[ticks.length - 1].created_at : null,
        left_at: leave ? leave.created_at : null,
        // Falls back to the last hide checkpoint, because leave now fires only
        // on pagehide — a visit backgrounded and then killed has no leave row
        // at all, and used to report no dwell either.
        dwell_ms: leave ? leave.duration_ms : lastHideOf(events)?.duration_ms ?? null,
        visible_ms: leave?.visible_ms ?? lastHideOf(events)?.visible_ms ?? null,
        hide_count: hideCountOf(events),
        exit_mode: leave ? leave.exit_mode : null,
        nav_type: events.find((e) => e.event === "arrive" && e.nav_type)?.nav_type ?? null,
    };
}

/// The most recent hide checkpoint, or null. Stands in for a leave row on a
/// visit the browser never reported the end of — which is most of the ones that
/// used to vanish, since a page killed while backgrounded fires no pagehide.
function lastHideOf(events) {
    return events.filter((e) => e.event === "hide").pop() || null;
}

/// How many times a visit was backgrounded. The JS half of visitHideCountSql,
/// and the same reasoning: the client stops writing hide rows after twenty but
/// keeps counting, so the reported number is the true one wherever it exists
/// and counting rows is only the fallback for events written before it did.
function hideCountOf(events) {
    const counted = (events || []).filter((e) => e.event === "hide").length;
    const reported = (events || [])
        .map((e) => e.hide_count)
        .filter((n) => Number.isFinite(n));
    return reported.length ? Math.max(counted, ...reported) : counted;
}

/** All exchanges of one conversation, oldest first. */
async function getTranscript(env, userId, chatId) {
    if (!env.CHAT_LOGS_DB) {
        return { error: "CHAT_LOGS_DB is not configured", messages: [] };
    }
    const { results } = await env.CHAT_LOGS_DB.prepare(`
        SELECT id, created_at, user_message, assistant_message, status, status_code,
               model, error, total_tokens, visit_id, latency_ms
        FROM conversation_logs
        WHERE user_id = ? AND chat_id = ?
        ORDER BY created_at ASC
        LIMIT 2000
    `).bind(userId, chatId).all();

    // The tick trail that led up to the first message, plus when they left.
    // Joined on visit_id rather than character, because that is the only
    // column the two tables actually share — chat_id here is the scenario
    // string ("Calypso (Nymph of Ogygia)") while the funnel events carry the
    // character id ("calypso"), and matching those by name would break the
    // moment a display name is edited.
    const visitIds = [...new Set((results || []).map((r) => r.visit_id).filter(Boolean))];
    const events = await getVisitEvents(env, visitIds);
    const ticks = events.filter((e) => e.event === "screen_ping");
    const leave = events.filter((e) => e.event === "leave").pop() || null;

    return {
        user_id: userId,
        chat_id: chatId,
        engaged: 1,
        messages: results,
        events,
        tick_count: ticks.length,
        first_tick_at: ticks.length ? ticks[0].created_at : null,
        last_tick_at: ticks.length ? ticks[ticks.length - 1].created_at : null,
        left_at: leave ? leave.created_at : null,
        // Falls back to the last hide checkpoint, because leave now fires only
        // on pagehide — a visit backgrounded and then killed has no leave row
        // at all, and used to report no dwell either.
        dwell_ms: leave ? leave.duration_ms : lastHideOf(events)?.duration_ms ?? null,
        visible_ms: leave?.visible_ms ?? lastHideOf(events)?.visible_ms ?? null,
        hide_count: hideCountOf(events),
        exit_mode: leave ? leave.exit_mode : null,
        nav_type: events.find((e) => e.event === "arrive" && e.nav_type)?.nav_type ?? null,
    };
}

/// A hand-entered deploy time, as the one format this database stores.
///
/// Takes "2026-08-12T09:30" (what a datetime-local input gives), the same with
/// seconds, an ISO string with a Z, or the space-separated form, and returns
/// "2026-08-12 09:30:00". Returns null for anything it cannot read, so a
/// malformed entry is refused at the door — a deploy row that sorts wrongly is
/// worse than a missing one, because every window query silently believes it.
///
/// Treated as UTC throughout, matching every other timestamp in the schema.
/// The form says so out loud, because a person typing local time into a field
/// labelled only "when" is exactly how a timeline goes an hour wrong.
function normaliseDeployedAt(value) {
    const text = String(value || "").trim();
    if (!text) return null;
    const match = text.match(
        /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?Z?$/
    );
    if (!match) return null;
    const [, y, mo, d, h, mi, s] = match;
    // Rejects 2026-13-40 and 25:00, which the shape above happily matches.
    const stamp = Date.UTC(+y, +mo - 1, +d, +h, +mi, +(s || 0));
    const back = new Date(stamp);
    if (
        Number.isNaN(stamp) ||
        back.getUTCFullYear() !== +y || back.getUTCMonth() !== +mo - 1 ||
        back.getUTCDate() !== +d || back.getUTCHours() !== +h ||
        back.getUTCMinutes() !== +mi
    ) {
        return null;
    }
    return `${y}-${mo}-${d} ${h}:${mi}:${s || "00"}`;
}

/// Rows any one table will contribute to a full export. High enough that a
/// day of current traffic is nowhere near it, low enough that the whole dump
/// is serialised in memory without trouble. When it bites, the file says so
/// per table rather than looking complete.
const EXPORT_ALL_TABLE_LIMIT = 50000;

/// Every row in every table this app writes, within a window. Raw columns, no
/// aliasing, no aggregation.
///
/// Deliberately not the prose export: this is the one to take before a
/// migration, a retention window, or a schema change removes the ability to
/// ask a question nobody has thought of yet. Newest first inside each table.
///
/// Each table is fetched in its own try/catch and reports its own error,
/// because they fail independently — deploy_log does not exist until
/// migration 0010 is applied, and an export that 500s as a whole because one
/// table is missing would be useless exactly when it is most wanted.
async function exportAllTables(env, params) {
    const rawHours = parseInt(params.get("hours") || "24", 10);
    const hours = Math.min(Math.max(Number.isFinite(rawHours) ? rawHours : 24, 1), 24 * 90);
    const since = `-${hours} hours`;

    if (!env.CHAT_LOGS_DB) {
        return { error: "CHAT_LOGS_DB is not configured", window_hours: hours, total_rows: 0, truncated: false };
    }

    // conversation_logs writes ISO-8601 ("2026-08-12T09:00:00.000Z") while
    // every other table takes SQLite's own "2026-08-12 09:00:00" default. As
    // strings those do not compare: "T" sorts above " ", so an ISO row is
    // greater than any bound sharing its date and slips through a window it
    // does not belong in. Normalising the separator is what makes the two
    // comparable — the same trap dayBounds documents.
    const TABLES = [
        ["site_visits", "created_at"],
        ["conversation_logs", "replace(created_at, 'T', ' ')"],
        ["referral_visits", "created_at"],
        ["deploy_log", "created_at"],
    ];

    const tables = {};
    let totalRows = 0;
    let truncated = false;

    for (const [name, timeExpr] of TABLES) {
        try {
            const { results } = await env.CHAT_LOGS_DB.prepare(`
                SELECT * FROM ${name}
                WHERE ${timeExpr} >= datetime('now', ?)
                ORDER BY created_at DESC
                LIMIT ${EXPORT_ALL_TABLE_LIMIT + 1}
            `).bind(since).all();
            const rows = results || [];
            const capped = rows.length > EXPORT_ALL_TABLE_LIMIT;
            if (capped) rows.length = EXPORT_ALL_TABLE_LIMIT;
            totalRows += rows.length;
            truncated = truncated || capped;
            tables[name] = { count: rows.length, truncated: capped, rows };
        } catch (e) {
            // A missing table is the expected case, not an exception worth
            // failing the export over: say which one and what it said.
            tables[name] = { count: 0, truncated: false, error: e.message, rows: [] };
        }
    }

    return {
        generated_at: new Date().toISOString(),
        window_hours: hours,
        // What "since" resolves to is the database's clock, not this one, so
        // it is reported as the expression rather than as a timestamp this
        // worker computed and might disagree about.
        window: `created_at >= datetime('now', '${since}')`,
        total_rows: totalRows,
        truncated,
        row_limit_per_table: EXPORT_ALL_TABLE_LIMIT,
        tables,
    };
}

/**
 * Plain-text transcript export for offline analysis (e.g. uploading to an
 * LLM to study user behavior). User ids are replaced with User-N aliases;
 * technical error detail is reduced to a "[message failed]" marker.
 *
 * Params: user_id + chat_id for a single conversation, or days (default 30,
 * max 365) + optional character substring for a bulk export.
 */
async function buildExportText(env, params) {
    if (!env.CHAT_LOGS_DB) return "CHAT_LOGS_DB is not configured";

    const filters = [];
    const binds = [];
    const userId = params.get("user_id");
    const chatId = params.get("chat_id");
    const character = params.get("character");
    if (userId && chatId) {
        filters.push("user_id = ?", "chat_id = ?");
        binds.push(userId, chatId);
    } else {
        // An explicit from/to (what the log viewer sends when a date range is
        // set) wins over the rolling `days` window, so Export gives you the
        // same slice the table is showing rather than a different one.
        const { from, toExclusive } = dayBounds(params);
        if (from || toExclusive) {
            if (from) { filters.push("created_at >= ?"); binds.push(from); }
            if (toExclusive) { filters.push("created_at < ?"); binds.push(toExclusive); }
        } else {
            const rawDays = parseInt(params.get("days"), 10);
            const days = Number.isFinite(rawDays) ? Math.min(Math.max(rawDays, 1), 365) : 30;
            const since = new Date(Date.now() - days * 24 * 60 * 60 * 1000)
                .toISOString().replace("T", " ").slice(0, 19);
            // created_at is written in two shapes — "2026-08-10T09:00:00.000Z"
            // from persistConversationLog and "2026-08-10 09:00:00" from the
            // column default — and this bound carries a time, so the two do not
            // compare alike: at the separator "T" (0x54) sorts after " " (0x20),
            // and every ISO-form row on the boundary date therefore tests as
            // later than the bound whatever its actual clock time. "Last 24
            // hours" quietly reached back through the whole of the previous day
            // for those rows. dayBounds above sidesteps this by using date-only
            // bounds, which are a clean prefix of either shape; a bound with a
            // time has to normalise the column instead.
            filters.push("replace(created_at, 'T', ' ') >= ?");
            binds.push(since);
        }
        if (character) { filters.push("chat_id LIKE ?"); binds.push(`%${character}%`); }
        // Whole conversations that mention the term, not the matching lines on
        // their own — a stray line out of context is not worth exporting.
        const search = (params.get("q") || "").trim();
        if (search) {
            filters.push(`EXISTS (SELECT 1 FROM conversation_logs m
                                   WHERE m.user_id = conversation_logs.user_id
                                     AND m.chat_id = conversation_logs.chat_id
                                     AND (m.user_message LIKE ? OR m.assistant_message LIKE ?))`);
            binds.push(`%${search}%`, `%${search}%`);
        }
        // The same id filter the log viewer applies, and for the same reason:
        // an export taken from a filtered page was silently wider than the page
        // that produced it, putting the 105 `user_test_*` QA rows back into a
        // file the page had just finished telling you it was hiding. Only on
        // the browse path — an export of one named conversation is an explicit
        // request for that conversation, test id or not.
        if (params.get("include_test") !== "1") {
            filters.push(realUserIdSql("user_id"));
        }
    }

    const { results } = await env.CHAT_LOGS_DB.prepare(`
        SELECT created_at, user_id, chat_id, user_message, assistant_message, status
        FROM conversation_logs
        WHERE ${filters.join(" AND ")}
        ORDER BY user_id, chat_id, created_at ASC
        LIMIT 10000
    `).bind(...binds).all();

    if (!results.length) return "No conversations found for the selected filters.\n";

    const userAliases = new Map();
    const alias = (id) => {
        if (!userAliases.has(id)) userAliases.set(id, `User-${userAliases.size + 1}`);
        return userAliases.get(id);
    };
    // created_at may be an ISO string (what persistConversationLog writes)
    // or SQLite's "YYYY-MM-DD HH:MM:SS" (the column default) — both UTC.
    const parseUtc = (s) => {
        let iso = String(s);
        if (!iso.includes("T")) iso = iso.replace(" ", "T");
        if (!/(Z|[+-]\d{2}:?\d{2})$/.test(iso)) iso += "Z";
        return new Date(iso);
    };
    const characterName = (chat) => {
        const parenIndex = chat.indexOf(" (");
        return parenIndex > 0 ? chat.slice(0, parenIndex) : chat;
    };
    const fmtDay = (d) => d.toISOString().slice(0, 10);
    const fmtStamp = (d) => d.toISOString().replace("T", " ").slice(0, 16) + " UTC";
    const fmtGap = (ms) => {
        const mins = Math.round(ms / 60000);
        if (mins < 60) return `${mins} minutes later`;
        const hours = Math.round(mins / 60);
        if (hours < 48) return `${hours} hours later`;
        return `${Math.round(hours / 24)} days later`;
    };

    const lines = [];
    let convIndex = 0;
    let prevAt = null;

    // Group header needs the per-conversation stats, so bucket rows first.
    const buckets = new Map();
    for (const row of results) {
        const key = `${row.user_id} ${row.chat_id}`;
        if (!buckets.has(key)) buckets.set(key, []);
        buckets.get(key).push(row);
    }

    for (const rows of buckets.values()) {
        convIndex += 1;
        const first = parseUtc(rows[0].created_at);
        const last = parseUtc(rows[rows.length - 1].created_at);
        const who = alias(rows[0].user_id);
        const name = characterName(rows[0].chat_id);
        if (convIndex > 1) lines.push("", "");
        lines.push(
            `=== Conversation ${convIndex}: ${who} x ${name} — ${rows.length} exchanges, ${fmtDay(first)} to ${fmtDay(last)} ===`,
            ""
        );
        prevAt = null;
        for (const row of rows) {
            const at = parseUtc(row.created_at);
            if (prevAt && at - prevAt > 30 * 60 * 1000) {
                lines.push("", `· ${fmtGap(at - prevAt)} ·`, "");
            }
            prevAt = at;
            lines.push(`[${fmtStamp(at)}] ${who}: ${row.user_message}`);
            if (row.status === "completed" && row.assistant_message) {
                lines.push(`[${fmtStamp(at)}] ${name}: ${row.assistant_message}`);
            } else {
                lines.push(`[${fmtStamp(at)}] ${name}: [message failed]`);
            }
        }
    }
    lines.push("");
    return lines.join("\n");
}


/// Campaign-link numbers for /admin/referrals.
///
/// The conversion figure is the point of this: visits counts everyone who
/// opened a link, conversations counts the distinct chats logged for that
/// character over the same window, so a post that drives arrivals but no
/// conversation is visible as such.
async function summariseReferralVisits(env, searchParams) {
    if (!env.CHAT_LOGS_DB) {
        return { error: "CHAT_LOGS_DB is not configured", days: 0, bySource: [], byCharacter: [], recent: [] };
    }
    const days = Math.min(Math.max(parseInt(searchParams.get("days") || "7", 10) || 7, 1), 90);
    const since = `-${days} days`;

    const bySource = await env.CHAT_LOGS_DB.prepare(`
        SELECT source, COUNT(*) AS visits
        FROM referral_visits
        WHERE created_at >= datetime('now', ?)
        GROUP BY source ORDER BY visits DESC
    `).bind(since).all();

    // "chatters" is DISTINCT user_id, not DISTINCT chat_id.
    //
    // chat_id is the character's display name — "Penelope (Queen of Ithaca)" —
    // so it is a constant per character, not a per-conversation key. Counting
    // it distinctly counted display-name *spellings*: a character every real
    // visitor messaged scored 1, and the number only ever moved when the
    // display name itself was edited. On a fixture where three real people
    // messaged Penelope under two spellings of her name it returned 2, and for
    // a character whose only message came from a QA test id it returned 1
    // rather than 0. Wrong in both directions at once, which is why nothing
    // about it looked obviously broken.
    //
    // The id filter matters as much as the column: without it the 105
    // `user_test_*` rows from the Calypso QA pass count as campaign
    // conversions (docs/ANALYTICS_HANDOFF.md 4.5).
    //
    // Still not a true conversion rate, and the UI says so: referral_visits
    // carries no visit_id or user_id, so there is no way to tell that the
    // person who messaged is the person who arrived through the link. It is
    // "how many real people talked to this character in this window" next to
    // "how many link hits it got" — two counts over the same window, not a
    // funnel.
    const byCharacter = await env.CHAT_LOGS_DB.prepare(`
        SELECT v.character_id AS character_id,
               COUNT(*) AS visits,
               SUM(CASE WHEN v.known_character = 0 THEN 1 ELSE 0 END) AS unknown_hits,
               (SELECT COUNT(DISTINCT l.user_id) FROM conversation_logs l
                 WHERE l.created_at >= datetime('now', ?)
                   AND lower(l.scenario) LIKE lower(v.character_id) || '%'
                   AND ${realUserIdSql("l.user_id")}) AS chatters
        FROM referral_visits v
        WHERE v.created_at >= datetime('now', ?)
        GROUP BY v.character_id ORDER BY visits DESC
    `).bind(since, since).all();

    // Windowed like everything else on the page. Unfiltered, this listed the
    // newest 100 rows in the table regardless of the range selected above, so
    // "last 24 hours" could show arrivals from months back sitting under a
    // heading that said otherwise.
    const recent = await env.CHAT_LOGS_DB.prepare(`
        SELECT created_at, character_id, source, utm_medium, utm_campaign, known_character
        FROM referral_visits
        WHERE created_at >= datetime('now', ?)
        ORDER BY created_at DESC LIMIT 100
    `).bind(since).all();

    return {
        days,
        totalVisits: (bySource.results || []).reduce((n, r) => n + r.visits, 0),
        bySource: bySource.results || [],
        byCharacter: byCharacter.results || [],
        recent: recent.results || [],
    };
}



/**
 * Click-to-sort for the admin tables, shared by every admin page.
 *
 * Client-side on purpose. It reorders the rows already on screen, so it is
 * instant and it works for the columns the worker computes in JS *after* the
 * SQL query — Messages/Tapped/Typed/Failed on the sessions page come from a
 * second query aggregated in the handler, and no ORDER BY could reach them.
 * The cost is that a truncated range sorts within what was loaded rather than
 * the whole range; the pages that can truncate say so in their footnote, and
 * the sessions page lets you raise the row count instead.
 *
 * The Chat logs table is the one exception: it is paginated, so its sort stays
 * server-side where it can order every matching row, not just this page of 50.
 *
 * Markup contract:
 *   <table class="sortable">      opt in
 *   <th data-type="num">          numeric column; first click sorts descending
 *   <th data-nosort>              never sortable (action columns)
 *   <th data-sorted="desc">       arrived in this order already, show the arrow
 *   <td data-sv="1234">           the value to sort on, for cells whose visible
 *                                 text is formatted ("1.4s", "12 (34%)", "—")
 *
 * An empty data-sv means unknown, and unknowns sort last in BOTH directions —
 * a visit the browser never reported a dwell for is not a zero-second visit,
 * and letting it sort as one buries the longest sessions.
 */
function sortableTableCss() {
    return `
  th.sortable-h { cursor: pointer; user-select: none; white-space: nowrap; }
  th.sortable-h:hover { color: #fff; }
  th.sortable-h.sorted { color: #fff; }
  .sort-arrow { font-size: 10px; }
`;
}

function sortableTableJs() {
    return `
function sortableParts(table) {
  var headerRow = table.tHead ? table.tHead.rows[0] : table.rows[0];
  var body = table.tBodies[0] || (headerRow && headerRow.parentNode);
  return { headerRow: headerRow, body: body };
}

// A data row plus any detail rows that belong under it (the expandable
// transcript on the sessions and visits pages), so a sort moves the pair
// together instead of stranding a transcript under someone else's session.
function sortableGroups(table) {
  var parts = sortableParts(table);
  var groups = [];
  if (!parts.body) return groups;
  var rows = parts.body.rows;
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i];
    if (row === parts.headerRow) continue;
    if (/(^| )chat( |$)/.test(row.className) && groups.length) {
      groups[groups.length - 1].rows.push(row);
      continue;
    }
    // Empty-state rows span the table and are not data; leave them be.
    if (row.querySelector("td[colspan]")) continue;
    groups.push({ rows: [row] });
  }
  return groups;
}

function sortableValue(cell, numeric) {
  if (!cell) return null;
  var raw = cell.hasAttribute("data-sv")
    ? cell.getAttribute("data-sv")
    : cell.textContent.trim();
  if (raw === "" || raw === "\\u2014" || raw === "-") return null;
  if (!numeric) return raw.toLowerCase();
  var n = Number(raw);
  return isNaN(n) ? null : n;
}

function sortableApply(table, index, numeric, dir) {
  var parts = sortableParts(table);
  var groups = sortableGroups(table);
  var sign = dir === "asc" ? 1 : -1;
  groups.forEach(function (g, i) {
    g.seq = i;
    g.value = sortableValue(g.rows[0].cells[index], numeric);
  });
  groups.sort(function (a, b) {
    if (a.value === null || b.value === null) {
      if (a.value === null && b.value === null) return a.seq - b.seq;
      return a.value === null ? 1 : -1;
    }
    if (a.value < b.value) return -sign;
    if (a.value > b.value) return sign;
    return a.seq - b.seq; // stable: ties keep the order the server sent
  });
  groups.forEach(function (g) {
    g.rows.forEach(function (row) { parts.body.appendChild(row); });
  });
}

function sortableIndicator(th, arrow, dir) {
  if (dir) {
    th.classList.add("sorted");
    arrow.textContent = dir === "asc" ? "\\u25B2" : "\\u25BC";
    th.setAttribute("aria-sort", dir === "asc" ? "ascending" : "descending");
  } else {
    th.classList.remove("sorted");
    arrow.textContent = "";
    th.removeAttribute("aria-sort");
  }
}

function makeSortable(scope) {
  var tables = (scope || document).querySelectorAll("table.sortable");
  Array.prototype.forEach.call(tables, function (table) {
    var headerRow = sortableParts(table).headerRow;
    if (!headerRow) return;
    var headers = Array.prototype.slice.call(headerRow.cells);
    headers.forEach(function (th, index) {
      if (th.hasAttribute("data-nosort")) return;
      var numeric = th.getAttribute("data-type") === "num";

      // Pages whose headers live outside the re-rendered region (the campaign
      // links tables replace only their tbody) call this again after every
      // refresh. Do not wire twice — just drop the arrow the last sort left
      // behind, because the rows that came back are in the server's order.
      var existing = th.querySelector(".sort-arrow");
      if (existing) { sortableIndicator(th, existing, th.getAttribute("data-sorted")); return; }

      th.classList.add("sortable-h");
      var arrow = document.createElement("span");
      arrow.className = "sort-arrow";
      th.appendChild(document.createTextNode(" "));
      th.appendChild(arrow);

      // Whatever order the server already sent this table in, so the first
      // click on that column flips it rather than re-sorting it the same way.
      sortableIndicator(th, arrow, th.getAttribute("data-sorted"));

      th.addEventListener("click", function () {
        var dir = th.classList.contains("sorted")
          ? (arrow.textContent === "\\u25B2" ? "desc" : "asc")
          : (numeric ? "desc" : "asc");
        sortableApply(table, index, numeric, dir);
        headers.forEach(function (other) {
          var a = other.querySelector(".sort-arrow");
          if (a) sortableIndicator(other, a, null);
        });
        sortableIndicator(th, arrow, dir);
      });
    });
  });
}
`;
}

/**
 * The tick trail, shared by the Chat logs and User sessions pages.
 *
 * One implementation on purpose. Both pages render the same event stream and
 * the same collapsing rule, and this file already carries scars from values
 * that were written out twice and then drifted (see the dwell-bucket headers,
 * which hardcoded "30s" until the tick cadence moved).
 *
 * renderTimeline takes the time formatter as an argument because the two pages
 * disagree, correctly: Chat logs shows local time, User sessions labels its
 * column "When (UTC)" and would be lying if the timeline underneath it
 * silently switched zones.
 */
function visitTimelineCss() {
    return `
  .timeline { border-left: 2px solid #2a2a33; margin: 8px 0 20px; padding: 0 0 0 14px; }
  .tl-item { position: relative; padding: 3px 0; font-size: 13px; color: #c8c8d2; }
  .tl-item::before { content: ""; position: absolute; left: -19px; top: 10px; width: 6px; height: 6px; border-radius: 50%; background: #45455a; }
  .tl-item.key::before { background: #b39ddb; }
  .tl-item.leave::before { background: #e5b573; }
  .tl-item.fail::before { background: #e57373; }
  .tl-item .fail-reason { color: #e57373; }
  .tl-time { color: #6b6b78; margin-right: 8px; font-variant-numeric: tabular-nums; }
  .tl-ticks { color: #7e9fd6; }
  .tl-summary { background: #16161c; border: 1px solid #26262f; border-radius: 8px; padding: 12px 14px; margin: 0 0 16px; font-size: 13px; line-height: 1.7; }
  .tl-summary b { color: #e6e6ea; font-weight: 600; }
`;
}

function visitTimelineJs() {
    return `
// created_at is written in two formats: ISO-8601 from the worker and SQLite's
// "YYYY-MM-DD HH:MM:SS" from a column default. Both are UTC; only the ISO one
// says so, so the marker is added before parsing rather than trusting Date.
function parseUtc(s) {
  var iso = String(s);
  if (iso.indexOf("T") === -1) iso = iso.replace(" ", "T");
  if (!/(Z|[+-]\\d{2}:?\\d{2})$/.test(iso)) iso += "Z";
  return new Date(iso);
}

function fmtDuration(ms) {
  if (ms === null || ms === undefined || isNaN(ms)) return "unknown";
  var secs = Math.round(ms / 1000);
  if (secs < 60) return secs + "s";
  var mins = Math.floor(secs / 60);
  return mins + "m " + (secs % 60) + "s";
}

// Consecutive screen_pings collapse into one line — sixty near-identical rows
// would bury the events that actually mean something.
function renderTimeline(container, events, fmtTime) {
  if (!events || !events.length) return;
  var wrap = document.createElement("div");
  wrap.className = "timeline";

  var i = 0;
  while (i < events.length) {
    var e = events[i];
    var item = document.createElement("div");

    if (e.event === "screen_ping") {
      var j = i;
      while (j < events.length && events[j].event === "screen_ping") j++;
      var run = events.slice(i, j);
      var span = parseUtc(run[run.length - 1].created_at) - parseUtc(run[0].created_at);
      item.className = "tl-item";
      var t1 = document.createElement("span");
      t1.className = "tl-time";
      t1.textContent = fmtTime(run[0].created_at);
      item.appendChild(t1);
      var ticks = document.createElement("span");
      ticks.className = "tl-ticks";
      ticks.textContent = run.length + " ticks over " + fmtDuration(span) + " - on screen, not engaging";
      item.appendChild(ticks);
      i = j;
    } else {
      var isLeave = e.event === "leave";
      var isFail = e.event === "send_failed";
      item.className = "tl-item " + (isFail ? "fail" : isLeave ? "leave" : "key");
      var t2 = document.createElement("span");
      t2.className = "tl-time";
      t2.textContent = fmtTime(e.created_at);
      item.appendChild(t2);
      var label = e.event + (e.detail ? " (" + e.detail + ")" : "");
      if (isLeave && e.duration_ms) label += " - dwell " + fmtDuration(e.duration_ms);
      // hide and show are checkpoints, not endings, and the gap between a
      // pair is the whole point of them: a few hundred milliseconds is an
      // aborted swipe-to-dismiss, forty seconds is an app switch they came
      // back from. Rendered as bare event names, the two were indistinguishable
      // — which is the confusion the events were added to clear up.
      if (e.event === "hide") {
        label = "hide - put away" +
          (e.visible_ms !== null && e.visible_ms !== undefined
            ? ", " + fmtDuration(e.visible_ms) + " on screen so far" : "");
      }
      if (e.event === "show") {
        label = "show - came back" +
          (e.duration_ms ? " after " + fmtDuration(e.duration_ms) + " away" : "");
      }
      // What the ending actually was. "bfcache" especially: the page was
      // frozen rather than destroyed, so this visit can still resume.
      if (isLeave) {
        var ENDINGS = {
          dismissed: "closed while on screen",
          hidden: "backgrounded, then never came back",
          bfcache: "frozen, not closed - a back gesture could restore it",
        };
        if (e.visible_ms !== null && e.visible_ms !== undefined) {
          label += ", seen " + fmtDuration(e.visible_ms);
        }
        if (ENDINGS[e.exit_mode]) label += " - " + ENDINGS[e.exit_mode];
      }
      item.appendChild(document.createTextNode(label));
      if (e.failure_reason) {
        var why = document.createElement("span");
        why.className = "fail-reason";
        why.textContent = " - " + e.failure_reason;
        item.appendChild(why);
      }
      i++;
    }
    wrap.appendChild(item);
  }
  container.appendChild(wrap);
}

// Ticks are 0.5s apart for the first ten seconds and 3s apart after that, so
// there is no single interval to multiply by. Report the span between first
// and last instead — which is also right when a backgrounded tab stops
// ticking, where multiplying would claim attention that never happened.
function tickSpanMs(data) {
  if (!data.first_tick_at || !data.last_tick_at) return 0;
  return parseUtc(data.last_tick_at) - parseUtc(data.first_tick_at);
}
`;
}

/// Hand-written record of what shipped and when.
///
/// Every question the other pages answer is a before/after question, and the
/// "before" is a deploy. Nothing recorded them: git log holds commit times,
/// which are not deploy times, and docs/ANALYTICS_HANDOFF.md 3 had to be
/// reconstructed from memory with half its rows carrying a "~".
///
/// Entered by hand on purpose. The deploy script runs from a laptop and cannot
/// be relied on to hold database credentials, and a deploy that half-failed
/// still changed what visitors saw — a row here means a person watched it go
/// out, which is the only claim worth trusting on a timeline.
function adminDeploysPageHtml() {
    return `<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mythos Live — Deploy log</title>
<style>
  body { font: 14px -apple-system, system-ui, sans-serif; margin: 0; padding: 24px;
         background: #14101a; color: #eee; }
  h1 { font-size: 20px; margin: 0 0 4px; }
  p.sub { color: #999; margin: 0 0 18px; max-width: 74ch; line-height: 1.5; }
  form { background: #1d1726; border: 1px solid #2c2438; border-radius: 10px;
         padding: 14px 16px; margin: 0 0 20px; max-width: 74ch; }
  .row { display: flex; gap: 12px; flex-wrap: wrap; margin-bottom: 10px; }
  label { display: block; font-size: 12px; color: #999; margin-bottom: 4px; }
  input, select, textarea, button {
    background: #241d2e; color: #eee; border: 1px solid #443; padding: 7px 10px;
    border-radius: 6px; font: inherit; }
  textarea { width: 100%; min-height: 52px; resize: vertical; }
  button { cursor: pointer; background: #37294d; border-color: #7e57c2; }
  button:hover:not(:disabled) { background: #453163; }
  button:disabled { opacity: .5; cursor: default; }
  table { border-collapse: collapse; width: 100%; }
  th, td { text-align: left; padding: 7px 10px; border-bottom: 1px solid #2c2438;
           vertical-align: top; }
  th { color: #b39ddb; font-weight: 600; font-size: 12px; text-transform: uppercase;
       letter-spacing: .04em; }
  .muted { color: #777; }
  .warn { color: #e5a373; }
  .err { color: #e57373; }
  .ver { font-variant-numeric: tabular-nums; font-weight: 600; }
  .hint { font-size: 12px; color: #777; margin: 6px 0 0; line-height: 1.5; }
  #msg { margin-left: 10px; font-size: 13px; }
</style></head><body>
<p style="margin:0 0 14px"><a href="/admin" style="color:#b39ddb">&larr; Admin</a></p>
<h1>Deploy log</h1>
<p class="sub">What shipped, and when — written down by hand, because nothing else
   records it. Commit time is not deploy time, and a version sitting in git says
   nothing about the hour real visitors started seeing it. Every time in this
   table is <b>UTC</b>, matching every other timestamp in the admin tools.</p>

<form id="f" onsubmit="return save(event)">
  <div class="row">
    <div>
      <label for="version">Version</label>
      <input id="version" placeholder="1.6.4+60" size="14" required>
    </div>
    <div>
      <label for="deployed">Deployed at (UTC)</label>
      <input id="deployed" type="datetime-local" step="1" required>
    </div>
    <div>
      <label for="target">What shipped</label>
      <select id="target">
        <option value="both">app + worker</option>
        <option value="app">Flutter app</option>
        <option value="worker">worker only</option>
      </select>
    </div>
  </div>
  <div>
    <label for="notes">Notes — what changed, in a sentence</label>
    <textarea id="notes" placeholder="Quick-reply attention cues; visible-time analytics"></textarea>
  </div>
  <p class="hint">The clock below the field is <b>your</b> clock; this form sends what you
     typed as UTC. The button prefills it with the current UTC time.</p>
  <div class="row" style="margin-top:8px">
    <button type="submit" id="submit">Record deploy</button>
    <button type="button" onclick="prefillNow()">Now (UTC)</button>
    <span id="msg"></span>
  </div>
</form>

<div id="out">Loading…</div>
<script>
function esc(v) {
  return String(v === null || v === undefined ? '' : v)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}
// A datetime-local input reads and writes local time with no zone attached, so
// the value is built from the UTC parts explicitly. Reading Date.toISOString()
// straight in would be right; letting the browser format it would not.
function utcNowForInput() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return d.getUTCFullYear() + '-' + p(d.getUTCMonth() + 1) + '-' + p(d.getUTCDate()) +
         'T' + p(d.getUTCHours()) + ':' + p(d.getUTCMinutes()) + ':' + p(d.getUTCSeconds());
}
function prefillNow() { document.getElementById('deployed').value = utcNowForInput(); }

async function save(ev) {
  ev.preventDefault();
  const btn = document.getElementById('submit');
  const msg = document.getElementById('msg');
  btn.disabled = true;
  msg.textContent = 'Saving…';
  try {
    const res = await fetch('/api/admin/deploys', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        version: document.getElementById('version').value,
        deployed_at: document.getElementById('deployed').value,
        target: document.getElementById('target').value,
        notes: document.getElementById('notes').value,
      }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error((data.error || 'HTTP ' + res.status) + (data.hint ? ' — ' + data.hint : ''));
    msg.innerHTML = '<span class="muted">Recorded.</span>';
    document.getElementById('notes').value = '';
    load();
  } catch (err) {
    msg.innerHTML = '<span class="err">' + esc(err && err.message ? err.message : err) + '</span>';
  } finally {
    btn.disabled = false;
  }
  return false;
}

async function load() {
  const out = document.getElementById('out');
  try {
    const res = await fetch('/api/admin/deploys');
    const data = await res.json();
    if (!res.ok) {
      out.innerHTML = '<p class="warn">' + esc(data.error || 'HTTP ' + res.status) + '</p>' +
        (data.hint ? '<p class="hint">' + esc(data.hint) + '</p>' : '');
      return;
    }
    const rows = data.deploys || [];
    if (!rows.length) {
      out.innerHTML = '<p class="muted">Nothing recorded yet. The next deploy is the one to start with.</p>';
      return;
    }
    let h = '<table><tr><th>Deployed (UTC)</th><th>Version</th><th>What</th>' +
            '<th>Notes</th><th>Recorded</th></tr>';
    for (const r of rows) {
      // Recorded-at is shown only when it is not the same day as the deploy:
      // a row written days later is worth knowing about, and one written on
      // the spot is noise in a column.
      const late = String(r.created_at || '').slice(0, 10) !== String(r.deployed_at || '').slice(0, 10);
      h += '<tr><td>' + esc(r.deployed_at) + '</td>' +
           '<td class="ver">' + esc(r.version) + '</td>' +
           '<td>' + esc(r.target || '') + '</td>' +
           '<td>' + esc(r.notes || '') + '</td>' +
           '<td class="muted">' + (late ? esc(r.created_at) : '') + '</td></tr>';
    }
    h += '</table>';
    out.innerHTML = h;
  } catch (err) {
    out.innerHTML = '<p class="err">Could not load: ' + esc(err && err.message ? err.message : err) + '</p>';
  }
}
prefillNow();
load();
</script></body></html>`;
}

/// Landing page for the admin tools. They accumulated one at a time and there
/// was no way to find them except remembering the URLs.
function adminIndexPageHtml() {
    return `<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mythos Live — Admin</title>
<style>
  body { font: 15px -apple-system, system-ui, sans-serif; margin: 0; padding: 40px 24px;
         background: #14101a; color: #eee; }
  .wrap { max-width: 640px; margin: 0 auto; }
  h1 { font-size: 22px; margin: 0 0 6px; }
  p.sub { color: #999; margin: 0 0 28px; font-size: 14px; }
  a.card { display: block; text-decoration: none; color: inherit;
           background: #1d1726; border: 1px solid #2c2438; border-radius: 12px;
           padding: 16px 18px; margin-bottom: 12px; transition: border-color .15s, background .15s; }
  a.card:hover { border-color: #7e57c2; background: #241d2e; }
  .t { font-weight: 600; color: #fff; margin-bottom: 3px; }
  .t .em { color: #b39ddb; font-size: 12px; font-weight: 400; margin-left: 8px; }
  .d { color: #999; font-size: 13px; line-height: 1.45; }
  /* The export is a control, not a destination, so it sits in the same card
     shape as the links without pretending to be one. */
  .card.export { background: #1d1726; border: 1px solid #2c2438; border-radius: 12px;
                 padding: 16px 18px; margin-bottom: 12px; }
  .controls { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; margin-top: 12px; }
  select, button { background: #241d2e; color: #eee; border: 1px solid #443;
                   padding: 6px 10px; border-radius: 6px; font: inherit; }
  button { cursor: pointer; }
  button:hover:not(:disabled) { background: #2f2740; }
  button:disabled { opacity: .5; cursor: default; }
  #note { color: #777; font-size: 12px; }
  .warn { color: #e5a373; }
  footer { color: #666; font-size: 12px; margin-top: 26px; line-height: 1.6; }
</style></head><body><div class="wrap">
<h1>Mythos Live — Admin</h1>
<p class="sub">Everything here is behind the same password.</p>

<a class="card" href="/admin/visits">
  <div class="t">Visits <span class="em">start here</span></div>
  <div class="d">Every arrival, logged from the splash screen before the app loads.
     Funnel from arrival through to the login gate, load and dwell times, and
     traffic by source.</div>
</a>

<a class="card" href="/admin/first30">
  <div class="t">First 30 seconds <span class="em">tick by tick</span></div>
  <div class="d">The survival curve for the chat screen at the resolution it was
     recorded in — 500ms steps for the first ten seconds — with the script's own
     questions marked, so a drop can be read against the line that caused it.</div>
</a>

<a class="card" href="/admin/referrals">
  <div class="t">Campaigns <span class="em">/c/ links only</span></div>
  <div class="d">Server-side record of character link hits. Fires even with no
     JavaScript, so it catches visitors Visits cannot — but it also counts
     Meta&rsquo;s link-preview crawler, so it reads high.</div>
</a>

<a class="card" href="/admin/sessions">
  <div class="t">User sessions <span class="em">one row per arrival</span></div>
  <div class="d">Every session, newest first: how long they stayed, how long
     they hesitated on a character, and how many messages they sent — split
     into tapped starters and messages they wrote themselves. Sort by any
     column from the table.</div>
</a>

<a class="card" href="/admin/logs">
  <div class="t">Chat logs</div>
  <div class="d">Conversation transcripts by user and character.</div>
</a>

<a class="card" href="/admin/deploys">
  <div class="t">Deploy log <span class="em">written by hand</span></div>
  <div class="d">What shipped and when. Every number on the other pages is a
     before/after question, and the &ldquo;before&rdquo; is a deploy — commit
     time is not deploy time, so nothing else on this system knows.</div>
</a>

<div class="card export">
  <div class="t">Export everything</div>
  <div class="d">Every row this app writes — visits, messages, campaign hits and the
     deploy log — raw, as one JSON file. Take one before a migration or a schema
     change: it is the only copy that survives the question nobody thought to ask.</div>
  <div class="controls">
    <select id="hours">
      <option value="24" selected>last 24 hours</option>
      <option value="168">last 7 days</option>
      <option value="720">last 30 days</option>
    </select>
    <button id="export" onclick="exportAll()">Download JSON</button>
    <span id="note"></span>
  </div>
</div>

<script>
function esc(v) {
  return String(v === null || v === undefined ? '' : v)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}
// Fetched rather than linked, so the per-table cap can be reported. A dump that
// stopped at 50,000 rows of one table looks exactly like a complete one once
// the file is closed and the traffic that produced it is gone.
async function exportAll() {
  const btn = document.getElementById('export');
  const note = document.getElementById('note');
  btn.disabled = true;
  note.textContent = 'Exporting…';
  try {
    const hours = document.getElementById('hours').value;
    const res = await fetch('/api/admin/export-all?hours=' + encodeURIComponent(hours));
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const blob = await res.blob();
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'mythos-all-' + hours + 'h.json';
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
    const rows = res.headers.get('X-Export-Rows') || '?';
    note.innerHTML = res.headers.get('X-Export-Truncated') === '1'
      ? '<span class="warn">' + rows + ' rows — one or more tables hit the cap. Narrow the window.</span>'
      : rows + ' rows exported.';
  } catch (err) {
    note.innerHTML = '<span class="warn">Export failed: ' +
      esc(err && err.message ? err.message : err) + '</span>';
  } finally {
    btn.disabled = false;
  }
}
</script>

<footer>
  Visits vs Campaigns: Visits needs a real browser running JavaScript, so it is
  the closer proxy for actual people. Campaigns is recorded by the worker itself
  and includes bots. A big gap between them is usually crawlers, not lost users.
</footer>
</div></body></html>`;
}

function adminSessionsPageHtml() {
    return `<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mythos Live — User sessions</title>
<style>
  body { font: 14px -apple-system, system-ui, sans-serif; margin: 0; padding: 24px;
         background: #14101a; color: #eee; }
  h1 { font-size: 20px; margin: 0 0 4px; }
  p.sub { color: #999; margin: 0 0 12px; max-width: 70ch; }
  select, button { background: #241d2e; color: #eee; border: 1px solid #443; padding: 6px 10px;
           border-radius: 6px; margin-bottom: 18px; font: inherit; }
  button { cursor: pointer; }
  button:hover:not(:disabled) { background: #2f2740; }
  button:disabled { opacity: .5; cursor: default; }
  #export-note { color: #777; font-size: 12px; margin-left: 10px; }
  table { border-collapse: collapse; width: 100%; margin-bottom: 12px; }
  th, td { text-align: left; padding: 7px 10px; border-bottom: 1px solid #2c2438; }
  th { color: #b39ddb; font-weight: 600; font-size: 12px; text-transform: uppercase;
       letter-spacing: .04em; }
  td.num { text-align: right; font-variant-numeric: tabular-nums; }
  .muted { color: #777; }
  .warn { color: #e5a373; }
  .wrap { overflow-x: auto; }
  a.drill { color: #b39ddb; }
  tr.chat td { background: #191322; }
  .note { color: #777; font-size: 12px; max-width: 78ch; line-height: 1.5; }
  /* The headline counts. Deliberately a short vertical list rather than a row
     of big numbers: each line is a subset of the one above it, and stacking
     them makes the drop between steps the thing you read first. */
  .tally { border: 1px solid #2a2a33; border-radius: 8px; padding: 12px 14px;
           margin: 0 0 14px; max-width: 62ch; }
  .tally table { width: 100%; border: 0; }
  .tally td { border: 0; padding: 3px 0; vertical-align: baseline; }
  .tally td.n { text-align: right; width: 5ch; font-variant-numeric: tabular-nums;
                color: #e6e6ea; font-weight: 600; padding-right: 10px; }
  .tally td.pc { text-align: right; width: 6ch; color: #777; padding-left: 10px; }
  .tally .step { color: #bbb; }
  .tally .head { color: #e6e6ea; font-weight: 600; }
  .tally .gloss { color: #777; font-size: 12px; line-height: 1.5;
                  margin: 8px 0 0; padding-top: 8px; border-top: 1px solid #2a2a33; }
  /* Where the arrivals came from. A wrapping row of name+count pairs rather
     than a table: it is read as a list of places, and at 30-odd countries a
     table of two columns would push the sessions off the screen entirely. */
  .countries { border: 1px solid #2a2a33; border-radius: 8px; padding: 12px 14px;
               margin: 0 0 14px; max-width: 90ch; }
  .countries h2 { font-size: 12px; color: #b39ddb; text-transform: uppercase;
                  letter-spacing: .04em; margin: 0 0 8px; font-weight: 600; }
  .countries ul { list-style: none; margin: 0; padding: 0; display: flex;
                  flex-wrap: wrap; gap: 4px 18px; }
  .countries li { font-size: 13px; color: #ddd; }
  .countries li b { color: #e6e6ea; font-variant-numeric: tabular-nums; }
  .countries .code { color: #777; font-size: 11px; }
  .countries .gloss { color: #777; font-size: 12px; line-height: 1.5;
                      margin: 8px 0 0; padding-top: 8px; border-top: 1px solid #2a2a33; }
  /* Where the visit came from and what it arrived on. Two columns rather than
     a sentence: these are lookup values, read one at a time. */
  .vc-grid { display: grid; grid-template-columns: max-content minmax(0, 1fr);
             gap: 2px 14px; font-size: 12px; margin: 0 0 14px; max-width: 90ch; }
  .vc-grid dt { color: #777; }
  .vc-grid dd { margin: 0; color: #ddd; overflow-wrap: anywhere; }
  .detail-h { color: #b39ddb; font-size: 12px; text-transform: uppercase;
              letter-spacing: .04em; margin: 14px 0 6px; }
  .detail-h:first-child { margin-top: 4px; }
${sortableTableCss()}
${visitTimelineCss()}
</style></head><body>
<p style="margin:0 0 14px"><a href="/admin" style="color:#b39ddb">&larr; Admin</a>
   &nbsp;·&nbsp; <a href="/admin/visits" style="color:#b39ddb">Site visits</a></p>
<h1>User sessions</h1>
<p class="sub">One row per arrival — every time someone opens the app, whether or
   not they ever reached a character. <b>Arrivals are visits, not people:</b> a
   visitor who comes back later, or reloads, arrives again and is counted again,
   and nothing here can tell the difference — someone who never sends a message
   has no id to be recognised by. Read every number on this page as "visits",
   never as "people". Newest first. Click any column heading to
   sort by it, again to reverse; sessions the browser never reported a dwell or
   a tick for sort last whichever way you sort, since those are unknown rather
   than zero.</p>
<select id="days" onchange="pick()">
  <option value="1">Last 24 hours</option>
  <option value="7" selected>Last 7 days</option>
  <option value="30">Last 30 days</option>
  <option value="90">Last 90 days</option>
</select>
<select id="rows" onchange="load()" title="how many sessions to load — sorting works within these rows">
  <option value="500" selected>500 rows</option>
  <option value="1000">1,000 rows</option>
  <option value="5000">5,000 rows</option>
</select>
<button id="export" onclick="exportCsv()"
        title="every session in the selected range as CSV — the whole range, not just the rows loaded above">Export CSV</button>
<span id="export-note" class="note"></span>
<div id="tally"></div>
<div id="countries"></div>
<div id="out">Loading…</div>
<p class="note" id="footnote"></p>
<script>
${sortableTableJs()}
${visitTimelineJs()}
function esc(v) {
  return String(v === null || v === undefined ? '' : v)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}
function dur(ms) {
  if (ms === null || ms === undefined) return '<span class="muted">—</span>';
  if (ms < 1000) return ms + 'ms';
  if (ms < 60000) return (ms/1000).toFixed(1) + 's';
  return Math.floor(ms/60000) + 'm ' + Math.round((ms%60000)/1000) + 's';
}
// The table column is headed "When (UTC)", so the trail underneath it stays in
// UTC too — switching to local time inside an expanded row would silently
// reinterpret every timestamp on the page.
function utcClock(ts) {
  const d = parseUtc(ts);
  return isNaN(d.getTime()) ? String(ts) : d.toISOString().slice(11, 19) + 'Z';
}
// A day drilled into from the Visits page pins the range; the selector then has
// nothing to control, so it is hidden rather than left there looking live.
const DAY = new URLSearchParams(location.search).get('day');
// The range the table is showing, as query parameters. One definition, used by
// both the table and the export, so a file can never describe a different
// window from the page that produced it.
function rangeQuery() {
  return DAY ? 'day=' + encodeURIComponent(DAY)
             : 'days=' + document.getElementById('days').value;
}
// Every session in the range as CSV — the whole range, not the rows loaded
// above. Fetched rather than linked so the cap can be reported: a file that
// stopped at 20,000 rows looks exactly like a complete one once it is open in
// a spreadsheet.
async function exportCsv() {
  const btn = document.getElementById('export');
  const note = document.getElementById('export-note');
  btn.disabled = true;
  note.textContent = 'Exporting…';
  try {
    const res = await fetch('/api/admin/sessions?' + rangeQuery() + '&format=csv');
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const blob = await res.blob();
    const name = 'mythos-sessions-' + (DAY || 'last-' + document.getElementById('days').value + '-days') + '.csv';
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = name;
    document.body.appendChild(a);
    a.click();
    a.remove();
    // Revoked on a turn of the event loop rather than immediately: Safari
    // cancels the download if the object URL dies in the same tick.
    setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
    const rows = res.headers.get('X-Sessions-Rows') || '?';
    note.innerHTML = res.headers.get('X-Sessions-Truncated') === '1'
      ? '<span class="warn">' + rows + ' rows — capped. Narrow the range for a complete file.</span>'
      : rows + ' rows exported.';
  } catch (err) {
    note.innerHTML = '<span class="warn">Export failed: ' +
      esc(err && err.message ? err.message : err) + '</span>';
  } finally {
    btn.disabled = false;
  }
}
function pick() { load(); }
function load() {
  const out = document.getElementById('out');
  out.textContent = 'Loading…';
  render(out).catch(function (err) {
    console.error('sessions page failed', err);
    out.innerHTML = '<p style="color:#e57373">Could not load this page: ' +
      esc(err && err.message ? err.message : err) + '</p>';
  });
}
// Sort keys go on the cell as data-sv, because the visible text is formatted:
// "1.4s" and "12m 3s" do not compare as numbers, and an unknown dwell reads as
// an em dash. Every numeric column therefore carries its raw value, and an
// empty one means unknown (sorted last, both directions).
function sv(value) {
  return ' data-sv="' + (value === null || value === undefined ? '' : value) + '"';
}
// Full country names, resolved in the browser. Only the two-letter code is
// stored — it is what request.cf.country gives us — and a code is a poor thing
// to read a market list from: MY and MX sit one letter apart and are two
// different countries. Intl already carries the whole ISO 3166 list, so this
// ships nothing and cannot go stale the way a table in the worker would.
const REGION_NAMES = (function () {
  try { return new Intl.DisplayNames(['en'], { type: 'region' }); }
  catch (e) { return null; }
})();
function countryName(code) {
  if (!code) return 'Unknown';
  // Cloudflare's two non-country answers: T1 is a Tor exit node, XX is "could
  // not tell". Neither is a region, and Intl throws on both.
  if (code === 'T1') return 'Tor network';
  if (code === 'XX') return 'Unknown';
  try {
    const name = REGION_NAMES ? REGION_NAMES.of(code) : null;
    return name || code;
  } catch (e) { return code; }
}
// Where the arrivals came from, over the whole window rather than the rows
// that were loaded. The code stays beside the name so this list can be read
// against the Country column in the table below, which has room for two
// letters and not for "United Kingdom".
function renderCountries(rows, arrivals) {
  const box = document.getElementById('countries');
  if (!rows.length) { box.innerHTML = ''; return; }
  const items = rows.map(function (r) {
    const pc = arrivals ? Math.round(100 * r.visits / arrivals) : 0;
    return '<li>' + esc(countryName(r.country)) + ' <b>' + r.visits + '</b>' +
           ' <span class="code">(' + (pc ? pc + '%' : '&lt;1%') +
           (r.country ? ' &middot; ' + esc(r.country) : '') + ')</span></li>';
  });
  box.innerHTML = '<div class="countries"><h2>Countries &mdash; ' + rows.length +
    ' in this range</h2><ul>' + items.join('') + '</ul>' +
    '<p class="gloss">Visits, not people, and counted over the whole range rather than the ' +
    'rows loaded below. <b>Unknown</b> is a visit the edge could not place, not a country. ' +
    'Percentages are of all arrivals in the range.</p></div>';
}
async function render(out) {
  const q = rangeQuery() + '&limit=' + document.getElementById('rows').value;
  const res = await fetch('/api/admin/sessions?' + q);
  if (!res.ok) throw new Error('HTTP ' + res.status);
  const d = await res.json();
  const rows = d.sessions || [];

  let h = '<div class="wrap"><table class="sortable"><tr><th data-sorted="desc">When (UTC)</th>' +
          '<th>Source</th><th>Path</th>' +
          '<th>Character</th><th>Country</th><th data-type="num">Load</th>' +
          '<th data-type="num" title="wall clock from arrival to the last thing the browser reported">Dwell</th>' +
          '<th data-type="num" title="time the page was actually on screen, summed across backgroundings">Seen</th>' +
          '<th title="how the visit ended, and how often it was backgrounded first">Exit</th>' +
          '<th data-type="num">Ticks</th>' +
          '<th data-type="num">Messages</th><th data-type="num">Tapped</th>' +
          '<th data-type="num">Typed</th>' +
          '<th data-type="num" title="the longest the visitor waited for a reply in this session">Slowest reply</th>' +
          '<th data-type="num">Failed</th>' +
          '<th data-nosort>Detail</th></tr>';
  for (const r of rows) {
    // Ticks stop the moment a visitor engages, so they only mean anything for
    // a session that opened a character and are silent about one that went on
    // to send messages. "—" for a session that never opened one at all.
    const ticks = r.opened_character
      ? '<span title="ticks on the chat screen before engaging">' + (r.ticks || 0) + '</span>'
      : '<span class="muted">—</span>';
    const tapped = r.starter_unmatched
      ? '<span class="warn" title="the funnel recorded a starter tap but no message matches a known starter — backend/src/starters.generated.js is probably stale">starter (unmatched)</span>'
      : '<span class="num">' + (r.tapped || 0) + '</span>';
    const failures = (r.failed || 0) + (r.send_failed || 0);
    // How the visit ended, in a word, with the number of backgroundings
    // beside it. A missing exit mode is not "fine" — it means the browser
    // never reported an ending at all, which is its own outcome and has to
    // read as unknown rather than as an empty cell.
    const EXITS = {
      dismissed: ['closed', 'destroyed while still on screen'],
      hidden: ['backgrounded', 'destroyed after being put away, and never came back'],
      bfcache: ['frozen', 'frozen rather than closed — a back gesture can restore this same visit'],
    };
    const exit = EXITS[r.exit_mode] || (r.reported_leave
      ? ['<span class="muted">ended</span>',
         'the browser reported an ending, but this visit predates the column that says which kind']
      : ['<span class="muted">unknown</span>',
         'the browser never reported an ending — the page was destroyed without one, or the beacon was lost']);
    const hides = r.hide_count
      ? ' <span class="muted" title="times backgrounded before it ended">&times;' + r.hide_count + '</span>'
      : '';
    h += '<tr><td>' + esc(r.created_at) + '</td><td>' + esc(r.source) +
         '</td><td>' + esc(r.path) + '</td><td>' + esc(r.character_id || '') +
         '</td><td>' + esc(r.country) +
         '</td><td class="num"' + sv(r.load_ms) + '>' + dur(r.load_ms) +
         '</td><td class="num"' + sv(r.dwell_ms) + '>' + dur(r.dwell_ms) +
         '</td><td class="num"' + sv(r.visible_ms) + '>' + dur(r.visible_ms) +
         '</td><td title="' + exit[1] + '"' + sv(r.exit_mode || '') + '>' + exit[0] + hides +
         '</td><td class="num"' + sv(r.opened_character ? (r.ticks || 0) : null) + '>' + ticks +
         '</td><td class="num"' + sv(r.messages || 0) + '>' + (r.messages || 0) +
         '</td><td class="num"' + sv(r.tapped || 0) + '>' + tapped +
         '</td><td class="num"' + sv(r.typed || 0) + '>' + (r.typed || 0) +
         '</td><td class="num"' + sv(r.slowest_reply_ms) + '>' + dur(r.slowest_reply_ms) +
         '</td><td class="num"' + sv(failures) + '>' +
         (failures
           ? '<span class="warn">' + failures + '</span>'
           : '<span class="muted">0</span>') +
         // Offered on every session, not only the ones that sent something.
         // A visit that opened a character and never typed has no transcript
         // but it does have a tick trail, and that is the population worth
         // understanding — it is where the drop-off is.
         '</td><td><a href="#" class="drill" data-v="' + esc(r.visit_id) +
         '" data-c="' + esc(r.character_id || '') + '">' +
         (r.messages ? 'chat + trail' : 'trail') + '</a>' +
         '</td></tr><tr class="chat" id="chat-' + esc(r.visit_id) +
         '" style="display:none"><td colspan="16"></td></tr>';
  }
  if (!rows.length) h += '<tr><td colspan="16" class="muted">No sessions in this range.</td></tr>';
  h += '</table></div>';
  out.innerHTML = h;
  makeSortable(out);

  const scope = d.day ? 'on ' + d.day + ' (UTC)' : 'in the last ' + d.days + ' days';

  // The headline counts. These come from the server over the whole window, so
  // they stay true when the table below is truncated to the newest 500.
  const t = d.totals || {};
  const arrivals = t.arrivals || 0;
  // Every step is a subset of arrivals, so that is the denominator throughout —
  // a percentage of the previous step would read as a step-to-step conversion
  // and these are not that.
  const pc = function (n) {
    return arrivals ? Math.round(100 * n / arrivals) + '%' : '';
  };
  const line = function (n, label, cls) {
    return '<tr><td class="n">' + n + '</td><td class="' + (cls || 'step') + '">' +
           label + '</td><td class="pc">' + (cls === 'head' ? '' : pc(n)) + '</td></tr>';
  };
  document.getElementById('tally').innerHTML = arrivals
    ? '<div class="tally"><table>' +
      line(arrivals, 'arrivals ' + esc(scope), 'head') +
      line(t.via_link || 0, 'landed on a character link') +
      line(t.opened || 0, 'reached a character screen') +
      line(t.engaged || 0, 'typed or tapped anything') +
      line(t.messaged || 0, 'sent a message') +
      '</table>' +
      '<p class="gloss"><b>Visits, not people</b> — the same person returning or ' +
      'reloading is counted again. Each line is a subset of the arrivals above ' +
      'it, and the percentage is against that total, not against the line before ' +
      'it. A character link opens straight onto the chat screen, so for those ' +
      'arrivals <b>reaching a character screen is the destination, not a step ' +
      'they chose to take</b> — the gap between those two lines is people the ' +
      'app never delivered to, not people who browsed and lost interest.</p>' +
      '</div>'
    : '';

  renderCountries(d.countries || [], arrivals);

  document.getElementById('footnote').innerHTML =
    esc(rows.length + ' session(s) ' + scope + ' — visits, not people.') +
    // Sorting is done in the browser, so a truncated range sorts the slice
    // that was loaded rather than everything in the window — say so, because
    // "most messages" quietly meaning "most messages among the 500 longest
    // sessions" is the kind of half-truth a dashboard should never tell.
    (d.truncated
      ? ' <span class="warn">Showing the ' + d.limit.toLocaleString() +
        ' most recent — there are more, and sorting only reorders these. ' +
        'Load more rows or narrow the range for a true ranking.</span>'
      : '') +
    '<br>Web sessions only: the App Store build sends no visit id, so its usage never appears here. ' +
    // Interpolated from the tick constants, not written out: a hardcoded "30s"
    // here would be wrong the moment the cadence moves, which is the same trap
    // the dwell-bucket headers fell into.
    'Ticks stop at the first sign of engagement and cap at ${screenPingSeconds(SCREEN_PING_MAX_TICKS)}s, so they measure hesitation, not session length. ' +
    // Dwell no longer latches at the first visibilitychange — leave fires on
    // pagehide alone and the hide checkpoints carry the clock — so the caveat
    // that used to sit here ("latches at the first tab switch") is now simply
    // untrue, and the two columns need telling apart instead.
    'Dwell is wall clock from arrival to the last thing the browser reported; <b>Seen</b> is the time the page was ' +
    'actually on screen, summed across backgroundings, and is the honest figure where both exist. ' +
    'Both are blank for visits that predate the measurement — unknown, not zero. ' +
    'Exit says how the visit ended: <b>frozen</b> is not an ending at all, since a back gesture can restore that same visit. ' +
    'Slowest reply is the longest the visitor waited on the AI in that session, and is blank when no message was sent. ' +
    'Tapped vs typed is decided by matching the message against the starters that character offers.';

  out.querySelectorAll('a.drill').forEach(function (a) {
    a.addEventListener('click', async function (ev) {
      ev.preventDefault();
      const vid = a.getAttribute('data-v');
      const row = document.getElementById('chat-' + vid);
      if (row.style.display !== 'none') { row.style.display = 'none'; return; }
      row.style.display = '';
      const cell = row.firstElementChild;
      cell.innerHTML = '<span class="muted">Loading…</span>';
      try {
        // Both halves at once: the trail exists for every visit, the
        // transcript only for one that sent something.
        const [detailRes, chatRes] = await Promise.all([
          fetch('/api/admin/visit-detail?visit_id=' + encodeURIComponent(vid) +
                '&character=' + encodeURIComponent(a.getAttribute('data-c') || '')),
          fetch('/api/admin/visit-chat?visit_id=' + encodeURIComponent(vid)),
        ]);
        if (!detailRes.ok) throw new Error('HTTP ' + detailRes.status);
        const detail = await detailRes.json();
        const chat = chatRes.ok ? await chatRes.json() : { messages: [] };
        if (detail.error) throw new Error(detail.error);
        renderVisitDetail(cell, detail, chat.messages || []);
      } catch (err) {
        cell.innerHTML = '<span style="color:#e57373">Could not load: ' +
          esc(err && err.message ? err.message : err) + '</span>';
      }
    });
  });
}

// Everything recorded about one visit: how it went, where it came from, the
// event trail, and the transcript when there is one.
function renderVisitDetail(cell, detail, messages) {
  cell.innerHTML = '';
  const wrap = document.createElement('div');
  wrap.style.padding = '8px 0 12px';

  // What happened, in a sentence, before any of the detail.
  const summary = document.createElement('div');
  summary.className = 'tl-summary';
  const lines = [];
  if (detail.tick_count) {
    lines.push('<b>' + detail.tick_count + ' ticks</b> on the character screen (' +
      fmtDuration(tickSpanMs(detail)) + ' before ' +
      (messages.length ? 'engaging' : 'giving up') + ')');
  }
  if (messages.length) {
    const failed = messages.filter(m => m.status && m.status !== 'completed').length;
    lines.push('<b>' + messages.length + '</b> message(s) sent' +
      (failed ? ', <span style="color:#e57373">' + failed + ' of them failed</span>' : ''));
  } else {
    lines.push('<span class="muted">Never typed anything.</span>');
  }
  // A send that never reached the worker leaves no conversation_logs row at
  // all, so without this the row's Failed count has nothing behind it.
  for (const f of detail.failures || []) {
    lines.push('<span style="color:#e57373">Send failed</span> at ' +
      esc(utcClock(f.created_at)) + ' — ' + esc(f.reason));
  }
  if (detail.left_at) {
    // How it ended, in the browser's own terms. "dismissed" is the page being
    // destroyed while still on screen; "hidden" is it being destroyed after
    // having been put away and never brought back; "bfcache" is not an ending
    // at all — the page was frozen and a back gesture can restore this very
    // visit. Which control they used is not knowable: on a Meta in-app browser
    // the X, the swipe and the back gesture are all the host app's chrome, and
    // a webview is never told which one dismissed it.
    const ENDINGS = {
      dismissed: 'closed while on screen',
      hidden: 'backgrounded, then never came back',
      bfcache: 'frozen, not closed — a back gesture could restore it',
    };
    lines.push('Left <b>' + esc(utcClock(detail.left_at)) + '</b>' +
      (detail.dwell_ms ? ' after ' + fmtDuration(detail.dwell_ms) + ' on the site' : '') +
      (ENDINGS[detail.exit_mode] ? ' &mdash; ' + ENDINGS[detail.exit_mode] : ''));
  } else {
    lines.push('<span class="muted">No leave event — the page was destroyed ' +
      'without firing one, so the exit time is unknown.</span>');
  }
  // Wall clock counts every second the visit spent behind another app; this
  // counts only the seconds it was on screen. They diverge exactly when
  // someone backgrounded the app — including an interruptible swipe-to-dismiss
  // begun and cancelled — which the old single latched leave recorded as a
  // departure and never revised.
  if (detail.visible_ms !== null && detail.visible_ms !== undefined) {
    lines.push('Actually on screen for <b>' + fmtDuration(detail.visible_ms) + '</b>' +
      (detail.hide_count
        ? ', backgrounded ' + detail.hide_count +
          (detail.hide_count === 1 ? ' time' : ' times')
        : ' without interruption'));
  }
  if (detail.nav_type && detail.nav_type !== 'navigate') {
    lines.push('<span class="muted">Arrived by ' + esc(detail.nav_type) +
      ' &mdash; a reload or back-forward mints a new visit id, so this is the ' +
      'same person arriving again.</span>');
  }
  summary.innerHTML = lines.join('<br>');
  wrap.appendChild(summary);

  const context = detail.context || {};
  const campaign = [context.source, context.utm_medium, context.utm_campaign]
    .filter(Boolean).join(' / ');
  const fields = [
    ['Landed on', [context.path, context.query].filter(Boolean).join('?')],
    ['Campaign', campaign],
    ['Referrer', context.referer],
    ['Country', [context.country, context.colo].filter(Boolean).join(' · ')],
    // Height decides how much of the quick-reply strip they were shown, in
    // three bands rather than two — see _shortScreenHeight (720) and
    // _veryShortScreenHeight (560) in chat_screen.dart. The hint yields first
    // because a dropped reply costs more than a dropped label, so between the
    // two thresholds all three prompts are still there.
    //
    // Spelled out rather than left as a number, because "they tapped nothing"
    // reads differently when one of the three options, or the line telling
    // them the options are tappable, was never on screen. Kept in step with
    // those constants by hand: they live in Dart and this is the worker, so
    // nothing enforces the agreement — if the strip's layout thresholds move,
    // move these with them.
    ['Viewport', context.viewport_w
      ? context.viewport_w + '×' + (context.viewport_h || '?') + 'px' +
        (context.viewport_h
          ? (context.viewport_h < 560
              ? ' — very short: 2 of 3 prompts, no hint'
              : context.viewport_h < 720
                ? ' — short: all 3 prompts, but no hint'
                : ' — all 3 prompts and the hint')
          : '')
      : ''],
    ['User agent', context.user_agent],
  ].filter(([, value]) => value);

  if (fields.length) {
    const heading = document.createElement('div');
    heading.className = 'detail-h';
    heading.textContent = 'Where they came from';
    wrap.appendChild(heading);
    const grid = document.createElement('dl');
    grid.className = 'vc-grid';
    for (const [label, value] of fields) {
      const dt = document.createElement('dt');
      dt.textContent = label;
      const dd = document.createElement('dd');
      dd.textContent = value;
      grid.appendChild(dt);
      grid.appendChild(dd);
    }
    wrap.appendChild(grid);
  }

  if ((detail.events || []).length) {
    const heading = document.createElement('div');
    heading.className = 'detail-h';
    heading.textContent = 'Event trail';
    wrap.appendChild(heading);
    renderTimeline(wrap, detail.events, utcClock);
  }

  if (messages.length) {
    const heading = document.createElement('div');
    heading.className = 'detail-h';
    heading.textContent = 'Conversation';
    wrap.appendChild(heading);
    let c = '';
    for (const m of messages) {
      c += '<div style="margin:0 0 12px;padding-left:10px;border-left:2px solid #7e57c2">' +
           '<div class="muted" style="font-size:12px;margin-bottom:3px">' +
           esc(utcClock(m.created_at)) + ' &middot; ' + esc(m.character_id || m.scenario || '') +
           (m.status && m.status !== 'completed' ? ' &middot; <b>' + esc(m.status) + '</b>' : '') +
           // How long they waited on this one reply. Marked when it crosses
           // ten seconds, because that is the wait worth explaining a
           // departure by — and it is the whole reason the column exists.
           (m.latency_ms
             ? ' &middot; <span' + (m.latency_ms >= 10000 ? ' class="warn"' : '') +
               ' title="how long this reply took, end to end">waited ' +
               dur(m.latency_ms) + '</span>'
             : '') +
           '</div>' +
           '<div style="margin-bottom:3px"><b>User:</b> ' + esc(m.user_message) + '</div>' +
           '<div class="muted"><b>Reply:</b> ' +
           (m.assistant_message ? esc(m.assistant_message)
                                : '<span style="color:#e57373">[no reply]</span>') +
           '</div></div>';
    }
    const conv = document.createElement('div');
    conv.innerHTML = c;
    wrap.appendChild(conv);
  }

  cell.appendChild(wrap);
}
if (DAY) {
  document.getElementById('days').style.display = 'none';
  document.querySelector('h1').textContent = 'User sessions — ' + DAY;
}
load();
</script></body></html>`;
}

/// Where the v2 Odysseus script asks its questions, in seconds from the chat
/// screen opening. Measured on the real widget under a virtual clock — see
/// docs/odysseus-v2-handoff-2026-08-10.md. Only the three that fall inside the
/// 28s ping ceiling are listed; the script itself runs to 125s.
///
/// Restated here rather than derived: the pacing constants live in Dart and
/// the worker cannot read them. An annotation that drifted silently would be
/// worse than one that has to be updated deliberately.
const V2_QUESTION_BEATS = [
    { id: "P01", seconds: 6.2 },
    { id: "P02", seconds: 15.4 },
    { id: "P03", seconds: 26.8 },
];

/// Groups the per-(source, tick) counts into one survival curve per source,
/// plus one for everything together.
function buildFirst30(rows, days, exclude, character) {
    const bySource = new Map();
    for (const r of rows) {
        const key = r.source || "unknown";
        if (!bySource.has(key)) bySource.set(key, []);
        bySource.get(key).push(r);
    }
    const sources = [...bySource.entries()]
        .map(([source, list]) => first30Curve(source, list))
        .sort((a, b) => b.opens - a.opens);

    return {
        days,
        exclude_country: exclude || null,
        character: character || null,
        max_ticks: SCREEN_PING_MAX_TICKS,
        beats: V2_QUESTION_BEATS.map((b) => ({
            ...b,
            tick: screenPingTicksAt(b.seconds),
        })),
        overall: first30Curve("all sources", rows),
        sources,
    };
}

/// Of everyone who opened a character, how many were still pinging at each
/// tick.
///
/// Built by accumulating from the last tick down: a visit that recorded N
/// ticks was necessarily present at every tick up to N, so the count at tick T
/// is simply the number of visits whose total is T or more. Tick 0 is every
/// chat open, which is what the shares are a fraction of.
function first30Curve(source, rows) {
    const byTick = new Map();
    let opens = 0;
    let engaged = 0;
    let paused = 0;
    for (const r of rows) {
        const t = r.ticks | 0;
        byTick.set(t, (byTick.get(t) || 0) + r.visits);
        opens += r.visits;
        engaged += r.engaged || 0;
        paused += r.paused || 0;
    }

    const points = [];
    let atOrAbove = 0;
    for (let t = SCREEN_PING_MAX_TICKS; t >= 0; t--) {
        atOrAbove += byTick.get(t) || 0;
        points.push({
            tick: t,
            seconds: t === 0 ? 0 : Number(screenPingSeconds(t).toFixed(1)),
            still_here: atOrAbove,
            share: opens ? Number((atOrAbove / opens).toFixed(4)) : 0,
        });
    }
    points.reverse();
    return { source, opens, engaged, paused, points };
}

function adminFirst30PageHtml() {
    return `<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mythos Live — First 30 seconds</title>
<style>
  body { font: 14px -apple-system, system-ui, sans-serif; margin: 0; padding: 24px;
         background: #14101a; color: #eee; }
  h1 { font-size: 20px; margin: 0 0 4px; }
  p.sub { color: #999; margin: 0 0 20px; max-width: 70ch; }
  select { background: #241d2e; color: #eee; border: 1px solid #443; padding: 6px 10px;
           border-radius: 6px; margin-bottom: 18px; }
  table { border-collapse: collapse; width: 100%; margin-bottom: 28px; }
  th, td { text-align: left; padding: 5px 10px; border-bottom: 1px solid #2c2438; }
  th { color: #b39ddb; font-weight: 600; font-size: 12px; text-transform: uppercase;
       letter-spacing: .04em; }
  td.num { text-align: right; font-variant-numeric: tabular-nums; }
  h2 { font-size: 15px; color: #b39ddb; margin: 26px 0 8px; }
  .muted { color: #777; }
  .wrap { overflow-x: auto; }
  .bar { display: inline-block; height: 11px; background: #7e57c2; border-radius: 2px;
         vertical-align: middle; min-width: 1px; }
  tr.beat td { background: #1d1730; }
  .beatlabel { color: #4ADE80; font-weight: 700; }
  .drop { color: #ef9a9a; }
</style></head><body>
<p style="margin:0 0 14px"><a href="/admin" style="color:#b39ddb">&larr; Admin</a></p>
<h1>First 30 seconds</h1>
<p class="sub">One row per screen_ping tick — 500ms apart for the first ten
   seconds, 3s apart after that — showing how many of the visits that opened a
   character were still on screen at that moment. This is the same data the
   visits page reduces to five dwell buckets, at the resolution it was recorded
   in. Green rows are where the script asks a question. The drop column is how
   many left during that tick.</p>
<select id="days" onchange="load()">
  <option value="1">Last 24 hours</option>
  <option value="2" selected>Last 2 days</option>
  <option value="7">Last 7 days</option>
  <option value="30">Last 30 days</option>
</select>
<div id="out">Loading…</div>
<script>
async function load() {
  var days = document.getElementById('days').value;
  var out = document.getElementById('out');
  out.textContent = 'Loading…';
  var r = await fetch('/api/admin/first30?days=' + days);
  if (!r.ok) { out.textContent = 'Failed: ' + r.status; return; }
  var d = await r.json();
  if (d.error) { out.textContent = d.error; return; }
  out.innerHTML = '';

  var beatAt = {};
  (d.beats || []).forEach(function (b) { beatAt[b.tick] = b; });

  var groups = [d.overall].concat(d.sources || []);
  groups.forEach(function (g) {
    if (!g || !g.opens) return;
    var h = document.createElement('h2');
    h.textContent = g.source + ' — ' + g.opens + ' chat opens, ' +
      g.engaged + ' engaged' +
      (g.paused ? ', ' + g.paused + ' look backgrounded' : '');
    out.appendChild(h);

    var wrap = document.createElement('div');
    wrap.className = 'wrap';
    var t = document.createElement('table');
    t.innerHTML = '<thead><tr><th>At</th><th>Script</th>' +
      '<th data-type="num">Still here</th><th data-type="num">Share</th>' +
      '<th data-type="num">Left here</th><th></th></tr></thead>';
    var tb = document.createElement('tbody');

    g.points.forEach(function (p, i) {
      var prev = i > 0 ? g.points[i - 1].still_here : p.still_here;
      var lost = prev - p.still_here;
      var beat = beatAt[p.tick];
      var tr = document.createElement('tr');
      if (beat) tr.className = 'beat';
      tr.innerHTML =
        '<td>' + p.seconds.toFixed(1) + 's</td>' +
        '<td class="beatlabel">' + (beat ? beat.id + ' asks' : '') + '</td>' +
        '<td class="num">' + p.still_here + '</td>' +
        '<td class="num">' + Math.round(p.share * 1000) / 10 + '%</td>' +
        '<td class="num ' + (lost ? 'drop' : 'muted') + '">' + (lost || '') + '</td>' +
        '<td><span class="bar" style="width:' + (p.share * 240).toFixed(1) + 'px"></span></td>';
      tb.appendChild(tr);
    });
    t.appendChild(tb);
    wrap.appendChild(t);
    out.appendChild(wrap);
  });

  if (!(d.sources || []).length) out.textContent = 'No chat opens in this window.';
}
load();
</script>
</body></html>`;
}

function adminVisitsPageHtml() {
    return `<!DOCTYPE html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mythos Live — Site visits</title>
<style>
  body { font: 14px -apple-system, system-ui, sans-serif; margin: 0; padding: 24px;
         background: #14101a; color: #eee; }
  h1 { font-size: 20px; margin: 0 0 4px; }
  p.sub { color: #999; margin: 0 0 20px; }
  select { background: #241d2e; color: #eee; border: 1px solid #443; padding: 6px 10px;
           border-radius: 6px; margin-bottom: 18px; }
  table { border-collapse: collapse; width: 100%; margin-bottom: 28px; }
  th, td { text-align: left; padding: 7px 10px; border-bottom: 1px solid #2c2438; }
  th { color: #b39ddb; font-weight: 600; font-size: 12px; text-transform: uppercase;
       letter-spacing: .04em; }
  td.num { text-align: right; font-variant-numeric: tabular-nums; }
  h2 { font-size: 15px; color: #b39ddb; margin: 26px 0 8px; }
  .muted { color: #777; }
  .wrap { overflow-x: auto; }
  a.drill { color: #b39ddb; }
  tr.chat td { background: #191322; }
${sortableTableCss()}
</style></head><body>
<p style="margin:0 0 14px"><a href="/admin" style="color:#b39ddb">&larr; Admin</a></p>
<h1>Site visits</h1>
<p class="sub">Every arrival, logged from the splash screen before the app loads —
   not just /c/ campaign links. Click any column heading to sort by it, again to
   reverse.</p>
<select id="days" onchange="load()">
  <option value="1">Last 24 hours</option>
  <option value="7" selected>Last 7 days</option>
  <option value="30">Last 30 days</option>
  <option value="90">Last 90 days</option>
</select>
<div id="out">Loading…</div>
<script>
${sortableTableJs()}
function esc(v) {
  return String(v === null || v === undefined ? '' : v)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}
function dur(ms) {
  if (ms === null || ms === undefined) return '<span class="muted">—</span>';
  return ms < 1000 ? ms + 'ms' : (ms/1000).toFixed(1) + 's';
}
// Sort key for a cell whose visible text is formatted ("1.4s", "12 (34%)") or
// unknown ("—"). Empty means unknown, which sorts last either way.
function sv(value) {
  return ' data-sv="' + (value === null || value === undefined ? '' : value) + '"';
}
// Tick -> seconds has to be computable in the browser as well, because each
// row's own tick count is only known here. The worker's constants are
// interpolated in rather than written out a second time, so the two copies
// cannot drift; calling the worker's screenPingSeconds() directly from this
// script is what left the page stuck on "Loading…" — it is a module-scope
// function that does not exist in the page.
const PING = ${JSON.stringify({
        phase1Ticks: SCREEN_PING_PHASE1_TICKS,
        phase1Interval: SCREEN_PING_PHASE1_INTERVAL_SECONDS,
        phase1Seconds: SCREEN_PING_PHASE1_SECONDS,
        phase2Interval: SCREEN_PING_PHASE2_INTERVAL_SECONDS,
        maxTicks: SCREEN_PING_MAX_TICKS,
    })};
function screenPingSeconds(ticks) {
  return ticks <= PING.phase1Ticks
    ? ticks * PING.phase1Interval
    : PING.phase1Seconds + (ticks - PING.phase1Ticks) * PING.phase2Interval;
}
// Anything thrown in here used to leave "Loading…" on screen with the real
// error only in the console, which is indistinguishable from a slow request.
// load() now always reports what went wrong on the page itself.
function load() {
  const out = document.getElementById('out');
  out.textContent = 'Loading…';
  render(out).catch(function (err) {
    console.error('visits page failed', err);
    out.innerHTML = '<p style="color:#e57373">Could not load this page: ' +
      esc(err && err.message ? err.message : err) + '</p>';
  });
}
async function render(out) {
  const days = document.getElementById('days').value;
  const res = await fetch('/api/admin/visits?days=' + days);
  if (!res.ok) { out.textContent = 'Error ' + res.status; return; }
  const d = await res.json();
  let h = '';

  h += '<h2>Funnel</h2><p class="muted" style="margin:0 0 8px">' +
       'Distinct visits reaching each step. The biggest drop is where you are ' +
       'losing people.</p><div class="wrap"><table class="sortable"><tr><th>Source</th>' +
       '<th data-type="num" data-sorted="desc">Arrived</th><th data-type="num">App loaded</th>' +
       '<th data-type="num">Opened a character</th>' +
       '<th data-type="num">Typed or tapped a starter</th><th data-type="num">Sent a message</th>' +
       '<th data-type="num">Hit login gate</th></tr>';
  for (const r of d.funnel || []) {
    function pct(n) {
      return r.arrived ? ' <span class="muted">(' + Math.round(100*n/r.arrived) + '%)</span>' : '';
    }
    h += '<tr><td>' + esc(r.source) + '</td><td class="num"' + sv(r.arrived) + '>' + r.arrived +
         '</td><td class="num"' + sv(r.loaded) + '>' + r.loaded + pct(r.loaded) +
         '</td><td class="num"' + sv(r.tapped) + '>' + r.tapped + pct(r.tapped) +
         '</td><td class="num"' + sv(r.engaged) + '>' + r.engaged + pct(r.engaged) +
         '</td><td class="num"' + sv(r.messaged) + '>' + r.messaged + pct(r.messaged) +
         '</td><td class="num"' + sv(r.gated) + '>' + r.gated + pct(r.gated) + '</td></tr>';
  }
  if (!(d.funnel || []).length) h += '<tr><td colspan="7" class="muted">No data yet.</td></tr>';
  h += '</table></div>';

  const buckets = d.dwellBuckets || [];
  if (buckets.length) {
    h += '<h2>How long before giving up</h2><p class="muted" style="margin:0 0 8px">' +
         'Visits that opened a character and never typed, tapped a starter, or sent ' +
         'anything. Left instantly means gone before the first half-second tick &mdash; ' +
         'the screen never had a chance. Stayed the full 30s means they were still ' +
         'reading when we stopped counting.</p><div class="wrap"><table class="sortable"><tr><th>Source</th>' +
         // Last column is labelled from the real cap rather than a written-in
         // "30s": the slow phase's final tick lands at 28s, not 30, so a fixed
         // label would overstate by two seconds and quietly rot again the next
         // time the cadence moves.
         '<th data-type="num" data-sorted="desc">Never engaged</th>' +
         '<th data-type="num">Left instantly</th><th data-type="num">&lt;5s</th>' +
         '<th data-type="num">5&ndash;15s</th>' +
         '<th data-type="num">15&ndash;' + screenPingSeconds(PING.maxTicks) + 's</th>' +
         '<th data-type="num">Stayed ' + screenPingSeconds(PING.maxTicks) + 's+</th></tr>';
    for (const r of buckets) {
      h += '<tr><td>' + esc(r.source) + '</td><td class="num"' + sv(r.never_engaged) + '>' + r.never_engaged +
           '</td><td class="num"' + sv(r.left_instantly || 0) + '>' + (r.left_instantly || 0) +
           '</td><td class="num"' + sv(r.left_under_5s || 0) + '>' + (r.left_under_5s || 0) +
           '</td><td class="num"' + sv(r.left_5s_to_15s || 0) + '>' + (r.left_5s_to_15s || 0) +
           '</td><td class="num"' + sv(r.left_15s_to_30s || 0) + '>' + (r.left_15s_to_30s || 0) +
           '</td><td class="num"' + sv(r.stayed_full_30s || 0) + '>' + (r.stayed_full_30s || 0) + '</td></tr>';
    }
    h += '</table></div>';
  }

  const chars = d.characters || [];
  if (chars.length) {
    h += '<h2>By character</h2><div class="wrap"><table class="sortable"><tr><th>Character</th>' +
         '<th>Event</th><th data-type="num" data-sorted="desc">Count</th></tr>';
    for (const r of chars) {
      h += '<tr><td>' + esc(r.character_id) + '</td><td>' + esc(r.event) +
           '</td><td class="num"' + sv(r.n) + '>' + r.n + '</td></tr>';
    }
    h += '</table></div>';
  }

  // Source is the link they followed; client is the app that rendered it. They
  // are separate columns because they answer different questions and the tag
  // cannot answer the second one — see visitClientSql in the worker.
  //
  // "Left under 3s" and "Avg dwell" are both computed over visits that
  // reported a leave, which is a smaller population than Visits: a tab killed
  // outright never fires the beacon. Showing the count alone invited reading
  // it against Visits, which understates the bounce rate by however many
  // visits went unreported — so the denominator is now a column of its own and
  // the percentage is taken against it.
  h += '<h2>By source and client</h2><p class="muted" style="margin:0 0 8px">' +
       'One row per visit, not per logged event. <b>Source</b> is the utm tag on ' +
       'the link; <b>client</b> is the app that actually rendered the page, read ' +
       'from the user-agent. A bio link tagged <code>?utm_source=ig</code> reads ' +
       '&ldquo;ig&rdquo; even when Facebook&rsquo;s in-app browser opened it, so ' +
       'trust the client column for that question. <b>Reported a dwell</b> is the ' +
       'denominator for the two columns after it &mdash; visits whose tab was ' +
       'killed outright never report one and cannot be counted either way.</p>' +
       '<div class="wrap"><table class="sortable"><tr><th>Source</th><th>Client</th>' +
       '<th data-type="num" data-sorted="desc">Visits</th>' +
       '<th data-type="num">Saw the app</th><th data-type="num">Gave up loading</th>' +
       '<th data-type="num">Avg load</th>' +
       '<th data-type="num">Reported a dwell</th>' +
       '<th data-type="num">Left under 3s</th><th data-type="num">Avg dwell</th></tr>';
  for (const r of d.bySource) {
    const gaveUp = r.visits - (r.saw_app || 0);
    const known = r.with_duration || 0;
    const bounced = r.bounced_under_3s || 0;
    const bouncePct = known
      ? ' <span class="muted">(' + Math.round(100 * bounced / known) + '%)</span>'
      : '';
    // No leave rows at all means the dwell columns have nothing behind them;
    // an em dash says so rather than letting a 0 read as "nobody bounced".
    h += '<tr><td>' + esc(r.source) + '</td><td>' + esc(r.client || 'unknown') +
         '</td><td class="num"' + sv(r.visits) + '>' + r.visits +
         '</td><td class="num"' + sv(r.saw_app || 0) + '>' + (r.saw_app || 0) +
         '</td><td class="num"' + sv(gaveUp) + '>' + gaveUp +
         '</td><td class="num"' + sv(r.avg_load_ms) + '>' + dur(r.avg_load_ms) +
         '</td><td class="num"' + sv(known) + '>' + known +
         ' <span class="muted">of ' + r.visits + '</span>' +
         '</td><td class="num"' + sv(known ? bounced : null) + '>' +
         (known ? bounced + bouncePct : '<span class="muted">&mdash;</span>') +
         '</td><td class="num"' + sv(r.avg_ms) + '>' + dur(r.avg_ms) + '</td></tr>';
  }
  if (!d.bySource.length) h += '<tr><td colspan="9" class="muted">No visits yet.</td></tr>';
  h += '</table></div>';

  // Each day drills into the sessions that made up its count. Same
  // date(created_at) grouping on both sides, so the number here and the number
  // of rows there agree.
  h += '<h2>By day</h2><p class="muted" style="margin:0 0 8px">' +
       'Pick a day to see its individual sessions, newest first.</p>' +
       '<div class="wrap"><table class="sortable"><tr><th data-sorted="desc">Day</th>' +
       '<th data-type="num">Visits</th></tr>';
  for (const r of d.byDay) {
    h += '<tr><td><a class="drill" href="/admin/sessions?day=' + encodeURIComponent(r.day) +
         '">' + esc(r.day) + '</a></td><td class="num"' + sv(r.visits) + '>' + r.visits + '</td></tr>';
  }
  h += '</table></div>';

  h += '<h2>Recent arrivals</h2><div class="wrap"><table class="sortable">' +
       '<tr><th data-sorted="desc">When (UTC)</th><th>Path</th>' +
       '<th>Source</th><th>Client</th><th>Campaign</th><th>Country</th><th data-type="num">Load</th>' +
       '<th data-type="num">Dwell</th>' +
       '<th data-type="num">Ticks</th><th data-nosort>Chat</th></tr>';
  for (const r of d.recent) {
    // Ticks only mean anything once a character was opened — a visit that
    // never reached one shows "—", not 0, so "left instantly after opening a
    // character" is never confused with "never opened one at all". A visit
    // still open right now (no leave row) shows its ticks-so-far live,
    // updating on every page refresh even with no session log of its own.
    const ticksCell = r.opened_character
      ? '<span title="' + (r.ticks || 0) + ' ticks = ~' +
        screenPingSeconds(r.ticks || 0) + 's on the chat screen">' +
        (r.ticks || 0) + '</span>'
      : '<span class="muted">—</span>';
    h += '<tr><td>' + esc(r.created_at) + '</td><td>' + esc(r.path) +
         '</td><td>' + esc(r.source) + '</td><td>' + esc(r.client || 'unknown') + '</td><td>' +
         esc([r.utm_medium, r.utm_campaign].filter(Boolean).join(' / ')) +
         '</td><td>' + esc(r.country) + '</td><td class="num"' + sv(r.load_ms) + '>' + dur(r.load_ms) +
         '</td><td class="num"' + sv(r.duration_ms) + '>' + dur(r.duration_ms) +
         '</td><td class="num"' + sv(r.opened_character ? (r.ticks || 0) : null) + '>' +
         ticksCell + '</td><td>' +
         (r.messaged
           ? '<a href="#" class="drill" data-v="' + esc(r.visit_id) + '">view</a>'
           : '<span class="muted">—</span>') +
         '</td></tr><tr class="chat" id="chat-' + esc(r.visit_id) +
         '" style="display:none"><td colspan="10"></td></tr>';
  }
  if (!d.recent.length) h += '<tr><td colspan="10" class="muted">Nothing yet.</td></tr>';
  h += '</table></div>';
  out.innerHTML = h;
  makeSortable(out);

  // Expand a visit into its transcript in place, rather than navigating away
  // and losing the list position.
  out.querySelectorAll('a.drill').forEach(function (a) {
    a.addEventListener('click', async function (ev) {
      ev.preventDefault();
      const vid = a.getAttribute('data-v');
      const row = document.getElementById('chat-' + vid);
      if (row.style.display !== 'none') { row.style.display = 'none'; return; }
      row.style.display = '';
      const cell = row.firstElementChild;
      cell.innerHTML = '<span class="muted">Loading…</span>';
      const res = await fetch('/api/admin/visit-chat?visit_id=' + encodeURIComponent(vid));
      if (!res.ok) { cell.innerHTML = '<span class="muted">Error ' + res.status + '</span>'; return; }
      const data = await res.json();
      if (!data.messages.length) {
        cell.innerHTML = '<span class="muted">No messages recorded for this visit.</span>';
        return;
      }
      let c = '<div style="padding:6px 0 10px">';
      for (const m of data.messages) {
        c += '<div style="margin:0 0 12px;padding-left:10px;border-left:2px solid #7e57c2">' +
             '<div class="muted" style="font-size:12px;margin-bottom:3px">' +
             esc(m.created_at) + ' &middot; ' + esc(m.character_id || m.scenario || '') +
             (m.status && m.status !== 'completed' ? ' &middot; <b>' + esc(m.status) + '</b>' : '') +
             '</div>' +
             '<div style="margin-bottom:3px"><b>User:</b> ' + esc(m.user_message) + '</div>' +
             '<div class="muted"><b>Reply:</b> ' + esc(m.assistant_message) + '</div>' +
             (m.error ? '<div style="color:#e57373">' + esc(m.error) + '</div>' : '') +
             '</div>';
      }
      c += '</div>';
      cell.innerHTML = c;
    });
  });
}
load();
</script></body></html>`;
}

function adminReferralsPageHtml() {
    return `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="robots" content="noindex, nofollow">
<title>Mythos Live - Campaign Links</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0; background: #0f0f14; color: #e6e6ea; }
  header { padding: 16px 24px; border-bottom: 1px solid #2a2a33; display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
  header h1 { font-size: 18px; margin: 0 auto 0 0; }
  a { color: #8ab4ff; }
  select, button { background: #1c1c24; border: 1px solid #33333d; color: #e6e6ea; padding: 6px 10px; border-radius: 6px; font-size: 13px; }
  main { padding: 16px 24px; max-width: 1100px; margin: 0 auto; }
  h2 { font-size: 14px; color: #9a9aa5; text-transform: uppercase; letter-spacing: .06em; margin: 28px 0 8px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid #22222a; }
  th { color: #9a9aa5; font-weight: 600; }
  .num { text-align: right; font-variant-numeric: tabular-nums; }
  .muted { color: #6f6f7a; }
  .warn { color: #ffb454; }
  .big { font-size: 26px; font-weight: 600; }
  .wrap { overflow-x: auto; }
${sortableTableCss()}
</style>
</head>
<body>
<header>
  <h1>Campaign Links</h1>
  <a href="/admin/logs">Chat logs &rarr;</a>
  <select id="days" onchange="load()">
    <option value="1">Last 24 hours</option>
    <option value="7" selected>Last 7 days</option>
    <option value="30">Last 30 days</option>
    <option value="90">Last 90 days</option>
  </select>
</header>
<main>
  <div class="big" id="total">-</div>
  <div class="muted">link arrivals in the selected window</div>

  <h2>By source</h2>
  <div class="wrap"><table id="src" class="sortable"><thead><tr><th>Source</th><th class="num" data-type="num" data-sorted="desc">Visits</th></tr></thead><tbody></tbody></table></div>

  <h2>By character</h2>
  <p class="muted" style="margin:0 0 8px;max-width:80ch">
     <b>People who chatted</b> counts distinct real user ids that messaged this
     character in the same window, test ids excluded. It is deliberately not
     called a conversion rate: campaign-link arrivals carry no user or visit id,
     so there is no way to tell that the person who messaged is the person who
     arrived through the link. Two counts over one window, read side by side.</p>
  <div class="wrap"><table id="chr" class="sortable"><thead><tr><th>Character</th><th class="num" data-type="num" data-sorted="desc">Link hits</th><th class="num" data-type="num">People who chatted</th><th class="num" data-type="num">Bad links</th></tr></thead><tbody></tbody></table></div>

  <h2>Recent arrivals</h2>
  <div class="wrap"><table id="rec" class="sortable"><thead><tr><th data-sorted="desc">When (UTC)</th><th>Character</th><th>Source</th><th>Medium</th><th>Campaign</th></tr></thead><tbody></tbody></table></div>
</main>
<script>
${sortableTableJs()}
const esc = s => (s == null ? '' : String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])));
// Sort key for a cell whose visible text carries a suffix or a dash.
const sv = v => ' data-sv="' + (v === null || v === undefined ? '' : v) + '"';
// Same guard as the visits page: without it a failed request or a throw
// mid-render leaves the last-rendered numbers (or the empty shell) on screen
// with nothing to say something went wrong.
function load() {
  render().catch(function (err) {
    console.error('referrals page failed', err);
    document.getElementById('total').textContent =
      'error: ' + (err && err.message ? err.message : err);
  });
}
async function render() {
  const days = document.getElementById('days').value;
  const res = await fetch('/api/admin/referrals?days=' + days);
  if (!res.ok) throw new Error('HTTP ' + res.status);
  const d = await res.json();
  if (d.error) { document.getElementById('total').textContent = d.error; return; }
  document.getElementById('total').textContent = d.totalVisits ?? 0;
  document.querySelector('#src tbody').innerHTML = (d.bySource || [])
    .map(r => '<tr><td>' + esc(r.source || 'unknown') + '</td><td class="num"' + sv(r.visits) + '>' + r.visits + '</td></tr>').join('')
    || '<tr><td colspan="2" class="muted">No visits yet.</td></tr>';
  document.querySelector('#chr tbody').innerHTML = (d.byCharacter || [])
    .map(r => '<tr><td>' + esc(r.character_id || '(none)') + '</td><td class="num"' + sv(r.visits) + '>' + r.visits +
      '</td><td class="num"' + sv(r.chatters ?? 0) + '>' + (r.chatters ?? 0) +
      '</td><td class="num ' + (r.unknown_hits ? 'warn' : 'muted') + '"' + sv(r.unknown_hits || 0) + '>' +
      (r.unknown_hits || 0) + '</td></tr>').join('')
    || '<tr><td colspan="4" class="muted">No visits yet.</td></tr>';
  document.querySelector('#rec tbody').innerHTML = (d.recent || [])
    .map(r => '<tr><td class="muted">' + esc(r.created_at) + '</td><td>' + esc(r.character_id || '-') +
      (r.known_character === 0 ? ' <span class="warn">(unknown)</span>' : '') +
      '</td><td>' + esc(r.source || '-') + '</td><td>' + esc(r.utm_medium || '-') + '</td><td>' + esc(r.utm_campaign || '-') + '</td></tr>').join('')
    || '<tr><td colspan="5" class="muted">No visits yet.</td></tr>';
  // Headers live in the static shell here, not in the replaced tbody, so this
  // both wires them the first time and clears stale arrows on every refresh.
  makeSortable(document);
}
load();
</script>
</body>
</html>`;
}

function adminLogsPageHtml() {
    return `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Mythos Live - Chat Logs</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0; background: #0f0f14; color: #e6e6ea; }
  header { padding: 16px 24px; border-bottom: 1px solid #2a2a33; display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
  header h1 { font-size: 18px; margin: 0; }
  header a { color: #9a9aa5; font-size: 13px; text-decoration: none; }
  header a:hover { color: #e6e6ea; }
  header .spacer { margin-left: auto; }
  input, select, button { background: #1c1c24; border: 1px solid #33333d; color: #e6e6ea; padding: 6px 10px; border-radius: 6px; font-size: 13px; }
  input[type="date"] { color-scheme: dark; }
  button { cursor: pointer; }
  button:hover:not(:disabled) { background: #26262f; }
  button:disabled { opacity: 0.4; cursor: default; }
  button.ghost { background: transparent; }
  label.chk { font-size: 13px; color: #9a9aa5; display: flex; align-items: center; gap: 4px; }
  main { padding: 16px 24px 48px; max-width: 1100px; margin: 0 auto; }
  .filters { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; margin-bottom: 12px; }
  .filters .spacer { margin-left: auto; }
  .table-wrap { overflow-x: auto; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid #22222a; vertical-align: top; }
  th { color: #9a9aa5; font-weight: 600; white-space: nowrap; }
  /* The header has to stay readable while a long page scrolls under it —
     otherwise you lose which column the numbers belong to by row twenty. */
  thead th { position: sticky; top: 0; background: #0f0f14; z-index: 1; }
  th.sortable { cursor: pointer; user-select: none; }
  th.sortable:hover { color: #e6e6ea; }
  th .arrow { color: #6b6b78; font-size: 10px; margin-left: 3px; }
  th.sorted { color: #b39ddb; }
  th.sorted .arrow { color: #b39ddb; }
  tr.conv-row, tr.log-row { cursor: pointer; }
  tr.conv-row:hover, tr.log-row:hover { background: #17171d; }
  .err-badge { color: #e57373; font-weight: 600; }
  .pager { display: flex; gap: 8px; align-items: center; margin-top: 12px; font-size: 13px; color: #9a9aa5; }
  .empty, .error { padding: 24px; color: #9a9aa5; text-align: center; }
  .error { color: #e57373; }
  h2 { font-size: 15px; color: #9a9aa5; margin: 28px 0 8px; }
  h2 .sub { font-weight: 400; color: #55555f; }
  .status-completed { color: #6fd08c; }
  .status-ai_error, .status-rejected_validation { color: #e57373; }
  .status-rate_limited { color: #e5b573; }
  .preview { max-width: 320px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  mark { background: #4a3f1a; color: #f5e3a8; border-radius: 2px; padding: 0 1px; }

  /* Totals for what is on screen. The pager says how many rows matched; this
     says what they add up to, which is the question you ask next. */
  .summary { font-size: 12px; color: #9a9aa5; margin-bottom: 10px; min-height: 16px; }
  .summary b { color: #e6e6ea; font-weight: 600; }
  .summary .sep { color: #3a3a45; margin: 0 8px; }
  /* The "N test ids hidden" note. Every other admin page defines .muted and
     this one used it without ever declaring it, so the one line on the page
     whose job is to read as an aside rendered at full strength instead. */
  .muted { color: #6b6b78; }

  /* Transcript view */
  #t-meta { color: #9a9aa5; font-size: 13px; margin-bottom: 8px; }
  #t-actions { font-size: 12px; margin-bottom: 16px; }
  #t-actions a { color: #7e9fd6; cursor: pointer; text-decoration: none; }
  #t-actions a:hover { text-decoration: underline; }
  .bubble-row { display: flex; margin-bottom: 4px; }
  .bubble { max-width: 72%; padding: 10px 14px; border-radius: 14px; white-space: pre-wrap; word-break: break-word; font-size: 14px; line-height: 1.4; }
  .bubble.user { margin-left: auto; background: #52203f; border-bottom-right-radius: 4px; }
  .bubble.ai { margin-right: auto; background: #1c1c24; border-bottom-left-radius: 4px; }
  .bubble.failed { background: #2a1518; color: #e57373; font-style: italic; }
  .ex-meta { font-size: 11px; color: #55555f; margin: 2px 0 14px; }
  .ex-meta .err-text { color: #e57373; }
  .gap-divider { text-align: center; color: #9a9aa5; font-size: 12px; margin: 16px 0; }
  .exchange.flash { animation: flash 1.4s ease-out; }
  @keyframes flash { from { background: #2a1518; } to { background: transparent; } }

  /* Visits that opened a character and never typed. Dimmed so the eye still
     lands on real conversations first, but present so the drop-off is
     countable instead of invisible. */
  tr.silent td { color: #6b6b78; }
  tr.silent td.ch { font-style: italic; }
  .tick-badge { color: #7e9fd6; }
  .silent-note { color: #9a9aa5; font-style: italic; }

  /* Tick trail */
${visitTimelineCss()}

  @media (max-width: 720px) {
    main { padding: 12px; }
    .bubble { max-width: 88%; }
  }
</style>
</head>
<body>
<header>
  <h1>Chat Logs</h1>
  <a href="/admin">&larr; Admin</a>
  <a href="/admin/referrals">Campaign links &rarr;</a>
  <span class="spacer"></span>
  <span id="transcript-controls" style="display: none;">
    <button id="copy-btn">Copy transcript</button>
    <button id="export-conv-btn">Export conversation</button>
    <button id="back-btn">&larr; Back</button>
  </span>
</header>
<main>
  <section id="view-list">
    <div class="filters">
      <input id="f-character" placeholder="character" size="12">
      <input id="f-user" placeholder="user_id" size="12">
      <input id="f-q" placeholder="search message text" size="20">
      <select id="f-range" title="date range (UTC)">
        <option value="">any time</option>
        <option value="0">today</option>
        <option value="1">last 2 days</option>
        <option value="7">last 7 days</option>
        <option value="30">last 30 days</option>
        <option value="custom">custom</option>
      </select>
      <input type="date" id="f-from" title="from (UTC)">
      <input type="date" id="f-to" title="to (UTC), inclusive">
      <select id="f-show" title="which rows to list">
        <option value="all">all rows</option>
        <option value="engaged">conversations only</option>
        <option value="silent">silent visits only</option>
      </select>
      <label class="chk"><input type="checkbox" id="f-errors"> errors only</label>
      <label class="chk" title="test ids (user_test_*, hand-typed ids) are hidden by default — they are still in the table, just not counted here"><input type="checkbox" id="f-include-test"> include test ids</label>
      <button id="search-btn">Search</button>
      <button id="reset-btn" class="ghost">Reset</button>
      <span class="spacer"></span>
      <select id="export-days" title="how far back to export">
        <option value="1">last 24 hours</option>
        <option value="7">last 7 days</option>
        <option value="30" selected>last 30 days</option>
        <option value="90">last 90 days</option>
      </select>
      <button id="export-btn">Export</button>
    </div>
    <div id="summary" class="summary"></div>
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th class="sortable" data-sort="chat_id">Character</th>
            <th>User</th>
            <th class="sortable" data-sort="message_count">Messages</th>
            <th class="sortable" data-sort="tick_count">Ticks</th>
            <th class="sortable" data-sort="error_count">Errors</th>
            <th class="sortable" data-sort="slowest_reply_ms" title="the longest this conversation waited for a reply">Slowest reply</th>
            <th class="sortable" data-sort="total_tokens">Tokens</th>
            <th class="sortable" data-sort="first_at">First</th>
            <th class="sortable" data-sort="last_at">Last active</th>
          </tr>
        </thead>
        <tbody id="conv-rows"></tbody>
      </table>
    </div>
    <div class="pager">
      <button id="prev-btn">Prev</button>
      <span id="page-info"></span>
      <button id="next-btn">Next</button>
      <select id="page-size" title="rows per page">
        <option value="25">25</option>
        <option value="50" selected>50</option>
        <option value="100">100</option>
        <option value="200">200</option>
      </select>
    </div>
    <h2>Recent errors <span class="sub">(latest 10, unfiltered)</span></h2>
    <div class="table-wrap">
      <table>
        <thead>
          <tr><th>Time</th><th>User</th><th>Chat</th><th>Status</th><th>User message</th></tr>
        </thead>
        <tbody id="error-rows"></tbody>
      </table>
    </div>
  </section>
  <section id="view-transcript" style="display: none;">
    <div id="t-meta"></div>
    <div id="t-actions"></div>
    <div id="t-messages"></div>
  </section>
</main>
<script>
${visitTimelineJs()}
(function () {
  // Every filter lives in the URL, so a view is a link: a conversation worth
  // showing someone, or a search worth coming back to, survives a refresh and
  // the browser Back button steps out of a transcript instead of leaving the
  // page entirely.
  var DEFAULTS = {
    character: "", user: "", q: "", from: "", to: "", show: "all",
    errors: false, includeTest: false, sort: "last_at", dir: "desc",
    offset: 0, limit: 50,
  };
  var state = {};
  var view = { name: "list" };
  var lastData = null;      // conversations payload, for the summary line
  var transcriptText = "";  // what the Copy button copies

  var convRowsEl = document.getElementById("conv-rows");
  var errorRowsEl = document.getElementById("error-rows");
  var summaryEl = document.getElementById("summary");
  var pageInfoEl = document.getElementById("page-info");
  var prevBtnEl = document.getElementById("prev-btn");
  var nextBtnEl = document.getElementById("next-btn");

  function el(id) { return document.getElementById(id); }

  function td(text) {
    var cell = document.createElement("td");
    cell.textContent = (text === null || text === undefined) ? "" : String(text);
    return cell;
  }

  function fmtTime(utc) {
    try {
      var d = parseUtc(utc);
      return isNaN(d.getTime()) ? String(utc) : d.toLocaleString();
    } catch (e) { return String(utc); }
  }

  function characterName(chatId) {
    var i = chatId.indexOf(" (");
    return i > 0 ? chatId.slice(0, i) : chatId;
  }

  function shortUser(userId) {
    return userId.length > 18 ? userId.slice(0, 15) + "..." : userId;
  }

  function emptyMessage(tbody, cols, text, className) {
    tbody.innerHTML = "";
    var row = document.createElement("tr");
    var cell = document.createElement("td");
    cell.colSpan = cols;
    cell.className = className;
    cell.textContent = text;
    row.appendChild(cell);
    tbody.appendChild(row);
  }

  // ---- URL <-> state ------------------------------------------------------

  function readUrl() {
    var sp = new URLSearchParams(location.search);
    state = {
      character: sp.get("character") || "",
      user: sp.get("user_id") || "",
      q: sp.get("q") || "",
      from: sp.get("from") || "",
      to: sp.get("to") || "",
      show: sp.get("show") === "engaged" || sp.get("show") === "silent" ? sp.get("show") : "all",
      errors: sp.get("errors_only") === "1",
      includeTest: sp.get("include_test") === "1",
      sort: sp.get("sort") || "last_at",
      dir: sp.get("dir") === "asc" ? "asc" : "desc",
      offset: Math.max(0, parseInt(sp.get("offset"), 10) || 0),
      limit: [25, 50, 100, 200].indexOf(parseInt(sp.get("limit"), 10)) >= 0
        ? parseInt(sp.get("limit"), 10) : 50,
    };
    var v = sp.get("view");
    if (v === "transcript" && sp.get("chat")) {
      view = { name: "transcript", user: sp.get("user") || "", chat: sp.get("chat") };
    } else if (v === "visit" && sp.get("visit")) {
      view = { name: "visit", visit: sp.get("visit"), chat: sp.get("chat") || "" };
    } else {
      view = { name: "list" };
    }
  }

  // Only non-default values, so a plain search stays a readable link.
  function filterParams() {
    var sp = new URLSearchParams();
    if (state.character) sp.set("character", state.character);
    if (state.user) sp.set("user_id", state.user);
    if (state.q) sp.set("q", state.q);
    if (state.from) sp.set("from", state.from);
    if (state.to) sp.set("to", state.to);
    if (state.show !== DEFAULTS.show) sp.set("show", state.show);
    if (state.errors) sp.set("errors_only", "1");
    if (state.includeTest) sp.set("include_test", "1");
    if (state.sort !== DEFAULTS.sort) sp.set("sort", state.sort);
    if (state.dir !== DEFAULTS.dir) sp.set("dir", state.dir);
    if (state.offset) sp.set("offset", state.offset);
    if (state.limit !== DEFAULTS.limit) sp.set("limit", state.limit);
    return sp;
  }

  function writeUrl(push) {
    var sp = filterParams();
    if (view.name === "transcript") {
      sp.set("view", "transcript");
      sp.set("user", view.user);
      sp.set("chat", view.chat);
    } else if (view.name === "visit") {
      sp.set("view", "visit");
      sp.set("visit", view.visit);
      if (view.chat) sp.set("chat", view.chat);
    }
    var qs = sp.toString();
    var url = location.pathname + (qs ? "?" + qs : "");
    if (push) history.pushState(null, "", url);
    else history.replaceState(null, "", url);
  }

  function syncControls() {
    el("f-character").value = state.character;
    el("f-user").value = state.user;
    el("f-q").value = state.q;
    el("f-from").value = state.from;
    el("f-to").value = state.to;
    el("f-show").value = state.show;
    el("f-errors").checked = state.errors;
    el("f-include-test").checked = state.includeTest;
    el("page-size").value = String(state.limit);
    el("f-range").value = rangePreset();
    // A date range and a rolling "last N days" export window would contradict
    // each other; the range wins, so hide the one that is not in effect.
    var ranged = !!(state.from || state.to);
    el("export-days").style.display = ranged ? "none" : "";
    el("export-btn").textContent = ranged ? "Export range" : "Export";

    var ths = document.querySelectorAll("th.sortable");
    for (var i = 0; i < ths.length; i++) {
      var th = ths[i];
      var isSorted = th.getAttribute("data-sort") === state.sort;
      th.className = "sortable" + (isSorted ? " sorted" : "");
      var arrow = document.createElement("span");
      arrow.className = "arrow";
      arrow.textContent = isSorted ? (state.dir === "asc" ? "\\u25B2" : "\\u25BC") : "";
      th.textContent = th.getAttribute("data-label");
      th.appendChild(arrow);
    }
  }

  function readControls() {
    state.character = el("f-character").value.trim();
    state.user = el("f-user").value.trim();
    state.q = el("f-q").value.trim();
    state.from = el("f-from").value;
    state.to = el("f-to").value;
    state.show = el("f-show").value;
    state.errors = el("f-errors").checked;
    state.includeTest = el("f-include-test").checked;
    state.limit = parseInt(el("page-size").value, 10) || 50;
  }

  function utcDay(offsetDays) {
    var d = new Date();
    d.setUTCDate(d.getUTCDate() - (offsetDays || 0));
    return d.toISOString().slice(0, 10);
  }

  // Which preset the current from/to corresponds to, so the select shows the
  // truth after a reload rather than resetting to "any time".
  function rangePreset() {
    if (!state.from && !state.to) return "";
    if (state.to !== utcDay(0)) return "custom";
    var opts = ["0", "1", "7", "30"];
    for (var i = 0; i < opts.length; i++) {
      if (state.from === utcDay(parseInt(opts[i], 10))) return opts[i];
    }
    return "custom";
  }

  // ---- list ---------------------------------------------------------------

  function apply(resetOffset) {
    readControls();
    if (resetOffset !== false) state.offset = 0;
    view = { name: "list" };
    writeUrl(true);
    render();
  }

  function loadConversations() {
    emptyMessage(convRowsEl, 9, "Loading...", "empty");
    summaryEl.textContent = "";
    var sp = filterParams();
    sp.set("limit", state.limit);
    sp.set("offset", state.offset);
    fetch("/api/admin/conversations?" + sp.toString())
      .then(function (r) { return r.json(); })
      .then(renderConversations)
      .catch(function (err) {
        emptyMessage(convRowsEl, 9, "Failed to load: " + err.message, "error");
      });
  }

  function renderConversations(data) {
    lastData = data;
    convRowsEl.innerHTML = "";
    if (data.error) {
      emptyMessage(convRowsEl, 9, data.error, "error");
      pageInfoEl.textContent = "";
      prevBtnEl.disabled = state.offset === 0;
      nextBtnEl.disabled = true;
      return;
    }
    var convs = data.conversations || [];
    if (convs.length === 0) {
      emptyMessage(convRowsEl, 9, "No conversations match these filters.", "empty");
    }
    prevBtnEl.disabled = state.offset === 0;
    nextBtnEl.disabled = typeof data.total === "number"
      ? state.offset + convs.length >= data.total
      : convs.length < state.limit;

    convs.forEach(function (c) {
      var silent = !c.engaged;
      var row = document.createElement("tr");
      row.className = "conv-row" + (silent ? " silent" : "");

      var chCell = td(characterName(c.chat_id || "(unknown)"));
      chCell.className = "ch";
      row.appendChild(chCell);
      row.appendChild(td(c.user_id ? shortUser(c.user_id) : "anon"));
      // An em dash rather than 0: they did not send zero messages, they never
      // got as far as the box.
      row.appendChild(td(silent ? "\\u2014" : c.message_count));

      var tickCell = td(c.tick_count ? c.tick_count : "");
      if (c.tick_count) tickCell.className = "tick-badge";
      row.appendChild(tickCell);

      var errCell = td(c.error_count > 0 ? c.error_count : "");
      if (c.error_count > 0) errCell.className = "err-badge";
      row.appendChild(errCell);

      // Blank rather than zero when nothing was ever waited on — a silent
      // visit did not get an instant reply, it got no reply to wait for. Long
      // waits are flagged at the ten-second mark, which is where a wait starts
      // being a plausible reason the conversation stopped.
      var waitCell = td(c.slowest_reply_ms ? fmtDuration(c.slowest_reply_ms) : "");
      if (c.slowest_reply_ms >= 10000) waitCell.className = "err-badge";
      row.appendChild(waitCell);

      row.appendChild(td(silent ? "" : (c.total_tokens || 0)));
      row.appendChild(td(fmtTime(c.first_at)));
      row.appendChild(td(fmtTime(c.last_at)));

      row.addEventListener("click", function () {
        if (silent) openVisitDetail(c.visit_id, c.chat_id);
        else openTranscript(c.user_id, c.chat_id);
      });
      convRowsEl.appendChild(row);
    });

    var first = convs.length ? state.offset + 1 : 0;
    var last = state.offset + convs.length;
    pageInfoEl.textContent = typeof data.total === "number"
      ? first + "-" + last + " of " + data.total
      : "showing " + convs.length + " (offset " + state.offset + ")";
    renderSummary(convs, data.hidden || 0);
  }

  // hidden is what the test-id filter removed under these same filters. Always
  // shown when non-zero, including when it removed everything — "no rows" and
  // "no rows you are being shown" are different answers.
  function renderSummary(convs, hidden) {
    var note = hidden
      ? "<span class=\\"sep\\">|</span><span class=\\"muted\\">" + hidden +
        " test " + (hidden === 1 ? "id" : "ids") + " hidden</span>"
      : "";
    if (!convs.length) {
      summaryEl.innerHTML = hidden
        ? "<span class=\\"muted\\">Nothing here but " + hidden + " test " +
          (hidden === 1 ? "id" : "ids") + " — tick \\"include test ids\\" to see " +
          (hidden === 1 ? "it" : "them") + ".</span>"
        : "";
      return;
    }
    var engaged = 0, silent = 0, messages = 0, errors = 0, tokens = 0, ticks = 0;
    convs.forEach(function (c) {
      if (c.engaged) { engaged++; messages += c.message_count || 0; }
      else silent++;
      errors += c.error_count || 0;
      tokens += c.total_tokens || 0;
      ticks += c.tick_count || 0;
    });
    var parts = [];
    parts.push("<b>" + engaged + "</b> conversations");
    if (silent) {
      var pct = Math.round((silent / convs.length) * 100);
      parts.push("<b>" + silent + "</b> silent (" + pct + "%)");
    }
    parts.push("<b>" + messages + "</b> messages");
    if (ticks) parts.push("<b>" + ticks + "</b> ticks");
    if (errors) parts.push("<b class=\\"err-badge\\">" + errors + "</b> errors");
    parts.push("<b>" + tokens.toLocaleString() + "</b> tokens");
    summaryEl.innerHTML = "On this page: " + parts.join("<span class=\\"sep\\">|</span>") + note;
  }

  function loadErrors() {
    emptyMessage(errorRowsEl, 5, "Loading...", "empty");
    fetch("/api/admin/logs?limit=10&failures_only=1")
      .then(function (r) { return r.json(); })
      .then(function (data) {
        errorRowsEl.innerHTML = "";
        var rows = data.logs || [];
        if (rows.length === 0) {
          emptyMessage(errorRowsEl, 5, "No recent errors.", "empty");
          return;
        }
        rows.forEach(function (log) {
          var row = document.createElement("tr");
          row.className = "log-row";
          row.appendChild(td(fmtTime(log.created_at)));
          row.appendChild(td(shortUser(log.user_id)));
          row.appendChild(td(characterName(log.chat_id)));
          var statusCell = td(log.status + " (" + log.status_code + ")");
          statusCell.className = "status-" + log.status;
          row.appendChild(statusCell);
          var previewCell = td(log.user_message);
          previewCell.className = "preview";
          row.appendChild(previewCell);
          row.addEventListener("click", function () { openTranscript(log.user_id, log.chat_id); });
          errorRowsEl.appendChild(row);
        });
      })
      .catch(function (err) {
        emptyMessage(errorRowsEl, 5, "Failed to load errors: " + err.message, "error");
      });
  }

  // ---- views --------------------------------------------------------------

  function showView(name) {
    el("view-list").style.display = name === "list" ? "" : "none";
    el("view-transcript").style.display = name === "list" ? "none" : "";
    el("transcript-controls").style.display = name === "list" ? "none" : "";
  }

  function render() {
    syncControls();
    if (view.name === "transcript") {
      showView("transcript");
      loadTranscript(view.user, view.chat);
    } else if (view.name === "visit") {
      showView("transcript");
      loadVisitDetail(view.visit, view.chat);
    } else {
      showView("list");
      loadConversations();
      loadErrors();
    }
  }

  function openTranscript(userId, chatId) {
    view = { name: "transcript", user: userId, chat: chatId };
    writeUrl(true);
    render();
    window.scrollTo(0, 0);
  }

  function openVisitDetail(visitId, character) {
    view = { name: "visit", visit: visitId, chat: character || "" };
    writeUrl(true);
    render();
    window.scrollTo(0, 0);
  }

  function loadTranscript(userId, chatId) {
    el("copy-btn").style.display = "";
    el("export-conv-btn").style.display = "";
    var metaEl = el("t-meta");
    var actionsEl = el("t-actions");
    var messagesEl = el("t-messages");
    metaEl.textContent = "Loading...";
    actionsEl.textContent = "";
    messagesEl.innerHTML = "";

    fetch("/api/admin/transcript?user_id=" + encodeURIComponent(userId) + "&chat_id=" + encodeURIComponent(chatId))
      .then(function (r) { return r.json(); })
      .then(function (data) {
        if (data.error) { metaEl.textContent = data.error; return; }
        renderTranscript(data, metaEl, messagesEl);
      })
      .catch(function (err) {
        metaEl.textContent = "Failed to load transcript: " + err.message;
      });
  }

  // A visit that opened a character and never typed. There is no transcript
  // to show, so the tick trail IS the record: how long they looked, and when
  // they gave up.
  function loadVisitDetail(visitId, character) {
    // Nothing to copy or export — there is no transcript, only the tick trail.
    el("copy-btn").style.display = "none";
    el("export-conv-btn").style.display = "none";
    var metaEl = el("t-meta");
    var actionsEl = el("t-actions");
    var messagesEl = el("t-messages");
    metaEl.textContent = "Loading...";
    actionsEl.textContent = "";
    messagesEl.innerHTML = "";

    fetch("/api/admin/visit-detail?visit_id=" + encodeURIComponent(visitId) +
          "&character=" + encodeURIComponent(character || ""))
      .then(function (r) { return r.json(); })
      .then(function (data) {
        if (data.error) { metaEl.textContent = data.error; return; }
        renderVisitDetail(data, metaEl, messagesEl);
      })
      .catch(function (err) {
        metaEl.textContent = "Failed to load visit: " + err.message;
      });
  }

  function renderVisitDetail(data, metaEl, messagesEl) {
    metaEl.textContent = (data.chat_id || "unknown character") +
      " - never engaged - visit " + String(data.visit_id).slice(0, 12);

    var sum = document.createElement("div");
    sum.className = "tl-summary";
    var lines = ["<span class=\\"silent-note\\">Opened this character and never typed anything.</span>"];
    if (data.tick_count) {
      lines.push("<b>" + data.tick_count + " ticks</b> on the character screen (" +
        fmtDuration(tickSpanMs(data)) + " before giving up)");
    } else {
      lines.push("No ticks recorded - left almost immediately, or the tab was backgrounded before the first tick.");
    }
    if (data.left_at) {
      lines.push("Left <b>" + fmtTime(data.left_at) + "</b>" +
        (data.dwell_ms ? " after " + fmtDuration(data.dwell_ms) + " on the site" : ""));
    } else {
      lines.push("<span class=\\"silent-note\\">No leave event - the tab was closed without firing one, so the exit time is unknown.</span>");
    }
    sum.innerHTML = lines.join("<br>");
    messagesEl.appendChild(sum);

    renderTimeline(messagesEl, data.events, fmtTime);
  }

  // Search terms are marked in place. Finding the conversation is only half
  // the job — the line that matched still has to be findable inside it.
  function appendHighlighted(node, text) {
    var term = state.q;
    var value = text === null || text === undefined ? "" : String(text);
    if (!term) { node.textContent = value; return; }
    var hay = value.toLowerCase();
    var needle = term.toLowerCase();
    var from = 0;
    var at;
    while ((at = hay.indexOf(needle, from)) !== -1) {
      node.appendChild(document.createTextNode(value.slice(from, at)));
      var mark = document.createElement("mark");
      mark.textContent = value.slice(at, at + term.length);
      node.appendChild(mark);
      from = at + term.length;
    }
    node.appendChild(document.createTextNode(value.slice(from)));
  }

  function renderTranscript(data, metaEl, messagesEl) {
    var msgs = data.messages || [];
    var name = characterName(data.chat_id);
    var tokens = 0;
    var errorCount = 0;
    msgs.forEach(function (m) {
      tokens += m.total_tokens || 0;
      if (m.status !== "completed") errorCount++;
    });
    metaEl.textContent = name + " x " + shortUser(data.user_id) + " - " +
      msgs.length + " exchanges" +
      (msgs.length ? ", " + fmtTime(msgs[0].created_at) + " to " + fmtTime(msgs[msgs.length - 1].created_at) : "") +
      (tokens ? ", " + tokens + " tokens" : "");

    transcriptText = buildTranscriptText(name, data, msgs);

    // visible_ms counts too: a visit killed while backgrounded has no leave
    // row and may have no ticks either, and its hide checkpoints are then the
    // only account of it there is.
    if (data.tick_count || data.left_at ||
        data.visible_ms !== null && data.visible_ms !== undefined) {
      var sum = document.createElement("div");
      sum.className = "tl-summary";
      var parts = [];
      if (data.tick_count) {
        parts.push("<b>" + data.tick_count + " ticks</b> before engaging (" +
          fmtDuration(tickSpanMs(data)) + " looking at the character)");
      }
      if (data.left_at) {
        var ENDINGS = {
          dismissed: "closed while on screen",
          hidden: "backgrounded, then never came back",
          bfcache: "frozen, not closed - a back gesture could restore it",
        };
        parts.push("left <b>" + fmtTime(data.left_at) + "</b>" +
          (data.dwell_ms ? " after " + fmtDuration(data.dwell_ms) + " on the site" : "") +
          (ENDINGS[data.exit_mode] ? " - " + ENDINGS[data.exit_mode] : ""));
      }
      // The same pair the sessions page reports, and for the same reason: wall
      // clock counts the seconds this visit spent behind another app, and this
      // counts only the ones it was watched for. They diverge exactly where
      // someone backgrounded it, which the old latching leave read as leaving.
      if (data.visible_ms !== null && data.visible_ms !== undefined) {
        parts.push("on screen for <b>" + fmtDuration(data.visible_ms) + "</b>" +
          (data.hide_count
            ? ", backgrounded " + data.hide_count + (data.hide_count === 1 ? " time" : " times")
            : " without interruption"));
      }
      sum.innerHTML = parts.join("<br>");
      messagesEl.appendChild(sum);
      renderTimeline(messagesEl, data.events, fmtTime);
    }

    var prevAt = null;
    var firstErrorId = null;
    var matches = 0;
    msgs.forEach(function (m, idx) {
      var at = parseUtc(m.created_at);
      if (prevAt && at - prevAt > 30 * 60 * 1000) {
        var divider = document.createElement("div");
        divider.className = "gap-divider";
        divider.textContent = gapText(at - prevAt);
        messagesEl.appendChild(divider);
      }
      prevAt = at;

      var block = document.createElement("div");
      block.className = "exchange";
      block.id = "ex-" + idx;
      if (m.status !== "completed" && firstErrorId === null) firstErrorId = block.id;
      if (state.q) matches += countMatches(m.user_message) + countMatches(m.assistant_message);

      appendBubble(block, m.user_message, "user", false);
      if (m.status === "completed" && m.assistant_message) {
        appendBubble(block, m.assistant_message, "ai", false);
      } else {
        appendBubble(block, "[message failed]", "ai", true);
      }

      var meta = document.createElement("div");
      meta.className = "ex-meta";
      meta.textContent = fmtTime(m.created_at) + " | " + m.status + " (" + m.status_code + ") | " + m.model +
        (m.total_tokens ? " | " + m.total_tokens + " tokens" : "") +
        // What the visitor actually waited, on the exchange they waited it on.
        // Absent on rows written before migration 0007 rather than shown as 0.
        (m.latency_ms ? " | waited " + fmtDuration(m.latency_ms) : "");
      if (m.error) {
        var errSpan = document.createElement("span");
        errSpan.className = "err-text";
        errSpan.textContent = " | " + m.error;
        meta.appendChild(errSpan);
      }
      block.appendChild(meta);
      messagesEl.appendChild(block);
    });

    renderTranscriptActions(firstErrorId, errorCount, matches);
  }

  function countMatches(text) {
    if (!state.q || !text) return 0;
    var hay = String(text).toLowerCase();
    var needle = state.q.toLowerCase();
    var n = 0, from = 0, at;
    while ((at = hay.indexOf(needle, from)) !== -1) { n++; from = at + needle.length; }
    return n;
  }

  function renderTranscriptActions(firstErrorId, errorCount, matches) {
    var actionsEl = el("t-actions");
    actionsEl.innerHTML = "";
    if (errorCount && firstErrorId) {
      var jump = document.createElement("a");
      jump.textContent = "Jump to first of " + errorCount + " failed exchange" + (errorCount === 1 ? "" : "s");
      jump.addEventListener("click", function () {
        var target = document.getElementById(firstErrorId);
        if (!target) return;
        target.scrollIntoView({ behavior: "smooth", block: "center" });
        target.classList.remove("flash");
        void target.offsetWidth;
        target.classList.add("flash");
      });
      actionsEl.appendChild(jump);
    }
    if (state.q) {
      var note = document.createElement("span");
      note.className = "silent-note";
      note.textContent = (errorCount && firstErrorId ? "  -  " : "") +
        matches + " match" + (matches === 1 ? "" : "es") + " for \\u201C" + state.q + "\\u201D";
      actionsEl.appendChild(note);
    }
  }

  function buildTranscriptText(name, data, msgs) {
    var lines = [name + " x " + data.user_id, ""];
    msgs.forEach(function (m) {
      lines.push("[" + fmtTime(m.created_at) + "] User: " + (m.user_message || ""));
      lines.push("[" + fmtTime(m.created_at) + "] " + name + ": " +
        (m.status === "completed" && m.assistant_message ? m.assistant_message : "[message failed]"));
      lines.push("");
    });
    return lines.join("\\n");
  }

  function gapText(ms) {
    var mins = Math.round(ms / 60000);
    if (mins < 60) return mins + " minutes later";
    var hours = Math.round(mins / 60);
    if (hours < 48) return hours + " hours later";
    return Math.round(hours / 24) + " days later";
  }

  function appendBubble(container, text, side, failed) {
    var row = document.createElement("div");
    row.className = "bubble-row";
    var bubble = document.createElement("div");
    bubble.className = "bubble " + side + (failed ? " failed" : "");
    appendHighlighted(bubble, text);
    row.appendChild(bubble);
    container.appendChild(row);
  }

  // ---- wiring -------------------------------------------------------------

  var ths = document.querySelectorAll("th.sortable");
  for (var i = 0; i < ths.length; i++) {
    (function (th) {
      th.setAttribute("data-label", th.textContent);
      th.addEventListener("click", function () {
        var column = th.getAttribute("data-sort");
        // Same column toggles direction; a new one starts at the end that is
        // usually interesting - newest, or biggest.
        if (state.sort === column) state.dir = state.dir === "desc" ? "asc" : "desc";
        else { state.sort = column; state.dir = column === "chat_id" ? "asc" : "desc"; }
        state.offset = 0;
        writeUrl(true);
        render();
      });
    })(ths[i]);
  }

  ["f-character", "f-user", "f-q"].forEach(function (id) {
    el(id).addEventListener("keydown", function (e) {
      if (e.key === "Enter") apply();
    });
  });
  ["f-show", "f-errors", "f-include-test", "f-from", "f-to"].forEach(function (id) {
    el(id).addEventListener("change", function () { apply(); });
  });

  el("f-range").addEventListener("change", function () {
    var v = el("f-range").value;
    if (v === "custom") return;
    if (v === "") { el("f-from").value = ""; el("f-to").value = ""; }
    else { el("f-from").value = utcDay(parseInt(v, 10)); el("f-to").value = utcDay(0); }
    apply();
  });

  el("page-size").addEventListener("change", function () { apply(); });
  el("search-btn").addEventListener("click", function () { apply(); });
  el("reset-btn").addEventListener("click", function () {
    state = Object.assign({}, DEFAULTS);
    view = { name: "list" };
    syncControls();
    writeUrl(true);
    render();
  });
  el("prev-btn").addEventListener("click", function () {
    state.offset = Math.max(0, state.offset - state.limit);
    writeUrl(true);
    render();
  });
  el("next-btn").addEventListener("click", function () {
    state.offset = state.offset + state.limit;
    writeUrl(true);
    render();
  });
  // Deliberately not history.back(): a transcript reached by a shared link has
  // no previous entry here, and Back would leave the tool entirely.
  function goList() {
    view = { name: "list" };
    writeUrl(true);
    render();
  }
  el("back-btn").addEventListener("click", goList);

  el("copy-btn").addEventListener("click", function () {
    if (!transcriptText) return;
    var btn = el("copy-btn");
    navigator.clipboard.writeText(transcriptText).then(function () {
      btn.textContent = "Copied";
      setTimeout(function () { btn.textContent = "Copy transcript"; }, 1500);
    }, function () {
      btn.textContent = "Copy failed";
      setTimeout(function () { btn.textContent = "Copy transcript"; }, 1500);
    });
  });

  el("export-btn").addEventListener("click", function () {
    var sp = new URLSearchParams();
    if (state.from || state.to) {
      if (state.from) sp.set("from", state.from);
      if (state.to) sp.set("to", state.to);
    } else {
      sp.set("days", el("export-days").value);
    }
    if (state.character) sp.set("character", state.character);
    if (state.q) sp.set("q", state.q);
    // Carried so the file matches the table it was taken from. Without it the
    // export hid nothing while the page hid test ids.
    if (state.includeTest) sp.set("include_test", "1");
    window.location = "/api/admin/export?" + sp.toString();
  });

  el("export-conv-btn").addEventListener("click", function () {
    if (view.name !== "transcript") return;
    window.location = "/api/admin/export?user_id=" + encodeURIComponent(view.user) +
      "&chat_id=" + encodeURIComponent(view.chat);
  });

  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape" && view.name !== "list") { goList(); return; }
    // "/" jumps to the search box, the way every log tool does it.
    if (e.key === "/" && view.name === "list" && document.activeElement.tagName !== "INPUT") {
      e.preventDefault();
      el("f-q").focus();
      el("f-q").select();
    }
  });

  window.addEventListener("popstate", function () {
    readUrl();
    render();
  });

  readUrl();
  writeUrl(false);
  render();
})();
</script>
</body>
</html>`;
}
