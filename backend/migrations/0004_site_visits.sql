-- Every arrival on the site, not just /c/* campaign links.
--
-- referral_visits only ever recorded /c/<character> hits, because that is the
-- one path wrangler routes to the worker. Anyone landing on the bare domain or
-- /dashboard was invisible, which is how ~1000 reported ad clicks showed up as
-- single-digit rows.
--
-- Written from a beacon in web/index.html that fires while the splash screen is
-- still up, before the 3MB Flutter bundle has downloaded — so a visitor who
-- gives up during loading is still counted. A matching beacon on page-hide
-- closes the visit with a duration, which is what tells apart "bounced during
-- load" from "actually looked around".
CREATE TABLE IF NOT EXISTS site_visits (
    id TEXT PRIMARY KEY,

    -- Groups the arrive/leave pair. Generated client-side per page load and
    -- held in sessionStorage, so a reload starts a new visit but an in-page
    -- route change does not.
    visit_id TEXT NOT NULL,

    -- 'arrive' | 'leave'
    event TEXT NOT NULL,

    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Landing path, e.g. "/" or "/c/zeus". Query string kept separately so a
    -- path can be grouped without utm noise splitting it.
    path TEXT,
    query TEXT,

    -- Where we think they came from: instagram, meta, direct, ...
    source TEXT,
    utm_medium TEXT,
    utm_campaign TEXT,
    referer TEXT,
    user_agent TEXT,

    -- Cloudflare-supplied, so it cannot be spoofed by the beacon body.
    country TEXT,
    colo TEXT,

    -- Only set on 'leave': milliseconds between arrive and leave.
    duration_ms INTEGER
);

CREATE INDEX IF NOT EXISTS idx_site_visits_created ON site_visits (created_at);
CREATE INDEX IF NOT EXISTS idx_site_visits_visit ON site_visits (visit_id);
CREATE INDEX IF NOT EXISTS idx_site_visits_source ON site_visits (source, created_at);
