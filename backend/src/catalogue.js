// The remote catalogue: characters and gifts added or changed WITHOUT an app
// release. docs/remote-catalogue.md is the how-to; this is the data.
//
// The app ships with a bundled roster (lib/src/core/data/characters.dart,
// character_profiles.dart) and a bundled gift list (coins_sheet.dart). On
// launch it asks GET /api/catalogue and lays the answer over that bundled
// data. So this file is a DELTA, and it starts empty:
//
//   - a character or gift listed here that the app has never heard of is
//     ADDED;
//   - one whose id the app already knows has the listed fields REPLACED
//     (rewrite Zeus's blurb, retitle the roses) and everything else kept;
//   - `hiddenCharacters` / `hiddenGifts` take something off the screen;
//   - `order` re-sorts a dashboard group.
//
// Nothing here can break an app that predates the endpoint: those builds
// never ask, and keep showing what they were built with. The worker itself
// still serves them — a persona or a gift price added here answers any client
// that names its id.
//
// IMAGES. `image` is a Flutter asset path ("assets/images/avatar_x.jpg").
// Put the file in assets/images/ and deploy: the web build publishes every
// asset at <origin>/assets/<path>, the app looks for the path in its own
// bundle first and fetches it from there when it is not, so a new portrait
// needs no release either. An absolute https:// URL also works.

/// Bumped only when the SHAPE of the response changes in a way an old client
/// could misread. Adding entries never needs it.
export const CATALOGUE_SCHEMA = 1;

/// Mutable on purpose: the tests add entries before loading the worker. In
/// production it is exactly what is written below.
export const SERVER_CATALOGUE = {
    /// New or overridden characters. A NEW one needs every presentation
    /// field, a `profile`, and a `persona` (the persona never leaves the
    /// worker). An override needs `id` plus only the fields that change.
    ///
    /// {
    ///     id: "achilles",                       // [a-z0-9_], permanent
    ///     name: "Achilles",
    ///     vibe: "Best of the Greeks",           // the line under the name
    ///     desc: "One sentence for the dashboard card.",
    ///     tagline: "Optional third line on the entry card.",
    ///     image: "assets/images/avatar_achilles_real.jpg",
    ///     color: "#B03A2E",
    ///     group: "greek",                       // "greek" | "modern"
    ///     profile: {
    ///         age: "ageless",
    ///         tags: ["three", "short", "chips"],
    ///         about: "First-person introduction.\nLine breaks are kept.",
    ///         asks: ["Three openers,", "in the USER's voice,", "tappable."],
    ///         verse: "Closing line, as the character.",
    ///     },
    ///     // What a notification from this character can say once someone
    ///     // has talked to them. Short, in voice, no questions about things
    ///     // the character could not know.
    ///     nudges: ["...", "..."],
    ///     // Server only. Same shape as CHARACTER_PERSONAS in worker.js.
    ///     persona: { name: "Achilles", title: "Best of the Greeks",
    ///                systemPrompt: "...", lore: "...", style: "..." },
    /// }
    characters: [],

    /// Ids to take off the dashboard (bundled or added). Existing chats with
    /// them keep working; they just stop being offered.
    hiddenCharacters: [],

    /// Optional. { greek: [ids...], modern: [ids...] } replaces that group's
    /// order outright; a group left out keeps the app's order with any new
    /// characters appended.
    order: {},

    /// New or overridden gifts. A NEW one needs every field; an override
    /// needs `item` plus what changes. The price is charged from here, so a
    /// gift cannot be shown at one price and debited at another.
    ///
    /// {
    ///     item: "lilies",                       // [a-z_], permanent
    ///     label: "Lilies",
    ///     detail: "One line under the label.",
    ///     image: "assets/images/gift_lilies.png",
    ///     price: 80,
    ///     once: false,                          // true = keepsake, once per character
    ///     giving: "a spray of lilies",          // "*gives ___ to Zeus*"; optional
    ///     narration: "a spray of white lilies", // how the character is told
    ///     // Keepsakes only:
    ///     heldBadge: "Worn",
    ///     heldDetail: "Worn since you gave it.",
    ///     keepsakeNote: "KEEPSAKE: ... what the character remembers ...",
    /// }
    gifts: [],

    /// Gift items to stop offering. Already-given keepsakes still show.
    hiddenGifts: [],

    /// Notification lines for characters the app already ships, replacing
    /// its bundled ones: { zeus: ["...", "..."] }. A new character carries
    /// its own in `nudges` above.
    nudges: {},
};

