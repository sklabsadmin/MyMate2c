// Test harness for the worker: a real SQLite database built from the real
// migrations, wrapped in a D1-shaped shim, with the real worker module on top.
//
// The point is that nothing here is a model of the production system — the
// schema comes from backend/migrations, the queries come from worker.js, and
// the pages come out of the same template functions the browser gets. A test
// that passes against a hand-written CREATE TABLE proves only that the test
// agrees with itself; this one fails when a migration and a query disagree,
// which is the failure that actually happens.
//
// No dependencies: node:sqlite and node:test are both built in.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const MIGRATIONS_DIR = path.join(HERE, '..', 'migrations');
const WORKER_PATH = path.join(HERE, '..', 'src', 'worker.js');

export const ADMIN_TOKEN = 'test-admin-token';
export const ADMIN_AUTH = 'Basic ' + Buffer.from('admin:' + ADMIN_TOKEN).toString('base64');

/// Every migration, in the order wrangler applies them (filename order — which
/// is why the two 0003 files are harmless and the two 0008 files across
/// branches are not).
export function migrationFiles() {
    return fs.readdirSync(MIGRATIONS_DIR)
        .filter((name) => name.endsWith('.sql'))
        .sort();
}

/// An in-memory database with the full migration history applied.
///
/// `skip` drops named migrations, which is how the "table does not exist yet"
/// paths are tested — deploy_log is unapplied on production until someone runs
/// it, and every route that touches it has to survive that.
export function freshDb({ skip = [] } = {}) {
    const db = new DatabaseSync(':memory:');
    for (const name of migrationFiles()) {
        if (skip.includes(name)) continue;
        db.exec(fs.readFileSync(path.join(MIGRATIONS_DIR, name), 'utf8'));
    }
    return db;
}

/// The subset of the D1 API worker.js actually uses: prepare().bind().all() /
/// .first() / .run(). Deliberately not a full D1 emulation — an incomplete
/// shim that throws on an unsupported call is better than a permissive one
/// that silently diverges.
export function d1(db) {
    return {
        prepare(sql) {
            let bound = [];
            const stmt = {
                bind(...args) {
                    // D1 accepts booleans and undefined; node:sqlite does not.
                    bound = args.map((v) => {
                        if (v === undefined || v === null) return null;
                        if (typeof v === 'boolean') return v ? 1 : 0;
                        return v;
                    });
                    return stmt;
                },
                all() { return { results: db.prepare(sql).all(...bound) }; },
                first() { return db.prepare(sql).get(...bound) ?? null; },
                run() { return db.prepare(sql).run(...bound); },
            };
            return stmt;
        },
    };
}

let workerModule = null;

/// The real worker, imported once. Cached because the module is large and its
/// top-level constants are immutable — every test gets its own database, not
/// its own copy of the code.
export async function loadWorker() {
    if (!workerModule) {
        workerModule = await import(new URL('file://' + WORKER_PATH));
    }
    return workerModule.default;
}

/// Drives a request through the worker exactly as Cloudflare would, with admin
/// credentials attached.
export async function adminFetch(env, pathname, { method = 'GET', body } = {}) {
    const worker = await loadWorker();
    const headers = { Authorization: ADMIN_AUTH };
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    const request = new Request('https://mythos.test' + pathname, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
    });
    const res = await worker.fetch(request, env, { waitUntil() {}, passThroughOnException() {} });
    const text = await res.text();
    let json = null;
    try { json = JSON.parse(text); } catch (_) { /* html, csv, or prose */ }
    return { status: res.status, headers: res.headers, text, json };
}

