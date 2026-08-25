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
//   MYMATE_ADMIN_TOKEN=... node tool/prod_eval.mjs [hours] [--split=auto|none|"YYYY-MM-DD HH:MM:SS"]
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
// And a third, which is why --split exists:
//
//   3. There is no bundle version on a visit. site_visits has no such column,
//      the splash beacon runs before Flutter exists, and the only version
//      column anywhere (message_delivery.app_version) is written by senders,
//      who are the numerator. So "segment on bundle version" is done here on
//      DEPLOY TIME: the +68 row in deploy_log splits the window into before
//      and after. That is not the same thing — a device can keep serving the
//      old bundle from cache after the deploy — so the after-segment also
//      reports the old bundle's fingerprint: visitors who reached a screen,
//      were not initialMessage arrivals, never spoke, and were NOT asked. On
//      +68 that population should be close to zero; whatever remains is old
//      bundle churn (or returning visitors who spoke on an earlier visit),
//      and says how much the "after" segment is still contaminated.
//
import process from 'node:process';

const HOST = process.env.MYMATE_ADMIN_HOST || 'logs.deeplovepoems.com';
const TOKEN = process.env.MYMATE_ADMIN_TOKEN;
const argv = process.argv.slice(2);
const positional = argv.filter((a) => !a.startsWith('--'));
const HOURS = Math.min(Math.max(parseInt(positional[0] || '24', 10) || 24, 1), 24 * 90);
const splitArg = (argv.find((a) => a.startsWith('--split=')) || '--split=auto').slice('--split='.length);
// Which deploy_log version marks the split when --split=auto. The default is
// the +68 denominator fix (a9813f1); pass --version=+69 to move it.
const SPLIT_VERSION = (argv.find((a) => a.startsWith('--version=')) || '--version=+68').slice('--version='.length);

// MYMATE_DUMP_FILE=path re-reads a saved export-all JSON instead of fetching,
// so a window can be pulled once and re-cut offline (and so this script can be
// exercised against a fixture without a token). MYMATE_SAVE_DUMP=path writes
// the fetched export there — outside the repo, please; it holds user messages.
let dump;
if (process.env.MYMATE_DUMP_FILE) {
    const { readFileSync } = await import('node:fs');
    dump = JSON.parse(readFileSync(process.env.MYMATE_DUMP_FILE, 'utf8'));
} else {
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
    dump = await res.json();
    if (process.env.MYMATE_SAVE_DUMP) {
        const { writeFileSync } = await import('node:fs');
        writeFileSync(process.env.MYMATE_SAVE_DUMP, JSON.stringify(dump));
        console.log(`saved export to ${process.env.MYMATE_SAVE_DUMP}`);
    }
}
const rows = dump.tables?.site_visits?.rows || [];
if (dump.tables?.site_visits?.truncated) {
    // 50k per table. Say so rather than quietly reporting a partial window.
    console.log('!! site_visits hit the export cap — this window is INCOMPLETE.');
}
const chatRows = dump.tables?.conversation_logs?.rows || [];
const deployRows = dump.tables?.deploy_log?.rows || [];

const pct = (n, d) => (d ? (100 * n / d).toFixed(1) + '%' : '-');
// SQLite default "YYYY-MM-DD HH:MM:SS"; a hand-typed deploy time may carry an
// ISO "T", and conversation_logs always does. Same string, so they compare.
const norm = (t) => String(t || '').replace('T', ' ').slice(0, 19);
const visits = new Map();
for (const r of rows) {
    let v = visits.get(r.visit_id);
    if (!v) visits.set(r.visit_id, (v = { ev: new Map(), at: null }));
    (v.ev.get(r.event) || v.ev.set(r.event, []).get(r.event)).push(r);
    const t = norm(r.created_at);
    if (!v.at || t < v.at) v.at = t;
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
    // /c/<id>?initialMessage= arrivals are not gated: their opener is sent for
    // them, so no entry_shown is ever expected for them.
    v.initialMessage = [...v.ev.values()].flat().some((r) => /(^|[?&])initialMessage=/.test(r.query || ''));
}

// Messages actually sent per visit, from conversation_logs joined on the
// x-visit-id the client stamps on /api/chat. Each row is one user turn.
const msgsByVisit = new Map();
for (const c of chatRows) {
    if (!c.visit_id) continue;
    msgsByVisit.set(c.visit_id, (msgsByVisit.get(c.visit_id) || 0) + 1);
}
for (const [id, v] of visits) v.messages = msgsByVisit.get(id) || 0;

console.log(`window ${dump.window_hours}h   site_visits ${rows.length}   visits ${all.length} (excl TH)`);
console.log(`span ${rows[rows.length - 1]?.created_at} -> ${rows[0]?.created_at}\n`);

