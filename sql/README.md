# ideo.cam Analytics — SQL Pipeline

An end-to-end SQL analytics pipeline built from raw first-party event exports:
profiling → staging/cleaning → dimensional modeling → fact tables → analysis →
data quality audit → final findings. Built against SQLite; no external
dependencies beyond the three raw CSV exports.

## Data sources

| File | Rows | Description |
|---|---|---|
| `website_event.csv` | 10,140 | One row per tracked event (pageview, interaction, or web vital) |
| `event_data.csv` | 12,931 | Long-format key/value properties attached to individual events |
| `session_data.csv` | 63 | Device/connection properties, 7 sessions only — out of scope for this analysis window (see `01_schema.sql`) |

## Run order

Each file is idempotent (drops/re-creates its own tables) and depends only on
tables built by earlier files. Run in numeric order against a SQLite database
seeded with the three raw CSVs as `raw_website_event`, `raw_event_data`, and
`raw_session_data`.

| File | Produces | Purpose |
|---|---|---|
| `00_data_profile.sql` | — (read-only) | Profiles the raw tables before any cleaning: row counts, window boundaries, completeness checks |
| `01_schema.sql` | `stg_website_events`, `stg_event_properties` | Staging schema: typed, cleaned mirrors of the raw export |
| `02_stage_clean.sql` | (populates staging tables) | Scope filter, window filter, missing-value normalization, `test_event` exclusion |
| `03_build_dimensions.sql` | `dim_event_types`, `dim_features`, `dim_sources`, `visit_source`, `event_properties_long` | Lookup tables, feature classification, traffic-source attribution, cleaned long-format properties |
| `04_build_fact_events.sql` | `fact_events` | One row per event, every dimension joined in |
| `05_build_fact_visits.sql` | `fact_visits` | One row per visit, aggregated metrics and engagement classification |
| `06_acquisition.sql` | — (analysis) | Traffic acquisition: source quality, weekly trends |
| `07_feature_engagement.sql` | — (analysis) | Feature reach, depth, co-occurrence, outbound/photo/theme detail |
| `08_navigation_paths.sql` | — (analysis) | Entry points, transition matrix, journey depth |
| `09_data_quality.sql` | — (audit) | Every known data limitation, instrumentation artifact, and exclusion decision, formally documented and re-runnable |
| `10_final_findings.sql` | — (capstone) | Evidence-backed findings, recommendations, and limitations |

## Key design decisions

- **`visit_id`, not `session_id`, is the unit of analysis.** `session_id` is a
  longer-lived anonymous identifier; a single session can span many visits.
- **`dim_features` replaces the usual `dim_pages`.** The site is a single-page
  app — nearly every event fires on `/` — so intent is expressed through
  feature interactions, not URL navigation.
- **`is_engaged` requires an unambiguous deliberate-action event.**
  State-restorable events (`theme_change`, `minesweeper_open`) fire
  identically for real visitors and bots, so they don't count on their own.
- **Everything is layered (staging → dimensions → facts → analysis)** so a
  bug in one layer is traceable and fixable without touching the layers
  around it. See `TECHNICAL_WRITEUP.md` for two cases where this is exactly
  what made a bug findable.

## Further reading

`TECHNICAL_WRITEUP.md` documents every bug found during QA (with root cause
and fix), every data-quality caveat baked into the model, and known
limitations of the dataset itself.
