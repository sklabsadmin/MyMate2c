// The Mythos Coins ledger.
//
// Every test here is named after the mistake it exists to catch, and most of
// those mistakes are the classic currency bugs: paying twice on a retry,
// charging for a turn that never happened, minting on a failure, trusting a
// client clock. The economy's whole trust story is "one idempotent INSERT per
// movement", so that is what gets pinned down.
//
// Chat tests stub globalThis.fetch, so no OpenAI key or network is involved:
// the worker's upstream call gets the answer the test chooses, and the ledger
// is judged on what it did around that answer.

import { createHmac } from 'node:crypto';
import fs from 'node:fs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { testEnv, loadWorker, adminFetch, freshDb } from './harness.mjs';

const USER = 'user_1700000000123';

function coinsEnv(extra = {}) {
    const { env, db } = testEnv();
    return {
        env: {
            ...env,
            REQUIRE_SIGNATURE: 'false',
            COIN_LEDGER: 'true',
            APP_SECRET: 'test-app-secret',
            OPENAI_API_KEY: 'test-key',
            ...extra,
        },
        db,
    };
}

function openAiOk() {
    return new Response(JSON.stringify({
        choices: [{ message: { role: 'assistant', content: 'Well met, traveller.' } }],
        usage: { prompt_tokens: 5, completion_tokens: 5, total_tokens: 10 },
    }), { status: 200, headers: { 'content-type': 'application/json' } });
}

function openAiDown() {
    return new Response(JSON.stringify({ error: { message: 'upstream on fire' } }),
        { status: 500, headers: { 'content-type': 'application/json' } });
}

/// Replaces globalThis.fetch for one test and counts upstream calls — the
/// count is itself an assertion surface ("never reaches the model").
function stubFetch(t, handler) {
    const original = globalThis.fetch;
    const calls = [];
    globalThis.fetch = async (input, init) => {
        calls.push(String(input));
        return handler(String(input), init);
    };
    t.after(() => { globalThis.fetch = original; });
    return calls;
}

async function callChat(env, { gift, userId = USER, message = 'Tell me of Troy.', metadata, claim } = {}) {
    const worker = await loadWorker();
    const body = {
        messages: [{ role: 'user', content: message }],
        ...(gift ? { gift } : {}),
        ...(metadata ? { metadata } : {}),
    };
    const request = new Request('https://mythos.test/api/chat', {
        method: 'POST',
        headers: {
            'content-type': 'application/json',
            'x-user-id': userId,
            'x-character-id': 'odysseus',
            'x-visit-id': 'v_test',
            ...(claim ? { 'x-wallet-claim': claim } : {}),
        },
        body: JSON.stringify(body),
    });
    const pending = [];
    const res = await worker.fetch(request, env, {
        waitUntil(p) { pending.push(p); },
        passThroughOnException() {},
    });
    const text = await res.text();
    await Promise.all(pending);
    return { status: res.status, json: JSON.parse(text) };
}

async function callGet(env, { userId = USER, claim } = {}) {
    const worker = await loadWorker();
    const request = new Request('https://mythos.test/api/wallet', {
        method: 'GET',
        headers: { 'x-user-id': userId, ...(claim ? { 'x-wallet-claim': claim } : {}) },
    });
    const res = await worker.fetch(request, env, { waitUntil() {}, passThroughOnException() {} });
    return { status: res.status, json: JSON.parse(await res.text()) };
}

async function callSync(env, { userId = USER, localDate, claim } = {}) {
    const worker = await loadWorker();
    const request = new Request('https://mythos.test/api/wallet/sync', {
        method: 'POST',
        headers: {
            'content-type': 'application/json',
            'x-user-id': userId,
            ...(claim ? { 'x-wallet-claim': claim } : {}),
        },
        body: JSON.stringify({ local_date: localDate, app_version: '1.7.2+76' }),
    });
    const res = await worker.fetch(request, env, { waitUntil() {}, passThroughOnException() {} });
    return { status: res.status, json: JSON.parse(await res.text()) };
}

function cachedBalance(db, userId) {
    return db.prepare('SELECT balance FROM coin_wallets WHERE user_id = ?').get(userId)?.balance ?? 0;
}
function ledgerSum(db, userId) {
    return db.prepare('SELECT COALESCE(SUM(delta), 0) AS s FROM coin_ledger WHERE user_id = ?').get(userId).s;
}
function rowCount(db, where, ...binds) {
    return db.prepare(`SELECT COUNT(*) AS n FROM coin_ledger WHERE ${where}`).get(...binds).n;
}

test('a fresh sync grants the welcome and the dawn offering exactly once', async () => {
    const { env, db } = coinsEnv();

    const first = await callSync(env, { localDate: '2026-08-20' });
    assert.equal(first.status, 200);
    assert.deepEqual(
        first.json.granted.map((g) => g.reason).sort(),
        ['daily', 'welcome'],
    );
    // 80 + 20: the arrival pays a round hundred, which is what the claim
    // screen promises on the entry card.
    assert.equal(first.json.wallet.balance, 100);

    const second = await callSync(env, { localDate: '2026-08-20' });
    assert.deepEqual(second.json.granted, []);
    assert.equal(second.json.wallet.balance, 100);
    assert.equal(cachedBalance(db, USER), 100);
});

test('a dawn offering cannot be claimed twice by moving the clock', async () => {
    const { env, db } = coinsEnv();
    await callSync(env, { localDate: '2026-08-20' });

    // "It's tomorrow already" from a device whose calendar rolled over (or
    // lied): the per-date key is new, but the server's own 20-hour spacing
    // has not elapsed, so nothing is granted.
    const tomorrow = await callSync(env, { localDate: '2026-08-21' });
    assert.deepEqual(tomorrow.json.granted, []);
    assert.equal(cachedBalance(db, USER), 100);
    assert.equal(rowCount(db, "reason = 'daily'"), 1);
});

test('every day pays the same flat daily, first day and after', async () => {
    // A flat 20 (decided 2026-08-22). It rides beside the +80 welcome on day
    // one so the first claim is a round 100, and every return pays the same
    // 20. This test exists because the amount used to differ by day, and a
    // regression to that split would be invisible until someone read a week
    // of ledger rows.
    const { env, db } = coinsEnv();
    const first = await callSync(env, { localDate: '2026-08-20' });
    assert.deepEqual(first.json.granted, [
        { reason: 'welcome', delta: 80 },
        { reason: 'daily', delta: 20 },
    ]);

    // Age the clock past the 20-hour guard rather than the calendar: the
    // guard is what a second day actually has to clear.
    db.prepare(
        "UPDATE coin_wallets SET last_daily_at = datetime('now', '-21 hours') WHERE user_id = ?"
    ).run(USER);

    const nextDay = await callSync(env, { localDate: '2026-08-21' });
    assert.deepEqual(nextDay.json.granted, [{ reason: 'daily', delta: 20 }]);
    assert.equal(nextDay.json.wallet.balance, 120);
    assert.equal(cachedBalance(db, USER), ledgerSum(db, USER));
});

