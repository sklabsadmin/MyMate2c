// Gift leaderboards (backend/src/leaderboard.js, GET /api/leaderboard).
//
// The boards are read straight off the coin ledger, so these tests write
// ledger rows the way a gift does and ask what the endpoint says. Each is
// named for the way a leaderboard goes wrong: counting what was not a gift,
// leaking who someone is, showing the global board to someone who has not
// earned it, or ranking a tie unfairly.

import test from 'node:test';
import assert from 'node:assert/strict';
import { testEnv, loadWorker } from './harness.mjs';
import { boardHandle, BOARD_SIZE } from '../src/leaderboard.js';

const user = (n) => `user_17000000${String(n).padStart(5, '0')}`;
const ME = user(1);

function env(extra = {}) {
    const { env, db } = testEnv();
    return {
        env: { ...env, REQUIRE_SIGNATURE: 'false', COIN_LEDGER: 'true', APP_SECRET: 's', SESSION_SECRET: 'board-secret', ...extra },
        db,
    };
}

let seq = 0;
/// One gift, written as the chat path writes it: a debit, reason 'gift',
/// ref = who it was for. `at` orders ties.
function gift(db, userId, characterId, amount, { at, once } = {}) {
    seq += 1;
    const id = once ? `gift:${once}:${userId}:${characterId}` : `tribute:${userId}:${seq}`;
    db.prepare(`
        INSERT INTO coin_ledger (id, user_id, created_at, delta, kind, reason, ref, meta_json)
        VALUES (?, ?, ?, ?, 'spend', 'gift', ?, '{}')
    `).run(id, userId, at || `2026-11-01 10:00:${String(seq % 60).padStart(2, '0')}`, -amount, characterId);
}

async function get(env, character, { userId = ME, headers = {} } = {}) {
    const worker = await loadWorker();
    const res = await worker.fetch(new Request(
        `https://mythos.test/api/leaderboard?character=${encodeURIComponent(character)}`,
        { headers: { ...(userId ? { 'x-user-id': userId } : {}), ...headers } },
    ), env, { waitUntil() {}, passThroughOnException() {} });
    return { status: res.status, json: JSON.parse(await res.text()) };
}

test('a character with no gifts has an empty board, not an error', async () => {
    const { env: e } = env();
    const res = await get(e, 'zeus');
    assert.equal(res.status, 200);
    assert.equal(res.json.enabled, true);
    assert.deepEqual(res.json.character, { id: 'zeus', entries: [], you: null });
    assert.deepEqual(res.json.global, { unlocked: false });
});

test('the board ranks by coins given to THAT character', async () => {
    const { env: e, db } = env();
    gift(db, user(2), 'zeus', 50);
    gift(db, user(2), 'zeus', 150);        // 200 on Zeus
    gift(db, user(3), 'zeus', 500);        // 500 on Zeus
    gift(db, user(3), 'penelope', 1500);   // not Zeus's business
    gift(db, ME, 'zeus', 50);              // 50 on Zeus

    const zeus = (await get(e, 'zeus')).json.character;
    assert.deepEqual(zeus.entries.map((x) => [x.rank, x.spent]), [[1, 500], [2, 200], [3, 50]]);
    assert.deepEqual(zeus.entries.map((x) => !!x.you), [false, false, true]);
    assert.deepEqual(zeus.you, { rank: 3, spent: 50, gifts: 1 });

    const penelope = (await get(e, 'penelope')).json.character;
    assert.deepEqual(penelope.entries.map((x) => x.spent), [1500]);
    assert.equal(penelope.you, null, 'no gift to her, no standing with her');
});

test('only gifts count: grants, purchases and refunds are not giving', async () => {
    const { env: e, db } = env();
    const row = (id, userId, delta, kind, reason, ref) => db.prepare(
        "INSERT INTO coin_ledger (id, user_id, delta, kind, reason, ref) VALUES (?, ?, ?, ?, ?, ?)"
    ).run(id, userId, delta, kind, reason, ref);
    row('w1', user(2), 80, 'grant', 'welcome', null);
    row('r1', user(2), 8, 'grant', 'reply', 'zeus');
    row('p1', user(2), 3000, 'purchase', 'pack', 'mythos_coins_3000');
    row('x1', user(2), -3000, 'refund', 'pack', 'mythos_coins_3000');
    gift(db, user(3), 'zeus', 50);
    assert.deepEqual((await get(e, 'zeus')).json.character.entries.map((x) => x.spent), [50]);
});

