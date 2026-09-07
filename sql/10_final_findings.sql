-- ============================================================
-- 10_final_findings.sql
-- Capstone: evidence-backed findings, recommendations, and
-- limitations for the ideo.cam portfolio case study.
--
-- Reporting window: March 24 – May 31, 2026 (10 weeks)
-- In-scope baseline: 391 visits / 227 sessions / 619 pageviews
-- Engaged visits: 205 (52%)
-- ============================================================


-- ============================================================
-- PART 1: FINDINGS
-- ============================================================

-- ---------------------------------------------------------------
-- FINDING 1: Instagram is the highest-quality traffic source
-- despite zero active promotion.
--
-- 86 visits arrived via a silent bio link — no post, no story,
-- no campaign. 76 of those 86 (88%) engaged with at least one
-- deliberate feature, compared to 41% of Direct visits.
-- Engaged Instagram visitors clicked outbound links at a 63%
-- rate, suggesting they arrived to explore the full online
-- presence, not a specific feature.
--
-- Critically, Instagram is the only consistently durable source.
-- Direct traffic collapsed from 84 visits in week 2 to under 15
-- visits/week by May. Instagram held 3–17 visits every single
-- week across the entire 10-week window.
-- ---------------------------------------------------------------

-- F1a. Engagement rate and depth by source
SELECT
    fv.source_channel,
    COUNT(*)                                                        AS total_visits,
    SUM(fv.is_engaged)                                              AS engaged_visits,
    ROUND(SUM(fv.is_engaged) * 100.0 / COUNT(*), 1)                AS engagement_rate_pct,
    ROUND(AVG(CASE WHEN fv.is_engaged = 1
        THEN fv.deliberate_action_count END), 1)                    AS avg_actions_engaged,
    ROUND(AVG(CASE WHEN fv.is_engaged = 1
        THEN fv.visit_span_seconds / 60.0 END), 1)                 AS avg_min_engaged,
    ROUND(SUM(CASE WHEN fv.is_engaged = 1
        THEN fv.used_outbound_link ELSE 0 END)
        * 100.0 / NULLIF(SUM(fv.is_engaged), 0), 1)                AS outbound_rate_pct
FROM fact_visits fv
JOIN dim_sources ds ON ds.source_channel = fv.source_channel
GROUP BY fv.source_channel
ORDER BY ds.sort_order;

-- F1b. Weekly Instagram vs Direct trend
SELECT
    MIN(DATE(fv.visit_start))                                       AS week_starting,
    SUM(CASE WHEN fv.source_channel = 'Instagram' THEN 1 ELSE 0 END) AS instagram,
    SUM(CASE WHEN fv.source_channel = 'Direct'    THEN 1 ELSE 0 END) AS direct
FROM fact_visits fv
GROUP BY strftime('%Y-%W', fv.visit_start)
ORDER BY strftime('%Y-%W', fv.visit_start);


-- ---------------------------------------------------------------
-- FINDING 2: Kiss Button and Photo Gallery form the core
-- experience loop; they dominate feature reach and transitions.
--
-- Kiss Button reached 71% of engaged visits (145 of 205).
-- Photo Gallery reached 45% (92 of 205). The most common
-- feature transition on the site is Photo Gallery → Kiss Button
-- (68 occurrences), closely followed by the reverse (58).
-- Both features have very high revisit rates within a single
-- visit (Kiss Button 96%, Photo Gallery 82%) confirming they
-- are anchors that visits orbit around, not linear stops.
-- Retro is the clear favourite theme: 475 switches, 175 sessions,
-- 33% of all theme activity.
-- ---------------------------------------------------------------

-- F2a. Feature reach among engaged visits
SELECT
    fe.feature_category,
    COUNT(DISTINCT fe.visit_id)                                     AS visits_reaching,
    ROUND(COUNT(DISTINCT fe.visit_id) * 100.0 / 205, 1)            AS pct_engaged_visits,
    ROUND(COUNT(*) * 1.0 / COUNT(DISTINCT fe.visit_id), 1)         AS avg_events_per_visit
FROM fact_events fe
WHERE fe.is_deliberate_action = 1
  AND fe.feature_category NOT IN ('Site Lifecycle')
GROUP BY fe.feature_category
ORDER BY visits_reaching DESC;

