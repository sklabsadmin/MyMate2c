// /api/delivery — the receipts the client sends for what it actually drew.
//
// The behaviours pinned down here are the ones that decide whether the table
// can be trusted as evidence, rather than the ones that are merely easy to
// test: that a retry completes a row instead of corrupting it, that a receipt
// the worker rejects still gets acked (or the client retries it forever), and
// that a flush which sat in a queue through an outage is not mistaken for a
// replay attack — which is the failure that would silently discard exactly the
// data the table exists to collect.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { ADMIN_TOKEN, adminFetch, d1, freshDb, loadWorker, seed } from './harness.mjs';

const APP_SECRET = 'test-app-secret';
const REAL_USER = 'user_1700000000000';

function envWith({ skip = [], requireSignature = false } = {}) {
    const db = seed(freshDb({ skip }));
    // ADMIN_TOKEN so the report half of these tests can get past the admin
    // guard; the ingest half never looks at it.
    const env = { CHAT_LOGS_DB: d1(db), APP_SECRET, ADMIN_TOKEN };
    // Off by default so most tests are about the storage behaviour rather than
    // about re-proving the HMAC that /api/chat already relies on.
    if (!requireSignature) env.REQUIRE_SIGNATURE = 'false';
    return { env, db };
}

/// A receipt with every required field filled in, so each test can name only
/// the field it is actually about.
function receipt(extra = {}) {
    return {
        bubbleId: 'b1',
        turnId: 't1',
        seq: 0,
        userId: REAL_USER,
        visitId: 'v_flap',
        chatId: 'Calypso (Nymph of Ogygia)',
        origin: 'ai_reply',
        text: 'well met',
        textLen: 8,
        intendedAt: '2026-08-13T09:00:00.000Z',
        ...extra,
    };
}

async function flush(env, receipts, { sign = null, cf = null } = {}) {
    const worker = await loadWorker();
    const body = JSON.stringify({ receipts });
    const headers = { 'Content-Type': 'application/json' };

    if (sign) {
        const timestamp = String(sign.timestamp ?? Date.now());
        headers['x-timestamp'] = timestamp;
        headers['x-signature'] = sign.signature ?? createHmac('sha256', sign.secret ?? APP_SECRET)
            .update(body + timestamp)
            .digest('hex');
    }

    const request = new Request('https://mythos.test/api/delivery', { method: 'POST', headers, body });
    if (cf) Object.defineProperty(request, 'cf', { value: cf });

    const res = await worker.fetch(request, env, { waitUntil() {}, passThroughOnException() {} });
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch (_) { /* prose */ }
    return { status: res.status, json, text };
}

const rowFor = (db, bubbleId) =>
    db.prepare('SELECT * FROM message_delivery WHERE bubble_id = ?').get(bubbleId);

test('a receipt is stored and acked', async () => {
    const { env, db } = envWith();
    const res = await flush(env, [receipt({ renderedAt: '2026-08-13T09:00:01.000Z' })]);

    assert.equal(res.status, 200);
    assert.deepEqual(res.json.acked, ['b1']);

    const row = rowFor(db, 'b1');
    assert.equal(row.origin, 'ai_reply');
    assert.equal(row.text, 'well met');
    assert.equal(row.intended_at, '2026-08-13T09:00:00.000Z');
    assert.equal(row.rendered_at, '2026-08-13T09:00:01.000Z');
    // The finding: intended, rendered, never seen.
    assert.equal(row.seen_at, null);
    // Written by the server's clock, not the client's, so a device with a bad
    // clock cannot fall out of an admin window.
    assert.ok(row.server_received_at);
});

test('country and colo come off the flush, not the payload', async () => {
    const { env, db } = envWith();
    // A client claiming its own country would be trusting the least reliable
    // party in the exchange; these are Cloudflare's.
    await flush(env, [receipt({ country: 'XX', colo: 'XXX' })], { cf: { country: 'GB', colo: 'LHR' } });

    const row = rowFor(db, 'b1');
    assert.equal(row.country, 'GB');
    assert.equal(row.colo, 'LHR');
});

