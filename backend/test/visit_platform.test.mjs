// site_visits.platform / referral_visits.platform — which app opened the link.
//
// Migration 0008 built these columns and 0024 repaired them. The bug they
// existed in for three months is the one worth pinning down here, because
// every property of it made it hard to see:
//
//   * it was in the write path, not the detector — /api/visit is an XHR to our
//     own worker, so its Referer header is always our own page, and `platform`
//     was reading that header while `source` three fields away correctly read
//     the beacon's payload;
//   * the user-agent arms still worked, so Meta in-app traffic — the only
//     segment anyone was looking at — stayed correct, and the 93% Facebook
//     finding 0008 was written to capture still held;
//   * everything else collapsed into a bucket named after us, which is not an
//     empty column or an error. It is a confident answer to a question nobody
//     asked, and it reads as data.
//
// So the assertions below are mostly about the referer the worker chooses,
// which is the thing that was wrong and the thing no amount of testing the
// detector in isolation would have caught.

import test from 'node:test';
import assert from 'node:assert/strict';
import { d1, freshDb, loadWorker, testEnv, adminFetch } from './harness.mjs';

const SELF = 'chat.deeploveechoes.com';

function beaconEnv() {
    const db = freshDb();
    return { env: { CHAT_LOGS_DB: d1(db), REQUIRE_SIGNATURE: 'false' }, db };
}

/// Posts a beacon the way the page does: the real referrer is in the BODY, and
/// the request's own Referer header is our own page, because that is what a
/// browser sends on an XHR.
async function beacon(env, { referer = null, userAgent = 'Mozilla/5.0 (iPhone)', visitId = 'v1', event = 'arrive', query = null } = {}) {
    const worker = await loadWorker();
    const headers = {
        'content-type': 'application/json',
        'user-agent': userAgent,
        // The header the broken code was reading. Present on every real
        // beacon, and never the answer.
        referer: `https://${SELF}/c/calypso`,
    };
    const pending = [];
    const res = await worker.fetch(new Request(`https://${SELF}/api/visit`, {
        method: 'POST',
        headers,
        body: JSON.stringify({ visitId, event, path: '/c/calypso', query, referer }),
    }), env, { waitUntil(p) { pending.push(p); }, passThroughOnException() {} });
    await res.text();
    await Promise.all(pending);
    return res.status;
}

const platformOf = (db, visitId) => db
    .prepare(`SELECT platform FROM site_visits WHERE visit_id = ? ORDER BY created_at DESC LIMIT 1`)
    .get(visitId)?.platform;

test('the beacon classifies the page referrer, not its own request header', async () => {
    // The regression. Before the fix every one of these recorded
    // 'chat.deeploveechoes.com', because that is what the XHR's Referer says.
    const { env, db } = beaconEnv();
    const cases = {
        'https://l.facebook.com/l.php?u=https%3A%2F%2Fchat.deeploveechoes.com%2Fc%2Fcalypso': 'facebook',
        'https://m.facebook.com/': 'facebook',
        'https://www.instagram.com/': 'instagram',
        'https://www.threads.net/@someone': 'threads',
        'https://www.tiktok.com/@someone': 'tiktok',
        'https://t.co/abc123': 'x',
        'https://www.google.com/search?q=mythos': 'google',
    };
    let i = 0;
    for (const [referer, expected] of Object.entries(cases)) {
        const visitId = `v_ref_${i++}`;
        // 204: the beacon is fire-and-forget and answers with no body.
        assert.equal(await beacon(env, { referer, visitId }), 204);
        assert.equal(platformOf(db, visitId), expected, `referer ${referer}`);
    }
});

test('a Facebook shim naming our own domain is a Facebook click, not an internal one', async () => {
    // The ordering trap, and the reason the worker matches on a parsed
    // hostname rather than a substring: the destination rides in the query
    // string, so the URL contains both names.
    const { env, db } = beaconEnv();
    await beacon(env, {
        visitId: 'v_shim',
        referer: `https://l.facebook.com/l.php?u=https://${SELF}/c/calypso&h=AT1`,
    });
    assert.equal(platformOf(db, 'v_shim'), 'facebook');
});

