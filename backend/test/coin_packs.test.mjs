// Coin packs: money entering the ledger through RevenueCat.
//
// Named, like coins.test.mjs, after the mistakes: crediting twice when the
// webhook retries, crediting a sandbox purchase onto a real wallet, letting a
// refund become a free gift, letting a guessed device id spend a paid wallet,
// and trusting the client about any of it. The webhook payloads are shaped
// after RevenueCat's documented event fields; the REST answer for reconcile
// is stubbed the same way the chat tests stub OpenAI.

import test from 'node:test';
import assert from 'node:assert/strict';
import { testEnv, loadWorker } from './harness.mjs';

const USER = 'user_1700000000123';
const OTHER = 'user_1700000000999';
const WEBHOOK_AUTH = 'rc-webhook-shared-secret';

function packsEnv(extra = {}) {
    const { env, db } = testEnv();
    return {
        env: {
            ...env,
            REQUIRE_SIGNATURE: 'false',
            COIN_LEDGER: 'true',
            APP_SECRET: 'test-app-secret',
            OPENAI_API_KEY: 'test-key',
            RC_WEBHOOK_AUTH: WEBHOOK_AUTH,
            RC_SECRET_KEY: 'sk_test',
            ...extra,
        },
        db,
    };
}

const ctx = { waitUntil() {}, passThroughOnException() {} };

function rcEvent(overrides = {}) {
    return {
        api_version: '1.0',
        event: {
            id: 'evt-1',
            type: 'NON_RENEWING_PURCHASE',
            app_user_id: USER,
            original_app_user_id: USER,
            aliases: [USER],
            product_id: 'mythos_coins_1000',
            transaction_id: 'tx-1000-a',
            original_transaction_id: 'tx-1000-a',
            store: 'APP_STORE',
            environment: 'PRODUCTION',
            price: 7.99,
            currency: 'USD',
            purchased_at_ms: 1_758_000_000_000,
            event_timestamp_ms: 1_758_000_000_500,
            ...overrides,
        },
    };
}

async function webhook(env, payload, { auth = WEBHOOK_AUTH } = {}) {
    const worker = await loadWorker();
    const headers = { 'content-type': 'application/json' };
    if (auth !== null) headers.Authorization = auth;
    const request = new Request('https://mythos.test/api/rc/webhook', {
        method: 'POST', headers,
        body: typeof payload === 'string' ? payload : JSON.stringify(payload),
    });
    const res = await worker.fetch(request, env, ctx);
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch (_) { /* prose */ }
    return { status: res.status, json };
}

async function wallet(env, { userId = USER, method = 'GET', path = '/api/wallet', claim, body } = {}) {
    const worker = await loadWorker();
    const headers = { 'content-type': 'application/json', 'x-user-id': userId };
    if (claim !== undefined) headers['x-wallet-claim'] = claim;
    const request = new Request('https://mythos.test' + path, {
        method, headers,
        body: method === 'POST' ? JSON.stringify(body ?? { local_date: '2026-09-28', app_version: '2.2.0+90' }) : undefined,
    });
    const res = await worker.fetch(request, env, ctx);
    return { status: res.status, json: JSON.parse(await res.text()) };
}

async function gift(env, { userId = USER, claim, item = 'roses', id = 'gift-abcdef01' } = {}) {
    const worker = await loadWorker();
    const headers = {
        'content-type': 'application/json', 'x-user-id': userId, 'x-character-id': 'odysseus',
    };
    if (claim !== undefined) headers['x-wallet-claim'] = claim;
    const request = new Request('https://mythos.test/api/chat', {
        method: 'POST', headers,
        body: JSON.stringify({ messages: [{ role: 'user', content: 'For you.' }], gift: { id, item } }),
    });
    const pending = [];
    const res = await worker.fetch(request, env, { waitUntil(p) { pending.push(p); }, passThroughOnException() {} });
    const text = await res.text();
    await Promise.all(pending);
    return { status: res.status, json: JSON.parse(text) };
}

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

