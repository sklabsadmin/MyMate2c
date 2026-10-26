// Sign in with Google / Apple (native + Apple web) and account deletion.
//
// Real crypto end to end: the test mints its own RSA keys, publishes them as a
// fake JWKS, and signs ID tokens with them, so the worker's verification runs
// exactly as in production. Apple's token/revoke endpoints and RevenueCat are
// stubbed at globalThis.fetch; every call to them is recorded and inspected.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, webcrypto } from 'node:crypto';
import { freshDb, d1, loadWorker } from './harness.mjs';
import { resetJwksCache } from '../src/identity.js';

const { subtle } = webcrypto;
const BUNDLE_ID = 'com.aiboyfriend.mymate';
const SERVICES_ID = 'com.deeploveechoes.chat.signin';
const GOOGLE_WEB = 'web-client.apps.googleusercontent.com';
const GOOGLE_IOS = 'ios-client.apps.googleusercontent.com';

const b64url = (buf) => Buffer.from(buf).toString('base64url');
const enc = (obj) => b64url(Buffer.from(JSON.stringify(obj)));
const sha256Hex = (s) => createHash('sha256').update(s).digest('hex');

async function rsaKey(kid) {
    const pair = await subtle.generateKey(
        { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
        true, ['sign', 'verify'],
    );
    const jwk = await subtle.exportKey('jwk', pair.publicKey);
    return { kid, privateKey: pair.privateKey, jwk: { kty: 'RSA', n: jwk.n, e: jwk.e, kid, alg: 'RS256', use: 'sig' } };
}

async function signJwt(key, payload, header = {}) {
    const h = { alg: 'RS256', kid: key.kid, typ: 'JWT', ...header };
    const input = `${enc(h)}.${enc(payload)}`;
    const sig = await subtle.sign('RSASSA-PKCS1-v1_5', key.privateKey, Buffer.from(input));
    return `${input}.${b64url(sig)}`;
}

const nowS = () => Math.floor(Date.now() / 1000);

let keys;
let appleP8;
let applePub;

test.before(async () => {
    keys = { google: await rsaKey('g1'), apple: await rsaKey('a1') };
    const ec = await subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
    const pkcs8 = Buffer.from(await subtle.exportKey('pkcs8', ec.privateKey)).toString('base64');
    appleP8 = `-----BEGIN PRIVATE KEY-----\n${pkcs8.match(/.{1,64}/g).join('\n')}\n-----END PRIVATE KEY-----`;
    applePub = ec.publicKey;
});

/// Stubs every outbound call the sign-in code makes and records it.
function stubNetwork(t, { appleRefreshToken = 'apple-refresh-1' } = {}) {
    resetJwksCache();
    const calls = [];
    const original = globalThis.fetch;
    globalThis.fetch = async (input, init = {}) => {
        const url = typeof input === 'string' ? input : input.url;
        const body = init.body ? Object.fromEntries(new URLSearchParams(init.body.toString())) : null;
        calls.push({ url, method: init.method || 'GET', body, headers: init.headers || {} });
        if (url === 'https://www.googleapis.com/oauth2/v3/certs') return Response.json({ keys: [keys.google.jwk] });
        if (url === 'https://appleid.apple.com/auth/keys') return Response.json({ keys: [keys.apple.jwk] });
        if (url === 'https://appleid.apple.com/auth/token') {
            return Response.json({ access_token: 'at', refresh_token: appleRefreshToken, id_token: 'x' });
        }
        if (url === 'https://appleid.apple.com/auth/revoke') return new Response('', { status: 200 });
        if (url.startsWith('https://api.revenuecat.com/v1/subscribers/')) return Response.json({});
        throw new Error(`unexpected fetch ${url}`);
    };
    t.after(() => { globalThis.fetch = original; });
    return calls;
}

function makeEnv(db, extra = {}) {
    return {
        CHAT_LOGS_DB: d1(db),
        SESSION_SECRET: 'test-session-secret',
        APP_SECRET: 'test-app-secret',
        REQUIRE_SIGNATURE: 'false',
        COIN_LEDGER: 'true',
        GOOGLE_CLIENT_ID: GOOGLE_WEB,
        GOOGLE_CLIENT_SECRET: 'gsecret',
        GOOGLE_IOS_CLIENT_ID: GOOGLE_IOS,
        APPLE_BUNDLE_ID: BUNDLE_ID,
        APPLE_SERVICES_ID: SERVICES_ID,
        APPLE_TEAM_ID: 'TEAM123456',
        APPLE_KEY_ID: 'KEY1234567',
        APPLE_PRIVATE_KEY: appleP8,
        RC_SECRET_KEY: 'rc-secret',
        APP_ORIGIN: 'https://mythos.test',
        ...extra,
    };
}

async function call(env, pathname, { method = 'GET', json, form, headers = {} } = {}) {
    const worker = await loadWorker();
    const h = { ...headers };
    let body;
    if (json !== undefined) { h['Content-Type'] = 'application/json'; body = JSON.stringify(json); }
    if (form !== undefined) { h['Content-Type'] = 'application/x-www-form-urlencoded'; body = new URLSearchParams(form).toString(); }
    const res = await worker.fetch(new Request('https://mythos.test' + pathname, { method, headers: h, body }), env,
        { waitUntil() {}, passThroughOnException() {} });
    const text = await res.text();
    let data = null;
    try { data = JSON.parse(text); } catch (_) { /* redirect or html */ }
    return { status: res.status, headers: res.headers, data, text };
}

const googleToken = (claims = {}, header = {}) => signJwt(keys.google, {
    iss: 'https://accounts.google.com', aud: GOOGLE_IOS, sub: 'g-sub-1',
    email: 'pat@example.com', email_verified: true, name: 'Pat', picture: 'https://pic/1',
    iat: nowS(), exp: nowS() + 3600, ...claims,
}, header);

const appleToken = (rawNonce, claims = {}) => signJwt(keys.apple, {
    iss: 'https://appleid.apple.com', aud: BUNDLE_ID, sub: 'a-sub-1',
    email: 'x@privaterelay.appleid.com', nonce: sha256Hex(rawNonce),
    iat: nowS(), exp: nowS() + 600, ...claims,
});

const bearer = (token) => ({ Authorization: `Bearer ${token}` });

function seedAnonWallet(db, anonId, coins) {
    db.prepare(`INSERT INTO coin_ledger (id, user_id, delta, kind, reason) VALUES (?, ?, ?, 'grant', 'welcome')`)
        .run(`grant:welcome:${anonId}`, anonId, coins);
}

// --- Google -------------------------------------------------------------------

test('native Google sign-in returns a bearer session that /auth/me accepts', async (t) => {
    stubNetwork(t);
    const env = makeEnv(freshDb());
    const res = await call(env, '/auth/native', { method: 'POST', json: { provider: 'google', id_token: await googleToken() } });
    assert.equal(res.status, 200, res.text);
    assert.ok(res.data.token);
    assert.equal(res.data.user.id, 'google:g-sub-1');
    assert.equal(res.headers.get('set-cookie'), null, 'native sign-in sets no cookie');

    const me = await call(env, '/auth/me', { headers: bearer(res.data.token) });
    assert.equal(me.data.authenticated, true);
    assert.equal(me.data.user.provider, 'google');
    assert.equal(me.data.user.username, 'Pat');
});

test('Google token addressed to the web client id is accepted too', async (t) => {
    stubNetwork(t);
    const env = makeEnv(freshDb());
    const res = await call(env, '/auth/native', { method: 'POST', json: { provider: 'google', id_token: await googleToken({ aud: GOOGLE_WEB }) } });
    assert.equal(res.status, 200);
});

test('forged, foreign, expired and alg-swapped Google tokens are all refused', async (t) => {
    stubNetwork(t);
    const env = makeEnv(freshDb());
    const good = await googleToken();
    const [h, p] = good.split('.');
    const cases = {
        wrongAudience: await googleToken({ aud: 'someone-elses-app.apps.googleusercontent.com' }),
        wrongIssuer: await googleToken({ iss: 'https://evil.example' }),
        expired: await googleToken({ exp: nowS() - 3600, iat: nowS() - 7200 }),
        badSignature: `${h}.${p}.${b64url(Buffer.alloc(256, 7))}`,
        algNone: `${enc({ alg: 'none', kid: 'g1' })}.${p}.`,
        payloadSwapped: `${h}.${enc({ ...JSON.parse(Buffer.from(p, 'base64url')), sub: 'victim' })}.${good.split('.')[2]}`,
    };
    for (const [name, token] of Object.entries(cases)) {
        const res = await call(env, '/auth/native', { method: 'POST', json: { provider: 'google', id_token: token } });
        assert.equal(res.status, 401, `${name} should be refused`);
    }
});

test('a session cookie or bearer that is forged gets nothing', async (t) => {
    stubNetwork(t);
    const env = makeEnv(freshDb());
    const fake = `${enc({ provider: 'google', sub: 'x', exp: nowS() + 99 })}.deadbeef`;
    const me = await call(env, '/auth/me', { headers: bearer(fake) });
    assert.equal(me.data.authenticated, false);
});

// --- Apple (native) -------------------------------------------------------------

test('native Apple sign-in checks the nonce and stores the refresh token for revocation', async (t) => {
    const calls = stubNetwork(t);
    const db = freshDb();
    const env = makeEnv(db);
    const nonce = 'raw-nonce-123';
    const res = await call(env, '/auth/native', {
        method: 'POST',
        json: { provider: 'apple', id_token: await appleToken(nonce), raw_nonce: nonce, authorization_code: 'code-1', given_name: 'Ada', family_name: 'L' },
    });
    assert.equal(res.status, 200, res.text);
    assert.equal(res.data.user.id, 'apple:a-sub-1');
    assert.equal(res.data.user.username, 'Ada L');

    const row = db.prepare(`SELECT * FROM linked_accounts WHERE provider = 'apple'`).get();
    assert.equal(row.user_id, 'apple:a-sub-1');
    assert.equal(row.apple_refresh_token, 'apple-refresh-1');
    assert.equal(row.apple_client_id, BUNDLE_ID);
    assert.equal(row.display_name, 'Ada L');

    // The client secret Apple received is a valid ES256 JWT for our team/key.
    const exchange = calls.find((c) => c.url === 'https://appleid.apple.com/auth/token');
    assert.equal(exchange.body.client_id, BUNDLE_ID);
    assert.equal(exchange.body.code, 'code-1');
    assert.equal(exchange.body.redirect_uri, undefined, 'native exchange sends no redirect_uri');
    const [sh, sp, ss] = exchange.body.client_secret.split('.');
    const header = JSON.parse(Buffer.from(sh, 'base64url'));
    const payload = JSON.parse(Buffer.from(sp, 'base64url'));
    assert.deepEqual([header.alg, header.kid], ['ES256', 'KEY1234567']);
    assert.deepEqual([payload.iss, payload.sub, payload.aud], ['TEAM123456', BUNDLE_ID, 'https://appleid.apple.com']);
    assert.ok(await subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, applePub,
        Buffer.from(ss, 'base64url'), Buffer.from(`${sh}.${sp}`)));

    // A later sign-in (no name — Apple only sends it once) keeps the name.
    const again = await call(env, '/auth/native', {
        method: 'POST', json: { provider: 'apple', id_token: await appleToken('n2'), raw_nonce: 'n2' },
    });
    assert.equal(again.data.user.username, 'Ada L');
});

