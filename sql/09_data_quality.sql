-- ============================================================
-- 09_data_quality.sql
-- Module 5: Data quality and instrumentation reliability
-- Formal documentation of every known data limitation,
-- instrumentation artifact, and exclusion decision made during
-- the profiling and modeling phase.
--
-- Run this module against the staging tables (stg_*) and the
-- raw imports (raw_*) so findings are traceable to source.
-- ============================================================


-- ---------------------------------------------------------------
-- DQ-1. Out-of-scope property exclusion: kritiquekapital.com
-- A second website property was mixed into the same analytics
-- export under the same website_id. Identified via disjoint
-- event vocabulary (section_open, slice_click vs. kiss_button,
-- photo_click) and an isolated 4-day window (Mar 28–Apr 1).
-- Excluded in 02_stage_clean.sql via hostname filter.
-- Impact: 399 rows and 38 visits removed from scope.
-- Corrected baseline: 391 visits vs. 424 in the original brief.
-- ---------------------------------------------------------------
SELECT
    COALESCE(hostname, '(blank hostname)')      AS hostname,
    COUNT(*)                                    AS rows_excluded,
    COUNT(DISTINCT visit_id)                    AS visits_excluded,
    MIN(created_at)                             AS first_event,
    MAX(created_at)                             AS last_event
FROM raw_website_event
WHERE created_at >= '2026-03-24' AND created_at < '2026-06-01'
  AND (hostname = 'kritiquekapital.com'
       OR hostname IS NULL
       OR hostname = '')
GROUP BY hostname;

-- NOTE: the two hostname rows above are NOT additive -- every
-- blank-hostname row belongs to a visit_id that also has a
-- kritiquekapital.com-hostname row. The true distinct count of
-- excluded visits is the union below, not the sum of the two rows.
SELECT
    COUNT(DISTINCT visit_id) AS true_distinct_visits_excluded
FROM raw_website_event
WHERE created_at >= '2026-03-24' AND created_at < '2026-06-01'
  AND (hostname = 'kritiquekapital.com' OR hostname IS NULL OR hostname = '');


-- ---------------------------------------------------------------
-- DQ-2. minesweeper_open: instrumentation artifact
-- minesweeper_open fires automatically on page load to force the
-- leaderboard to hydrate in the background. It is NOT triggered
-- by a user opening the game. This was discovered by observing
-- it fire on 372 of 391 visits (95%), including every Ashburn
-- bot visit, and simultaneously with page_load on state-restore.
-- Reclassified from 'Minesweeper' to 'Site Lifecycle' in
-- dim_features; excluded from is_deliberate_action in fact_events.
--
-- "Actual gameplay" is defined consistently here and in Finding 5
-- (10_final_findings.sql) as minesweeper_start, minesweeper_new_game,
-- minesweeper_loss, and minesweeper_difficulty_change -- 6 visits.
-- Actual gameplay (minesweeper_start / new_game / loss): 6 visits.
-- ---------------------------------------------------------------
SELECT
    'minesweeper_open (auto-fire, technical)'   AS event_type,
    COUNT(*)                                    AS total_events,
    COUNT(DISTINCT visit_id)                    AS visits_affected
FROM stg_website_events
WHERE event_name = 'minesweeper_open'
UNION ALL
SELECT
    'minesweeper gameplay (start/new_game/loss)',
    COUNT(*),
    COUNT(DISTINCT visit_id)
FROM stg_website_events
WHERE event_name IN ('minesweeper_start','minesweeper_new_game',
                     'minesweeper_loss','minesweeper_difficulty_change');


-- ---------------------------------------------------------------
-- DQ-3. Stale label on a repurposed outbound link: substack-button
-- (and a second, smaller instance: duolingo)
--
-- The substack-button destination changed mid-window -- but this
-- was an intentional repurposing, not a regression. It correctly
-- pointed to substack.com/@camglhf from Mar 28–Apr 3 (7 clicks,
-- 5 sessions), then was deliberately re-pointed to
-- kritiquekapital.com starting Apr 14 (32 clicks, 27 sessions).
-- kritiquekapital.com is the current, correct destination for
-- this button going forward.
--
-- The "duolingo" label shows the identical pattern at smaller
-- scale: 9 clicks to an invite link and 2 clicks to a profile-
-- share link, both under the same label -- also a legitimate
-- destination change, not a broken link.
--
-- The actual data-quality issue in both cases: the button's
-- internal label/id was never updated to reflect the new
-- destination, so any label-based reporting silently conflates
-- different eras of intent under one name. This is a labeling/
-- metadata hygiene issue, not a broken link.
-- Recommendation: rename substack-button to reflect its current
-- destination (e.g. "kritiquekapital-button"), and keep a
-- periodic label-to-destination audit (DQ-3b/DQ-3c below) so
-- future intentional destination changes get documented at the
-- label level rather than discovered after the fact.
-- ---------------------------------------------------------------

