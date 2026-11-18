# Music Revenue Intelligence — R Shiny dashboard v2

An interactive, **fully fictional** music revenue-operations portfolio project. The revised dashboard reads either the existing BigQuery views or locally generated CSVs, and includes a repeatable R-to-BigQuery data pipeline.

## What's new

**Commercial Performance**
- Full market names, labelled and sorted revenue-per-1,000-streams bars.
- KPI values with latest-month vs preceding-month percentages.
- Sequential revenue bridge: **streaming volume**, **market mix**, **within-market revenue per stream** (exactly additive).
- Plain-language key insights generated from the active filter selection.
- Rolling anomalies for gross revenue and monetisation. Requires **three preceding monthly observations**, nonzero standard deviation, and a deviation beyond ±2 standard deviations. Anomalies are *flags*, not proven errors.
- Artist table includes revenue per 1,000 streams and revenue share.

**Revenue Reconciliation**
- Eliminates the misleading overlapping Expected/Recorded line chart; shows **signed exception variance** by month and market.
- Plotly monthly ticks are explicitly `dtick = "M1"`, with `%b %y` date labels.
- The dashboard uses an **absolute £0.50 matching tolerance**: rows with a missing counterpart or an absolute discrepancy greater than £0.50 are exceptions. Both headline variance cards use only exception rows. Any small rounding residue within tolerance does not inflate these cards.
- An issue register provides an *unconfirmed* suspected cause, owner, follow-up status (Open / Queried / Resolved), and notes. Edits are **saved locally** to `data/processed/issue_register.csv` and never modify the ledger or BigQuery.
- A QA panel shows core source row counts, null counts, duplicate keys, unmatched catalogue/contract records, and pipeline ingestion time (when metadata is available).

**Deal Operations**
- Illustrative calculation of expected label allocations, a simulated **monthly minimum guarantee**, the resulting guarantee top-up, and an amount to recharge.
- A separate **proposed rebill** worksheet shows reversing adjustments for exceptions, **subject to evidence and approval**. No actual accounting entries are posted.
- Optional South Korea market and fictional monthly local-currency conversion assumptions.

**Methodology** describes all synthetic assumptions, controls and limitations.

## Launch using your existing BigQuery data

1. Extract the ZIP and open the `music_revenue_shiny` folder as the RStudio working directory.
2. Use **R 4.1+** and install the packages once:

```r
install.packages(c("shiny", "bslib", "dplyr", "plotly", "DT", "readr",
                   "DBI", "bigrquery", "scales", "tidyverse"))
```

3. Authenticate if not already authorised:

```r
bigrquery::bq_auth()
```

4. Run:

```r
shiny::runApp(".", launch.browser = TRUE)
```

The app defaults to Google BigQuery and uses the existing project/dataset:

- Project: `music-revenue-intelligence`
- Dataset: `streaming_revenue_analytics`
- Views: `v_streaming_enriched`, `v_revenue_reconciliation`

**You do not need to rerun your generator or BigQuery pipeline merely to view the redesigned charts.** Your current four-market dataset will continue to load, including the two known reconciliation exceptions. The Korea/FX features will show a message until upgraded data is loaded.

To use a different project, in RStudio set `MUSIC_BQ_PROJECT`, `MUSIC_BQ_DATASET` and optionally `MUSIC_BQ_BILLING` before running the app.

## Optional upgrade: South Korea, FX and guarantee simulation

This intentionally changes the generated source data and therefore the dashboard's totals. Preserve a copy of your current data before upgrading if you want to compare results.

```r
# From the folder containing app.R:
source("generate_data_extended.R")  # writes 6 synthetic CSVs to data/raw
source("run_pipeline.R")             # uploads source tables, refreshes views, checks results
shiny::runApp(".", launch.browser = TRUE)
```

**New synthetic scenario:** 30 tracks × 3 platforms × 5 markets × 6 months = **2,700 streaming rows**; 3 labels × 5 markets × 6 months = **90 monthly reconciliation groups**. There are still two intentionally introduced exceptions, now for `L02/DE/Jan 2026` (+£125.40) and `L02/GB/Feb 2026` (−£90.00). Minor penny-level conversion/rounding residuals are allowed within the declared £0.50 tolerance.

The extended generator adds:
- `KR` / South Korea, **not** real BTS or Stray Kids data.
- Fictional local-currency rates (`fx_local_per_gbp`, meaning local units per £1) and `gross_revenue_local`, converted to `gross_revenue_gbp` at the **synthetic** monthly rate.
- `deal_terms.csv` with fictional monthly guarantees, separate from the label-share agreement table.

The included updated SQL view definition and pipeline accept both the original four-market CSVs and the extended dataset. For legacy inputs, the pipeline adds `GBP`-only passthrough columns (rate 1.0) so the new SQL schema works without claiming any real conversion occurred. If switching back to the original generator after running the extended one, remove the stale `data/raw/deal_terms.csv` and `data/raw/fx_rates.csv` files first.

For a fully **offline** demonstration, generate local CSVs, launch the app, and choose **Local CSVs** in the sidebar. The app will join and reconcile them with `dplyr` without BigQuery.

## Running tests

The included `tests/smoke_tests.R` checks the mathematical revenue bridge identity, matching tolerance and local data integrity. From the root folder, run:

```r
source("generate_data_extended.R")
source("tests/smoke_tests.R")
```

No external credentials are needed for this check.

## Folder structure

```text
music_revenue_shiny/
├── app.R
├── R/analytics.R
├── generate_data.R             # original four-market demo, unchanged
├── generate_data_extended.R    # optional five-market FX & deal-term demo
├── run_pipeline.R              # refreshed BigQuery uploader & SQL checks
├── sql/
│   ├── 01_streaming_enriched.sql
│   └── 02_revenue_reconciliation.sql
├── tests/smoke_tests.R
├── data/raw/                  # generated by R, not bundled
└── data/processed/            # generated pipeline checks & editable issue register
```

## Limitations and disclosures

- Every record, artist, label, payment assumption, distribution agreement, FX rate and minimum guarantee is fictitious. No real-platform royalties are represented.
- The finance ledger is model-derived and adjusted deliberately, **not independent accounting evidence**.
- The issue register stores **suspected** causes, not validated findings. A "Resolved" issue may still remain in the source reconciliation view until a correction is documented and posted separately.
- Ingestion is **repeatable but not scheduled**. Clicking Refresh retrieves data but does not run the ingestion script.
- `run_pipeline.R` **overwrites synthetic raw BigQuery tables** for reproducibility. Never use this overwrite pattern on real financial data. It writes a single latest-run metadata record for the QA card.
- Deal terms in the demo apply once per **month × label × platform × market**, not once per track.
- This project was packaged without an R runtime in the authoring environment; run the smoke tests and launch locally to verify package versions and interactive behaviour.

## Portfolio talking point

"Developed an R-orchestrated, SQL-backed commercial revenue intelligence dashboard, with reconciled label allocations, explicit matching tolerances, issue-tracking workflows, and an exact decomposition of revenue change into volume, market-mix and monetisation effects." Clearly disclose the simulated data.
