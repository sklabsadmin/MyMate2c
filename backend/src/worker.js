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

            const ids = await db.prepare(`
                SELECT DISTINCT app_user_id FROM site_visits
                WHERE visit_id = ? AND app_user_id IS NOT NULL
            `).bind(visitId).all();
            const userIds = (ids.results || []).map((r) => r.app_user_id);
            if (!userIds.length) return jsonResponse({ userIds: [], messages: [] });

            // Bounded by the visit window so a returning device does not drag
            // in every conversation it has ever had.
            const window = await db.prepare(`
                SELECT MIN(created_at) AS started, MAX(created_at) AS ended
                FROM site_visits WHERE visit_id = ?
            `).bind(visitId).first();

            const placeholders = userIds.map(() => "?").join(",");
            const msgs = await db.prepare(`
                SELECT created_at, character_id, scenario, user_message,
                       assistant_message, status, error
                FROM conversation_logs
                WHERE user_id IN (${placeholders})
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
            const bySource = await db.prepare(`
                SELECT a.source AS source,
                       COUNT(*) AS visits,
                       SUM(CASE WHEN l.duration_ms IS NOT NULL THEN 1 ELSE 0 END) AS with_duration,
                       SUM(CASE WHEN l.duration_ms < 3000 THEN 1 ELSE 0 END) AS bounced_under_3s,
                       SUM(CASE WHEN r.visit_id IS NOT NULL THEN 1 ELSE 0 END) AS saw_app,
                       CAST(AVG(r.duration_ms) AS INTEGER) AS avg_load_ms,
                       CAST(AVG(l.duration_ms) AS INTEGER) AS avg_ms
                FROM site_visits a
                LEFT JOIN site_visits l
                       ON l.visit_id = a.visit_id AND l.event = 'leave'
                LEFT JOIN site_visits r
                       ON r.visit_id = a.visit_id AND r.event = 'app_ready'
                WHERE a.event = 'arrive' AND a.created_at >= datetime('now', ?)
                GROUP BY a.source ORDER BY visits DESC
            `).bind(since).all();

            const byDay = await db.prepare(`
                SELECT date(created_at) AS day, COUNT(*) AS visits
                FROM site_visits
                WHERE event = 'arrive' AND created_at >= datetime('now', ?)
                GROUP BY day ORDER BY day DESC
            `).bind(since).all();

            const recent = await db.prepare(`
                SELECT a.visit_id, a.created_at, a.path, a.query, a.source, a.utm_medium,
                       a.utm_campaign, a.country, a.referer, l.duration_ms,
                       r.duration_ms AS load_ms,
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
                LEFT JOIN site_visits l
                       ON l.visit_id = a.visit_id AND l.event = 'leave'
                LEFT JOIN site_visits r
                       ON r.visit_id = a.visit_id AND r.event = 'app_ready'
                WHERE a.event = 'arrive' AND a.created_at >= datetime('now', ?)
                ORDER BY a.created_at DESC LIMIT 200
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

            const characters = await db.prepare(`
                SELECT detail AS character_id, event, COUNT(*) AS n
                FROM site_visits
                WHERE detail IS NOT NULL AND created_at >= datetime('now', ?)
                GROUP BY detail, event ORDER BY n DESC
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
            const dwellBuckets = await db.prepare(`
                SELECT a.source AS source,
                       COUNT(DISTINCT a.visit_id) AS never_engaged,
                       SUM(CASE WHEN p.ticks IS NULL OR p.ticks = 0 THEN 1 ELSE 0 END) AS left_instantly,
                       SUM(CASE WHEN p.ticks BETWEEN 1 AND ${b5s - 1} THEN 1 ELSE 0 END) AS left_under_5s,
                       SUM(CASE WHEN p.ticks BETWEEN ${b5s} AND ${b15s - 1} THEN 1 ELSE 0 END) AS left_5s_to_15s,
                       SUM(CASE WHEN p.ticks BETWEEN ${b15s} AND ${bFull - 1} THEN 1 ELSE 0 END) AS left_15s_to_30s,
                       SUM(CASE WHEN p.ticks >= ${bFull} THEN 1 ELSE 0 END) AS stayed_full_30s
                FROM site_visits a
                LEFT JOIN (
                    SELECT visit_id, COUNT(*) AS ticks
                    FROM site_visits WHERE event = 'screen_ping'
                    GROUP BY visit_id
                ) p ON p.visit_id = a.visit_id
                WHERE a.event = 'arrive'
                  AND a.created_at >= datetime('now', ?)
                  AND EXISTS (
                      SELECT 1 FROM site_visits t
                      WHERE t.visit_id = a.visit_id AND t.event = 'character_tap'
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM site_visits e
                      WHERE e.visit_id = a.visit_id
                        AND e.event IN ('input_typed', 'starter_tap', 'first_message')
                  )
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
            // Sorted by dwell, longest first, with unknowns last. A visit with
            // no leave row is one the browser never got to report — that is not
            // a zero-second visit, and sorting it as one would bury the longest
            // sessions under a wall of hard exits.
            const SESSION_LIMIT = 500;
            const sessions = await db.prepare(`
                SELECT a.visit_id,
                       MIN(a.created_at) AS created_at,
                       a.source, a.path, a.country, a.viewport_w,
                       (SELECT MIN(r.duration_ms) FROM site_visits r
                         WHERE r.visit_id = a.visit_id AND r.event = 'app_ready') AS load_ms,
                       (SELECT MAX(l.duration_ms) FROM site_visits l
                         WHERE l.visit_id = a.visit_id AND l.event = 'leave') AS dwell_ms,
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
                ORDER BY dwell_ms IS NULL, dwell_ms DESC
                LIMIT ${SESSION_LIMIT + 1}
            `).bind(param).all();

            const rows = sessions.results || [];
            const truncated = rows.length > SESSION_LIMIT;
            if (truncated) rows.length = SESSION_LIMIT;

            // Messages for the same visits. conversation_logs.created_at is
            // ISO-8601 with a T and a Z while site_visits uses SQLite's own
            // format, so these are selected by visit rather than by their own
            // timestamp — comparing the two formats as strings goes wrong
            // inside a single day.
            const messages = await db.prepare(`
                SELECT c.visit_id, c.user_message, c.scenario, c.status
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
                    byVisit.set(m.visit_id, { messages: 0, tapped: 0, typed: 0, failed: 0 });
                }
                const agg = byVisit.get(m.visit_id);
                agg.messages += 1;
                // A successful row is status "completed"; everything else
                // ("ai_error", "rejected_validation", "rate_limited") is a
                // message the visitor sent and got nothing usable back from.
                if (m.status && m.status !== "completed") agg.failed += 1;
                if (isStarterText(m.user_message, characterIdFromScenario(m.scenario))) agg.tapped += 1;
                else agg.typed += 1;
            }

            return jsonResponse({
                day: isDay ? day : null,
                days: isDay ? null : days,
                truncated,
                limit: SESSION_LIMIT,
                sessions: rows.map((r) => {
                    const agg = byVisit.get(r.visit_id) || { messages: 0, tapped: 0, typed: 0, failed: 0 };
                    return {
                        ...r,
                        ...agg,
                        // A tap recorded by the funnel that no message text
                        // matches means the starters moved on since this visit
                        // and backend/src/starters.generated.js is stale. Say
                        // so on the row rather than counting the tap as typed.
                        starter_unmatched: Boolean(r.tapped_starter) && agg.messages > 0 && agg.tapped === 0,
                    };
                }),
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
        "Access-Control-Allow-Headers": "Content-Type, x-signature, x-timestamp, x-user-id, x-chat-id, x-scenario, x-language, x-character-id, x-visit-id",
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
    //                 character id). Fired twice a second starting at
    //                 character_tap, capped at 30s (60 ticks), and stopped
    //                 the moment the visitor actually engages — see leave for
    //                 full-page dwell; this measures dwell on the chat screen
    //                 specifically, for the population that opened a
    //                 character but never typed or tapped anything, which
    //                 leave alone cannot isolate. Bounded on both axes
    //                 (visitor population and duration) so it stays cheap:
    //                 only the "opened a character" cohort ever sends these,
    //                 and never for more than 60 ticks each.
    //   leave         page hidden/closed (duration = dwell)
    //
    // input_typed and starter_tap split the character_tap -> first_message gap,
    // which is where almost everyone is lost: they separate visitors who never
    // realised they could reply from those who started a message and
    // abandoned it, and they say which of the two routes into the
    // conversation people actually take.
    const ALLOWED_EVENTS = [
        "arrive", "app_ready", "character_tap", "input_typed", "starter_tap",
        "first_message", "login_gate", "send_failed", "screen_ping", "leave",
    ];
    const event = ALLOWED_EVENTS.includes(payload.event) ? payload.event : "arrive";
    const detail = String(payload.detail || "").slice(0, 80) || null;
    // Only the in-app events carry this; the splash beacon runs before Flutter
    // exists, so arrive/leave rows have it NULL by design.
    const appUserId = String(payload.appUserId || "").slice(0, 120) || null;
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

    try {
        await env.CHAT_LOGS_DB.prepare(`
            INSERT INTO site_visits (
                id, visit_id, event, path, query, source,
                utm_medium, utm_campaign, referer, user_agent,
                country, colo, duration_ms, detail, app_user_id,
                viewport_w, failure_reason
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            failureReason
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
               user_message, assistant_message, error, prompt_tokens, completion_tokens, total_tokens
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
 * One row per conversation (user_id + chat_id pair) with aggregates,
 * newest activity first. Optional filters: character (substring of
 * chat_id), user_id (exact), errors_only.
 */
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
    const errorsOnly = params.get("errors_only") === "1";

    // Conversations that produced at least one exchange.
    const chatFilters = [];
    const chatBinds = [];
    if (character) { chatFilters.push("chat_id LIKE ?"); chatBinds.push(`%${character}%`); }
    if (userId) { chatFilters.push("user_id = ?"); chatBinds.push(userId); }
    const where = chatFilters.length ? `WHERE ${chatFilters.join(" AND ")}` : "";
    const having = errorsOnly
        ? "HAVING SUM(CASE WHEN status = 'completed' THEN 0 ELSE 1 END) > 0"
        : "";

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
    // Excluded when filtering for errors: a visit that never sent anything
    // cannot have failed a send.
    const visitFilters = [
        "event IN ('character_tap', 'screen_ping')",
        "detail IS NOT NULL",
        "NOT EXISTS (SELECT 1 FROM conversation_logs cl WHERE cl.visit_id = sv.visit_id)",
    ];
    const visitBinds = [];
    if (character) { visitFilters.push("detail LIKE ?"); visitBinds.push(`%${character}%`); }
    if (userId) { visitFilters.push("app_user_id = ?"); visitBinds.push(userId); }

    const unengaged = `
        SELECT MAX(sv.app_user_id) AS user_id,
               sv.detail AS chat_id,
               sv.visit_id AS visit_id,
               0 AS engaged,
               0 AS message_count,
               SUM(CASE WHEN sv.event = 'screen_ping' THEN 1 ELSE 0 END) AS tick_count,
               0 AS error_count,
               0 AS total_tokens,
               MIN(sv.created_at) AS first_at,
               MAX(sv.created_at) AS last_at,
               (SELECT l.duration_ms FROM site_visits l
                 WHERE l.visit_id = sv.visit_id AND l.event = 'leave'
                 ORDER BY l.created_at DESC LIMIT 1) AS dwell_ms
        FROM site_visits sv
        WHERE ${visitFilters.join(" AND ")}
        GROUP BY sv.visit_id, sv.detail`;

    const union = errorsOnly ? engaged : `${engaged} UNION ALL ${unengaged}`;
    const binds = errorsOnly ? chatBinds : [...chatBinds, ...visitBinds];

    const { results } = await env.CHAT_LOGS_DB.prepare(`
        SELECT * FROM (${union})
        ORDER BY last_at DESC
        LIMIT ? OFFSET ?
    `).bind(...binds, limit, offset).all();

    return { conversations: results, limit, offset };
}

/**
 * Funnel events for one visit, oldest first — the tick trail.
 *
 * screen_ping fires twice a second while a character screen sits open and
 * unengaged, stopping the moment anything is typed, so the tick count is a
 * direct measure of how long someone looked at a character before either
 * starting to type or giving up. 'leave' carries the dwell time for the whole
 * page visit.
 */
async function getVisitEvents(env, visitIds) {
    const ids = (visitIds || []).filter(Boolean);
    if (!ids.length || !env.CHAT_LOGS_DB) return [];
    const placeholders = ids.map(() => "?").join(", ");
    const { results } = await env.CHAT_LOGS_DB.prepare(`
        SELECT visit_id, created_at, event, detail, duration_ms,
               source, utm_campaign, country, viewport_w, failure_reason
        FROM site_visits
        WHERE visit_id IN (${placeholders})
        ORDER BY created_at ASC
    `).bind(...ids).all();
    return results || [];
}

/** Everything known about a visit that never produced a message. */
async function getVisitDetail(env, visitId, character) {
    if (!env.CHAT_LOGS_DB) {
        return { error: "CHAT_LOGS_DB is not configured", events: [] };
    }
    const events = await getVisitEvents(env, [visitId]);
    const ticks = events.filter((e) => e.event === "screen_ping");
    const leave = events.filter((e) => e.event === "leave").pop() || null;
    return {
        visit_id: visitId,
        chat_id: character || null,
        engaged: 0,
        events,
        tick_count: ticks.length,
        // Ticks are 500ms apart, but derive the span from the timestamps
        // rather than multiplying — a backgrounded tab stops firing, and
        // counting would then overstate how long they actually looked.
        first_tick_at: ticks.length ? ticks[0].created_at : null,
        last_tick_at: ticks.length ? ticks[ticks.length - 1].created_at : null,
        left_at: leave ? leave.created_at : null,
        dwell_ms: leave ? leave.duration_ms : null,
    };
}

/** All exchanges of one conversation, oldest first. */
async function getTranscript(env, userId, chatId) {
    if (!env.CHAT_LOGS_DB) {
        return { error: "CHAT_LOGS_DB is not configured", messages: [] };
    }
    const { results } = await env.CHAT_LOGS_DB.prepare(`
        SELECT id, created_at, user_message, assistant_message, status, status_code,
               model, error, total_tokens, visit_id
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
        dwell_ms: leave ? leave.duration_ms : null,
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
        const rawDays = parseInt(params.get("days"), 10);
        const days = Number.isFinite(rawDays) ? Math.min(Math.max(rawDays, 1), 365) : 30;
        const since = new Date(Date.now() - days * 24 * 60 * 60 * 1000)
            .toISOString().replace("T", " ").slice(0, 19);
        filters.push("created_at >= ?");
        binds.push(since);
        if (character) { filters.push("chat_id LIKE ?"); binds.push(`%${character}%`); }
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

    const byCharacter = await env.CHAT_LOGS_DB.prepare(`
        SELECT v.character_id AS character_id,
               COUNT(*) AS visits,
               SUM(CASE WHEN v.known_character = 0 THEN 1 ELSE 0 END) AS unknown_hits,
               (SELECT COUNT(DISTINCT l.chat_id) FROM conversation_logs l
                 WHERE l.created_at >= datetime('now', ?)
                   AND lower(l.scenario) LIKE lower(v.character_id) || '%') AS conversations
        FROM referral_visits v
        WHERE v.created_at >= datetime('now', ?)
        GROUP BY v.character_id ORDER BY visits DESC
    `).bind(since, since).all();

    const recent = await env.CHAT_LOGS_DB.prepare(`
        SELECT created_at, character_id, source, utm_medium, utm_campaign, known_character
        FROM referral_visits ORDER BY created_at DESC LIMIT 100
    `).all();

    return {
        days,
        totalVisits: (bySource.results || []).reduce((n, r) => n + r.visits, 0),
        bySource: bySource.results || [],
        byCharacter: byCharacter.results || [],
        recent: recent.results || [],
    };
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

<a class="card" href="/admin/referrals">
  <div class="t">Campaigns <span class="em">/c/ links only</span></div>
  <div class="d">Server-side record of character link hits. Fires even with no
     JavaScript, so it catches visitors Visits cannot — but it also counts
     Meta&rsquo;s link-preview crawler, so it reads high.</div>
</a>

<a class="card" href="/admin/sessions">
  <div class="t">User sessions <span class="em">one row per arrival</span></div>
  <div class="d">Every session, longest dwell first: how long they stayed, how
     long they hesitated on a character, and how many messages they sent —
     split into tapped starters and messages they wrote themselves.</div>
</a>

<a class="card" href="/admin/logs">
  <div class="t">Chat logs</div>
  <div class="d">Conversation transcripts by user and character.</div>
</a>

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
  select { background: #241d2e; color: #eee; border: 1px solid #443; padding: 6px 10px;
           border-radius: 6px; margin-bottom: 18px; }
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
</style></head><body>
<p style="margin:0 0 14px"><a href="/admin" style="color:#b39ddb">&larr; Admin</a>
   &nbsp;·&nbsp; <a href="/admin/visits" style="color:#b39ddb">Site visits</a></p>
<h1>User sessions</h1>
<p class="sub">One row per arrival — every time someone opens the app, whether or
   not they ever reached a character. Longest dwell first; sessions the browser
   never reported a leave for sort last, since those are unknown rather than
   zero.</p>
<select id="days" onchange="pick()">
  <option value="1">Last 24 hours</option>
  <option value="7" selected>Last 7 days</option>
  <option value="30">Last 30 days</option>
  <option value="90">Last 90 days</option>
</select>
<div id="out">Loading…</div>
<p class="note" id="footnote"></p>
<script>
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
// A day drilled into from the Visits page pins the range; the selector then has
// nothing to control, so it is hidden rather than left there looking live.
const DAY = new URLSearchParams(location.search).get('day');
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
async function render(out) {
  const q = DAY ? 'day=' + encodeURIComponent(DAY)
                : 'days=' + document.getElementById('days').value;
  const res = await fetch('/api/admin/sessions?' + q);
  if (!res.ok) throw new Error('HTTP ' + res.status);
  const d = await res.json();
  const rows = d.sessions || [];

  let h = '<div class="wrap"><table><tr><th>When (UTC)</th><th>Source</th><th>Path</th>' +
          '<th>Character</th><th>Country</th><th>Load</th><th>Dwell</th><th>Ticks</th>' +
          '<th>Messages</th><th>Tapped</th><th>Typed</th><th>Failed</th><th>Chat</th></tr>';
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
    h += '<tr><td>' + esc(r.created_at) + '</td><td>' + esc(r.source) +
         '</td><td>' + esc(r.path) + '</td><td>' + esc(r.character_id || '') +
         '</td><td>' + esc(r.country) +
         '</td><td class="num">' + dur(r.load_ms) +
         '</td><td class="num">' + dur(r.dwell_ms) +
         '</td><td class="num">' + ticks +
         '</td><td class="num">' + (r.messages || 0) +
         '</td><td class="num">' + tapped +
         '</td><td class="num">' + (r.typed || 0) +
         '</td><td class="num">' +
         ((r.failed || r.send_failed)
           ? '<span class="warn">' + ((r.failed || 0) + (r.send_failed || 0)) + '</span>'
           : '<span class="muted">0</span>') +
         '</td><td>' +
         (r.messages
           ? '<a href="#" class="drill" data-v="' + esc(r.visit_id) + '">view</a>'
           : '<span class="muted">—</span>') +
         '</td></tr><tr class="chat" id="chat-' + esc(r.visit_id) +
         '" style="display:none"><td colspan="13"></td></tr>';
  }
  if (!rows.length) h += '<tr><td colspan="13" class="muted">No sessions in this range.</td></tr>';
  h += '</table></div>';
  out.innerHTML = h;

  const scope = d.day ? 'on ' + d.day + ' (UTC)' : 'in the last ' + d.days + ' days';
  document.getElementById('footnote').innerHTML =
    esc(rows.length + ' session(s) ' + scope + '.') +
    (d.truncated
      ? ' <span class="warn">Showing the first ' + d.limit + ' by dwell — there are more.</span>'
      : '') +
    '<br>Web sessions only: the App Store build sends no visit id, so its usage never appears here. ' +
    // Interpolated from the tick constants, not written out: a hardcoded "30s"
    // here would be wrong the moment the cadence moves, which is the same trap
    // the dwell-bucket headers fell into.
    'Ticks stop at the first sign of engagement and cap at ${screenPingSeconds(SCREEN_PING_MAX_TICKS)}s, so they measure hesitation, not session length. ' +
    'Dwell is reported by the browser on page hide and latches at the first tab switch — treat it as directional. ' +
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
        const res = await fetch('/api/admin/visit-chat?visit_id=' + encodeURIComponent(vid));
        if (!res.ok) throw new Error('HTTP ' + res.status);
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
               '</div>';
        }
        cell.innerHTML = c + '</div>';
      } catch (err) {
        cell.innerHTML = '<span style="color:#e57373">Could not load: ' +
          esc(err && err.message ? err.message : err) + '</span>';
      }
    });
  });
}
if (DAY) {
  document.getElementById('days').style.display = 'none';
  document.querySelector('h1').textContent = 'User sessions — ' + DAY;
}
load();
</script></body></html>`;
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
</style></head><body>
<p style="margin:0 0 14px"><a href="/admin" style="color:#b39ddb">&larr; Admin</a></p>
<h1>Site visits</h1>
<p class="sub">Every arrival, logged from the splash screen before the app loads —
   not just /c/ campaign links.</p>
<select id="days" onchange="load()">
  <option value="1">Last 24 hours</option>
  <option value="7" selected>Last 7 days</option>
  <option value="30">Last 30 days</option>
  <option value="90">Last 90 days</option>
</select>
<div id="out">Loading…</div>
<script>
function esc(v) {
  return String(v === null || v === undefined ? '' : v)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}
function dur(ms) {
  if (ms === null || ms === undefined) return '<span class="muted">—</span>';
  return ms < 1000 ? ms + 'ms' : (ms/1000).toFixed(1) + 's';
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
       'losing people.</p><div class="wrap"><table><tr><th>Source</th>' +
       '<th>Arrived</th><th>App loaded</th><th>Opened a character</th>' +
       '<th>Typed or tapped a starter</th><th>Sent a message</th>' +
       '<th>Hit login gate</th></tr>';
  for (const r of d.funnel || []) {
    function pct(n) {
      return r.arrived ? ' <span class="muted">(' + Math.round(100*n/r.arrived) + '%)</span>' : '';
    }
    h += '<tr><td>' + esc(r.source) + '</td><td class="num">' + r.arrived +
         '</td><td class="num">' + r.loaded + pct(r.loaded) +
         '</td><td class="num">' + r.tapped + pct(r.tapped) +
         '</td><td class="num">' + r.engaged + pct(r.engaged) +
         '</td><td class="num">' + r.messaged + pct(r.messaged) +
         '</td><td class="num">' + r.gated + pct(r.gated) + '</td></tr>';
  }
  if (!(d.funnel || []).length) h += '<tr><td colspan="7" class="muted">No data yet.</td></tr>';
  h += '</table></div>';

  const buckets = d.dwellBuckets || [];
  if (buckets.length) {
    h += '<h2>How long before giving up</h2><p class="muted" style="margin:0 0 8px">' +
         'Visits that opened a character and never typed, tapped a starter, or sent ' +
         'anything. Left instantly means gone before the first half-second tick &mdash; ' +
         'the screen never had a chance. Stayed the full 30s means they were still ' +
         'reading when we stopped counting.</p><div class="wrap"><table><tr><th>Source</th>' +
         // Last column is labelled from the real cap rather than a written-in
         // "30s": the slow phase's final tick lands at 28s, not 30, so a fixed
         // label would overstate by two seconds and quietly rot again the next
         // time the cadence moves.
         '<th>Never engaged</th><th>Left instantly</th><th>&lt;5s</th><th>5&ndash;15s</th>' +
         '<th>15&ndash;' + screenPingSeconds(PING.maxTicks) + 's</th>' +
         '<th>Stayed ' + screenPingSeconds(PING.maxTicks) + 's+</th></tr>';
    for (const r of buckets) {
      h += '<tr><td>' + esc(r.source) + '</td><td class="num">' + r.never_engaged +
           '</td><td class="num">' + (r.left_instantly || 0) +
           '</td><td class="num">' + (r.left_under_5s || 0) +
           '</td><td class="num">' + (r.left_5s_to_15s || 0) +
           '</td><td class="num">' + (r.left_15s_to_30s || 0) +
           '</td><td class="num">' + (r.stayed_full_30s || 0) + '</td></tr>';
    }
    h += '</table></div>';
  }

  const chars = d.characters || [];
  if (chars.length) {
    h += '<h2>By character</h2><div class="wrap"><table><tr><th>Character</th>' +
         '<th>Event</th><th>Count</th></tr>';
    for (const r of chars) {
      h += '<tr><td>' + esc(r.character_id) + '</td><td>' + esc(r.event) +
           '</td><td class="num">' + r.n + '</td></tr>';
    }
    h += '</table></div>';
  }

  h += '<h2>By source</h2><div class="wrap"><table><tr><th>Source</th><th>Visits</th>' +
       '<th>Saw the app</th><th>Gave up loading</th><th>Avg load</th>' +
       '<th>Left under 3s</th><th>Avg dwell</th></tr>';
  for (const r of d.bySource) {
    const gaveUp = r.visits - (r.saw_app || 0);
    h += '<tr><td>' + esc(r.source) + '</td><td class="num">' + r.visits +
         '</td><td class="num">' + (r.saw_app || 0) +
         '</td><td class="num">' + gaveUp +
         '</td><td class="num">' + dur(r.avg_load_ms) +
         '</td><td class="num">' + (r.bounced_under_3s || 0) +
         '</td><td class="num">' + dur(r.avg_ms) + '</td></tr>';
  }
  if (!d.bySource.length) h += '<tr><td colspan="7" class="muted">No visits yet.</td></tr>';
  h += '</table></div>';

  // Each day drills into the sessions that made up its count. Same
  // date(created_at) grouping on both sides, so the number here and the number
  // of rows there agree.
  h += '<h2>By day</h2><p class="muted" style="margin:0 0 8px">' +
       'Pick a day to see its individual sessions, longest dwell first.</p>' +
       '<div class="wrap"><table><tr><th>Day</th><th>Visits</th></tr>';
  for (const r of d.byDay) {
    h += '<tr><td><a class="drill" href="/admin/sessions?day=' + encodeURIComponent(r.day) +
         '">' + esc(r.day) + '</a></td><td class="num">' + r.visits + '</td></tr>';
  }
  h += '</table></div>';

  h += '<h2>Recent arrivals</h2><div class="wrap"><table><tr><th>When (UTC)</th><th>Path</th>' +
       '<th>Source</th><th>Campaign</th><th>Country</th><th>Load</th><th>Dwell</th>' +
       '<th>Ticks</th><th>Chat</th></tr>';
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
         '</td><td>' + esc(r.source) + '</td><td>' +
         esc([r.utm_medium, r.utm_campaign].filter(Boolean).join(' / ')) +
         '</td><td>' + esc(r.country) + '</td><td class="num">' + dur(r.load_ms) +
         '</td><td class="num">' + dur(r.duration_ms) +
         '</td><td class="num">' + ticksCell + '</td><td>' +
         (r.messaged
           ? '<a href="#" class="drill" data-v="' + esc(r.visit_id) + '">view</a>'
           : '<span class="muted">—</span>') +
         '</td></tr><tr class="chat" id="chat-' + esc(r.visit_id) +
         '" style="display:none"><td colspan="9"></td></tr>';
  }
  if (!d.recent.length) h += '<tr><td colspan="9" class="muted">Nothing yet.</td></tr>';
  h += '</table></div>';
  out.innerHTML = h;

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
  <div class="wrap"><table id="src"><thead><tr><th>Source</th><th class="num">Visits</th></tr></thead><tbody></tbody></table></div>

  <h2>By character</h2>
  <div class="wrap"><table id="chr"><thead><tr><th>Character</th><th class="num">Visits</th><th class="num">Conversations</th><th class="num">Bad links</th></tr></thead><tbody></tbody></table></div>

  <h2>Recent arrivals</h2>
  <div class="wrap"><table id="rec"><thead><tr><th>When (UTC)</th><th>Character</th><th>Source</th><th>Medium</th><th>Campaign</th></tr></thead><tbody></tbody></table></div>
</main>
<script>
const esc = s => (s == null ? '' : String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])));
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
    .map(r => '<tr><td>' + esc(r.source || 'unknown') + '</td><td class="num">' + r.visits + '</td></tr>').join('')
    || '<tr><td colspan="2" class="muted">No visits yet.</td></tr>';
  document.querySelector('#chr tbody').innerHTML = (d.byCharacter || [])
    .map(r => '<tr><td>' + esc(r.character_id || '(none)') + '</td><td class="num">' + r.visits +
      '</td><td class="num">' + (r.conversations ?? 0) + '</td><td class="num ' + (r.unknown_hits ? 'warn' : 'muted') + '">' +
      (r.unknown_hits || 0) + '</td></tr>').join('')
    || '<tr><td colspan="4" class="muted">No visits yet.</td></tr>';
  document.querySelector('#rec tbody').innerHTML = (d.recent || [])
    .map(r => '<tr><td class="muted">' + esc(r.created_at) + '</td><td>' + esc(r.character_id || '-') +
      (r.known_character === 0 ? ' <span class="warn">(unknown)</span>' : '') +
      '</td><td>' + esc(r.source || '-') + '</td><td>' + esc(r.utm_medium || '-') + '</td><td>' + esc(r.utm_campaign || '-') + '</td></tr>').join('')
    || '<tr><td colspan="5" class="muted">No visits yet.</td></tr>';
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
<meta name="robots" content="noindex, nofollow">
<title>Mythos Live - Chat Logs</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0; background: #0f0f14; color: #e6e6ea; }
  header { padding: 16px 24px; border-bottom: 1px solid #2a2a33; display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
  header h1 { font-size: 18px; margin: 0 auto 0 0; }
  input, select, button { background: #1c1c24; border: 1px solid #33333d; color: #e6e6ea; padding: 6px 10px; border-radius: 6px; font-size: 13px; }
  button { cursor: pointer; }
  button:hover { background: #26262f; }
  label.chk { font-size: 13px; color: #9a9aa5; display: flex; align-items: center; gap: 4px; }
  main { padding: 16px 24px; max-width: 1100px; margin: 0 auto; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid #22222a; vertical-align: top; }
  th { color: #9a9aa5; font-weight: 600; }
  tr.conv-row, tr.log-row { cursor: pointer; }
  tr.conv-row:hover, tr.log-row:hover { background: #17171d; }
  .err-badge { color: #e57373; font-weight: 600; }
  .pager { display: flex; gap: 8px; align-items: center; margin-top: 12px; }
  .empty, .error { padding: 24px; color: #9a9aa5; text-align: center; }
  h2 { font-size: 15px; color: #9a9aa5; margin: 28px 0 8px; }
  .status-completed { color: #6fd08c; }
  .status-ai_error, .status-rejected_validation { color: #e57373; }
  .status-rate_limited { color: #e5b573; }
  .preview { max-width: 320px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

  /* Transcript view */
  #t-meta { color: #9a9aa5; font-size: 13px; margin-bottom: 16px; }
  .bubble-row { display: flex; margin-bottom: 4px; }
  .bubble { max-width: 72%; padding: 10px 14px; border-radius: 14px; white-space: pre-wrap; word-break: break-word; font-size: 14px; line-height: 1.4; }
  .bubble.user { margin-left: auto; background: #52203f; border-bottom-right-radius: 4px; }
  .bubble.ai { margin-right: auto; background: #1c1c24; border-bottom-left-radius: 4px; }
  .bubble.failed { background: #2a1518; color: #e57373; font-style: italic; }
  .ex-meta { font-size: 11px; color: #55555f; margin: 2px 0 14px; }
  .ex-meta .err-text { color: #e57373; }
  .gap-divider { text-align: center; color: #9a9aa5; font-size: 12px; margin: 16px 0; }

  /* Visits that opened a character and never typed. Dimmed so the eye still
     lands on real conversations first, but present so the drop-off is
     countable instead of invisible. */
  tr.silent td { color: #6b6b78; }
  tr.silent td.ch { font-style: italic; }
  .tick-badge { color: #7e9fd6; }
  .silent-note { color: #9a9aa5; font-style: italic; }

  /* Tick trail */
  .timeline { border-left: 2px solid #2a2a33; margin: 8px 0 20px; padding: 0 0 0 14px; }
  .tl-item { position: relative; padding: 3px 0; font-size: 13px; color: #c8c8d2; }
  .tl-item::before { content: ""; position: absolute; left: -19px; top: 10px; width: 6px; height: 6px; border-radius: 50%; background: #45455a; }
  .tl-item.key::before { background: #b39ddb; }
  .tl-item.leave::before { background: #e5b573; }
  .tl-time { color: #6b6b78; margin-right: 8px; font-variant-numeric: tabular-nums; }
  .tl-ticks { color: #7e9fd6; }
  .tl-summary { background: #16161c; border: 1px solid #26262f; border-radius: 8px; padding: 12px 14px; margin: 0 0 16px; font-size: 13px; line-height: 1.7; }
  .tl-summary b { color: #e6e6ea; font-weight: 600; }
</style>
</head>
<body>
<header>
  <h1>Chat Logs</h1>
  <a href="/admin/referrals">Campaign links &rarr;</a>
  <span id="list-controls" style="display: contents;">
    <input id="f-character" placeholder="character">
    <input id="f-user" placeholder="user_id">
    <label class="chk"><input type="checkbox" id="f-errors"> errors only</label>
    <button id="search-btn">Search</button>
    <select id="export-days">
      <option value="1">last 24 hours</option>
      <option value="7">last 7 days</option>
      <option value="30" selected>last 30 days</option>
      <option value="90">last 90 days</option>
    </select>
    <button id="export-btn">Export</button>
  </span>
  <span id="transcript-controls" style="display: none;">
    <button id="back-btn">&larr; Back</button>
    <button id="export-conv-btn">Export conversation</button>
  </span>
</header>
<main>
  <section id="view-list">
    <table>
      <thead>
        <tr><th>Character</th><th>User</th><th>Messages</th><th>Ticks</th><th>Errors</th><th>Tokens</th><th>First</th><th>Last active</th></tr>
      </thead>
      <tbody id="conv-rows"></tbody>
    </table>
    <div class="pager">
      <button id="prev-btn">Prev</button>
      <span id="page-info"></span>
      <button id="next-btn">Next</button>
    </div>
    <h2>Recent errors</h2>
    <table>
      <thead>
        <tr><th>Time</th><th>User</th><th>Chat</th><th>Status</th><th>User message</th></tr>
      </thead>
      <tbody id="error-rows"></tbody>
    </table>
  </section>
  <section id="view-transcript" style="display: none;">
    <div id="t-meta"></div>
    <div id="t-messages"></div>
  </section>
</main>
<script>
(function () {
  var limit = 50;
  var offset = 0;
  var current = null; // { userId, chatId } when transcript open

  var convRowsEl = document.getElementById("conv-rows");
  var errorRowsEl = document.getElementById("error-rows");
  var pageInfoEl = document.getElementById("page-info");
  var prevBtnEl = document.getElementById("prev-btn");
  var nextBtnEl = document.getElementById("next-btn");

  function td(text) {
    var el = document.createElement("td");
    el.textContent = (text === null || text === undefined) ? "" : String(text);
    return el;
  }

  function parseUtc(s) {
    var iso = String(s);
    if (iso.indexOf("T") === -1) iso = iso.replace(" ", "T");
    if (!/(Z|[+-]\\d{2}:?\\d{2})$/.test(iso)) iso += "Z";
    return new Date(iso);
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

  function listParams() {
    var sp = new URLSearchParams();
    sp.set("limit", limit);
    sp.set("offset", offset);
    var character = document.getElementById("f-character").value.trim();
    var userId = document.getElementById("f-user").value.trim();
    if (character) sp.set("character", character);
    if (userId) sp.set("user_id", userId);
    if (document.getElementById("f-errors").checked) sp.set("errors_only", "1");
    return sp;
  }

  function loadConversations() {
    emptyMessage(convRowsEl, 8, "Loading...", "empty");
    fetch("/api/admin/conversations?" + listParams().toString())
      .then(function (r) { return r.json(); })
      .then(renderConversations)
      .catch(function (err) {
        emptyMessage(convRowsEl, 8, "Failed to load: " + err.message, "error");
      });
  }

  function renderConversations(data) {
    convRowsEl.innerHTML = "";
    if (data.error) {
      emptyMessage(convRowsEl, 8, data.error, "error");
      pageInfoEl.textContent = "";
      prevBtnEl.disabled = offset === 0;
      nextBtnEl.disabled = true;
      return;
    }
    var convs = data.conversations || [];
    if (convs.length === 0) {
      emptyMessage(convRowsEl, 8, "No conversations found.", "empty");
    }
    prevBtnEl.disabled = offset === 0;
    nextBtnEl.disabled = convs.length < limit;

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
      row.appendChild(td(silent ? "" : (c.total_tokens || 0)));
      row.appendChild(td(fmtTime(c.first_at)));
      row.appendChild(td(fmtTime(c.last_at)));

      row.addEventListener("click", function () {
        if (silent) openVisitDetail(c.visit_id, c.chat_id);
        else openTranscript(c.user_id, c.chat_id);
      });
      convRowsEl.appendChild(row);
    });
    pageInfoEl.textContent = "Showing " + convs.length + " (offset " + offset + ")";
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

  function showView(name) {
    document.getElementById("view-list").style.display = name === "list" ? "" : "none";
    document.getElementById("list-controls").style.display = name === "list" ? "contents" : "none";
    document.getElementById("view-transcript").style.display = name === "transcript" ? "" : "none";
    document.getElementById("transcript-controls").style.display = name === "transcript" ? "contents" : "none";
  }

  function openTranscript(userId, chatId) {
    current = { userId: userId, chatId: chatId };
    showView("transcript");
    document.getElementById("export-conv-btn").style.display = "";
    var metaEl = document.getElementById("t-meta");
    var messagesEl = document.getElementById("t-messages");
    metaEl.textContent = "Loading...";
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

  // Ticks are 500ms apart while the character screen sits unengaged. Report
  // the span between first and last rather than count x 500ms: a backgrounded
  // tab stops ticking, so multiplying would claim attention that never
  // happened.
  function tickSpanMs(data) {
    if (!data.first_tick_at || !data.last_tick_at) return 0;
    return parseUtc(data.last_tick_at) - parseUtc(data.first_tick_at);
  }

  function fmtDuration(ms) {
    if (ms === null || ms === undefined || isNaN(ms)) return "unknown";
    var secs = Math.round(ms / 1000);
    if (secs < 60) return secs + "s";
    var mins = Math.floor(secs / 60);
    return mins + "m " + (secs % 60) + "s";
  }

  // The tick trail. Consecutive screen_pings collapse into one line — sixty
  // near-identical rows would bury the events that actually mean something.
  function renderTimeline(container, events) {
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
        item.className = "tl-item " + (isLeave ? "leave" : "key");
        var t2 = document.createElement("span");
        t2.className = "tl-time";
        t2.textContent = fmtTime(e.created_at);
        item.appendChild(t2);
        var label = e.event + (e.detail ? " (" + e.detail + ")" : "");
        if (isLeave && e.duration_ms) label += " - dwell " + fmtDuration(e.duration_ms);
        if (e.failure_reason) label += " - " + e.failure_reason;
        item.appendChild(document.createTextNode(label));
        i++;
      }
      wrap.appendChild(item);
    }
    container.appendChild(wrap);
  }

  // A visit that opened a character and never typed. There is no transcript
  // to show, so the tick trail IS the record: how long they looked, and when
  // they gave up.
  function openVisitDetail(visitId, character) {
    current = null;
    showView("transcript");
    // Nothing to export — there is no transcript, only the tick trail.
    document.getElementById("export-conv-btn").style.display = "none";
    var metaEl = document.getElementById("t-meta");
    var messagesEl = document.getElementById("t-messages");
    metaEl.textContent = "Loading...";
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

    renderTimeline(messagesEl, data.events);
  }

  function renderTranscript(data, metaEl, messagesEl) {
    var msgs = data.messages || [];
    var name = characterName(data.chat_id);
    var tokens = 0;
    msgs.forEach(function (m) { tokens += m.total_tokens || 0; });
    metaEl.textContent = name + " x " + shortUser(data.user_id) + " - " +
      msgs.length + " exchanges" +
      (msgs.length ? ", " + fmtTime(msgs[0].created_at) + " to " + fmtTime(msgs[msgs.length - 1].created_at) : "") +
      (tokens ? ", " + tokens + " tokens" : "");

    if (data.tick_count || data.left_at) {
      var sum = document.createElement("div");
      sum.className = "tl-summary";
      var parts = [];
      if (data.tick_count) {
        parts.push("<b>" + data.tick_count + " ticks</b> before engaging (" +
          fmtDuration(tickSpanMs(data)) + " looking at the character)");
      }
      if (data.left_at) {
        parts.push("left <b>" + fmtTime(data.left_at) + "</b>" +
          (data.dwell_ms ? " after " + fmtDuration(data.dwell_ms) + " on the site" : ""));
      }
      sum.innerHTML = parts.join("<br>");
      messagesEl.appendChild(sum);
      renderTimeline(messagesEl, data.events);
    }

    var prevAt = null;
    msgs.forEach(function (m) {
      var at = parseUtc(m.created_at);
      if (prevAt && at - prevAt > 30 * 60 * 1000) {
        var divider = document.createElement("div");
        divider.className = "gap-divider";
        divider.textContent = gapText(at - prevAt);
        messagesEl.appendChild(divider);
      }
      prevAt = at;

      appendBubble(messagesEl, m.user_message, "user", false);
      if (m.status === "completed" && m.assistant_message) {
        appendBubble(messagesEl, m.assistant_message, "ai", false);
      } else {
        appendBubble(messagesEl, "[message failed]", "ai", true);
      }

      var meta = document.createElement("div");
      meta.className = "ex-meta";
      var metaText = fmtTime(m.created_at) + " | " + m.status + " (" + m.status_code + ") | " + m.model +
        (m.total_tokens ? " | " + m.total_tokens + " tokens" : "");
      meta.textContent = metaText;
      if (m.error) {
        var errSpan = document.createElement("span");
        errSpan.className = "err-text";
        errSpan.textContent = " | " + m.error;
        meta.appendChild(errSpan);
      }
      messagesEl.appendChild(meta);
    });
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
    bubble.textContent = text;
    row.appendChild(bubble);
    container.appendChild(row);
  }

  document.getElementById("search-btn").addEventListener("click", function () {
    offset = 0;
    loadConversations();
  });
  document.getElementById("prev-btn").addEventListener("click", function () {
    offset = Math.max(0, offset - limit);
    loadConversations();
  });
  document.getElementById("next-btn").addEventListener("click", function () {
    offset = offset + limit;
    loadConversations();
  });
  document.getElementById("back-btn").addEventListener("click", function () {
    current = null;
    showView("list");
  });
  document.getElementById("export-btn").addEventListener("click", function () {
    var sp = new URLSearchParams();
    sp.set("days", document.getElementById("export-days").value);
    var character = document.getElementById("f-character").value.trim();
    if (character) sp.set("character", character);
    window.location = "/api/admin/export?" + sp.toString();
  });
  document.getElementById("export-conv-btn").addEventListener("click", function () {
    if (!current) return;
    window.location = "/api/admin/export?user_id=" + encodeURIComponent(current.userId) +
      "&chat_id=" + encodeURIComponent(current.chatId);
  });

  loadConversations();
  loadErrors();
})();
</script>
</body>
</html>`;
}
