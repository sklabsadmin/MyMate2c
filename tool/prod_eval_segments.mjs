#!/usr/bin/env node
//
// The +68 question, asked properly: prod_eval.mjs prints one funnel for one
// window, but the window now straddles deploys that change who the entry card
// is even shown to. a9813f1 (+68) widened the card's denominator from "empty
// history" to "never spoken", so an entry rate quoted across that boundary
// mixes two different questions. This script segments every visit by the
// deploy it arrived under and prints the funnel per segment.
//
//   MYMATE_ADMIN_TOKEN=... node tool/prod_eval_segments.mjs [hours]
//
// Defaults to 48 hours: wide enough to hold the whole 1.7.1 era (+66 shipped
// the card on 2026-08-17) on both sides of the +68 boundary.
//
// What a deploy boundary does and does not mean:
//
//   * deployed_at says when the NEW bundle became available, not when devices
//     started running it. A device that cached an older bundle keeps running
//     it — the first night of 1.7.1, devices still on 1.7.0 auto-played the
//     monologue for hours. Time segments are therefore contaminated by stale
//     bundles, and the contamination is measured here, not assumed away:
//       - message_delivery.app_version names the exact bundle for any visit
//         that rendered at least one bubble (present once the worker with the
//         wider export-all is deployed; the script says when it is not).
//       - a visit that reached a character screen, was never shown the card,
//         and still engaged is running a bundle from before the card existed
//         (≤ +65) — the card holds the input back on every later bundle.
//   * site_visits itself records no version anywhere. That is the gap this
//     script works around, and the reason the workarounds above exist at all.
//
// Inherits both corrections from prod_eval.mjs: visible_ms not duration_ms,
// and character_tap meaning "reached a screen", never engagement.
//
import process from 'node:process';

const HOST = process.env.MYMATE_ADMIN_HOST || 'logs.deeplovepoems.com';
const TOKEN = process.env.MYMATE_ADMIN_TOKEN;
const HOURS = Math.min(Math.max(parseInt(process.argv[2] || '48', 10) || 48, 1), 24 * 90);

if (!TOKEN) {
    console.error('MYMATE_ADMIN_TOKEN is not set. Export it for this command only:');
    console.error('  MYMATE_ADMIN_TOKEN=... node tool/prod_eval_segments.mjs 48');
    process.exit(2);
}

const auth = 'Basic ' + Buffer.from(`admin:${TOKEN}`).toString('base64');
async function get(path) {
    const res = await fetch(`https://${HOST}${path}`, { headers: { Authorization: auth } });
    if (!res.ok) {
        console.error(`${res.status} from ${HOST}${path} — 401 means the token is wrong or has been rotated.`);
        process.exit(1);
    }
    return res.json();
}

// deploy_log rows and site_visits rows write "2026-08-18 10:33:12";
// conversation_logs writes ISO-8601 with T and Z. Both are UTC; only the
// separator differs. Everything is compared as epoch millis, never as strings
// across the two formats — "T" sorts above " " and would misplace every row.
const epoch = (s) => s ? Date.parse(s.includes('T') ? s : s.replace(' ', 'T') + 'Z') : NaN;
const hhmm = (ms) => new Date(ms).toISOString().slice(5, 16).replace('T', ' ');
const pct = (n, d) => (d ? (100 * n / d).toFixed(1) + '%' : '-');

// Small-n honesty: 3/316 and 0/12 both deserve an interval, not a point.
function wilson(k, n, z = 1.96) {
    if (!n) return null;
    const p = k / n, z2 = z * z, denom = 1 + z2 / n;
    const centre = p + z2 / (2 * n);
    const spread = z * Math.sqrt((p * (1 - p) + z2 / (4 * n)) / n);
    return [Math.max(0, (centre - spread) / denom), Math.min(1, (centre + spread) / denom)];
}
const ci = (k, n) => {
    const w = wilson(k, n);
    return w ? `[${(100 * w[0]).toFixed(1)}–${(100 * w[1]).toFixed(1)}%]` : '';
};

const [dump, deploysRes] = await Promise.all([
    get(`/api/admin/export-all?hours=${HOURS}`),
    // The full deploy history, not the windowed rows: the deploy that governs
    // the start of the window may itself be older than the window.
    get('/api/admin/deploys?limit=30'),
]);

const sv = dump.tables?.site_visits;
if (!sv) { console.error('export-all returned no site_visits table'); process.exit(1); }
if (sv.truncated) console.log('!! site_visits hit the export cap — this window is INCOMPLETE.');

