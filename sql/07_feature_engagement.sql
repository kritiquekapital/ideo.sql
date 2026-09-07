-- ============================================================
-- 07_feature_engagement.sql
-- Module 3: Feature engagement analysis
-- Answers: which features did visitors actually use, how deeply,
-- which features cluster together, and what did they interact
-- with specifically (themes, links, photos, messages)?
--
-- "Feature reach" is always reported at visit grain (% of visits
-- that used the feature at least once), not raw event count.
-- Raw counts alone are misleading: a single visit with 100
-- kiss_button_clicks would dominate totals while counting as
-- one visit in reach. Both metrics are included where useful.
-- ============================================================


-- ---------------------------------------------------------------
-- A. Feature reach: % of all visits and % of engaged visits
-- using each feature (deliberate actions only -- state-restore
-- opens excluded via is_deliberate_action = 1 filter).
-- The denominator difference matters: reach among all 391 visits
-- includes bot/bounce visits that could never engage, while reach
-- among the 205 engaged visits is the "of people who actually
-- interacted, how many found this feature" signal.
-- ---------------------------------------------------------------
WITH engaged_visit_count AS (
    SELECT COUNT(*) AS n FROM fact_visits WHERE is_engaged = 1
),
total_visit_count AS (
    SELECT COUNT(*) AS n FROM fact_visits
)
SELECT
    fe.feature_category,
    COUNT(DISTINCT fe.visit_id)                                         AS visits_reaching,
    ROUND(COUNT(DISTINCT fe.visit_id) * 100.0
        / (SELECT n FROM total_visit_count), 1)                         AS pct_all_visits,
    ROUND(COUNT(DISTINCT fe.visit_id) * 100.0
        / (SELECT n FROM engaged_visit_count), 1)                       AS pct_engaged_visits,
    COUNT(*)                                                            AS total_events,
    ROUND(COUNT(*) * 1.0
        / COUNT(DISTINCT fe.visit_id), 1)                               AS avg_events_per_using_visit
FROM fact_events fe
WHERE fe.is_deliberate_action = 1
  AND fe.feature_category NOT IN ('Site Lifecycle')
GROUP BY fe.feature_category
ORDER BY visits_reaching DESC;


-- ---------------------------------------------------------------
-- B. Feature depth: among visits that used a feature, how long
-- did those visits tend to last and how many total deliberate
-- actions did they contain? A high avg_actions number means the
-- feature co-occurs with heavy engagement generally -- it does NOT
-- mean the feature caused the engagement (correlation only).
-- ---------------------------------------------------------------
WITH feature_visits AS (
    SELECT DISTINCT visit_id, feature_category
    FROM fact_events
    WHERE is_deliberate_action = 1
      AND feature_category NOT IN ('Site Lifecycle')
)
SELECT
    fv.feature_category,
    COUNT(DISTINCT fv.visit_id)                                         AS visits_using,
    ROUND(AVG(CAST(fac.deliberate_action_count AS REAL)), 1)            AS avg_total_actions_that_visit,
    ROUND(AVG(CAST(fac.visit_span_seconds AS REAL) / 60.0), 1)         AS avg_span_minutes,
    MIN(fac.deliberate_action_count)                                    AS min_actions,
    MAX(fac.deliberate_action_count)                                    AS max_actions
FROM feature_visits fv
JOIN fact_visits fac ON fac.visit_id = fv.visit_id
GROUP BY fv.feature_category
ORDER BY visits_using DESC;


-- ---------------------------------------------------------------
-- C. Feature co-occurrence: which features appear together most
-- often within the same visit? Reveals the core engaged-visit
-- cluster (Kiss Button + Photo Gallery + Outbound Link) and which
-- features tend to be isolated vs. bridges to other content.
-- The self-join on feature_category > guarantees each pair
-- appears once (A+B, not A+B and B+A).
-- ---------------------------------------------------------------
WITH visit_features AS (
    SELECT DISTINCT visit_id, feature_category
    FROM fact_events
    WHERE is_deliberate_action = 1
      AND feature_category NOT IN ('Site Lifecycle')
)
SELECT
    a.feature_category                                                  AS feature_a,
    b.feature_category                                                  AS feature_b,
    COUNT(*)                                                            AS co_occurring_visits
FROM visit_features a
JOIN visit_features b
    ON b.visit_id = a.visit_id
   AND b.feature_category > a.feature_category
GROUP BY a.feature_category, b.feature_category
ORDER BY co_occurring_visits DESC;