test('a retried offering charges once, and the second answer is still 200', async (t) => {
    const { env, db } = coinsEnv();
    stubFetch(t, openAiOk);
    await callSync(env, { localDate: '2026-08-20' }); // balance 100

    const gift = { id: 'gift_retry_00001', item: 'roses' };
    const first = await callChat(env, { gift });
    assert.equal(first.status, 200);
    assert.equal(first.json.wallet.balance, 58); // 100 - 50 roses + 8 reply grant

    // The client never saw the first answer and replays the same turn with
    // the same gift id. The reply is generated again (it is a new request),
    // but the tribute is only ever paid for once.
    const second = await callChat(env, { gift });
    assert.equal(second.status, 200);
    assert.equal(rowCount(db, "kind = 'spend'"), 1);
    assert.equal(second.json.wallet.balance, 66); // one more reply grant, no second charge
    assert.equal(cachedBalance(db, USER), ledgerSum(db, USER));
});

test('an offering the balance cannot cover never reaches the model', async (t) => {
    const { env, db } = coinsEnv();
    const upstreamCalls = stubFetch(t, openAiOk);
    // Deliberately no sync: a wallet that has never been funded is the
    // cheapest way to be certain the balance cannot cover the tribute, and
    // it stays true whatever the grants are repriced to.
    const res = await callChat(env, { gift: { id: 'gift_poor_00001', item: 'roses' } });
    assert.equal(res.status, 402);
    assert.equal(res.json.wallet.balance, 0);
    assert.equal(res.json.wallet.needed, 50);
    assert.equal(upstreamCalls.length, 0);
    assert.equal(rowCount(db, "kind = 'spend'"), 0);
    // The refusal is a logged outcome, not a vanished request.
    const logged = db.prepare(
        "SELECT COUNT(*) AS n FROM conversation_logs WHERE status = 'insufficient_coins'"
    ).get().n;
    assert.equal(logged, 1);
});

test('a reply that failed upstream grants nothing', async (t) => {
    const { env, db } = coinsEnv();
    stubFetch(t, openAiDown);
    await callSync(env, { localDate: '2026-08-20' });

    const res = await callChat(env, {});
    assert.equal(res.status, 500);
    assert.equal(rowCount(db, "reason = 'reply'"), 0);
    assert.equal(cachedBalance(db, USER), 100);
    // The settlement still reports the (unchanged) balance rather than hiding.
    assert.equal(res.json.wallet.balance, 100);
    assert.deepEqual(res.json.wallet.granted, []);
});

test('the twenty-first reply of the day earns nothing, and the balance says so', async (t) => {
    const { env, db } = coinsEnv();
    stubFetch(t, openAiOk);
    const insert = db.prepare(
        "INSERT INTO coin_ledger (id, user_id, delta, kind, reason) VALUES (?, ?, 1, 'grant', 'reply')"
    );
    for (let i = 0; i < 20; i++) insert.run(`grant:reply:pre-${i}`, USER);
    assert.equal(cachedBalance(db, USER), 20);

    const res = await callChat(env, {});
    assert.equal(res.status, 200);
    assert.deepEqual(res.json.wallet.granted, []);
    assert.equal(res.json.wallet.balance, 20);
    assert.equal(rowCount(db, "reason = 'reply'"), 20);
});

test('with the flag off, a gift turn is answered, not refused, and says so', async (t) => {
    const { env, db } = coinsEnv({ COIN_LEDGER: 'false' });
    stubFetch(t, openAiOk);

    const sync = await callSync(env, { localDate: '2026-08-20' });
    assert.equal(sync.status, 200);
    assert.deepEqual(sync.json, { enabled: false });

    const res = await callChat(env, { gift: { id: 'gift_offed_0001', size: 'medium' } });
    assert.equal(res.status, 200);
    assert.equal(res.json.wallet.enabled, false);
    assert.ok(res.json.choices, 'the turn still went through as plain chat');
    assert.equal(rowCount(db, '1=1'), 0);
});

test('an invented user id gets no wallet and writes no rows', async (t) => {
    const { env, db } = coinsEnv();
    stubFetch(t, openAiOk);

    const sync = await callSync(env, { userId: 'hackerman', localDate: '2026-08-20' });
    assert.equal(sync.status, 200);
    assert.equal(sync.json.enabled, true);
    assert.equal(sync.json.wallet, null);

    const chat = await callChat(env, { userId: 'hackerman' });
    assert.equal(chat.status, 200);
    assert.equal(chat.json.wallet, undefined);
    assert.equal(rowCount(db, '1=1'), 0);
});

test('signing in carries the anonymous balance across and pays the bonus once', async (t) => {
    const { env, db } = coinsEnv({
        GOOGLE_CLIENT_ID: 'cid',
        GOOGLE_CLIENT_SECRET: 'csecret',
        APP_ORIGIN: 'https://mythos.test',
    });
    stubFetch(t, (url) => {
        if (url.includes('oauth2.googleapis.com/token')) {
            return new Response(JSON.stringify({ access_token: 'tok' }),
                { status: 200, headers: { 'content-type': 'application/json' } });
        }
        if (url.includes('googleapis.com/oauth2/v3/userinfo')) {
            return new Response(JSON.stringify({ sub: 'gsub1', email: 'g@example.com', name: 'G' }),
                { status: 200, headers: { 'content-type': 'application/json' } });
        }
        throw new Error(`unexpected upstream call: ${url}`);
    });

    await callSync(env, { localDate: '2026-08-20' }); // anon balance 100

    const worker = await loadWorker();
    const signIn = () => worker.fetch(new Request(
        'https://mythos.test/auth/google/callback?state=st1&code=c1',
        { headers: { Cookie: `mymate_google_state=st1||${USER}` } },
    ), env, { waitUntil() {}, passThroughOnException() {} });

    const res = await signIn();
    assert.equal(res.status, 302);

    const google = 'google:gsub1';
    assert.equal(cachedBalance(db, google), 200); // 100 carried + 100 bonus
    assert.equal(cachedBalance(db, USER), 0);
    // The dawn-offering clock crossed too: the account cannot claim a second
    // morning the anonymous wallet already claimed.
    const clock = db.prepare('SELECT last_daily_on FROM coin_wallets WHERE user_id = ?').get(google);
    assert.equal(clock.last_daily_on, '2026-08-20');

    // A second login the same way must not merge or pay again.
    const again = await signIn();
    assert.equal(again.status, 302);
    assert.equal(cachedBalance(db, google), 200);
    assert.equal(rowCount(db, "reason = 'link' AND kind = 'grant'"), 1);

    // And through it all, the cache is only ever a view of the ledger.
    for (const uid of [USER, google]) {
        assert.equal(cachedBalance(db, uid), ledgerSum(db, uid));
    }
});