test('our own hostname is internal, which is the absence of a platform', async () => {
    const { env, db } = beaconEnv();
    for (const [i, referer] of [
        `https://${SELF}/`,
        `https://${SELF}/c/zeus`,
        'https://chat.deeplovepoems.com/',
        'https://deeploveechoes.com/',
        'https://www.deeploveechoes.com/landing',
    ].entries()) {
        const visitId = `v_self_${i}`;
        await beacon(env, { referer, visitId });
        assert.equal(platformOf(db, visitId), 'internal', `referer ${referer}`);
    }
});

test('an unrecognised referrer is one bucket, not one bucket per host', async () => {
    // The cardinality half. A GROUP BY column cannot have a bucket per host on
    // the internet, and the raw host is not lost — it stays in `referer`.
    const { env, db } = beaconEnv();
    const hosts = ['https://news.ycombinator.com/item?id=1', 'https://some.blog.example/post', 'https://reddit.com/r/x'];
    for (const [i, referer] of hosts.entries()) {
        await beacon(env, { referer, visitId: `v_other_${i}` });
    }
    const rows = db.prepare(`
        SELECT platform, COUNT(*) AS n FROM site_visits
        WHERE visit_id LIKE 'v_other_%' GROUP BY platform
    `).all().map((r) => ({ ...r }));
    assert.deepEqual(rows, [{ platform: 'other', n: 3 }]);

    // And the evidence survives the narrowing, which is what makes it safe.
    const refs = db.prepare(`SELECT referer FROM site_visits WHERE visit_id = 'v_other_0'`).get();
    assert.equal(refs.referer, 'https://news.ycombinator.com/item?id=1');
});

test('no referrer is direct, and the in-app user-agent still wins over any of it', async () => {
    const { env, db } = beaconEnv();
    await beacon(env, { referer: null, visitId: 'v_direct' });
    assert.equal(platformOf(db, 'v_direct'), 'direct');

    // The arms that never broke, and that carried the 0008 finding. Asserted
    // so the repair cannot quietly cost them: a Meta in-app browser is the
    // platform whatever the referrer says, including when it says nothing or
    // says us.
    await beacon(env, { referer: null, userAgent: 'Mozilla/5.0 (iPhone) Instagram 300.0', visitId: 'v_ig' });
    assert.equal(platformOf(db, 'v_ig'), 'instagram');
    await beacon(env, { referer: `https://${SELF}/`, userAgent: 'Mozilla/5.0 (iPhone) FBAV/400.0', visitId: 'v_fb' });
    assert.equal(platformOf(db, 'v_fb'), 'facebook');
    // Both tokens: Instagram is tested first so it is not filed as Facebook.
    await beacon(env, { referer: null, userAgent: 'Mozilla/5.0 Instagram 300.0 FBAV/400.0', visitId: 'v_both' });
    assert.equal(platformOf(db, 'v_both'), 'instagram');
});

test('platform never consults utm_source, however the link is tagged', async () => {
    // 0008's founding argument: the tag says where the link was published and
    // the client says where it was clicked. A campaign link tagged for
    // Instagram, opened in Facebook's in-app browser, has to read facebook
    // here and ig in `source` — the gap between the two is the finding.
    const { env, db } = beaconEnv();
    await beacon(env, {
        visitId: 'v_tagged',
        query: '?utm_source=ig&utm_campaign=calypso-reel',
        userAgent: 'Mozilla/5.0 (iPhone) FBAV/400.0',
        referer: 'https://m.facebook.com/',
    });
    const row = db.prepare(`SELECT platform, source FROM site_visits WHERE visit_id = 'v_tagged'`).get();
    assert.equal(row.platform, 'facebook', 'where it was clicked');
    assert.equal(row.source, 'ig', 'where it was published');
});

test('the character landing page keeps classifying its real referrer', async () => {
    // referral_visits was never affected by the write-path bug: its caller is
    // a real page navigation, so the request's Referer IS the page the visitor
    // came from. Only the vocabulary changed, and this is what says so.
    const { env, db } = beaconEnv();
    const worker = await loadWorker();
    env.ASSETS = { fetch: async () => new Response('<html><head></head><body></body></html>', { headers: { 'content-type': 'text/html' } }) };
    const pending = [];
    await worker.fetch(new Request(`https://${SELF}/c/calypso?utm_source=ig`, {
        headers: { referer: 'https://m.facebook.com/', 'user-agent': 'Mozilla/5.0 (iPhone)' },
    }), env, { waitUntil(p) { pending.push(p); }, passThroughOnException() {} });
    await Promise.all(pending);

    const row = db.prepare(`SELECT platform, source FROM referral_visits ORDER BY created_at DESC LIMIT 1`).get();
    assert.equal(row.platform, 'facebook');
    assert.equal(row.source, 'ig');
});