-- F2b. Top feature transitions
WITH deliberate_sequence AS (
    SELECT visit_id, feature_category, created_at, event_id,
           LAG(feature_category) OVER (
               PARTITION BY visit_id ORDER BY created_at, event_id
           ) AS prev_feature
    FROM fact_events
    WHERE is_deliberate_action = 1
      AND feature_category NOT IN ('Site Lifecycle')
),
deduped AS (
    SELECT visit_id, feature_category,
           ROW_NUMBER() OVER (
               PARTITION BY visit_id ORDER BY created_at, event_id
           ) AS rn
    FROM deliberate_sequence
    WHERE feature_category IS NOT prev_feature OR prev_feature IS NULL
)
SELECT
    a.feature_category                                              AS from_feature,
    b.feature_category                                              AS to_feature,
    COUNT(*)                                                        AS transitions
FROM deduped a
JOIN deduped b ON b.visit_id = a.visit_id AND b.rn = a.rn + 1
WHERE a.feature_category != b.feature_category
GROUP BY a.feature_category, b.feature_category
ORDER BY transitions DESC
LIMIT 10;

-- F2c. Theme leaderboard
SELECT
    string_value                                                    AS theme,
    COUNT(*)                                                        AS switches,
    COUNT(DISTINCT session_id)                                      AS distinct_sessions,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1)            AS pct_of_all_switches
FROM event_properties_long
WHERE event_name IN ('theme_change', 'theme_applied', 'theme_toggle')
  AND data_key = 'theme'
GROUP BY string_value
ORDER BY switches DESC;


-- ---------------------------------------------------------------
-- FINDING 3: Feature breadth is the best predictor of visit
-- depth. Journey depth scales monotonically with time spent.
--
-- Visits using 1 distinct feature average 30 seconds.
-- Visits using 7–9 features average 37–42 minutes.
-- The relationship is strong and consistent, making distinct
-- features used a reliable proxy for visit quality on this
-- single-page app (where URL-level navigation doesn't exist).
-- 54% of engaged visits used 3 or more distinct features.
-- ---------------------------------------------------------------
SELECT
    fv.distinct_features_used,
    COUNT(*)                                                        AS visits,
    ROUND(AVG(fv.visit_span_seconds) / 60.0, 1)                    AS avg_span_minutes,
    ROUND(AVG(fv.deliberate_action_count), 0)                      AS avg_deliberate_actions,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1)            AS pct_of_engaged_visits
FROM fact_visits fv
WHERE fv.is_engaged = 1
GROUP BY fv.distinct_features_used
ORDER BY fv.distinct_features_used;


-- ---------------------------------------------------------------
-- FINDING 4: An outbound button was deliberately repurposed
-- mid-window, but its internal label was never updated to match.
--
-- The substack-button pointed to substack.com/@camglhf from
-- Mar 28–Apr 3 (7 clicks), then was intentionally re-pointed to
-- kritiquekapital.com starting Apr 14 (32 clicks, 27 sessions).
-- kritiquekapital.com is the current, correct destination — this
-- is not a broken link, it's a legitimate destination change.
--
-- The real finding is a labeling gap: the button's id/label
-- still reads "substack-button" despite pointing somewhere else
-- entirely, which would mislead any label-based click reporting
-- run without cross-referencing the actual destination_url.
-- ---------------------------------------------------------------
SELECT
    lbl.string_value                                                AS button_label,
    dest.string_value                                               AS destination_url,
    COUNT(*)                                                        AS clicks,
    COUNT(DISTINCT lbl.session_id)                                  AS sessions,
    MIN(dest.created_at)                                            AS first_click,
    MAX(dest.created_at)                                            AS last_click
FROM event_properties_long lbl
JOIN event_properties_long dest
    ON dest.event_id = lbl.event_id
   AND dest.data_key = 'destination_url'
WHERE lbl.data_key = 'label'
  AND dest.is_functional_link = 1
GROUP BY lbl.string_value, dest.string_value
ORDER BY lbl.string_value, first_click;