function openAiOk() {
    return new Response(JSON.stringify({
        choices: [{ message: { role: 'assistant', content: 'You are too kind.' } }],
        usage: { prompt_tokens: 5, completion_tokens: 5, total_tokens: 10 },
    }), { status: 200, headers: { 'content-type': 'application/json' } });
}

const balance = (db, userId) => db.prepare('SELECT balance FROM coin_wallets WHERE user_id = ?').get(userId)?.balance ?? 0;
const walletRow = (db, userId) => db.prepare('SELECT * FROM coin_wallets WHERE user_id = ?').get(userId);
const ledgerRows = (db, where, ...binds) => db.prepare(`SELECT * FROM coin_ledger WHERE ${where}`).all(...binds);
const eventRow = (db, id) => db.prepare('SELECT * FROM rc_events WHERE id = ?').get(id);

// --- webhook auth and shape --------------------------------------------------

test('the webhook refuses without the shared Authorization value, and says so when unconfigured', async () => {
    const { env, db } = packsEnv();
    assert.equal((await webhook(env, rcEvent(), { auth: null })).status, 401);
    assert.equal((await webhook(env, rcEvent(), { auth: 'wrong' })).status, 401);
    assert.equal(balance(db, USER), 0);
    assert.equal(eventRow(db, 'evt-1'), undefined);

    const { env: bare } = packsEnv({ RC_WEBHOOK_AUTH: undefined });
    assert.equal((await webhook(bare, rcEvent())).status, 503);
});

test('the Bearer form of the header is accepted too', async () => {
    const { env, db } = packsEnv();
    const res = await webhook(env, rcEvent(), { auth: `Bearer ${WEBHOOK_AUTH}` });
    assert.equal(res.status, 200);
    assert.equal(balance(db, USER), 1000);
});

test('bad JSON and a payload with no event are 400, not stored', async () => {
    const { env, db } = packsEnv();
    assert.equal((await webhook(env, '{not json')).status, 400);
    assert.equal((await webhook(env, { api_version: '1.0' })).status, 400);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM rc_events').get().n, 0);
});

// --- crediting ---------------------------------------------------------------

test('a production pack purchase credits exactly its coins, once, under the transaction id', async () => {
    const { env, db } = packsEnv();
    const res = await webhook(env, rcEvent());
    assert.equal(res.status, 200);
    assert.deepEqual(res.json, { ok: true, applied: true, note: null });

    assert.equal(balance(db, USER), 1000);
    const rows = ledgerRows(db, 'user_id = ?', USER);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].id, 'purchase:tx-1000-a');
    assert.equal(rows[0].kind, 'purchase');
    assert.equal(rows[0].reason, 'pack');
    assert.equal(rows[0].ref, 'mythos_coins_1000');

    const w = walletRow(db, USER);
    assert.equal(w.lifetime_purchased, 1000);
    // Money is not "earned": the free-economy counters do not move.
    assert.equal(w.lifetime_earned, 0);
    assert.equal(w.lifetime_spent, 0);

    const ev = eventRow(db, 'evt-1');
    assert.equal(ev.applied, 1);
    assert.equal(ev.user_id, USER);
    assert.equal(ev.product_id, 'mythos_coins_1000');
});

test('a retried event (same id) and a duplicate under a new id both leave the balance alone', async () => {
    const { env, db } = packsEnv();
    await webhook(env, rcEvent());
    const retry = await webhook(env, rcEvent());
    assert.deepEqual(retry.json, { ok: true, duplicate: true });

    // RevenueCat re-sends with the same id, but defend against a fresh id
    // for the same store transaction too — the ledger key is the transaction.
    const again = await webhook(env, rcEvent({ id: 'evt-1-bis' }));
    assert.equal(again.status, 200);
    assert.equal(again.json.applied, false);
    assert.equal(again.json.note, 'already credited');
    assert.equal(balance(db, USER), 1000);
    assert.equal(ledgerRows(db, 'user_id = ?', USER).length, 1);
});

