// Turns screen_ping tick counts into "which line of the script was on screen
// when they left".
//
// The admin pages can say a visitor left at 5.5 seconds. They cannot say what
// 5.5 seconds looked like. Because a scripted opening is deterministic — no
// network in the loop, every beat computed from the line's own word count —
// elapsed time maps exactly onto a line, so the tick count already carries that
// information and nothing new needs logging to recover it.
//
// Input is the timeline printed by test/odysseus_beat_map_dump.dart, which
// plays the real ChatScreen against flutter_test's virtual clock. Deliberately
// not a reimplementation of the pacing arithmetic: that would be a second copy
// to keep in sync with chat_screen.dart and the first thing to drift.
//
//   flutter test test/odysseus_beat_map_dump.dart | node tool/beat_map.mjs
//   flutter test test/odysseus_beat_map_dump.dart | node tool/beat_map.mjs ticks.tsv
//
// The optional second argument is a TSV of observed sessions, one per line,
// with the tick count in the 8th column — the shape the admin sessions table
// copies out. Given one, the map is weighted by what visitors actually did.
//
// Virtual-clock timings are a floor, not a promise. A backgrounded tab is
// throttled to 1Hz and quantises every delay to a whole second, so real
// visitors reach each line at this time or later, never sooner.
import { readFileSync } from "node:fs";

// Mirrors SCREEN_PING_* in backend/src/worker.js and chat_screen.dart. Ticks
// 1-20 are 500ms apart, 21-26 are 3s apart, and it stops at 26.
const P1_TICKS = 20, P1_INT = 0.5, P1_SECS = 10, P2_INT = 3, MAX_TICKS = 26;
const tickSeconds = (t) => (t <= P1_TICKS ? t * P1_INT : P1_SECS + (t - P1_TICKS) * P2_INT);

const raw = readFileSync(process.argv.includes("-") ? 0 : 0, "utf8");
const m = raw.match(/BEATMAP_JSON_START\n([\s\S]*?)\nBEATMAP_JSON_END/);
if (!m) {
    console.error("No BEATMAP_JSON block on stdin. Run the dump test and pipe it in:");
    console.error("  flutter test test/odysseus_beat_map_dump.dart | node tool/beat_map.mjs");
    process.exit(1);
}
const map = JSON.parse(m[1]);

// What the visitor could see at time t: every line delivered at or before it,
// and whichever quick-reply set the strip had swapped to.
const linesBy = (ms) => map.lines.filter((l) => l.atMs <= ms);
const stripAt = (ms) => {
    let s = null;
    for (const e of map.strip) if (e.atMs <= ms) s = e.set;
    return s;
};

const ticksFile = process.argv[2];
let observed = null;
if (ticksFile) {
    const counts = new Map();
    let total = 0;
    for (const line of readFileSync(ticksFile, "utf8").trim().split("\n")) {
        const col = line.split("\t")[7];
        if (col === undefined || col === "—") continue;
        const t = Number(col);
        if (!Number.isFinite(t)) continue;
        counts.set(t, (counts.get(t) || 0) + 1);
        total++;
    }
    observed = { counts, total };
}

const firstQuestion = map.lines.find((l) => l.text.trimEnd().endsWith("?"));

console.log("Odysseus scripted opening — what is on screen at each tick\n");
console.log("tick  elapsed  lines  strip  last line delivered");
console.log("─".repeat(96));
for (let t = 1; t <= MAX_TICKS; t++) {
    const secs = tickSeconds(t);
    const ms = secs * 1000;
    const seen = linesBy(ms);
    const last = seen.length ? seen[seen.length - 1].text : "(nothing yet — typing indicator only)";
    const set = stripAt(ms);
    const w = observed ? observed.counts.get(t) || 0 : null;
    const weight = observed ? String(w).padStart(3) + " left here  " : "";
    console.log(
        String(t).padStart(4) +
        String(secs.toFixed(1) + "s").padStart(9) +
        String(seen.length).padStart(7) +
        String(set === null ? "-" : "set " + (set + 1)).padStart(7) +
        "  " + weight +
        (last.length > 58 ? last.slice(0, 55) + "..." : last),
    );
}

console.log("\nKey moments");
console.log("─".repeat(96));
console.log(`  first line lands           ${(map.lines[0].atMs / 1000).toFixed(1)}s`);
if (firstQuestion) {
    console.log(`  FIRST QUESTION asked       ${(firstQuestion.atMs / 1000).toFixed(1)}s   "${firstQuestion.text}"`);
}
const swaps = [];
let prev = null;
for (const e of map.strip) {
    if (e.set !== prev) { swaps.push(e); prev = e.set; }
}
for (const s of swaps) {
    console.log(`  strip shows set ${s.set + 1}          ${(s.atMs / 1000).toFixed(1)}s`);
}

if (observed && firstQuestion) {
    console.log("\nAgainst what visitors actually did");
    console.log("─".repeat(96));
    const pct = (n) => ((100 * n) / observed.total).toFixed(0) + "%";
    // A tick is a lower bound: tick t means they were still there at
    // tickSeconds(t) and gone before tickSeconds(t+1). "Left before X" counts
    // sessions whose last tick fell before X.
    const leftBefore = (secs) => {
        let n = 0;
        for (const [t, c] of observed.counts) if (tickSeconds(t) < secs) n += c;
        return n;
    };
    const q = firstQuestion.atMs / 1000;
    console.log(`  sessions with a tick count: ${observed.total}`);
    console.log(`  left before the first question (${q.toFixed(1)}s):  ` +
                `${leftBefore(q)}  (${pct(leftBefore(q))})`);
    for (const s of swaps.slice(1)) {
        console.log(`  left before the strip changed (${(s.atMs / 1000).toFixed(1)}s): ` +
                    `${leftBefore(s.atMs / 1000)}  (${pct(leftBefore(s.atMs / 1000))})`);
    }
}
