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

import test from 'node:test';
import assert from 'node:assert/strict';
import { testEnv, loadWorker, adminFetch } from './harness.mjs';

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

async function callChat(env, { gift, userId = USER, message = 'Tell me of Troy.' } = {}) {
    const worker = await loadWorker();
    const body = { messages: [{ role: 'user', content: message }], ...(gift ? { gift } : {}) };
    const request = new Request('https://mythos.test/api/chat', {
        method: 'POST',
        headers: {
            'content-type': 'application/json',
            'x-user-id': userId,
            'x-character-id': 'odysseus',
            'x-visit-id': 'v_test',
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

async function callSync(env, { userId = USER, localDate } = {}) {
    const worker = await loadWorker();
    const request = new Request('https://mythos.test/api/wallet/sync', {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-user-id': userId },
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
    assert.equal(first.json.wallet.balance, 40);

    const second = await callSync(env, { localDate: '2026-08-20' });
    assert.deepEqual(second.json.granted, []);
    assert.equal(second.json.wallet.balance, 40);
    assert.equal(cachedBalance(db, USER), 40);
});

test('a dawn offering cannot be claimed twice by moving the clock', async () => {
    const { env, db } = coinsEnv();
    await callSync(env, { localDate: '2026-08-20' });

    // "It's tomorrow already" from a device whose calendar rolled over (or
    // lied): the per-date key is new, but the server's own 20-hour spacing
    // has not elapsed, so nothing is granted.
    const tomorrow = await callSync(env, { localDate: '2026-08-21' });
    assert.deepEqual(tomorrow.json.granted, []);
    assert.equal(cachedBalance(db, USER), 40);
    assert.equal(rowCount(db, "reason = 'daily'"), 1);
});

test('a retried offering charges once, and the second answer is still 200', async (t) => {
    const { env, db } = coinsEnv();
    stubFetch(t, openAiOk);
    await callSync(env, { localDate: '2026-08-20' }); // balance 40

    const gift = { id: 'gift_retry_00001', size: 'medium' };
    const first = await callChat(env, { gift });
    assert.equal(first.status, 200);
    assert.equal(first.json.wallet.balance, 26); // 40 - 15 + 1 reply grant

    // The client never saw the first answer and replays the same turn with
    // the same gift id. The reply is generated again (it is a new request),
    // but the tribute is only ever paid for once.
    const second = await callChat(env, { gift });
    assert.equal(second.status, 200);
    assert.equal(rowCount(db, "kind = 'spend'"), 1);
    assert.equal(second.json.wallet.balance, 27); // one more reply grant, no second charge
    assert.equal(cachedBalance(db, USER), ledgerSum(db, USER));
});

test('an offering the balance cannot cover never reaches the model', async (t) => {
    const { env, db } = coinsEnv();
    const upstreamCalls = stubFetch(t, openAiOk);
    await callSync(env, { localDate: '2026-08-20' }); // balance 40 < 50

    const res = await callChat(env, { gift: { id: 'gift_poor_00001', size: 'large' } });
    assert.equal(res.status, 402);
    assert.equal(res.json.wallet.balance, 40);
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
    assert.equal(cachedBalance(db, USER), 40);
    // The settlement still reports the (unchanged) balance rather than hiding.
    assert.equal(res.json.wallet.balance, 40);
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

    await callSync(env, { localDate: '2026-08-20' }); // anon balance 40

    const worker = await loadWorker();
    const signIn = () => worker.fetch(new Request(
        'https://mythos.test/auth/google/callback?state=st1&code=c1',
        { headers: { Cookie: `mymate_google_state=st1||${USER}` } },
    ), env, { waitUntil() {}, passThroughOnException() {} });

    const res = await signIn();
    assert.equal(res.status, 302);

    const google = 'google:gsub1';
    assert.equal(cachedBalance(db, google), 80); // 40 carried + 40 bonus
    assert.equal(cachedBalance(db, USER), 0);
    // The dawn-offering clock crossed too: the account cannot claim a second
    // morning the anonymous wallet already claimed.
    const clock = db.prepare('SELECT last_daily_on FROM coin_wallets WHERE user_id = ?').get(google);
    assert.equal(clock.last_daily_on, '2026-08-20');

    // A second login the same way must not merge or pay again.
    const again = await signIn();
    assert.equal(again.status, 302);
    assert.equal(cachedBalance(db, google), 80);
    assert.equal(rowCount(db, "reason = 'link' AND kind = 'grant'"), 1);

    // And through it all, the cache is only ever a view of the ledger.
    for (const uid of [USER, google]) {
        assert.equal(cachedBalance(db, uid), ledgerSum(db, uid));
    }
});

test('the admin api names the missing migration instead of a bare 500', async () => {
    const { env } = coinsEnv();
    // The wallet route says it too, for the client's benefit.
    const noTables = testEnv({ skip: ['0014_coin_ledger.sql'] });
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
    assert.equal(ok.json.totals.granted, 40);
    assert.equal(ok.json.totals.spent, 0);
    assert.equal(ok.json.totals.users, 1);
    assert.ok(ok.json.by_day.length >= 1);
});
