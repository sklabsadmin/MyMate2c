-- Operational alerts the worker has raised, one row per alert key.
--
-- The first alert is "a provider says we are out of credit": OpenAI's
-- insufficient_quota 429, a 402 from anyone, or an error body that talks
-- about billing or balance. Every chat turn fails identically once that
-- happens, so without a throttle the inbox would get one email per message.
-- This table is the throttle: last_sent_at gates a resend (one per hour per
-- key), and the counters say how many turns failed between emails, which is
-- the number worth knowing when the email does arrive.
--
-- alert_key is "<provider>:<kind>", e.g. "openai:out_of_funds".
CREATE TABLE IF NOT EXISTS ops_alerts (
    alert_key TEXT PRIMARY KEY,
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    last_sent_at TEXT,
    seen_count INTEGER NOT NULL DEFAULT 0,
    sent_count INTEGER NOT NULL DEFAULT 0,
    last_detail TEXT
);
