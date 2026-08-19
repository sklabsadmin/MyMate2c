// The admin read paths, against a database built from the real migrations.
//
// Each test names the mistake it exists to catch. A test whose failure message
// is "expected 25, got 20" tells the next person nothing; the name has to say
// that counting hide rows undercounts, because that is the bug.

import test from 'node:test';
import assert from 'node:assert/strict';
import { adminFetch, testEnv } from './harness.mjs';

const sessionsFor = async (env, visitId) => {
    const res = await adminFetch(env, '/api/admin/sessions?days=30');
    assert.equal(res.status, 200);
    const row = (res.json.sessions || []).find((s) => s.visit_id === visitId);
    assert.ok(row, `no session row for ${visitId}`);
    return row;
};

test('backgrounding count comes from the reported column, not the hide rows', async () => {
    const { env } = testEnv();
    // The client writes at most 20 hide rows and keeps counting past them, so
    // a query that counts rows reports 20 for a visit that flapped 25 times.
    const row = await sessionsFor(env, 'v_flap');
    assert.equal(row.hide_count, 25);
});

test('a visit killed while backgrounded still reports dwell, visible time and hides', async () => {
    const { env } = testEnv();
    // No leave row at all: everything has to come off the hide checkpoints, or
    // this visit disappears from the dwell figures entirely.
    const row = await sessionsFor(env, 'v_killed');
    assert.equal(row.dwell_ms, 30000);
    assert.equal(row.visible_ms, 21000);
    assert.equal(row.hide_count, 3);
    assert.equal(row.exit_mode, null);
});

test('"reported an ending, kind unknown" is distinguishable from "never reported one"', async () => {
    const { env } = testEnv();
    // v_old predates exit_mode but did send a leave; v_killed sent none. Both
    // have exit_mode NULL and they are not the same outcome.
    const old = await sessionsFor(env, 'v_old');
    const killed = await sessionsFor(env, 'v_killed');
    assert.equal(old.exit_mode, null);
    assert.equal(Boolean(old.reported_leave), true);
    assert.equal(Boolean(killed.reported_leave), false);
});

test('slowest reply is the worst wait, and unknown stays unknown', async () => {
    const { env } = testEnv();
    const flap = await sessionsFor(env, 'v_flap');
    // 2.4s and 14.3s in the same session: the average would hide the wait that
    // actually loses people.
    assert.equal(flap.slowest_reply_ms, 14300);
    // A session whose only message predates latency_ms must not read as 0ms.
    const old = await sessionsFor(env, 'v_old');
    assert.equal(old.slowest_reply_ms, null);
    // And a session that never sent anything has nothing to have waited for.
    const quiet = await sessionsFor(env, 'v_quiet');
    assert.equal(quiet.slowest_reply_ms, null);
    assert.equal(quiet.messages, 0);
});

test('countries are counted per visit over the whole window', async () => {
    const { env } = testEnv();
    const res = await adminFetch(env, '/api/admin/sessions?days=30');
    const byCode = Object.fromEntries((res.json.countries || []).map((c) => [c.country, c.visits]));
    // v_flap flapped 20 times and messaged twice; it is still one visit from GB.
    assert.equal(byCode.GB, 1);
    assert.equal(byCode.US, 1);
    assert.equal(byCode.MY, 1);
    // An unplaceable visit is its own bucket, not dropped and not merged.
    assert.equal(byCode[null], 1);
});

test('visit detail carries viewport height, which decides what the strip showed', async () => {
    const { env } = testEnv();
    const res = await adminFetch(env, '/api/admin/visit-detail?visit_id=v_flap');
    assert.equal(res.status, 200);
    // Stored since migration 0008 and dropped on the way out for a fortnight,
    // which silently disabled the whole "2 of 3 prompts" explanation.
    assert.equal(res.json.context.viewport_h, 600);
    assert.equal(res.json.context.viewport_w, 390);
    assert.equal(res.json.hide_count, 25);
    assert.equal(res.json.visible_ms, 61000);
    assert.equal(res.json.exit_mode, 'hidden');
    assert.equal(res.json.nav_type, 'reload');
});

test('reply latency reaches the transcript views it was recorded for', async () => {
    const { env } = testEnv();
    const chat = await adminFetch(env, '/api/admin/visit-chat?visit_id=v_flap');
    assert.deepEqual(chat.json.messages.map((m) => m.latency_ms), [2400, 14300]);

    const transcript = await adminFetch(env,
        '/api/admin/transcript?user_id=user_1700000000000&chat_id=' +
        encodeURIComponent('Calypso (Nymph of Ogygia)'));
    assert.deepEqual(transcript.json.messages.map((m) => m.latency_ms), [2400, 14300]);

    const logs = await adminFetch(env, '/api/admin/logs?limit=10');
    assert.ok(logs.json.logs.some((l) => l.latency_ms === 14300));
});

test('a silent visit reports dwell from its hide checkpoint', async () => {
    const { env } = testEnv();
    const res = await adminFetch(env, '/api/admin/conversations?limit=50');
    const silent = (res.json.conversations || []).find((c) => c.visit_id === 'v_killed');
    assert.ok(silent, 'the silent visit is missing from the conversations list');
    assert.equal(silent.engaged, 0);
    // Leave-only dwell reported nothing here, which is the population the page
    // exists to show.
    assert.equal(silent.dwell_ms, 30000);
});

test('conversations carry the slowest reply of the conversation', async () => {
    const { env } = testEnv();
    const res = await adminFetch(env, '/api/admin/conversations?limit=50');
    const calypso = (res.json.conversations || [])
        .find((c) => c.chat_id === 'Calypso (Nymph of Ogygia)');
    assert.equal(calypso.slowest_reply_ms, 14300);
});

test('the visits page still aggregates with the new columns present', async () => {
    const { env } = testEnv();
    const res = await adminFetch(env, '/api/admin/visits?days=30');
    assert.equal(res.status, 200);
    assert.ok(res.json.bySource.length > 0);
    assert.ok(res.json.recent.length > 0);
    // Four arrivals, each counted once however many events it left behind.
    assert.equal(res.json.recent.length, 4);
});

test('visits aggregates read time on screen, wall clock only as fallback', async () => {
    const { env } = testEnv();
    const res = await adminFetch(env, '/api/admin/visits?days=30');
    const row = res.json.bySource[0];
    // The fixture through visitTimeOnScreenMsSql: v_flap watched 61s of its
    // 120s wall clock, v_killed 21s of 30s, v_old predates visible_ms so its
    // 30s wall clock stands in, v_quiet reported nothing and stays out of
    // the average. (61000 + 21000 + 30000) / 3, not the wall-clock 60000
    // that once read a 5.2s median as 32.7s.
    assert.equal(row.avg_ms, 37333);

    const flap = res.json.recent.find((r) => r.visit_id === 'v_flap');
    assert.equal(flap.duration_ms, 61000);
    const old = res.json.recent.find((r) => r.visit_id === 'v_old');
    assert.equal(old.duration_ms, 30000);
    // Neither figure exists: unknown, never zero.
    const quiet = res.json.recent.find((r) => r.visit_id === 'v_quiet');
    assert.equal(quiet.duration_ms, null);
});