// ---- deploys in the window, and where to split ---------------------------
if (deployRows.length) {
    console.log('== deploy_log rows in window ==');
    for (const d of [...deployRows].sort((a, z) => norm(a.deployed_at).localeCompare(norm(z.deployed_at)))) {
        console.log(`  ${norm(d.deployed_at)}  ${String(d.version).padEnd(12)} ${String(d.target || '').padEnd(8)} ${d.notes || ''}`);
    }
} else {
    console.log('== deploy_log: no rows in this window (the table is filled in by hand) ==');
}
let splitAt = null;
if (splitArg === 'auto') {
    const esc = SPLIT_VERSION.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const cands = deployRows
        .filter((d) => new RegExp(`${esc}(?![0-9])`).test(String(d.version)))
        // The Flutter bundle is what changed who gets asked; a worker-only row
        // for the same version number is not the boundary.
        .sort((a, z) => (/worker/i.test(a.target || '') ? 1 : 0) - (/worker/i.test(z.target || '') ? 1 : 0)
            || norm(a.deployed_at).localeCompare(norm(z.deployed_at)));
    if (cands.length) splitAt = norm(cands[0].deployed_at);
    else {
        console.log(`\n!! no deploy_log row for version ${SPLIT_VERSION} in this window — no segmentation.`);
        console.log(`   (pass --split="YYYY-MM-DD HH:MM:SS" to split on a time you know, or --version=+NN)`);
    }
} else if (splitArg !== 'none') {
    splitAt = norm(splitArg);
}
if (splitAt) console.log(`\nSPLIT at ${splitAt} UTC (arrive time; a visit is "after" if it arrived at or after this)`);

// ---- the report, once for the window and once per segment ----------------
const bucket = (ms) => ms == null ? 'unknown'
    : ms < 1000 ? '<1s' : ms < 5000 ? '1-5s' : ms < 15000 ? '5-15s'
        : ms < 35000 ? '15-35s' : ms < 90000 ? '35-90s' : '90s+';
const ORDER = ['<1s', '1-5s', '5-15s', '15-35s', '35-90s', '90s+', 'unknown'];
const median = (arr) => (arr.length ? arr[arr.length >> 1] : null);
const sec = (ms) => (ms == null ? '-' : (ms / 1000).toFixed(1) + 's');

