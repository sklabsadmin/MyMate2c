// The platform report and the page that reads it.
//
// The column itself is covered by the tests that came with migration 0023;
// what is pinned down here is the reading of it, where the ways to be wrong
// are different. A per-platform count is only worth having if the page cannot
// quietly turn absence into a number — so the behaviours asserted below are
// mostly about what it refuses to do:
//
//   * Rows nobody can place stay their own row, never folded into a platform
//     and never dropped. Every client built before 0023 reports nothing, so
//     for now they are most of the data.
//   * A filter value the worker does not recognise falls back to "all", rather
//     than filtering on something nothing can match and rendering an empty
//     page that reads as a finding.
//   * Web arrivals are bucketed by user-agent and always labelled "(web)",
//     because a browser on an iPhone is not the iOS app — and the apps write
//     no arrival rows at all.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ADMIN_TOKEN, adminFetch, d1, freshDb, loadWorker, seed } from './harness.mjs';

const REAL_USER = 'user_1700000000000';
const OTHER_USER = 'user_1700000000001';

function envWith({ skip = [] } = {}) {
    const db = seed(freshDb({ skip }));
    return {
        db,
        env: {
            CHAT_LOGS_DB: d1(db),
            APP_SECRET: 'test-app-secret',
            ADMIN_TOKEN,
            REQUIRE_SIGNATURE: 'false',
        },
    };
}

/// A receipt with every required field filled in, so each test names only what
/// it is about. `clientPlatform` is the key the worker reads — see
/// recordDeliveryReceipts.
function receipt(extra = {}) {
    return {
        bubbleId: 'b1',
        turnId: 't1',
        seq: 0,
        userId: REAL_USER,
        chatId: 'Odysseus (King of Ithaca)',
        origin: 'ai_reply',
        text: 'well met',
        textLen: 8,
        intendedAt: '2026-11-18T09:00:00.000Z',
        ...extra,
    };
}

async function flush(env, receipts) {
    const worker = await loadWorker();
    return worker.fetch(new Request('https://example.com/api/delivery', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ receipts }),
    }), env, { waitUntil() {} });
}

const report = async (env, query = 'hours=24') =>
    JSON.parse((await adminFetch(env, `/api/admin/platforms?${query}`)).text);

test('the report separates what it can attribute from what it cannot', async () => {
    const { env } = envWith();
    await flush(env, [receipt({ bubbleId: 'p1', clientPlatform: 'ios' })]);
    await flush(env, [receipt({ bubbleId: 'p2', clientPlatform: 'ios', userId: OTHER_USER })]);
    await flush(env, [receipt({ bubbleId: 'p3', clientPlatform: 'android' })]);
    // Two from clients too old to say.
    await flush(env, [receipt({ bubbleId: 'p4' })]);
    await flush(env, [receipt({ bubbleId: 'p5' })]);

    const d = await report(env);
    const byPlatform = Object.fromEntries(d.receipts.map((r) => [r.platform, r]));
    assert.equal(byPlatform.ios.rows_n, 2);
    assert.equal(byPlatform.ios.users, 2, 'distinct users, not rows');
    assert.equal(byPlatform.android.rows_n, 1);
    assert.equal(byPlatform['(unattributed)'].rows_n, 2,
        'the ones nobody can place keep their own row');

    assert.equal(d.coverage.attributed, 3);
    assert.equal(d.coverage.unattributed, 2);
    assert.equal(d.coverage.pct, 60, '3 of 5 placed');
});

test('coverage is null rather than zero when the window holds nothing', async () => {
    const { env } = envWith();
    // 0% would claim everything in the window is unattributed. Nothing is in
    // the window, which is a different statement and the page says so.
    const d = await report(env, 'hours=24');
    assert.equal(d.coverage.attributed, 0);
    assert.equal(d.coverage.unattributed, 0);
    assert.equal(d.coverage.pct, null);
});

