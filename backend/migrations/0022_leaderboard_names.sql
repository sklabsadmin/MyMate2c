-- Display names on the gift leaderboards (backend/src/leaderboard.js).
--
-- A name is here only because its owner sent it for this purpose — the app
-- asks for one before a first gift. It is deliberately NOT read from
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