test('an event stored but never finalised is applied on the retry rather than dropped as a duplicate', async () => {
    const { env, db } = packsEnv();
    // Simulate the crash between the two writes: the event row exists with
    // applied=0 and no note, and no ledger row was written.
    db.prepare(`INSERT INTO rc_events (id, type, payload_json) VALUES ('evt-1', 'NON_RENEWING_PURCHASE', '{}')`).run();
    const res = await webhook(env, rcEvent());
    assert.equal(res.json.applied, true);
    assert.equal(balance(db, USER), 1000);
    assert.equal(eventRow(db, 'evt-1').applied, 1);
});

test('all three packs credit their catalogue amounts; an unknown product is logged and not applied', async () => {
    const { env, db } = packsEnv();
    await webhook(env, rcEvent({ id: 'e1', product_id: 'mythos_coins_300', transaction_id: 't1' }));
    await webhook(env, rcEvent({ id: 'e2', product_id: 'mythos_coins_1000', transaction_id: 't2' }));
    await webhook(env, rcEvent({ id: 'e3', product_id: 'mythos_coins_3000', transaction_id: 't3' }));
    assert.equal(balance(db, USER), 4300);

    const unknown = await webhook(env, rcEvent({ id: 'e4', product_id: 'premium_monthly', transaction_id: 't4' }));
    assert.equal(unknown.status, 200);
    assert.equal(unknown.json.applied, false);
    assert.match(unknown.json.note, /unknown product/);
    assert.equal(balance(db, USER), 4300);
    assert.equal(eventRow(db, 'e4').applied, 0);
});

test('quantity multiplies the credit when the store sells several at once', async () => {
    const { env, db } = packsEnv();
    await webhook(env, rcEvent({ product_id: 'mythos_coins_300', quantity: 3 }));
    assert.equal(balance(db, USER), 900);
});

test('the wallet id comes from app_user_id or an alias; an event with none of ours is logged unapplied', async () => {
    const { env, db } = packsEnv();
    // The SDK was anonymous when it bought, then logIn merged ours in as an alias.
    const res = await webhook(env, rcEvent({
        app_user_id: '$RCAnonymousID:abc', original_app_user_id: '$RCAnonymousID:abc', aliases: ['$RCAnonymousID:abc', USER],
    }));
    assert.equal(res.json.applied, true);
    assert.equal(balance(db, USER), 1000);

    const nobody = await webhook(env, rcEvent({ id: 'e2', transaction_id: 't2', app_user_id: '$RCAnonymousID:zzz', original_app_user_id: '$RCAnonymousID:zzz', aliases: [] }));
    assert.equal(nobody.status, 200);
    assert.equal(nobody.json.applied, false);
    assert.match(nobody.json.note, /no wallet id/);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM coin_ledger').get().n, 1);
});

test('TEST and other event types are acknowledged, stored, and not applied', async () => {
    const { env, db } = packsEnv();
    for (const type of ['TEST', 'INITIAL_PURCHASE', 'RENEWAL', 'TRANSFER', 'VIRTUAL_CURRENCY_TRANSACTION']) {
        const res = await webhook(env, rcEvent({ id: `e-${type}`, type, transaction_id: `t-${type}` }));
        assert.equal(res.status, 200, type);
        assert.equal(res.json.applied, false, type);
        assert.equal(eventRow(db, `e-${type}`).applied, 0, type);
    }
    assert.equal(balance(db, USER), 0);
});

// --- sandbox ---------------------------------------------------------------