test('nobody is named: handles are made up, stable, and not the user id', async () => {
    const { env: e, db } = env();
    gift(db, user(2), 'zeus', 500);
    gift(db, user(3), 'zeus', 150);
    const first = (await get(e, 'zeus')).json;
    const second = (await get(e, 'zeus', { userId: user(9) })).json;
    const names = first.character.entries.map((x) => x.name);

    assert.deepEqual(second.character.entries.map((x) => x.name), names, 'the same handle whoever is looking');
    assert.equal(names[0], await boardHandle(user(2), 'board-secret'));
    for (const name of names) assert.match(name, /^[A-Z][A-Za-z-]+ [A-Z][a-z]+ \d\d$/);
    const body = JSON.stringify(first);
    assert.ok(!body.includes('user_17'), 'no user id anywhere in the response');
    assert.notEqual(await boardHandle(user(2), 'other-secret'), names[0],
        'keyed: a handle cannot be recomputed without the server secret');
});

test('a tie goes to whoever got there first', async () => {
    const { env: e, db } = env();
    gift(db, user(2), 'zeus', 150, { at: '2026-11-02 09:00:00' });
    gift(db, user(3), 'zeus', 150, { at: '2026-11-01 09:00:00' });
    const entries = (await get(e, 'zeus', { userId: user(3) })).json.character.entries;
    assert.deepEqual(entries.map((x) => !!x.you), [true, false], 'matching someone does not bump them');
});

test('below the fold you still learn your own rank', async () => {
    const { env: e, db } = env();
    for (let n = 2; n < 2 + BOARD_SIZE + 3; n++) gift(db, user(n), 'zeus', 1000 + n);
    gift(db, ME, 'zeus', 50);
    const zeus = (await get(e, 'zeus')).json.character;
    assert.equal(zeus.entries.length, BOARD_SIZE);
    assert.ok(zeus.entries.every((x) => !x.you));
    assert.deepEqual(zeus.you, { rank: BOARD_SIZE + 4, spent: 50, gifts: 1 });
});

test('the global board is not shown, or even hinted at, before two gifts', async () => {
    const { env: e, db } = env();
    gift(db, user(2), 'zeus', 500);
    gift(db, user(2), 'hector', 500);
    gift(db, ME, 'zeus', 50);
    assert.deepEqual((await get(e, 'zeus')).json.global, { unlocked: false });
    assert.deepEqual((await get(e, 'zeus', { userId: null })).json.global, { unlocked: false });
});

test('two gifts unlock the global board, which lists only people with two', async () => {
    const { env: e, db } = env();
    gift(db, user(2), 'zeus', 500);
    gift(db, user(2), 'hector', 500);      // 1000 across two gifts
    gift(db, user(3), 'penelope', 1500);   // more coins, but one gift
    gift(db, ME, 'zeus', 50);
    gift(db, ME, 'calypso', 150);          // 200 across two gifts

    const global = (await get(e, 'zeus')).json.global;
    assert.equal(global.unlocked, true);
    assert.deepEqual(global.entries.map((x) => [x.rank, x.spent, !!x.you]), [[1, 1000, false], [2, 200, true]]);
    assert.deepEqual(global.you, { rank: 2, spent: 200, gifts: 2 });
});

test('a keepsake and a repeatable gift both count', async () => {
    const { env: e, db } = env();
    gift(db, ME, 'zeus', 500, { once: 'pendant' });
    gift(db, ME, 'zeus', 50);
    const res = (await get(e, 'zeus')).json;
    assert.deepEqual(res.character.you, { rank: 1, spent: 550, gifts: 2 });
    assert.equal(res.global.unlocked, true);
});

test('developer wallets are left off every board', async () => {
    const { env: e, db } = env();
    gift(db, user(2), 'zeus', 5000);
    gift(db, user(2), 'hector', 5000);
    gift(db, ME, 'zeus', 50);
    gift(db, ME, 'zeus', 50);
    db.prepare("INSERT INTO site_visits (id, visit_id, event, app_user_id, is_dev) VALUES ('sv_dev', 'v_dev', 'arrive', ?, 1)").run(user(2));
    const res = (await get(e, 'zeus')).json;
    assert.deepEqual(res.character.entries.map((x) => x.spent), [100]);
    assert.deepEqual(res.global.entries.map((x) => x.spent), [100]);
});

test('switched off, or with no coin ledger, it says so instead of failing', async () => {
    const off = await get(env({ LEADERBOARDS: 'false' }).env, 'zeus');
    assert.deepEqual([off.status, off.json], [200, { enabled: false }]);
    const noCoins = await get(env({ COIN_LEDGER: 'false' }).env, 'zeus');
    assert.deepEqual([noCoins.status, noCoins.json], [200, { enabled: false }]);
});

test('it is signed like a wallet read, and takes only roster-shaped ids', async () => {
    const { env: e } = env({ REQUIRE_SIGNATURE: 'true' });
    assert.equal((await get(e, 'zeus')).status, 401);
    const open = env().env;
    assert.equal((await get(open, 'Zeus; DROP TABLE')).status, 400);
    assert.equal((await get(open, '')).status, 400);
});