-- DQ-3a. Substack destination split
SELECT
    dest.string_value                           AS destination,
    COUNT(*)                                    AS clicks,
    COUNT(DISTINCT lbl.session_id)              AS sessions,
    MIN(dest.created_at)                        AS first_click,
    MAX(dest.created_at)                        AS last_click
FROM event_properties_long lbl
JOIN event_properties_long dest
    ON dest.event_id = lbl.event_id
   AND dest.data_key = 'destination_url'
WHERE lbl.data_key = 'label'
  AND lbl.string_value = 'substack-button'
GROUP BY dest.string_value
ORDER BY first_click;

-- DQ-3b. Full outbound label→destination map for link auditing.
-- Run this periodically to catch href changes before they
-- accumulate significant misdirected traffic.
SELECT
    lbl.string_value                            AS button_label,
    dest.string_value                           AS destination_url,
    COUNT(*)                                    AS clicks,
    MIN(dest.created_at)                        AS first_seen,
    MAX(dest.created_at)                        AS last_seen
FROM event_properties_long lbl
JOIN event_properties_long dest
    ON dest.event_id = lbl.event_id
   AND dest.data_key = 'destination_url'
WHERE lbl.data_key = 'label'
  AND dest.is_functional_link = 1
GROUP BY lbl.string_value, dest.string_value
ORDER BY lbl.string_value, first_seen;

-- DQ-3c. Any label currently pointing to more than one destination.
-- Run this instead of eyeballing DQ-3b -- it surfaces substack-button
-- and duolingo automatically, and will catch the next one too.
SELECT
    lbl.string_value                            AS button_label,
    COUNT(DISTINCT dest.string_value)           AS distinct_destinations
FROM event_properties_long lbl
JOIN event_properties_long dest
    ON dest.event_id = lbl.event_id
   AND dest.data_key = 'destination_url'
WHERE lbl.data_key = 'label'
  AND dest.is_functional_link = 1
GROUP BY lbl.string_value
HAVING COUNT(DISTINCT dest.string_value) > 1;


-- ---------------------------------------------------------------
-- DQ-4. page_exit tracking: effectively non-functional
-- page_exit fired only 4 times across 391 visits. The event
-- is expected to fire when a user navigates away or closes the
-- tab, but browser tab-close and navigation events are
-- unreliable in most analytics stacks -- the browser may not
-- give the page enough time to fire the event before unloading.
-- Result: visit_span_seconds (MAX - MIN timestamp) understates
-- true time-on-site for most visits. Exit-page analysis is
-- not possible with this data and is excluded from findings.
-- ---------------------------------------------------------------
SELECT
    COUNT(*)                                    AS page_exit_events,
    COUNT(DISTINCT visit_id)                    AS visits_with_exit_event,
    391 - COUNT(DISTINCT visit_id)              AS visits_missing_exit_event
FROM stg_website_events
WHERE event_name = 'page_exit';


-- ---------------------------------------------------------------
-- DQ-5. Ashburn bot pattern
-- 19 visits from Ashburn, Virginia (a major US data-center hub)
-- share an identical fingerprint: minesweeper_open + theme_change
-- (both state-restore auto-fires) + exactly one pageview, zero
-- deliberate user actions. These are correctly classified as
-- not-engaged by the is_engaged definition and are visible in
-- the 'Direct' source channel (bots carry no referrer headers).
-- Not excluded from the dataset -- bot/bounce visits are a real
-- part of total traffic and should be counted in denominators.
-- ---------------------------------------------------------------
SELECT
    we.city,
    COUNT(DISTINCT we.visit_id)                 AS visits,
    SUM(CASE WHEN we.event_type = 1 THEN 1 ELSE 0 END) AS pageviews,
    SUM(CASE WHEN we.event_name = 'minesweeper_open'
        THEN 1 ELSE 0 END)                      AS minesweeper_open_fires,
    COUNT(DISTINCT CASE WHEN we.event_name IN (
        'photo_click','kiss_button_click','outbound_link_click',
        'minesweeper_start','music_play_toggle'
    ) THEN we.visit_id END)                     AS visits_with_any_real_click,
    MIN(DATE(we.created_at))                    AS first_seen,
    MAX(DATE(we.created_at))                    AS last_seen