test('a retried receipt completes the row and never moves a time already set', async () => {
    const { env, db } = envWith();

    // First flush: intended only — the bubble was committed to but the send
    // went out before it had been drawn.
    await flush(env, [receipt()]);
    assert.equal(rowFor(db, 'b1').rendered_at, null);

    // Second flush: the same bubble, now drawn and seen.
    await flush(env, [receipt({
        renderedAt: '2026-08-13T09:00:01.000Z',
        seenAt: '2026-08-13T09:00:02.000Z',
    })]);

    let row = rowFor(db, 'b1');
    assert.equal(row.rendered_at, '2026-08-13T09:00:01.000Z');
    assert.equal(row.seen_at, '2026-08-13T09:00:02.000Z');

    // Third flush: a duplicate carrying different times, which is what a lost
    // ack plus a regenerated payload looks like. The first recorded moment wins.
    await flush(env, [receipt({
        intendedAt: '2026-08-13T11:00:00.000Z',
        renderedAt: '2026-08-13T11:00:01.000Z',
        seenAt: '2026-08-13T11:00:02.000Z',
    })]);

    row = rowFor(db, 'b1');
    assert.equal(row.intended_at, '2026-08-13T09:00:00.000Z');
    assert.equal(row.rendered_at, '2026-08-13T09:00:01.000Z');
    assert.equal(row.seen_at, '2026-08-13T09:00:02.000Z');

    // And exactly one row throughout.
    const { count } = db.prepare('SELECT COUNT(*) AS count FROM message_delivery').get();
    assert.equal(count, 1);
});

test('the worst queue delay survives a later, faster flush', async () => {
    const { env, db } = envWith();

    // Landed after 40 minutes in the queue, on the fourth attempt.
    await flush(env, [receipt({ queuedMs: 2_400_000, flushAttempts: 4 })]);
    // The retry that completes it went out instantly — but the outage still
    // happened, and it is the outage the column is for.
    await flush(env, [receipt({ seenAt: '2026-08-13T09:00:02.000Z', queuedMs: 12, flushAttempts: 1 })]);

    const row = rowFor(db, 'b1');
    assert.equal(row.queued_ms, 2_400_000);
    assert.equal(row.flush_attempts, 4);
});

test('a receipt the worker refuses to store is still acked', async () => {
    const { env, db } = envWith();

    const res = await flush(env, [
        receipt({ bubbleId: 'b_unknown_origin', origin: 'telepathy' }),
        receipt({ bubbleId: 'b_fake_user', userId: 'browsertest' }),
        receipt({ bubbleId: 'b_good' }),
    ]);

    // All three acked: an unacked receipt is retried forever, so refusing to
    // store one must not also mean refusing to answer for it.
    assert.deepEqual(res.json.acked.sort(), ['b_fake_user', 'b_good', 'b_unknown_origin']);

    // Only the good one is on disk. The other two are the pollution guards
    // working — see writeConversationLogRow for what unrecognised ids did to
    // conversation_logs before it had one.
    assert.ok(rowFor(db, 'b_good'));
    assert.equal(rowFor(db, 'b_unknown_origin'), undefined);
    assert.equal(rowFor(db, 'b_fake_user'), undefined);
});

test('a receipt with no id is dropped rather than acked', async () => {
    const { env, db } = envWith();
    const res = await flush(env, [receipt({ bubbleId: '' }), receipt({ turnId: '' })]);

    assert.equal(res.status, 200);
    assert.deepEqual(res.json.acked, []);
    const { count } = db.prepare('SELECT COUNT(*) AS count FROM message_delivery').get();
    assert.equal(count, 0);
});

test('an oversized batch is refused whole', async () => {
    const { env, db } = envWith();
    const many = Array.from({ length: 201 }, (_, i) => receipt({ bubbleId: `b${i}` }));

    const res = await flush(env, many);
    assert.equal(res.status, 413);

    const { count } = db.prepare('SELECT COUNT(*) AS count FROM message_delivery').get();
    assert.equal(count, 0);
});

test('a correctly signed flush is accepted', async () => {
    const { env, db } = envWith({ requireSignature: true });
    const res = await flush(env, [receipt()], { sign: {} });

    assert.equal(res.status, 200);
    assert.ok(rowFor(db, 'b1'));
});

test('an unsigned flush is refused when signing is required', async () => {
    const { env } = envWith({ requireSignature: true });
    const res = await flush(env, [receipt()]);

    assert.equal(res.status, 401);
});

test('a wrongly signed flush is refused', async () => {
    const { env } = envWith({ requireSignature: true });
    const res = await flush(env, [receipt()], { sign: { secret: 'not-the-secret' } });

    assert.equal(res.status, 401);
});