/// A session cookie the worker itself would accept: base64url payload dot
/// hex HMAC, signed with the same APP_SECRET the env carries (SESSION_SECRET
/// falls back to it). Minted here so the profile tests drive the real
/// cookie-auth path instead of an exported internal.
function mintSession(secret, payload) {
    const encoded = Buffer.from(JSON.stringify(payload)).toString('base64url');
    const signature = createHmac('sha256', secret).update(encoded).digest('hex');
    return `${encoded}.${signature}`;
}

test('saving a profile pays once, and a nameless save pays nothing', async () => {
    const { env, db } = coinsEnv();
    const worker = await loadWorker();
    const session = mintSession(env.APP_SECRET, {
        provider: 'google',
        googleId: 'gprof1',
        email: 'p@example.com',
        exp: Math.floor(Date.now() / 1000) + 3600,
    });
    const put = (profile) => worker.fetch(new Request('https://mythos.test/api/profile', {
        method: 'PUT',
        headers: {
            'content-type': 'application/json',
            Cookie: `mymate_session=${session}`,
        },
        body: JSON.stringify({ profile }),
    }), env, { waitUntil() {}, passThroughOnException() {} });

    // A form saved with no name is not "telling them about you" yet.
    const nameless = await put({ location: 'Ithaca' });
    assert.equal(nameless.status, 200);
    const namelessBody = JSON.parse(await nameless.text());
    assert.deepEqual(namelessBody.wallet.granted, []);
    assert.equal(rowCount(db, "reason = 'profile'"), 0);

    const first = await put({ name: 'Ada', location: 'Ithaca' });
    const firstBody = JSON.parse(await first.text());
    assert.deepEqual(firstBody.wallet.granted, [{ reason: 'profile', delta: 200 }]);
    assert.equal(firstBody.wallet.balance, 200);

    // Editing the profile later is not a second completion.
    const again = await put({ name: 'Ada B.', location: 'Ogygia' });
    const againBody = JSON.parse(await again.text());
    assert.deepEqual(againBody.wallet.granted, []);
    assert.equal(againBody.wallet.balance, 200);
    assert.equal(rowCount(db, "reason = 'profile'"), 1);
    assert.equal(cachedBalance(db, 'google:gprof1'), ledgerSum(db, 'google:gprof1'));
});

test('the admin api names the missing migration instead of a bare 500', async () => {
    const { env } = coinsEnv();
    // The wallet route says it too, for the client's benefit.
    // 0017 alters the tables 0014 creates, 0021 indexes one of them and 0025
    // hangs a trigger on its ledger, so they have to go too.
    const noTables = testEnv({ skip: [
        '0014_coin_ledger.sql', '0017_coin_packs.sql', '0021_gift_leaderboard_index.sql',
        '0025_coin_keepsakes.sql',
    ] });
    const res = await adminFetch(
        { ...noTables.env },
        '/api/admin/coins',
    );
    assert.equal(res.status, 503);
    assert.match(res.json.hint || '', /0014_coin_ledger/);

    // With the tables present, the report adds up.
    await callSync(env, { localDate: '2026-08-20' });
    const ok = await adminFetch(env, '/api/admin/coins?days=14');
    assert.equal(ok.status, 200);
    assert.equal(ok.json.totals.granted, 100);
    assert.equal(ok.json.totals.spent, 0);
    assert.equal(ok.json.totals.users, 1);
    assert.ok(ok.json.by_day.length >= 1);
});

test('a pendant is given once per character, and the second giving is free', async (t) => {
    // The whole point of the once-only gift: a visitor who taps it again
    // (or whose client retries) must not be charged 500 twice. The guard is
    // the ledger id itself — derived from (user, character), not from the
    // client's random id — so the second insert collapses onto the first.
    const { env, db } = coinsEnv();
    stubFetch(t, openAiOk);
    db.prepare(
        "INSERT INTO coin_ledger (id, user_id, delta, kind, reason) VALUES ('seed', ?, 900, 'adjust', 'admin')"
    ).run(USER);

    const first = await callChat(env, { gift: { id: 'pendant_aaaa0001', item: 'pendant' } });
    assert.equal(first.status, 200);
    assert.equal(first.json.wallet.balance, 408); // 900 - 500 + 8
    assert.equal(first.json.wallet.gift.charged, true);

    // A different client id for the same character — the case a random id
    // would happily charge for a second time.
    const second = await callChat(env, { gift: { id: 'pendant_bbbb0002', item: 'pendant' } });
    assert.equal(second.status, 200);
    assert.equal(second.json.wallet.gift.charged, false,
        'nothing was taken, so the client must not celebrate a spend');
    assert.equal(rowCount(db, "reason = 'gift'"), 1);
    assert.equal(second.json.wallet.balance, 416); // reply grant only
    assert.equal(cachedBalance(db, USER), ledgerSum(db, USER));
});

test('a pendant given to one character is not worn by another', async (t) => {
    const { env, db } = coinsEnv();
    stubFetch(t, openAiOk);
    db.prepare(
        "INSERT INTO coin_ledger (id, user_id, delta, kind, reason) VALUES ('seed', ?, 2000, 'adjust', 'admin')"
    ).run(USER);

    await callChat(env, { gift: { id: 'pendant_odys0001', item: 'pendant' } });
    // callChat always addresses odysseus; hercules must still be unadorned,
    // and must still cost the full 500.
    const worn = (await callSync(env)).json.wallet.pendants;
    assert.deepEqual(worn, ['odysseus']);

    const rows = db.prepare(
        "SELECT id, ref, meta_json FROM coin_ledger WHERE reason = 'gift'"
    ).all();
    assert.equal(rows.length, 1);
    assert.equal(rows[0].ref, 'odysseus');
    assert.equal(JSON.parse(rows[0].meta_json).item, 'pendant');
});

