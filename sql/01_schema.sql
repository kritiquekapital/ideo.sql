-- ============================================================
-- 01_schema.sql
-- Staging schema: typed, cleaned mirrors of the raw export.
-- Per the project's modeling rule: visit_id is the unit of a
-- single browsing visit; session_id is kept only as a longer-term
-- anonymous identifier, never used as "one session" in metrics.
--
-- Columns that were 100% null/unused across the in-scope window
-- (gclid, msclkid, ttclid, li_fat_id, twclid, utm_campaign,
-- utm_term, distinct_id, tag, referrer_query, job_id) are dropped
-- here rather than carried through dead weight. fbclid is kept in
-- staging for completeness but flagged for removal before any
-- public/sample export, since it's a click identifier.
-- ============================================================

DROP TABLE IF EXISTS stg_website_events;
CREATE TABLE stg_website_events (
    event_id        TEXT PRIMARY KEY,
    website_id      TEXT,
    session_id      TEXT,
    visit_id        TEXT,
    hostname        TEXT,        -- retained for audit trail even though
                                  -- in-scope data is effectively one site
    browser         TEXT,
    os              TEXT,
    device          TEXT,
    screen          TEXT,
    language        TEXT,
    country         TEXT,
    region          TEXT,
    city            TEXT,
    url_path        TEXT,
    url_query       TEXT,
    utm_source      TEXT,
    utm_medium      TEXT,
    utm_content     TEXT,
    referrer_path   TEXT,
    referrer_domain TEXT,
    page_title      TEXT,
    fbclid          TEXT,        -- click id; drop before any public export
    lcp             REAL,
    inp             REAL,
    cls             REAL,
    fcp             REAL,
    ttfb            REAL,
    event_type      INTEGER,     -- 1 = pageview, 2 = custom interaction, 5 = web vitals
    event_name      TEXT,
    created_at      TEXT         -- naive local time, already ET-equivalent; no tz math needed
);

CREATE INDEX idx_stg_we_visit   ON stg_website_events(visit_id);
CREATE INDEX idx_stg_we_session ON stg_website_events(session_id);
CREATE INDEX idx_stg_we_created ON stg_website_events(created_at);

DROP TABLE IF EXISTS stg_event_properties;
CREATE TABLE stg_event_properties (
    event_id      TEXT,
    session_id    TEXT,
    url_path      TEXT,
    event_name    TEXT,
    data_key      TEXT,
    string_value  TEXT,
    number_value  REAL,
    data_type     INTEGER,     -- 1 = string, 2 = numeric, 3 = boolean (observed; no date-typed rows exist)
    created_at    TEXT,
    PRIMARY KEY (event_id, data_key)
);

CREATE INDEX idx_stg_ep_event ON stg_event_properties(event_id);
CREATE INDEX idx_stg_ep_key   ON stg_event_properties(data_key);

-- session_data (device/connection properties) is explicitly out of
-- scope for V1 per the project brief: only 7 sessions, starting
-- May 31, well after the core window. Intentionally not staged here.
-- Revisit as an appendix table if a later analysis window includes it.
