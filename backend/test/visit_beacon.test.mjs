// The funnel write path: what a beacon POST to /api/visit actually stores.
// Focused on app_version, the column that exists so a funnel can be segmented
// across a deploy without reconstructing versions from delivery receipts.

import test from 'node:test';
import assert from 'node:assert/strict';
import { testEnv, loadWorker } from './harness.mjs';

// The route answers 204 immediately and writes through ctx.waitUntil, so the
// stub has to hold those promises and the test has to await them — a stub
// with a no-op waitUntil passes even when nothing is ever written.
async function beacon(env, body) {
    const worker = await loadWorker();
    const pending = [];
    const res = await worker.fetch(new Request('https://mythos.test/api/visit', {
        method: 'POST',
        body: JSON.stringify(body),
    }), env, { waitUntil(p) { pending.push(p); }, passThroughOnException() {} });
    await Promise.all(pending);
    return res;
}

const rowFor = (db, visitId) =>
    db.prepare('SELECT * FROM site_visits WHERE visit_id = ?').get(visitId);

test('a visit row records the bundle version the beacon sent', async () => {
    const { env, db } = testEnv();
    const res = await beacon(env, {
        visitId: 'v_versioned', event: 'arrive', path: '/c/zeus',
        appVersion: '1.7.1+70',
    });
    assert.equal(res.status, 204);
    assert.equal(rowFor(db, 'v_versioned').app_version, '1.7.1+70');
});

test('a beacon without a version stores unknown, never an empty string', async () => {
    // Dev serves and bare `flutter build web` skip the stamp and send nothing;
    // those rows must read as unknown, the same rule as every other column.
    const { env, db } = testEnv();
    await beacon(env, { visitId: 'v_unstamped', event: 'arrive', path: '/' });
    assert.equal(rowFor(db, 'v_unstamped').app_version, null);
});

test('an oversized version string is capped, not stored verbatim', async () => {
    // The endpoint is unauthenticated by design; length caps are the defence.
    const { env, db } = testEnv();
    await beacon(env, {
        visitId: 'v_hostile', event: 'arrive', path: '/',
        appVersion: 'x'.repeat(500),
    });
    assert.equal(rowFor(db, 'v_hostile').app_version.length, 40);
});