FROM stg_website_events we
WHERE we.city = 'Ashburn'
GROUP BY we.city;


-- ---------------------------------------------------------------
-- DQ-6. Same-timestamp events (1-second resolution artifact)
-- created_at has 1-second granularity. 2,188 (visit_id,
-- created_at) groups contain 2+ events -- this is NOT duplicate
-- logging. Rapid-fire features (kiss button, photo clicks) can
-- fire multiple events in the same second. State-restore on page
-- load also fires multiple events simultaneously. No deduplication
-- applied; events with identical timestamps are distinct rows
-- with distinct event_ids.
-- ---------------------------------------------------------------
SELECT
    COUNT(*)                                    AS timestamp_groups_with_2plus_events,
    MAX(event_count)                            AS max_events_in_one_second
FROM (
    SELECT visit_id, created_at, COUNT(*) AS event_count
    FROM stg_website_events
    GROUP BY visit_id, created_at
    HAVING COUNT(*) > 1
);


-- ---------------------------------------------------------------
-- DQ-7. test_event exclusion
-- One developer smoke-test event was present in the raw export
-- (event_name = 'test_event', property foo = 'bar', May 19).
-- Excluded in 02_stage_clean.sql. Confirmed via event_data join.
-- ---------------------------------------------------------------
SELECT
    we.created_at,
    we.visit_id,
    we.event_name,
    ed.data_key,
    ed.string_value
FROM raw_website_event we
LEFT JOIN raw_event_data ed ON ed.event_id = we.event_id
WHERE we.event_name = 'test_event';


-- ---------------------------------------------------------------
-- DQ-8. Web vitals: zero in-scope observations
-- All 58 web-vitals events (event_type = 5) in the full export
-- had a blank hostname and traced back exclusively to
-- kritiquekapital.com visits. ideo.cam has no observed web-vitals
-- data in this window. Performance monitoring (LCP, FCP, CLS,
-- INP, TTFB) was not firing on the live site during this period.
-- ---------------------------------------------------------------
SELECT
    COALESCE(hostname, '(blank)') AS hostname,
    COUNT(*)                      AS vitals_events
FROM raw_website_event
WHERE event_type = 5
  AND created_at >= '2026-03-24'
  AND created_at < '2026-06-01'
GROUP BY hostname;


-- ---------------------------------------------------------------
-- DQ-9. Visit span reliability
-- visit_span_seconds = MAX(created_at) - MIN(created_at) within
-- a visit. This understates true time-on-site because:
--   a) page_exit fires too rarely to mark the true end time
--   b) single-event visits always show span = 0
--   c) the last recorded event may be well before the actual exit
-- Treat visit_span_seconds as a lower-bound proxy, not a precise
-- time-on-site measurement.
-- ---------------------------------------------------------------
SELECT
    SUM(CASE WHEN visit_span_seconds = 0 THEN 1 ELSE 0 END)    AS zero_span_visits,
    SUM(CASE WHEN visit_span_seconds BETWEEN 1 AND 30
        THEN 1 ELSE 0 END)                                      AS sub_30s,
    SUM(CASE WHEN visit_span_seconds BETWEEN 31 AND 300
        THEN 1 ELSE 0 END)                                      AS btw_30s_5min,
    SUM(CASE WHEN visit_span_seconds > 300 THEN 1 ELSE 0 END)  AS over_5min,
    ROUND(AVG(CASE WHEN is_engaged = 1
        THEN visit_span_seconds END) / 60.0, 1)                AS avg_span_min_engaged,
    COUNT(*)                                                    AS total_visits
FROM fact_visits;


-- ---------------------------------------------------------------
-- DQ-10. Outbound-link exits: visits ending on a link click
-- 50 visits have outbound_link_click as their final recorded
-- event. These visits "exited" by clicking a link -- a useful
-- behavioural signal even without reliable page_exit data.
-- ---------------------------------------------------------------
WITH last_event AS (
    SELECT
        visit_id,
        event_name,
        ROW_NUMBER() OVER (
            PARTITION BY visit_id ORDER BY created_at DESC, event_id DESC
        ) AS rn
    FROM stg_website_events
)
SELECT
    COALESCE(event_name, '(pageview)')          AS last_recorded_event,
    COUNT(*)                                    AS visits
FROM last_event
WHERE rn = 1
GROUP BY event_name
ORDER BY visits DESC;