-- ---------------------------------------------------------------
-- FINDING 5: Minesweeper is almost never actually played;
-- web vitals monitoring is not functioning.
--
-- minesweeper_open fired on 372 of 391 visits (95%) because it
-- auto-fires on page load to force leaderboard hydration -- it
-- is not a user gesture. Only 6 visits contain a genuine gameplay
-- event (start/new_game/loss/difficulty_change -- same definition
-- as DQ-2 in 09_data_quality.sql). Without this audit, minesweeper
-- would appear as the site's most-reached feature.
--
-- Separately, all 58 web-vitals events (LCP, FCP, CLS, INP, TTFB)
-- in the export belonged exclusively to the out-of-scope property.
-- ideo.cam has zero performance measurements in this window --
-- a blind spot for load time and rendering health.
-- ---------------------------------------------------------------
SELECT
    'minesweeper_open fires (auto, page load)'  AS signal,
    COUNT(DISTINCT visit_id)                    AS visits
FROM stg_website_events WHERE event_name = 'minesweeper_open'
UNION ALL
SELECT 'minesweeper gameplay (start/new_game/loss/difficulty_change)',
    COUNT(DISTINCT visit_id)
FROM stg_website_events
WHERE event_name IN ('minesweeper_start', 'minesweeper_new_game',
                     'minesweeper_loss', 'minesweeper_difficulty_change')
UNION ALL
SELECT 'web vitals events in scope',
    COUNT(*)
FROM stg_website_events WHERE event_type = 5;



-- ============================================================
-- PART 2: RECOMMENDATIONS
-- ============================================================

-- ---------------------------------------------------------------
-- REC-1: Rename the substack-button label to match its actual,
-- current destination; keep a periodic outbound-link audit.
--
-- Immediate: rename the button id/label from "substack-button" to
-- something reflecting kritiquekapital.com (its correct, current
-- destination — no href fix needed). Going forward, run the query
-- below monthly so any future intentional destination change gets
-- documented at the label level instead of surfacing later as a
-- naming mismatch. The pattern -- label + destination grouped by
-- date range -- surfaces any destination change for any button.
-- ---------------------------------------------------------------
SELECT
    lbl.string_value                                                AS button_label,
    dest.string_value                                               AS destination_url,
    COUNT(*)                                                        AS clicks,
    MIN(DATE(dest.created_at))                                      AS first_seen,
    MAX(DATE(dest.created_at))                                      AS last_seen
FROM event_properties_long lbl
JOIN event_properties_long dest
    ON dest.event_id = lbl.event_id
   AND dest.data_key = 'destination_url'
WHERE lbl.data_key = 'label'
  AND dest.is_functional_link = 1
GROUP BY lbl.string_value, dest.string_value
ORDER BY lbl.string_value, first_seen;


-- ---------------------------------------------------------------
-- REC-2: The passive Instagram bio link converts at 88%.
-- Any intentional promotion would likely drive high-quality
-- traffic at scale.
--
-- Supporting evidence: 86 visits from a silent link, sustained
-- across 10 weeks, at nearly double the Direct engagement rate.
-- Engaged Instagram visitors also click outbound links at a 63%
-- rate -- they arrive to explore the full online presence.
-- A single story or post directing followers to the link would
-- materially increase both volume and engaged-visit count with
-- no change to the site itself.
-- ---------------------------------------------------------------
SELECT
    fv.source_channel,
    COUNT(*)                                                        AS visits,
    SUM(fv.is_engaged)                                              AS engaged,
    ROUND(SUM(fv.is_engaged) * 100.0 / COUNT(*), 1)                AS engagement_rate_pct,
    ROUND(SUM(CASE WHEN fv.is_engaged = 1
        THEN fv.used_outbound_link ELSE 0 END)
        * 100.0 / NULLIF(SUM(fv.is_engaged), 0), 1)                AS pct_engaged_clicking_outbound
FROM fact_visits fv
WHERE fv.source_channel IN ('Instagram', 'Direct')
GROUP BY fv.source_channel;


-- ---------------------------------------------------------------
-- REC-3: Fix instrumentation -- web vitals and minesweeper_open.
--
-- a) Enable web vitals (LCP, FCP, CLS) on ideo.cam. Currently
--    zero performance observations exist for the live site.
--    Without this data, there is no way to detect regressions
--    in load time or rendering after deployments.
--
-- b) Rename or gate minesweeper_open. If the auto-fire is
--    required for leaderboard hydration, fire a distinct
--    technical event (e.g. leaderboard_prefetch) and reserve
--    minesweeper_open for genuine user-initiated opens only.
--    This makes the minesweeper reach metric meaningful and
--    removes the need for the workaround in dim_features.
-- ---------------------------------------------------------------
SELECT
    'web vitals events on ideo.cam'             AS metric,
    COUNT(*)                                    AS value
