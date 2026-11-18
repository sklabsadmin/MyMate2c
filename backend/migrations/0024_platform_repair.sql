-- Repairs site_visits.platform and referral_visits.platform, which have been
-- recording our own hostname instead of a platform.
--
-- Migration 0008 built these columns and documented their values as the
-- in-app browser's user-agent, then the referring host, then "direct". In live
-- data they read 'chat.deeploveechoes.com' and 'chat.deeplovepoems.com'. Two
-- separate faults produced that, one in the write path and one in the
-- vocabulary, and both are fixed in worker.js alongside this file.
--
-- THE WRITE PATH. recordSiteVisit was passing the beacon REQUEST to the
-- detector instead of the beacon's PAYLOAD. /api/visit is an XHR the page
-- sends to our own worker, so its Referer header is always the page that sent
-- it — our own URL. The page's real document.referrer arrives in the body, and
-- the handler already goes to the trouble of assembling a fake request around
-- it for detectTrafficSource, with a comment explaining why the live request
-- cannot answer. `platform` was the one field that still read the live
-- request. So on every row whose user-agent was not Instagram or Facebook, the
-- column recorded the fact that the visitor was on our site, which is not a
-- question anyone asked.
--
-- That also explains why the breakage was invisible for three months. The
-- user-agent arms still worked, so Meta in-app traffic — the segment anyone
-- actually looked at — was classified correctly, and the ~93% Facebook finding
-- 0008 was written to capture still holds. Everything else silently collapsed
-- into one bucket named after us.
--
-- THE VOCABULARY. The detector returned the referring hostname verbatim for
-- anything it did not recognise, which gave a GROUP BY column one bucket per
-- host on the internet. It is now closed: a REFERER_PLATFORMS name, or
-- 'internal' (us), 'other' (a referrer we do not recognise) or 'direct' (none
-- sent). Nothing is lost by narrowing it, which is the only reason it is the
-- right thing to do here — `referer` is stored raw and uncapped on every row
-- of both tables, so the host behind 'other' is always one query away.
--
-- THE BACKFILL, and why there is one at all. 0023 had to leave its column NULL
-- for historical rows because the evidence had never been collected. This is
-- the opposite case and the distinction is the whole of it: user_agent and
-- referer have been on both tables since they were created (0003, 0004), and
-- `referer` holds the payload value — the real one — not the header the write
-- path was misreading. So the same evidence the fixed code now uses is already
-- on every row ever written, and every one of them can be recomputed to the
-- value it should always have had. This is a genuine repair rather than a
-- guess dressed as one; it is the case 0008's own comment contrasts itself
-- against.
--
-- Recomputed unconditionally rather than only where the value looks like a
-- hostname. Rows written before this deploy and rows written after it then
-- carry the same vocabulary, which is what lets a window spanning the deploy
-- be counted at all; a partial repair would leave two systems of meaning in
-- one column and no way to tell from a row which it used. The UPDATE is also
-- idempotent and safe to re-run, because it reads only the raw evidence and
-- never its own output.
--
-- Host matching is by substring, as in 0008, because SQLite has no URL parser.
-- That is looser than the worker's parsed-hostname check and the order below
-- is what keeps it honest: Facebook's link shim carries the destination in its
-- query string (l.facebook.com/l.php?u=https://chat.deeploveechoes.com/...),
-- so a referer naming both is a Facebook click. Every known platform is
-- therefore tested before the internal check, matching the function's order.
--
-- Our own domains are spelled out here, where the worker takes them from the
-- request's own hostname. A migration has no request to ask, and the
-- alternative — leaving these rows as hostnames — is the bug. Add a line if a
-- domain is added; a missed one reads as 'other', which is wrong but bounded,
-- and still recomputable from `referer` afterwards.

UPDATE site_visits
SET platform = CASE
    WHEN user_agent LIKE '%Instagram%' THEN 'instagram'
    WHEN user_agent LIKE '%FBAN%' OR user_agent LIKE '%FBAV%' THEN 'facebook'
    -- No evidence of either kind. Distinct from 'direct' below: this is a row
    -- the beacon never described, not a visitor who arrived without a
    -- referrer. NULL, the 0009 rule — unknown is not a value.
    WHEN (referer IS NULL OR referer = '') AND (user_agent IS NULL OR user_agent = '')
        THEN NULL
    -- The beacon was running (it sent a user-agent) and reported no referrer,
    -- which is what 'direct' means.
    WHEN referer IS NULL OR referer = '' THEN 'direct'
    WHEN referer LIKE '%facebook.com%' THEN 'facebook'
    WHEN referer LIKE '%instagram.com%' THEN 'instagram'
    WHEN referer LIKE '%threads.net%' OR referer LIKE '%threads.com%' THEN 'threads'
    WHEN referer LIKE '%tiktok.com%' THEN 'tiktok'
    WHEN referer LIKE '%youtube.com%' OR referer LIKE '%youtu.be%' THEN 'youtube'
    WHEN referer LIKE '%twitter.com%' OR referer LIKE '%//x.com%' OR referer LIKE '%t.co/%'
        THEN 'x'
    WHEN referer LIKE '%google.%' THEN 'google'
    WHEN referer LIKE '%deeploveechoes.com%' OR referer LIKE '%deeplovepoems.com%'
        THEN 'internal'
    ELSE 'other'
END;

UPDATE referral_visits
SET platform = CASE
    WHEN user_agent LIKE '%Instagram%' THEN 'instagram'
    WHEN user_agent LIKE '%FBAN%' OR user_agent LIKE '%FBAV%' THEN 'facebook'
    WHEN (referer IS NULL OR referer = '') AND (user_agent IS NULL OR user_agent = '')
        THEN NULL
    WHEN referer IS NULL OR referer = '' THEN 'direct'
    WHEN referer LIKE '%facebook.com%' THEN 'facebook'
    WHEN referer LIKE '%instagram.com%' THEN 'instagram'
    WHEN referer LIKE '%threads.net%' OR referer LIKE '%threads.com%' THEN 'threads'
    WHEN referer LIKE '%tiktok.com%' THEN 'tiktok'
    WHEN referer LIKE '%youtube.com%' OR referer LIKE '%youtu.be%' THEN 'youtube'
    WHEN referer LIKE '%twitter.com%' OR referer LIKE '%//x.com%' OR referer LIKE '%t.co/%'
        THEN 'x'
    WHEN referer LIKE '%google.%' THEN 'google'
    WHEN referer LIKE '%deeploveechoes.com%' OR referer LIKE '%deeplovepoems.com%'
        THEN 'internal'
    ELSE 'other'
END;
