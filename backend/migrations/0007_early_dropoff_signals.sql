-- Measuring where visitors quit in their first few minutes, and specifically
-- how far into a conversation they get.
--
-- The funnel could not answer either question. login_gate does not fire until
-- AppConfig.freeRepliesPerCharacter (20) replies, and first_message is
-- one-shot, so messages 2-19 emitted nothing at all — the whole range where
-- people actually give up was invisible.
--
-- Rather than add a beacon per message, the fix is to give conversation_logs
-- the session key it was missing. It already holds one row per message with a
-- created_at; joined to site_visits on visit_id, the full 1->N progression,
-- the gaps between messages, and which session bounced all fall out of a
-- GROUP BY. No new client events needed for any of it.

-- Which browser visit a message belongs to. conversation_logs had only
-- user_id, which spans days and devices — useless for "how far did this
-- session get". Sent by the client as x-visit-id; the same id the splash
-- beacon already generates, so these rows join straight onto the
-- arrive/app_ready/leave rows for the same visit.
--
-- NULL for any request that predates this, and for the mobile app (there is
-- no page, so no visit).
ALTER TABLE conversation_logs ADD COLUMN visit_id TEXT;

-- How long the reply actually took, end to end, in milliseconds.
--
-- created_at is insert time for the whole request, which cannot distinguish a
-- 400ms reply from a 12s one — and a slow first reply is among the most
-- plausible reasons someone leaves inside a minute. runInworldPipeline already
-- computed this and threw it at console.log, so it expired with log retention
-- and could never be queried next to drop-off; the plain-OpenAI path (every
-- character except Oedipus) was not timed at all. Now both are, on the row.
ALTER TABLE conversation_logs ADD COLUMN latency_ms INTEGER;

-- Viewport width at arrival. The app is built as a portrait phone experience
-- (see AppConfig.maxContentWidth) and stretches awkwardly on desktop, but
-- nothing recorded whether wide-viewport visitors bounce harder. user_agent
-- can be parsed for device class; it cannot tell you the window was 2560px.
ALTER TABLE site_visits ADD COLUMN viewport_w INTEGER;

-- Why a send_failed event fired.
--
-- A request that never reaches the worker — network drop, timeout, DNS —
-- leaves no conversation_logs row at all, by definition. So "their message
-- silently failed" and "they never typed anything" were identical in the
-- data. The client reports those itself via a send_failed event; this column
-- carries the reason.
--
-- Deliberately its own column rather than packed into `detail`: detail means
-- "which character" for every other event, and migration 0005 exists because
-- overloading a column that way corrupts the grouping that depends on it.
ALTER TABLE site_visits ADD COLUMN failure_reason TEXT;

-- The funnel aggregates all filter by visit plus event; without this they scan.
CREATE INDEX IF NOT EXISTS idx_site_visits_visit_event
    ON site_visits (visit_id, event);

CREATE INDEX IF NOT EXISTS idx_conversation_logs_visit_created
    ON conversation_logs (visit_id, created_at);