test('the freshness window is on the flush, not on the bubble', async () => {
    const { env, db } = envWith({ requireSignature: true });

    // A flush signed an hour ago is a replay and is refused...
    const stale = await flush(env, [receipt()], { sign: { timestamp: Date.now() - 60 * 60 * 1000 } });
    assert.equal(stale.status, 401);

    // ...but a bubble seen an hour ago, flushed now, is the whole point of the
    // queue and must land. If these two ever collapse into one check, every
    // receipt from a network outage is discarded as an attack and the table
    // goes quiet precisely when it matters.
    const queued = await flush(env, [receipt({
        intendedAt: new Date(Date.now() - 60 * 60 * 1000).toISOString(),
        queuedMs: 3_600_000,
    })], { sign: {} });

    assert.equal(queued.status, 200);
    assert.ok(rowFor(db, 'b1'));
});

test('delivery logging explains itself when the migration has not been applied', async () => {
    const { env } = envWith({ skip: ['0011_message_delivery.sql'] });
    const res = await flush(env, [receipt()]);

    // 503, not 200: the client must keep the receipt and retry, because on an
    // unmigrated deployment nothing stored it. Acking here would throw away
    // every receipt sent before someone remembered to run the migration.
    assert.equal(res.status, 503);
});

/// Drives the report the way the page does. Separate from `flush` because these
/// go through the admin auth path.
const report = (env, days = 7) =>
    adminFetch(env, `/api/admin/delivery?days=${days}`);

test('the report counts the funnel and separates unrendered from unseen', async () => {
    const { env } = envWith();

    await flush(env, [
        // Seen.
        receipt({ bubbleId: 'b0', seq: 0, renderedAt: '2026-08-13T09:00:01.000Z', seenAt: '2026-08-13T09:00:02.000Z' }),
        // Drawn, but never in front of anyone — a hidden tab or below the fold.
        receipt({ bubbleId: 'b1', seq: 1, renderedAt: '2026-08-13T09:00:03.000Z' }),
        // Never drawn at all: the delivery failure.
        receipt({ bubbleId: 'b2', seq: 2 }),
    ]);

    const res = await report(env);
    assert.equal(res.status, 200);
    const s = res.json.summary;
    assert.equal(s.total, 3);
    assert.equal(s.rendered, 2);
    assert.equal(s.seen, 1);
    // The two are different problems and must not be conflated.
    assert.equal(s.never_rendered, 1);
    assert.equal(s.rendered_unseen, 1);
});

test('text fidelity forgives the client stripping and flags anything else', async () => {
    const { env, db } = envWith();

    // The seeded m1 reply is 'well met'. Give it characters the client is known
    // to strip before drawing, so the stored reply and the drawn text differ.
    db.prepare(`UPDATE conversation_logs SET assistant_message = ? WHERE id = 'm1'`)
        .run('**well met**, "traveller"');

    await flush(env, [
        // What the client would actually draw after its own cleanup. Different
        // bytes from assistant_message, and correct.
        receipt({ bubbleId: 'b_ok', conversationLogId: 'm1', text: 'well met, traveller' }),
        // Text the reply does not contain at all — the case worth alerting on.
        receipt({ bubbleId: 'b_bad', conversationLogId: 'm1', text: 'buy cheap watches' }),
        // Composed on the device: no log row to check it against, counted
        // separately rather than silently passing.
        receipt({ bubbleId: 'b_local', origin: 'welcome_script', text: 'What brings you here?' }),
    ]);

    const f = (await report(env)).json.fidelity;
    assert.equal(f.checkable, 2);
    assert.equal(f.verified, 1);
    assert.equal(f.unexplained, 1);
    assert.equal(f.unverifiable, 1);
});

test('the report groups by origin, country and connection', async () => {
    const { env } = envWith();

    await flush(env, [
        receipt({ bubbleId: 'a1', origin: 'ai_reply', connectionType: '4g', renderedAt: '2026-08-13T09:00:01.000Z', seenAt: '2026-08-13T09:00:02.000Z' }),
        receipt({ bubbleId: 'w1', origin: 'welcome_script', connectionType: 'slow-2g' }),
        receipt({ bubbleId: 'w2', origin: 'welcome_script', connectionType: 'slow-2g' }),
    ], { cf: { country: 'MY', colo: 'KUL' } });

    const data = (await report(env)).json;

    const welcome = data.by_origin.find((r) => r.origin === 'welcome_script');
    assert.equal(welcome.total, 2);
    assert.equal(welcome.never_rendered, 2);

    const my = data.by_country.find((r) => r.country === 'MY');
    assert.equal(my.total, 3);
    assert.equal(my.never_rendered, 2);

    const slow = data.by_connection.find((r) => r.connection_type === 'slow-2g');
    assert.equal(slow.total, 2);
});