// ---------------------------------------------------------------- deploys --
// Only deploys that change what the visitor's device runs create segments; a
// worker-only deploy changes the API under every bundle at once.
const deploys = (deploysRes.deploys || [])
    .map((d) => ({ ...d, at: epoch(d.deployed_at) }))
    .filter((d) => Number.isFinite(d.at))
    .sort((a, b) => a.at - b.at);
const appDeploys = deploys.filter((d) => d.target !== 'worker');

console.log(`window ${dump.window_hours}h   site_visits ${sv.rows.length} rows   generated ${dump.generated_at}`);
console.log('\n== deploy timeline (UTC, ** = changes what devices run) ==');
const windowStart = Date.now() - HOURS * 3600 * 1000;
for (const d of deploys.filter((d) => d.at >= windowStart - 36 * 3600 * 1000)) {
    const mark = d.target === 'worker' ? '  ' : '**';
    console.log(`  ${mark} ${hhmm(d.at)}  ${d.version.padEnd(12)} ${d.target || '?'}  ${d.notes || ''}`);
}
if (!appDeploys.length) console.log('  (no app deploys recorded at all — segmentation impossible)');

// ------------------------------------------------------------------ visits --
const visits = new Map();
for (const r of sv.rows) {
    let v = visits.get(r.visit_id);
    if (!v) visits.set(r.visit_id, (v = { ev: new Map() }));
    let list = v.ev.get(r.event);
    if (!list) v.ev.set(r.event, (list = []));
    list.push(r);
}

// TH is the developer's home; is_dev is the developer anywhere else —
// the ?dev=1 marker rides every event, so one flagged row damns the visit.
const all = [...visits.values()].filter((v) => v.ev.get('arrive')?.[0]?.country !== 'TH'
    && ![...v.ev.values()].flat().some((r) => r.is_dev === 1));
const has = (v, e) => v.ev.has(e);
for (const v of all) {
    const arrive = v.ev.get('arrive')?.[0];
    const ua = arrive?.user_agent || '';
    v.client = /Instagram/.test(ua) ? 'instagram'
        : /FBAN|FBAV/.test(ua) ? 'facebook'
            : ua ? 'browser' : 'unknown';
    // Arrival time decides the segment. A visit whose arrive row fell outside
    // the window still has rows in it; its earliest row stands in.
    const times = [...v.ev.values()].flat().map((r) => epoch(r.created_at)).filter(Number.isFinite);
    v.at = arrive ? epoch(arrive.created_at) : Math.min(...times);
    v.id = [...v.ev.values()][0][0].visit_id;
    const leave = v.ev.get('leave')?.[0];
    const hides = v.ev.get('hide') || [];
    v.visible = leave?.visible_ms ?? (hides.length ? Math.max(...hides.map((h) => h.visible_ms || 0)) : null);
    v.exitMode = leave?.exit_mode || null;
    v.engaged = has(v, 'input_typed') || has(v, 'starter_tap') || has(v, 'first_message');
    v.country = arrive?.country || '?';
}

// -------------------------------------------------------- bundle versions --
// Best source first: bundles since the beacon stamp carry app_version on
// every site_visits row, so any visit that wrote anything is versioned —
// decliners included. Older bundles fall back to message_delivery, which
// only exists for visits that rendered a bubble (tappers and auto-players).
const md = dump.tables?.message_delivery;
const versionOf = new Map();
if (md?.rows?.length) {
    for (const r of md.rows) {
        if (!r.visit_id || !r.app_version) continue;
        const set = versionOf.get(r.visit_id) || versionOf.set(r.visit_id, new Set()).get(r.visit_id);
        set.add(r.app_version);
    }
}
let direct = 0;
for (const v of all) {
    const own = [...v.ev.values()].flat().find((r) => r.app_version)?.app_version;
    if (own) { v.version = own; direct++; continue; }
    const set = versionOf.get(v.id);
    v.version = set ? [...set].sort().join(',') : null;
}
const versioned = all.filter((v) => v.version).length;
console.log(`\nbundle versions known for ${versioned}/${all.length} visits`
    + ` (${direct} from the beacon itself, ${versioned - direct} via message_delivery)`);
if (direct < versioned) {
    console.log('  delivery-receipt versions exist only for visits that rendered a bubble —');
    console.log('  never the card-decliners — so no rate may use them as a denominator.');
}
if (!md?.rows?.length) {
    console.log('!! message_delivery is not in this export — the deployed worker predates the');
    console.log('   wider export-all, so pre-stamp bundles cannot be versioned at all here.');
}

