-- ============================================================
-- 05_build_fact_visits.sql
-- One row per visit_id. Aggregates fact_events into a flat
-- visit-level summary with all metrics, flags, and classifications
-- needed for acquisition, engagement, and feature-engagement analysis.
--
-- Key design decisions documented here:
--
--   is_engaged: 1 if the visit contains at least one deliberate-action
--   event (is_deliberate_action = 1 in fact_events). theme_change alone
--   does NOT qualify -- it is auto-restorable state that fires on page
--   load for bots and returning visitors alike. Only unambiguous user
--   gestures count. Confirmed against Ashburn bot pattern (19 visits,
--   all theme/minesweeper_open state-restore only, zero real clicks).
--
--   visit_span_seconds: MAX(created_at) - MIN(created_at) within the
--   visit. This is observed span only -- it measures the gap between
--   first and last recorded event, NOT true time-on-site. A visit
--   that ends mid-interaction has no final timestamp; single-event
--   visits always show span = 0. Interpret with care.
--
--   landing_path: canonical_path of the first event in the visit
--   (by created_at, event_id tiebreaker). On this single-page app
--   this is effectively always '/'.
-- ============================================================

DROP TABLE IF EXISTS fact_visits;
CREATE TABLE fact_visits (
    -- identity
    visit_id          TEXT PRIMARY KEY,
    session_id        TEXT NOT NULL,

    -- timing
    visit_start       TEXT NOT NULL,
    visit_end         TEXT NOT NULL,
    visit_span_seconds INTEGER NOT NULL,   -- observed span only; see note above

    -- source (from visit_source)
    source_channel    TEXT NOT NULL,

    -- device context (from first event)
    browser           TEXT,
    os                TEXT,
    device            TEXT,
    country           TEXT,
    city              TEXT,

    -- volume metrics
    total_events          INTEGER NOT NULL DEFAULT 0,
    pageview_count        INTEGER NOT NULL DEFAULT 0,
    interaction_count     INTEGER NOT NULL DEFAULT 0,   -- all event_type = 2 events
    deliberate_action_count INTEGER NOT NULL DEFAULT 0, -- unambiguous user gestures only

    -- feature flags: did this visit use each feature at all? (0/1)
    used_photo_gallery    INTEGER NOT NULL DEFAULT 0,
    used_kiss_button      INTEGER NOT NULL DEFAULT 0,
    used_theme            INTEGER NOT NULL DEFAULT 0,   -- theme_change fired (may include state-restore)
    used_minesweeper      INTEGER NOT NULL DEFAULT 0,
    used_games_shelf      INTEGER NOT NULL DEFAULT 0,
    used_music_player     INTEGER NOT NULL DEFAULT 0,
    used_video_player     INTEGER NOT NULL DEFAULT 0,
    used_spotify_game     INTEGER NOT NULL DEFAULT 0,
    used_settings         INTEGER NOT NULL DEFAULT 0,
    used_outbound_link    INTEGER NOT NULL DEFAULT 0,

    -- distinct features engaged with (for breadth-of-engagement analysis)
    distinct_features_used INTEGER NOT NULL DEFAULT 0,

    -- landing page
    landing_path      TEXT,

    -- engagement classification
    is_engaged        INTEGER NOT NULL DEFAULT 0   -- 1 if deliberate_action_count >= 1
);

INSERT INTO fact_visits (
    visit_id, session_id,
    visit_start, visit_end, visit_span_seconds,
    source_channel,
    browser, os, device, country, city,
    total_events, pageview_count, interaction_count, deliberate_action_count,
    used_photo_gallery, used_kiss_button, used_theme, used_minesweeper,
    used_games_shelf, used_music_player, used_video_player, used_spotify_game,
    used_settings, used_outbound_link,
    distinct_features_used,
    landing_path,
    is_engaged
)
WITH

-- Step 1: first event per visit for landing page + device context.
-- ROW_NUMBER() guarantees exactly one row per visit regardless of ties.
first_event AS (
    SELECT visit_id, canonical_path, browser, os, device, country, city,
           ROW_NUMBER() OVER (PARTITION BY visit_id ORDER BY created_at, event_id) AS rn
    FROM fact_events
),

