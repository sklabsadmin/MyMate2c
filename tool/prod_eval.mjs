#!/usr/bin/env node
//
// Pulls a window of production analytics straight out of the worker and prints
// the funnel. Written because the obvious route does not work from a Claude
// Code session: api.cloudflare.com is not on the sandbox's egress allowlist, so
// `wrangler d1 execute --remote` dies at the proxy with a 403 on CONNECT before
// any token is presented. The worker's own admin API is on a normal public
// hostname and answers fine, and /api/admin/export-all returns the raw rows —
// so the aggregation happens here instead of in D1.
//
//   MYMATE_ADMIN_TOKEN=... node tool/prod_eval.mjs [hours]
//
// The token is the worker's ADMIN_TOKEN (Basic auth, any username). It is read
// from the environment and never written to disk by this script — do not paste
// it into a file in this repo.
//
// Two things about the data that this script exists to get right, because both
// have already produced a confidently wrong answer:
//
//   1. duration_ms is WALL CLOCK. On Meta in-app traffic 91% of exits are
//      exit_mode='hidden' — backgrounded, not closed — and the clock keeps
//      running in a browser nobody is looking at. Reading it as attention
//      turned a flat 5.2s into a triumphant 32.5s. visible_ms is the honest
//      column and everything below uses it.
//
//   2. character_tap is not a tap. It fires on landing on /c/<character>, so
//      it means "reached a character screen", and it appears in the same
//      breath as entry_shown. Engagement is input_typed / starter_tap /
//      first_message, and nothing else.
//
import process from 'node:process';

const HOST = process.env.MYMATE_ADMIN_HOST || 'logs.deeplovepoems.com';
const TOKEN = process.env.MYMATE_ADMIN_TOKEN;
const HOURS = Math.min(Math.max(parseInt(process.argv[2] || '24', 10) || 24, 1), 24 * 90);

if (!TOKEN) {
    console.error('MYMATE_ADMIN_TOKEN is not set. Export it for this command only:');
    console.error('  MYMATE_ADMIN_TOKEN=... node tool/prod_eval.mjs 24');
    process.exit(2);
}

const auth = 'Basic ' + Buffer.from(`admin:${TOKEN}`).toString('base64');
const url = `https://${HOST}/api/admin/export-all?hours=${HOURS}`;
const res = await fetch(url, { headers: { Authorization: auth } });
if (!res.ok) {
    console.error(`${res.status} from ${HOST} — 401 means the token is wrong or has been rotated.`);
    process.exit(1);
}
const dump = await res.json();
const rows = dump.tables?.site_visits?.rows || [];
if (dump.tables?.site_visits?.truncated) {
    // 50k per table. Say so rather than quietly reporting a partial window.
    console.log('!! site_visits hit the export cap — this window is INCOMPLETE.');
}

const pct = (n, d) => (d ? (100 * n / d).toFixed(1) + '%' : '-');
const visits = new Map();
for (const r of rows) {
    let v = visits.get(r.visit_id);
    if (!v) visits.set(r.visit_id, (v = { ev: new Map() }));
    (v.ev.get(r.event) || v.ev.set(r.event, []).get(r.event)).push(r);
}

// TH is the developer's own country, excluded the same way the admin pages do.
const all = [...visits.values()].filter((v) => v.ev.get('arrive')?.[0]?.country !== 'TH');
const has = (v, e) => v.ev.has(e);
for (const v of all) {
    const arrive = v.ev.get('arrive')?.[0];
    const ua = arrive?.user_agent || '';
    v.client = /Instagram/.test(ua) ? 'instagram'
        : /FBAN|FBAV/.test(ua) ? 'facebook'
            : ua ? 'browser' : 'unknown';
    const leave = v.ev.get('leave')?.[0];
    const hides = v.ev.get('hide') || [];
    // A visit that never left still reported visible time on each hide.
    v.visible = leave?.visible_ms ?? (hides.length ? Math.max(...hides.map((h) => h.visible_ms || 0)) : null);
    v.wall = leave?.duration_ms ?? (hides.length ? Math.max(...hides.map((h) => h.duration_ms || 0)) : null);
    v.exitMode = leave?.exit_mode || null;
    v.engaged = has(v, 'input_typed') || has(v, 'starter_tap') || has(v, 'first_message');
}

console.log(`window ${dump.window_hours}h   site_visits ${rows.length}   visits ${all.length} (excl TH)`);
console.log(`span ${rows[rows.length - 1]?.created_at} -> ${rows[0]?.created_at}\n`);