test('Apple tokens without the right nonce are refused', async (t) => {
    stubNetwork(t);
    const env = makeEnv(freshDb());
    const missing = await call(env, '/auth/native', { method: 'POST', json: { provider: 'apple', id_token: await appleToken('n') } });
    assert.equal(missing.status, 400);
    const wrong = await call(env, '/auth/native', { method: 'POST', json: { provider: 'apple', id_token: await appleToken('n'), raw_nonce: 'other' } });
    assert.equal(wrong.status, 401);
    const otherApp = await call(env, '/auth/native', {
        method: 'POST', json: { provider: 'apple', id_token: await appleToken('n', { aud: 'com.other.app' }), raw_nonce: 'n' },
    });
    assert.equal(otherApp.status, 401);
});

test('Apple sign-in still works without the .p8 key, it just cannot store a refresh token', async (t) => {
    const calls = stubNetwork(t);
    const db = freshDb();
    const env = makeEnv(db, { APPLE_PRIVATE_KEY: undefined });
    const res = await call(env, '/auth/native', {
        method: 'POST', json: { provider: 'apple', id_token: await appleToken('n'), raw_nonce: 'n', authorization_code: 'c' },
    });
    assert.equal(res.status, 200);
    assert.equal(calls.some((c) => c.url.endsWith('/auth/token')), false);
    assert.equal(db.prepare(`SELECT apple_refresh_token FROM linked_accounts`).get().apple_refresh_token, null);
});

