-- ============================================================
-- 00_data_profile.sql
-- Module 1: Data profiling and measurement audit
-- Run against raw_website_event, raw_event_data, raw_session_data
-- (straight CSV imports, no cleaning applied yet)
-- ============================================================

-- 1. Row counts and key cardinality: confirms what a "row" represents
--    in each table before we model anything on top of it.
SELECT
    COUNT(*)                       AS total_rows,
    COUNT(DISTINCT event_id)       AS distinct_event_ids,
    COUNT(DISTINCT visit_id)       AS distinct_visit_ids,
    COUNT(DISTINCT session_id)     AS distinct_session_ids
FROM raw_website_event;

-- 2. Analysis-window boundary check.
--    created_at is stored as naive local time that already matches ET
--    (verified: earliest row is 2026-03-24 21:40:03, matching the
--    documented "March 24, 9:40 PM ET" first event -- NOT UTC).
--    So the window filter below needs no timezone conversion.
SELECT
    MIN(created_at) AS earliest_event,
    MAX(created_at) AS latest_event,
    SUM(CASE WHEN created_at >= '2026-03-24 00:00:00'
              AND created_at <  '2026-06-01 00:00:00' THEN 1 ELSE 0 END) AS rows_in_window,
    SUM(CASE WHEN created_at >= '2026-06-01 00:00:00' THEN 1 ELSE 0 END) AS rows_after_window
FROM raw_website_event;

-- 3. event_type breakdown inside the window (pageview / interaction / vitals).
SELECT
    event_type,
    CASE event_type
        WHEN 1 THEN 'Pageview'
        WHEN 2 THEN 'Custom Interaction'
        WHEN 5 THEN 'Web Vitals / Performance'
        ELSE 'Unmapped'
    END AS event_class,
    COUNT(*) AS row_count
FROM raw_website_event
WHERE created_at >= '2026-03-24 00:00:00' AND created_at < '2026-06-01 00:00:00'
GROUP BY event_type
ORDER BY event_type;

-- 4. Column completeness inside the window: which fields are usable
--    vs. structurally empty (click-id and UTM fields are mostly unused
--    here, which is expected for a low-traffic personal site, but we
--    should still know it before building dim_sources).
SELECT
    SUM(CASE WHEN utm_source      IS NULL THEN 1 ELSE 0 END) AS utm_source_null,
    SUM(CASE WHEN referrer_domain IS NULL THEN 1 ELSE 0 END) AS referrer_domain_null,
    SUM(CASE WHEN event_name      IS NULL THEN 1 ELSE 0 END) AS event_name_null,
    SUM(CASE WHEN lcp = '\N'                 THEN 1 ELSE 0 END) AS lcp_unset,
    COUNT(*) AS total_rows
FROM raw_website_event
WHERE created_at >= '2026-03-24 00:00:00' AND created_at < '2026-06-01 00:00:00';

-- 5. Home-path variants that should collapse to a single logical page
--    in dim_pages (cleaning rule #3 in the project brief).
SELECT url_path, COUNT(*) AS hits
FROM raw_website_event
WHERE created_at >= '2026-03-24 00:00:00' AND created_at < '2026-06-01 00:00:00'
  AND url_path IN ('/', '/marjork/', '/index.html')
GROUP BY url_path
ORDER BY hits DESC;

-- 6. Custom interaction event_name catalog and volume -- the menu of
--    "features" we'll classify in dim_event_types / feature engagement.
SELECT event_name, COUNT(*) AS occurrences
FROM raw_website_event
WHERE created_at >= '2026-03-24 00:00:00' AND created_at < '2026-06-01 00:00:00'
  AND event_type = 2
GROUP BY event_name
ORDER BY occurrences DESC;

-- 7. Same-timestamp event clusters within a visit. A high count here
--    does NOT necessarily mean duplicate logging -- created_at has
--    one-second granularity, so genuine rapid-fire clicks (e.g. the
--    kiss button) will naturally collide. We flag the pattern here
--    and decide visit-by-visit in the data-quality module whether any
--    specific burst looks like a logging artifact vs. real behavior.
SELECT
    COUNT(*) AS rows_sharing_a_timestamp_with_a_sibling_event
FROM (
    SELECT visit_id, created_at, event_name
    FROM raw_website_event
    WHERE created_at >= '2026-03-24 00:00:00' AND created_at < '2026-06-01 00:00:00'
    GROUP BY visit_id, created_at, event_name
    HAVING COUNT(*) > 1
);

-- 8. Largest anonymous session by distinct visit_id count -- the
--    evidence for treating visit_id, not session_id, as the unit of
--    a single browsing visit.
SELECT session_id, COUNT(DISTINCT visit_id) AS visit_count
FROM raw_website_event
GROUP BY session_id
ORDER BY visit_count DESC
LIMIT 5;

-- 9. Explicit test/instrumentation events that should be excluded or
--    flagged before behavioral analysis.
SELECT event_id, session_id, visit_id, created_at, url_path, event_name
FROM raw_website_event
WHERE event_name = 'test_event';

-- 10. event_data profile: property rows and how many distinct events
--     carry at least one property (one-to-many relationship to events).
SELECT
    COUNT(*)                  AS total_property_rows,
    COUNT(DISTINCT event_id)  AS distinct_events_with_properties,
    COUNT(DISTINCT data_key)  AS distinct_property_keys
FROM raw_event_data
WHERE created_at >= '2026-03-24 00:00:00' AND created_at < '2026-06-01 00:00:00';

-- 11. event_data data_key catalog -- what kinds of properties exist.
SELECT data_key, COUNT(*) AS occurrences
FROM raw_event_data
WHERE created_at >= '2026-03-24 00:00:00' AND created_at < '2026-06-01 00:00:00'
GROUP BY data_key
ORDER BY occurrences DESC;

-- 12. session_data coverage check -- confirms this table is out of
--     scope for the March-May core analysis (starts May 31).
SELECT
    COUNT(DISTINCT session_id) AS distinct_sessions,
    MIN(created_at)            AS earliest,
    MAX(created_at)            AS latest
FROM raw_session_data;
