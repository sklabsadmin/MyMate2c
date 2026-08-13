-- Which app actually opened the link, recorded separately from `source`.
--
-- `source` was utm_source-first: detectTrafficSource() returned the tag and
-- never reached the in-app-browser check below it. Every campaign link is
-- hardcoded ?utm_source=ig, so every arrival was filed as Instagram. Measured
-- over arrivals since 2026-08-05, excluding country='TH' (the developer):
--
--   calypso-reel-20260805   270 arrivals  260 Facebook in-app   0 Instagram in-app
--   odysseus-reel-20260808  139 arrivals  129 Facebook in-app   4 Instagram in-app
--
-- and the referers on those rows are facebook.com / m.facebook.com /
-- l.facebook.com (Facebook's outbound link shim). The dashboard read ~100%
-- "ig" for traffic that was ~93% Facebook, which is a decision-changing error
-- about where the audience is.
--
-- The tag itself is not a mistake, and that is exactly why this has to be a
-- second column rather than a reordering of the two checks. The link was given
-- to marketing tagged ?utm_source=ig for an Instagram post, and that is a true
-- statement about where it was published. Meta then served the same content on
-- Facebook placements, so where it was CLICKED is a different fact that only
-- the user-agent and the referring host know. Letting the user-agent overwrite
-- the tag would answer the second question by destroying the first — and the
-- gap between the two is itself the finding: it measures how much of an
-- Instagram campaign Meta actually delivered on Facebook.
--
-- So: `platform` is derived from the in-app browser's user-agent, then the
-- referring host, then "direct", and never consults utm_source. `source` keeps
-- its old meaning — the campaign tag as written on the link — which is still
-- the right key for "did this reel work"; it just no longer gets to answer
-- "which platform".

ALTER TABLE site_visits ADD COLUMN platform TEXT;
ALTER TABLE referral_visits ADD COLUMN platform TEXT;

-- Backfill. Unlike migration 0007's columns, this one CAN be recovered for
-- historical rows: user_agent and referer were stored all along, so the same
-- evidence the worker now uses at write time is already on every row.
--
-- Instagram is tested before FBAN/FBAV so a Meta user-agent carrying both is
-- not filed as Facebook. Host matching is by substring rather than a parsed
-- hostname (SQLite has no URL parser) — deliberately loose, because the point
-- is to collapse m./l./lm. facebook.com onto the one platform name the
-- user-agent check produces, not to split them into three rows.
UPDATE site_visits
SET platform = CASE
    WHEN user_agent LIKE '%Instagram%' THEN 'instagram'
    WHEN user_agent LIKE '%FBAN%' OR user_agent LIKE '%FBAV%' THEN 'facebook'
    WHEN referer LIKE '%facebook.com%' THEN 'facebook'
    WHEN referer LIKE '%instagram.com%' THEN 'instagram'
    WHEN referer LIKE '%threads.net%' OR referer LIKE '%threads.com%' THEN 'threads'
    WHEN referer LIKE '%tiktok.com%' THEN 'tiktok'
    WHEN referer LIKE '%youtube.com%' OR referer LIKE '%youtu.be%' THEN 'youtube'
    WHEN referer LIKE '%twitter.com%' OR referer LIKE '%//x.com%' THEN 'x'
    WHEN referer LIKE '%google.%' THEN 'google'
    -- No utm_source on the link means `source` was already derived from
    -- exactly these signals, so it IS the platform — modulo the tag spelling
    -- ("ig" is the campaign tag; the platform column spells it out).
    WHEN query IS NULL OR instr(lower(query), 'utm_source=') = 0
        THEN CASE WHEN source = 'ig' THEN 'instagram' ELSE source END
    -- Tagged link, no in-app-browser user-agent and no referer: the tag is the
    -- only thing left and the tag is what we stopped trusting. NULL, shown as
    -- "unknown" in the admin UI, rather than a guess that reads as a measurement.
    ELSE NULL
END;

-- referral_visits has no stored query string, so the "was there a utm_source?"
-- test above is not available here. source='direct' can only have come from
-- the derivation path (nobody tags a link ?utm_source=direct), so it is safe
-- to carry over; anything else without user-agent or referer evidence stays NULL.
UPDATE referral_visits
SET platform = CASE
    WHEN user_agent LIKE '%Instagram%' THEN 'instagram'
    WHEN user_agent LIKE '%FBAN%' OR user_agent LIKE '%FBAV%' THEN 'facebook'
    WHEN referer LIKE '%facebook.com%' THEN 'facebook'
    WHEN referer LIKE '%instagram.com%' THEN 'instagram'
    WHEN referer LIKE '%threads.net%' OR referer LIKE '%threads.com%' THEN 'threads'
    WHEN referer LIKE '%tiktok.com%' THEN 'tiktok'
    WHEN referer LIKE '%youtube.com%' OR referer LIKE '%youtu.be%' THEN 'youtube'
    WHEN referer LIKE '%twitter.com%' OR referer LIKE '%//x.com%' THEN 'x'
    WHEN referer LIKE '%google.%' THEN 'google'
    WHEN source = 'direct' THEN 'direct'
    ELSE NULL
END;

-- The admin visits page groups every one of its tables on this column now.
CREATE INDEX IF NOT EXISTS idx_site_visits_platform
    ON site_visits (platform, created_at);

CREATE INDEX IF NOT EXISTS idx_referral_visits_platform
    ON referral_visits (platform, created_at);