// --- Identity flows through the app --------------------------------------------

test('the anonymous wallet follows the person onto the account, and the bearer then owns it', async (t) => {
    stubNetwork(t);
    const db = freshDb();
    const env = makeEnv(db);
    const anon = 'user_1760000000000';
    seedAnonWallet(db, anon, 250);

    const res = await call(env, '/auth/native', {
        method: 'POST', json: { provider: 'apple', id_token: await appleToken('n'), raw_nonce: 'n', anon_id: anon },
    });
    assert.equal(res.status, 200);
    const wallet = db.prepare(`SELECT balance FROM coin_wallets WHERE user_id = 'apple:a-sub-1'`).get();
    assert.ok(wallet.balance >= 250, `merged balance ${wallet.balance}`);

    // The wallet route resolves identity from the bearer, not x-user-id.
    const w = await call(env, '/api/wallet', { headers: { ...bearer(res.data.token), 'x-user-id': anon } });
    assert.equal(w.status, 200, w.text);
    assert.equal(w.data.wallet.balance, wallet.balance);
});

test('a second device merges only with proof it owns its wallet', async (t) => {
    stubNetwork(t);
    const db = freshDb();
    const env = makeEnv(db);
    const worker = await loadWorker();
    const { coinMergeTicket } = (await import('../src/worker.js')).__test;
    assert.ok(worker);

    const phone = 'user_1760000000001';
    const tablet = 'user_1760000000002';
    const stranger = 'user_1760000000003';
    seedAnonWallet(db, phone, 100);
    seedAnonWallet(db, tablet, 40);
    seedAnonWallet(db, stranger, 70);
    const signIn = async (anonId, ticket) => call(env, '/auth/native', {
        method: 'POST',
        json: { provider: 'google', id_token: await googleToken(), anon_id: anonId, ...(ticket ? { anon_ticket: ticket } : {}) },
    });

    await signIn(phone);
    // A later sign-in naming someone else's id, with no ticket: nothing moves.
    await signIn(stranger);
    assert.equal(db.prepare(`SELECT balance FROM coin_wallets WHERE user_id = ?`).get(stranger).balance, 70);
    // The tablet proves ownership: its coins cross.
    await signIn(tablet, await coinMergeTicket(env, tablet));
    assert.equal(db.prepare(`SELECT balance FROM coin_wallets WHERE user_id = ?`).get(tablet).balance, 0);
    const account = db.prepare(`SELECT balance FROM coin_wallets WHERE user_id = 'google:g-sub-1'`).get().balance;
    const linkBonus = db.prepare(`SELECT COALESCE(SUM(delta),0) AS s FROM coin_ledger WHERE id = 'grant:link:google:g-sub-1'`).get().s;
    assert.equal(account, 140 + linkBonus, 'phone + tablet + one link bonus');
});

