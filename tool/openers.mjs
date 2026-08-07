#!/usr/bin/env node
// What each visitor opened with, and whether they tapped a starter or typed.
//
//   node tool/openers.mjs [hours]        # default 36
//
// The interesting column is Source. Every character profile carries an ordered
// `asks` list (lib/src/core/data/character_profiles.dart) which the chat screen
// shows as one-tap starters, so an opener that matches one exactly is a tap on
// that starter — "ask #2" is the second one in the list. Anything else was
// typed. site_visits records a starter_tap event but only stores the character
// in `detail`, never which starter, so the text match is the only way to know
// which one; the funnel events are used to cross-check, not to label.
//
// Reads the live D1 through wrangler, so it needs the sklabs Cloudflare login.
// conversation_logs holds real user message text — treat the output as private.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const hours = Number(process.argv[2] || 36);
if (!Number.isFinite(hours) || hours <= 0) {
    console.error('Usage: node tool/openers.mjs [hours]');
    process.exit(1);
}

// --- the starters, straight from the app's own source ------------------------
// Parsed rather than duplicated: if a character's asks change, the numbering
// here follows automatically, and an opener from an older wording simply stops
// matching instead of being mislabelled as a different ask.
function loadAsks() {
    const src = fs.readFileSync(
        path.join(repo, 'lib/src/core/data/character_profiles.dart'), 'utf8');
    const asks = {};
    const entry = /'([a-z_]+)':\s*CharacterProfile\(/g;
    let m;
    while ((m = entry.exec(src))) {
        const id = m[1];
        const rest = src.slice(m.index);
        const block = rest.slice(0, rest.indexOf('\n  ),'));
        const list = block.match(/asks:\s*\[([\s\S]*?)\]/);
        if (!list) continue;
        asks[id] = [...list[1].matchAll(/(['"])((?:\\.|(?!\1).)*)\1/g)]
            .map((s) => s[2].replace(/\\'/g, "'").replace(/\\"/g, '"'));
    }
    return asks;
}

function d1(sql) {
    const out = execFileSync('npx', [
        'wrangler', 'd1', 'execute', 'mymate2_db', '--remote', '--json', '--command', sql,
    ], { cwd: repo, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
    // wrangler prints its banner before the JSON payload.
    return JSON.parse(out.slice(out.indexOf('[')))[0].results;
}

// conversation_logs.created_at is ISO-8601 with a T and a Z, while
// site_visits.created_at is SQLite's "YYYY-MM-DD HH:MM:SS". Comparing the
// first form to datetime('now', ...) as plain strings is wrong within a single
// day ('T' sorts above ' '), so every comparison here goes through datetime().
const since = `datetime('now','-${hours} hours')`;

// One row per user per character: their first message in the window, plus what
// the funnel recorded for that visit. Real users only — user_<epoch> or
// google:<sub>; everything else is a smoke test or a QA pass (see
// docs/ANALYTICS_HANDOFF.md §4.5).
const rows = d1(`
    SELECT c.user_id,
           c.scenario,
           c.user_message,
           datetime(c.created_at) AS at,
           c.status,
           c.visit_id,
           EXISTS (SELECT 1 FROM site_visits v
                    WHERE v.visit_id = c.visit_id AND v.event = 'starter_tap') AS tapped,
           EXISTS (SELECT 1 FROM site_visits v
                    WHERE v.visit_id = c.visit_id AND v.event = 'input_typed') AS typed
    FROM conversation_logs c
    WHERE datetime(c.created_at) >= ${since}
      AND (c.user_id LIKE 'user\\_%' ESCAPE '\\' OR c.user_id LIKE 'google:%')
      AND c.user_id NOT LIKE 'user\\_test\\_%' ESCAPE '\\'
      AND c.created_at = (
          SELECT MIN(c2.created_at) FROM conversation_logs c2
           WHERE c2.user_id = c.user_id AND c2.scenario = c.scenario
             AND datetime(c2.created_at) >= ${since})
    ORDER BY c.created_at
`);

const asksById = loadAsks();
// scenario is a display name ("Penelope (Queen of Ithaca)"); the asks are keyed
// by character id.
const idFor = (scenario) => String(scenario || '').split(' (')[0].trim().toLowerCase();

const users = new Map();
const table = rows.map((r) => {
    if (!users.has(r.user_id)) users.set(r.user_id, users.size + 1);
    const id = idFor(r.scenario);
    const asks = asksById[id] || [];
    const i = asks.findIndex((a) => a === r.user_message);
    let source = i >= 0 ? `ask #${i + 1}` : 'typed';
    // A starter_tap with no matching ask text means the wording moved on since
    // that visit; say so rather than silently calling a tap a typed message.
    if (i < 0 && r.tapped && !r.typed) source = 'starter (unmatched)';
    return {
        user: `User-${users.get(r.user_id)} → ${id ? id[0].toUpperCase() + id.slice(1) : '?'}`,
        opener: r.user_message.replace(/\s+/g, ' ').trim(),
        source,
        at: r.at,
        status: r.status,
    };
});

if (!table.length) {
    console.log(`No opening messages from real users in the last ${hours}h.`);
    const failed = d1(`
        SELECT failure_reason, COUNT(*) AS n FROM site_visits
         WHERE event = 'send_failed' AND datetime(created_at) >= ${since}
         GROUP BY failure_reason`);
    const tried = d1(`
        SELECT COUNT(*) AS n FROM site_visits
         WHERE event = 'first_message' AND datetime(created_at) >= ${since}`)[0].n;
    // An empty table has two very different causes: nobody wrote anything, or
    // everybody's message failed. Say which.
    if (failed.length) {
        console.log(`\n${tried} message attempt(s), and ${failed.map((f) => `${f.n} send_failed (${f.failure_reason})`).join(', ')}.`);
        console.log('Messages are failing before they can be logged — check the chat pipeline, not the query.');
    }
    process.exit(0);
}

const w = (k, min) => Math.max(min, ...table.map((r) => r[k].length));
const cols = [['user', 'User', 20], ['opener', 'Opener', 30], ['source', 'Source', 6]];
const line = (cells) => '| ' + cells.map(([v, n]) => v.padEnd(n)).join(' | ') + ' |';
console.log(line(cols.map(([k, h, m]) => [h, w(k, m)])));
console.log('|' + cols.map(([k, , m]) => '-'.repeat(w(k, m) + 2)).join('|') + '|');
for (const r of table) console.log(line(cols.map(([k, , m]) => [r[k], w(k, m)])));
console.log(`\n${table.length} opener(s) from ${users.size} user(s), last ${hours}h.`);
