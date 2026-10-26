# Sign in with Google + Apple — handoff (2026-10-26)

Branch: `feat/sign-in-google-apple`. Replaces the never-pushed
`feat/sign-in-apple-google-email` (no email-code login in this pass).

Scope: **iOS and web.** Android shows no sign-in (see "Not done").

## What it does

| | Web | iOS |
|---|---|---|
| Google | Redirect flow (unchanged) | Native sheet → ID token → `POST /auth/native` |
| Apple | **New** redirect flow, `/auth/apple/start` → Apple → `POST /auth/apple/callback` | Native sheet → ID token + nonce → `POST /auth/native` |
| Session | `mymate_session` cookie | Same signed payload, kept in the keychain, sent as `Authorization: Bearer` |
| Sign out | `/auth/logout` → `/signed-out` | Forget token; back to the device's anonymous id |
| Delete account | Settings → Account → Delete account | same |

- The worker verifies every ID token itself against Google's / Apple's
  published keys (RS256 only; issuer, audience, expiry; Apple nonce). The app
  is never trusted for identity. Code: `backend/src/identity.js`.
- User ids: `google:<sub>`, `apple:<sub>`. Anonymous chat history and the coin
  wallet merge onto the account on sign-in exactly as the web Google flow
  always did, merge ticket included.
- **New:** a second device (iPad, reinstall) also merges its wallet into an
  existing account, when it proves ownership with a merge ticket. Before, only
  the first device ever merged.
- RevenueCat switches to the account id on sign-in (and at launch when signed
  in), back to the device id on sign-out, so purchases land in the wallet that
  follows the person.
- **Delete account** revokes the Apple token, deletes chat logs, delivery
  receipts, profile, gift reactions, wallet, linked accounts and the
  RevenueCat customer; coin ledger and RevenueCat event rows are kept under an
  unlinkable `deleted:<uuid>` id for accounting. Sessions issued before the
  deletion stop working (`account_deletions` table).
- Sign-in prompts (Apple and Google always together — `SignInButtons`):
  Settings → Account; after a signed-out profile save; **once right after the
  first coin pack lands** ("Protect your coins"); the store footer; the web
  chat gate and `/signed-out` page. Native still has **no forced gate** —
  sign-in stays optional.

## Setup — must be done before it works

### 1. Apple Developer (team TG5RWCPY3K)

1. **Identifiers → App ID `com.sklabs.mythoslive`** → enable *Sign in with
   Apple*. (Xcode automatic signing usually does this on first build with the
   new entitlement; confirm in the portal.)
2. **Identifiers → + → Services IDs** → e.g. `com.sklabs.mythoslive.web`.
   Enable *Sign in with Apple* → Configure: primary App ID
   `com.sklabs.mythoslive`; domains `chat.deeploveechoes.com`,
   `chat.deeplovepoems.com`; return URLs
   `https://chat.deeploveechoes.com/auth/apple/callback` and
   `https://chat.deeplovepoems.com/auth/apple/callback`.
3. **Keys → +** → enable *Sign in with Apple*, primary App ID
   `com.sklabs.mythoslive`. Download the `.p8` (only downloadable once) and
   note the Key ID. This key signs the client secret used for the code
   exchange and for **revoking tokens on account deletion** — without it,
   sign-in works but deletion cannot revoke (App Review 5.1.1(v) expects it).

### 2. Google Cloud (the project that holds the existing web client)

1. **Credentials → Create OAuth client ID → iOS**, bundle id
   `com.sklabs.mythoslive`. Copy the client id and the "iOS URL scheme"
   (reversed client id).
2. Put both into `ios/Flutter/GoogleSignIn.xcconfig` (replace `REPLACE_ME`).
3. **OAuth consent screen** must be *In production*, not *Testing*, or only
   listed test users can sign in.

### 3. Worker secrets

```sh
npx wrangler secret put GOOGLE_IOS_CLIENT_ID      # the iOS client id from step 2
npx wrangler secret put APPLE_BUNDLE_ID           # com.sklabs.mythoslive
npx wrangler secret put APPLE_SERVICES_ID         # the Services ID from step 1.2
npx wrangler secret put APPLE_TEAM_ID             # TG5RWCPY3K
npx wrangler secret put APPLE_KEY_ID              # from step 1.3
npx wrangler secret put APPLE_PRIVATE_KEY < AuthKey_XXXXXXXXXX.p8
npx wrangler secret list                          # confirm SESSION_SECRET is set
```

**Check `SESSION_SECRET` exists.** Sessions are HMAC-signed with
`SESSION_SECRET`, falling back to `APP_SECRET` — and `APP_SECRET` ships inside
the app binary. If `SESSION_SECRET` is missing, anyone who extracts the app
could forge a session for any account, and with bearer tokens that now
includes every iOS user. Setting it (any long random string) signs out
existing web sessions once; that is the right trade.

### 4. Deploy the worker

`npm run deploy` — it applies migration `0020_apple_sign_in.sql` before
deploying. Nothing breaks if the worker deploys before the iOS build ships:
the web keeps working, `/auth/native` simply has no callers yet.

### 5. Build iOS (Mac)

```sh
git fetch && git checkout feat/sign-in-google-apple
flutter pub get
cd ios && pod install && cd ..
flutter analyze
```

The Dart was written without a Flutter SDK available, so `flutter analyze`
on the Mac is the first real compile — expect to fix anything it reports
before building. In Xcode, Runner → Signing & Capabilities should now show
*Sign in with Apple*. Bump the version (1.0.6 or 1.1) before upload.

## Test plan

iOS (device, sandbox account for purchases):
1. Fresh install → Settings → Continue with Apple → signed in; +100 coins;
   existing coins kept.
2. Sign out → coins disappear from the chip (they're on the account) → sign in
   with the same Apple ID → coins back.
3. Same with Google.
4. Signed out, buy a pack → "Protect your coins" sheet appears once; never
   again on the next purchase.
5. Sign in on a second device with the same account → both devices' coins
   end up in one wallet.
6. Delete account → confirm → signed out. iOS Settings → Apple ID → Sign in
   with Apple should no longer list Mythos Live (revoked). Signing in again
   starts a fresh account.

Web: Continue with Apple → Apple page → back where you started, signed in;
Google unchanged; Delete account lands on `/signed-out?deleted=1`.

Backend: `npm test` (12 new tests in `backend/test/sign_in.test.mjs` — real
RS256/ES256 crypto, forged/expired/foreign tokens refused, nonce, merge
rules, the web Apple flow, deletion).

## App Review notes (paste into the submission)

- Sign-in is optional; the app is fully usable without an account.
- Sign in with Apple is offered alongside Google everywhere (4.8).
- Account deletion: Settings → Account → Delete account. Deletes the account
  and its data and revokes the Sign in with Apple token (5.1.1(v)).

## Not done / follow-ups

- **Android:** no sign-in UI (hidden). Needs an Android OAuth client with the
  upload-key and Play app-signing SHA-1s, plus Apple via the web flow in a
  Custom Tab.
- **Apple server-to-server notifications** (user stops using Apple ID with the
  app, or deletes their Apple account) are not handled. Optional; endpoint is
  set per App ID in the portal.
- **Google button mark:** uses a Material placeholder icon. Drop in the
  official "G" from Google's sign-in branding kit (TODO in
  `sign_in_sheet.dart`).
- **Apple and Google are separate accounts.** Someone who signs in with Google
  on the web and Apple on the phone gets two wallets. No account linking yet.
- **Private relay email:** if Mythos Live ever emails users, the sending
  domain must be registered with Apple's private email relay first.
