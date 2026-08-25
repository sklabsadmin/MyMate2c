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

test('the engagement-context trio lands: touches, return bit, variant', async () => {
    const { env, db } = testEnv();
    await beacon(env, {
        visitId: 'v_ctx', event: 'entry_shown', path: '/c/zeus', detail: 'zeus#fold=below',
        touchCount: 3, isReturn: 1, variant: 'card-copy-oct:b',
    });
    const row = rowFor(db, 'v_ctx');
    assert.equal(row.touch_count, 3);
    assert.equal(row.is_return, 1);
    assert.equal(row.variant, 'card-copy-oct:b');
    // The fold flag rides detail; the '#' convention keeps character grouping
    // intact because every consumer takes the part before the first '#'.
    assert.equal(row.detail, 'zeus#fold=below');
});

test('absent context reads as unknown, and junk is coerced, not stored', async () => {
    const { env, db } = testEnv();
    await beacon(env, { visitId: 'v_bare', event: 'arrive', path: '/' });
    const bare = rowFor(db, 'v_bare');
    assert.equal(bare.touch_count, null);
    assert.equal(bare.is_return, null);
    assert.equal(bare.variant, null);

    await beacon(env, {
        visitId: 'v_junk', event: 'arrive', path: '/',
        touchCount: -5, isReturn: 'yes', variant: 'x'.repeat(200),
    });
    const junk = rowFor(db, 'v_junk');
    assert.equal(junk.touch_count, null, 'a negative count is not a count');
    assert.equal(junk.is_return, null, 'a string is not the bit');
    assert.equal(junk.variant.length, 60);
});

test('the visits page splits the funnel by variant once one exists', async () => {
    const { env } = testEnv();
    for (const [visit, arm, tapped] of [['v_a1', 'exp:a', false], ['v_b1', 'exp:b', true]]) {
        await beacon(env, { visitId: visit, event: 'arrive', path: '/c/zeus', variant: arm });
        await beacon(env, { visitId: visit, event: 'entry_shown', path: '/c/zeus', variant: arm });
        if (tapped) await beacon(env, { visitId: visit, event: 'entry_tap', path: '/c/zeus', variant: arm });
    }
    const { adminFetch } = await import('./harness.mjs');
    const res = await adminFetch(env, '/api/admin/visits?days=30');
    const byVariant = res.json.byVariant;
    assert.equal(byVariant.length, 2);
    const b = byVariant.find((r) => r.variant === 'exp:b');
    assert.equal(b.shown, 1);
    assert.equal(b.tapped, 1);
});

