// The remote catalogue: characters and gifts added without an app release.
//
// Two halves. The first holds the file that actually ships
// (backend/src/catalogue.js) to its own rules, against the ids the app really
// bundles — a typo there is a broken card on every phone within five minutes
// of a deploy, with no app release to blame. The second adds a character and
// two gifts the way an editor would and checks the worker treats them exactly
// like built-in ones: served, priced, charged, narrated, remembered, voiced.
//
// The additions are made BEFORE the worker module loads, because the gift
// tables are joined once at load. node --test gives every file its own
// process, so nothing here leaks into the other suites.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import assert from 'node:assert/strict';
import { testEnv, loadWorker } from './harness.mjs';
import {
    SERVER_CATALOGUE,
    catalogueProblems,
    publicCatalogue,
    cataloguePersona,
    catalogueShareCard,
} from '../src/catalogue.js';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');

/// What the app bundles, read from the Dart the app is built from.
const BUNDLED = {
    characters: [...read('lib/src/core/data/characters.dart').matchAll(/'id':\s*'([a-z0-9_]+)'/g)].map((m) => m[1]),
    gifts: [...read('lib/src/features/wallet/presentation/coins_sheet.dart').matchAll(/TributeOption\(\s*'([a-z_]+)'/g)].map((m) => m[1]),
};

/// The catalogue exactly as it is in the repo, taken before the additions
/// further down are pushed into the live object.
const SHIPPED = structuredClone(SERVER_CATALOGUE);

test('the bundled ids this suite checks against were actually found', () => {
    // A refactor that moves the Dart lists would otherwise turn every
    // "is this an override?" check below into a silent no.
    assert.ok(BUNDLED.characters.includes('zeus'), 'characters.dart roster');
    assert.ok(BUNDLED.gifts.includes('roses'), 'coins_sheet.dart catalogue');
});

test('the catalogue that ships has nothing wrong with it', () => {
    assert.deepEqual(catalogueProblems(SHIPPED, BUNDLED), []);
});

test('every image the shipped catalogue names is a file that will be deployed', () => {
    for (const entry of [...SHIPPED.characters, ...SHIPPED.gifts]) {
        if (!entry.image || entry.image.startsWith('https://')) continue;
        assert.ok(fs.existsSync(path.join(ROOT, entry.image)),
            `${entry.id || entry.item}: ${entry.image} is not in the repo, so the URL the app is sent would 404`);
    }
});

test('Ada ships whole: a card, a profile, a voice, and a picture that exists', () => {
    // The first character added without an app release. If this entry is
    // ever broken, every phone shows it within five minutes of a deploy.
    const served = publicCatalogue('https://chat.example.test', SHIPPED);
    const ada = served.characters.find((c) => c.id === 'ada');
    assert.equal(ada.name, 'Ada');
    assert.equal(ada.group, 'modern');
    assert.equal(ada.profile.age, '25');
    assert.equal(ada.profile.asks.length, 3);
    assert.ok(ada.nudges.length >= 3, 'three notification lines, so her three are different');
    assert.equal(ada.image_url, 'https://chat.example.test/assets/' + ada.image);
    assert.ok(!('persona' in ada), 'her persona stays on the server');

    const persona = cataloguePersona('ada', SHIPPED);
    assert.equal(persona.name, 'Ada');
    for (const fact of ['Kenting', 'PhD', 'Traditional Chinese', 'Party World', 'karaoke']) {
        assert.ok(persona.lore.includes(fact), `her background mentions ${fact}`);
    }
    assert.deepEqual(catalogueShareCard('ada', SHIPPED), {
        name: 'Ada', vibe: ada.vibe, desc: ada.desc, image: 'avatar_ada_placeholder.jpg',
    });
    assert.equal(catalogueShareCard('zeus', SHIPPED), null, 'built-in characters keep their own card');
});

test('the shipped switches are the ones that were decided', () => {
    // Boards show user numbers. Turning names on is an App Review decision,
    // so a stray edit that flips it should fail here first.
    assert.deepEqual(SHIPPED.features, { leaderboard_names: false });
});

// ---------------------------------------------------------------------------
// Additions, as an editor would make them.
// ---------------------------------------------------------------------------

const ACHILLES = {
    id: 'achilles',
    name: 'Achilles',
    vibe: 'Best of the Greeks',
    desc: 'Swift, proud, and more honest about grief than about anything else.',
    image: 'assets/images/avatar_achilles_real.jpg',
    color: '#B03A2E',
    group: 'greek',
    profile: {
        age: '27',
        tags: ['Glory', 'Rage', 'Grief'],
        about: 'They sing about the rage.\nAsk me about what came after.',
        asks: ['Was the glory worth it?', 'What would you tell Patroclus?', 'Who taught you the lyre?'],
        verse: 'A short life, and a loud one.',
    },
    nudges: ['The camp is quiet tonight.'],
    persona: {
        name: 'Achilles',
        title: 'Best of the Greeks',
        systemPrompt: 'You speak as the man who chose a short life and has had time to regret the arithmetic.',
        lore: 'You are Achilles of the Iliad.',
        style: 'Direct, quick to feeling, never falsely modest.',
    },
};
const LILIES = {
    item: 'lilies', label: 'Lilies', detail: 'White, and already opening.',
    image: 'assets/images/gift_lilies.png', price: 80, once: false,
    giving: 'a spray of lilies', narration: 'a spray of white lilies',
};
const LYRE = {
    item: 'lyre', label: 'Lyre', detail: 'Theirs to play. Given once.',
    image: 'https://cdn.example.test/gift_lyre.png', price: 900, once: true,
    heldBadge: 'Played', heldDetail: 'Played since you gave it.', giving: 'a lyre',
    narration: 'a tortoiseshell lyre, strung and tuned',
    keepsakeNote: 'KEEPSAKE: This person gave you a lyre. You play it when you are alone.',
};

SERVER_CATALOGUE.characters.push(ACHILLES, { id: 'zeus', desc: 'Rewritten without a release.' });
SERVER_CATALOGUE.gifts.push(LILIES, LYRE, { item: 'roses', price: 60 });
SERVER_CATALOGUE.hiddenCharacters.push('surfer');
SERVER_CATALOGUE.hiddenGifts.push('ambrosia');
SERVER_CATALOGUE.order.greek = ['achilles', 'odysseus'];
SERVER_CATALOGUE.nudges.zeus = ['Olympus is dull without an argument.'];

const USER = 'user_1700000000456';

function env() {
    const { env, db } = testEnv();
    return {
        env: { ...env, REQUIRE_SIGNATURE: 'false', COIN_LEDGER: 'true', APP_SECRET: 's', OPENAI_API_KEY: 'k' },
        db,
    };
}

function stubOpenAi(t) {
    const original = globalThis.fetch;
    const bodies = [];
    globalThis.fetch = async (input, init) => {
        bodies.push(init && init.body ? String(init.body) : '');
        return new Response(JSON.stringify({
            choices: [{ message: { role: 'assistant', content: 'Well met.' } }],
            usage: { prompt_tokens: 5, completion_tokens: 5, total_tokens: 10 },
        }), { status: 200, headers: { 'content-type': 'application/json' } });
    };
    t.after(() => { globalThis.fetch = original; });
    return bodies;
}

async function call(env, pathname, { method = 'GET', headers = {}, body } = {}) {
    const worker = await loadWorker();
    const pending = [];
    const res = await worker.fetch(new Request('https://mythos.test' + pathname, {
        method,
        headers: { 'x-user-id': USER, ...(body ? { 'content-type': 'application/json' } : {}), ...headers },
        body: body ? JSON.stringify(body) : undefined,
    }), env, { waitUntil(p) { pending.push(p); }, passThroughOnException() {} });
    const text = await res.text();
    await Promise.all(pending);
    return { status: res.status, headers: res.headers, json: JSON.parse(text) };
}

/// What was debited for gifts, newest last. Read from the ledger rather than
/// the balance, which also moves by the reply grant on every turn.
function giftDebits(db) {
    return db.prepare("SELECT delta FROM coin_ledger WHERE user_id = ? AND reason = 'gift' ORDER BY rowid")
        .all(USER).map((r) => r.delta);
}

function fund(db, coins) {
    db.prepare("INSERT INTO coin_ledger (id, user_id, delta, kind, reason) VALUES ('seed', ?, ?, 'adjust', 'admin')")
        .run(USER, coins);
}

test('the test additions themselves pass the rules an editor is held to', () => {
    assert.deepEqual(catalogueProblems(SERVER_CATALOGUE, BUNDLED), []);
});

test('the rules catch what would ship broken', () => {
    const bad = (patch) => catalogueProblems({ ...SERVER_CATALOGUE, ...patch }, BUNDLED);
    assert.ok(bad({ characters: [{ ...ACHILLES, persona: undefined }] }).some((p) => p.includes('persona')),
        'a new character with no persona would answer in the generic voice');
    assert.ok(bad({ characters: [{ id: 'zeuss', desc: 'typo of an override' }] }).length > 0,
        'a mistyped override id is a new character missing everything');
    assert.ok(bad({ gifts: [{ ...LYRE, keepsakeNote: undefined }] }).some((p) => p.includes('keepsakeNote')),
        'a keepsake with no note is charged for and forgotten');
    assert.ok(bad({ gifts: [{ ...LILIES, price: 0 }] }).some((p) => p.includes('price')));
    assert.ok(bad({ gifts: [{ item: 'pendant', once: false }] }).some((p) => p.includes('once')),
        'flipping once on an existing gift would orphan its ledger keys');
    assert.ok(bad({ gifts: [{ ...LILIES, item: 'li:lies' }] }).length > 0,
        'a colon in an item would collide with the keepsake ledger ids');
});

test('GET /api/catalogue serves the additions, unsigned, and never a persona', async () => {
    const { env: e } = env();
    const res = await call({ ...e, REQUIRE_SIGNATURE: 'true' }, '/api/catalogue', { headers: { 'x-user-id': '' } });
    assert.equal(res.status, 200);
    assert.match(res.headers.get('cache-control') || '', /max-age=\d+/);

    const achilles = res.json.characters.find((c) => c.id === 'achilles');
    assert.equal(achilles.name, 'Achilles');
    assert.equal(achilles.image_url, 'https://mythos.test/assets/assets/images/avatar_achilles_real.jpg',
        'an asset path becomes the URL the web build publishes it at');
    assert.deepEqual(achilles.profile.asks, ACHILLES.profile.asks);
    assert.deepEqual(achilles.nudges, ACHILLES.nudges);
    assert.ok(!JSON.stringify(res.json).includes('chose a short life'), 'the persona stays on the server');
    assert.ok(!JSON.stringify(res.json).includes('KEEPSAKE'), 'so does the keepsake note');
    assert.ok(!JSON.stringify(res.json).includes('tortoiseshell'), 'and the narration');

    // An override carries only what changed.
    assert.deepEqual(res.json.characters.find((c) => c.id === 'zeus'), { id: 'zeus', desc: 'Rewritten without a release.' });

    assert.deepEqual(res.json.hidden_characters, ['surfer']);
    assert.deepEqual(res.json.hidden_gifts, ['ambrosia']);
    assert.deepEqual(res.json.order, { greek: ['achilles', 'odysseus'] });
    assert.deepEqual(res.json.nudges, { zeus: ['Olympus is dull without an argument.'] });

    const lyre = res.json.gifts.find((g) => g.item === 'lyre');
    assert.equal(lyre.image_url, LYRE.image, 'an absolute URL is passed through');
    assert.equal(lyre.once, true);
    assert.equal(lyre.heldBadge, 'Played');
});

test('publicCatalogue of an empty catalogue is empty, not missing keys', () => {
    const empty = publicCatalogue('https://x.test', {
        characters: [], hiddenCharacters: [], order: {}, gifts: [], hiddenGifts: [], nudges: {},
    });
    assert.deepEqual(empty, {
        schema: 1, characters: [], hidden_characters: [], order: {}, gifts: [], hidden_gifts: [], nudges: {},
        features: {},
    });
});

test('a wallet read prices the added gifts and honours a reprice', async () => {
    const { env: e } = env();
    const prices = (await call(e, '/api/wallet')).json.wallet.prices.gift;
    assert.equal(prices.lilies, 80);
    assert.equal(prices.lyre, 900);
    assert.equal(prices.roses, 60, 'repriced from the catalogue');
    assert.equal(prices.pendant, 500, 'untouched gifts keep their price');
});

test('an added character answers in its own persona', async (t) => {
    const { env: e } = env();
    const bodies = stubOpenAi(t);
    const res = await call(e, '/api/chat', {
        method: 'POST',
        headers: { 'x-character-id': 'achilles', 'x-visit-id': 'v' },
        body: { messages: [{ role: 'user', content: 'Was it worth it?' }] },
    });
    assert.equal(res.status, 200);
    assert.ok(bodies.at(-1).includes('You are Achilles, Best of the Greeks.'));
    assert.ok(bodies.at(-1).includes('chose a short life'));
});

test('an added gift is charged at its price and the character is told what it is', async (t) => {
    const { env: e, db } = env();
    const bodies = stubOpenAi(t);
    fund(db, 2000);
    const res = await call(e, '/api/chat', {
        method: 'POST',
        headers: { 'x-character-id': 'achilles', 'x-visit-id': 'v' },
        body: {
            messages: [{ role: 'user', content: '*gives a spray of lilies to Achilles*' }],
            gift: { id: 'lilies_0000000001', item: 'lilies' },
        },
    });
    assert.equal(res.status, 200);
    assert.deepEqual(giftDebits(db), [-80]);
    assert.ok(bodies.at(-1).includes('a spray of white lilies'));
});

test('an added keepsake is given once, listed as held, and remembered in the prompt', async (t) => {
    const { env: e, db } = env();
    const bodies = stubOpenAi(t);
    fund(db, 3000);
    const give = (id) => call(e, '/api/chat', {
        method: 'POST',
        headers: { 'x-character-id': 'achilles', 'x-visit-id': 'v' },
        body: { messages: [{ role: 'user', content: '*gives a lyre to Achilles*' }], gift: { id, item: 'lyre' } },
    });
    await give('lyre_00000000001');
    await give('lyre_00000000002');
    assert.deepEqual(giftDebits(db), [-900], 'a keepsake cannot be bought twice for the same character');

    const wallet = (await call(e, '/api/wallet')).json.wallet;
    assert.deepEqual(wallet.keepsakes.map((k) => [k.item, k.ref]), [['lyre', 'achilles']]);

    await call(e, '/api/chat', {
        method: 'POST',
        headers: { 'x-character-id': 'achilles', 'x-visit-id': 'v' },
        body: { messages: [{ role: 'user', content: 'Play something.' }] },
    });
    assert.ok(bodies.at(-1).includes('You play it when you are alone'));
});

test('a character id that is a property of every object is nobody', async (t) => {
    // x-character-id is client-supplied; "constructor" must not resolve to a
    // persona-shaped function and crash the prompt builder.
    const { env: e } = env();
    stubOpenAi(t);
    const res = await call(e, '/api/chat', {
        method: 'POST',
        headers: { 'x-character-id': 'constructor', 'x-visit-id': 'v' },
        body: { messages: [{ role: 'user', content: 'Hello.' }] },
    });
    assert.equal(res.status, 200);
});