test('a SANDBOX purchase does not credit an ordinary wallet, but does credit a dev-marked or allowlisted one', async () => {
    const { env, db } = packsEnv();
    const plain = await webhook(env, rcEvent({ environment: 'SANDBOX' }));
    assert.equal(plain.status, 200);
    assert.equal(plain.json.applied, false);
    assert.match(plain.json.note, /sandbox/);
    assert.equal(balance(db, USER), 0);

    // Dev-marked: any visit row for this id with is_dev=1 (0015).
    db.prepare(`INSERT INTO site_visits (id, visit_id, event, created_at, app_user_id, is_dev) VALUES ('r-dev', 'v_dev', 'arrive', CURRENT_TIMESTAMP, ?, 1)`).run(USER);
    const dev = await webhook(env, rcEvent({ id: 'e2', transaction_id: 't2', environment: 'SANDBOX' }));
    assert.equal(dev.json.applied, true);
    assert.equal(balance(db, USER), 1000);

    // Allowlisted, no dev visit.
    const { env: envAllow, db: dbAllow } = packsEnv({ COIN_ALLOWLIST: `${OTHER}, synthetic` });
    const allowed = await webhook(envAllow, rcEvent({ app_user_id: OTHER, original_app_user_id: OTHER, aliases: [OTHER], environment: 'SANDBOX' }));
    assert.equal(allowed.json.applied, true);
    assert.equal(balance(dbAllow, OTHER), 1000);

    // The soak switch.
    const { env: envSoak, db: dbSoak } = packsEnv({ RC_SANDBOX_CREDITS: 'true' });
    await webhook(envSoak, rcEvent({ environment: 'SANDBOX' }));
    assert.equal(balance(dbSoak, USER), 1000);
});

// --- refunds -----------------------------------------------------------------

test('a refund reverses the purchase by its recorded delta and may take the balance negative', async () => {
    const { env, db } = packsEnv();
    await webhook(env, rcEvent({ product_id: 'mythos_coins_300' }));
    assert.equal(balance(db, USER), 300);

    // Spend most of it before the refund lands: buy → give → refund.
    db.prepare(`INSERT INTO coin_ledger (id, user_id, delta, kind, reason, ref) VALUES ('gift:g1', ?, -250, 'spend', 'gift', 'odysseus')`).run(USER);
    assert.equal(balance(db, USER), 50);

    const refund = await webhook(env, rcEvent({ id: 'evt-refund', type: 'CANCELLATION', cancel_reason: 'CUSTOMER_SUPPORT' }));
    assert.equal(refund.status, 200);
    assert.equal(refund.json.applied, true);
    assert.equal(balance(db, USER), -250);

    const rows = ledgerRows(db, "id = 'refund:tx-1000-a'");
    assert.equal(rows.length, 1);
    assert.equal(rows[0].delta, -300);
    assert.equal(rows[0].kind, 'refund');

    const w = walletRow(db, USER);
    assert.equal(w.lifetime_purchased, 0);
    // The free counters saw only the gift.
    assert.equal(w.lifetime_earned, 0);
    assert.equal(w.lifetime_spent, 250);

    // Twice is still once.
    const again = await webhook(env, rcEvent({ id: 'evt-refund-2', type: 'CANCELLATION' }));
    assert.equal(again.json.applied, false);
    assert.equal(balance(db, USER), -250);
});

test('a refund for something we do not sell is logged, not invented', async () => {
    // (A refund for a pack we DO sell is booked ahead of its purchase — see
    // the unordered-webhook test below.)
    const { env, db } = packsEnv();
    const res = await webhook(env, rcEvent({ type: 'CANCELLATION', transaction_id: 'never-seen', product_id: 'premium_monthly' }));
    assert.equal(res.status, 200);
    assert.equal(res.json.applied, false);
    assert.match(res.json.note, /no purchase row/);
    assert.equal(balance(db, USER), 0);
});

test('a negative balance blocks gifts until a new pack clears the debt', async (t) => {
    const { env, db } = packsEnv();
    stubFetch(t, () => openAiOk());
    await webhook(env, rcEvent({ product_id: 'mythos_coins_300' }));
    db.prepare(`INSERT INTO coin_ledger (id, user_id, delta, kind, reason, ref) VALUES ('gift:g1', ?, -300, 'spend', 'gift', 'odysseus')`).run(USER);
    await webhook(env, rcEvent({ id: 'evt-refund', type: 'CANCELLATION' }));
    assert.equal(balance(db, USER), -300);

    const poor = await gift(env, { id: 'gift-poor0001' });
    assert.equal(poor.status, 402);

    await webhook(env, rcEvent({ id: 'e-new', transaction_id: 'tx-new', product_id: 'mythos_coins_1000' }));
    assert.equal(balance(db, USER), 700);
    const rich = await gift(env, { id: 'gift-rich0001' });
    assert.equal(rich.status, 200);
    // 700 - 50 roses + 8 reply grant: the gift rides on a chat turn, and a
    // turn that succeeds pays like any other.
    assert.equal(balance(db, USER), 658);
});