// --- Apple (web) ----------------------------------------------------------------

test('Apple web flow: start redirects with state + nonce, callback verifies and sets the session', async (t) => {
    const calls = stubNetwork(t);
    const db = freshDb();
    const env = makeEnv(db);
    const start = await call(env, '/auth/apple/start?return_to=' + encodeURIComponent('https://mythos.test/chat/hercules'));
    assert.equal(start.status, 302);
    const loc = new URL(start.headers.get('location'));
    assert.equal(loc.origin + loc.pathname, 'https://appleid.apple.com/auth/authorize');
    assert.equal(loc.searchParams.get('response_mode'), 'form_post');
    assert.equal(loc.searchParams.get('client_id'), SERVICES_ID);
    const stateCookie = start.headers.get('set-cookie').split(';')[0];
    assert.match(start.headers.get('set-cookie'), /SameSite=None; Secure/);

    const nonce = loc.searchParams.get('nonce');
    const idToken = await signJwt(keys.apple, {
        iss: 'https://appleid.apple.com', aud: SERVICES_ID, sub: 'a-sub-web', nonce,
        iat: nowS(), exp: nowS() + 600,
    });
    const cb = await call(env, '/auth/apple/callback', {
        method: 'POST',
        headers: { Cookie: stateCookie },
        form: { state: loc.searchParams.get('state'), code: 'web-code', id_token: idToken, user: JSON.stringify({ name: { firstName: 'Web', lastName: 'User' } }) },
    });
    assert.equal(cb.status, 302);
    assert.equal(cb.headers.get('location'), 'https://mythos.test/chat/hercules');
    const session = cb.headers.getSetCookie().find((c) => c.startsWith('mymate_session='));
    assert.ok(session, 'session cookie set');

    const me = await call(env, '/auth/me', { headers: { Cookie: session.split(';')[0] } });
    assert.equal(me.data.user.id, 'apple:a-sub-web');
    assert.equal(me.data.user.username, 'Web User');

    const exchange = calls.find((c) => c.url.endsWith('/auth/token'));
    assert.equal(exchange.body.client_id, SERVICES_ID);
    assert.equal(exchange.body.redirect_uri, 'https://mythos.test/auth/apple/callback');
});

