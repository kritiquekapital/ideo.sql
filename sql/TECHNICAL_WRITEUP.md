# Technical write-up: bugs, fixes, and data-quality caveats

This documents everything found during building and QA-ing the ideo.cam
analytics pipeline that isn't obvious from reading the SQL alone — two real
bugs that were caught by re-running the pipeline end-to-end rather than just
reading the code, and a set of data-quality findings that shape how the
results should be interpreted. Query references point to `09_data_quality.sql`
and `10_final_findings.sql`, where each of these is reproducible.

## Bugs found and fixed

### 1. A missing comma silently zeroed out every feature-usage metric

**Where:** `03_build_dimensions.sql`, the `dim_features` INSERT.

**What happened:** one row ended with an inline trailing comment, and the
comma meant to separate it from the next row got typed *inside* the comment
instead of after it:

```sql
('minesweeper_open', 'Site Lifecycle') -- not a user gesture,
('minesweeper_start', 'Minesweeper'),
```

SQLite treats `--` as a line comment, so the intended separator never
executed as SQL. The whole multi-row `INSERT` failed with a syntax error —
silently, since nothing downstream checks that `dim_features` actually has
rows in it.

**Impact:** `dim_features` built with 0 rows. Every `LEFT JOIN dim_features`
downstream (`fact_events`) returned NULL for `feature_category` on all 9,116
interaction events. That NULL propagated into `fact_visits`, zeroing out
`used_photo_gallery`, `used_kiss_button`, `used_minesweeper`,
`used_outbound_link` — every feature flag the site has. Modules 07 and 08,
and most of module 10, depend entirely on `feature_category`, so a
from-scratch rebuild at that point would have produced empty feature-reach
tables with no error to explain why.

**Fix:** moved the comma outside the comment. Verified by rebuilding from the
raw CSVs and confirming the documented numbers reproduce exactly (Kiss
Button 145 visits / 70.7% of engaged visits, Photo Gallery 92 / 44.9%, etc.).

**Takeaway:** a hand-written multi-row `INSERT` with trailing inline comments
is exactly the shape that hides this kind of typo — the file *looks* correct
on read-through. A sanity check that asserts `dim_features` row count > 0
(or asserts zero unmapped `event_name`s, which the file already has) would
have caught this immediately if run right after the `INSERT` rather than
trusted implicitly.

### 2. Two "missing value" conventions in one export swapped Direct and Other Referral

**Where:** `02_stage_clean.sql` (root cause) / `03_build_dimensions.sql`
(where it surfaced).

**What happened:** the raw export encodes "missing" two different ways
depending on the column. Web-vitals fields (`lcp`, `inp`, `cls`, `fcp`,
`ttfb`) use the literal string `'\N'`. Every URL/UTM/referrer/`fbclid`/
`hostname`/`region` field uses a plain empty string `''` instead. The
original staging script only normalized `'\N'` to `NULL`, so `utm_source`
and `referrer_domain` stayed as `''` — not `NULL` — for every visit with no
tag and no referrer.

The `visit_source` classification in `03_build_dimensions.sql` checked
`utm_source IS NULL AND referrer_domain IS NULL` for `'Direct'`, and
`referrer_domain IS NOT NULL` for `'Other Referral'`. Since `''` is not
`NULL`, every genuinely direct visit failed the first check and matched the
second instead.

**Impact:** 278 of 391 visits (71% of all traffic) that should have been
`'Direct'` were classified `'Other Referral'`. The `'Direct'` bucket showed
**zero visits** in every table, chart, and finding. `'Other Referral'`
(nominally 280 visits) was really presenting Direct-channel traffic under
the wrong name — the only genuinely uncategorized referral traffic was 2
Facebook visits.

**How it surfaced:** the signal was visible from the very first profiling
pass — `00_data_profile.sql` query #4 reported `utm_source_null = 0` and
`referrer_domain_null = 0` across the whole window, which got read as "these
fields are just unused for a low-traffic personal site" rather than "check
for a second missing-value marker." It was caught only later, during
pipeline verification, when the weekly acquisition trend
(`06_acquisition.sql`) showed a `direct_visits` column that was literally
zero in every single week — a result implausible enough to investigate.

**Fix:** chained a second `NULLIF(..., '')` onto every affected column in
`02_stage_clean.sql` (`hostname`, `region`, `url_query`, `utm_source`,
`utm_medium`, `utm_content`, `referrer_path`, `referrer_domain`, `fbclid`).
No changes were needed to the classification logic itself — once the
staging layer produces true `NULL`s, the existing `IS NULL` checks work
correctly.

**Takeaway:** "zero nulls" in a completeness check means "this marker never
appears as NULL," not "this field is fully populated." The layered
architecture (staging → dimensions → facts) is what made this fixable in one
place — the classification CASE expression in `03` needed no changes at all
once `02` was corrected.

## Data-quality findings baked into the model

These aren't bugs — they're real properties of the data and the site that
shape what the numbers mean. All are documented and reproducible in
`09_data_quality.sql`.