test('the wallet quotes the catalogue, so the client never invents a price', async () => {
    const { env } = coinsEnv();
    const res = await callSync(env, { localDate: '2026-08-21' });
    assert.deepEqual(res.json.wallet.prices.gift,
        { roses: 50, ambrosia: 150, pendant: 500, laurel: 1500 });
    assert.deepEqual(res.json.wallet.pendants, []);
    assert.deepEqual(res.json.wallet.keepsakes, []);
});

test('a laurel is given once per character, and the second giving is free', async (t) => {
    // Same guard as the pendant, at three times the price: a retry or a
    // second tap must not take another 1500.
    const { env, db } = coinsEnv();
    stubFetch(t, openAiOk);
    db.prepare(
        "INSERT INTO coin_ledger (id, user_id, delta, kind, reason) VALUES ('seed', ?, 2000, 'adjust', 'admin')"
    ).run(USER);

    const first = await callChat(env, { gift: { id: 'laurel_aaaa0001', item: 'laurel' } });
    assert.equal(first.status, 200);
    assert.equal(first.json.wallet.balance, 508); // 2000 - 1500 + 8
    assert.equal(first.json.wallet.gift.charged, true);

    const second = await callChat(env, { gift: { id: 'laurel_bbbb0002', item: 'laurel' } });
    assert.equal(second.status, 200);
    assert.equal(second.json.wallet.gift.charged, false);
    assert.equal(rowCount(db, "reason = 'gift'"), 1);
    assert.equal(second.json.wallet.balance, 516); // reply grant only
    assert.equal(cachedBalance(db, USER), ledgerSum(db, USER));
});

test('a laurel the wallet cannot cover is refused with what it needs', async (t) => {
    const { env, db } = coinsEnv();
    stubFetch(t, openAiOk);
    db.prepare(
        "INSERT INTO coin_ledger (id, user_id, delta, kind, reason) VALUES ('seed', ?, 1499, 'adjust', 'admin')"
    ).run(USER);

    const res = await callChat(env, { gift: { id: 'laurel_poor0001', item: 'laurel' } });
    assert.equal(res.status, 402);
    assert.equal(res.json.wallet.needed, 1500);
    assert.equal(rowCount(db, "reason = 'gift'"), 0);
    assert.equal(cachedBalance(db, USER), 1499);
});

test('keepsakes are listed with who holds them and when, and pendants keeps its old shape', async (t) => {
    // The profile's "Gifts From You" reads this list; iOS 1.0.3 only knows
    // `pendants`, which must keep listing pendants and nothing else.
    const { env, db } = coinsEnv();
    stubFetch(t, openAiOk);
    db.prepare(
        "INSERT INTO coin_ledger (id, user_id, delta, kind, reason) VALUES ('seed', ?, 3000, 'adjust', 'admin')"
    ).run(USER);

    await callChat(env, { gift: { id: 'pendant_kp000001', item: 'pendant' } });
    await callChat(env, { gift: { id: 'laurel_kp00000002', item: 'laurel' } });
    await callChat(env, { gift: { id: 'roses_kp0000003', item: 'roses' } });

    const wallet = (await callSync(env)).json.wallet;
    assert.deepEqual(wallet.pendants, ['odysseus']);
    assert.deepEqual(wallet.keepsakes.map((k) => [k.item, k.ref]),
        [['pendant', 'odysseus'], ['laurel', 'odysseus']]);
    for (const k of wallet.keepsakes) assert.ok(k.at, 'each keepsake carries when it was given');
});

test('the character is told about the keepsakes they hold, and only those', async (t) => {
    // The lasting payoff of a keepsake is the note in the prompt. Captured
    // from the upstream request itself, so this fails if the note is built
    // but never sent.
    const { env, db } = coinsEnv();
    const prompts = [];
    stubFetch(t, (url, init) => {
        prompts.push(init && init.body ? String(init.body) : '');
        return openAiOk();
    });
    db.prepare(
        "INSERT INTO coin_ledger (id, user_id, delta, kind, reason) VALUES ('seed', ?, 3000, 'adjust', 'admin')"
    ).run(USER);

    await callChat(env, { message: 'Before any gift.' });
    assert.ok(!prompts.at(-1).includes('KEEPSAKE'), 'no keepsake, no note');

    await callChat(env, { gift: { id: 'laurel_note000001', item: 'laurel' } });
    assert.ok(prompts.at(-1).includes('crowned you with a golden laurel'),
        'the turn that gives the laurel is the first turn it is remembered');
    assert.ok(!prompts.at(-1).includes('wearing a pendant'), 'a laurel is not a pendant');

    await callChat(env, { gift: { id: 'pendant_note0002', item: 'pendant' } });
    const last = prompts.at(-1);
    assert.ok(last.includes('crowned you with a golden laurel') && last.includes('wearing a pendant'),
        'both keepsakes are remembered together');
});

test('a gift the catalogue does not sell is refused, not silently free', async (t) => {
    const { env, db } = coinsEnv();
    const upstreamCalls = stubFetch(t, openAiOk);
    await callSync(env, { localDate: '2026-08-21' });

    const res = await callChat(env, { gift: { id: 'gift_bogus_0001', item: 'chariot' } });
    assert.equal(res.status, 400);
    assert.equal(rowCount(db, "reason = 'gift'"), 0);
    assert.equal(upstreamCalls.length, 0);
});

test('reading the wallet grants nothing and creates no wallet row', async () => {
    // The bug this fixes: the client used to POST /api/wallet/sync at app load,
    // which minted the welcome+daily for every passive arrival. The read-only
    // GET the client now uses at startup must NOT grant, and must not even
    // create a wallet row for someone who has done nothing but load the app.
    const { env, db } = coinsEnv();
    const res = await callGet(env);
    assert.equal(res.status, 200);
    assert.equal(res.json.enabled, true);
    assert.deepEqual(res.json.granted, []);
    assert.equal(res.json.wallet.balance, 0);
    assert.equal(rowCount(db, '1=1'), 0, 'no ledger row for a mere read');
    assert.equal(
        db.prepare('SELECT COUNT(*) AS n FROM coin_wallets').get().n, 0,
        'no wallet row for a mere read',
    );

    // And the granting path still works when the tap does call it.
    const claim = await callSync(env, { localDate: '2026-08-22' });
    assert.deepEqual(claim.json.granted.map((g) => g.reason).sort(), ['daily', 'welcome']);
    assert.equal(claim.json.wallet.balance, 100);
});