test('Apple web callback with a wrong state is refused', async (t) => {
    stubNetwork(t);
    const env = makeEnv(freshDb());
    const start = await call(env, '/auth/apple/start');
    const stateCookie = start.headers.get('set-cookie').split(';')[0];
    const cb = await call(env, '/auth/apple/callback', {
        method: 'POST', headers: { Cookie: stateCookie }, form: { state: 'forged', id_token: 'x' },
    });
    assert.equal(cb.status, 302);
    assert.match(cb.headers.get('location'), /apple=failed/);
});

// --- Account deletion ---------------------------------------------------------

test('deleting an account revokes Apple, wipes personal data, keeps pseudonymous money records, kills old sessions', async (t) => {
    const calls = stubNetwork(t);
    const db = freshDb();
    const env = makeEnv(db);
    const anon = 'user_1760000000009';
    seedAnonWallet(db, anon, 30);
    db.prepare(`INSERT INTO conversation_logs (id, user_id, chat_id, model, status, status_code, user_message, request_messages_json)
                VALUES ('c1', ?, 'chat', 'm', 'ok', 200, 'hello', '[]')`).run(anon);

    const signedIn = await call(env, '/auth/native', {
        method: 'POST', json: { provider: 'apple', id_token: await appleToken('n'), raw_nonce: 'n', authorization_code: 'code', anon_id: anon },
    });
    const token = signedIn.data.token;
    const uid = 'apple:a-sub-1';
    assert.equal(db.prepare(`SELECT COUNT(*) AS n FROM conversation_logs WHERE user_id = ?`).get(uid).n, 1, 'history merged first');

    const unauth = await call(env, '/api/account/delete', { method: 'POST' });
    assert.equal(unauth.status, 401);

    const del = await call(env, '/api/account/delete', { method: 'POST', headers: bearer(token) });
    assert.equal(del.status, 200, del.text);
    assert.equal(del.data.apple_revoked, true);

    const revoke = calls.find((c) => c.url === 'https://appleid.apple.com/auth/revoke');
    assert.equal(revoke.body.token, 'apple-refresh-1');
    assert.equal(revoke.body.client_id, BUNDLE_ID);
    assert.ok(calls.some((c) => c.method === 'DELETE' && c.url.endsWith(encodeURIComponent(uid))), 'RevenueCat customer deleted');

    for (const table of ['conversation_logs', 'linked_accounts', 'coin_wallets', 'user_profiles']) {
        assert.equal(db.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE user_id = ?`).get(uid).n, 0, `${table} cleared`);
    }
    assert.equal(db.prepare(`SELECT COUNT(*) AS n FROM coin_ledger WHERE user_id = ?`).get(uid).n, 0);
    assert.ok(db.prepare(`SELECT COUNT(*) AS n FROM coin_ledger WHERE user_id LIKE 'deleted:%'`).get().n > 0, 'ledger kept, pseudonymous');

    const me = await call(env, '/auth/me', { headers: bearer(token) });
    assert.equal(me.data.authenticated, false, 'pre-deletion session no longer works');

    // Coming back later with the same Apple ID is a fresh, working account.
    const back = await call(env, '/auth/native', { method: 'POST', json: { provider: 'apple', id_token: await appleToken('n3'), raw_nonce: 'n3' } });
    const me2 = await call(env, '/auth/me', { headers: bearer(back.data.token) });
    assert.equal(me2.data.authenticated, true);
});