test('a turn cut short is reported once, not once per bubble', async () => {
    const { env } = envWith();

    await flush(env, [
        receipt({ bubbleId: 'b0', seq: 0, renderedAt: '2026-08-13T09:00:01.000Z', seenAt: '2026-08-13T09:00:02.000Z' }),
        receipt({ bubbleId: 'b1', seq: 1 }),
        receipt({ bubbleId: 'b2', seq: 2 }),
    ]);

    const cutShort = (await report(env)).json.cut_short;
    assert.equal(cutShort.length, 1);
    assert.equal(cutShort[0].turn_id, 't1');
    assert.equal(cutShort[0].bubbles, 3);
    assert.equal(cutShort[0].seen, 1);
    assert.equal(cutShort[0].never_rendered, 2);
});

test('a turn the visitor saw in full is not reported as cut short', async () => {
    const { env } = envWith();

    await flush(env, [
        receipt({ bubbleId: 'b0', seq: 0, renderedAt: '2026-08-13T09:00:01.000Z', seenAt: '2026-08-13T09:00:02.000Z' }),
        receipt({ bubbleId: 'b1', seq: 1, renderedAt: '2026-08-13T09:00:03.000Z', seenAt: '2026-08-13T09:00:04.000Z' }),
    ]);

    assert.deepEqual((await report(env)).json.cut_short, []);
});

test('the report says which migration is missing rather than failing', async () => {
    const { env } = envWith({ skip: ['0011_message_delivery.sql'] });
    const res = await report(env);

    assert.equal(res.status, 503);
    assert.match(res.json.error, /0011/);
});

test('unseen bubbles are findable per turn', async () => {
    const { env, db } = envWith();

    // One reply, three bubbles, the visitor left after the first.
    await flush(env, [
        receipt({ bubbleId: 'b0', seq: 0, renderedAt: '2026-08-13T09:00:01.000Z', seenAt: '2026-08-13T09:00:01.500Z' }),
        receipt({ bubbleId: 'b1', seq: 1 }),
        receipt({ bubbleId: 'b2', seq: 2 }),
    ]);

    const unseen = db.prepare(`
        SELECT seq FROM message_delivery
        WHERE turn_id = ? AND seen_at IS NULL
        ORDER BY seq
    `).all('t1');

    assert.deepEqual(unseen.map((r) => r.seq), [1, 2]);
});

test('DELIVERY_LOGGING=false acks the batch and stores nothing', async () => {
    const { env, db } = envWith();
    env.DELIVERY_LOGGING = 'false';

    const res = await flush(env, [
        receipt({ bubbleId: 'b0', seq: 0 }),
        receipt({ bubbleId: 'b1', seq: 1 }),
    ]);

    // Acked, not refused. The client is already built with this feature in it
    // and keeps queueing whatever the worker says, so a refusal would leave
    // every visitor retrying on a backoff against something switched off —
    // filling a queue that eventually drops its oldest entries. The ack is how
    // the flag stops costing anything on the device.
    assert.equal(res.status, 200);
    assert.deepEqual(res.json.acked, ['b0', 'b1']);

    // And it says so. Without this the response is byte-identical to a
    // successful write, which makes a flag left off indistinguishable from a
    // quiet site — the same "recorded, then nothing" ambiguity the table
    // exists to resolve, in the one path that drops data deliberately.
    assert.equal(res.json.stored, false);

    const stored = db.prepare('SELECT COUNT(*) AS n FROM message_delivery').get();
    assert.equal(stored.n, 0);
});

test('a stored batch carries no stored marker', async () => {
    // The marker means "worth noticing", so it must be absent on the ordinary
    // path — otherwise anything reading it has to distinguish false from
    // missing, and the cheap check (is the key there?) silently inverts.
    const { env, db } = envWith();

    const res = await flush(env, [receipt()]);

    assert.equal(res.status, 200);
    assert.deepEqual(res.json.acked, ['b1']);
    assert.equal('stored' in res.json, false);
    assert.equal(db.prepare('SELECT COUNT(*) AS n FROM message_delivery').get().n, 1);
});

test('delivery logging stays on unless the var is exactly "false"', async () => {
    // A missing var is the state every environment is in until someone sets
    // one, and a misspelt value is the likeliest way to reach for the switch
    // and miss. Neither may silently stop the logging.
    for (const value of [undefined, 'true', 'FALSE', 'no', '0', '']) {
        const { env, db } = envWith();
        if (value !== undefined) env.DELIVERY_LOGGING = value;

        const res = await flush(env, [receipt()]);

        assert.equal(res.status, 200, `value ${JSON.stringify(value)} should log`);
        const stored = db.prepare('SELECT COUNT(*) AS n FROM message_delivery').get();
        assert.equal(stored.n, 1, `value ${JSON.stringify(value)} should have stored the receipt`);
    }
});
