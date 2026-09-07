-- ============================================================
-- 08_navigation_paths.sql
-- Module 4: Navigation and feature sequencing
-- On a single-page app, there is no URL-level navigation to
-- follow -- every event fires on '/'. Intent is expressed through
-- feature interactions, so navigation analysis here means:
--   1. What feature did a visit start with?
--   2. What feature transitions occur most often?
--   3. How deep into the feature set do visits go?
--   4. Do entry feature or source channel predict journey shape?
--
-- NOTE on page_exit: only 4 page_exit events fired across the
-- entire window. Exit tracking is not reliable on this site.
-- Pre-exit analysis is intentionally omitted here and documented
-- as a data quality finding in 10_data_quality.sql.
-- ============================================================


-- ---------------------------------------------------------------
-- A. First deliberate action per engaged visit
-- ROW_NUMBER() OVER (PARTITION BY visit_id ORDER BY created_at,
-- event_id) numbers every deliberate action within a visit
-- chronologically, event_id as tiebreaker for same-second events.
-- Filtering to rn = 1 gives the visit's entry feature.
-- ---------------------------------------------------------------
WITH first_action AS (
    SELECT
        fe.visit_id,
        fe.feature_category,
        fe.event_name,
        fv.source_channel,
        ROW_NUMBER() OVER (
            PARTITION BY fe.visit_id
            ORDER BY fe.created_at, fe.event_id
        ) AS rn
    FROM fact_events fe
    JOIN fact_visits fv ON fv.visit_id = fe.visit_id
    WHERE fe.is_deliberate_action = 1
)
SELECT
    feature_category                                            AS entry_feature,
    COUNT(*)                                                    AS engaged_visits,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1)        AS pct_of_engaged_visits
FROM first_action
WHERE rn = 1
GROUP BY feature_category
ORDER BY engaged_visits DESC;


-- ---------------------------------------------------------------
-- B. Entry feature by source channel
-- Do Instagram and Direct visitors start in different places?
-- Instagram visitors reach Outbound Link first at nearly 2x the
-- rate of Direct (26% vs 17%) -- consistent with an audience
-- exploring the full online presence rather than a specific feature.
-- Direct visitors discover Spotify Goal Game as an entry point
-- at much higher rates than Instagram visitors.
-- ---------------------------------------------------------------
WITH first_action AS (
    SELECT
        fe.visit_id,
        fe.feature_category,
        fv.source_channel,
        ROW_NUMBER() OVER (
            PARTITION BY fe.visit_id
            ORDER BY fe.created_at, fe.event_id
        ) AS rn
    FROM fact_events fe
    JOIN fact_visits fv ON fv.visit_id = fe.visit_id
    WHERE fe.is_deliberate_action = 1
)
SELECT
    source_channel,
    feature_category                                            AS entry_feature,
    COUNT(*)                                                    AS visits,
    ROUND(COUNT(*) * 100.0
        / SUM(COUNT(*)) OVER (PARTITION BY source_channel), 1) AS pct_of_source_visits
FROM first_action
WHERE rn = 1
  AND source_channel IN ('Direct', 'Instagram', 'LinkedIn')
GROUP BY source_channel, feature_category
ORDER BY source_channel, visits DESC;


