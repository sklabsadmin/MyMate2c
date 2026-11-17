-- Which client the person is actually using: ios, android or web.
--
-- "How many iOS users signed in this week" was unanswerable from this
-- database. Three attempts to answer it from production on 2026-11-17 each
-- failed for a different reason, and the three reasons are worth writing down
-- because they are what this migration is shaped around:
--
--   * site_visits.platform looks like the answer and is not. Migration 0008
--     built it as TRAFFIC SOURCE — instagram / facebook / direct, derived from
--     the in-app browser's user-agent and then the referring host. It has
--     never held a device, and in live data it has since drifted further
--     still: the recent rows hold hostnames (chat.deeploveechoes.com,
--     chat.deeplovepoems.com) rather than any of the values 0008 documents.
--     That drift is a separate bug and is NOT addressed here; this migration
--     only stops the two questions sharing a word. See the naming note below.
--
--   * The native apps write nothing to the funnel tables at all.
--     lib/src/core/services/analytics.dart conditionally exports
--     analytics_stub.dart off the web, where logFunnelEvent is a no-op, so an
--     iOS or Android arrival produces no site_visits row of any kind. Not a
--     row with a missing platform — no row. Over the 7 days to 2026-11-17
--     site_visits held 26 web arrivals while message_delivery held 1,689
--     receipts from 51 distinct users and conversation_logs held 229 rows.
--     Nearly all real usage was invisible to the only table that claimed to
--     have a "platform" column.
--
--   * app_version cannot stand in for it. message_delivery (0011) and
--     coin_ledger (0014) both record it, but web and app are built from the
--     same pubspec.yaml, so "1.0.7+102" is the same string on all three
--     platforms and segments nothing.
--
-- The one hard signal that did exist was linked_accounts.apple_client_id from
-- 0020: the bundle id means the app, the Services ID means the web. It covers
-- only Apple sign-ins that returned a refresh token, and says nothing about
-- Google — handleNativeSignIn writes a Google sign-in from the iOS app
-- identically to one from a browser.
--
-- So: record it, at the two moments that already know it, rather than deriving
-- it afterwards from evidence that was never kept.
--
--   linked_accounts     who signed in, and from where. The account-level
--                       answer, and the one the question above is really
--                       asking for. Last writer wins, never regressing to
--                       NULL, so it agrees with linked_at — which
--                       recordLinkedAccount already refreshes on every
--                       sign-in, making this row "the platform of the most
--                       recent sign-in" rather than "of the first one".
--   message_delivery    per flush of delivery receipts. The high-volume table,
--                       so this is the column that makes "which platform is
--                       having delivery trouble" answerable — a question that
--                       until now could only be asked of web visitors, who
--                       are the minority that was never in doubt.
--   conversation_logs   per /api/chat request, from the x-client-platform
--                       header, sent alongside the x-visit-id that 0007 added.
--
-- NAMING. Deliberately client_platform and not platform, even though three of
-- these tables have no platform column to collide with. site_visits.platform
-- and referral_visits.platform mean traffic source and will keep meaning it;
-- a `platform` on the other tables meaning device would put two unrelated
-- facts under one word in one database, and the join that silently compares
-- 'instagram' against 'ios' would return zero rows and look like an answer.
-- This is the same trap 0008 itself was written to avoid — it added a second
-- column rather than redefining `source`, precisely so that one word kept one
-- meaning — and the cost of repeating the mistake here is paid by every future
-- query rather than by this file.
--
-- NO BACKFILL, and this is the real difference from 0008. That migration could
-- recompute its column for historical rows because user_agent and referer had
-- been stored all along: the evidence was already on every row and only the
-- derivation was missing. Here the evidence itself was never collected. The
-- native apps never sent a platform, and nothing server-side can recover it:
-- the request carried no header saying so, the user agent of a Flutter app's
-- HTTP client is not a reliable discriminator, and app_version is identical
-- across platforms. A CASE expression over apple_client_id would populate a
-- fraction of linked_accounts and nothing else, and would still not separate
-- iOS from Android — it only separates app from web. Writing a guess into a
-- column that reads as a measurement is worse than leaving it NULL, so every
-- historical row stays NULL and NULL means "this row predates the client that
-- reports it", exactly as the 0009 rule has it: unknown, never a value.
--
-- Consequence worth stating plainly, because it will be asked: the first
-- useful week of data starts when the apps carrying this change are in
-- people's hands, which for iOS and Android is after App Store and Play review
-- plus however long people take to update. Web answers immediately. Until then
-- a query grouping on these columns has to treat NULL as its own bucket, and
-- a NULL-heavy result is an old client, not a platform.
--
-- Additive and nullable throughout, so the worker that writes these columns
-- and the one that does not can both run against this schema. Apply before
-- deploying the writer — npm run deploy does this in the right order — the
-- same note 0013 carries.

ALTER TABLE linked_accounts ADD COLUMN client_platform TEXT;
ALTER TABLE message_delivery ADD COLUMN client_platform TEXT;
ALTER TABLE conversation_logs ADD COLUMN client_platform TEXT;

-- The query this migration exists to make possible, and the shape the admin
-- reports group by:
--
--   SELECT client_platform, COUNT(*) FROM linked_accounts
--   WHERE linked_at >= datetime('now','-7 days') GROUP BY client_platform;
--
-- Column order is (client_platform, <time>) rather than the reverse because
-- every one of these is "this platform, over this window" — the platform is
-- the equality and the time is the range, so it has to come first to be used.
CREATE INDEX IF NOT EXISTS idx_linked_accounts_client_platform
    ON linked_accounts (client_platform, linked_at);

CREATE INDEX IF NOT EXISTS idx_message_delivery_client_platform
    ON message_delivery (client_platform, server_received_at);

CREATE INDEX IF NOT EXISTS idx_conversation_logs_client_platform
    ON conversation_logs (client_platform, created_at);
