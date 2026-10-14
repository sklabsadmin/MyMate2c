// Ops alerts: the out-of-credit email.
//
// The failure these tests pin down is the quiet one: OpenAI's balance hits
// zero, every turn comes back 429 insufficient_quota, the app says "having
// trouble thinking", and nobody is told. The worker must turn that into one
// email — and only one, not one per failing turn — while leaving every other
// kind of failure alone.
//
// Chat tests stub globalThis.fetch so the worker's upstream call gets the
// answer the test chooses; the email binding is a fake that records sends.

import test from 'node:test';
import assert from 'node:assert/strict';
import { testEnv, loadWorker } from './harness.mjs';

const USER = 'user_1700000000123';

function fakeEmail() {
    const sent = [];
    return {
        sent,
        binding: {
            async send(message) {
                sent.push(message);
                return { messageId: `msg-${sent.length}` };
            },
        },
    };
}

function alertEnv({ skip = [], email = true, extra = {} } = {}) {
    const { env, db } = testEnv({ skip });
    const mail = fakeEmail();
    return {
        env: {
            ...env,
            REQUIRE_SIGNATURE: 'false',
            APP_SECRET: 'test-app-secret',
            OPENAI_API_KEY: 'test-key',
            ...(email ? {
                ALERT_EMAIL: mail.binding,
                ALERT_EMAIL_TO: 'ops@example.test',
                ALERT_EMAIL_FROM: 'alerts@example.test',
            } : {}),
            ...extra,
        },
        db,
        mail,
    };
}

function upstream(status, body) {
    return () => new Response(JSON.stringify(body), {
        status, headers: { 'content-type': 'application/json' },
    });
}

const QUOTA_429 = upstream(429, {
    error: {
        message: 'You exceeded your current quota, please check your plan and billing details.',
        type: 'insufficient_quota',
        code: 'insufficient_quota',
    },
});
const RATE_429 = upstream(429, {
    error: { message: 'Rate limit reached for gpt-4o-mini', type: 'requests', code: 'rate_limit_exceeded' },
});
const SERVER_500 = upstream(500, { error: { message: 'upstream on fire' } });
const PAYMENT_402 = upstream(402, { message: 'Payment Required' });

function stubFetch(t, handler) {
    const original = globalThis.fetch;
    let calls = 0;
    globalThis.fetch = async (input, init) => { calls += 1; return handler(String(input), init); };
    t.after(() => { globalThis.fetch = original; });
    return () => calls;
}

async function callChat(env, { userId = USER, message = 'Tell me of Troy.' } = {}) {
    const worker = await loadWorker();
    const request = new Request('https://mythos.test/api/chat', {
        method: 'POST',
        headers: {
            'content-type': 'application/json',
            'x-user-id': userId,
            'x-character-id': 'odysseus',
            'x-visit-id': 'v_test',
        },
        body: JSON.stringify({ messages: [{ role: 'user', content: message }] }),
    });
    const pending = [];
    const res = await worker.fetch(request, env, {
        waitUntil(p) { pending.push(p); },
        passThroughOnException() {},
    });
    const text = await res.text();
    await Promise.all(pending);
    return { status: res.status, json: JSON.parse(text) };
}

function alertRow(db, key = 'openai:out_of_funds') {
    return db.prepare('SELECT * FROM ops_alerts WHERE alert_key = ?').get(key) ?? null;
}

test('insufficient_quota from OpenAI sends one email with the reason in it', async (t) => {
    const { env, db, mail } = alertEnv();
    stubFetch(t, QUOTA_429);

    const res = await callChat(env);
    assert.equal(res.status, 429, 'the user still gets the failure the provider gave');

    assert.equal(mail.sent.length, 1);
    const [msg] = mail.sent;
    assert.equal(msg.to, 'ops@example.test');
    assert.equal(msg.from.email, 'alerts@example.test');
    assert.match(msg.subject, /OpenAI is out of credit \(HTTP 429\)/);
    assert.match(msg.text, /insufficient_quota/);
    assert.match(msg.text, /exceeded your current quota/);
    assert.match(msg.text, /Character: +odysseus/);
    assert.ok(msg.html.includes('insufficient_quota'));

    const row = alertRow(db);
    assert.ok(row, 'throttle row written');
    assert.equal(row.seen_count, 1);
    assert.equal(row.sent_count, 1);
    assert.ok(row.last_sent_at);
});