-- Step 2: aggregate all events per visit into visit-level metrics.
agg AS (
    SELECT
        visit_id,
        MIN(session_id)                                        AS session_id,
        MIN(source_channel)                                    AS source_channel,
        MIN(created_at)                                        AS visit_start,
        MAX(created_at)                                        AS visit_end,
        -- span: difference in seconds between first and last event.
        -- SQLite has no native DATEDIFF, so we use strftime to extract
        -- epoch seconds and subtract. Works correctly across day boundaries.
        CAST(
            (strftime('%s', MAX(created_at)) - strftime('%s', MIN(created_at)))
        AS INTEGER)                                            AS visit_span_seconds,
        COUNT(*)                                               AS total_events,
        SUM(CASE WHEN event_type = 1 THEN 1 ELSE 0 END)       AS pageview_count,
        SUM(CASE WHEN event_type = 2 THEN 1 ELSE 0 END)       AS interaction_count,
        SUM(is_deliberate_action)                              AS deliberate_action_count,

        -- feature flags
        MAX(CASE WHEN feature_category = 'Photo Gallery'       THEN 1 ELSE 0 END) AS used_photo_gallery,
        MAX(CASE WHEN feature_category = 'Kiss Button'         THEN 1 ELSE 0 END) AS used_kiss_button,
        MAX(CASE WHEN feature_category = 'Theme/Personalization' THEN 1 ELSE 0 END) AS used_theme,
        MAX(CASE WHEN feature_category = 'Minesweeper'         THEN 1 ELSE 0 END) AS used_minesweeper,
        MAX(CASE WHEN feature_category = 'Games Shelf'         THEN 1 ELSE 0 END) AS used_games_shelf,
        MAX(CASE WHEN feature_category = 'Music Player'        THEN 1 ELSE 0 END) AS used_music_player,
        MAX(CASE WHEN feature_category = 'Video Player'        THEN 1 ELSE 0 END) AS used_video_player,
        MAX(CASE WHEN feature_category = 'Spotify Goal Game'   THEN 1 ELSE 0 END) AS used_spotify_game,
        MAX(CASE WHEN feature_category = 'Settings'            THEN 1 ELSE 0 END) AS used_settings,
        MAX(CASE WHEN feature_category = 'Outbound Link'       THEN 1 ELSE 0 END) AS used_outbound_link,

        -- distinct feature categories used (breadth metric).
        -- site lifecycle events excluded: page_load/exit/heartbeat
        -- don't represent feature choices.
        COUNT(DISTINCT CASE
            WHEN feature_category NOT IN ('Site Lifecycle') AND feature_category IS NOT NULL
            THEN feature_category
        END)                                                   AS distinct_features_used

    FROM fact_events
    GROUP BY visit_id
)

SELECT
    agg.visit_id,
    agg.session_id,
    agg.visit_start,
    agg.visit_end,
    agg.visit_span_seconds,
    agg.source_channel,
    fe.browser,
    fe.os,
    fe.device,
    fe.country,
    fe.city,
    agg.total_events,
    agg.pageview_count,
    agg.interaction_count,
    agg.deliberate_action_count,
    agg.used_photo_gallery,
    agg.used_kiss_button,
    agg.used_theme,
    agg.used_minesweeper,
    agg.used_games_shelf,
    agg.used_music_player,
    agg.used_video_player,
    agg.used_spotify_game,
    agg.used_settings,
    agg.used_outbound_link,
    agg.distinct_features_used,
    fe.canonical_path  AS landing_path,
    CASE WHEN agg.deliberate_action_count >= 1 THEN 1 ELSE 0 END AS is_engaged
FROM agg
JOIN first_event fe ON fe.visit_id = agg.visit_id AND fe.rn = 1;

CREATE INDEX idx_fv_session  ON fact_visits(session_id);
CREATE INDEX idx_fv_source   ON fact_visits(source_channel);
CREATE INDEX idx_fv_engaged  ON fact_visits(is_engaged);
CREATE INDEX idx_fv_start    ON fact_visits(visit_start);

-- Sanity checks
SELECT 'fact_visits rows'           AS check_name, COUNT(*)                                   AS value FROM fact_visits
UNION ALL
SELECT 'engaged visits',                           SUM(is_engaged)                             FROM fact_visits
UNION ALL
SELECT 'not engaged',                              SUM(CASE WHEN is_engaged=0 THEN 1 ELSE 0 END) FROM fact_visits
UNION ALL
SELECT 'avg deliberate actions (engaged only)',    ROUND(AVG(CAST(deliberate_action_count AS REAL)),1) FROM fact_visits WHERE is_engaged = 1
UNION ALL
SELECT 'avg visit span seconds (engaged)',         ROUND(AVG(CAST(visit_span_seconds AS REAL)),0) FROM fact_visits WHERE is_engaged = 1
UNION ALL
SELECT 'avg visit span seconds (not engaged)',     ROUND(AVG(CAST(visit_span_seconds AS REAL)),0) FROM fact_visits WHERE is_engaged = 0
UNION ALL
SELECT 'visits using photo gallery',              SUM(used_photo_gallery)                     FROM fact_visits
UNION ALL
SELECT 'visits using minesweeper',                SUM(used_minesweeper)                       FROM fact_visits
UNION ALL
SELECT 'visits using outbound link',              SUM(used_outbound_link)                     FROM fact_visits
UNION ALL
SELECT 'source channel check (sum = 391)',        COUNT(*)                                    FROM fact_visits
UNION ALL
SELECT source_channel || ' visits',               COUNT(*)                                    FROM fact_visits GROUP BY source_channel;
