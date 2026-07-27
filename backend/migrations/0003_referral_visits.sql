-- One row per /c/<character> campaign-link arrival.
--
-- Separate from conversation_logs on purpose: most link traffic never sends a
-- message, and those visits are exactly what we need to see to judge whether a
-- post worked. Joining on character_id shows the arrival-to-conversation rate.
CREATE TABLE IF NOT EXISTS referral_visits (
    id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    character_id TEXT,
    -- utm_source when supplied, else derived: "instagram"/"facebook" from the
    -- in-app browser user-agent, else the referring hostname, else "direct".
    source TEXT,
    utm_medium TEXT,
    utm_campaign TEXT,
    referer TEXT,
    user_agent TEXT,
    -- 0 when the id matched no character, i.e. a mistyped or retired link.
    known_character INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_referral_visits_created_at
    ON referral_visits(created_at);

CREATE INDEX IF NOT EXISTS idx_referral_visits_source_created_at
    ON referral_visits(source, created_at);

CREATE INDEX IF NOT EXISTS idx_referral_visits_character_created_at
    ON referral_visits(character_id, created_at);