// ---------------------------------------------------------------- segments --
// A visit belongs to the newest app deploy at or before its arrival. Anything
// older than the first recorded app deploy is lumped as "(before first)".
const segOf = (v) => {
    let name = '(before first recorded app deploy)';
    for (const d of appDeploys) if (v.at >= d.at) name = d.version;
    return name;
};
const segments = new Map();
for (const v of all) {
    const s = segOf(v);
    (segments.get(s) || segments.set(s, []).get(s)).push(v);
}

function funnel(vs, label) {
    const arrivals = vs.filter((v) => has(v, 'arrive'));
    const reached = vs.filter((v) => has(v, 'character_tap'));
    const shown = vs.filter((v) => has(v, 'entry_shown'));
    const tapped = vs.filter((v) => has(v, 'entry_tap'));
    const engaged = vs.filter((v) => v.engaged);
    console.log(`\n== ${label} ==   ${vs.length} visits, ${arrivals.length} arrivals`);
    for (const [name, n] of [
        ['app_ready', vs.filter((v) => has(v, 'app_ready')).length],
        ['character_tap (reached a screen, NOT a tap)', reached.length],
        ['entry_shown', shown.length],
        ['entry_tap', tapped.length],
        ['engaged (type/starter/send)', engaged.length],
        ['first_message', vs.filter((v) => has(v, 'first_message')).length],
    ]) console.log(String(n).padStart(6), pct(n, arrivals.length).padStart(7), name);
    console.log(`ENTRY GATE  ${tapped.length}/${shown.length} = ${pct(tapped.length, shown.length)} ${ci(tapped.length, shown.length)}`);
    // The fix's own signature. +68 shows the card to everyone who never spoke,
    // so this ratio rises with +68 penetration; the gap that remains is stale
    // bundles plus visitors who left before the card mounted.
    console.log(`shown/reached  ${shown.length}/${reached.length} = ${pct(shown.length, reached.length)}`);
    // Bundles from before the card existed (≤ +65): the card holds the input
    // back on every later bundle, so engagement without a card row means the
    // device never ran one. (A returning visitor who spoke on an earlier visit
    // is the benign case inside this count — rare at a ~1% engagement base.)
    const ghosts = vs.filter((v) => v.engaged && !has(v, 'entry_shown') && !has(v, 'entry_tap'));
    if (ghosts.length) console.log(`engaged with no card ever shown  ${ghosts.length}  <- pre-card bundle (or returning speaker)`);
    const byClient = {};
    for (const v of vs) {
        const c = (byClient[v.client] ||= { n: 0, shown: 0, tapped: 0, engaged: 0 });
        c.n++;
        if (has(v, 'entry_shown')) c.shown++;
        if (has(v, 'entry_tap')) c.tapped++;
        if (v.engaged) c.engaged++;
    }
    for (const [k, c] of Object.entries(byClient).sort((a, z) => z[1].n - a[1].n)) {
        console.log(`   ${String(c.n).padStart(5)} ${k.padEnd(10)} entry ${c.tapped}/${c.shown} ${pct(c.tapped, c.shown)}   engaged ${c.engaged} ${pct(c.engaged, c.n)}`);
    }
    if (versionOf.size) {
        const mix = {};
        for (const v of vs) if (v.version) mix[v.version] = (mix[v.version] || 0) + 1;
        const parts = Object.entries(mix).sort((a, z) => z[1] - a[1]).map(([k, n]) => `${k}:${n}`);
        if (parts.length) console.log(`   versions among bubble-rendering visits: ${parts.join('  ')}`);
    }
}

// Oldest segment first, so the story reads forward in time.
const segNames = [...segments.keys()].sort((a, b) => {
    const da = appDeploys.find((d) => d.version === a), db = appDeploys.find((d) => d.version === b);
    return (da?.at ?? 0) - (db?.at ?? 0);
});
for (const name of segNames) funnel(segments.get(name), `arrived under ${name}`);