// --- free / paid split -------------------------------------------------------

test('the wallet reports the free/paid split with free coins spent first', async () => {
    const { env, db } = packsEnv();
    await wallet(env, { method: 'POST', path: '/api/wallet/sync' }); // +100 free
    await webhook(env, rcEvent({ product_id: 'mythos_coins_300' })); // +300 paid

    let state = (await wallet(env)).json.wallet;
    assert.equal(state.balance, 400);
    assert.equal(state.free_unspent, 100);
    assert.equal(state.paid_unspent, 300);
    assert.equal(state.lifetime_purchased, 300);
    assert.deepEqual(state.packs, { mythos_coins_300: 300, mythos_coins_1000: 1000, mythos_coins_3000: 3000 });

    // Give 150: the free hundred goes first, then fifty of the paid.
    db.prepare(`INSERT INTO coin_ledger (id, user_id, delta, kind, reason, ref) VALUES ('gift:g1', ?, -150, 'spend', 'gift', 'odysseus')`).run(USER);
    state = (await wallet(env)).json.wallet;
    assert.equal(state.balance, 250);
    assert.equal(state.free_unspent, 0);
    assert.equal(state.paid_unspent, 250);
});

test('a merge carries the paid portion onto the account, and the ledger stays the only write', async () => {
    const { env, db } = packsEnv();
    const worker = await loadWorker();
    await wallet(env, { method: 'POST', path: '/api/wallet/sync' }); // +100 free
    await webhook(env, rcEvent({ product_id: 'mythos_coins_300' }));  // +300 paid
    db.prepare(`INSERT INTO coin_ledger (id, user_id, delta, kind, reason, ref) VALUES ('gift:g1', ?, -150, 'spend', 'gift', 'odysseus')`).run(USER);
    // Anonymous wallet now: 250, all of it paid.

    // Drive the merge exactly as the OAuth callback does.
    const mod = await import(new URL('file://' + new URL('../src/worker.js', import.meta.url).pathname));
    void mod; void worker;
    const account = 'google:sub-1';
    // recordLinkedAccount is internal; reproduce its merge call through the
    // same SQL path by inserting a linked account and invoking the merge via
    // the exported default's fetch is not possible, so call coinMergeWallet
    // through the module's test hook when present, else via the ledger rows
    // it would write. Prefer the real function.
    if (typeof mod.__test?.coinMergeWallet === 'function') {
        await mod.__test.coinMergeWallet(env.CHAT_LOGS_DB, account, USER);
    } else {
        assert.fail('coinMergeWallet is not reachable from tests');
    }

    assert.equal(balance(db, USER), 0);
    assert.equal(balance(db, account), 250 + 100); // + link bonus
    const acct = walletRow(db, account);
    assert.equal(acct.lifetime_purchased, 250);
    assert.equal(acct.lifetime_earned, 100); // the link bonus only
    const anon = walletRow(db, USER);
    assert.equal(anon.lifetime_purchased, 50); // 300 bought, 250 carried away
    const out = ledgerRows(db, "id = ?", `merge:out:${USER}`)[0];
    assert.equal(JSON.parse(out.meta_json).paid, -250);
});

// --- claim token -------------------------------------------------------------

