-- Display names on the gift leaderboards (backend/src/leaderboard.js).
--
-- WHAT A BOARD SHOWS is decided by one worker switch,
-- SERVER_CATALOGUE.features.leaderboard_names (backend/src/catalogue.js):
--   off (now)  every row is a generated user number, "User 482913". Nothing
--              anyone typed is shown to anyone else. Names people have set
--              in their profile are still stored here, for later.
--   on         a row shows the name its owner chose, once they have been
--              told it is public; everyone else keeps their number.
--
-- A name is here only because its owner's app sent it for this purpose. It is deliberately NOT read from
-- user_profiles.name: that field was typed as "what should they call you?"
-- for the characters, by people who were never told anyone else would see
-- it, and it only exists for signed-in accounts anyway. Most givers are
-- anonymous devices.
--
-- `ref` is what a board row carries instead of a user id, so that someone
-- can be reported without the app ever learning who they are. `hidden` puts
-- the row back to its generated alias: set by enough reports, or by hand.
CREATE TABLE IF NOT EXISTS leaderboard_names (
    user_id    TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    ref        TEXT NOT NULL,
    hidden     INTEGER NOT NULL DEFAULT 0,
    -- 1 only when the name was sent by an app that had just told its owner
    -- it would be shown on leaderboards. While the boards show user numbers
    -- (SERVER_CATALOGUE.features.leaderboard_names off) names arrive with 0:
    -- kept, never displayed, and still not displayed on the day the switch
    -- is turned on — their owners were not asked.
    noticed    INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_leaderboard_names_ref
    ON leaderboard_names (ref);

-- One row per (reporter, reported name). The name is copied in because the
-- report is about the text that was on screen, which its owner may change.
CREATE TABLE IF NOT EXISTS leaderboard_name_reports (
    reporter_id      TEXT NOT NULL,
    reported_user_id TEXT NOT NULL,
    name             TEXT NOT NULL,
    created_at       TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (reporter_id, reported_user_id, name)
);

CREATE INDEX IF NOT EXISTS idx_leaderboard_name_reports_reported
    ON leaderboard_name_reports (reported_user_id, created_at);
