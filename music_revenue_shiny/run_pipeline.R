# Music Revenue Intelligence | repeatable R -> BigQuery reporting pipeline.
# For synthetic portfolio data only: source tables are overwritten on each run.
library(bigrquery)
library(DBI)
library(readr)
library(dplyr)

PROJECT_ID <- Sys.getenv("MUSIC_BQ_PROJECT", "music-revenue-intelligence")
DATASET_ID <- Sys.getenv("MUSIC_BQ_DATASET", "streaming_revenue_analytics")
BILLING_ID <- Sys.getenv("MUSIC_BQ_BILLING", PROJECT_ID)

run_pipeline <- function() {
  required <- c("track_catalogue", "streaming_statements",
                "distribution_agreements", "finance_ledger")
  optional <- c("deal_terms", "fx_rates")
  paths <- setNames(file.path("data", "raw", paste0(required, ".csv")), required)
  if (!all(file.exists(paths))) {
    stop("Missing required data/raw CSVs: ",
         paste(paths[!file.exists(paths)], collapse = ", "),
         ". Run source('generate_data.R') or source('generate_data_extended.R').")
  }
  optional_paths <- setNames(file.path("data", "raw", paste0(optional, ".csv")), optional)
  paths <- c(paths, optional_paths[file.exists(optional_paths)])

  message("1/4 Reading CSVs and validating source keys...")
  data <- lapply(paths, function(path) {
    x <- readr::read_csv(path, show_col_types = FALSE)
    for (field in intersect(c("month", "effective_from", "effective_to"), names(x))) {
      x[[field]] <- as.Date(x[[field]])
    }
    x
  })
  assert_unique <- function(x, fields, label) {
    if (anyDuplicated(x[fields])) stop("Duplicate keys in ", label)
  }
  assert_unique(data$track_catalogue, "track_id", "track_catalogue")
  assert_unique(data$streaming_statements, "record_id", "streaming_statements")
  assert_unique(data$distribution_agreements, c("label_id", "platform", "market"),
                "distribution_agreements")
  assert_unique(data$finance_ledger, c("month", "label_id", "market"), "finance_ledger")
  stopifnot(!anyNA(data$streaming_statements), !anyNA(data$finance_ledger),
            all(data$streaming_statements$gross_revenue_gbp >= 0),
            all(data$streaming_statements$streams >= 0))
  stopifnot(nrow(data$streaming_statements) ==
              length(unique(data$streaming_statements$month)) *
              length(unique(data$streaming_statements$platform)) *
              length(unique(data$streaming_statements$market)) *
              nrow(data$track_catalogue))
  stopifnot(nrow(data$finance_ledger) ==
              length(unique(data$streaming_statements$month)) *
              length(unique(data$track_catalogue$label_id)) *
              length(unique(data$streaming_statements$market)))

  # This is a neutral GBP passthrough, NOT a claimed currency conversion.
  s <- data$streaming_statements
  if (!"local_currency" %in% names(s)) s$local_currency <- "GBP"
  if (!"fx_local_per_gbp" %in% names(s)) s$fx_local_per_gbp <- 1
  if (!"gross_revenue_local" %in% names(s)) s$gross_revenue_local <- s$gross_revenue_gbp
  data$streaming_statements <- s
  if (is.null(data$deal_terms)) {
    data$deal_terms <- data$distribution_agreements |>
      dplyr::transmute(deal_id = paste0("LEGACY_", agreement_id),
                       label_id, platform, market,
                       minimum_guarantee_gbp = 0,
                       effective_from = min(s$month),
                       effective_to = max(s$month))
  }
  assert_unique(data$deal_terms, c("label_id", "platform", "market"), "deal_terms")
  if (anyNA(data$deal_terms$minimum_guarantee_gbp)) stop("Missing guarantee in deal_terms")

  message("2/4 Connecting to BigQuery...")
  bigrquery::bq_auth()
  con <- DBI::dbConnect(bigrquery::bigquery(), project = PROJECT_ID,
                        dataset = DATASET_ID, billing = BILLING_ID)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  message("3/4 Uploading source data and refreshing SQL views...")
  for (nm in names(data)) {
    DBI::dbWriteTable(con, nm, data[[nm]], overwrite = TRUE)
    message("Uploaded ", nm, ": ", nrow(data[[nm]]), " rows")
  }
  for (script in c("sql/01_streaming_enriched.sql",
                   "sql/02_revenue_reconciliation.sql")) {
    if (!file.exists(script)) stop("SQL file is missing: ", script)
    DBI::dbExecute(con, paste(readLines(script, warn = FALSE), collapse = "\n"))
    message("View updated: ", script)
  }

  message("4/4 Validating reconciliations and writing run metadata...")
  qa <- DBI::dbGetQuery(con, "
    SELECT COUNT(*) AS n_rows, COUNT(DISTINCT record_id) AS unique_records,
      COUNTIF(label_id IS NULL) AS missing_tracks,
      COUNTIF(label_share_pct IS NULL) AS missing_agreements
    FROM v_streaming_enriched")
  stopifnot(qa$n_rows == nrow(s), qa$unique_records == nrow(s),
            qa$missing_tracks == 0, qa$missing_agreements == 0)
  recon <- DBI::dbGetQuery(con, "SELECT * FROM v_revenue_reconciliation")
  variance <- round(as.numeric(recon$recorded_label_revenue_gbp) -
                      as.numeric(recon$expected_label_revenue_gbp), 2)
  exceptions <- recon[is.na(variance) | abs(variance) > 0.50, ]
  if (nrow(exceptions) != 2L) {
    warning("The seeded demonstration normally has 2 exceptions; found ", nrow(exceptions))
  }
  dir.create("data/processed", recursive = TRUE, showWarnings = FALSE)
  readr::write_csv(exceptions, "data/processed/reconciliation_exceptions.csv")
  meta <- data.frame(
    run_utc = as.POSIXct(Sys.time(), tz = "UTC"),
    streaming_rows = nrow(s),
    reconciliation_groups = nrow(recon),
    exceptions = nrow(exceptions),
    source_nulls = sum(vapply(data, function(x) sum(is.na(x)), numeric(1))),
    duplicate_keys = 0L
  )
  DBI::dbWriteTable(con, "pipeline_runs", meta, overwrite = TRUE)
  readr::write_csv(meta, "data/processed/pipeline_run_metadata.csv")
  message("Pipeline complete: ", nrow(s), " streaming records, ",
          nrow(recon), " reconciled groups, ", nrow(exceptions), " exceptions.")
  invisible(list(quality = qa, exceptions = exceptions, run = meta))
}

# Source the file to run, as in the original project workflow.
run_pipeline()
