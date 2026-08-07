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

// --- what counts as a tap ----------------------------------------------------
// The same generated file the worker's sessions page uses, rather than a second
// parser over the Dart source. Keeping two of those was how this tool ended up
// blind to Calypso's quick replies after the worker had already learned them:
// it could see the funnel had recorded a tap, and still had to report it as
// unmatched. Regenerate with `npm run gen:starters`.
const { CHARACTER_ASKS, CHARACTER_QUICK_REPLY_SETS, DEFAULT_STARTERS, SHARED_TAPS } =
    await import(path.join(repo, 'backend/src/starters.generated.js'));

/// Names the tap: which ask it was, or how far into a scripted conversation the
/// visitor had walked before saying this. Returns null for anything that was
/// not on offer, which is what "typed" means.
function labelFor(text, characterId) {
    const asks = CHARACTER_ASKS[characterId] || [];
    const ask = asks.indexOf(text);
    if (ask >= 0) return `ask #${ask + 1}`;

    const sets = CHARACTER_QUICK_REPLY_SETS[characterId] || [];
    for (let i = 0; i < sets.length; i++) {
        if (sets[i].includes(text)) return `quick reply, set ${i + 1}`;
    }

    if (SHARED_TAPS.includes(text)) return 'photo button';

    // Only for characters with no profile of their own — everyone else has
    // asks, and a match here would be a coincidence of wording.
    if (!asks.length) {
        const i = DEFAULT_STARTERS.indexOf(text);
        if (i >= 0) return `starter #${i + 1}`;
    }
    return null;
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

// scenario is a display name ("Penelope (Queen of Ithaca)"); the starters are
// keyed by character id.
const idFor = (scenario) => String(scenario || '').split(' (')[0].trim().toLowerCase();

const users = new Map();
const table = rows.map((r) => {
    if (!users.has(r.user_id)) users.set(r.user_id, users.size + 1);
    const id = idFor(r.scenario);
    const label = labelFor(r.user_message, id);
    let source = label || 'typed';
    // A starter_tap the text cannot account for means the wording moved on
    // since that visit, or starters.generated.js is stale. Say so rather than
    // silently calling a tap a typed message.
    if (!label && r.tapped && !r.typed) source = 'starter (unmatched)';
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
