// Sign in with Google / Sign in with Apple — the parts that do not depend on
// the rest of the worker: verifying an identity token against the provider's
// published keys, minting Apple's client secret, and Apple's token exchange
// and revocation.
//
// Why ID tokens and not the web redirect for the app: the native SDKs
// (google_sign_in, sign_in_with_apple) hand the app a signed JWT. The worker
// checks that signature against the provider's JWKS, so the app never has to
// be trusted — the same reason identity on the web comes from the session
// cookie and never from x-user-id.
//
// Everything here uses Web Crypto only, so it runs unchanged in workerd and in
// Node's test runner.

export const GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs";
export const APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys";
export const GOOGLE_ISSUERS = ["https://accounts.google.com", "accounts.google.com"];
export const APPLE_ISSUER = "https://appleid.apple.com";

// Keys rotate rarely and both providers publish the next key well before
// using it, so an hour is safe. An unknown kid forces one refetch regardless,
// which is what makes a rotation inside the hour harmless.
const JWKS_TTL_MS = 60 * 60 * 1000;
// Clock skew allowed on exp / iat. Phones are frequently a minute or two off.
const CLOCK_SKEW_S = 300;

const jwksCache = new Map(); // url -> { keys, fetchedAt }

/// For tests: forget cached key sets so each test controls what is served.
export function resetJwksCache() {
    jwksCache.clear();
}

function b64urlToBytes(value) {
    const padded = value.replace(/-/g, "+").replace(/_/g, "/")
        .padEnd(Math.ceil(value.length / 4) * 4, "=");
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
}