const ID = /^[a-z0-9_]{1,40}$/;
const ITEM = /^[a-z_]{1,40}$/;
const COLOR = /^#[0-9a-fA-F]{6}$/;
const GROUPS = ["greek", "modern"];

const isText = (v) => typeof v === "string" && v.trim().length > 0;
const isTextList = (v) => Array.isArray(v) && v.length > 0 && v.every(isText);
const isImage = (v) => isText(v) && (/^assets\/[\w./-]+$/.test(v) || /^https:\/\//.test(v));

/// Everything wrong with a catalogue, as sentences. Empty means it can ship.
///
/// `known` is what the app already bundles ({ characters: [ids], gifts:
/// [items] }): an entry with a known id is an override and may be partial,
/// anything else is new and must be complete. The deploy test passes the
/// real bundled ids so a typo in an override id is caught as "new character
/// missing fields" rather than shipping as a broken card.
export function catalogueProblems(catalogue = SERVER_CATALOGUE, known = { characters: [], gifts: [] }) {
    const problems = [];
    const seen = new Set();
    for (const c of catalogue.characters || []) {
        const at = `character ${JSON.stringify(c && c.id)}`;
        if (!c || !ID.test(c.id || "")) { problems.push(`${at}: id must match ${ID}`); continue; }
        if (seen.has(c.id)) problems.push(`${at}: listed twice`);
        seen.add(c.id);
        const isNew = !known.characters.includes(c.id);
        for (const field of ["name", "vibe", "desc"]) {
            if (c[field] !== undefined ? !isText(c[field]) : isNew) problems.push(`${at}: needs ${field}`);
        }
        if (c.tagline !== undefined && !isText(c.tagline)) problems.push(`${at}: tagline must be text`);
        if (c.image !== undefined ? !isImage(c.image) : isNew) problems.push(`${at}: image must be an assets/ path or https URL`);
        if (c.color !== undefined ? !COLOR.test(c.color) : isNew) problems.push(`${at}: color must be #RRGGBB`);
        if (c.group !== undefined ? !GROUPS.includes(c.group) : isNew) problems.push(`${at}: group must be one of ${GROUPS.join(", ")}`);
        if (c.profile !== undefined || isNew) {
            const p = c.profile || {};
            if (!isText(p.age)) problems.push(`${at}: profile.age`);
            if (!isTextList(p.tags)) problems.push(`${at}: profile.tags`);
            if (!isText(p.about)) problems.push(`${at}: profile.about`);
            if (!isTextList(p.asks)) problems.push(`${at}: profile.asks`);
            if (!isText(p.verse)) problems.push(`${at}: profile.verse`);
        }
        if (c.nudges !== undefined && !isTextList(c.nudges)) problems.push(`${at}: nudges must be a list of lines`);
        if (c.persona !== undefined || isNew) {
            const p = c.persona || {};
            for (const field of ["name", "title", "systemPrompt", "lore", "style"]) {
                if (!isText(p[field])) problems.push(`${at}: persona.${field} (without a persona the character answers in the generic voice)`);
            }
        }
    }
    const items = new Set();
    for (const g of catalogue.gifts || []) {
        const at = `gift ${JSON.stringify(g && g.item)}`;
        if (!g || !ITEM.test(g.item || "")) { problems.push(`${at}: item must match ${ITEM}`); continue; }
        if (items.has(g.item)) problems.push(`${at}: listed twice`);
        items.add(g.item);
        const isNew = !known.gifts.includes(g.item);
        for (const field of ["label", "detail"]) {
            if (g[field] !== undefined ? !isText(g[field]) : isNew) problems.push(`${at}: needs ${field}`);
        }
        if (g.image !== undefined ? !isImage(g.image) : isNew) problems.push(`${at}: image must be an assets/ path or https URL`);
        if (g.price !== undefined ? !(Number.isInteger(g.price) && g.price > 0) : isNew) problems.push(`${at}: price must be a positive whole number`);
        if (g.once !== undefined && typeof g.once !== "boolean") problems.push(`${at}: once must be true or false`);
        if (!isNew && g.once !== undefined) problems.push(`${at}: once cannot be changed on a gift that already exists — the ledger keys depend on it`);
        if (g.narration !== undefined ? !isText(g.narration) : isNew) problems.push(`${at}: needs narration (how the character is told what it was handed)`);
        if (isNew && g.once === true && !isText(g.keepsakeNote)) problems.push(`${at}: a keepsake needs keepsakeNote, or it is charged for and forgotten`);
        for (const field of ["giving", "heldBadge", "heldDetail", "keepsakeNote"]) {
            if (g[field] !== undefined && !isText(g[field])) problems.push(`${at}: ${field} must be text`);
        }
    }
    for (const id of catalogue.hiddenCharacters || []) {
        if (!ID.test(id)) problems.push(`hiddenCharacters: ${JSON.stringify(id)} is not an id`);
    }
    for (const item of catalogue.hiddenGifts || []) {
        if (!ITEM.test(item)) problems.push(`hiddenGifts: ${JSON.stringify(item)} is not an item`);
    }
    for (const [group, ids] of Object.entries(catalogue.order || {})) {
        if (!GROUPS.includes(group)) problems.push(`order: unknown group ${JSON.stringify(group)}`);
        else if (!Array.isArray(ids) || !ids.every((id) => ID.test(id))) problems.push(`order.${group}: must be a list of ids`);
    }
    for (const [id, lines] of Object.entries(catalogue.nudges || {})) {
        if (!ID.test(id) || !isTextList(lines)) problems.push(`nudges.${id}: must be a list of lines`);
    }
    return problems;
}

/// Turns an asset path into something a phone can fetch. The web build
/// publishes Flutter assets under /assets/, so "assets/images/x.jpg" lives at
/// <origin>/assets/assets/images/x.jpg — the doubled segment is Flutter's.
function imageUrl(image, origin) {
    if (!isText(image)) return undefined;
    if (/^https:\/\//.test(image)) return image;
    return `${origin}/assets/${image}`;
}

/// What GET /api/catalogue answers. Personas, prices' server-side notes and
/// narration stay behind: only what a screen draws goes out.
export function publicCatalogue(origin, catalogue = SERVER_CATALOGUE) {
    const characters = (catalogue.characters || [])
        .filter((c) => c && ID.test(c.id || ""))
        .map((c) => {
            const out = { id: c.id };
            for (const field of ["name", "vibe", "desc", "tagline", "image", "color", "group"]) {
                if (c[field] !== undefined) out[field] = c[field];
            }
            if (c.image !== undefined) out.image_url = imageUrl(c.image, origin);
            if (c.profile) {
                out.profile = {
                    age: c.profile.age, tags: c.profile.tags, about: c.profile.about,
                    asks: c.profile.asks, verse: c.profile.verse,
                };
            }
            if (Array.isArray(c.nudges)) out.nudges = c.nudges;
            return out;
        });
    const gifts = (catalogue.gifts || [])
        .filter((g) => g && ITEM.test(g.item || ""))
        .map((g) => {
            const out = { item: g.item };
            for (const field of ["label", "detail", "image", "price", "once", "giving", "heldBadge", "heldDetail"]) {
                if (g[field] !== undefined) out[field] = g[field];
            }
            if (g.image !== undefined) out.image_url = imageUrl(g.image, origin);
            return out;
        });
    return {
        schema: CATALOGUE_SCHEMA,
        characters,
        hidden_characters: [...(catalogue.hiddenCharacters || [])],
        order: { ...(catalogue.order || {}) },
        gifts,
        hidden_gifts: [...(catalogue.hiddenGifts || [])],
        nudges: { ...(catalogue.nudges || {}) },
    };
}

/// The persona for a character added here, or null. worker.js asks this
/// after its own CHARACTER_PERSONAS, so a bundled character's persona cannot
/// be replaced from this file by accident.
export function cataloguePersona(characterId, catalogue = SERVER_CATALOGUE) {
    const entry = (catalogue.characters || []).find((c) => c && c.id === characterId);
    const p = entry && entry.persona;
    if (!p || !["name", "title", "systemPrompt", "lore", "style"].every((f) => isText(p[f]))) return null;
    return p;
}

/// The tappable openers of a character added here — what the admin "was this
/// typed?" check needs for characters starters.generated.js has never seen.
export function catalogueStarters(characterId, catalogue = SERVER_CATALOGUE) {
    const entry = (catalogue.characters || []).find((c) => c && c.id === characterId);
    const asks = entry && entry.profile && entry.profile.asks;
    return Array.isArray(asks) ? asks : null;
}
