// client_platform — "which platform is this user on?", from the database.
//
// Migration 0023 records it at the three points that know it: sign-in,
// /api/chat and /api/delivery. The question had been unanswerable from
// production for three separate reasons, so what is pinned down here is not
// "the column exists" but the four properties that make an answer trustworthy:
//
//   * the three write points agree on one vocabulary, so a GROUP BY returns
//     three buckets rather than six spellings of them;
//   * an unrecognised value is stored as NULL rather than as itself, because
//     all three endpoints take client-asserted input from anonymous callers
//     and a free-text column would both split the count and hand a stranger a
//     place to write;
//   * NULL means unknown and never gets manufactured into a value, so an old
//     client is visibly an old client instead of silently a web user;
//   * the value survives the second sign-in and the second flush, which is
//     where last-writer-wins and COALESCE pull in opposite directions.
//
// The Apple key work is reproduced from sign_in.test.mjs rather than shared:
// that file's helpers are private to it, and a test file that cannot build its
// own fixtures is one more thing to keep in step.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, webcrypto } from 'node:crypto';
import { freshDb, d1, loadWorker, seed, testEnv, adminFetch, ADMIN_TOKEN } from './harness.mjs';
import { resetJwksCache } from '../src/identity.js';

const { subtle } = webcrypto;
const BUNDLE_ID = 'com.sklabs.mythoslive';
const SERVICES_ID = 'com.deeploveechoes.chat.signin';
const GOOGLE_IOS = 'ios-client.apps.googleusercontent.com';
const REAL_USER = 'user_1700000000000';

const b64url = (buf) => Buffer.from(buf).toString('base64url');
const enc = (obj) => b64url(Buffer.from(JSON.stringify(obj)));
const sha256Hex = (s) => createHash('sha256').update(s).digest('hex');
const nowS = () => Math.floor(Date.now() / 1000);

let keys;
let appleP8;