/// A database seeded with the situations these tests exist to pin down. Times
/// are relative to now so that every "last N days" window covers them, and far
/// enough inside the boundaries that a slow test run cannot fall out of range.
///
/// The visits, and what each is for:
///
///   v_flap    backgrounded 25 times. The client stops writing hide rows at 20
///             (MAX_VISIBILITY_EVENTS) and keeps counting, so anything that
///             counts rows reports 20 and is wrong.
///   v_killed  destroyed while backgrounded: hide checkpoints, no leave row.
///             Everything about how it ended has to come off the checkpoints.
///   v_old     a leave row from before migration 0009: it reported an ending,
///             but not which kind. Distinct from v_killed, which reported none.
///   v_quiet   arrived and did nothing at all.
export function seed(db) {
    const base = Date.now() - 2 * 60 * 60 * 1000;
    const at = (offsetSeconds) =>
        new Date(base + offsetSeconds * 1000).toISOString().slice(0, 19).replace('T', ' ');
    const isoAt = (offsetSeconds) => new Date(base + offsetSeconds * 1000).toISOString();

    const insertVisit = db.prepare(`
        INSERT INTO site_visits (
            id, visit_id, event, created_at, path, source, country, user_agent,
            duration_ms, detail, app_user_id, viewport_w, viewport_h,
            visible_ms, hide_count, exit_mode, nav_type, failure_reason
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);
    let rowId = 0;
    const visit = (visitId, event, offset, extra = {}) => {
        insertVisit.run(
            `row-${rowId++}`, visitId, event, at(offset),
            extra.path ?? '/c/calypso', extra.source ?? 'ig',
            // `in`, not `??`: a visit the edge could not place has country
            // NULL on purpose, and ?? would quietly hand it the default.
            'country' in extra ? extra.country : 'GB',
            extra.ua ?? 'Mozilla/5.0 (iPhone) FBAV/1.0',
            extra.durationMs ?? null, extra.detail ?? null, extra.appUserId ?? null,
            extra.vw ?? null, extra.vh ?? null, extra.visibleMs ?? null,
            extra.hideCount ?? null, extra.exitMode ?? null, extra.navType ?? null,
            extra.failureReason ?? null
        );
    };

    // v_flap — 25 backgroundings, only 20 of them written as rows.
    visit('v_flap', 'arrive', 0, { vw: 390, vh: 600, navType: 'reload' });
    visit('v_flap', 'app_ready', 3, { durationMs: 3100 });
    visit('v_flap', 'character_tap', 5, { detail: 'calypso', appUserId: 'user_1700000000000' });
    for (let i = 1; i <= 20; i++) {
        visit('v_flap', 'hide', 10 + i, { durationMs: (10 + i) * 1000, visibleMs: i * 400, hideCount: i });
        visit('v_flap', 'show', 10 + i, { durationMs: 250 });
    }
    visit('v_flap', 'first_message', 40, { detail: 'calypso', appUserId: 'user_1700000000000' });
    visit('v_flap', 'leave', 120, { durationMs: 120000, visibleMs: 61000, hideCount: 25, exitMode: 'hidden' });

    // v_killed — no leave row at all.
    visit('v_killed', 'arrive', 200, { vw: 430, vh: 930, navType: 'navigate', country: 'US' });
    visit('v_killed', 'character_tap', 205, { detail: 'zeus', appUserId: 'user_1700000000001' });
    for (let i = 1; i <= 3; i++) visit('v_killed', 'screen_ping', 205 + i, { detail: 'zeus' });
    visit('v_killed', 'hide', 230, { durationMs: 30000, visibleMs: 21000, hideCount: 3 });

    // v_old — pre-0009 ending: a leave row carrying none of the new columns.
    visit('v_old', 'arrive', 300, { vw: 1440, country: 'MY' });
    visit('v_old', 'character_tap', 305, { detail: 'penelope', appUserId: 'user_1700000000002' });
    visit('v_old', 'leave', 330, { durationMs: 30000 });

    // v_quiet — arrived, did nothing, and the edge could not place it.
    visit('v_quiet', 'arrive', 400, { path: '/', country: null });

    const insertLog = db.prepare(`
        INSERT INTO conversation_logs (
            id, created_at, user_id, chat_id, scenario, model, status, status_code,
            user_message, assistant_message, request_messages_json, total_tokens,
            visit_id, latency_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);
    const message = (id, offset, userId, chat, status, code, latency, visitId) => {
        insertLog.run(id, isoAt(offset), userId, chat, chat, 'gpt-4o', status, code,
            'hello there', status === 'completed' ? 'well met' : null, '[]', 120, visitId, latency);
    };
    message('m1', 45, 'user_1700000000000', 'Calypso (Nymph of Ogygia)', 'completed', 200, 2400, 'v_flap');
    // The slow one. Every "slowest reply" assertion is about this row.
    message('m2', 60, 'user_1700000000000', 'Calypso (Nymph of Ogygia)', 'completed', 200, 14300, 'v_flap');
    // Pre-0007: no latency recorded, which must read as unknown and never as 0.
    message('m3', 320, 'user_1700000000002', 'Penelope (Queen of Ithaca)', 'ai_error', 500, null, 'v_old');

    return db;
}

/// A ready-to-use environment: seeded database, admin token, nothing else.
/// Anything the worker needs beyond D1 is deliberately absent, so a test that
/// starts depending on OpenAI or a session secret fails loudly rather than
/// reaching for a real one.
export function testEnv({ skip = [] } = {}) {
    const db = seed(freshDb({ skip }));
    return { env: { CHAT_LOGS_DB: d1(db), ADMIN_TOKEN }, db };
}
