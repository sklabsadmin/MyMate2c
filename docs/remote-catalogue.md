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

Ada is the worked example: her entry in `backend/src/catalogue.js` is the
first character added this way. Her portrait is a placeholder card
(`assets/images/avatar_ada_placeholder.jpg`) that prints her name. To swap in
real pictures, save the square portrait over that file, or add a new file and
change `image`, then deploy.

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

The "come back" notifications scheduled when the app is left are written as
the characters the person talks to most, by messages exchanged, each in that
character's voice:

| After leaving | From |
|---|---|
| 4 hours | the character they talk to most |
| 1 day | the character they talk to most |
| 2 days | their second |
| 3 days | the character they talk to most |
| 5 days | their third |

With two characters that is four notifications, with one it is three. The older
reminder an hour after leaving an open conversation is gone; the four-hour
notification replaces it. Tapping one
opens that conversation. Each is titled "Zeus says" with the line beneath.
Someone with no chats yet gets the app-level lines as
before. App-level notifications, including the daily dawn and nightfall ones, are
titled "In the Greek World · " followed by their heading.

Times that would land between 21:30 and 09:30 move to 10:30 the following
morning. All of it is the phone's own clock.

A line may mention the time of day. The planner reads the words and only
uses a line at a matching hour: "tonight", "evening", "sunset" from 17:00;
"morning", "dawn" before noon; "afternoon" from noon to 18:00; "how your day
went", "all day" from 15:00. So each character needs at least three lines
that are true at any hour, and a test counts them. Lines sent through the
catalogue are held to the same rule with no extra markup. Do not name a day
of the week in a line; nothing checks that against the calendar.

One limit: times are fixed when the app is left. Someone who then flies to
another time zone gets them at the old zone's hour until they next open the
app, which reschedules everything.

The lines live in `lib/src/core/data/character_nudges.dart`, with the rules
they are written to at the top of that file. They are local notifications: no
push certificate, no server, no device token. The worker can replace any
character's lines through the catalogue.

## Leaderboards

Each roster character has a leaderboard: everyone who has given them a gift,
ranked by the coins those gifts cost. It opens from a button on the
character's profile, and a snackbar offers it after a gift ("You are #3 on
Zeus's leaderboard. View").

The trophy button in the dashboard header opens the Leaderboards menu: one
row per character showing who leads and where the viewer stands, each
opening that character's board (`GET /api/leaderboard/summary`).

There is also an all-characters board, at the top of that menu and as a
second tab on a character's board. It lists people who have given two or
more gifts, and it is only sent to someone who has done the same. Until then
the app shows no tab and no hint that it exists.

- **User numbers, not names.** Every other person on a board is shown as a
  generated number such as "User 482913". The viewer's own row says "You".
  Nothing one person typed is visible to another, so there is no
  user-written content on a board and App Store Guideline 1.2 does not come
  into it. The number is a keyed hash of the user id: stable for that
  person, not a count of anything, and not reversible.
- **Names are collected, not shown.** If someone has a Name in their profile
  the app passes it to the worker to keep (`leaderboard_names` table,
  migration 0022). It is filtered on the way in and never displayed.
- **Chosen names are built and switched off.** `features.leaderboard_names`
  in `backend/src/catalogue.js` turns them on with no app release. With it
  on, the app requires a display name before a gift (the profile's Name, or
  a prompt the gift waits on), boards show chosen names, and each one
  carries a report flag. Three different reporters hide a name
  automatically, and a person can review, hide and restore:

  ```sh
  curl -u admin:$ADMIN_TOKEN https://logs.deeplovepoems.com/api/admin/leaderboard-names
  curl -u admin:$ADMIN_TOKEN -X POST -H 'content-type: application/json' \
    -d '{"ref":"<ref>","hidden":true}' \
    https://logs.deeplovepoems.com/api/admin/leaderboard-names
  ```

  A name collected while the switch was off is NOT published when it is
  turned on. Its owner was never told it would be public, so it is shown
  only after they next give a gift from a build that says so. Before turning
  it on, read Guideline 1.2 and tell App Review: names are user-written text
  shown to strangers, which is why the filter, flag and auto-hide exist.
- **Read from the ledger.** `backend/src/leaderboard.js` groups the gift rows
  in `coin_ledger`. Migration 0021 adds the index; 0022 adds the two small
  tables for names and reports. Developer wallets (dev-marked visits) are left off.
- **Ties** go to whoever reached the total first.
- **Off switch.** `LEADERBOARDS` in `wrangler.jsonc`; the exact string
  `"false"` turns it off and the app says "not available".
- **Tuning.** `BOARD_SIZE` (10) and `GLOBAL_MIN_GIFTS` (2) are constants at
  the top of the module. Changing them needs no app release.

## Stopping the app: "please update" and "back shortly"

Two settings under `app` in `backend/src/catalogue.js` let the worker hold
the app. Builds from 1.0.7 on obey them; 1.0.6 and earlier never ask and
cannot be told anything. Both ship open and `npm test` fails if either is
changed without also changing the test that says so.

**Please update.** `min_build: { ios: 0, android: 0 }` is the oldest build
number still supported in each store. An app whose own build number is lower
shows one screen, "Time to update", with a button to the store.

- Raise it only after the newer build is live in that store. The screen sends
  people there to get it.
- `update_url` holds the store links the button opens. A store left empty
  gets no button and a sentence telling people to open the store. Only App
  Store and Google Play links are accepted, by the worker's check and again
  by the app.
- The web is never asked to update. It is always the current bundle.

**Back shortly.** `maintenance: true` puts every app, web included, on a
holding screen. `maintenance_message` replaces the default sentence. The
screen re-checks once a minute and has a "Try again" button, so it lifts on
its own when the setting goes back to `false`.

How it avoids locking people out:

- A phone that cannot reach the worker never shows the maintenance screen. It
  is only shown on an answer the worker gave during that launch, not on one
  remembered from earlier.
- An unknown build number, an unknown store, or a response that does not
  parse all mean "carry on".
- "Please update" is honoured from the remembered catalogue, because a
  minimum only goes up.

Phones pick a change up at launch and on return to the foreground. The
catalogue is cached for five minutes at the edge, so allow that long.

For one feature rather than the whole app, use the narrower switches:
`LEADERBOARDS` in `wrangler.jsonc`, `hiddenCharacters`, `hiddenGifts`, and
`features` in the catalogue.

## The version line in Settings

Settings shows one line: `1.0.6 build 99 · server build 100`. The first half
is the app's own version and build. The second is the build number of the
web bundle the worker was deployed with, read by the worker from that
bundle's `version.json` and sent in the catalogue. Only the server's build
number is shown, never its version, so nobody sees two version numbers that
differ. Offline, or before the first fetch, the line is the app's half alone.

`npm run deploy` builds the web app and deploys the worker together, so
bumping the build number in `pubspec.yaml` before a deploy is what moves the
server build.

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
