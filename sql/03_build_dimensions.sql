-- ============================================================
-- 03_build_dimensions.sql
-- dim_event_types, dim_features (replaces dim_pages -- this is a
-- single-page app, so there's no URL-level page dimension to build;
-- intent is expressed through features instead), dim_sources, and
-- event_properties_long (cleaned long-format event properties).
-- ============================================================

-- ---------------------------------------------------------------
-- dim_event_types
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS dim_event_types;
CREATE TABLE dim_event_types (
    event_type   INTEGER PRIMARY KEY,
    event_class  TEXT NOT NULL
);
INSERT INTO dim_event_types VALUES
    (1, 'Pageview'),
    (2, 'Custom Interaction'),
    (5, 'Web Vitals / Performance');

-- ---------------------------------------------------------------
-- dim_features (replaces dim_pages)
-- One row per event_name observed on the in-scope site, mapped to
-- a human-readable feature category. test_event is intentionally
-- absent -- it was excluded in staging as developer smoke-test
-- traffic, not a real feature.
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS dim_features;
CREATE TABLE dim_features (
    event_name        TEXT PRIMARY KEY,
    feature_category  TEXT NOT NULL
);
INSERT INTO dim_features (event_name, feature_category) VALUES
    ('photo_click',                          'Photo Gallery'),
    ('kiss_button_click',                    'Kiss Button'),
    ('kiss_button_sink',                     'Kiss Button'),
    ('kiss_click',                           'Kiss Button'),
    ('kiss_sink',                             'Kiss Button'),
    ('theme_change',                         'Theme/Personalization'),
    ('theme_applied',                        'Theme/Personalization'),
    ('theme_toggle',                         'Theme/Personalization'),
    ('minesweeper_open',                     'Site Lifecycle'), -- auto-fires on load to force leaderboard hydration; not a user gesture
    ('minesweeper_start',                    'Minesweeper'),
    ('minesweeper_new_game',                 'Minesweeper'),
    ('minesweeper_loss',                     'Minesweeper'),
    ('minesweeper_difficulty_change',        'Minesweeper'),
    ('minesweeper_leaderboard_open',         'Minesweeper'),
    ('minesweeper_leaderboard_difficulty_change', 'Minesweeper'),
    ('minesweeper_leaderboard_sort_change',  'Minesweeper'),
    ('games_shelf_open',                     'Games Shelf'),
    ('games_shelf_close',                    'Games Shelf'),
    ('games_shelf_game_click',               'Games Shelf'),
    ('music_player_open',                    'Music Player'),
    ('music_play_toggle',                    'Music Player'),
    ('music_next_track',                     'Music Player'),
    ('volume_set',                           'Music Player'),
    ('video_player_open',                    'Video Player'),
    ('video_next',                           'Video Player'),
    ('video_prev',                           'Video Player'),
    ('video_pin_toggle',                     'Video Player'),
    ('spotify_goal_open',                    'Spotify Goal Game'),
    ('spotify_goal_scored',                  'Spotify Goal Game'),
    ('settings_open',                        'Settings'),
    ('settings_close',                       'Settings'),
    ('url_links_toggle',                     'Settings'),
    ('outbound_link_click',                  'Outbound Link'),
    ('site_loaded',                          'Site Lifecycle'),
    ('page_load',                            'Site Lifecycle'),
    ('page_exit',                            'Site Lifecycle'),
    ('session_heartbeat',                    'Site Lifecycle');

-- Sanity check: every in-scope custom-interaction event_name should
-- now have a feature_category. Anything returned here is a gap.
SELECT DISTINCT we.event_name
FROM stg_website_events we
LEFT JOIN dim_features df ON df.event_name = we.event_name
WHERE we.event_type = 2 AND df.event_name IS NULL;

-- ---------------------------------------------------------------
-- dim_sources
-- Lookup of traffic-source categories. Classification logic itself
-- (which visit gets which source_channel) lives in visit_source
-- below, since it requires reading each visit's FIRST event only --
-- UTM/referrer fields are typically populated on the landing event
-- and blank on later interaction events within the same visit.
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS dim_sources;
CREATE TABLE dim_sources (
    source_channel  TEXT PRIMARY KEY,
    description     TEXT NOT NULL,
    sort_order      INTEGER NOT NULL
);
INSERT INTO dim_sources VALUES
    ('Instagram',                 'utm_source = ig, or referred from l.instagram.com', 1),
    ('LinkedIn',                  'Referred from linkedin.com, no UTM tag',             2),
    ('Likely Bot/Spam Referrer',  'Single/few-hit referrer domains with no repeat engagement pattern (e.g. aisearchindex.space, zapmeta.com) -- kept visible, flagged rather than silently dropped', 3),
    ('Other Referral',            'Real referrer domain not otherwise classified',     4),
    ('Direct',                    'No UTM tag, no referrer',                            5),
    ('Other/Unknown',             'Catch-all; should be ~0 rows if classification is complete', 6);

-- ---------------------------------------------------------------
-- visit_source: one row per visit_id, attributed from that visit's
-- FIRST event using ROW_NUMBER() OVER (PARTITION BY visit_id ORDER BY
-- created_at). This is the window-function pattern: without it, a
-- visit with a UTM-tagged landing event but blank UTM on every
-- subsequent interaction would get double-counted or misclassified
-- if we scanned every row instead of just the first.
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS visit_source;
CREATE TABLE visit_source (
    visit_id        TEXT PRIMARY KEY,
    utm_source      TEXT,
    referrer_domain TEXT,
    source_channel  TEXT NOT NULL REFERENCES dim_sources(source_channel)
);