- **`minesweeper_open` is a technical auto-fire, not gameplay.** It fires on
  372 of 391 visits (95%) — including every bot visit — because it forces
  the leaderboard to hydrate in the background on page load, not because
  anyone opened the game. Reclassified from `Minesweeper` to `Site Lifecycle`
  in `dim_features`. Genuine gameplay (`minesweeper_start` / `new_game` /
  `loss` / `difficulty_change`) appears in only 6 visits.
- **The "laptop" device tag is a de facto bot signal.** It's the single
  largest device category by raw count (154 of 391 visits), but 77% of
  laptop-tagged visits trace back to the same crawler-fingerprint cities as
  the site's confirmed bot/international traffic. Desktop and mobile visits
  engage at 70–80%; laptop-tagged visits engage at 15%. Any analysis that
  treats `device` as a straightforward user-agent category will overweight
  bot traffic under "laptop."
- **`substack-button` (and `duolingo`) are stale labels, not broken links.**
  `substack-button` legitimately pointed to Substack from Mar 28–Apr 3 (7
  clicks), then was intentionally re-pointed to kritiquekapital.com starting
  Apr 14 (32 clicks, 27 sessions) — kritiquekapital.com is the current,
  correct destination. `duolingo` shows the identical pattern at smaller
  scale (2 clicks to one link, then 9 to a different one). In both cases the
  button's internal label/id was never renamed to match its new purpose, so
  label-based reporting run without cross-referencing `destination_url`
  would misread these as broken links. `DQ-3c` in `09_data_quality.sql`
  auto-detects any label with more than one destination, so this doesn't
  need to be caught by eye next time.
- **A photo was logged under two filenames.** `cordes en boyaux.png` (space)
  ran Mar 28–Apr 2, then `cordes-en-boyaux.png` (hyphen) ran Apr 3 onward —
  a clean, non-overlapping date cutover confirms one photo renamed
  mid-window, not two photos. Normalized to the hyphenated form in
  `event_properties_long` so the top-photos ranking isn't artificially split
  (142 combined clicks, moving it well up the ranking).
- **The Ashburn cluster is a confirmed bot fingerprint.** 19 visits from
  Ashburn, VA (a major data-center hub) share an identical signature:
  `minesweeper_open` + `theme_change` (both auto-fire on state restore) plus
  exactly one pageview, zero deliberate actions. Correctly classified as
  not-engaged; kept in the dataset rather than dropped, since bot/bounce
  traffic is a real part of total volume.
- **`page_exit` is effectively non-functional.** Only 4 of 391 visits fired
  it. `visit_span_seconds` (`MAX(created_at) - MIN(created_at)`) is a lower
  bound on time-on-site, not a true measurement — single-event visits always
  show a span of 0.
- **Geolocation and device fields are partial by design.** `country` /
  `city` / `browser` / `os` / `device` are only as complete as the visitor's
  browser allows — a direct consequence of the site's intentionally
  cookie-free, non-intrusive analytics approach. No fingerprinting is used
  to backfill gaps, so these fields should be treated as best-effort
  context, not guaranteed dimensions.
- **`session_data` (device/connection properties, including full user-agent
  strings) is out of scope.** It covers only 7 sessions, all starting
  May 31 — right at the edge of or after the analysis window — and isn't
  representative. It does contain a `ua` property with full user-agent
  strings (device-model-level detail, e.g. `iPhone17,3`), but only one of
  the 7 sessions is even a phone, which is far too small a sample to
  support any device-model-level claim for the reporting period.

## Known limitations

- **391 visits over 10 weeks** — percentages should be read as directional
  signals, not statistically precise measurements.
- **No cross-visit identity linking**, by design — the analytics setup is
  intentionally cookie-free and non-intrusive. A returning visitor on a
  different day or device appears as an unrelated new visit.
- **Bot filtering is behavioral, not technical.** Fingerprint-matching
  (no real clicks, state-restore only, known data-center city, the
  laptop-tag pattern) catches what it catches; bot traffic that mimics real
  interaction patterns wouldn't be detectable from event data alone.
- **Outbound clicks are intent signals, not conversions.** No data exists on
  what happened after a visitor left the site.

## Possible next steps

- **Persist the bot heuristic as a column.** The "likely bot" signal
  currently gets re-derived ad hoc in different queries (Ashburn fingerprint
  in `09`, the laptop-tag finding, international-city assumptions in the
  city breakdown). Formalizing it into a single `is_likely_bot` flag on
  `fact_visits` — computed once from device tag + city + zero-real-action
  fingerprint — would make every downstream query consistent and auditable
  instead of re-implementing the same judgment call differently each time.
  This is a real modeling decision (where exactly to draw the line) rather
  than a mechanical fix, so it's worth deciding deliberately rather than
  folding in silently.
- **Indexes on `visit_source.source_channel` and `event_properties_long`**
  (`event_id`, and `event_name, data_key`) have been added — these tables
  are joined and filtered on constantly in modules 06–10 and previously had
  no indexes beyond their primary keys.
- **Consider views for the repeated CTE patterns** (`deliberate_sequence`,
  `first_action`) that currently appear near-identically in `07`, `08`, and
  `10`. Kept as standalone duplicated blocks intentionally, so each analysis
  module can be read and run independently — but if this pipeline runs on a
  recurring schedule rather than as a one-off, pulling them into named views
  would remove the risk of the three copies drifting out of sync.