-- ---------------------------------------------------------------
-- C. Feature transition matrix (LAG/LEAD pattern)
-- For each deliberate action, LEAD() looks one step forward within
-- the same visit to find the next feature touched. Same-feature
-- consecutive events are collapsed (a run of kiss_button_clicks
-- is one feature node, not 20 separate transitions) so the matrix
-- shows meaningful feature-to-feature movement, not click depth.
--
-- The core finding: Photo Gallery → Kiss Button (68x) and
-- Kiss Button → Photo Gallery (58x) is the dominant bidirectional
-- loop. These two features feed each other.
-- ---------------------------------------------------------------
WITH deliberate_sequence AS (
    SELECT
        visit_id,
        feature_category,
        created_at,
        event_id,
        LAG(feature_category) OVER (
            PARTITION BY visit_id ORDER BY created_at, event_id
        ) AS prev_feature
    FROM fact_events
    WHERE is_deliberate_action = 1
      AND feature_category NOT IN ('Site Lifecycle')
),
deduped AS (
    -- one row per feature block (first event of each uninterrupted run)
    -- ROW_NUMBER re-numbers the collapsed sequence so the next-step
    -- join below is a simple rn + 1 rather than a correlated subquery.
    SELECT visit_id, feature_category,
           ROW_NUMBER() OVER (PARTITION BY visit_id ORDER BY created_at, event_id) AS rn
    FROM deliberate_sequence
    WHERE feature_category IS NOT prev_feature
       OR prev_feature IS NULL
),
transitions AS (
    SELECT
        a.feature_category                                              AS from_feature,
        b.feature_category                                              AS to_feature
    FROM deduped a
    JOIN deduped b
        ON b.visit_id = a.visit_id
       AND b.rn = a.rn + 1
    WHERE a.feature_category != b.feature_category
)
SELECT
    from_feature,
    to_feature,
    COUNT(*)                                                            AS transitions
FROM transitions
GROUP BY from_feature, to_feature
ORDER BY transitions DESC;


-- ---------------------------------------------------------------
-- D. Journey depth: distinct features used per engaged visit
-- Strong monotonic relationship: more features = longer visit.
-- Single-feature visits average 30 seconds; 7+ feature visits
-- average 37-42 minutes. Feature breadth is a reliable proxy
-- for visit depth on this site.
-- ---------------------------------------------------------------
SELECT
    fv.distinct_features_used,
    COUNT(*)                                                            AS visits,
    ROUND(AVG(fv.visit_span_seconds) / 60.0, 1)                        AS avg_span_minutes,
    ROUND(AVG(fv.deliberate_action_count), 1)                          AS avg_deliberate_actions,
    MIN(fv.visit_span_seconds)                                          AS min_span_secs,
    MAX(fv.visit_span_seconds)                                          AS max_span_secs
FROM fact_visits fv
WHERE fv.is_engaged = 1
GROUP BY fv.distinct_features_used
ORDER BY fv.distinct_features_used;


-- ---------------------------------------------------------------
-- E. Journey depth by source channel
-- Do Instagram and Direct visitors explore the same breadth?
-- Instagram engages more often but concentrates in 1-3 features.
-- Direct engaged visits spread more across the full feature set.
-- ---------------------------------------------------------------
SELECT
    fv.source_channel,
    fv.distinct_features_used,
    COUNT(*)                                                            AS visits
FROM fact_visits fv
WHERE fv.is_engaged = 1
  AND fv.source_channel IN ('Direct', 'Instagram')
GROUP BY fv.source_channel, fv.distinct_features_used
ORDER BY fv.source_channel, fv.distinct_features_used;


-- ---------------------------------------------------------------
-- F. Feature loop detection: which features are revisited
-- within the same visit (user came back to it after doing
-- something else)? Identifies features that act as anchors
-- vs. features that are touched once and left.
-- ---------------------------------------------------------------
WITH deliberate_sequence AS (
    SELECT
        visit_id,
        feature_category,
        ROW_NUMBER() OVER (
            PARTITION BY visit_id ORDER BY created_at, event_id
        ) AS rn
    FROM fact_events
    WHERE is_deliberate_action = 1
      AND feature_category NOT IN ('Site Lifecycle')
),
feature_revisits AS (
    SELECT
        visit_id,
        feature_category,
        COUNT(DISTINCT rn) AS times_visited
    FROM deliberate_sequence
    GROUP BY visit_id, feature_category
)
SELECT
    feature_category,
    COUNT(DISTINCT visit_id)                                            AS total_visits_using,
    SUM(CASE WHEN times_visited > 1 THEN 1 ELSE 0 END)                 AS visits_that_revisited,
    ROUND(SUM(CASE WHEN times_visited > 1 THEN 1 ELSE 0 END)
        * 100.0 / COUNT(DISTINCT visit_id), 0)                         AS pct_revisiting
FROM feature_revisits
GROUP BY feature_category
ORDER BY total_visits_using DESC;