test('a missed day resets the streak — three claims are not three in a row', async () => {
    // The streak counts consecutive user-local dates back from the newest
    // daily claim. Its refs ARE the dates (the grant's idempotency key), so
    // the test writes them directly: 20th, 21st, then a gap, then the 23rd.
    // A count would say 3; in a row it is 1.
    const { env, db } = coinsEnv();
    const grant = db.prepare(
        "INSERT INTO coin_ledger (id, user_id, delta, kind, reason, ref) VALUES (?, ?, 20, 'grant', 'daily', ?)"
    );
    grant.run('s1', USER, '2026-08-20');
    grant.run('s2', USER, '2026-08-21');
    grant.run('s3', USER, '2026-08-23');

    const gapped = await callGet(env);
    assert.equal(gapped.json.wallet.streak_days, 1,
        'the gap on the 22nd broke the run; only the 23rd counts');

    // Fill the gap and the whole run connects.
    grant.run('s4', USER, '2026-08-22');
    const filled = await callGet(env);
    assert.equal(filled.json.wallet.streak_days, 4);

    // A brand-new wallet has no streak, not a streak of zero-with-a-line.
    const fresh = await callGet(env, { userId: 'user_1700000000999' });
    assert.equal(fresh.json.wallet.streak_days, 0);
});

test('a custom character, keyed by its chat, remembers its laurel too', async (t) => {
    // Custom characters send no x-character-id, so the gift lands on the chat
    // id. The memory must be looked up the same way, or the laurel is charged
    // for and then forgotten.
    const { env, db } = coinsEnv();
    const prompts = [];
    stubFetch(t, (url, init) => {
        prompts.push(init && init.body ? String(init.body) : '');
        return openAiOk();
    });
    db.prepare(
        "INSERT INTO coin_ledger (id, user_id, delta, kind, reason) VALUES ('seed', ?, 2000, 'adjust', 'admin')"
    ).run(USER);
    const worker = await loadWorker();
    const send = async (gift) => {
        const request = new Request('https://mythos.test/api/chat', {
            method: 'POST',
            headers: {
                'content-type': 'application/json',
                'x-user-id': USER,
                'x-chat-id': 'Lysander (A Poet of Athens)',
                'x-scenario': 'Lysander (A Poet of Athens)',
                'x-visit-id': 'v_test',
            },
            body: JSON.stringify({ messages: [{ role: 'user', content: 'Hello.' }], ...(gift ? { gift } : {}) }),
        });
        const pending = [];
        const res = await worker.fetch(request, env, { waitUntil(p) { pending.push(p); }, passThroughOnException() {} });
        const text = await res.text();
        await Promise.all(pending);
        return { status: res.status, json: JSON.parse(text) };
    };

    const given = await send({ id: 'laurel_custom0001', item: 'laurel' });
    assert.equal(given.status, 200);
    assert.equal(given.json.wallet.gift.charged, true);
    assert.ok(prompts.at(-1).includes('crowned you with a golden laurel'));

    await send(null);
    assert.ok(prompts.at(-1).includes('crowned you with a golden laurel'),
        'the next plain turn still remembers it');
    const wallet = (await callSync(env)).json.wallet;
    assert.deepEqual(wallet.keepsakes.map((k) => [k.item, k.ref]),
        [['laurel', 'Lysander (A Poet of Athens)']]);
});

test('a character on the Inworld engine is handed the gift and remembers the keepsake', async (t) => {
    // Oedipus replies through Inworld, not the persona path every other
    // gift test exercises. The gift is narrated onto the last user message
    // (Inworld keeps only user/assistant turns) and the keepsake note goes
    // into Inworld's own system prompt; both are read off the request
    // Inworld actually receives.
    const { env, db } = coinsEnv({ INWORLD_API_KEY: 'test-inworld-key' });
    const inworldBodies = [];
    stubFetch(t, (url, init) => {
        if (url.includes('inworld.ai')) {
            inworldBodies.push(JSON.parse(String(init.body)));
            return new Response(JSON.stringify({
                choices: [{ message: { role: 'assistant', content: 'You honour me, stranger.' } }],
            }), { status: 200, headers: { 'content-type': 'application/json' } });
        }
        return openAiOk(); // the cleanup pass
    });
    db.prepare(
        "INSERT INTO coin_ledger (id, user_id, delta, kind, reason) VALUES ('seed', ?, 2000, 'adjust', 'admin')"
    ).run(USER);
    const worker = await loadWorker();
    const send = async (gift) => {
        const request = new Request('https://mythos.test/api/chat', {
            method: 'POST',
            headers: {
                'content-type': 'application/json',
                'x-user-id': USER,
                'x-character-id': 'oedipus',
                'x-chat-id': 'Oedipus (King of Thebes)',
                'x-visit-id': 'v_test',
            },
            body: JSON.stringify({ messages: [{ role: 'user', content: 'For you.' }], ...(gift ? { gift } : {}) }),
        });
        const pending = [];
        const res = await worker.fetch(request, env, { waitUntil(p) { pending.push(p); }, passThroughOnException() {} });
        const text = await res.text();
        await Promise.all(pending);
        return { status: res.status, json: JSON.parse(text) };
    };
    const systemOf = (body) => body.messages.find((m) => m.role === 'system').content;
    const lastUserOf = (body) => [...body.messages].reverse().find((m) => m.role === 'user').content;

    const given = await send({ id: 'laurel_inworld01', item: 'laurel' });
    assert.equal(given.status, 200);
    assert.equal(given.json.wallet.gift.charged, true);
    assert.equal(given.json.wallet.balance, 508); // 2000 - 1500 + 8
    const first = inworldBodies.at(-1);
    assert.ok(lastUserOf(first).includes('golden laurel wreath'), 'the gift is narrated to Inworld');
    assert.ok(systemOf(first).includes('crowned you with a golden laurel'), 'the keepsake is remembered at once');

    await send(null);
    assert.ok(systemOf(inworldBodies.at(-1)).includes('crowned you with a golden laurel'),
        'and on the next plain turn');
    assert.ok(!lastUserOf(inworldBodies.at(-1)).includes('golden laurel wreath'),
        'a plain turn is not narrated as another gift');
});

// --- Gift reactions: a thank-you is owed until the visitor has seen it ------

const USER2 = 'user_1700000000456';

function seed(db, userId, coins) {
    db.prepare(
        "INSERT INTO coin_ledger (id, user_id, delta, kind, reason) VALUES (?, ?, ?, 'adjust', 'admin')"
    ).run(`seed:${userId}`, userId, coins);
}