test.before(async () => {
    const rsa = async (kid) => {
        const pair = await subtle.generateKey(
            { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
            true, ['sign', 'verify'],
        );
        const jwk = await subtle.exportKey('jwk', pair.publicKey);
        return { kid, privateKey: pair.privateKey, jwk: { kty: 'RSA', n: jwk.n, e: jwk.e, kid, alg: 'RS256', use: 'sig' } };
    };
    keys = { google: await rsa('g1'), apple: await rsa('a1') };
    const ec = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pkcs8 = Buffer.from(await subtle.exportKey('pkcs8', ec.privateKey)).toString('base64');
    appleP8 = `-----BEGIN PRIVATE KEY-----\n${pkcs8.match(/.{1,64}/g).join('\n')}\n-----END PRIVATE KEY-----`;
});

async function signJwt(key, payload) {
    const input = `${enc({ alg: 'RS256', kid: key.kid, typ: 'JWT' })}.${enc(payload)}`;
    const sig = await subtle.sign('RSASSA-PKCS1-v1_5', key.privateKey, Buffer.from(input));
    return `${input}.${b64url(sig)}`;
}

const googleToken = (claims = {}) => signJwt(keys.google, {
    iss: 'https://accounts.google.com', aud: GOOGLE_IOS, sub: 'g-sub-1',
    email: 'pat@example.com', email_verified: true, name: 'Pat',
    iat: nowS(), exp: nowS() + 3600, ...claims,
});

const appleToken = (rawNonce, claims = {}) => signJwt(keys.apple, {
    iss: 'https://appleid.apple.com', aud: BUNDLE_ID, sub: 'a-sub-1',
    email: 'x@privaterelay.appleid.com', nonce: sha256Hex(rawNonce),
    iat: nowS(), exp: nowS() + 600, ...claims,
});

function stubNetwork(t, { appleRefreshToken = 'apple-refresh-1' } = {}) {
    resetJwksCache();
    const original = globalThis.fetch;
    globalThis.fetch = async (input) => {
        const url = typeof input === 'string' ? input : input.url;
        if (url === 'https://www.googleapis.com/oauth2/v3/certs') return Response.json({ keys: [keys.google.jwk] });
        if (url === 'https://appleid.apple.com/auth/keys') return Response.json({ keys: [keys.apple.jwk] });
        if (url === 'https://appleid.apple.com/auth/token') {
            return Response.json({ access_token: 'at', refresh_token: appleRefreshToken, id_token: 'x' });
        }
        if (url.startsWith('https://api.revenuecat.com/v1/subscribers/')) return Response.json({});
        throw new Error(`unexpected fetch ${url}`);
    };
    t.after(() => { globalThis.fetch = original; });
}

function authEnv(db) {
    return {
        CHAT_LOGS_DB: d1(db),
        SESSION_SECRET: 'test-session-secret',
        APP_SECRET: 'test-app-secret',
        REQUIRE_SIGNATURE: 'false',
        GOOGLE_CLIENT_ID: 'web-client.apps.googleusercontent.com',
        GOOGLE_CLIENT_SECRET: 'gsecret',
        GOOGLE_IOS_CLIENT_ID: GOOGLE_IOS,
        APPLE_BUNDLE_ID: BUNDLE_ID,
        APPLE_SERVICES_ID: SERVICES_ID,
        APPLE_TEAM_ID: 'TEAM123456',
        APPLE_KEY_ID: 'KEY1234567',
        APPLE_PRIVATE_KEY: appleP8,
        APP_ORIGIN: 'https://mythos.test',
        ADMIN_TOKEN,
    };
}

async function call(env, pathname, { method = 'GET', json, headers = {} } = {}) {
    const worker = await loadWorker();
    const h = { ...headers };
    let body;
    if (json !== undefined) { h['Content-Type'] = 'application/json'; body = JSON.stringify(json); }
    const pending = [];
    const res = await worker.fetch(new Request('https://mythos.test' + pathname, { method, headers: h, body }), env,
        { waitUntil(p) { pending.push(p); }, passThroughOnException() {} });
    const text = await res.text();
    await Promise.all(pending);
    let data = null;
    try { data = JSON.parse(text); } catch (_) { /* redirect or html */ }
    return { status: res.status, headers: res.headers, data, text };
}

const platformOf = (db, sub) => db
    .prepare(`SELECT client_platform FROM linked_accounts WHERE provider_id = ?`)
    .get(sub)?.client_platform;

// --- sign-in ------------------------------------------------------------------

test('a native sign-in records the platform the app states', async (t) => {
    stubNetwork(t);
    const db = freshDb();
    const env = authEnv(db);

    for (const platform of ['ios', 'android']) {
        const res = await call(env, '/auth/native', {
            method: 'POST',
            json: { provider: 'google', id_token: await googleToken({ sub: `g-${platform}` }), platform },
        });
        assert.equal(res.status, 200, res.text);
        assert.equal(platformOf(db, `g-${platform}`), platform);
    }
});

test('Google native and Google web are told apart, which apple_client_id could not do', async (t) => {
    // The gap this whole change exists to close. handleNativeSignIn wrote a
    // Google sign-in from the app byte-identically to one from a browser, and
    // the Apple client-id pair — the only hard app-vs-web signal there was —
    // is NULL on every Google row, so the two were indistinguishable.
    stubNetwork(t);
    const db = freshDb();
    const env = authEnv(db);

    await call(env, '/auth/native', {
        method: 'POST',
        json: { provider: 'google', id_token: await googleToken({ sub: 'g-app' }), platform: 'ios' },
    });

    const row = db.prepare(`SELECT client_platform, apple_client_id FROM linked_accounts WHERE provider_id = 'g-app'`).get();
    assert.equal(row.client_platform, 'ios');
    assert.equal(row.apple_client_id, null, 'a Google row carries no Apple client id to infer from');
});

test('an Apple sign-in from a build that states no platform is still known to be iOS', async (t) => {
    // The transition window: every app already installed sends no platform and
    // will keep signing in for weeks. Apple mints the token for the bundle id
    // rather than the Services ID, which proves the app, and the app offers
    // Apple sign-in natively on iOS only — so this one is recoverable.
    stubNetwork(t);
    const db = freshDb();
    const env = authEnv(db);
    const rawNonce = 'nonce-abc';

    const res = await call(env, '/auth/native', {
        method: 'POST',
        json: { provider: 'apple', id_token: await appleToken(rawNonce), raw_nonce: rawNonce, authorization_code: 'code-1' },
    });
    assert.equal(res.status, 200, res.text);
    assert.equal(platformOf(db, 'a-sub-1'), 'ios');
});

test('the web redirect flow records web without being asked', async (t) => {
    // Not client-asserted: only a page navigation reaches this route, so the
    // platform is a property of the route rather than of the request body.
    stubNetwork(t);
    const db = freshDb();
    const env = authEnv(db);
    const worker = await loadWorker();

    const start = await worker.fetch(
        new Request('https://mythos.test/auth/google/start'), env,
        { waitUntil() {}, passThroughOnException() {} });
    const stateCookie = start.headers.get('set-cookie');
    assert.ok(stateCookie, 'the start route sets the state cookie');
    // The cookie is percent-encoded and packs state|returnTo|anonId|anonTicket
    // into one value. Sent back verbatim, with the state query param decoded
    // out of it, which is exactly what the browser does.
    const cookieValue = /mymate_google_state=([^;]*)/.exec(stateCookie)[1];
    const state = decodeURIComponent(cookieValue).split('|')[0];

    const original = globalThis.fetch;
    globalThis.fetch = async (input) => {
        const url = typeof input === 'string' ? input : input.url;
        if (url === 'https://oauth2.googleapis.com/token') return Response.json({ access_token: 'at' });
        if (url === 'https://www.googleapis.com/oauth2/v3/userinfo') {
            return Response.json({ sub: 'g-web-1', email: 'web@example.com', name: 'Web Pat' });
        }
        if (url.startsWith('https://api.revenuecat.com/v1/subscribers/')) return Response.json({});
        throw new Error(`unexpected fetch ${url}`);
    };
    t.after(() => { globalThis.fetch = original; });

    const res = await worker.fetch(new Request(
        `https://mythos.test/auth/google/callback?code=c1&state=${state}`,
        { headers: { cookie: `mymate_google_state=${cookieValue}` } },
    ), env, { waitUntil() {}, passThroughOnException() {} });
    assert.equal(res.status, 302, await res.text());
    assert.equal(platformOf(db, 'g-web-1'), 'web');
});

test('a platform the worker does not recognise is stored as unknown, not as itself', async (t) => {
    // /auth/native is unauthenticated by design — the ID token is what is
    // trusted, not the body around it — so this field is a stranger's string.
    // Storing it verbatim would both split the GROUP BY and put arbitrary text
    // into a column the admin pages render.
    stubNetwork(t);
    const db = freshDb();
    const env = authEnv(db);

    const junk = ['iOS', 'ios-17.2', 'iphone', '', 'web ', 42, null, { platform: 'ios' }];
    for (let i = 0; i < junk.length; i++) {
        const res = await call(env, '/auth/native', {
            method: 'POST',
            json: { provider: 'google', id_token: await googleToken({ sub: `g-junk-${i}` }), platform: junk[i] },
        });
        assert.equal(res.status, 200, res.text);
        assert.equal(platformOf(db, `g-junk-${i}`), null, `${JSON.stringify(junk[i])} should not be stored`);
    }
});

test('signing in again moves the platform, and an old build never blanks it', async (t) => {
    // linked_at is refreshed on every sign-in, so the row means "the most
    // recent sign-in" and the platform has to agree with it: someone who
    // signed in on the web in August and on their phone this morning is an iOS
    // user today. But a build predating the column sends nothing, and that
    // must read as "no news" rather than as "no longer iOS" — the two pull in
    // opposite directions and both are wrong if the other wins.
    stubNetwork(t);
    const db = freshDb();
    const env = authEnv(db);
    const signIn = async (platform) => call(env, '/auth/native', {
        method: 'POST',
        json: { provider: 'google', id_token: await googleToken(), ...(platform ? { platform } : {}) },
    });

    await signIn('web');
    assert.equal(platformOf(db, 'g-sub-1'), 'web');

    await signIn('ios');
    assert.equal(platformOf(db, 'g-sub-1'), 'ios', 'the newer sign-in wins');

    await signIn(null);
    assert.equal(platformOf(db, 'g-sub-1'), 'ios', 'a build that says nothing erases nothing');

    await signIn('bogus');
    assert.equal(platformOf(db, 'g-sub-1'), 'ios', 'and neither does one that says nonsense');
});

test('the question this migration exists for is one GROUP BY', async (t) => {
    stubNetwork(t);
    const db = freshDb();
    const env = authEnv(db);

    for (const [sub, platform] of [['a', 'ios'], ['b', 'ios'], ['c', 'android'], ['d', 'web'], ['e', null]]) {
        await call(env, '/auth/native', {
            method: 'POST',
            json: { provider: 'google', id_token: await googleToken({ sub }), ...(platform ? { platform } : {}) },
        });
    }

    const rows = db.prepare(`
        SELECT client_platform, COUNT(*) AS n FROM linked_accounts
        WHERE linked_at >= datetime('now', '-7 days')
        GROUP BY client_platform ORDER BY n DESC, client_platform
    `).all().map((r) => ({ ...r }));
    assert.deepEqual(rows, [
        { client_platform: 'ios', n: 2 },
        // NULL is its own bucket and has to stay visible: it is the old-client
        // count, and folding it into any platform would be the error the whole
        // migration is written against.
        { client_platform: null, n: 1 },
        { client_platform: 'android', n: 1 },
        { client_platform: 'web', n: 1 },
    ]);
});

// --- /api/chat ----------------------------------------------------------------

function chatEnv() {
    const { env, db } = testEnv();
    return { env: { ...env, REQUIRE_SIGNATURE: 'false', OPENAI_API_KEY: 'test-key' }, db };
}

async function callChat(env, { platform, userId = REAL_USER } = {}) {
    const worker = await loadWorker();
    const headers = {
        'content-type': 'application/json',
        'x-user-id': userId,
        'x-character-id': 'odysseus',
    };
    if (platform !== undefined) headers['x-client-platform'] = platform;
    const pending = [];
    const res = await worker.fetch(new Request('https://mythos.test/api/chat', {
        method: 'POST', headers,
        body: JSON.stringify({ messages: [{ role: 'user', content: 'Tell me of Troy.' }] }),
    }), env, { waitUntil(p) { pending.push(p); }, passThroughOnException() {} });
    await res.text();
    await Promise.all(pending);
    return res.status;
}

function stubOpenAi(t) {
    const original = globalThis.fetch;
    globalThis.fetch = async () => new Response(JSON.stringify({
        choices: [{ message: { role: 'assistant', content: 'Well met, traveller.' } }],
        usage: { prompt_tokens: 5, completion_tokens: 5, total_tokens: 10 },
    }), { status: 200, headers: { 'content-type': 'application/json' } });
    t.after(() => { globalThis.fetch = original; });
}

test('a chat request carries its platform onto the log row', async (t) => {
    stubOpenAi(t);
    const { env, db } = chatEnv();
    assert.equal(await callChat(env, { platform: 'android' }), 200);

    const row = db.prepare(`
        SELECT client_platform, visit_id FROM conversation_logs
        WHERE user_id = ? ORDER BY created_at DESC LIMIT 1
    `).get(REAL_USER);
    assert.equal(row.client_platform, 'android');
    // The pair that makes the row readable: the app sends no visit id because
    // it has no page load, and until now that absence was the only hint about
    // what it was — a hint that cannot tell an app from an old browser build.
    assert.equal(row.visit_id, null);
});

test('a chat request from a client that sends no platform header logs unknown', async (t) => {
    stubOpenAi(t);
    const { env, db } = chatEnv();
    assert.equal(await callChat(env, {}), 200);
    const row = db.prepare(`SELECT client_platform FROM conversation_logs WHERE user_id = ? ORDER BY created_at DESC LIMIT 1`).get(REAL_USER);
    assert.equal(row.client_platform, null);
});

test('a junk platform header is logged as unknown rather than stored', async (t) => {
    stubOpenAi(t);
    const { env, db } = chatEnv();
    assert.equal(await callChat(env, { platform: 'ios; DROP TABLE site_visits' }), 200);
    const row = db.prepare(`SELECT client_platform FROM conversation_logs WHERE user_id = ? ORDER BY created_at DESC LIMIT 1`).get(REAL_USER);
    assert.equal(row.client_platform, null);
});

test('a rejected chat request still records which platform sent it', async (t) => {
    // The failure paths matter more than the happy one here: "which platform
    // is getting refused" is exactly the question the funnel could not answer,
    // and a log row written before the model call has to carry the platform
    // too or the refusals all look like they came from nowhere.
    stubOpenAi(t);
    const { env, db } = chatEnv();
    const worker = await loadWorker();
    const pending = [];
    const res = await worker.fetch(new Request('https://mythos.test/api/chat', {
        method: 'POST',
        headers: {
            'content-type': 'application/json',
            'x-user-id': REAL_USER,
            'x-client-platform': 'ios',
        },
        body: JSON.stringify({ messages: [{ role: 'user', content: 'x'.repeat(2500) }] }),
    }), env, { waitUntil(p) { pending.push(p); }, passThroughOnException() {} });
    await res.text();
    await Promise.all(pending);
    assert.equal(res.status, 400);

    const row = db.prepare(`
        SELECT status, client_platform FROM conversation_logs
        WHERE user_id = ? ORDER BY created_at DESC LIMIT 1
    `).get(REAL_USER);
    assert.equal(row.status, 'rejected_validation');
    assert.equal(row.client_platform, 'ios');
});

// --- /api/delivery ------------------------------------------------------------

async function flush(env, receipts) {
    const worker = await loadWorker();
    const res = await worker.fetch(new Request('https://mythos.test/api/delivery', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ receipts }),
    }), env, { waitUntil() {}, passThroughOnException() {} });
    return { status: res.status, json: JSON.parse(await res.text()) };
}