test('the by-ad table groups on the ids inside the query string', async () => {
    const { env } = testEnv();
    const q = '?fbclid=' + 'A'.repeat(180) +
        '&utm_source=fb&utm_medium=paid&utm_campaign=hercules-paid-20260817' +
        '&utm_content=52613165107531&utm_term=52613164274931';
    await beacon(env, { visitId: 'v_ad1', event: 'arrive', path: '/c/hercules', query: q });
    await beacon(env, { visitId: 'v_ad1', event: 'entry_shown', path: '/c/hercules' });
    const { adminFetch } = await import('./harness.mjs');
    const res = await adminFetch(env, '/api/admin/visits?days=30');
    const row = res.json.byAd.find((r) => r.ad === '52613165107531');
    assert.ok(row, 'the ad id must survive parsing whole');
    assert.equal(row.adset, '52613164274931');
    assert.equal(row.shown, 1);
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

test('a Meta-sized query survives with its trailing utm params intact', async () => {
    // The real shape that broke: fbclid first, the attribution params last.
    // At the old 300-char cap the tail was amputated on 89% of arrivals in a
    // 45h window — utm_term reduced to a six-character stump — so the ad ids
    // the campaign was already sending never reached the table whole.
    const { env, db } = testEnv();
    const query = '?fbclid=' + 'A'.repeat(180) +
        '&utm_source=fb&utm_medium=paid&utm_campaign=hercules-paid-20260817' +
        '&utm_id=52613165086331&utm_content=52613165107531&utm_term=52613164274931';
    assert.ok(query.length > 300, 'fixture must exceed the old cap');
    await beacon(env, { visitId: 'v_meta', event: 'arrive', path: '/c/hercules', query });
    assert.ok(rowFor(db, 'v_meta').query.endsWith('utm_term=52613164274931'),
        'the last param must survive whole');
});

test('the claim screen events are stored as themselves, not counted as arrivals', async () => {
    // ALLOWED_EVENTS coerces anything it does not recognise to 'arrive'. That
    // is the trap this test exists for: a client shipping a new funnel event
    // before the worker knows the name does not error, it silently inflates
    // the arrival count — the denominator every rate on the visits page is
    // built from. Both halves of the coin claim have to survive the round
    // trip under their own names.
    const { env, db } = testEnv();
    await beacon(env, {
        visitId: 'v_claim', event: 'claim_shown', path: '/c/odysseus',
        detail: 'odysseus#40',
    });
    await beacon(env, {
        visitId: 'v_claim', event: 'claim_tap', path: '/c/odysseus',
        detail: 'odysseus#40',
    });

    const events = db.prepare(
        'SELECT event, detail FROM site_visits WHERE visit_id = ? ORDER BY rowid'
    ).all('v_claim');
    assert.deepEqual(events.map((r) => r.event), ['claim_shown', 'claim_tap']);
    // The '#' convention again: everything downstream groups on the part
    // before it, so the amount claimed rides along without splitting the
    // character into forty of itself.
    assert.equal(events[0].detail, 'odysseus#40');
    assert.equal(
        db.prepare("SELECT COUNT(*) AS n FROM site_visits WHERE visit_id = ? AND event = 'arrive'")
            .get('v_claim').n,
        0,
        'not one of them may land as an arrival',
    );
});

test('the dev marker lands, and junk does not fake it', async () => {
    const { env, db } = testEnv();
    await beacon(env, { visitId: 'v_dev', event: 'arrive', path: '/', isDev: 1 });
    assert.equal(rowFor(db, 'v_dev').is_dev, 1);
    await beacon(env, { visitId: 'v_notdev', event: 'arrive', path: '/' });
    assert.equal(rowFor(db, 'v_notdev').is_dev, null);
    // Unauthenticated endpoint: only the exact bit counts as the developer.
    await beacon(env, { visitId: 'v_devjunk', event: 'arrive', path: '/', isDev: 'yes' });
    assert.equal(rowFor(db, 'v_devjunk').is_dev, null);
});

test('dev visits vanish from every aggregate but stay in the raw export', async () => {
    const { env } = testEnv();
    // One real visit, one dev visit, both shown the card; only the real one
    // may reach any funnel. The dev visit taps, which would otherwise be the
    // most analysed row in the table — a Mac test session once spent a day
    // being read as the coins card's first paid acceptor.
    for (const [vid, dev] of [['v_real9', undefined], ['v_dev9', 1]]) {
        await beacon(env, { visitId: vid, event: 'arrive', path: '/c/zeus', isDev: dev });
        await beacon(env, { visitId: vid, event: 'entry_shown', path: '/c/zeus', detail: 'zeus#fold=fit', isDev: dev });
    }
    await beacon(env, { visitId: 'v_dev9', event: 'entry_tap', path: '/c/zeus', detail: 'zeus#button', isDev: 1 });

    const { adminFetch } = await import('./harness.mjs');
    const visits = await adminFetch(env, '/api/admin/visits?days=30');
    assert.ok(!visits.json.recent.some((r) => r.visit_id === 'v_dev9'),
        'the dev visit must not appear in recent arrivals');
    assert.ok(visits.json.recent.some((r) => r.visit_id === 'v_real9'));
    const funnelTapped = visits.json.funnel.reduce((n, r) => n + (r.entry_tap || 0), 0);
    assert.equal(funnelTapped, 0, 'the dev tap must not reach the funnel');

    // The raw dump keeps everything: it is the record, not a report.
    const dump = await adminFetch(env, '/api/admin/export-all?hours=24');
    assert.ok(dump.json.tables.site_visits.rows.some((r) => r.visit_id === 'v_dev9'));
});
