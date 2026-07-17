/**
 * Cloudflare Worker for Secure AI Backend
 * 
 * Features:
 * 1. HMAC Signature Verification
 * 2. Rate Limiting (Token Bucket / Fixed Window)
 * 3. Input Validation
 * 4. Fixed Model Enforcement
 */

export default {
    async fetch(request, env, ctx) {
        const url = new URL(request.url);

        if (request.method === "OPTIONS") {
            return new Response(null, { headers: corsHeaders(request) });
        }

        if (request.method === "GET" && url.pathname === "/auth/instagram/start") {
            return startInstagramAuth(request, env, url);
        }

        if (request.method === "GET" && url.pathname === "/auth/instagram/callback") {
            return finishInstagramAuth(request, env, url);
        }

        if (request.method === "GET" && url.pathname === "/auth/me") {
            const session = await getSessionFromRequest(request, env);
            return jsonResponse({
                authenticated: Boolean(session),
                user: session ? {
                    provider: "instagram",
                    id: session.instagramId,
                    username: session.username,
                } : null,
            }, { headers: corsHeaders(request) });
        }

        if (request.method === "GET" && url.pathname === "/auth/logout") {
            return redirectResponse(getAppOrigin(env), [
                expiredCookie("mymate_session", request),
            ]);
        }

        if (request.method === "GET" && url.pathname === "/admin/logs") {
            const authError = requireAdminAuth(request, env);
            if (authError) return authError;
            return new Response(adminLogsPageHtml(), {
                headers: { "Content-Type": "text/html; charset=utf-8" },
            });
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
                ? `instagram:${session.instagramId}`
                : request.headers.get("x-user-id") || "anonymous";
            const requestId = crypto.randomUUID();

            if (!signature || !timestamp) {
                return new Response(JSON.stringify({ error: "Missing signature or timestamp" }), {
                    status: 401,
                    headers: jsonHeaders(request)
                });
            }

            // Check timestamp freshness (prevent replay attacks > 5 mins)
            const now = Date.now();
            const reqTime = parseInt(timestamp, 10);
            if (Math.abs(now - reqTime) > 5 * 60 * 1000) {
                return new Response(JSON.stringify({ error: "Request expired" }), {
                    status: 401,
                    headers: jsonHeaders(request)
                });
            }

            const bodyText = await request.text();
            const verified = await verifySignature(env.APP_SECRET, bodyText, timestamp, signature);

            if (!verified) {
                return new Response(JSON.stringify({ error: "Invalid signature" }), {
                    status: 401,
                    headers: jsonHeaders(request)
                });
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

            if (inworldCharacter) {
                // Inworld generates the in-character reply, then OpenAI does a
                // cleanup pass. Reshaped into the same {choices:[...]} envelope
                // OpenAI itself returns, so every line below (logging, response
                // shape) is shared with the plain-OpenAI path unchanged.
                try {
                    const cleanedText = await runInworldPipeline(env, inworldCharacter, body.messages);
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
                    messages: body.messages, // Pass through messages
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

            // Pass back the response
            const assistantMessage = extractAssistantMessage(responseData);

            await persistConversationLog(env, {
                id: requestId,
                userId,
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
    const returnTo = safeReturnTo(url.searchParams.get("return_to"), env);
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
        return redirectResponse(`${getAppOrigin(env)}/#/settings?instagram=failed`, [
            expiredCookie("mymate_ig_state", request),
        ]);
    }

    const [expectedState, returnTo] = stateCookie.split("|");
    if (state !== expectedState) {
        return redirectResponse(`${getAppOrigin(env)}/#/settings?instagram=failed`, [
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

        return redirectResponse(returnTo || `${getAppOrigin(env)}/#/settings?instagram=connected`, [
            expiredCookie("mymate_ig_state", request),
            cookie("mymate_session", sessionValue, request, { maxAge: 60 * 60 * 24 * 30 }),
        ]);
    } catch (error) {
        console.error(JSON.stringify({ event: "instagram_auth_failed", error: error.message }));
        return redirectResponse(`${getAppOrigin(env)}/#/settings?instagram=failed`, [
            expiredCookie("mymate_ig_state", request),
        ]);
    }
}

function corsHeaders(request) {
    const origin = request.headers.get("Origin") || "*";
    return {
        "Access-Control-Allow-Origin": origin,
        "Access-Control-Allow-Credentials": "true",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, x-signature, x-timestamp, x-user-id, x-chat-id, x-scenario, x-language, x-character-id",
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

function getAppOrigin(env) {
    return (env.APP_ORIGIN || "http://localhost:8787").replace(/\/$/, "");
}

function safeReturnTo(value, env) {
    const fallback = `${getAppOrigin(env)}/#/settings?instagram=connected`;
    if (!value) return fallback;
    try {
        const url = new URL(value);
        if (url.origin === getAppOrigin(env)) return url.toString();
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

async function persistConversationLog(env, entry) {
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
            client_timestamp
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        entry.clientTimestamp
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
const INWORLD_CHARACTERS = {
    odysseus: {
        id: "odysseus",
        name: "Odysseus",
        systemPrompt:
            "You are Odysseus, king of Ithaca, speaking from the long memory of war, wandering, loyalty, and clever survival.",
        lore:
            "You are the Greek hero Odysseus: tactician of Troy, sailor of impossible seas, husband of Penelope, father of Telemachus, and a man tested by gods and monsters.",
        style: "Use vivid, grounded language with a seasoned, strategic, and occasionally wry tone.",
    },
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

async function runInworldPipeline(env, character, clientMessages) {
    const normalizedMessages = normalizeInworldMessages(clientMessages);
    const rawReply = await callInworldChat(env, character, normalizedMessages);
    return cleanupInworldReply(env, rawReply, character.name);
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

    const filters = [];
    const binds = [];
    const character = params.get("character");
    const userId = params.get("user_id");
    if (character) { filters.push("chat_id LIKE ?"); binds.push(`%${character}%`); }
    if (userId) { filters.push("user_id = ?"); binds.push(userId); }
    const where = filters.length ? `WHERE ${filters.join(" AND ")}` : "";
    const having = params.get("errors_only") === "1"
        ? "HAVING SUM(CASE WHEN status = 'completed' THEN 0 ELSE 1 END) > 0"
        : "";

    const { results } = await env.CHAT_LOGS_DB.prepare(`
        SELECT user_id, chat_id,
               COUNT(*) AS message_count,
               MIN(created_at) AS first_at,
               MAX(created_at) AS last_at,
               SUM(CASE WHEN status = 'completed' THEN 0 ELSE 1 END) AS error_count,
               SUM(COALESCE(total_tokens, 0)) AS total_tokens
        FROM conversation_logs
        ${where}
        GROUP BY user_id, chat_id
        ${having}
        ORDER BY last_at DESC
        LIMIT ? OFFSET ?
    `).bind(...binds, limit, offset).all();

    return { conversations: results, limit, offset };
}

/** All exchanges of one conversation, oldest first. */
async function getTranscript(env, userId, chatId) {
    if (!env.CHAT_LOGS_DB) {
        return { error: "CHAT_LOGS_DB is not configured", messages: [] };
    }
    const { results } = await env.CHAT_LOGS_DB.prepare(`
        SELECT id, created_at, user_message, assistant_message, status, status_code,
               model, error, total_tokens
        FROM conversation_logs
        WHERE user_id = ? AND chat_id = ?
        ORDER BY created_at ASC
        LIMIT 2000
    `).bind(userId, chatId).all();
    return { user_id: userId, chat_id: chatId, messages: results };
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
        const first = new Date(rows[0].created_at + "Z");
        const last = new Date(rows[rows.length - 1].created_at + "Z");
        const who = alias(rows[0].user_id);
        const name = characterName(rows[0].chat_id);
        if (convIndex > 1) lines.push("", "");
        lines.push(
            `=== Conversation ${convIndex}: ${who} x ${name} — ${rows.length} exchanges, ${fmtDay(first)} to ${fmtDay(last)} ===`,
            ""
        );
        prevAt = null;
        for (const row of rows) {
            const at = new Date(row.created_at + "Z");
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


function adminLogsPageHtml() {
    return `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="robots" content="noindex, nofollow">
<title>MyMate - Chat Logs</title>
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
</style>
</head>
<body>
<header>
  <h1>Chat Logs</h1>
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
        <tr><th>Character</th><th>User</th><th>Messages</th><th>Errors</th><th>Tokens</th><th>First</th><th>Last active</th></tr>
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

  function fmtTime(sqliteUtc) {
    try { return new Date(sqliteUtc.replace(" ", "T") + "Z").toLocaleString(); }
    catch (e) { return sqliteUtc; }
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
    emptyMessage(convRowsEl, 7, "Loading...", "empty");
    fetch("/api/admin/conversations?" + listParams().toString())
      .then(function (r) { return r.json(); })
      .then(renderConversations)
      .catch(function (err) {
        emptyMessage(convRowsEl, 7, "Failed to load: " + err.message, "error");
      });
  }

  function renderConversations(data) {
    convRowsEl.innerHTML = "";
    if (data.error) {
      emptyMessage(convRowsEl, 7, data.error, "error");
      pageInfoEl.textContent = "";
      prevBtnEl.disabled = offset === 0;
      nextBtnEl.disabled = true;
      return;
    }
    var convs = data.conversations || [];
    if (convs.length === 0) {
      emptyMessage(convRowsEl, 7, "No conversations found.", "empty");
    }
    prevBtnEl.disabled = offset === 0;
    nextBtnEl.disabled = convs.length < limit;

    convs.forEach(function (c) {
      var row = document.createElement("tr");
      row.className = "conv-row";
      row.appendChild(td(characterName(c.chat_id)));
      row.appendChild(td(shortUser(c.user_id)));
      row.appendChild(td(c.message_count));
      var errCell = td(c.error_count > 0 ? c.error_count : "");
      if (c.error_count > 0) errCell.className = "err-badge";
      row.appendChild(errCell);
      row.appendChild(td(c.total_tokens || 0));
      row.appendChild(td(fmtTime(c.first_at)));
      row.appendChild(td(fmtTime(c.last_at)));
      row.addEventListener("click", function () { openTranscript(c.user_id, c.chat_id); });
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

  function renderTranscript(data, metaEl, messagesEl) {
    var msgs = data.messages || [];
    var name = characterName(data.chat_id);
    var tokens = 0;
    msgs.forEach(function (m) { tokens += m.total_tokens || 0; });
    metaEl.textContent = name + " x " + shortUser(data.user_id) + " - " +
      msgs.length + " exchanges" +
      (msgs.length ? ", " + fmtTime(msgs[0].created_at) + " to " + fmtTime(msgs[msgs.length - 1].created_at) : "") +
      (tokens ? ", " + tokens + " tokens" : "");

    var prevAt = null;
    msgs.forEach(function (m) {
      var at = new Date(m.created_at.replace(" ", "T") + "Z");
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