function report(label, set, { full }) {
    console.log(`\n${'#'.repeat(70)}\n# ${label}   visits ${set.length}\n${'#'.repeat(70)}`);
    const arrivals = set.filter((v) => has(v, 'arrive'));
    const shown = set.filter((v) => has(v, 'entry_shown'));
    const tapped = set.filter((v) => has(v, 'entry_tap'));
    const reached = set.filter((v) => has(v, 'character_tap'));
    const engaged = set.filter((v) => v.engaged);

    console.log('== funnel ==');
    for (const [name, n] of [
        ['arrive', arrivals.length],
        ['app_ready', set.filter((v) => has(v, 'app_ready')).length],
        ['entry_shown', shown.length],
        ['entry_tap', tapped.length],
        ['character_tap (reached a screen, NOT a tap)', reached.length],
        ['engaged (type/starter/send)', engaged.length],
        ['first_message', set.filter((v) => has(v, 'first_message')).length],
    ]) console.log(String(n).padStart(6), pct(n, arrivals.length).padStart(7), name);

    // The one rate 1.7.1 exists to move: a denominator of people demonstrably asked.
    console.log(`\nENTRY GATE  ${tapped.length}/${shown.length} = ${pct(tapped.length, shown.length)}`);
    console.log(`  baseline to beat: 0.95% engaged (30 days to 2026-08-17, 3,490 visits, auto-playing screen)`);
    console.log(`ENGAGED AFTER TAPPING  ${tapped.filter((v) => v.engaged).length}/${tapped.length}`);

    // Who reached a screen but was never asked. Before +68 this is mostly the
    // suppressed cohort (old auto-played monologue in localStorage); after it,
    // it is the old bundle still being served, plus returning visitors who
    // spoke on an earlier visit, plus initialMessage arrivals (shown apart).
    const notShown = reached.filter((v) => !has(v, 'entry_shown'));
    const notShownIM = notShown.filter((v) => v.initialMessage);
    const notShownQuiet = notShown.filter((v) => !v.initialMessage && !v.engaged);
    const notShownEngaged = notShown.filter((v) => !v.initialMessage && v.engaged);
    console.log(`\nREACHED A SCREEN, NOT ASKED  ${notShown.length}/${reached.length} = ${pct(notShown.length, reached.length)}`);
    console.log(`  ${String(notShownIM.length).padStart(4)} initialMessage arrivals (never gated, by design)`);
    console.log(`  ${String(notShownQuiet.length).padStart(4)} silent and never asked — the old gate's cohort; after +68 this is old-bundle churn`);
    console.log(`  ${String(notShownEngaged.length).padStart(4)} engaged without a card — returning talkers, or an old bundle's auto-played screen`);

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

    if (full) {
        console.log('\n== time on a character screen — visible vs wall clock ==');
        for (const key of ['visible', 'wall']) {
            const b = {};
            for (const v of reached) b[bucket(v[key])] = (b[bucket(v[key])] || 0) + 1;
            const arr = reached.map((v) => v[key]).filter((x) => x != null).sort((a, c) => a - c);
            console.log(`\n-- ${key} -- median ${arr.length ? (arr[arr.length >> 1] / 1000).toFixed(1) : '-'}s  n=${arr.length}`);
            for (const k of ORDER) if (b[k]) console.log(String(b[k]).padStart(5), pct(b[k], reached.length).padStart(7), k);
        }
    } else {
        const arr = reached.map((v) => v.visible).filter((x) => x != null).sort((a, c) => a - c);
        console.log(`\nvisible time on a character screen: median ${sec(median(arr))}  n=${arr.length}`);
    }

    console.log('\n== client ==');
    const byClient = {};
    for (const v of set) {
        const c = (byClient[v.client] ||= { n: 0, shown: 0, tapped: 0, engaged: 0 });
        c.n++;
        if (has(v, 'entry_shown')) c.shown++;
        if (has(v, 'entry_tap')) c.tapped++;
        if (v.engaged) c.engaged++;
    }
    for (const [k, c] of Object.entries(byClient).sort((a, z) => z[1].n - a[1].n)) {
        console.log(String(c.n).padStart(5), k.padEnd(10), `entry ${c.tapped}/${c.shown} ${pct(c.tapped, c.shown)}   engaged ${c.engaged} ${pct(c.engaged, c.n)}`);
    }

    if (full) {
        console.log('\n== exit mode ==   (hidden = backgrounded, which is why wall clock lies)');
        const em = {};
        for (const v of set) if (v.exitMode) em[v.exitMode] = (em[v.exitMode] || 0) + 1;
        for (const [k, n] of Object.entries(em).sort((a, z) => z[1] - a[1])) console.log(String(n).padStart(5), pct(n, Object.values(em).reduce((x, y) => x + y, 0)).padStart(7), k);

        console.log('\n== country top 12 ==');
        const cc = {};
        for (const v of set) {
            const k = v.ev.get('arrive')?.[0]?.country || '?';
            cc[k] = (cc[k] || 0) + 1;
        }
        for (const [k, n] of Object.entries(cc).sort((a, z) => z[1] - a[1]).slice(0, 12)) console.log(String(n).padStart(5), k);
    }

    // Does opting in predict depth? Every tapper, one line each — at these
    // counts a table is more honest than a rate.
    console.log(`\n== opt-in -> depth: the ${tapped.length} who tapped in ==`);
    console.log('  when (UTC)           client     visible   wall     typed starter first_msg  msgs  exit');
    for (const v of [...tapped].sort((a, z) => a.at.localeCompare(z.at))) {
        console.log('  ' + [
            v.at.padEnd(20),
            v.client.padEnd(10),
            sec(v.visible).padStart(7),
            sec(v.wall).padStart(7),
            (has(v, 'input_typed') ? 'y' : '.').padStart(6),
            (has(v, 'starter_tap') ? 'y' : '.').padStart(7),
            (has(v, 'first_message') ? 'y' : '.').padStart(9),
            String(v.messages).padStart(5),
            '  ' + (v.exitMode || '-'),
        ].join(' '));
    }
    const tv = tapped.map((v) => v.visible).filter((x) => x != null).sort((a, c) => a - c);
    const nv = shown.filter((v) => !has(v, 'entry_tap')).map((v) => v.visible).filter((x) => x != null).sort((a, c) => a - c);
    console.log(`  tapped: engaged ${tapped.filter((v) => v.engaged).length}/${tapped.length}, sent ${tapped.filter((v) => has(v, 'first_message')).length}/${tapped.length}, visible median ${sec(median(tv))}`);
    console.log(`  shown & did not tap: n=${shown.length - tapped.length}, visible median ${sec(median(nv))}, engaged ${shown.filter((v) => !has(v, 'entry_tap') && v.engaged).length} (should be ~0: the card blocks the chat)`);
}

report(`WHOLE WINDOW (${dump.window_hours}h)`, all, { full: true });
if (splitAt) {
    const before = all.filter((v) => v.at < splitAt);
    const after = all.filter((v) => v.at >= splitAt);
    report(`BEFORE ${splitAt} — old gate: card only over an empty history`, before, { full: false });
    report(`AFTER  ${splitAt} — +68: card for anyone who never spoke (time-based; old bundles may linger)`, after, { full: false });
    // Cache churn, hour by hour after the deploy: the share of quiet visitors
    // who reached a screen and were not asked. Falling toward zero is the old
    // bundle draining out of caches; flat is a fault.
    console.log('\n== after the split, hour by hour: reached / asked / not-asked-and-silent / tapped ==');
    const byHour = new Map();
    for (const v of after) {
        if (!has(v, 'character_tap')) continue;
        const h = v.at.slice(0, 13) + ':00';
        const b = byHour.get(h) || { reached: 0, shown: 0, quiet: 0, tapped: 0 };
        b.reached++;
        if (has(v, 'entry_shown')) b.shown++;
        else if (!v.initialMessage && !v.engaged) b.quiet++;
        if (has(v, 'entry_tap')) b.tapped++;
        byHour.set(h, b);
    }
    for (const [h, b] of [...byHour].sort()) {
        console.log(`  ${h}  reached ${String(b.reached).padStart(4)}  asked ${String(b.shown).padStart(4)}  not-asked-silent ${String(b.quiet).padStart(3)}  tapped ${String(b.tapped).padStart(3)}`);
    }
}
