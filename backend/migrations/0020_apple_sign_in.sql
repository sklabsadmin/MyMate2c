-- Sign in with Apple + account deletion.
--
-- apple_refresh_token / apple_client_id: Apple requires an app that lets
-- people create an account to let them delete it, and deleting it must revoke
-- the Sign in with Apple token (App Review 5.1.1(v)). Revoking needs the
-- refresh token from the first code exchange and the client id that minted it
-- (the bundle id for the app, the Services ID for the web), so both are kept
-- on the linked account row. The refresh token is only usable together with
-- our .p8-signed client secret.
ALTER TABLE linked_accounts ADD COLUMN apple_refresh_token TEXT;
ALTER TABLE linked_accounts ADD COLUMN apple_client_id TEXT;

-- One row per deleted account. Sessions are stateless HMAC tokens, so a
-- token issued before the deletion would otherwise keep working until it
-- expired; getSessionFromRequest refuses any session for this user_id issued
-- (iat_ms) at or before deleted_at. Signing in again later with the same Apple
-- or Google account is a fresh start and works normally (its iat is later).
CREATE TABLE IF NOT EXISTS account_deletions (
    user_id TEXT PRIMARY KEY,
    deleted_at INTEGER NOT NULL  -- unix ms
);
