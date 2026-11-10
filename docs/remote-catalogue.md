# Remote catalogue: adding characters and gifts without an app release

Since the build that carries this change, the app asks the worker what has
been added or changed since it was built. A new character, a new gift, a
rewritten blurb, a reprice or a retired card is a worker deploy. No App Store
or Play submission.

Builds older than this one never ask. They keep the roster and gifts they were
compiled with, and the worker keeps serving them.

## How it fits together

| Piece | Where | What it does |
|---|---|---|
| The data | `backend/src/catalogue.js` | The one file you edit. Starts empty. |
| The endpoint | `GET /api/catalogue` in `backend/src/worker.js` | Serves the public half: no personas, no keepsake notes, no narration. Unsigned, cached five minutes. |
| The store | `lib/src/core/data/remote_catalogue.dart` | Loads the last fetched copy before first paint, refreshes at launch and on resume, merges over the bundled data. |
| The bundled data | `characters.dart`, `character_profiles.dart`, `coins_sheet.dart`, `character_nudges.dart` | What the build shows with no network. Still the source of truth for everything that shipped. |

The catalogue is a delta. An entry whose id the app does not know is added. An
entry whose id it does know replaces only the fields it carries. With an empty
catalogue the app is exactly the build.

## Add a character

1. Put the portrait in `assets/images/` (square JPEG, same treatment as the
   others). It is published at `<origin>/assets/assets/images/<file>` by the
   next web build; the app fetches it from there.
2. Add an entry to `characters` in `backend/src/catalogue.js`. The template is
   in the comment above the list. A new character needs every presentation
   field, a `profile`, a `persona`, and ideally three `nudges`.
3. `npm test`. `backend/test/catalogue.test.mjs` holds the shipped file to its
   rules and checks the image file exists.
4. Deploy as usual (`npm run deploy`). The web build must be part of it, since
   that is what publishes the image.

The character appears at the end of its tab. To place it, set
`order: { greek: ["newid", "odysseus", ...] }`. Ids you leave out follow in
the app's own order.

Phones pick it up at next launch or resume, at most ten minutes stale. The
share link `/c/<id>` works immediately, including on a phone that has not
launched since: the route waits for the catalogue before deciding the id is
unknown.

## Add a gift

1. Put the art in `assets/images/` (256px PNG cut-out, like the others).
2. Add an entry to `gifts` in `backend/src/catalogue.js`: `item`, `label`,
   `detail`, `image`, `price`, `once`, `narration`, optionally `giving`. A
   keepsake (`once: true`) also needs `keepsakeNote`, plus `heldBadge` and
   `heldDetail` for the sheet.
3. `npm test`, deploy.

The price in that entry is the price charged. The sheet shows what the wallet
read says, and the wallet read comes from the same table, so the two cannot
disagree. Gifts are listed cheapest first.

Hearts: `AppConfig.tributeHeartScore` is compiled in, so a gift added this way
scores no hearts until a build adds it there.

## Change or remove something that already shipped

- **Rewrite a card:** `{ id: "zeus", desc: "..." }` in `characters`. Any of
  name, vibe, desc, tagline, image, color, group, profile, nudges.
- **Reprice or relabel a gift:** `{ item: "roses", price: 60 }` in `gifts`.
  `once` cannot be changed on an existing gift. The ledger keys of everything
  already given depend on it, and both sides refuse.
- **Retire a character:** add the id to `hiddenCharacters`. It leaves the
  dashboard. Existing chats keep working.
- **Retire a gift:** add the item to `hiddenGifts`. It leaves the sheet.
  Keepsakes already given still show on profiles.
- **Notification lines for a shipped character:** `nudges: { zeus: [...] }`.

A shipped character's persona is not overridable from the catalogue. Edit
`CHARACTER_PERSONAS` in `worker.js` as before; that was already release-free.

## Notifications from characters

The three "come back" notifications scheduled when the app is left (four
hours, one day, three days) are now written as the characters the person has
talked to, most recent first, each in that character's voice. Tapping one
opens that conversation. Someone with no chats yet gets the app-level lines as
before. The daily dawn and nightfall notifications are unchanged.

It is the same three slots, not three more. Times that would land between
21:30 and 09:30 move to 10:30 the following morning.

The lines live in `lib/src/core/data/character_nudges.dart`, with the rules
they are written to at the top of that file. They are local notifications: no
push certificate, no server, no device token. The worker can replace any
character's lines through the catalogue.

## What still needs an app release

- Hearts for a new gift (see above).
- Anything that is new code rather than new content: a new screen, a new kind
  of gift behaviour, a new tab on the dashboard.
- Server push notifications, if they are ever wanted. These are local.

Coin packs were already release-free and are not part of this file: the store
screen lists whatever is in the RevenueCat offering AND in `COIN_PACKS` in
`worker.js`. A new pack is a product in App Store Connect and Play, a package
in the RevenueCat offering, and a line in `COIN_PACKS`.

## Limits worth knowing

- Remote portraits are held in memory, not on disk. A character added after
  the build shows a blank tile if the phone is offline at launch. Adding the
  image to the next build fixes that for good: the app prefers a bundled file
  whenever the path matches.
- The response carries `schema: 1`. A build ignores any catalogue with a
  higher number, so bump `CATALOGUE_SCHEMA` only for a change old builds would
  misread.
- `logs.deeplovepoems.com` bounces `/api/catalogue` like every non-admin path.
