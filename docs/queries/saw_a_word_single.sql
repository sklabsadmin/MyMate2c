WITH v AS (
  SELECT a.visit_id,
         CASE WHEN a.path LIKE '/c/%' THEN 'campaign' ELSE 'other' END AS seg,
         (SELECT MIN(r.duration_ms) FROM site_visits r
           WHERE r.visit_id = a.visit_id AND r.event = 'app_ready') AS load_ms,
         (SELECT MAX(l.duration_ms) FROM site_visits l
           WHERE l.visit_id = a.visit_id AND l.event = 'leave') AS dwell_ms,
         (SELECT COUNT(*) FROM site_visits f
           WHERE f.visit_id = a.visit_id AND f.event = 'first_message') AS sent
    FROM site_visits a
   WHERE a.event = 'arrive'
     AND a.created_at >= '2026-07-30 17:02:00'
   GROUP BY a.visit_id
)
SELECT seg,
       CASE
         WHEN sent > 0                  THEN '5_typed'
         WHEN dwell_ms IS NULL          THEN '0_no_leave_recorded'
         WHEN load_ms  IS NULL          THEN '1_left_before_app_ready'
         WHEN dwell_ms < load_ms + 4300 THEN '2_left_before_opener'
         WHEN dwell_ms < load_ms + 5300 THEN '3_ambiguous'
         ELSE                                '4_saw_opener_left'
       END AS stage,
       COUNT(*) AS visits
  FROM v
 GROUP BY seg, stage
 ORDER BY seg, stage;
