-- ============================================================
-- 02_stage_clean.sql
-- Populates stg_website_events and stg_event_properties from the
-- raw imports, applying every cleaning decision made in the
-- profiling and design phase:
--
--   1. Scope filter: hostname IN ('ideo.cam', 'kritiquekapital.github.io',
--      '127.0.0.1'). kritiquekapital.com is a different property entirely
--      (confirmed via disjoint event vocabulary + isolated 4-day window)
--      and is excluded outright, not just flagged.
--   2. Window filter: 2026-03-24 00:00:00 (inclusive) to
--      2026-06-01 00:00:00 (exclusive). created_at is naive local time
--      that already matches ET -- verified against the documented
--      first-event timestamp, no UTC conversion applied.
--   3. '\N' literal placeholders normalized to true NULLs. NOTE: this
--      raw export uses TWO different "missing" conventions depending
--      on column -- web vitals fields (lcp/inp/cls/fcp/ttfb) use the
--      literal string '\N', while hostname/region/URL/UTM/referrer/
--      fbclid fields use plain empty string '' instead. Both are
--      normalized to NULL below (NULLIF chained on both markers) so
--      that no downstream IS NULL check silently misses an "empty"
--      value stored as ''. This was caught during dimension-building:
--      the source-channel classification originally used a bare
--      utm_source/referrer_domain IS NULL check, which matched zero
--      rows because the real "missing" marker was '' -- see
--      09_data_quality.sql DQ-12.
--   4. test_event rows (developer smoke-test, property foo:bar)
--      excluded entirely.
--   5. Web vitals fields cast from text to REAL.
-- ============================================================

DELETE FROM stg_website_events;

INSERT INTO stg_website_events (
    event_id, website_id, session_id, visit_id, hostname,
    browser, os, device, screen, language, country, region, city,
    url_path, url_query, utm_source, utm_medium, utm_content,
    referrer_path, referrer_domain, page_title, fbclid,
    lcp, inp, cls, fcp, ttfb,
    event_type, event_name, created_at
)
SELECT
    event_id,
    website_id,
    session_id,
    visit_id,
    NULLIF(NULLIF(hostname, '\N'), ''),
    NULLIF(browser, '\N'),
    NULLIF(os, '\N'),
    NULLIF(device, '\N'),
    NULLIF(screen, '\N'),
    NULLIF(language, '\N'),
    NULLIF(country, '\N'),
    NULLIF(NULLIF(region, '\N'), ''),
    NULLIF(city, '\N'),
    NULLIF(url_path, '\N'),
    NULLIF(NULLIF(url_query, '\N'), ''),
    NULLIF(NULLIF(utm_source, '\N'), ''),
    NULLIF(NULLIF(utm_medium, '\N'), ''),
    NULLIF(NULLIF(utm_content, '\N'), ''),
    NULLIF(NULLIF(referrer_path, '\N'), ''),
    NULLIF(NULLIF(referrer_domain, '\N'), ''),
    NULLIF(page_title, '\N'),
    NULLIF(NULLIF(fbclid, '\N'), ''),
    CASE WHEN lcp = '\N' OR lcp IS NULL THEN NULL ELSE CAST(lcp AS REAL) END,
    CASE WHEN inp = '\N' OR inp IS NULL THEN NULL ELSE CAST(inp AS REAL) END,
    CASE WHEN cls = '\N' OR cls IS NULL THEN NULL ELSE CAST(cls AS REAL) END,
    CASE WHEN fcp = '\N' OR fcp IS NULL THEN NULL ELSE CAST(fcp AS REAL) END,
    CASE WHEN ttfb = '\N' OR ttfb IS NULL THEN NULL ELSE CAST(ttfb AS REAL) END,
    event_type,
    NULLIF(event_name, '\N'),
    created_at
FROM raw_website_event
WHERE created_at >= '2026-03-24 00:00:00'
  AND created_at <  '2026-06-01 00:00:00'
  AND hostname IN ('ideo.cam', 'kritiquekapital.github.io', '127.0.0.1')
  AND (event_name IS NULL OR event_name != 'test_event');

DELETE FROM stg_event_properties;

INSERT INTO stg_event_properties (
    event_id, session_id, url_path, event_name, data_key,
    string_value, number_value, data_type, created_at
)
SELECT
    ed.event_id,
    ed.session_id,
    NULLIF(ed.url_path, '\N'),
    NULLIF(ed.event_name, '\N'),
    ed.data_key,
    NULLIF(ed.string_value, '\N'),
    CASE WHEN ed.number_value = '\N' OR ed.number_value IS NULL THEN NULL
         ELSE CAST(ed.number_value AS REAL) END,
    ed.data_type,
    ed.created_at
FROM raw_event_data ed
-- Inner join to the already-scoped staging table: this guarantees
-- stg_event_properties can never contain a property row for an event
-- that staging excluded (wrong hostname, outside window, or test_event).
INNER JOIN stg_website_events we ON we.event_id = ed.event_id;

-- Sanity checks
SELECT 'stg_website_events row count' AS check_name, COUNT(*) AS value FROM stg_website_events
UNION ALL
SELECT 'distinct visits', COUNT(DISTINCT visit_id) FROM stg_website_events
UNION ALL
SELECT 'distinct sessions', COUNT(DISTINCT session_id) FROM stg_website_events
UNION ALL
SELECT 'pageviews', COUNT(*) FROM stg_website_events WHERE event_type = 1
UNION ALL
SELECT 'interactions', COUNT(*) FROM stg_website_events WHERE event_type = 2
UNION ALL
SELECT 'web vitals', COUNT(*) FROM stg_website_events WHERE event_type = 5
UNION ALL
SELECT 'stg_event_properties row count', COUNT(*) FROM stg_event_properties
UNION ALL
SELECT 'distinct events with properties', COUNT(DISTINCT event_id) FROM stg_event_properties;