function bytesToB64url(bytes) {
    let binary = "";
    for (const b of bytes) binary += String.fromCharCode(b);
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function jsonToB64url(obj) {
    return bytesToB64url(new TextEncoder().encode(JSON.stringify(obj)));
}

export async function sha256Hex(text) {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
    return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function fetchJwks(url, { force = false } = {}) {
    const cached = jwksCache.get(url);
    if (!force && cached && Date.now() - cached.fetchedAt < JWKS_TTL_MS) return cached.keys;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`JWKS fetch failed (${res.status})`);
    const body = await res.json();
    const keys = Array.isArray(body?.keys) ? body.keys : [];
    jwksCache.set(url, { keys, fetchedAt: Date.now() });
    return keys;
}

/// Splits and decodes a JWT without trusting it. Throws on anything malformed.
export function decodeJwt(token) {
    if (typeof token !== "string") throw new Error("token missing");
    const parts = token.split(".");
    if (parts.length !== 3) throw new Error("token malformed");
    const td = new TextDecoder();
    const header = JSON.parse(td.decode(b64urlToBytes(parts[0])));
    const payload = JSON.parse(td.decode(b64urlToBytes(parts[1])));
    return { header, payload, signingInput: `${parts[0]}.${parts[1]}`, signature: b64urlToBytes(parts[2]) };
}

/// Verifies an RS256 identity token: signature against the JWKS at `jwksUrl`,
/// then issuer, audience (any of `audiences`), expiry and issued-at. Returns
/// the payload, or throws with a reason that is safe to log (never the token).
export async function verifyIdToken(token, { jwksUrl, issuers, audiences, now = Date.now() }) {
    const { header, payload, signingInput, signature } = decodeJwt(token);
    // RS256 only. Accepting whatever alg the header names is the classic JWT
    // hole ("none", or HS256 keyed with the public key).
    if (header.alg !== "RS256") throw new Error(`unexpected alg ${header.alg}`);
    if (!header.kid) throw new Error("token has no kid");

    let keys = await fetchJwks(jwksUrl);
    let jwk = keys.find((k) => k.kid === header.kid);
    if (!jwk) {
        keys = await fetchJwks(jwksUrl, { force: true });
        jwk = keys.find((k) => k.kid === header.kid);
    }
    if (!jwk) throw new Error("signing key not found");

    const key = await crypto.subtle.importKey(
        "jwk",
        { kty: jwk.kty, n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
        { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
        false,
        ["verify"],
    );
    const ok = await crypto.subtle.verify(
        "RSASSA-PKCS1-v1_5", key, signature, new TextEncoder().encode(signingInput),
    );
    if (!ok) throw new Error("bad signature");

    if (!issuers.includes(payload.iss)) throw new Error("wrong issuer");
    const aud = Array.isArray(payload.aud) ? payload.aud : [payload.aud];
    const wanted = audiences.filter(Boolean);
    if (!wanted.length || !aud.some((a) => wanted.includes(a))) throw new Error("wrong audience");
    const nowS = Math.floor(now / 1000);
    if (typeof payload.exp !== "number" || payload.exp + CLOCK_SKEW_S < nowS) throw new Error("token expired");
    if (typeof payload.iat === "number" && payload.iat - CLOCK_SKEW_S > nowS) throw new Error("token from the future");
    if (!payload.sub) throw new Error("token has no subject");
    return payload;
}

// --- Google -----------------------------------------------------------------

/// The client ids a Google ID token may be addressed to: the web client (the
/// redirect flow, and the native SDK when it is given a serverClientId) and
/// the iOS client (the native SDK without one).
export function googleAudiences(env) {
    return [env.GOOGLE_CLIENT_ID, env.GOOGLE_IOS_CLIENT_ID, env.GOOGLE_ANDROID_CLIENT_ID].filter(Boolean);
}

export async function verifyGoogleIdToken(env, token) {
    const payload = await verifyIdToken(token, {
        jwksUrl: GOOGLE_JWKS_URL,
        issuers: GOOGLE_ISSUERS,
        audiences: googleAudiences(env),
    });
    return {
        provider: "google",
        sub: String(payload.sub),
        email: payload.email_verified === false ? null : (payload.email || null),
        name: payload.name || null,
        picture: payload.picture || null,
    };
}

// --- Apple ------------------------------------------------------------------

/// Native tokens are addressed to the app's bundle id, web ones to the
/// Services ID. Either is fine for identity — the `sub` is the same for one
/// Apple ID across every client id under the same team.
export function appleAudiences(env) {
    return [env.APPLE_BUNDLE_ID, env.APPLE_SERVICES_ID].filter(Boolean);
}

/// `rawNonce` is what the client generated; Apple puts its SHA-256 (native)
/// into the token. On the web flow we send the raw value and Apple echoes it
/// unhashed, so `nonceHashed: false` there.
export async function verifyAppleIdToken(env, token, { rawNonce = null, nonceHashed = true } = {}) {
    const payload = await verifyIdToken(token, {
        jwksUrl: APPLE_JWKS_URL,
        issuers: [APPLE_ISSUER],
        audiences: appleAudiences(env),
    });
    if (rawNonce !== null) {
        const expected = nonceHashed ? await sha256Hex(rawNonce) : rawNonce;
        if (payload.nonce !== expected) throw new Error("nonce mismatch");
    }
    const aud = Array.isArray(payload.aud) ? payload.aud[0] : payload.aud;
    return {
        provider: "apple",
        sub: String(payload.sub),
        // Often a private-relay address. Apple sends it on every sign-in but
        // the user's NAME only on the very first one, and only to the client.
        email: payload.email || null,
        name: null,
        picture: null,
        clientId: aud,
    };
}

export function appleKeyConfigured(env) {
    return Boolean(env.APPLE_TEAM_ID && env.APPLE_KEY_ID && env.APPLE_PRIVATE_KEY);
}

function pemToPkcs8(pem) {
    const body = String(pem)
        .replace(/\\n/g, "\n")
        .replace(/-----BEGIN [^-]+-----/, "")
        .replace(/-----END [^-]+-----/, "")
        .replace(/\s+/g, "");
    return b64urlToBytes(body.replace(/\+/g, "-").replace(/\//g, "_"));
}

/// Apple's "client secret": an ES256 JWT signed with the .p8 key from the
/// developer account, valid for at most six months. Minted per call — it is
/// cheap, and it means a rotated key needs only a secret update, no redeploy.
export async function appleClientSecret(env, clientId, now = Date.now()) {
    if (!appleKeyConfigured(env)) throw new Error("Apple key is not configured");
    const key = await crypto.subtle.importKey(
        "pkcs8", pemToPkcs8(env.APPLE_PRIVATE_KEY),
        { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
    );
    const iat = Math.floor(now / 1000);
    const header = { alg: "ES256", kid: env.APPLE_KEY_ID };
    const payload = { iss: env.APPLE_TEAM_ID, iat, exp: iat + 60 * 60, aud: APPLE_ISSUER, sub: clientId };
    const signingInput = `${jsonToB64url(header)}.${jsonToB64url(payload)}`;
    // Web Crypto's ECDSA output is already r||s (IEEE P1363), which is what
    // JWS ES256 wants — no DER unwrapping.
    const sig = await crypto.subtle.sign(
        { name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signingInput),
    );
    return `${signingInput}.${bytesToB64url(new Uint8Array(sig))}`;
}

/// Trades an authorization code for tokens. We want the refresh token for one
/// reason: Apple requires apps that offer account deletion to revoke it then.
/// `redirectUri` is required for the web flow and must be omitted for native.
export async function appleExchangeCode(env, { code, clientId, redirectUri = null }) {
    const params = new URLSearchParams({
        client_id: clientId,
        client_secret: await appleClientSecret(env, clientId),
        code,
        grant_type: "authorization_code",
    });
    if (redirectUri) params.set("redirect_uri", redirectUri);
    const res = await fetch(`${APPLE_ISSUER}/auth/token`, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: params,
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(`Apple token exchange failed (${res.status} ${data.error || ""})`.trim());
    return data; // { access_token, refresh_token, id_token, ... }
}

/// Revokes a refresh token. Apple answers 200 for an already-revoked token,
/// so this is safe to repeat.
export async function appleRevoke(env, { token, clientId, hint = "refresh_token" }) {
    const res = await fetch(`${APPLE_ISSUER}/auth/revoke`, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
            client_id: clientId,
            client_secret: await appleClientSecret(env, clientId),
            token,
            token_type_hint: hint,
        }),
    });
    if (!res.ok) throw new Error(`Apple revoke failed (${res.status})`);
    return true;
}