function deliveryEnv() {
    const db = seed(freshDb());
    return { env: { CHAT_LOGS_DB: d1(db), APP_SECRET: 'test-app-secret', REQUIRE_SIGNATURE: 'false', ADMIN_TOKEN }, db };
}

const receipt = (extra = {}) => ({
    bubbleId: 'b1', turnId: 't1', seq: 0, userId: REAL_USER,
    origin: 'ai_reply', text: 'well met', textLen: 8,
    intendedAt: '2026-11-17T09:00:00.000Z', ...extra,
});

test('delivery receipts carry the platform, so unseen bubbles can be sliced by it', async () => {
    const { env, db } = deliveryEnv();
    const res = await flush(env, [receipt({ clientPlatform: 'ios' })]);
    assert.equal(res.status, 200);
    assert.deepEqual(res.json.acked, ['b1']);
    assert.equal(db.prepare(`SELECT client_platform FROM message_delivery WHERE bubble_id = 'b1'`).get().client_platform, 'ios');
});

test('a second flush of the same bubble does not change the platform, or lose it', async () => {
    // The receipt is retried until acked and the ack can itself be lost, so
    // the same bubble arrives more than once. The platform is a compile-time
    // property of the build, so the second answer should equal the first — but
    // a receipt queued by an older build and flushed after an update is the one
    // case that arrives late, and the row it completes should end up saying so.
    const { env, db } = deliveryEnv();
    await flush(env, [receipt({ clientPlatform: 'ios' })]);
    await flush(env, [receipt({ seenAt: '2026-11-17T09:00:04.000Z' })]);
    const row = db.prepare(`SELECT client_platform, seen_at FROM message_delivery WHERE bubble_id = 'b1'`).get();
    assert.equal(row.client_platform, 'ios', 'a later flush without one must not blank it');
    assert.ok(row.seen_at, 'and the flush still completed the row it came for');

    await flush(env, [receipt({ bubbleId: 'b2', clientPlatform: undefined })]);
    await flush(env, [receipt({ bubbleId: 'b2', clientPlatform: 'android' })]);
    assert.equal(
        db.prepare(`SELECT client_platform FROM message_delivery WHERE bubble_id = 'b2'`).get().client_platform,
        'android', 'a late first answer still lands',
    );
});