-- ---------------------------------------------------------------
-- D. Theme leaderboard
-- Which themes did visitors switch to, and how many distinct
-- sessions chose each? Session count guards against one heavy
-- switcher inflating a theme's apparent popularity.
-- Retro dominates by a large margin (475 switches, 175 sessions).
-- ---------------------------------------------------------------
SELECT
    string_value                                                        AS theme,
    COUNT(*)                                                            AS total_switches,
    COUNT(DISTINCT session_id)                                          AS distinct_sessions,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1)                AS pct_of_all_switches
FROM event_properties_long
WHERE event_name IN ('theme_change', 'theme_applied', 'theme_toggle')
  AND data_key = 'theme'
GROUP BY string_value
ORDER BY total_switches DESC;


-- ---------------------------------------------------------------
-- E. Outbound link destinations
-- Functional links only (is_functional_link = 1 filters out '#'
-- and 'javascript:void(0)' placeholder clicks).
-- NOTE: "substack-button" appears twice with different destinations.
-- This is NOT a broken link -- it's an intentional repurposing.
-- The button originally pointed to substack.com/@camglhf (Mar 28-
-- Apr 3, 7 clicks), then was deliberately re-pointed to
-- kritiquekapital.com starting Apr 14 (32 clicks across 27
-- sessions), which is the current, correct destination. The
-- internal label/id ("substack-button") was never updated to
-- match -- that stale-label mismatch is the real data-quality
-- finding here. See 09_data_quality.sql DQ-3 for detail.
-- ---------------------------------------------------------------
SELECT
    lbl.string_value                                                    AS label,
    dest.string_value                                                   AS destination_url,
    COUNT(*)                                                            AS total_clicks,
    COUNT(DISTINCT lbl.session_id)                                      AS distinct_sessions,
    MIN(lbl.created_at)                                                 AS first_click,
    MAX(lbl.created_at)                                                 AS last_click
FROM event_properties_long lbl
JOIN event_properties_long dest
    ON dest.event_id = lbl.event_id
   AND dest.data_key = 'destination_url'
WHERE lbl.data_key = 'label'
  AND dest.is_functional_link = 1
GROUP BY lbl.string_value, dest.string_value
ORDER BY total_clicks DESC;


-- ---------------------------------------------------------------
-- F. Photo gallery: top photos by click count
-- photo_click carries both 'file' (the image filename) and
-- 'theme' (which theme was active at click time). File ranking
-- shows which specific photos attracted the most attention.
-- ---------------------------------------------------------------
SELECT
    string_value                                                        AS photo_file,
    COUNT(*)                                                            AS clicks,
    COUNT(DISTINCT session_id)                                          AS distinct_sessions
FROM event_properties_long
WHERE event_name = 'photo_click'
  AND data_key = 'file'
GROUP BY string_value
ORDER BY clicks DESC;


-- ---------------------------------------------------------------
-- G. Kiss button: message distribution and depth
-- The kiss button cycles through a set of output messages.
-- Distribution shows which messages appeared most often, which
-- reflects how many times visitors cycled through (each click
-- advances the sequence). One visit generated 119 clicks alone.
-- ---------------------------------------------------------------

-- G1. Message frequency
SELECT
    string_value                                                        AS message,
    COUNT(*)                                                            AS times_shown,
    COUNT(DISTINCT session_id)                                          AS sessions_seeing_it
FROM event_properties_long
WHERE event_name IN ('kiss_button_click', 'kiss_click')
  AND data_key = 'message'
GROUP BY string_value
ORDER BY times_shown DESC;

-- G2. Click depth per visit (how many times did each visit click?)
SELECT
    clicks_in_visit,
    COUNT(*)                                                            AS visits_at_this_depth
FROM (
    SELECT visit_id, COUNT(*) AS clicks_in_visit
    FROM fact_events
    WHERE event_name IN ('kiss_button_click','kiss_click',
                         'kiss_button_sink','kiss_sink')
    GROUP BY visit_id
)
GROUP BY clicks_in_visit
ORDER BY clicks_in_visit;


-- ---------------------------------------------------------------
-- H. Spotify Goal Game: device and context breakdown
-- The game tracks which device type was used and what theme was
-- active. Desktop dominates (216 vs 48 mobile events).
-- ---------------------------------------------------------------
SELECT
    data_key,
    string_value,
    COUNT(*)                                                            AS occurrences
FROM event_properties_long
WHERE event_name IN ('spotify_goal_open', 'spotify_goal_scored')
  AND data_key IN ('device', 'theme')
GROUP BY data_key, string_value
ORDER BY data_key, occurrences DESC;