// ---------------------------------------------------------------------------
// Display names: chosen by their owner, shown to strangers.
// ---------------------------------------------------------------------------

import { cleanDisplayName, REPORTS_TO_HIDE } from '../src/leaderboard.js';
import { adminFetch } from './harness.mjs';

async function send(env, method, pathname, body, { userId = ME, headers = {} } = {}) {
    const worker = await loadWorker();
    const res = await worker.fetch(new Request(`https://mythos.test${pathname}`, {
        method,
        headers: { 'content-type': 'application/json', ...(userId ? { 'x-user-id': userId } : {}), ...headers },
        body: JSON.stringify(body),
    }), env, { waitUntil() {}, passThroughOnException() {} });
    return { status: res.status, json: JSON.parse(await res.text()) };
}
const setName = (env, name, opts) => send(env, 'PUT', '/api/leaderboard/name', { name }, opts);
const report = (env, ref, opts) => send(env, 'POST', '/api/leaderboard/report', { ref }, opts);

test('the filter lets names through and stops what should not be on a board', () => {
    const ok = (name) => cleanDisplayName(name);
    for (const name of ['Anna', 'José María', "O'Brien", 'Anne-Marie', '小林', 'Dr Who 2', 'Ελένη']) {
        assert.equal(ok(name).ok, true, name);
    }
    assert.equal(ok('  Anna   Lee ').name, 'Anna Lee', 'tidied, not rejected');
    // Ordinary names that contain a blocked word are not caught by it.
    for (const name of ['Dickson', 'Cockburn', 'Analise', 'Cumberland', 'Hancock', 'Nazia', 'Swank', 'Atwater', 'Jizelle', 'Torpedo']) {
        assert.equal(ok(name).ok, true, name);
    }
    assert.equal(ok('A').reason, 'length');
    assert.equal(ok('x'.repeat(21)).reason, 'length');
    assert.equal(ok('   ').reason, 'length');
    assert.equal(ok(undefined).reason, 'length');
    for (const name of ['anna@mail.com', 'buy.coins.io', 'http://x', '12345', '<b>Anna</b>', 'Anna😀']) {
        assert.equal(ok(name).reason, 'characters', name);
    }
    for (const name of ['You', 'ADMIN', 'Mythos Live', 'F u c k', 'sh1t head', 'Fuuuck', 'Bitch', 'Dick', 'H1tler', 'Nazi', 'N4z1']) {
        assert.equal(ok(name).reason, 'not_allowed', name);
    }
});

test('a chosen name replaces the handle on every board, for everyone', async () => {
    const { env: e, db } = env();
    gift(db, user(2), 'zeus', 500);
    gift(db, user(2), 'hector', 500);
    gift(db, ME, 'zeus', 50);
    gift(db, ME, 'hector', 50);
    const before = (await get(e, 'zeus')).json;
    assert.equal(before.your_name, null);
    assert.ok(!('ref' in before.character.entries[0]), 'a handle carries nothing to report');

    const saved = await setName(e, ' Penelope  of Ithaca', { userId: user(2) });
    assert.deepEqual([saved.status, saved.json], [200, { enabled: true, ok: true, name: 'Penelope of Ithaca' }]);

    const after = (await get(e, 'zeus')).json;
    assert.equal(after.character.entries[0].name, 'Penelope of Ithaca');
    assert.match(after.character.entries[0].ref, /^[0-9a-f]{24}$/);
    assert.equal(after.global.entries[0].name, 'Penelope of Ithaca');
    assert.equal(after.character.entries[1].name, before.character.entries[1].name, 'no name sent, still a handle');
    assert.ok(!JSON.stringify(after).includes('user_17'), 'still no user id anywhere');

    // Your own row says who you are to the server, and is never reportable.
    await setName(e, 'Telemachus');
    const mine = (await get(e, 'zeus')).json;
    assert.equal(mine.your_name, 'Telemachus');
    const row = mine.character.entries.find((x) => x.you);
    assert.equal(row.name, 'Telemachus');
    assert.ok(!('ref' in row));
});

test('a name that fails the filter is refused and nothing is stored', async () => {
    const { env: e, db } = env();
    gift(db, ME, 'zeus', 50);
    const res = await setName(e, 'sh1thead');
    assert.deepEqual([res.status, res.json], [422, { enabled: true, ok: false, reason: 'not_allowed' }]);
    assert.equal((await get(e, 'zeus')).json.your_name, null);
});

