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