/// Stubs fetch with a script of per-call outcomes ('ok' | 'down'), repeating
/// the last one, and captures every upstream request body.
function scriptedFetch(t, script) {
    const bodies = [];
    let n = 0;
    stubFetch(t, (url, init) => {
        bodies.push(init && init.body ? String(init.body) : '');
        const step = script[Math.min(n++, script.length - 1)];
        return step === 'down' ? openAiDown() : openAiOk();
    });
    return bodies;
}

test('repeatable gift ids are scoped to the user, so two strangers in the same millisecond both pay', async (t) => {
    const { env, db } = coinsEnv();
    stubFetch(t, openAiOk);
    seed(db, USER, 100);
    seed(db, USER2, 100);

    const a = await callChat(env, { gift: { id: 'roses_same0001', item: 'roses' } });
    const b = await callChat(env, { gift: { id: 'roses_same0001', item: 'roses' }, userId: USER2 });
    assert.equal(a.json.wallet.gift.charged, true);
    assert.equal(b.json.wallet.gift.charged, true, 'the second stranger is not riding the first one\'s key');
    assert.equal(rowCount(db, "reason = 'gift'"), 2);
});

test('a gift whose reply failed is thanked for on the next turn, until the client says it was seen', async (t) => {
    const { env, db } = coinsEnv();
    const bodies = scriptedFetch(t, ['down', 'ok', 'ok']);
    seed(db, USER, 200);

    // The giving turn: charged, then the model falls over. The coins stay
    // spent (the gift was given), the client is told so, and nothing is
    // marked as thanked because nothing was said.
    const given = await callChat(env, { gift: { id: 'roses_fail0001', item: 'roses' } });
    assert.equal(given.status, 500);
    assert.equal(cachedBalance(db, USER), 150);
    assert.equal(given.json.wallet.gift.charged, true);
    assert.equal(given.json.wallet.thanked, undefined);

    // The next plain turn carries the thanks, and says which gift it is for.
    const next = await callChat(env, { message: 'Are you there?' });
    assert.equal(next.status, 200);
    assert.ok(bodies.at(-1).includes('OWED THANKS') && bodies.at(-1).includes('bunch of roses'),
        'the character is told to thank them now');
    assert.deepEqual(next.json.wallet.thanked, [`tribute:${USER}:roses_fail0001`]);

    // The client drew those bubbles and says so on its next request: settled.
    const after = await callChat(env, {
        message: 'Good.',
        metadata: { giftAcks: [`tribute:${USER}:roses_fail0001`] },
    });
    assert.ok(!bodies.at(-1).includes('OWED THANKS'), 'acknowledged thanks are not repeated');
    assert.equal(after.json.wallet.thanked, undefined);
});

test('replaying a gift id after a failed reply narrates again for free; once seen, it is plain chat', async (t) => {
    const { env, db } = coinsEnv();
    const bodies = scriptedFetch(t, ['down', 'ok', 'ok', 'ok']);
    seed(db, USER, 200);
    const gift = { id: 'roses_retry0001', item: 'roses' };
    const narrated = (body) => body.includes('The visitor just gave you');

    await callChat(env, { gift }); // charged, reply failed
    const retry = await callChat(env, { gift }); // the client's retry, same id
    assert.equal(retry.status, 200);
    assert.equal(retry.json.wallet.gift.charged, false, 'nothing was taken twice');
    assert.ok(narrated(bodies.at(-1)), 'the thanks still owed, the gift is narrated again');
    assert.deepEqual(retry.json.wallet.thanked, [`tribute:${USER}:roses_retry0001`]);
    assert.equal(rowCount(db, "reason = 'gift'"), 1);

    // Seen and acknowledged; the same id sent a third time buys nothing and
    // says nothing — a free re-narration would be the roses again for 0.
    await callChat(env, { message: 'Thank you.', metadata: { giftAcks: [`tribute:${USER}:roses_retry0001`] } });
    const replay = await callChat(env, { gift });
    assert.equal(replay.status, 200);
    assert.equal(replay.json.wallet.gift.charged, false);
    assert.ok(!narrated(bodies.at(-1)), 'an acknowledged gift is not narrated on replay');
    assert.equal(replay.json.wallet.thanked, undefined);
    assert.equal(cachedBalance(db, USER), ledgerSum(db, USER));
});

test('owed thanks stop after the attempt cap, so a silent client cannot make a character thank forever', async (t) => {
    const { env, db } = coinsEnv();
    const bodies = scriptedFetch(t, ['down', 'down', 'down', 'down', 'ok']);
    seed(db, USER, 200);

    await callChat(env, { gift: { id: 'roses_loop00001', item: 'roses' } }); // attempt 1, failed
    for (let i = 0; i < 3; i++) {
        await callChat(env, { message: `turn ${i}` }); // attempts 2, 3, 4 — all failed
        assert.ok(bodies.at(-1).includes('OWED THANKS'), `still owed on re-try ${i + 1}`);
    }
    await callChat(env, { message: 'last' });
    assert.ok(!bodies.at(-1).includes('OWED THANKS'), 'after the cap the character lets it go');
});

test('a keepsake given to one character is not thanked for by another', async (t) => {
    const { env, db } = coinsEnv();
    const bodies = scriptedFetch(t, ['down', 'ok']);
    seed(db, USER, 2000);

    await callChat(env, { gift: { id: 'laurel_x0000001', item: 'laurel' } }); // to odysseus, failed
    const worker = await loadWorker();
    const request = new Request('https://mythos.test/api/chat', {
        method: 'POST',
        headers: {
            'content-type': 'application/json',
            'x-user-id': USER,
            'x-character-id': 'penelope',
            'x-visit-id': 'v_test',
        },
        body: JSON.stringify({ messages: [{ role: 'user', content: 'Hello.' }] }),
    });
    const pending = [];
    const res = await worker.fetch(request, env, { waitUntil(p) { pending.push(p); }, passThroughOnException() {} });
    await res.text();
    await Promise.all(pending);
    assert.ok(!bodies.at(-1).includes('OWED THANKS'), 'Penelope owes nothing for a laurel given to Odysseus');
});

// --- Keepsakes across a sign-in (0025) ---------------------------------------
//
// A keepsake is paid for once, under whichever id gave it, and from then on
// it is HELD. Holding has to follow the person onto their account the way the
// coins do, and under the same verdict: an allowed merge carries both, a
// refused one carries neither. These drive the real Google callback, so the
// merge ticket travels the way it does in production — in the state cookie.

const LAUREL_NOTE_TEXT = 'crowned you with a golden laurel';
const PENDANT_NOTE_TEXT = 'wearing a pendant';

