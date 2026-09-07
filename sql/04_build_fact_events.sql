-- ============================================================
-- 04_build_fact_events.sql
-- One row per event_id. Joins every dimension lookup into a single
-- flat, analysis-ready table so downstream queries never need to
-- re-derive event class, feature category, or source channel.
--
-- Canonical url_path rule: '/', '/marjork/', and '/index.html' all
-- represent the same single-page app home experience. Collapsed here
-- to '/' so any path-level aggregation is consistent.
-- ============================================================

DROP TABLE IF EXISTS fact_events;
CREATE TABLE fact_events (
    -- identity
    event_id          TEXT PRIMARY KEY,
    visit_id          TEXT NOT NULL,
    session_id        TEXT NOT NULL,

    -- timing
    created_at        TEXT NOT NULL,

    -- event classification (from dim_event_types / dim_features)
    event_type        INTEGER NOT NULL,
    event_class       TEXT NOT NULL,    -- 'Pageview' | 'Custom Interaction' | 'Web Vitals / Performance'
    event_name        TEXT,             -- NULL for pageviews (event_type = 1)
    feature_category  TEXT,             -- NULL for pageviews and unmapped events

    -- canonical page (single-page app: effectively always '/')
    canonical_path    TEXT,

    -- source (from visit_source: attributed to this visit's first event)
    source_channel    TEXT NOT NULL,

    -- device context
    browser           TEXT,
    os                TEXT,
    device            TEXT,
    country           TEXT,
    city              TEXT,

    -- is this a deliberate-action event?
    -- used to compute is_engaged on fact_visits; true for unambiguous
    -- clicks/plays/starts, false for state-restore opens and lifecycle events
    is_deliberate_action  INTEGER NOT NULL DEFAULT 0  -- 0/1 boolean
);

INSERT INTO fact_events (
    event_id, visit_id, session_id, created_at,
    event_type, event_class, event_name, feature_category,
    canonical_path, source_channel,
    browser, os, device, country, city,
    is_deliberate_action
)
SELECT
    we.event_id,
    we.visit_id,
    we.session_id,
    we.created_at,
    we.event_type,
    COALESCE(det.event_class, 'Unknown')  AS event_class,
    we.event_name,
    df.feature_category,

    -- collapse all home-path variants to '/'
    CASE
        WHEN we.url_path IN ('/', '/marjork/', '/index.html') THEN '/'
        ELSE we.url_path
    END AS canonical_path,

    vs.source_channel,
    we.browser,
    we.os,
    we.device,
    we.country,
    we.city,

    -- deliberate-action flag: these events require an explicit user gesture.
    -- excludes: _open (state-restorable), theme_change (ambiguous),
    -- lifecycle events (page_load, page_exit, site_loaded, session_heartbeat)
    CASE WHEN we.event_name IN (
        'photo_click',
        'kiss_button_click', 'kiss_button_sink', 'kiss_click', 'kiss_sink',
        'minesweeper_start', 'minesweeper_new_game', 'minesweeper_loss',
        'minesweeper_difficulty_change', 'minesweeper_leaderboard_open',
        'minesweeper_leaderboard_difficulty_change', 'minesweeper_leaderboard_sort_change',
        'games_shelf_game_click',
        'music_play_toggle', 'music_next_track', 'volume_set',
        'video_next', 'video_prev', 'video_pin_toggle',
        'spotify_goal_scored',
        'outbound_link_click',
        'url_links_toggle'
    ) THEN 1 ELSE 0 END AS is_deliberate_action

FROM stg_website_events we
LEFT JOIN dim_event_types  det ON det.event_type  = we.event_type
LEFT JOIN dim_features     df  ON df.event_name   = we.event_name
LEFT JOIN visit_source     vs  ON vs.visit_id     = we.visit_id;

CREATE INDEX idx_fe_visit   ON fact_events(visit_id);
CREATE INDEX idx_fe_created ON fact_events(created_at);
CREATE INDEX idx_fe_source  ON fact_events(source_channel);
CREATE INDEX idx_fe_feature ON fact_events(feature_category);

-- Sanity checks
SELECT 'fact_events rows'        AS check_name, COUNT(*)                    AS value FROM fact_events
UNION ALL
SELECT 'distinct visits',                        COUNT(DISTINCT visit_id)   FROM fact_events
UNION ALL
SELECT 'pageviews',                              COUNT(*)                    FROM fact_events WHERE event_type = 1
UNION ALL
SELECT 'deliberate-action events',              COUNT(*)                    FROM fact_events WHERE is_deliberate_action = 1
UNION ALL
SELECT 'visits with 1+ deliberate action',      COUNT(DISTINCT visit_id)   FROM fact_events WHERE is_deliberate_action = 1
UNION ALL
SELECT 'null feature_category (pageviews ok)',  COUNT(*)                    FROM fact_events WHERE feature_category IS NULL AND event_type = 2;