INSERT INTO visit_source (visit_id, utm_source, referrer_domain, source_channel)
WITH first_event AS (
    SELECT
        visit_id,
        utm_source,
        referrer_domain,
        ROW_NUMBER() OVER (PARTITION BY visit_id ORDER BY created_at, event_id) AS rn
    FROM stg_website_events
)
SELECT
    visit_id,
    utm_source,
    referrer_domain,
    CASE
        WHEN utm_source = 'ig' OR referrer_domain = 'l.instagram.com' THEN 'Instagram'
        WHEN referrer_domain = 'linkedin.com' THEN 'LinkedIn'
        WHEN referrer_domain IN (
            'aisearchindex.space','zapmeta.com','search.yam.com','panjoy.com',
            'omnimedicalsearch.com','lexxe.com','geona.com','claude.ai'
        ) THEN 'Likely Bot/Spam Referrer'
        WHEN referrer_domain IS NOT NULL THEN 'Other Referral'
        WHEN utm_source IS NULL AND referrer_domain IS NULL THEN 'Direct'
        ELSE 'Other/Unknown'
    END AS source_channel
FROM first_event
WHERE rn = 1;

CREATE INDEX idx_visit_source_channel ON visit_source(source_channel);

-- Sanity check: distribution should sum to 391 visits, Other/Unknown ~0.
SELECT source_channel, COUNT(*) AS visits
FROM visit_source
GROUP BY source_channel
ORDER BY visits DESC;

-- ---------------------------------------------------------------
-- event_properties_long: cleaned long-format properties.
--   - outbound_link_click: href/url collapsed into one canonical
--     data_key ('destination_url'); label suffix " opened-this-session"
--     stripped into a separate is_repeat_in_session flag rather than
--     baked into the text, so destination grouping isn't fragmented.
--   - '#'/'javascript:void(0);' destinations flagged as non-functional
--     rather than deleted, so click volume stays auditable.
--   - photo_click: filename normalized for one known rename. The
--     photo logged as 'cordes en boyaux.png' (space) from Mar 28-
--     Apr 2 and 'cordes-en-boyaux.png' (hyphen) from Apr 3 onward
--     -- a clean, non-overlapping date cutover confirms these are
--     the same photo under two filenames, not two photos. Collapsed
--     to the current hyphenated name so gallery rankings aren't
--     artificially split. See 09_data_quality.sql DQ-13.
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS event_properties_long;
CREATE TABLE event_properties_long (
    event_id              TEXT,
    session_id            TEXT,
    event_name            TEXT,
    data_key              TEXT,
    string_value          TEXT,
    number_value          REAL,
    data_type             INTEGER,
    is_repeat_in_session  INTEGER,   -- 1 if label originally carried "opened-this-session"
    is_functional_link    INTEGER,   -- 0 if destination is '#' or 'javascript:void(0);'
    created_at            TEXT
);

INSERT INTO event_properties_long (
    event_id, session_id, event_name, data_key, string_value, number_value,
    data_type, is_repeat_in_session, is_functional_link, created_at
)
SELECT
    event_id,
    session_id,
    event_name,
    CASE WHEN event_name = 'outbound_link_click' AND data_key IN ('href','url')
         THEN 'destination_url' ELSE data_key END AS data_key,
    CASE
        WHEN event_name = 'outbound_link_click' AND data_key = 'label'
             THEN TRIM(REPLACE(string_value, ' opened-this-session', ''))
        WHEN event_name = 'photo_click' AND data_key = 'file'
             AND string_value = 'cordes en boyaux.png'
             THEN 'cordes-en-boyaux.png'
        ELSE string_value
    END AS string_value,
    number_value,
    data_type,
    CASE WHEN event_name = 'outbound_link_click' AND data_key = 'label'
              AND string_value LIKE '%opened-this-session%'
         THEN 1 ELSE 0 END AS is_repeat_in_session,
    CASE WHEN event_name = 'outbound_link_click' AND data_key IN ('href','url')
              AND string_value IN ('#', 'javascript:void(0);')
         THEN 0 ELSE 1 END AS is_functional_link,
    created_at
FROM stg_event_properties;

-- event_properties_long has no natural primary key (a single event can
-- carry many properties, and self-joins on event_id are the dominant
-- access pattern in 06-10), so index the join and filter columns
-- explicitly rather than relying on a rowid scan.
CREATE INDEX idx_epl_event      ON event_properties_long(event_id);
CREATE INDEX idx_epl_name_key   ON event_properties_long(event_name, data_key);

-- Sanity check: outbound destinations after the href/url coalesce
-- and label cleanup, functional links only.
SELECT
    lbl.string_value AS label,
    dest.string_value AS destination_url,
    COUNT(*) AS rows
FROM event_properties_long lbl
JOIN event_properties_long dest
  ON dest.event_id = lbl.event_id AND dest.data_key = 'destination_url'
WHERE lbl.data_key = 'label' AND dest.is_functional_link = 1
GROUP BY lbl.string_value, dest.string_value
ORDER BY rows DESC
LIMIT 10;

-- Sanity check: cordes-en-boyaux should now appear as a single
-- merged row instead of two.
SELECT string_value AS photo_file, COUNT(*) AS clicks
FROM event_properties_long
WHERE event_name = 'photo_click' AND data_key = 'file'
  AND string_value LIKE 'cordes%'
GROUP BY string_value;
