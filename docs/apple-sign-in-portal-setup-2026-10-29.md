# Sign in with Apple: portal setup runbook (2026-10-29)

**Done 2026-10-29.** Portal steps 1-3 and the five worker secrets are in
place (key ID `ZYXGAVTXRJ`, file kept outside the repo in
`~/Downloads/appledev/`). Web sign-in verified live: Continue with Apple on
chat.deeploveechoes.com lands back on Settings showing "Signed in with
Apple", and the account row in `linked_accounts` carries a refresh token, so
revocation on delete will work. Still to do: the iOS device test plan and
the App Store Connect privacy update (steps 5-6 below).

Testing pitfall: the web build's API base is `chat.deeploveechoes.com`
(`tool/build_web.sh`). Start the flow on that host. Starting it by hand on
chat.deeplovepoems.com puts the session cookie on the wrong host and
Settings stays signed out even though the worker created the account.

Status of the code: **done and on `main`** (merged 2026-10-27 as part of
1.0.6+98). Nothing in the app or worker needs to change for Apple login.
Background and test plan: `docs/HANDOFF-sign-in-2026-10-26.md`.

## What is already in the repo

| Piece | Where | State |
|---|---|---|
| Native iOS sheet, nonce, ID token, name capture | `lib/src/core/services/auth_service.dart` | done |
| Apple + Google buttons together everywhere | `lib/src/features/auth/presentation/sign_in_sheet.dart` | done |
| iOS entitlement `com.apple.developer.applesignin` | `ios/Runner/Runner.entitlements`, wired in `project.pbxproj` for Debug/Release/Profile | done |
| Revoked-credential check on launch | `auth_service.dart` (`_appleCredentialRevoked`) | done |
| Worker: token verification against Apple JWKS, nonce, audience | `backend/src/identity.js` | done, tested |
| Worker: `POST /auth/native` (app), `/auth/apple/start` + `/auth/apple/callback` (web) | `backend/src/worker.js` | done, tested |
| Worker: code exchange for refresh token, revoke on account delete | `identity.js`, `worker.js` | done, tested |
| D1 migration `0020_apple_sign_in.sql` | `backend/migrations/` | applied by `npm run deploy` |
| Tests | `backend/test/sign_in.test.mjs` | 151/151 pass (2026-10-29) |
| `flutter analyze` | | 0 errors, 0 warnings (103 infos, all pre-existing style) |

Not done, by design: Android sign-in, Apple server-to-server notifications,
account linking across providers (see the handoff doc).

## Values to use in the portal

| Item | Value |
|---|---|
| Team | SK Labs Limited Liability Company, **TG5RWCPY3K** |
| App ID (iOS bundle id) | `com.sklabs.mythoslive` |
| Services ID (web, create new) | `com.sklabs.mythoslive.web` |
| Web domains | `chat.deeploveechoes.com`, `chat.deeplovepoems.com` |
| Return URLs | `https://chat.deeploveechoes.com/auth/apple/callback`, `https://chat.deeplovepoems.com/auth/apple/callback` |
| Key name | `Mythos Live Sign in with Apple` |

The worker accepts tokens whose audience is either the bundle id (app) or
the Services ID (web), see `appleAudiences` in `identity.js`, so both must
be exactly as above.

## Portal steps (developer.apple.com, signed in as the account holder)

Sign in at https://developer.apple.com/account and open
**Certificates, Identifiers & Profiles**.

### 1. App ID: enable the capability

1. **Identifiers** → filter *App IDs* → open `com.sklabs.mythoslive`.
2. Tick **Sign in with Apple**. Leave *Enable as a primary App ID* selected.
   Do not set a server-to-server notification endpoint (not implemented).
3. **Save** → confirm. Existing provisioning profiles are invalidated; Xcode
   automatic signing regenerates them on the next build.

### 2. Services ID: the web client

1. **Identifiers** → **+** → choose **Services IDs** → Continue.
2. Description `Mythos Live web`, Identifier `com.sklabs.mythoslive.web` →
   Continue → Register.
3. Open the new Services ID → tick **Sign in with Apple** → **Configure**.
4. Primary App ID: `com.sklabs.mythoslive`.
5. Domains and Subdomains (one per line):
   `chat.deeploveechoes.com`
   `chat.deeplovepoems.com`
6. Return URLs (one per line):
   `https://chat.deeploveechoes.com/auth/apple/callback`
   `https://chat.deeplovepoems.com/auth/apple/callback`
7. Next → Done → Continue → **Save**.

### 3. Key: signs the client secret and revocation

1. **Keys** → **+**.
2. Key Name `Mythos Live Sign in with Apple`. Tick **Sign in with Apple** →
   **Configure** → Primary App ID `com.sklabs.mythoslive` → Save.
3. Continue → Register.
4. **Download** the `.p8` once (Apple never offers it again) and write down
   the **Key ID** (10 characters). Keep the file out of the repo; `*.p8` is
   gitignored.

Without this key, sign-in still works but account deletion cannot revoke
the Apple token, which App Review 5.1.1(v) expects.

### 4. Worker secrets (on the Mac, in the repo folder)

```sh
npx wrangler secret put APPLE_BUNDLE_ID        # com.sklabs.mythoslive
npx wrangler secret put APPLE_SERVICES_ID      # com.sklabs.mythoslive.web
npx wrangler secret put APPLE_TEAM_ID          # TG5RWCPY3K
npx wrangler secret put APPLE_KEY_ID           # the Key ID from step 3
npx wrangler secret put APPLE_PRIVATE_KEY < ~/Downloads/AuthKey_<KEYID>.p8
npx wrangler secret list                       # SESSION_SECRET must be present
```

`SESSION_SECRET` matters: without it sessions are signed with `APP_SECRET`,
which ships inside the app binary. Set it if `secret list` does not show it.

### 5. Deploy and verify

```sh
npm run deploy
```

Then:

```sh
curl -sI "https://chat.deeplovepoems.com/auth/apple/start?return_to=/" | head -5
```

A `302` to `appleid.apple.com` means the Services ID and secrets are wired.
A `503 Apple sign-in is not configured` means `APPLE_SERVICES_ID` is missing.

Web test: open https://chat.deeplovepoems.com, Settings → Continue with Apple.
An Apple error page saying *invalid_client* or *invalid redirect_uri* means
step 2's domains or return URLs do not match exactly.

iOS test: build from `main` on the Mac (Xcode → Runner → Signing &
Capabilities should list *Sign in with Apple*), then follow the test plan in
`docs/HANDOFF-sign-in-2026-10-26.md`. The native path needs only
`APPLE_BUNDLE_ID` to sign in; it needs the key as well to store the refresh
token for deletion.

### 6. App Store Connect

- **App Privacy**: add Name, Email Address, User ID, Purchase History, Other
  User Content as *linked to the user* (sign-in is optional).
- **Review notes**: paste the paragraph from the handoff doc.