-- ---------------------------------------------------------------
-- DQ-11. Geolocation and device fields are partially populated
-- country/city/browser/os/device are captured only when the
-- visitor's browser makes them available -- e.g. blocked by
-- privacy settings, ad blockers, or the visitor's own
-- configuration. This is consistent with (and a direct consequence
-- of) the site's intentionally non-intrusive, cookie-free
-- analytics setup: no fingerprinting or persistent identifiers are
-- used to backfill gaps. Treat these fields as best-effort context,
-- not guaranteed dimensions -- don't assume 100% coverage in any
-- GROUP BY or use them as a required join key.
-- ---------------------------------------------------------------
SELECT
    COUNT(*)                                            AS total_events,
    SUM(CASE WHEN country IS NULL THEN 1 ELSE 0 END)   AS missing_country,
    SUM(CASE WHEN city    IS NULL THEN 1 ELSE 0 END)   AS missing_city,
    SUM(CASE WHEN device  IS NULL THEN 1 ELSE 0 END)   AS missing_device,
    SUM(CASE WHEN browser IS NULL THEN 1 ELSE 0 END)   AS missing_browser
FROM stg_website_events;


-- ---------------------------------------------------------------
-- DQ-12. Two missing-value conventions in the same export, and
-- the classification bug it caused.
--
-- The raw export encodes "missing" two different ways depending
-- on column: web-vitals fields (lcp/inp/cls/fcp/ttfb) use the
-- literal string '\N', while hostname/region/URL/UTM/referrer/
-- fbclid fields use plain empty string '' instead. The original
-- staging script only normalized '\N' to NULL, so utm_source and
-- referrer_domain stayed as '' for the ~278 visits with no tag
-- and no referrer.
--
-- Impact: the source-channel CASE in 03_build_dimensions.sql
-- checked "utm_source IS NULL AND referrer_domain IS NULL" for
-- 'Direct' and "referrer_domain IS NOT NULL" for 'Other Referral'.
-- Since '' is NOT NULL, every genuine Direct visit fell into
-- 'Other Referral' instead, leaving 'Direct' empty in every table
-- and chart and inflating 'Other Referral' to 280 visits (should
-- be 2 -- just the real facebook.com referrals).
--
-- The signal was visible from the first profiling pass: query #4
-- in 00_data_profile.sql reported utm_source_null = 0 and
-- referrer_domain_null = 0 across the whole window, which was
-- read as "these fields are just unused" rather than "check for
-- a second missing-value marker." Fixed by chaining a second
-- NULLIF(..., '') onto every affected column in 02_stage_clean.sql.
-- Query below reproduces the check that should have caught it.
-- ---------------------------------------------------------------
SELECT
    SUM(CASE WHEN utm_source = ''      THEN 1 ELSE 0 END) AS utm_source_empty_string,
    SUM(CASE WHEN utm_source IS NULL   THEN 1 ELSE 0 END) AS utm_source_true_null,
    SUM(CASE WHEN referrer_domain = ''    THEN 1 ELSE 0 END) AS referrer_domain_empty_string,
    SUM(CASE WHEN referrer_domain IS NULL THEN 1 ELSE 0 END) AS referrer_domain_true_null
FROM raw_website_event
WHERE created_at >= '2026-03-24' AND created_at < '2026-06-01';


-- ---------------------------------------------------------------
-- DQ-13. Photo filename rename mid-window: cordes-en-boyaux
-- The same photo was logged under two filenames with a clean,
-- non-overlapping date cutover: 'cordes en boyaux.png' (space)
-- from Mar 28-Apr 2, then 'cordes-en-boyaux.png' (hyphen) from
-- Apr 3 onward. Confirmed as a rename, not two photos, and
-- normalized to the hyphenated form in event_properties_long
-- (03_build_dimensions.sql) so the top-photos ranking in
-- 07_feature_engagement.sql isn't artificially split. Combined:
-- 142 clicks, which moves it well up the ranking.
-- ---------------------------------------------------------------
SELECT
    CASE WHEN string_value = 'cordes en boyaux.png' THEN 'pre-rename (space)'
         ELSE 'post-rename (hyphen)' END           AS era,
    COUNT(*)                                        AS clicks,
    MIN(created_at)                                 AS first_seen,
    MAX(created_at)                                 AS last_seen
FROM stg_event_properties
WHERE event_name = 'photo_click' AND data_key = 'file'
  AND string_value IN ('cordes en boyaux.png', 'cordes-en-boyaux.png')
GROUP BY era;