test('a burst of failing turns produces one email, and the counter keeps running', async (t) => {
    const { env, db, mail } = alertEnv();
    stubFetch(t, QUOTA_429);

    for (let i = 0; i < 5; i++) await callChat(env);

    assert.equal(mail.sent.length, 1, 'throttled to one email inside the hour');
    const row = alertRow(db);
    assert.equal(row.seen_count, 5);
    assert.equal(row.sent_count, 1);
});

test('after the resend window a fresh email goes out, carrying the failure count', async (t) => {
    const { env, db, mail } = alertEnv();
    stubFetch(t, QUOTA_429);

    await callChat(env);
    await callChat(env);
    assert.equal(mail.sent.length, 1);

    // Age the throttle row past the hour, as time passing would.
    const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000).toISOString();
    db.prepare('UPDATE ops_alerts SET last_sent_at = ? WHERE alert_key = ?').run(twoHoursAgo, 'openai:out_of_funds');

    await callChat(env);
    assert.equal(mail.sent.length, 2);
    assert.match(mail.sent[1].text, /Failures since first seen: 3/);
    assert.equal(alertRow(db).sent_count, 2);
});

test('an ordinary rate limit is not an out-of-credit alert', async (t) => {
    const { env, db, mail } = alertEnv();
    stubFetch(t, RATE_429);
    const res = await callChat(env);
    assert.equal(res.status, 429);
    assert.equal(mail.sent.length, 0);
    assert.equal(alertRow(db), null);
});

test('a plain upstream 500 is not an out-of-credit alert', async (t) => {
    const { env, db, mail } = alertEnv();
    stubFetch(t, SERVER_500);
    const res = await callChat(env);
    assert.equal(res.status, 500);
    assert.equal(mail.sent.length, 0);
    assert.equal(alertRow(db), null);
});

test('HTTP 402 from any provider counts as out of funds', async (t) => {
    const { env, mail } = alertEnv();
    stubFetch(t, PAYMENT_402);
    await callChat(env);
    assert.equal(mail.sent.length, 1);
    assert.match(mail.sent[0].subject, /HTTP 402/);
    assert.match(mail.sent[0].text, /Payment Required/);
});

test('a successful reply never touches the alert path', async (t) => {
    const { env, db, mail } = alertEnv();
    stubFetch(t, upstream(200, {
        choices: [{ message: { role: 'assistant', content: 'Well met.' } }],
        usage: { prompt_tokens: 5, completion_tokens: 5, total_tokens: 10 },
    }));
    const res = await callChat(env);
    assert.equal(res.status, 200);
    assert.equal(mail.sent.length, 0);
    assert.equal(alertRow(db), null);
});

test('with the ops_alerts migration unapplied the email still goes out', async (t) => {
    const { env, mail } = alertEnv({ skip: ['0016_ops_alerts.sql'] });
    stubFetch(t, QUOTA_429);
    const res = await callChat(env);
    assert.equal(res.status, 429, 'the request itself is unaffected');
    assert.equal(mail.sent.length, 1, 'throttle unavailable falls through to send');
});

test('without the email binding configured the request still completes', async (t) => {
    const { env, db } = alertEnv({ email: false });
    stubFetch(t, QUOTA_429);
    const res = await callChat(env);
    assert.equal(res.status, 429);
    const row = alertRow(db);
    assert.ok(row, 'detection and the throttle row happen regardless');
    assert.equal(row.seen_count, 1);
});

test('an email provider failure cannot break the chat response', async (t) => {
    const { env } = alertEnv();
    env.ALERT_EMAIL = { async send() { throw new Error('smtp said no'); } };
    stubFetch(t, QUOTA_429);
    const res = await callChat(env);
    assert.equal(res.status, 429);
    assert.equal(res.json.error.code, 'insufficient_quota');
});