test('an own-hostname landing is internal there too', async () => {
    const { env, db } = beaconEnv();
    const worker = await loadWorker();
    env.ASSETS = { fetch: async () => new Response('<html><head></head><body></body></html>', { headers: { 'content-type': 'text/html' } }) };
    const pending = [];
    await worker.fetch(new Request(`https://${SELF}/c/zeus`, {
        headers: { referer: `https://${SELF}/`, 'user-agent': 'Mozilla/5.0 (iPhone)' },
    }), env, { waitUntil(p) { pending.push(p); }, passThroughOnException() {} });
    await Promise.all(pending);
    assert.equal(db.prepare(`SELECT platform FROM referral_visits ORDER BY created_at DESC LIMIT 1`).get().platform, 'internal');
});

// --- the repair -----------------------------------------------------------

test('0024 recomputes historical rows from the evidence that was always stored', async () => {
    // The difference from 0023, which could not backfill: user_agent and
    // referer have been on these tables since they were created, and `referer`
    // holds the payload value — the real one — not the header the write path
    // was misreading. So every row ever written can be recomputed to the value
    // it should have had.
    //
    // The migration runs at database build time, so this seeds rows carrying
    // the BROKEN values and re-runs it, which is also what proves it is
    // idempotent and safe to re-apply.
    const { env, db } = beaconEnv();
    const insert = db.prepare(`
        INSERT INTO site_visits (id, visit_id, event, platform, referer, user_agent)
        VALUES (?, ?, 'arrive', ?, ?, ?)
    `);
    const rows = [
        // What the bug actually wrote: our own hostname, for real Google traffic.
        ['r1', SELF, 'https://www.google.com/search?q=mythos', 'Mozilla/5.0 (iPhone)', 'google'],
        ['r2', 'chat.deeplovepoems.com', 'https://news.ycombinator.com/x', 'Mozilla/5.0', 'other'],
        ['r3', SELF, `https://${SELF}/c/zeus`, 'Mozilla/5.0', 'internal'],
        ['r4', SELF, null, 'Mozilla/5.0 (iPhone)', 'direct'],
        // The arms that were right all along and must survive the repair.
        ['r5', 'instagram', null, 'Mozilla/5.0 Instagram 300.0', 'instagram'],
        // Nothing stored at all: unknown, and must stay NULL rather than
        // become 'direct'.
        ['r6', null, null, null, null],
    ];
    for (const [id, broken, referer, ua] of rows) insert.run(id, id, broken, referer, ua);

    const sql = (await import('node:fs')).readFileSync(
        new URL('../migrations/0024_platform_repair.sql', import.meta.url), 'utf8');
    db.exec(sql);

    for (const [id, , , , expected] of rows) {
        assert.equal(
            db.prepare(`SELECT platform FROM site_visits WHERE id = ?`).get(id).platform,
            expected, `row ${id}`);
    }

    // Idempotent: it reads only the raw evidence, never its own output.
    db.exec(sql);
    for (const [id, , , , expected] of rows) {
        assert.equal(db.prepare(`SELECT platform FROM site_visits WHERE id = ?`).get(id).platform, expected, `row ${id} re-run`);
    }
    assert.ok(env);
});

test('after the repair the column groups into a vocabulary, not a host list', async () => {
    // The point of the whole exercise: one GROUP BY that answers "where did
    // this week's visitors come from" without a bucket per hostname.
    const { env } = testEnv();
    const res = await adminFetch(env, '/api/admin/export-all?hours=24');
    assert.equal(res.status, 200);
    const seen = new Set(res.json.tables.site_visits.rows.map((r) => r.platform));
    const allowed = new Set([
        'instagram', 'facebook', 'threads', 'tiktok', 'youtube', 'x', 'google',
        'internal', 'other', 'direct', null,
    ]);
    for (const value of seen) {
        assert.ok(allowed.has(value), `unexpected platform ${JSON.stringify(value)}`);
        // The specific shape of the bug: never a hostname.
        if (value) assert.ok(!value.includes('.'), `${value} looks like a hostname`);
    }
});