test('a junk platform on a receipt is dropped, and the receipt is still stored and acked', async () => {
    // The receipt is evidence about delivery; the platform is context on it.
    // A bad value must cost the context and not the row — dropping the whole
    // receipt would make a client that sends nonsense indistinguishable from
    // one whose bubbles never arrived, which is the ambiguity 0011 exists to
    // remove.
    const { env, db } = deliveryEnv();
    const res = await flush(env, [receipt({ clientPlatform: 'IOS' })]);
    assert.deepEqual(res.json.acked, ['b1']);
    const row = db.prepare(`SELECT client_platform, text FROM message_delivery WHERE bubble_id = 'b1'`).get();
    assert.equal(row.client_platform, null);
    assert.equal(row.text, 'well met');
});

// --- the admin API ------------------------------------------------------------

test('the full export includes linked_accounts, which is why this was unanswerable remotely', async (t) => {
    // Not a nicety: exportAllTables covered seven tables and linked_accounts
    // was not one of them, and no /api/admin/ route joined to it — so the
    // platform question could not be asked from outside the worker at all,
    // however good the column was.
    stubNetwork(t);
    const db = seed(freshDb());
    const env = authEnv(db);
    await call(env, '/auth/native', {
        method: 'POST',
        json: { provider: 'google', id_token: await googleToken(), platform: 'ios' },
    });

    const res = await adminFetch(env, '/api/admin/export-all?hours=24');
    assert.equal(res.status, 200);
    const table = res.json.tables.linked_accounts;
    assert.equal(table.count, 1, table.error);
    assert.equal(table.rows[0].client_platform, 'ios');
    assert.equal(table.rows[0].provider, 'google');
});

