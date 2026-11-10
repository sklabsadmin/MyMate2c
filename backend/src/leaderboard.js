// Leaderboards: who has given the most, by coins spent on gifts.
//
// Two boards, both answered straight from coin_ledger — the gift rows ARE the
// record, so there is no second table to drift from what was charged:
//
//   - one per character: everyone who has given that character anything,
//     ranked by the coins those gifts cost;
//   - one across all characters, for people who have given at least
//     GLOBAL_MIN_GIFTS gifts. It is only SENT to a requester who has done the
//     same — until then the app does not show that it exists.
//
// WHO A ROW SAYS IT IS. No user id, account name or profile field is ever on
// a board, and the requester's own row is marked `you` (the app says "You").
// For everyone else it is one of two things, chosen by a single switch —
// SERVER_CATALOGUE.features.leaderboard_names in catalogue.js:
//
//   off (how it ships)  A generated user number, "User 482913", derived from
//       the user id by a keyed hash: stable for that person, meaningless to
//       anyone else. Nothing anyone typed is shown to anyone, so there is no
//       user-written content on a board and App Store Guideline 1.2 has
//       nothing to say about it. Names people set in their profile are still
//       sent here and kept (setDisplayName), just never displayed.
//
//   on   The display name its owner chose — but only a name sent by an app
//       that had told them it would be public (`noticed`). Everyone else
//       keeps their number. This is user-written text shown to strangers,
//       so the rest of this file's name handling comes into play: a filter
//       on the way in (cleanDisplayName), a way to report one
//       (reportDisplayName), and action on reports — REPORTS_TO_HIDE
//       distinct reporters put a row back to its number, and
//       /api/admin/leaderboard-names lets a person review, hide, restore.

/// Rows shown on a board.
export const BOARD_SIZE = 10;

/// Gifts (to anyone) before someone is listed on, and shown, the global board.
export const GLOBAL_MIN_GIFTS = 2;

/// Distinct people reporting a name before it is hidden without waiting for
/// anyone to look.
export const REPORTS_TO_HIDE = 3;

export const NAME_MIN = 2;
export const NAME_MAX = 20;

/// Names nobody may take: what the app itself prints in a row, and anything
/// that reads as us.
const RESERVED = ["you", "admin", "administrator", "moderator", "mythos", "mythoslive", "mythos live", "support", "staff", "official", "system"];

/// Substrings that sink a name, matched after [fold] — so spacing, case,
/// accents, repeats and the usual digit swaps do not get around it. Short on
/// purpose: it is the first line, and reports are the second. It errs toward
/// letting a real name through: a word that sits inside ordinary names is
/// only blocked as the WHOLE name (the set below), which means "NaziKing"
/// gets past the filter and has to be reported. That trade is deliberate —
/// refusing Nazia, Pedro's cousin Torpedo or Mr Hancock at the moment they
/// try to give a gift costs more than a bad name that lasts until three
/// people flag it. Add to either list when a report shows a gap.
const BLOCKED = [
    "fuck", "shit", "bitch", "cunt", "nigg", "fagg", "faggot", "retard",
    "whore", "slut", "rapist", "rape", "pedo", "paedo", "nazi", "hitler",
    "kike", "spic", "chink", "tranny", "porn", "pussy", "dick", "cock",
    "penis", "vagina", "anal", "cum", "jizz", "blowjob", "handjob",
    "killyourself", "kys", "suicide", "asshole", "bastard", "wank",
    "twat", "milf", "dildo", "horny", "sexy", "nude", "boob", "tits",
];
/// Blocked only as a whole name, because they hide inside ordinary ones
/// ("Cockburn", "Dickson", "Analise", "Cumberland", "Nazia", "Swank",
/// "Atwater", "Jizelle", "Drapeau"...).
const BLOCKED_WHOLE_ONLY = new Set([
    "cock", "dick", "anal", "cum", "tits", "rape", "spic", "nude", "kys",
    "nazi", "pedo", "paedo", "wank", "twat", "jizz",
]);

/// A name reduced to what it sounds like: lower case, accents off, the
/// common digit and symbol swaps undone, everything that is not a letter
/// dropped, runs of one letter collapsed.
function fold(name) {
    return name
        .normalize("NFKD").replace(/[\u0300-\u036f]/g, "")
        .toLowerCase()
        .replace(/[0@]/g, (c) => (c === "0" ? "o" : "a"))
        .replace(/1|!|\|/g, "i").replace(/3/g, "e").replace(/4/g, "a")
        .replace(/5|\$/g, "s").replace(/7/g, "t").replace(/8/g, "b")
        .replace(/[^a-z]/g, "")
        .replace(/(.)\1+/g, "$1");
}

