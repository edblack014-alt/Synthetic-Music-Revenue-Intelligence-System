# From project root after generating the data: source('tests/smoke_tests.R')
library(dplyr)
library(readr)
source("R/analytics.R", local = TRUE)

required <- c("streaming_statements", "track_catalogue", "distribution_agreements",
              "finance_ledger")
d <- setNames(lapply(required, function(nm)
  readr::read_csv(file.path("data/raw", paste0(nm, ".csv")),
                  show_col_types = FALSE)), required)
d$streaming_statements$month <- as.Date(d$streaming_statements$month)
d$finance_ledger$month <- as.Date(d$finance_ledger$month)

s <- d$streaming_statements |>
  left_join(d$track_catalogue, by = "track_id") |>
  left_join(d$distribution_agreements, by = c("label_id", "platform", "market")) |>
  mutate(expected_label_revenue_gbp = gross_revenue_gbp * label_share_pct)
stopifnot(nrow(s) == nrow(d$streaming_statements),
          !anyNA(s$label_id), !anyNA(s$label_share_pct),
          !anyDuplicated(s$record_id))

monthly <- s |>
  group_by(month, label_id, label_name, market) |>
  summarise(expected_label_revenue_gbp = round(sum(expected_label_revenue_gbp), 2),
            .groups = "drop") |>
  full_join(d$finance_ledger, by = c("month", "label_id", "market"))
recon <- classify_reconciliation(monthly)
stopifnot(sum(recon$reconciliation_status == "Mismatch") == 2,
          abs(sum(abs(recon$exception_variance_gbp), na.rm = TRUE) - 215.40) < 0.011,
          abs(sum(recon$exception_variance_gbp, na.rm = TRUE) - 35.40) < 0.011)

bridge <- revenue_bridge(s)
stopifnot(!is.null(bridge),
          abs(bridge$start + bridge$volume + bridge$mix + bridge$rate - bridge$end) < 0.0001)

if (file.exists("data/raw/deal_terms.csv")) {
  terms <- read_csv("data/raw/deal_terms.csv", show_col_types = FALSE)
  recharge <- calculate_recharges(s, terms)
  stopifnot(all(recharge$guarantee_topup_gbp >= 0),
            all(recharge$illustrative_recharge_gbp + 0.001 >=
                recharge$expected_label_revenue_gbp))
}

cat("Smoke tests passed: joins, 2 exceptions, monetary totals, revenue bridge, deal floors.\n")
