// The export paths — CSV of sessions, the whole-database JSON dump, and the
// deploy log. These are the routes whose output leaves the building, so the
// things asserted here are the ones that are invisible once a file is open in
// a spreadsheet: what a blank cell means, and whether anything was silently
// left out.

import test from 'node:test';
import assert from 'node:assert/strict';
import { adminFetch, testEnv } from './harness.mjs';

const parseCsv = (text) => {
    const lines = text.trim().split('\n');
    return { header: lines[0].split(','), rows: lines.slice(1) };
};

test('sessions CSV exports the range, not the rows the page happened to load', async () => {
    const { env } = testEnv();
    const res = await adminFetch(env, '/api/admin/sessions?days=30&format=csv&limit=500');
    assert.equal(res.status, 200);
    assert.match(res.headers.get('Content-Type'), /text\/csv/);
    assert.match(res.headers.get('Content-Disposition'), /attachment; filename="mythos-sessions-/);
    assert.equal(res.headers.get('X-Sessions-Truncated'), '0');
    const { header, rows } = parseCsv(res.text);
    assert.equal(rows.length, 4);
    assert.equal(header[0], 'visit_id');
    // The page's names, not the database's: seen_ms is what the column is
    // called on screen, and an export that disagrees makes every question
    // about it harder to answer.
    assert.ok(header.includes('seen_ms'));
    assert.ok(header.includes('slowest_reply_ms'));
});

test('CSV writes unknowns as empty, never as zero', async () => {
    const { env } = testEnv();
    const res = await adminFetch(env, '/api/admin/sessions?days=30&format=csv');
    const { header, rows } = parseCsv(res.text);
    const seen = header.indexOf('seen_ms');
    const slowest = header.indexOf('slowest_reply_ms');
    const old = rows.find((r) => r.startsWith('v_old,')).split(',');
    // v_old predates visible_ms and latency_ms. A zero here would tell a
    // spreadsheet the visitor watched nothing and waited no time, both false.
    assert.equal(old[seen], '');
    assert.equal(old[slowest], '');
    const flap = rows.find((r) => r.startsWith('v_flap,')).split(',');
    assert.equal(flap[seen], '61000');
    assert.equal(flap[slowest], '14300');
});

test('CSV neutralises spreadsheet formulas from attacker-controlled columns', async () => {
    const { env, db } = testEnv();
    // source and path come off a URL a stranger controls, and Excel executes a
    // leading = on open.
    db.prepare(`
        INSERT INTO site_visits (id, visit_id, event, created_at, path, source, country)
        VALUES ('evil', 'v_evil', 'arrive', datetime('now', '-1 hour'),
                '=cmd|calc', '=HYPERLINK("http://x")', 'GB')
    `).run();
    const res = await adminFetch(env, '/api/admin/sessions?days=30&format=csv');
    const row = res.text.split('\n').find((r) => r.startsWith('v_evil,'));
    assert.ok(row.includes(`"'=HYPERLINK(""http://x"")"`), `not escaped: ${row}`);
    assert.ok(row.includes("'=cmd|calc"), `not escaped: ${row}`);
    assert.ok(!/,=/.test(row), `a bare formula survived: ${row}`);
});

test('full export covers every table and says how much it holds', async () => {
    const { env } = testEnv();
    const res = await adminFetch(env, '/api/admin/export-all?hours=24');
    assert.equal(res.status, 200);
    assert.equal(res.json.window_hours, 24);
    assert.equal(res.json.truncated, false);
    assert.ok(res.json.tables.site_visits.count > 0);
    assert.equal(res.json.tables.conversation_logs.count, 3);
    assert.equal(res.json.tables.deploy_log.count, 0);
    assert.equal(res.headers.get('X-Export-Truncated'), '0');
});

test('full export windows conversation_logs despite its different timestamp format', async () => {
    const { env, db } = testEnv();
    // conversation_logs writes ISO-8601 while everything else takes SQLite's
    // default. As strings "T" sorts above " ", so an old ISO row slips through
    // a window it does not belong in unless the separator is normalised.
    db.prepare(`
        INSERT INTO conversation_logs (id, created_at, user_id, chat_id, model,
            status, status_code, user_message, request_messages_json)
        VALUES ('ancient', '2026-01-01T09:00:00.000Z', 'user_1700000000000',
                'Zeus (King of the Gods)', 'gpt-4o', 'completed', 200, 'old', '[]')
    `).run();
    const res = await adminFetch(env, '/api/admin/export-all?hours=24');
    const ids = res.json.tables.conversation_logs.rows.map((r) => r.id);
    assert.ok(!ids.includes('ancient'), 'a January row came back in a 24-hour window');
});

test('full export survives a table that does not exist yet', async () => {
    // deploy_log only exists once migration 0010 is applied, which on any given
    // database it may not be. One missing table must not cost the whole dump.
    const { env } = testEnv({ skip: ['0010_deploy_log.sql'] });
    const res = await adminFetch(env, '/api/admin/export-all?hours=24');
    assert.equal(res.status, 200);
    assert.ok(res.json.tables.deploy_log.error, 'expected the missing table to report itself');
    assert.ok(res.json.tables.site_visits.count > 0, 'the other tables should still be there');
});

test('deploy log records a deploy and reads it back', async () => {
    const { env } = testEnv();
    const created = await adminFetch(env, '/api/admin/deploys', {
        method: 'POST',
        body: { version: '1.6.4+60', deployed_at: '2026-08-11T18:20', target: 'both', notes: 'analytics' },
    });
    assert.equal(created.status, 200);
    // Stored in the one format every query on this database compares against.
    assert.equal(created.json.deploy.deployed_at, '2026-08-11 18:20:00');

    const list = await adminFetch(env, '/api/admin/deploys');
    assert.equal(list.json.deploys.length, 1);
    assert.equal(list.json.deploys[0].version, '1.6.4+60');
});

test('deploy log accepts an ISO timestamp and refuses an impossible one', async () => {
    const { env } = testEnv();
    const iso = await adminFetch(env, '/api/admin/deploys', {
        method: 'POST',
        body: { version: '1.6.3+59', deployed_at: '2026-08-09T11:05:30.000Z' },
    });
    assert.equal(iso.json.deploy.deployed_at, '2026-08-09 11:05:30');

    // A row that sorts wrongly is worse than a missing one: every window query
    // believes it silently.
    for (const bad of ['2026-13-40T09:00', 'yesterday', '2026-08-09 25:00:00', '']) {
        const res = await adminFetch(env, '/api/admin/deploys', {
            method: 'POST', body: { version: '1.0.0', deployed_at: bad },
        });
        assert.equal(res.status, 400, `accepted ${JSON.stringify(bad)}`);
    }

    const noVersion = await adminFetch(env, '/api/admin/deploys', {
        method: 'POST', body: { deployed_at: '2026-08-09T11:05' },
    });
    assert.equal(noVersion.status, 400);
});

test('deploy log explains itself when the migration has not been applied', async () => {
    const { env } = testEnv({ skip: ['0010_deploy_log.sql'] });
    const read = await adminFetch(env, '/api/admin/deploys');
    assert.equal(read.status, 503);
    // The page can only act on this if it names the file to run.
    assert.match(read.json.hint, /0010_deploy_log\.sql/);

    const write = await adminFetch(env, '/api/admin/deploys', {
        method: 'POST', body: { version: '1.0.0', deployed_at: '2026-08-09T11:05' },
    });
    assert.equal(write.status, 503);
    assert.match(write.json.hint, /0010_deploy_log\.sql/);
});

test('admin routes refuse a request without the token', async () => {
    const { env } = testEnv();
    const worker = (await import('../src/worker.js')).default;
    for (const pathname of ['/api/admin/sessions', '/api/admin/export-all', '/api/admin/deploys']) {
        const res = await worker.fetch(
            new Request('https://mythos.test' + pathname), env,
            { waitUntil() {}, passThroughOnException() {} });
        assert.equal(res.status, 401, `${pathname} answered ${res.status} unauthenticated`);
    }
});
