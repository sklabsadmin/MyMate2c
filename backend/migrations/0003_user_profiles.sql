-- The player's own profile, for signed-in users only.
--
-- Keyed by user_id in the same form linked_accounts uses ('google:<sub>'), so
-- the two join directly. provider/provider_id are stored explicitly as well:
-- the Google ID is the thing that actually identifies the person across
-- devices, and keeping it on the row means a profile can be found by Google
-- identity without a join, and survives any future change to how user_id is
-- composed.
--
-- Anonymous users are deliberately absent. Their id is a client-generated
-- 'user_<timestamp>' that nothing verifies, so a row here keyed to one would be
-- readable and writable by anyone who guessed it. They keep the device-local
-- SharedPreferences copy instead.
CREATE TABLE IF NOT EXISTS user_profiles (
    user_id TEXT PRIMARY KEY,
    provider TEXT NOT NULL,
    provider_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

    name TEXT,
    age TEXT,
    gender TEXT,
    pronouns TEXT,
    location TEXT,
    hobbies TEXT,
    turn_ons TEXT,

    avatar_emoji TEXT,
    -- Base64 data URI, downscaled to 512px/75% quality client-side before it
    -- ever gets here. Kept small on purpose: D1 is not a blob store.
    avatar_photo TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_user_profiles_provider_id
    ON user_profiles(provider, provider_id);