function googleEnv() {
    return coinsEnv({
        GOOGLE_CLIENT_ID: 'cid',
        GOOGLE_CLIENT_SECRET: 'csecret',
        APP_ORIGIN: 'https://mythos.test',
    });
}

/// Upstream for tests that both sign in and chat. Google answers as whoever
/// the callback's `code` names (code → token → userinfo), so one stub serves
/// any number of accounts; anything else is the model, and its prompts are
/// kept for the keepsake-note assertions.
function stubGoogleAndModel(t) {
    const prompts = [];
    const ok = (body) => new Response(JSON.stringify(body),
        { status: 200, headers: { 'content-type': 'application/json' } });
    stubFetch(t, (url, init) => {
        if (url.includes('oauth2.googleapis.com/token')) {
            return ok({ access_token: `tok-${new URLSearchParams(String(init.body)).get('code')}` });
        }
        if (url.includes('googleapis.com/oauth2/v3/userinfo')) {
            const sub = init.headers.Authorization.replace('Bearer tok-', '');
            return ok({ sub, email: `${sub}@example.com`, name: sub });
        }
        prompts.push(init && init.body ? String(init.body) : '');
        return openAiOk();
    });
    return prompts;
}

/// The real OAuth callback, with the anonymous id and (optionally) a merge
/// ticket in the state cookie exactly where startGoogleAuth leaves them.
async function signInWithGoogle(env, { sub, anonId = USER, ticket = '' }) {
    const worker = await loadWorker();
    const res = await worker.fetch(new Request(
        `https://mythos.test/auth/google/callback?state=st&code=${sub}`,
        { headers: { Cookie: `mymate_google_state=st||${anonId}|${ticket}` } },
    ), env, { waitUntil() {}, passThroughOnException() {} });
    assert.equal(res.status, 302);
    assert.doesNotMatch(res.headers.get('location') || '', /failed/);
    return `google:${sub}`;
}

async function mergeTicketFor(env, claim, { userId = USER } = {}) {
    const worker = await loadWorker();
    const res = await worker.fetch(new Request('https://mythos.test/api/wallet/merge-ticket', {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-user-id': userId, 'x-wallet-claim': claim },
        body: '{}',
    }), env, { waitUntil() {}, passThroughOnException() {} });
    assert.equal(res.status, 200);
    return JSON.parse(await res.text()).ticket;
}

function seedCoins(db, userId, amount) {
    db.prepare(
        "INSERT INTO coin_ledger (id, user_id, delta, kind, reason) VALUES (?, ?, ?, 'adjust', 'admin')"
    ).run(`seed:${userId}`, userId, amount);
}

const heldBy = (wallet) => wallet.keepsakes.map((k) => [k.item, k.ref]);

test('keepsakes given before sign-in are held by the account after it', async (t) => {
    const { env, db } = googleEnv();
    const prompts = stubGoogleAndModel(t);
    seedCoins(db, USER, 2500);
    await callChat(env, { gift: { id: 'pendant_pre00001', item: 'pendant' } });
    await callChat(env, { gift: { id: 'laurel_pre000001', item: 'laurel' } });
    const before = (await callGet(env)).json.wallet;
    assert.deepEqual(heldBy(before), [['pendant', 'odysseus'], ['laurel', 'odysseus']]);

    const account = await signInWithGoogle(env, { sub: 'gkeep1' });

    // What the profile's "Gifts From You", the sheet's held badges and the
    // iOS 1.0.3 pendants list all read.
    const after = (await callGet(env, { userId: account })).json.wallet;
    assert.deepEqual(heldBy(after), heldBy(before));
    assert.deepEqual(after.keepsakes.map((k) => k.at), before.keepsakes.map((k) => k.at),
        'a keepsake keeps the day it was given, not the day of the sign-in');
    assert.deepEqual(after.pendants, ['odysseus']);

    // They moved with the coins: the anonymous id holds nothing now.
    const left = (await callGet(env)).json.wallet;
    assert.deepEqual(left.keepsakes, []);
    assert.deepEqual(left.pendants, []);

    // The character still remembers both, speaking to the account.
    await callChat(env, { userId: account, message: 'It is me, signed in.' });
    assert.ok(prompts.at(-1).includes(LAUREL_NOTE_TEXT) && prompts.at(-1).includes(PENDANT_NOTE_TEXT));

    // And no ledger row was rewritten to get there: the gifts are still paid
    // for under the id that paid, and both caches still equal their ledgers.
    assert.equal(rowCount(db, "reason = 'gift' AND user_id = ?", USER), 2);
    assert.equal(rowCount(db, "reason = 'gift' AND user_id = ?", account), 0);
    for (const uid of [USER, account]) assert.equal(cachedBalance(db, uid), ledgerSum(db, uid));
});

test('a keepsake carried across is not sold to the account a second time', async (t) => {
    // The account's own key for the pendant (gift:pendant:<account>:...) is
    // new, so the ledger alone would happily charge again.
    const { env, db } = googleEnv();
    stubGoogleAndModel(t);
    seedCoins(db, USER, 600);
    await callChat(env, { gift: { id: 'pendant_pre00002', item: 'pendant' } });
    const account = await signInWithGoogle(env, { sub: 'gkeep2' });
    seedCoins(db, account, 1000); // enough that only the holding can stop the charge
    const balanceBefore = cachedBalance(db, account);

    // A client that missed the wallet refresh offers it again.
    const again = await callChat(env, { userId: account, gift: { id: 'pendant_post0002', item: 'pendant' } });
    assert.equal(again.status, 200);
    assert.equal(again.json.wallet.gift.charged, false);
    assert.equal(again.json.wallet.balance, balanceBefore + 8); // the reply grant only
    assert.equal(rowCount(db, "reason = 'gift' AND user_id = ?", account), 0);
    assert.equal(cachedBalance(db, account), ledgerSum(db, account));
});

test('a keepsake crosses even when it took every coin the wallet had', async (t) => {
    // Merge rows are written only for a non-zero balance, and the laurel buyer
    // has often spent the lot on it. The keepsake must not depend on change.
    const { env, db } = googleEnv();
    stubGoogleAndModel(t);
    seedCoins(db, USER, 1500);
    db.prepare(`
        INSERT INTO coin_ledger (id, user_id, delta, kind, reason, ref, meta_json)
        VALUES (?, ?, -1500, 'spend', 'gift', 'odysseus', '{"item":"laurel"}')
    `).run(`gift:laurel:${USER}:odysseus`, USER);
    assert.equal(cachedBalance(db, USER), 0);

    const account = await signInWithGoogle(env, { sub: 'gkeep3' });
    assert.equal(rowCount(db, "kind = 'merge'"), 0, 'no coins to move');
    assert.deepEqual(heldBy((await callGet(env, { userId: account })).json.wallet), [['laurel', 'odysseus']]);
    assert.equal(cachedBalance(db, account), 100); // the link bonus alone
});