test('a wallet is claimed only when the client asks, and the token is returned exactly once', async () => {
    const { env, db } = packsEnv();
    const plain = await wallet(env, { method: 'POST', path: '/api/wallet/sync' });
    assert.equal(plain.json.claim_token, undefined);
    assert.equal(walletRow(db, USER).claim_token_hash, null);

    const claimed = await wallet(env, { method: 'POST', path: '/api/wallet/sync', claim: 'new' });
    assert.match(claimed.json.claim_token, /^[0-9a-f]{64}$/);
    assert.ok(walletRow(db, USER).claim_token_hash);
    assert.notEqual(walletRow(db, USER).claim_token_hash, claimed.json.claim_token);

    // Asking again with the token presents it; asking again with "new" is refused.
    const again = await wallet(env, { method: 'POST', path: '/api/wallet/sync', claim: claimed.json.claim_token });
    assert.equal(again.status, 200);
    assert.equal(again.json.claim_token, undefined);
    assert.equal((await wallet(env, { method: 'POST', path: '/api/wallet/sync', claim: 'new' })).status, 403);
});

test('a claimed wallet refuses reads, grants and gifts without its token — and serves them with it', async (t) => {
    const { env, db } = packsEnv();
    stubFetch(t, () => openAiOk());
    const token = (await wallet(env, { method: 'POST', path: '/api/wallet/sync', claim: 'new' })).json.claim_token;
    await webhook(env, rcEvent({ product_id: 'mythos_coins_300' }));
    assert.equal(balance(db, USER), 400);

    // A stranger who guessed the id.
    assert.equal((await wallet(env)).status, 403);
    assert.equal((await wallet(env, { claim: 'not-the-token' })).status, 403);
    assert.equal((await wallet(env, { method: 'POST', path: '/api/wallet/sync' })).status, 403);
    assert.equal((await wallet(env, { method: 'POST', path: '/api/wallet/reconcile' })).status, 403);
    const stolen = await gift(env, { id: 'gift-steal0001' });
    assert.equal(stolen.status, 403);
    assert.equal(balance(db, USER), 400);

    // The device that holds the secret.
    assert.equal((await wallet(env, { claim: token })).status, 200);
    const given = await gift(env, { claim: token, id: 'gift-mine00001' });
    assert.equal(given.status, 200);
    assert.equal(balance(db, USER), 400 - 50 + 8); // roses, plus the turn's reply grant
});

test('an unclaimed wallet and a signed-in id are untouched by the claim rule', async (t) => {
    const { env } = packsEnv();
    stubFetch(t, () => openAiOk());
    await wallet(env, { method: 'POST', path: '/api/wallet/sync' });
    assert.equal((await wallet(env)).status, 200);
    assert.equal((await gift(env, { id: 'gift-free00001' })).status, 200);
    // "new" on a non-anonymous id is simply ignored.
    const acct = await wallet(env, { userId: 'google:sub-9', method: 'POST', path: '/api/wallet/sync', claim: 'new' });
    assert.equal(acct.status, 200);
    assert.equal(acct.json.claim_token, undefined);
});

// --- reconcile ---------------------------------------------------------------

test('reconcile credits what RevenueCat knows and the ledger lacks, once, honouring the sandbox rule', async (t) => {
    const { env, db } = packsEnv();
    const calls = stubFetch(t, (url) => {
        assert.match(url, /api\.revenuecat\.com\/v1\/subscribers\/user_1700000000123$/);
        return new Response(JSON.stringify({
            subscriber: {
                non_subscriptions: {
                    mythos_coins_300: [
                        { id: 'rc-1', store_transaction_id: 'tx-300-a', purchase_date: '2026-09-28T00:00:00Z', store: 'app_store', is_sandbox: false },
                        { id: 'rc-2', store_transaction_id: 'tx-300-sandbox', purchase_date: '2026-09-28T00:00:00Z', store: 'app_store', is_sandbox: true },
                    ],
                    mythos_coins_1000: [
                        { id: 'rc-3', store_transaction_id: 'tx-1000-a', purchase_date: '2026-09-28T00:00:00Z', store: 'app_store', is_sandbox: false },
                    ],
                    premium_monthly: [{ id: 'rc-4', store_transaction_id: 'tx-sub' }],
                },
            },
        }), { status: 200, headers: { 'content-type': 'application/json' } });
    });
    // The 1000 already arrived by webhook; only the 300 is missing.
    await webhook(env, rcEvent());
    assert.equal(balance(db, USER), 1000);

    const res = await wallet(env, { method: 'POST', path: '/api/wallet/reconcile' });
    assert.equal(res.status, 200);
    assert.deepEqual(res.json.credited, ['tx-300-a']);
    assert.equal(res.json.wallet.balance, 1300);
    assert.equal(calls.length, 1);

    const twice = await wallet(env, { method: 'POST', path: '/api/wallet/reconcile' });
    assert.deepEqual(twice.json.credited, []);
    assert.equal(balance(db, USER), 1300);
});