const arrivals = all.filter((v) => has(v, 'arrive'));
const shown = all.filter((v) => has(v, 'entry_shown'));
const tapped = all.filter((v) => has(v, 'entry_tap'));
const reached = all.filter((v) => has(v, 'character_tap'));
const engaged = all.filter((v) => v.engaged);

console.log('== funnel ==');
for (const [label, n] of [
    ['arrive', arrivals.length],
    ['app_ready', all.filter((v) => has(v, 'app_ready')).length],
    ['entry_shown', shown.length],
    ['entry_tap', tapped.length],
    ['character_tap (reached a screen, NOT a tap)', reached.length],
    ['engaged (type/starter/send)', engaged.length],
    ['first_message', all.filter((v) => has(v, 'first_message')).length],
]) console.log(String(n).padStart(6), pct(n, arrivals.length).padStart(7), label);

// The one rate 1.7.1 exists to move: a denominator of people demonstrably asked.
console.log(`\nENTRY GATE  ${tapped.length}/${shown.length} = ${pct(tapped.length, shown.length)}`);
console.log(`  baseline to beat: 0.95% engaged (30 days to 2026-08-17, 3,490 visits, auto-playing screen)`);
console.log(`ENGAGED AFTER TAPPING  ${tapped.filter((v) => v.engaged).length}/${tapped.length}`);

// How fast the ask got on screen. Decides whether a low rate reads as
// "declined" or "never saw it" — those need opposite responses.
const shownAt = shown.map((v) => v.ev.get('entry_shown')[0].duration_ms).filter(Number.isFinite).sort((a, b) => a - b);
if (shownAt.length) {
    const q = (p) => (shownAt[Math.floor(shownAt.length * p)] / 1000).toFixed(1);
    console.log(`\nentry card on screen at: median ${q(0.5)}s  p75 ${q(0.75)}s  p90 ${q(0.9)}s`);
    let gone = 0;
    for (const v of shown) {
        const at = v.ev.get('entry_shown')[0].duration_ms;
        if (v.visible != null && Number.isFinite(at) && v.visible < at) gone++;
    }
    console.log(`  ${gone} of ${shown.length} (${pct(gone, shown.length)}) had less visible time than the card took to appear`);
}

const bucket = (ms) => ms == null ? 'unknown'
    : ms < 1000 ? '<1s' : ms < 5000 ? '1-5s' : ms < 15000 ? '5-15s'
        : ms < 35000 ? '15-35s' : ms < 90000 ? '35-90s' : '90s+';
const ORDER = ['<1s', '1-5s', '5-15s', '15-35s', '35-90s', '90s+', 'unknown'];
console.log('\n== time on a character screen — visible vs wall clock ==');
for (const key of ['visible', 'wall']) {
    const b = {};
    for (const v of reached) b[bucket(v[key])] = (b[bucket(v[key])] || 0) + 1;
    const arr = reached.map((v) => v[key]).filter((x) => x != null).sort((a, c) => a - c);
    console.log(`\n-- ${key} -- median ${arr.length ? (arr[arr.length >> 1] / 1000).toFixed(1) : '-'}s  n=${arr.length}`);
    for (const k of ORDER) if (b[k]) console.log(String(b[k]).padStart(5), pct(b[k], reached.length).padStart(7), k);
}

console.log('\n== client ==');
const byClient = {};
for (const v of all) {
    const c = (byClient[v.client] ||= { n: 0, shown: 0, tapped: 0, engaged: 0 });
    c.n++;
    if (has(v, 'entry_shown')) c.shown++;
    if (has(v, 'entry_tap')) c.tapped++;
    if (v.engaged) c.engaged++;
}
for (const [k, c] of Object.entries(byClient).sort((a, z) => z[1].n - a[1].n)) {
    console.log(String(c.n).padStart(5), k.padEnd(10), `entry ${c.tapped}/${c.shown} ${pct(c.tapped, c.shown)}   engaged ${c.engaged} ${pct(c.engaged, c.n)}`);
}

console.log('\n== exit mode ==   (hidden = backgrounded, which is why wall clock lies)');
const em = {};
for (const v of all) if (v.exitMode) em[v.exitMode] = (em[v.exitMode] || 0) + 1;
for (const [k, n] of Object.entries(em).sort((a, z) => z[1] - a[1])) console.log(String(n).padStart(5), pct(n, Object.values(em).reduce((x, y) => x + y, 0)).padStart(7), k);

console.log('\n== country top 12 ==');
const cc = {};
for (const v of all) {
    const k = v.ev.get('arrive')?.[0]?.country || '?';
    cc[k] = (cc[k] || 0) + 1;
}
for (const [k, n] of Object.entries(cc).sort((a, z) => z[1] - a[1]).slice(0, 12)) console.log(String(n).padStart(5), k);
