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
            };
            const chatId = typeof metadata.chatId === "string" && metadata.chatId.trim()
                ? metadata.chatId.trim()
                : "default";

            const validationError = validateInput(userMessage);
            if (validationError) {
                await persistConversationLog(env, {
                    id: requestId,
                    userId,
                    chatId,
                    scenario: metadata.scenario,
                    language: metadata.language,
                    model: "gpt-4o-mini",
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

            // 4. Proxy to OpenAI with Fixed Model
            // Enforce model: gpt-4o-mini
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

            // Pass back the response
            const responseData = await openAiResponse.json();
            const assistantMessage = extractAssistantMessage(responseData);

            await persistConversationLog(env, {
                id: requestId,
                userId,
                chatId,
                scenario: metadata.scenario,
                language: metadata.language,
                model: openAiBody.model,
                status: openAiResponse.ok ? "completed" : "openai_error",
                statusCode: openAiResponse.status,
                userMessage,
                assistantMessage,
                requestMessages: body.messages,
                responseBody: responseData,
                error: openAiResponse.ok ? null : extractErrorMessage(responseData),
                clientTimestamp: timestamp,
            });

            return new Response(JSON.stringify(responseData), {
                status: openAiResponse.status,
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
        "Access-Control-Allow-Headers": "Content-Type, x-signature, x-timestamp, x-user-id, x-chat-id, x-scenario, x-language",
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
function validateInput(text) {
    if (!text) return null; // Let empty pass or fail elsewhere? OpenAI handles empty.

    if (text.length > 2000) {
        return "Message too long.";
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
