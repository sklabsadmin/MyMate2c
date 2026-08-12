-- What was deployed, and when — recorded by hand.
--
-- Every analytics question on the admin pages is really a before/after
-- question, and the "before" is a deploy. Until now the only record of when
-- one happened was git log, which is commit time rather than deploy time (see
-- docs/ANALYTICS_HANDOFF.md 3, where every row had to be reconstructed from
-- memory and half of them carry a "~"). A funnel step that moved on the 11th
-- is unreadable without knowing what shipped on the 11th, and reconstructing
-- that a fortnight later is exactly what this table exists to stop.
--
-- Written by hand rather than by the deploy script on purpose: the script is
-- run from a laptop against production and cannot be relied on to have
-- database credentials, and a deploy that fails halfway is still a deploy that
-- changed what visitors saw. A row here means "a person watched this go out".

CREATE TABLE IF NOT EXISTS deploy_log (
    id TEXT PRIMARY KEY,

    -- As pubspec.yaml writes it: "1.6.4+60". Free text rather than parsed —
    -- a hotfix deployed off a branch may not have a clean version at all, and
    -- refusing to record it would leave the gap this table exists to close.
    version TEXT NOT NULL,

    -- When it actually went live, UTC, "YYYY-MM-DD HH:MM:SS". Distinct from
    -- created_at below: a deploy noticed an hour late is still recorded at the
    -- time it happened, and every query that windows on it depends on that.
    deployed_at TEXT NOT NULL,

    -- What shipped, in a sentence. The thing that makes a marker on a chart
    -- worth having.
    notes TEXT,

    -- Which surface went out. The Flutter app and the worker deploy
    -- separately and can be at different versions, and a funnel change caused
    -- by one is routinely blamed on the other.
    target TEXT,

    -- When the row was written, which is not when the deploy happened.
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Every read is "what shipped in this window", newest first.
CREATE INDEX IF NOT EXISTS idx_deploy_log_deployed_at
    ON deploy_log (deployed_at DESC);
