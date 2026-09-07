-- ============================================================
-- 06_acquisition.sql
-- Module 2: Traffic acquisition analysis
-- Answers: how did visitors arrive, which sources drove engaged
-- visits, and how did volume change over the reporting window?
--
-- All queries read from fact_visits and visit_source, which
-- already carry first-event source attribution. No raw table
-- access needed here -- that's the point of the model layer.
-- ============================================================


-- ---------------------------------------------------------------
-- A. Source channel overview
-- Core acquisition summary: volume, engagement rate, and depth.
-- Engagement rate = engaged_visits / total_visits.
-- Depth metrics (avg actions, avg span) are scoped to engaged
-- visits only -- including non-engaged visits would dilute the
-- signal with bot/bounce noise.
-- ---------------------------------------------------------------
SELECT
    vs.source_channel,
    ds.sort_order,
    COUNT(*)                                                            AS total_visits,
    SUM(fv.is_engaged)                                                  AS engaged_visits,
    ROUND(SUM(fv.is_engaged) * 100.0 / COUNT(*), 1)                    AS engagement_rate_pct,
    ROUND(AVG(CASE WHEN fv.is_engaged = 1
        THEN fv.deliberate_action_count END), 1)                        AS avg_actions_when_engaged,
    ROUND(AVG(CASE WHEN fv.is_engaged = 1
        THEN fv.visit_span_seconds END), 0)                             AS avg_span_secs_when_engaged,
    SUM(CASE WHEN fv.is_engaged = 1
        THEN fv.used_outbound_link ELSE 0 END)                          AS engaged_outbound_clicks,
    ROUND(SUM(CASE WHEN fv.is_engaged = 1 THEN fv.used_outbound_link ELSE 0 END)
        * 100.0 / NULLIF(SUM(fv.is_engaged), 0), 1)                    AS outbound_rate_of_engaged_pct
FROM fact_visits fv
JOIN visit_source vs  ON vs.visit_id      = fv.visit_id
JOIN dim_sources  ds  ON ds.source_channel = fv.source_channel
GROUP BY fv.source_channel, ds.sort_order
ORDER BY ds.sort_order;


-- ---------------------------------------------------------------
-- B. Weekly visit trend by source channel
-- strftime('%Y-%W') groups by ISO year-week. MIN(DATE(visit_start))
-- gives a readable Monday anchor for each week row.
-- ---------------------------------------------------------------
SELECT
    strftime('%Y-%W', fv.visit_start)              AS year_week,
    MIN(DATE(fv.visit_start))                       AS week_starting,
    COUNT(*)                                        AS total_visits,
    SUM(CASE WHEN fv.source_channel = 'Direct'
        THEN 1 ELSE 0 END)                          AS direct_visits,
    SUM(CASE WHEN fv.source_channel = 'Instagram'
        THEN 1 ELSE 0 END)                          AS instagram_visits,
    SUM(CASE WHEN fv.source_channel = 'LinkedIn'
        THEN 1 ELSE 0 END)                          AS linkedin_visits,
    SUM(CASE WHEN fv.source_channel NOT IN
        ('Direct','Instagram','LinkedIn')
        THEN 1 ELSE 0 END)                          AS other_visits,
    SUM(fv.is_engaged)                              AS engaged_visits
FROM fact_visits fv
GROUP BY year_week
ORDER BY year_week;


-- ---------------------------------------------------------------
-- C. Engagement depth comparison: Instagram vs Direct vs LinkedIn
-- Instagram engages most often (88%) but least deeply.
-- Direct visitors who engage spend ~15 min on average -- far
-- longer than Instagram's ~1-minute engaged sessions (Instagram
-- visits still average ~11 deliberate actions in that short span,
-- just compressed rather than lingering).
-- LinkedIn is small sample but mirrors Direct-level depth.
-- NULLIF prevents divide-by-zero on zero-engaged channels.
-- ---------------------------------------------------------------
SELECT
    fv.source_channel,
    SUM(fv.is_engaged)                                                  AS engaged_visits,
    ROUND(AVG(CASE WHEN fv.is_engaged = 1
        THEN fv.deliberate_action_count END), 1)                        AS avg_deliberate_actions,
    ROUND(AVG(CASE WHEN fv.is_engaged = 1
        THEN fv.visit_span_seconds / 60.0 END), 1)                     AS avg_span_minutes,
    ROUND(SUM(CASE WHEN fv.is_engaged = 1
        THEN fv.used_photo_gallery ELSE 0 END)
        * 100.0 / NULLIF(SUM(fv.is_engaged), 0), 0)                    AS pct_used_photos,
    ROUND(SUM(CASE WHEN fv.is_engaged = 1
        THEN fv.used_kiss_button ELSE 0 END)
        * 100.0 / NULLIF(SUM(fv.is_engaged), 0), 0)                    AS pct_used_kiss,
    ROUND(SUM(CASE WHEN fv.is_engaged = 1
        THEN fv.used_outbound_link ELSE 0 END)
        * 100.0 / NULLIF(SUM(fv.is_engaged), 0), 0)                    AS pct_clicked_outbound
FROM fact_visits fv
WHERE fv.source_channel IN ('Direct', 'Instagram', 'LinkedIn')
GROUP BY fv.source_channel
ORDER BY SUM(fv.is_engaged) DESC;


-- ---------------------------------------------------------------
-- D. Instagram visit distribution over time
-- No single promotional spike -- consistent trickle from a silent
-- bio link. Largest single day was 7 visits. Confirms this is
-- passive discovery traffic, not a campaign effect.
-- ---------------------------------------------------------------
SELECT
    DATE(fv.visit_start)    AS day,
    COUNT(*)                AS ig_visits,
    SUM(fv.is_engaged)      AS ig_engaged
FROM fact_visits fv
WHERE fv.source_channel = 'Instagram'
GROUP BY day
ORDER BY day;


-- ---------------------------------------------------------------
-- E. Non-engaged visit span distribution by source
-- Separates real bounces from instrumentation noise.
-- Sub-5s visits are almost certainly bots or state-restore fires.
-- ---------------------------------------------------------------
SELECT
    fv.source_channel,
    COUNT(*)                                                            AS not_engaged_visits,
    ROUND(AVG(fv.visit_span_seconds), 0)                               AS avg_span_secs,
    SUM(CASE WHEN fv.visit_span_seconds <= 5  THEN 1 ELSE 0 END)       AS sub_5s,
    SUM(CASE WHEN fv.visit_span_seconds BETWEEN 6 AND 60
        THEN 1 ELSE 0 END)                                              AS btw_6_60s,
    SUM(CASE WHEN fv.visit_span_seconds > 60  THEN 1 ELSE 0 END)       AS over_60s
FROM fact_visits fv
WHERE fv.is_engaged = 0
GROUP BY fv.source_channel
ORDER BY not_engaged_visits DESC;
