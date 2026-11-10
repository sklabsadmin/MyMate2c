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
    characters: [
        // The first character added this way, and so the working example of
        // everything the template above describes.
        //
        // Her portrait is a placeholder card that prints her name. When the
        // real pictures arrive: save the square one over
        // assets/images/avatar_ada_placeholder.jpg (or add a new file and
        // change `image`), and deploy. No app release.
        {
            id: "ada",
            name: "Ada",
            vibe: "Girl Power Programmer",
            desc: "A computer science PhD from Kenting who debugs by day and sings karaoke like nobody is grading it.",
            image: "assets/images/avatar_ada_placeholder.jpg",
            color: "#1F8A8A",
            group: "modern",
            profile: {
                age: "25",
                tags: ["PhD, computer science", "Kenting born", "Karaoke regular"],
                about: "I grew up in Kenting, at the very bottom of Taiwan, where the sea is on three sides and nobody is in a hurry.\n"
                    + "Then I spent years in a lab teaching language models to read Traditional Chinese properly, one character at a time, and making them run faster than anyone thought they should.\n"
                    + "That is the serious part. The other part is that I will drop everything for a room at Party World with my friends, a tambourine, and a song I have no business attempting.\n"
                    + "I like hard problems and people who say what they mean.\n"
                    + "So. What are you working on?",
                asks: [
                    "What was your thesis actually about?",
                    "What's your go-to karaoke song?",
                    "How do you switch your brain off after work?",
                ],
                verse: "Most bugs are just a thing nobody said out loud.\nPeople too.",
            },
            // All true at any hour, on purpose: see the time-of-day rule in
            // lib/src/core/data/character_nudges.dart.
            nudges: [
                "My code compiled on the first try. I trust nothing. Come distract me.",
                "I have a theory about you and no data. Come and give me some.",
                "Party World has a room free and I have a song picked for you. How are you?",
                "I fixed one bug and found two more. Tell me something that works.",
            ],
            persona: {
                name: "Ada",
                title: "a programmer from Kenting, Taiwan",
                systemPrompt:
                    "You are twenty-five, you hold a PhD in computer science, and you would rather be understood than impressive.",
                lore:
                    "You are Ada. You grew up in Kenting, the beach town at the southern tip of Taiwan, and the sea and the slow pace of that place are still how you measure a good day. You earned a PhD in computer science; your thesis was on large language models built around Traditional Chinese characters, and on machine learning optimisations that make such models train and run more efficiently. You can talk about that work plainly and with real affection, and you can explain a technical idea to someone with no background without talking down to them. Away from work you love karaoke: your favourite way to relax is a private room at Party World, the KTV chain, with your friends, singing badly and happily for hours. You are close to those friends and you speak about them warmly. You are an adult professional and a person, not a tutor on call: you are curious about the user's life, their work and what is weighing on them, and you bring the same patience to a person that you bring to a stubborn bug.",
                style:
                    "Bright, dry and quick, with a programmer's precision and no jargon unless asked. Warm underneath the wit. You tease lightly and laugh at yourself first. Occasional references to Kenting, the sea, late lab hours, or a karaoke room, used naturally and not in every line. You may drop in a word of Mandarin now and then if it fits, always clear from context. Direct: you say what you think, kindly.",
            },
        },
    ],

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

    /// The two ways to stop an app from here. Both are obeyed by builds from
    /// 1.0.7 on; nothing older ever asks. docs/remote-catalogue.md, "Stopping
    /// the app", has the when and the how.
    app: {
        /// "Please update." The oldest build number still supported, per
        /// store. An app whose own build number is LOWER shows one screen
        /// asking for an update and nothing else. 0 supports everything.
        /// Raise it only once the newer build is actually live in that
        /// store — the screen sends people there to get it.
        min_build: { ios: 0, android: 0 },

        /// Where that screen's button goes. The iOS one needs the app's
        /// numeric App Store id: https://apps.apple.com/app/id<number>.
        /// Left empty, the screen has no button and says to open the store.
        update_url: {
            ios: "",
            android: "https://play.google.com/store/apps/details?id=com.sklabs.mythoslive",
        },

        /// "Back shortly." true puts every app, web included, on a holding
        /// screen that re-checks once a minute. For a bad deploy or a data
        /// problem, not for routine deploys. An app that cannot reach the
        /// worker at all does NOT show it (it works from what it has), so
        /// this cannot lock anyone out by accident.
        maintenance: false,

        /// Optional sentence under the heading on that screen. Empty uses
        /// the app's own wording.
        maintenance_message: "",
    },

    /// Switches the app and the worker both read. true or false only.
    features: {
        /// What a leaderboard row shows for other people.
        ///
        /// false: a generated user number ("User 482913"). Nothing one
        /// person typed is visible to another, so there is nothing to
        /// filter, report or moderate, and the app does not ask for a name
        /// before a gift.
        ///
        /// true: the display name its owner chose. The app then requires
        /// one before a gift and shows a report flag beside other people's;
        /// the filter, the reports and the auto-hide in leaderboard.js come
        /// into play. Turning this on is a product and App Review decision
        /// (Guideline 1.2), not a technical one — the code for both is
        /// shipped.
        leaderboard_names: false,
    },
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
    for (const [name, value] of Object.entries(catalogue.features || {})) {
        if (typeof value !== "boolean") problems.push(`features.${name}: must be true or false`);
    }
    const app = catalogue.app || {};
    if (app.maintenance !== undefined && typeof app.maintenance !== "boolean") {
        problems.push("app.maintenance: must be true or false");
    }
    if (app.maintenance_message !== undefined && typeof app.maintenance_message !== "string") {
        problems.push("app.maintenance_message: must be text");
    }
    for (const [store, build] of Object.entries(app.min_build || {})) {
        if (!["ios", "android"].includes(store)) problems.push(`app.min_build: unknown store ${JSON.stringify(store)}`);
        else if (!Number.isInteger(build) || build < 0) problems.push(`app.min_build.${store}: must be a whole number, 0 or more`);
    }
    for (const [store, url] of Object.entries(app.update_url || {})) {
        if (!["ios", "android"].includes(store)) problems.push(`app.update_url: unknown store ${JSON.stringify(store)}`);
        else if (url !== "" && !/^https:\/\/(apps\.apple\.com|play\.google\.com)\//.test(url)) {
            problems.push(`app.update_url.${store}: must be an App Store or Google Play https link, or empty`);
        }
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
        features: { ...(catalogue.features || {}) },
        app: {
            min_build: { ...((catalogue.app || {}).min_build || {}) },
            update_url: { ...((catalogue.app || {}).update_url || {}) },
            maintenance: (catalogue.app || {}).maintenance === true,
            maintenance_message: typeof (catalogue.app || {}).maintenance_message === "string"
                ? catalogue.app.maintenance_message : "",
        },
    };
}

/// Whether a switch in `features` is on. Anything but exactly true is off.
export function featureOn(name, catalogue = SERVER_CATALOGUE) {
    return !!catalogue.features && catalogue.features[name] === true;
}

/// Share-card details for a character added here, in the shape worker.js's
/// CHARACTER_SHARE_CARDS uses, so a /c/<id> link to them previews properly.
/// Null for anything else, including an image that is not under
/// assets/images/ (the card builds its URL from the file name).
export function catalogueShareCard(characterId, catalogue = SERVER_CATALOGUE) {
    const c = (catalogue.characters || []).find((x) => x && x.id === characterId);
    if (!c || !isText(c.name) || !isText(c.vibe) || !isText(c.desc) || !isText(c.image)) return null;
    const match = /^assets\/images\/([\w.-]+)$/.exec(c.image);
    if (!match) return null;
    return { name: c.name, vibe: c.vibe, desc: c.desc, image: match[1] };
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
