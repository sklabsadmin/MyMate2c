-- What % of campaign-link arrivals left before the character said anything?
--
-- Derived threshold, from chat_screen.dart:550-620 (_triggerWelcomeSequence):
--     portrait          600 ms
--     "Connected with"  1000 ms
--     typing indicator  800 ms + 30 ms per character of the opener
--   = 2400 ms fixed + 30 ms/char, AFTER the chat screen mounts.
--
-- Observed opener lengths give 4260-5220 ms (Calypso) and 4200-4600 ms
-- (Penelope). The line is drawn at random and is NOT logged, so per visit we
-- only know the range, not the value. Hence an explicit ambiguous bucket
-- rather than a single cutoff pretending to precision we do not have.
--
-- Each visit is measured against ITS OWN app_ready load time, not the ~1.5s
-- average, so slow connections are not misclassified as fast bounces.
--
-- WINDOW: from 2026-07-30 17:02 — before that the visit_id collision (§4.1)
-- duplicates arrive/leave rows and every ratio here becomes meaningless.
-- Aggregate subqueries, never joins, for the same reason.

WITH v AS (
  SELECT a.visit_id,
         a.source,
         (SELECT MIN(r.duration_ms) FROM site_visits r
           WHERE r.visit_id = a.visit_id AND r.event = 'app_ready') AS load_ms,
         (SELECT MAX(l.duration_ms) FROM site_visits l
           WHERE l.visit_id = a.visit_id AND l.event = 'leave')     AS dwell_ms,
         (SELECT COUNT(*) FROM site_visits f
           WHERE f.visit_id = a.visit_id AND f.event = 'first_message') AS sent
    FROM site_visits a
   WHERE a.event = 'arrive'
     AND a.created_at >= '2026-07-30 17:02:00'
   GROUP BY a.visit_id
)
SELECT
  CASE
    WHEN sent > 0                      THEN '5. typed a message'
    WHEN dwell_ms IS NULL              THEN '0. no leave recorded (unknown)'
    WHEN load_ms  IS NULL              THEN '1. left before app_ready'
    WHEN dwell_ms < load_ms + 4300     THEN '2. left before ANY opener could show'
    WHEN dwell_ms < load_ms + 5300     THEN '3. ambiguous (opener may have shown)'
    ELSE                                    '4. saw the opener, left anyway'
  END                                   AS stage,
  COUNT(*)                              AS visits,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM v
GROUP BY stage
ORDER BY stage;

-- Same split, campaign traffic only (the people who clicked a bio link).
WITH v AS (
  SELECT a.visit_id,
         (SELECT MIN(r.duration_ms) FROM site_visits r
           WHERE r.visit_id = a.visit_id AND r.event = 'app_ready') AS load_ms,
         (SELECT MAX(l.duration_ms) FROM site_visits l
           WHERE l.visit_id = a.visit_id AND l.event = 'leave')     AS dwell_ms,
         (SELECT COUNT(*) FROM site_visits f
           WHERE f.visit_id = a.visit_id AND f.event = 'first_message') AS sent
    FROM site_visits a
   WHERE a.event = 'arrive'
     AND a.created_at >= '2026-07-30 17:02:00'
     AND a.path LIKE '/c/%'
   GROUP BY a.visit_id
)
SELECT
  CASE
    WHEN sent > 0                      THEN '5. typed a message'
    WHEN dwell_ms IS NULL              THEN '0. no leave recorded (unknown)'
    WHEN load_ms  IS NULL              THEN '1. left before app_ready'
    WHEN dwell_ms < load_ms + 4300     THEN '2. left before ANY opener could show'
    WHEN dwell_ms < load_ms + 5300     THEN '3. ambiguous (opener may have shown)'
    ELSE                                    '4. saw the opener, left anyway'
  END        AS stage,
  COUNT(*)   AS visits,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM v
GROUP BY stage
ORDER BY stage;

-- READING IT HONESTLY
--
-- Bucket 0 is not noise, it is the confidence interval. duration_ms comes from
-- sendBeacon on pagehide; a hard close never reports (§4.2 survivorship). If
-- bucket 0 is large, every percentage here is soft — say so rather than
-- quoting bucket 2 as a fact.
--
-- Bucket 2 is also a FLOOR, not a ceiling. The leave handler is once-only, so
-- a visitor who tab-switches at 2s and returns for a minute is recorded at 2s
-- and lands in bucket 2 wrongly. Skew is toward over-counting early leaves.
--
-- Bucket 4 is the only one that carries a content signal. Buckets 1-3 say
-- nothing about the writing, the character, or the campaign - only about the
-- delay. If 1+2+3 dominates, character A/B tests are measuring latency.