FROM stg_website_events WHERE event_type = 5
UNION ALL
SELECT 'minesweeper_open fires per visit (ratio)',
    ROUND(
        (SELECT COUNT(*) FROM stg_website_events WHERE event_name='minesweeper_open')
        * 1.0 /
        (SELECT COUNT(DISTINCT visit_id) FROM stg_website_events)
    , 2);


-- ============================================================
-- PART 3: LIMITATIONS
-- ============================================================

-- ---------------------------------------------------------------
-- Documented limitations for the published case study.
-- No SQL output; these are methodology notes.
--
-- L1. Anonymized visitors, by design. This analytics setup was
--     deliberately chosen to be capable but non-intrusive and
--     cookie-free, so there is no identity linking across visits
--     or sessions. The same person returning on different days or
--     devices appears as separate visit_ids. This is a privacy-
--     first design tradeoff, not an instrumentation gap.
--
-- L2. Small sample. 391 visits over 10 weeks. Percentages and
--     rates should be read as directional signals, not
--     statistically precise measurements.
--
-- L3. Partial first day. The window opens March 24 but the
--     earliest event is 9:40 PM ET. March 24 is a partial day.
--
-- L4. visit_span_seconds is a lower bound. MAX(created_at) -
--     MIN(created_at) within a visit understates true time-on-site
--     because page_exit fires too rarely to mark the real end.
--     Single-event visits always show span = 0.
--
-- L5. page_exit is unreliable. Only 4 of 391 visits fired a
--     page_exit event. Exit-page and true bounce analysis are
--     not possible from this data.
--
-- L6. Bot filtering is behavioural, not technical. The Ashburn
--     pattern was identified via fingerprint matching (no real
--     clicks, state-restore only, known data-center city). Other
--     bot traffic that mimics real interaction patterns would
--     not be detectable from event data alone.
--
-- L7. minesweeper_open reclassification is inferred. The decision
--     to treat it as a technical auto-fire is based on co-occurrence
--     patterns and visit-level behavioural analysis, not a code
--     review of the instrumentation implementation.
--
-- L8. Out-of-scope property exclusion. kritiquekapital.com events
--     were excluded based on hostname + disjoint event vocabulary.
--     Five visit_ids appeared under both hostnames (expected from
--     IP+browser+day hashing); the ideo.cam portion of those
--     visits is retained.
--
-- L9. Outbound clicks ≠ conversions. A click on the Substack or
--     Letterboxd button confirms intent but not follow-through.
--     No data exists on what happened after the visitor left.
--
-- L10. session_data excluded. The device/connection property table
--      covers only 7 sessions starting May 31 and is not
--      representative of the full analysis window.
--
-- L11. Geolocation and device fields are partial by design.
--      country/city/browser/os/device are only as complete as
--      the visitor's browser allows -- a direct consequence of
--      the intentionally cookie-free, non-intrusive analytics
--      setup (no fingerprinting to backfill gaps). See DQ-11 in
--      09_data_quality.sql for the completeness breakdown.
--
-- L12. Two "missing value" conventions in the raw export ('\N' vs
--      empty string) initially caused every genuinely Direct visit
--      to be misclassified as 'Other Referral', since the staging
--      cleanup only normalized '\N'. Fixed by normalizing both
--      markers to NULL in 02_stage_clean.sql. See DQ-12 in
--      09_data_quality.sql. Caught during pipeline verification,
--      not during the original profiling pass -- a reminder that
--      "0 nulls" in a completeness check can mean "uses a different
--      missing-value marker," not "fully populated."
--
-- L13. A dropped comma in the dim_features INSERT (03_build_
--      dimensions.sql) previously caused the entire feature
--      mapping to silently fail on rebuild, zeroing out every
--      feature-usage metric downstream. Fixed; the row counts in
--      this file reflect the corrected build. Flagged here because
--      a hand-written multi-row INSERT with trailing inline
--      comments is exactly the shape that hides this kind of typo.
-- ---------------------------------------------------------------

SELECT 'See methodology notes above for L1–L10' AS limitations_documented;