/// A submitted display name, tidied — or the reason it cannot be used.
///
/// Returns { ok: true, name } or { ok: false, reason } where reason is
/// "length" | "characters" | "not_allowed". The app shows a sentence for
/// each; none of them says which word tripped the filter.
export function cleanDisplayName(raw) {
    if (typeof raw !== "string") return { ok: false, reason: "length" };
    const name = raw.normalize("NFC").replace(/\s+/g, " ").trim();
    const length = [...name].length;
    if (length < NAME_MIN || length > NAME_MAX) return { ok: false, reason: "length" };
    // Letters and digits of any script, and the punctuation real names use.
    // No @, /, : or dots-with-letters: a name is not a handle, a link or an
    // address, and those are how one gets advertised on a leaderboard.
    if (!/^[\p{L}\p{N}][\p{L}\p{N} '’_-]*$/u.test(name)) return { ok: false, reason: "characters" };
    if (!/\p{L}/u.test(name)) return { ok: false, reason: "characters" };
    const folded = fold(name);
    if (RESERVED.some((r) => fold(r) === folded)) return { ok: false, reason: "not_allowed" };
    for (const word of BLOCKED) {
        const w = fold(word);
        if (BLOCKED_WHOLE_ONLY.has(word) ? folded === w : folded.includes(w)) {
            return { ok: false, reason: "not_allowed" };
        }
    }
    return { ok: true, name };
}

async function keyedHex(secret, text, bytes) {
    const key = await crypto.subtle.importKey(
        "raw", new TextEncoder().encode(secret || "mythos-leaderboard"),
        { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
    );
    const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(text)));
    return [...mac.slice(0, bytes)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/// Stores [rawName] as [userId]'s display name. A changed name clears
/// `hidden`: the new text has not been reported, and it went through the
/// filter again. (Someone cycling through bad names is what the admin list
/// and its per-user history are for.)
///
/// [noticed] is whether the sending app had told its owner the name would
/// be shown on leaderboards. Once 1 it stays 1 for the same name; a changed
/// name takes the new value.
export async function setDisplayName(db, { userId, rawName, secret, noticed = false }) {
    const cleaned = cleanDisplayName(rawName);
    if (!cleaned.ok) return cleaned;
    const ref = await keyedHex(secret, `leaderboard-ref:${userId}`, 12);
    await db.prepare(`
        INSERT INTO leaderboard_names (user_id, name, ref, noticed) VALUES (?, ?, ?, ?)
        ON CONFLICT(user_id) DO UPDATE SET
            hidden = CASE WHEN leaderboard_names.name = excluded.name THEN leaderboard_names.hidden ELSE 0 END,
            noticed = CASE WHEN leaderboard_names.name = excluded.name
                           THEN MAX(leaderboard_names.noticed, excluded.noticed)
                           ELSE excluded.noticed END,
            name = excluded.name,
            updated_at = CURRENT_TIMESTAMP
    `).bind(userId, cleaned.name, ref, noticed ? 1 : 0).run();
    return { ok: true, name: cleaned.name };
}

/// The display name [userId] has on file, hidden or not — it is still theirs.
export async function displayNameOf(db, userId) {
    try {
        const row = await db.prepare(`SELECT name FROM leaderboard_names WHERE user_id = ?`).bind(userId).first();
        return row ? row.name : null;
    } catch (_) {
        return null; // migration 0022 not applied yet
    }
}

/// Records that [reporterId] objects to the name behind [ref], and hides the
/// name once REPORTS_TO_HIDE different people have. Answers the same thing
/// whether or not the ref exists, so the endpoint cannot be used to test
/// refs. Returns what happened, for the log.
export async function reportDisplayName(db, { reporterId, ref }) {
    if (typeof ref !== "string" || !/^[0-9a-f]{24}$/.test(ref)) return { recorded: false };
    const target = await db.prepare(
        `SELECT user_id, name, hidden FROM leaderboard_names WHERE ref = ?`
    ).bind(ref).first();
    if (!target || target.user_id === reporterId) return { recorded: false };
    await db.prepare(`
        INSERT OR IGNORE INTO leaderboard_name_reports (reporter_id, reported_user_id, name)
        VALUES (?, ?, ?)
    `).bind(reporterId, target.user_id, target.name).run();
    const count = await db.prepare(`
        SELECT COUNT(DISTINCT reporter_id) AS n FROM leaderboard_name_reports
        WHERE reported_user_id = ? AND name = ?
    `).bind(target.user_id, target.name).first();
    const reports = count ? Number(count.n) : 0;
    let hidden = Number(target.hidden) === 1;
    if (!hidden && reports >= REPORTS_TO_HIDE) {
        await db.prepare(`UPDATE leaderboard_names SET hidden = 1 WHERE user_id = ?`).bind(target.user_id).run();
        hidden = true;
    }
    return { recorded: true, name: target.name, reports, hidden };
}

/// For the admin API: every name with a report against it, most reported
/// first, plus the names currently hidden.
export async function reportedDisplayNames(db) {
    const { results } = await db.prepare(`
        SELECT n.ref, n.name, n.hidden, n.updated_at,
               (SELECT COUNT(DISTINCT r.reporter_id) FROM leaderboard_name_reports r
                 WHERE r.reported_user_id = n.user_id AND r.name = n.name) AS reports,
               (SELECT COUNT(DISTINCT r.name) FROM leaderboard_name_reports r
                 WHERE r.reported_user_id = n.user_id) AS names_reported
        FROM leaderboard_names n
        WHERE n.hidden = 1 OR EXISTS (
            SELECT 1 FROM leaderboard_name_reports r WHERE r.reported_user_id = n.user_id)
        ORDER BY reports DESC, n.updated_at DESC
        LIMIT 200
    `).all();
    return (results || []).map((r) => ({
        ref: r.ref, name: r.name, hidden: Number(r.hidden) === 1,
        reports: Number(r.reports), names_reported: Number(r.names_reported),
        updated_at: r.updated_at,
    }));
}

/// For the admin API: hide or restore the name behind [ref]. True if a row
/// changed hands.
export async function setDisplayNameHidden(db, { ref, hidden }) {
    const result = await db.prepare(
        `UPDATE leaderboard_names SET hidden = ? WHERE ref = ?`
    ).bind(hidden ? 1 : 0, String(ref || "")).run();
    return !!(result && result.meta && result.meta.changes > 0);
}

/// Developer wallets — any user id a dev-marked visit carried (migration
/// 0015) — are left off, the same rule the admin coins report uses. Test
/// spending would otherwise sit at the top of every board.
const NOT_DEV = `user_id NOT IN (
    SELECT DISTINCT sv.app_user_id FROM site_visits sv
    WHERE COALESCE(sv.is_dev, 0) = 1 AND sv.app_user_id IS NOT NULL)`;

/// A gift row: a debit with reason 'gift'. `ref` is who it was given to.
const IS_GIFT = `reason = 'gift' AND delta < 0`;

/// The number a user goes by on every board: "User 482913".
///
/// Six digits from a keyed hash of the user id. Keyed with a server secret so
/// a number cannot be turned back into a user id by hashing guesses; six
/// digits so that two of a board's ten rows sharing one is a
/// once-in-twenty-thousand-boards event rather than a weekly one. It is not
/// a count of anything and says nothing about how many users there are.
export async function boardHandle(userId, secret) {
    const key = await crypto.subtle.importKey(
        "raw", new TextEncoder().encode(secret || "mythos-leaderboard"),
        { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
    );
    const mac = new Uint8Array(await crypto.subtle.sign(
        "HMAC", key, new TextEncoder().encode(`leaderboard:${userId}`),
    ));
    const number = 100000 + ((((mac[0] << 24) | (mac[1] << 16) | (mac[2] << 8) | mac[3]) >>> 0) % 900000);
    return `User ${number}`;
}

/// One board. `where` narrows the gift rows (to a character, or not at all);
/// `minGifts` is how many gifts a user needs to be listed.
///
/// Ranking is by coins, then by who got there first: of two people on the
/// same total, the one whose latest gift is older holds the higher place, so
/// matching someone does not bump them. The requester's own standing comes
/// back even when they are below the fold, as { rank, spent, gifts }.
async function board(db, { where, binds, minGifts, userId, secret, showNames }) {
    const grouped = `
        SELECT user_id, SUM(-delta) AS spent, COUNT(*) AS gifts, MAX(created_at) AS last_at
        FROM coin_ledger
        WHERE ${IS_GIFT} AND ${where} AND ${NOT_DEV}
        GROUP BY user_id
        HAVING COUNT(*) >= ?`;
    const { results } = await db.prepare(`
        ${grouped}
        ORDER BY spent DESC, last_at ASC, user_id ASC
        LIMIT ?
    `).bind(...binds, minGifts, BOARD_SIZE).all();

    // The chosen names of the people on this page, in one read.
    const ids = (results || []).map((r) => r.user_id);
    const chosen = new Map();
    if (showNames && ids.length) {
        try {
            const { results: named } = await db.prepare(`
                SELECT user_id, name, ref FROM leaderboard_names
                WHERE hidden = 0 AND noticed = 1 AND user_id IN (${ids.map(() => "?").join(", ")})
            `).bind(...ids).all();
            for (const n of named || []) chosen.set(n.user_id, n);
        } catch (_) {
            // Migration 0022 not applied yet: everyone keeps their number,
            // and the board itself still answers.
        }
    }

    const entries = [];
    for (const [i, row] of (results || []).entries()) {
        const mine = !!userId && row.user_id === userId;
        const own = chosen.get(row.user_id);
        entries.push({
            rank: i + 1,
            name: own ? own.name : await boardHandle(row.user_id, secret),
            spent: Number(row.spent),
            // `ref` only on a chosen name, and never on your own row: it is
            // what a report names, and a number we generated needs no
            // reporting.
            ...(own && !mine ? { ref: own.ref } : {}),
            ...(mine ? { you: true } : {}),
        });
    }

    let you = null;
    if (userId) {
        const own = await db.prepare(`
            SELECT SUM(-delta) AS spent, COUNT(*) AS gifts, MAX(created_at) AS last_at
            FROM coin_ledger
            WHERE ${IS_GIFT} AND ${where} AND user_id = ?
        `).bind(...binds, userId).first();
        const gifts = own ? Number(own.gifts || 0) : 0;
        if (gifts >= minGifts && gifts > 0) {
            const listed = entries.find((e) => e.you);
            let rank = listed ? listed.rank : null;
            if (rank === null) {
                // Below the fold: count who is ahead, by the same ordering.
                const ahead = await db.prepare(`
                    SELECT COUNT(*) AS n FROM (${grouped})
                    WHERE spent > ? OR (spent = ? AND (last_at < ? OR (last_at = ? AND user_id < ?)))
                `).bind(...binds, minGifts, own.spent, own.spent, own.last_at, own.last_at, userId).first();
                rank = Number(ahead ? ahead.n : 0) + 1;
            }
            you = { rank, spent: Number(own.spent), gifts };
        }
    }
    return { entries, you };
}

/// What GET /api/leaderboard answers for [userId] looking at [characterId].
///
/// `global` is { unlocked: false } until the requester has given
/// GLOBAL_MIN_GIFTS gifts — no entries, no hint of who is on it. Everything
/// about the character's own board is public to anyone who can open the
/// character.
///
/// [showNames] is the leaderboard_names switch: false shows a user number on
/// every row, true shows chosen names where there is one.
export async function leaderboards(db, { characterId, userId, secret, showNames = false }) {
    const character = await board(db, {
        where: "ref = ?", binds: [characterId], minGifts: 1, userId, secret, showNames,
    });

    let totalGifts = 0;
    if (userId) {
        const row = await db.prepare(
            `SELECT COUNT(*) AS n FROM coin_ledger WHERE ${IS_GIFT} AND user_id = ?`
        ).bind(userId).first();
        totalGifts = row ? Number(row.n) : 0;
    }
    const unlocked = totalGifts >= GLOBAL_MIN_GIFTS;
    const global = unlocked
        ? { unlocked: true, ...(await board(db, {
            where: "1 = 1", binds: [], minGifts: GLOBAL_MIN_GIFTS, userId, secret, showNames,
        })) }
        : { unlocked: false };

    return {
        character: { id: characterId, ...character },
        global,
        // The requester's own display name, so the app knows whether it has
        // been sent yet (null: not on file — ask before the next gift).
        your_name: userId ? await displayNameOf(db, userId) : null,
    };
}