// ------------------------------------------------- penetration, hour by hour --
// How fast the newest bundle actually took over, which is the number that says
// when the post-deploy segment stops being contaminated. Behavioural proxy
// (shown/reached) always; exact versions when the export carries them.
const latest = appDeploys[appDeploys.length - 1];
if (latest && Number.isFinite(latest.at)) {
    const post = all.filter((v) => v.at >= latest.at).sort((a, b) => a.at - b.at);
    if (post.length) {
        console.log(`\n== hourly since ${latest.version} deployed ${hhmm(latest.at)} ==`);
        console.log('   hour  visits  reached  shown  shown/reached   versions seen');
        const byHour = new Map();
        for (const v of post) {
            const h = Math.floor((v.at - latest.at) / 3600000);
            (byHour.get(h) || byHour.set(h, []).get(h)).push(v);
        }
        for (const [h, vs] of [...byHour.entries()].sort((a, b) => a[0] - b[0])) {
            const reached = vs.filter((v) => has(v, 'character_tap')).length;
            const shown = vs.filter((v) => has(v, 'entry_shown')).length;
            const mix = {};
            for (const v of vs) if (v.version) mix[v.version] = (mix[v.version] || 0) + 1;
            const vsStr = Object.entries(mix).sort((a, z) => z[1] - a[1]).map(([k, n]) => `${k}:${n}`).join(' ') || '-';
            console.log(`   +${String(h).padStart(2)}h ${String(vs.length).padStart(7)} ${String(reached).padStart(8)} ${String(shown).padStart(6)} ${pct(shown, reached).padStart(14)}   ${vsStr}`);
        }
    } else {
        console.log(`\n(no visits since the ${latest.version} deploy at ${hhmm(latest.at)} yet)`);
    }
}

// ------------------------------------------------------------ tapper depth --
// The counter-signal from 2026-08-18 was 2 of 3 tappers engaging, one for 92
// visible seconds — a direction, not a rate. This is that question against
// every tapper in the window, with the conversation joined on.
const logs = dump.tables?.conversation_logs?.rows || [];
const turnsOf = new Map();
for (const r of logs) {
    if (!r.visit_id) continue;
    const t = turnsOf.get(r.visit_id) || turnsOf.set(r.visit_id, { n: 0, ok: 0 }).get(r.visit_id);
    t.n++;
    if (r.status === 'completed') t.ok++;
}

const tappers = all.filter((v) => has(v, 'entry_tap')).sort((a, b) => a.at - b.at);
const shownAll = all.filter((v) => has(v, 'entry_shown'));
console.log(`\n== every entry_tap in the window: does opting in predict depth? ==`);
if (!tappers.length) {
    console.log('   no tappers in this window.');
} else {
    console.log('   arrived (UTC)   client     ver          src      visible  engaged  turns(ok)  chars');
    for (const v of tappers.slice(0, 60)) {
        const src = (v.ev.get('entry_tap')[0].detail || '').split('#')[1] || '?';
        const chars = [...new Set((v.ev.get('entry_tap') || []).concat(v.ev.get('character_tap') || []).map((r) => (r.detail || '').split('#')[0]))].join(',');
        const t = turnsOf.get(v.id);
        console.log(`   ${hhmm(v.at)}     ${v.client.padEnd(10)} ${(v.version || '?').padEnd(12)} ${src.padEnd(8)} ${(v.visible != null ? (v.visible / 1000).toFixed(0) + 's' : '?').padStart(7)} ${(v.engaged ? 'yes' : 'no').padStart(8)} ${String(t ? `${t.n}(${t.ok})` : '0').padStart(10)}  ${chars}`);
    }
    if (tappers.length > 60) console.log(`   ... and ${tappers.length - 60} more`);

    const k = tappers.filter((v) => v.engaged).length;
    const fm = tappers.filter((v) => has(v, 'first_message')).length;
    console.log(`\n   engaged after tapping   ${k}/${tappers.length} = ${pct(k, tappers.length)} ${ci(k, tappers.length)}`);
    console.log(`   sent a first message    ${fm}/${tappers.length} = ${pct(fm, tappers.length)} ${ci(fm, tappers.length)}`);
    const med = (arr) => {
        const a = arr.filter((x) => x != null).sort((x, y) => x - y);
        return a.length ? (a[a.length >> 1] / 1000).toFixed(1) + 's' : '-';
    };
    const decliners = shownAll.filter((v) => !has(v, 'entry_tap'));
    console.log(`   visible time, median    tappers ${med(tappers.map((v) => v.visible))}   vs decliners ${med(decliners.map((v) => v.visible))}`);
    // The comparison that decides "upstream vs first screen": if the few who
    // opt in go deep while the rate stays flat two designs running, the screen
    // is not the lever — who arrives is.
}
