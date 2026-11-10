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
// NAMES. Nobody's real name, account name or user id is ever on a board. A
// wallet may be an anonymous device, and even a signed-in person has not
// agreed to be listed. Each row carries a made-up mythic handle derived from
// the user id by a keyed hash, stable for that user and meaningless to anyone
// else; the requester's own row is marked `you` and the app says "You". This
// also keeps the boards free of user-written text, which would need
// moderation and reporting (App Store Guideline 1.2).

/// Rows shown on a board.
export const BOARD_SIZE = 10;

/// Gifts (to anyone) before someone is listed on, and shown, the global board.
export const GLOBAL_MIN_GIFTS = 2;

/// Developer wallets — any user id a dev-marked visit carried (migration
/// 0015) — are left off, the same rule the admin coins report uses. Test
/// spending would otherwise sit at the top of every board.
const NOT_DEV = `user_id NOT IN (
    SELECT DISTINCT sv.app_user_id FROM site_visits sv
    WHERE COALESCE(sv.is_dev, 0) = 1 AND sv.app_user_id IS NOT NULL)`;

/// A gift row: a debit with reason 'gift'. `ref` is who it was given to.
const IS_GIFT = `reason = 'gift' AND delta < 0`;

const EPITHETS = [
    "Swift", "Grey-Eyed", "Wine-Dark", "Laurelled", "Far-Sailing", "Golden",
    "Storm-Born", "Silver-Tongued", "Lion-Hearted", "Rosy-Fingered",
    "Fleet-Footed", "Bright-Helmed", "Star-Crowned", "Deep-Minded",
    "Sea-Born", "Bronze-Clad", "Honey-Voiced", "Dawn-Lit", "Oak-Hearted",
    "Moon-Watching", "Fire-Bringing", "Cloud-Gathering", "Wide-Wandering",
    "Sure-Aiming",
];
const FIGURES = [
    "Argonaut", "Oracle", "Voyager", "Muse", "Nymph", "Titan", "Weaver",
    "Navigator", "Bard", "Huntress", "Champion", "Charioteer", "Herald",
    "Sibyl", "Wanderer", "Helmsman", "Archer", "Lyrist", "Seer", "Shepherd",
    "Torchbearer", "Mariner", "Sentinel", "Pilgrim",
];

/// The handle a user goes by on every board: "Wine-Dark Navigator 47".
///
/// Keyed with a server secret so a handle cannot be turned back into a user
/// id by hashing guesses, and so two deployments do not share handles. The
/// number is what keeps 576 word pairs from colliding among a board's ten.
export async function boardHandle(userId, secret) {
    const key = await crypto.subtle.importKey(
        "raw", new TextEncoder().encode(secret || "mythos-leaderboard"),
        { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
    );
    const mac = new Uint8Array(await crypto.subtle.sign(
        "HMAC", key, new TextEncoder().encode(`leaderboard:${userId}`),
    ));
    const epithet = EPITHETS[mac[0] % EPITHETS.length];
    const figure = FIGURES[mac[1] % FIGURES.length];
    const number = 10 + (((mac[2] << 8) | mac[3]) % 90);
    return `${epithet} ${figure} ${number}`;
}

/// One board. `where` narrows the gift rows (to a character, or not at all);
/// `minGifts` is how many gifts a user needs to be listed.
///
/// Ranking is by coins, then by who got there first: of two people on the
/// same total, the one whose latest gift is older holds the higher place, so
/// matching someone does not bump them. The requester's own standing comes
/// back even when they are below the fold, as { rank, spent, gifts }.
async function board(db, { where, binds, minGifts, userId, secret }) {
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

    const entries = [];
    for (const [i, row] of (results || []).entries()) {
        const mine = !!userId && row.user_id === userId;
        entries.push({
            rank: i + 1,
            name: await boardHandle(row.user_id, secret),
            spent: Number(row.spent),
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
export async function leaderboards(db, { characterId, userId, secret }) {
    const character = await board(db, {
        where: "ref = ?", binds: [characterId], minGifts: 1, userId, secret,
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
            where: "1 = 1", binds: [], minGifts: GLOBAL_MIN_GIFTS, userId, secret,
        })) }
        : { unlocked: false };

    return {
        character: { id: characterId, ...character },
        global,
    };
}