test('reconcile without a secret key, or with RevenueCat down, is a 503 that changes nothing', async (t) => {
    const { env: noKey, db } = packsEnv({ RC_SECRET_KEY: undefined });
    assert.equal((await wallet(noKey, { method: 'POST', path: '/api/wallet/reconcile' })).status, 503);

    const { env } = packsEnv();
    stubFetch(t, () => new Response('nope', { status: 500 }));
    assert.equal((await wallet(env, { method: 'POST', path: '/api/wallet/reconcile' })).status, 503);
    assert.equal(balance(db, USER), 0);
});

// --- review fixes (2026-09-28) ------------------------------------------------

async function mergeTicket(env, { userId = USER, claim } = {}) {
    return wallet(env, { userId, method: 'POST', path: '/api/wallet/merge-ticket', claim, body: {} });
}

test('a claimed wallet does not follow a sign-in without a merge ticket — the coins stay put', async () => {
    const { env, db } = packsEnv();
    const mod = await import(new URL('file://' + new URL('../src/worker.js', import.meta.url).pathname));
    const token = (await wallet(env, { method: 'POST', path: '/api/wallet/sync', claim: 'new' })).json.claim_token;
    await webhook(env, rcEvent({ product_id: 'mythos_coins_1000' }));
    assert.equal(balance(db, USER), 1100);

    // A stranger who guessed the id signs in with a fresh account: no ticket.
    await mod.__test.coinMergeWallet(env.CHAT_LOGS_DB, 'google:stranger', USER, { env, ticket: null });
    assert.equal(balance(db, USER), 1100);
    assert.equal(balance(db, 'google:stranger'), 100); // link bonus only
    assert.equal(ledgerRows(db, "id = ?", `merge:out:${USER}`).length, 0);

    // A forged / expired ticket is the same as none.
    await mod.__test.coinMergeWallet(env.CHAT_LOGS_DB, 'google:forger', USER, { env, ticket: '9999999999.deadbeef' });
    assert.equal(balance(db, USER), 1100);

    // The device that holds the claim asks for a ticket, and the merge goes through.
    const ticketRes = await mergeTicket(env, { claim: token });
    assert.equal(ticketRes.status, 200);
    assert.match(ticketRes.json.ticket, /^\d+\.[0-9a-f]{64}$/);
    await mod.__test.coinMergeWallet(env.CHAT_LOGS_DB, 'google:owner', USER, { env, ticket: ticketRes.json.ticket });
    assert.equal(balance(db, USER), 0);
    assert.equal(balance(db, 'google:owner'), 1100 + 100);
    assert.equal(walletRow(db, 'google:owner').lifetime_purchased, 1000);
});

test('a merge ticket needs the claim, and only an anonymous wallet can have one', async () => {
    const { env } = packsEnv();
    await wallet(env, { method: 'POST', path: '/api/wallet/sync', claim: 'new' });
    assert.equal((await mergeTicket(env)).status, 403);
    assert.equal((await mergeTicket(env, { claim: 'wrong' })).status, 403);
    assert.equal((await mergeTicket(env, { userId: 'google:sub-1' })).status, 400);
});

test('an unclaimed wallet still merges without a ticket (older clients)', async () => {
    const { env, db } = packsEnv();
    const mod = await import(new URL('file://' + new URL('../src/worker.js', import.meta.url).pathname));
    await wallet(env, { method: 'POST', path: '/api/wallet/sync' });
    await mod.__test.coinMergeWallet(env.CHAT_LOGS_DB, 'google:old', USER, { env, ticket: null });
    assert.equal(balance(db, USER), 0);
    assert.equal(balance(db, 'google:old'), 200);
});