test('a profile name typed before all this is never put on a board', async () => {
    // user_profiles.name was entered as "what should they call you?", in
    // private. Only a name sent to the leaderboard endpoint is public.
    const { env: e, db } = env();
    gift(db, ME, 'zeus', 50);
    db.prepare("INSERT INTO user_profiles (user_id, provider, provider_id, name) VALUES (?, 'google', 'g1', 'Private Name')").run(ME);
    const res = (await get(e, 'zeus', { userId: user(9) })).json;
    assert.ok(!JSON.stringify(res).includes('Private Name'));
});

test('enough reports put a name back to its handle; changing it starts clean', async () => {
    const { env: e, db } = env();
    gift(db, user(2), 'zeus', 500);
    await setName(e, 'Borderline', { userId: user(2) });
    const ref = (await get(e, 'zeus')).json.character.entries[0].ref;

    // The same person reporting repeatedly is one report.
    for (let i = 0; i < REPORTS_TO_HIDE + 2; i++) await report(e, ref, { userId: user(10) });
    assert.equal((await get(e, 'zeus')).json.character.entries[0].name, 'Borderline');

    for (let n = 11; n < 10 + REPORTS_TO_HIDE; n++) await report(e, ref, { userId: user(n) });
    const hidden = (await get(e, 'zeus')).json.character.entries[0];
    assert.notEqual(hidden.name, 'Borderline');
    assert.ok(!('ref' in hidden), 'a handle again');
    // Its owner still has it on file, and is not told to choose again.
    assert.equal((await get(e, 'zeus', { userId: user(2) })).json.your_name, 'Borderline');

    // Sending the same name back does not undo the hiding…
    await setName(e, 'Borderline', { userId: user(2) });
    assert.notEqual((await get(e, 'zeus')).json.character.entries[0].name, 'Borderline');
    // …a different one is a different name.
    await setName(e, 'Perfectly Fine', { userId: user(2) });
    assert.equal((await get(e, 'zeus')).json.character.entries[0].name, 'Perfectly Fine');
});

test('a report answers the same for a real ref, a made-up one, and your own', async () => {
    const { env: e, db } = env();
    gift(db, user(2), 'zeus', 500);
    await setName(e, 'Someone', { userId: user(2) });
    const ref = (await get(e, 'zeus')).json.character.entries[0].ref;
    const answers = [
        await report(e, ref),
        await report(e, 'f'.repeat(24)),
        await report(e, 'not a ref'),
        await report(e, ref, { userId: user(2) }),
    ];
    for (const a of answers) assert.deepEqual([a.status, a.json], [200, { enabled: true, ok: true }]);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM leaderboard_name_reports').get().n, 1,
        'only the real report of someone else was recorded');
});

test('the admin api lists reported names and can hide and restore one', async () => {
    const { env: e, db } = env();
    gift(db, user(2), 'zeus', 500);
    await setName(e, 'Reported Once', { userId: user(2) });
    const ref = (await get(e, 'zeus')).json.character.entries[0].ref;
    await report(e, ref);

    const listed = await adminFetch(e, '/api/admin/leaderboard-names');
    assert.equal(listed.status, 200);
    assert.deepEqual(listed.json.names.map((n) => [n.name, n.reports, n.hidden]), [['Reported Once', 1, false]]);
    assert.ok(!JSON.stringify(listed.json).includes('user_17'), 'refs, not ids, even for admins');

    assert.equal((await adminFetch(e, '/api/admin/leaderboard-names', { method: 'POST', body: { ref, hidden: true } })).status, 200);
    assert.notEqual((await get(e, 'zeus')).json.character.entries[0].name, 'Reported Once');
    await adminFetch(e, '/api/admin/leaderboard-names', { method: 'POST', body: { ref, hidden: false } });
    assert.equal((await get(e, 'zeus')).json.character.entries[0].name, 'Reported Once');
    assert.equal((await adminFetch(e, '/api/admin/leaderboard-names', { method: 'POST', body: { ref: 'nope', hidden: true } })).status, 404);
});

test('a name needs a real user, a signature, and the wallet\'s own device', async () => {
    const signed = env({ REQUIRE_SIGNATURE: 'true' }).env;
    assert.equal((await setName(signed, 'Anna')).status, 401);
    const open = env().env;
    assert.equal((await setName(open, 'Anna', { userId: 'someone' })).status, 400);
    assert.deepEqual((await setName(env({ LEADERBOARDS: 'false' }).env, 'Anna')).json, { enabled: false });

    // A claimed anonymous wallet: knowing its id is not enough to rename it.
    const { env: e, db } = env();
    db.prepare("INSERT INTO coin_wallets (user_id, claim_token_hash, claim_used_at) VALUES (?, 'somehash', CURRENT_TIMESTAMP)").run(ME);
    assert.equal((await setName(e, 'Impostor')).status, 403);
});