test('the platform filter narrows the report to one client', async () => {
    const { env } = envWith();
    await flush(env, [receipt({ bubbleId: 'f1', clientPlatform: 'ios' })]);
    await flush(env, [receipt({ bubbleId: 'f2', clientPlatform: 'android' })]);

    const d = await report(env, 'hours=24&platform=ios');
    assert.equal(d.platform, 'ios');
    assert.deepEqual(d.receipts.map((r) => r.platform), ['ios']);

    // Web arrivals are deliberately not filtered: those rows are written by a
    // browser beacon the apps never run, so they can never carry a platform
    // and narrowing them to one would silently empty the table.
    assert.ok(d.webDevices.length > 0, 'web devices ignore the filter');
});

test('a platform the worker does not know is refused as a filter, not passed to SQL', async () => {
    const { env } = envWith();
    await flush(env, [receipt({ bubbleId: 'g1', clientPlatform: 'ios' })]);
    const d = await report(env, 'hours=24&platform=nintendo');
    assert.equal(d.platform, null, 'falls back to all platforms');
    assert.ok(d.receipts.length > 0, 'rather than rendering an empty page');
});

test('the window is one of the three offered, and anything else is 24 hours', async () => {
    const { env } = envWith();
    for (const [query, expected] of [['24', 24], ['48', 48], ['168', 168], ['3', 24], ['abc', 24]]) {
        const d = await report(env, `hours=${query}`);
        assert.equal(d.hours, expected, `hours=${query}`);
    }
});

test('the report says which migration is missing rather than failing', async () => {
    const { env } = envWith({ skip: ['0023_client_platform.sql'] });
    const res = await adminFetch(env, '/api/admin/platforms?hours=24');
    assert.equal(res.status, 503);
    assert.match(JSON.parse(res.text).error, /0023/,
        'names the migration to apply, the way the delivery report does');
});

test('app version is reported beside the platform, not merged into it', async () => {
    const { env } = envWith();
    // The overlap this table exists to show: one version string, two clients.
    await flush(env, [receipt({ bubbleId: 'v1', clientPlatform: 'ios', appVersion: '1.0.7+103' })]);
    await flush(env, [receipt({ bubbleId: 'v2', clientPlatform: 'web', appVersion: '1.0.7+103' })]);

    const rows = (await report(env)).versions
        .filter((r) => r.app_version === '1.0.7+103')
        .map((r) => r.platform)
        .sort();
    assert.deepEqual(rows, ['ios', 'web'],
        'one version, two platforms, two rows — never collapsed to a guess');
});

test('web arrivals are bucketed by the device their user agent names', async () => {
    const { env, db } = envWith();
    // Deltas, not totals: the shared fixture already seeds arrivals (iPhone
    // user agents among them), and an absolute count here would be a test of
    // seed() that breaks whenever it gains a row.
    const devices = async () => Object.fromEntries(
        (await report(env)).webDevices.map((r) => [r.device, r.arrivals]));
    const before = await devices();

    const insert = db.prepare(`
        INSERT INTO site_visits (id, visit_id, event, created_at, user_agent, is_dev)
        VALUES (?, ?, 'arrive', datetime('now', '-1 hours'), ?, 0)
    `);
    insert.run('ua1', 'v_ua1', 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Safari');
    insert.run('ua2', 'v_ua2', 'Mozilla/5.0 (Linux; Android 14; Pixel 8) Chrome/131');
    insert.run('ua3', 'v_ua3', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/131');
    insert.run('ua4', 'v_ua4', 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/157');

    const after = await devices();
    const added = (k) => (after[k] || 0) - (before[k] || 0);
    // Labelled "(web)" throughout: a browser page load on an iPhone is a
    // different fact from the iOS app, and the page must never let the two be
    // read as one number.
    assert.equal(added('ios (web)'), 1);
    assert.equal(added('android (web)'), 1);
    assert.equal(added('windows (web)'), 1);
    assert.equal(added('mac (web)'), 1);
});

test('a developer arrival is left out of the web device counts', async () => {
    const { env, db } = envWith();
    const total = async () => (await report(env)).webDevices
        .reduce((n, r) => n + r.arrivals, 0);
    const before = await total();
    db.prepare(`
        INSERT INTO site_visits (id, visit_id, event, created_at, user_agent, is_dev)
        VALUES ('dev1', 'v_dev1', 'arrive', datetime('now', '-1 hours'), 'Mozilla/5.0 (iPhone)', 1)
    `).run();
    assert.equal(await total(), before, 'is_dev rows do not reach the report');
});