test('a refused merge carries no keepsakes: a claimed wallet needs its ticket', async (t) => {
    // The stranger who guessed a device id and signed in with a fresh account
    // gets the link bonus and nothing else — not the coins (the pack tests pin
    // that) and not the laurel. The owner, with a ticket, gets both.
    const { env, db } = googleEnv();
    const prompts = stubGoogleAndModel(t);
    const claim = (await callSync(env, { localDate: '2026-10-01', claim: 'new' })).json.claim_token;
    assert.match(claim, /^[0-9a-f]{64}$/);
    seedCoins(db, USER, 2000);
    const given = await callChat(env, { claim, gift: { id: 'laurel_claim0001', item: 'laurel' } });
    assert.equal(given.json.wallet.gift.charged, true);

    const stranger = await signInWithGoogle(env, { sub: 'gstranger' });
    const strangerWallet = (await callGet(env, { userId: stranger })).json.wallet;
    assert.deepEqual(strangerWallet.keepsakes, []);
    assert.deepEqual(strangerWallet.pendants, []);
    assert.equal(strangerWallet.balance, 100, 'the link bonus, and only that');
    await callChat(env, { userId: stranger, message: 'Remember me?' });
    assert.ok(!prompts.at(-1).includes(LAUREL_NOTE_TEXT), 'the character does not remember a stranger');

    // A forged ticket is no ticket.
    const forger = await signInWithGoogle(env, { sub: 'gforger', ticket: '9999999999.deadbeef' });
    assert.deepEqual((await callGet(env, { userId: forger })).json.wallet.keepsakes, []);

    // Neither attempt moved it: still the anonymous wallet's.
    assert.deepEqual(heldBy((await callGet(env, { claim })).json.wallet), [['laurel', 'odysseus']]);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM coin_keepsakes WHERE moved_to IS NOT NULL').get().n, 0);

    // The device holding the claim asks for a ticket, and the laurel follows.
    const owner = await signInWithGoogle(env, { sub: 'gowner', ticket: await mergeTicketFor(env, claim) });
    assert.deepEqual(heldBy((await callGet(env, { userId: owner })).json.wallet), [['laurel', 'odysseus']]);
    assert.deepEqual((await callGet(env, { claim })).json.wallet.keepsakes, []);
});

test('keepsakes move once: a second account from the same device finds none left', async (t) => {
    const { env, db } = googleEnv();
    stubGoogleAndModel(t);
    seedCoins(db, USER, 600);
    await callChat(env, { gift: { id: 'pendant_once0001', item: 'pendant' } });

    const first = await signInWithGoogle(env, { sub: 'gfirst' });
    const second = await signInWithGoogle(env, { sub: 'gsecond' });
    assert.deepEqual(heldBy((await callGet(env, { userId: first })).json.wallet), [['pendant', 'odysseus']]);
    assert.deepEqual((await callGet(env, { userId: second })).json.wallet.keepsakes, []);

    // One live holding; the original stays as history, saying where it went.
    const rows = db.prepare('SELECT user_id, from_user_id, moved_to FROM coin_keepsakes ORDER BY id').all();
    assert.deepEqual(rows.map((r) => ({ ...r })), [
        { user_id: USER, from_user_id: null, moved_to: first },
        { user_id: first, from_user_id: USER, moved_to: null },
    ]);
});

test('a keepsake that moved away does not stop its old holder holding a new one', async (t) => {
    // Uniqueness covers live holdings only (a partial index, 0025). As a key
    // on (user, item, character), a holder whose carried-in pendant had since
    // moved on would be charged 500 for a new one and the holding dropped.
    const { env, db } = coinsEnv();
    stubFetch(t, openAiOk);
    db.prepare(`
        INSERT INTO coin_keepsakes (user_id, item, ref, given_at, gift_id, from_user_id, moved_to)
        VALUES (?, 'pendant', 'odysseus', '2026-09-01 00:00:00',
                'gift:pendant:user_1700000000555:odysseus', 'user_1700000000555', 'google:elsewhere')
    `).run(USER);
    seedCoins(db, USER, 600);

    const res = await callChat(env, { gift: { id: 'pendant_anew0001', item: 'pendant' } });
    assert.equal(res.json.wallet.gift.charged, true);
    assert.deepEqual(heldBy((await callGet(env)).json.wallet), [['pendant', 'odysseus']]);
});

test('the migration backfills every keepsake already given, and nothing else', () => {
    // 0025 lands on a production ledger that already holds pendants. The
    // backfill applies the trigger's rule to rows written before the table
    // existed — including ids whose user and character contain colons.
    const db = freshDb({ skip: ['0025_coin_keepsakes.sql'] });
    const gift = db.prepare(`
        INSERT INTO coin_ledger (id, user_id, delta, kind, reason, ref, created_at)
        VALUES (?, ?, ?, 'spend', 'gift', ?, ?)
    `);
    gift.run(`gift:pendant:${USER}:odysseus`, USER, -500, 'odysseus', '2026-09-01 10:00:00');
    gift.run('gift:laurel:google:abc:Hermes: Herald of the Gods', 'google:abc', -1500,
        'Hermes: Herald of the Gods', '2026-09-02 10:00:00');
    gift.run('gift:roses_00000001', USER, -50, 'odysseus', '2026-09-03 10:00:00'); // repeatable

    db.exec(fs.readFileSync(new URL('../migrations/0025_coin_keepsakes.sql', import.meta.url), 'utf8'));

    const rows = db.prepare(
        'SELECT user_id, item, ref, given_at, gift_id, from_user_id, moved_to FROM coin_keepsakes ORDER BY id'
    ).all();
    assert.deepEqual(rows.map((r) => ({ ...r })), [
        {
            user_id: USER, item: 'pendant', ref: 'odysseus', given_at: '2026-09-01 10:00:00',
            gift_id: `gift:pendant:${USER}:odysseus`, from_user_id: null, moved_to: null,
        },
        {
            user_id: 'google:abc', item: 'laurel', ref: 'Hermes: Herald of the Gods',
            given_at: '2026-09-02 10:00:00', gift_id: 'gift:laurel:google:abc:Hermes: Herald of the Gods',
            from_user_id: null, moved_to: null,
        },
    ]);
});