test('the export never hands out the Apple refresh token', async (t) => {
    // apple_refresh_token revokes an Apple account (0020). This route's output
    // is a JSON file that leaves the building — downloaded, saved, pasted into
    // tools — so a SELECT * here would put a live credential in all of them.
    // The failure mode is silent and permanent, which is why it is asserted
    // rather than trusted to the column list.
    stubNetwork(t);
    const db = seed(freshDb());
    const env = authEnv(db);
    const rawNonce = 'nonce-xyz';
    await call(env, '/auth/native', {
        method: 'POST',
        json: { provider: 'apple', id_token: await appleToken(rawNonce), raw_nonce: rawNonce, authorization_code: 'code-1' },
    });
    assert.equal(
        db.prepare(`SELECT apple_refresh_token FROM linked_accounts WHERE provider_id = 'a-sub-1'`).get().apple_refresh_token,
        'apple-refresh-1', 'the token really is in the table',
    );

    const res = await adminFetch(env, '/api/admin/export-all?hours=24');
    const row = res.json.tables.linked_accounts.rows[0];
    assert.equal(row.apple_client_id, BUNDLE_ID, 'the client id, which says app-or-web, is exported');
    assert.ok(!('apple_refresh_token' in row), 'the token is not');
    assert.ok(!res.text.includes('apple-refresh-1'), 'and appears nowhere else in the dump');
});

test('the export survives linked_accounts predating this migration', async () => {
    // Every other table in the dump is reported as present-but-empty rather
    // than missing when its migration has not run, and this one has to behave
    // the same way: an absent key and an empty table read identically to a
    // consumer, and only one of them means "nothing happened".
    const { env } = testEnv({ skip: ['0023_client_platform.sql'] });
    const res = await adminFetch(env, '/api/admin/export-all?hours=24');
    assert.equal(res.status, 200);
    assert.match(res.json.tables.linked_accounts.error, /client_platform/);
    assert.deepEqual(res.json.tables.linked_accounts.rows, []);
});