test('a refund debt follows the sign-in instead of evaporating', async () => {
    const { env, db } = packsEnv();
    const mod = await import(new URL('file://' + new URL('../src/worker.js', import.meta.url).pathname));
    await webhook(env, rcEvent({ product_id: 'mythos_coins_3000' }));
    db.prepare(`INSERT INTO coin_ledger (id, user_id, delta, kind, reason, ref) VALUES ('gift:g1', ?, -3000, 'spend', 'gift', 'odysseus')`).run(USER);
    await webhook(env, rcEvent({ id: 'evt-refund', type: 'CANCELLATION' }));
    assert.equal(balance(db, USER), -3000);

    await mod.__test.coinMergeWallet(env.CHAT_LOGS_DB, 'google:debtor', USER, { env, ticket: null });
    assert.equal(balance(db, USER), 0);
    assert.equal(balance(db, 'google:debtor'), -3000 + 100);
    assert.equal(walletRow(db, 'google:debtor').lifetime_purchased, -3000);
    assert.equal(walletRow(db, 'google:debtor').lifetime_earned, 100);
});

test('a refund that arrives before its purchase nets the later purchase to zero', async () => {
    const { env, db } = packsEnv();
    const refund = await webhook(env, rcEvent({ id: 'evt-refund', type: 'CANCELLATION', product_id: 'mythos_coins_300' }));
    assert.equal(refund.status, 200);
    assert.equal(refund.json.applied, true);
    assert.equal(refund.json.note, 'refund before purchase');
    assert.equal(balance(db, USER), -300);

    const purchase = await webhook(env, rcEvent({ product_id: 'mythos_coins_300' }));
    assert.equal(purchase.json.applied, true);
    assert.equal(balance(db, USER), 0);
    assert.equal(walletRow(db, USER).lifetime_purchased, 0);

    // And twice is still once, either way round.
    await webhook(env, rcEvent({ id: 'evt-refund-2', type: 'CANCELLATION', product_id: 'mythos_coins_300' }));
    assert.equal(balance(db, USER), 0);
});

test('reconcile never keys a credit on RevenueCat\'s own entry id', async (t) => {
    const { env, db } = packsEnv();
    stubFetch(t, () => new Response(JSON.stringify({
        subscriber: {
            non_subscriptions: {
                mythos_coins_300: [
                    { id: 'cadba0c81b', purchase_date: '2026-09-28T00:00:00Z', store: 'app_store', is_sandbox: false },
                ],
            },
        },
    }), { status: 200, headers: { 'content-type': 'application/json' } }));
    const res = await wallet(env, { method: 'POST', path: '/api/wallet/reconcile' });
    assert.equal(res.status, 200);
    assert.deepEqual(res.json.credited, []);
    assert.equal(balance(db, USER), 0);
});

test('a claim whose token never reached the device can be re-minted once; a used one cannot', async () => {
    const { env, db } = packsEnv();
    const first = (await wallet(env, { method: 'POST', path: '/api/wallet/sync', claim: 'new' })).json.claim_token;
    assert.ok(first);
    assert.equal(walletRow(db, USER).claim_used_at, null);

    // The device never got `first`: it holds nothing, so it asks again.
    const second = (await wallet(env, { method: 'POST', path: '/api/wallet/sync', claim: 'new' })).json.claim_token;
    assert.ok(second);
    assert.notEqual(second, first);
    assert.equal((await wallet(env, { claim: first })).status, 403);
    assert.equal((await wallet(env, { claim: second })).status, 200);
    assert.ok(walletRow(db, USER).claim_used_at);

    // Now that the claim has been used, "new" is a stranger's move.
    const again = await wallet(env, { method: 'POST', path: '/api/wallet/sync', claim: 'new' });
    assert.equal(again.status, 403);
    assert.equal((await wallet(env, { claim: second })).status, 200);
    // A read (not a sync) with "new" is never a re-mint path.
    assert.equal((await wallet(env, { claim: 'new' })).status, 403);
});
