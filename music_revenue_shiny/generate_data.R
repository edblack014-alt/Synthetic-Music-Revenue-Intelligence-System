# Fully synthetic; NOT actual music royalties, FX rates, artists or deal terms.

library(tidyverse)
set.seed(2026)
dir.create("data/raw", recursive = TRUE, showWarnings = FALSE)

labels <- tibble(label_id = c("L01", "L02", "L03"),
                 label_name = c("Northline Records", "Juniper Sound", "Atlas Audio"))
artists <- tibble(
  artist_id = sprintf("A%02d", 1:10),
  artist_name = c("Neon Transit", "Amber Lines", "Low Tide", "Glass Avenue",
                  "Northern Echo", "Silver Pines", "Night Orchard", "Sundown Club",
                  "Afterimage", "The Satellites"),
  label_id = rep(labels$label_id, length.out = 10)
)
track_catalogue <- tibble(
  track_id = sprintf("T%03d", 1:30),
  track_name = sprintf("Recording %02d", 1:30),
  artist_id = rep(artists$artist_id, each = 3),
  popularity_weight = round(runif(30, 0.5, 3), 2)
) |>
  left_join(artists, by = "artist_id") |>
  left_join(labels, by = "label_id") |>
  select(track_id, track_name, artist_id, artist_name, label_id, label_name,
         popularity_weight)

platforms <- tibble(
  platform = c("Spotify", "Apple Music", "YouTube Music"),
  platform_stream_factor = c(1.5, 0.75, 1.1),
  illustrative_gbp_per_1000 = c(2.9, 5.1, 1.2)
)
markets <- tibble(
  market = c("GB", "US", "DE", "JP", "KR"),
  local_currency = c("GBP", "USD", "EUR", "JPY", "KRW"),
  market_stream_factor = c(1, 2.5, 0.85, 1.1, 1.3),
  market_revenue_factor = c(1, 1.1, 0.9, 1.05, 0.92),
  base_fx_local_per_gbp = c(1, 1.25, 1.17, 190, 1700)
)
months <- seq.Date(as.Date("2026-01-01"), by = "month", length.out = 6)

# Fictional local currency units per 1 GBP; rates intentionally change by month.
fx_rates <- tidyr::expand_grid(month = months, market = markets$market) |>
  left_join(markets |> select(market, local_currency, base_fx_local_per_gbp),
            by = "market") |>
  mutate(month_index = as.integer(format(month, "%m")) - 1L,
         fx_local_per_gbp = round(
           if_else(market == "GB", 1,
                   base_fx_local_per_gbp * (1 + 0.013 * sin(month_index +
                      match(market, markets$market)))), 6)) |>
  select(month, market, local_currency, fx_local_per_gbp)

streaming_statements <- tidyr::expand_grid(
  month = months,
  platform = platforms$platform,
  market = markets$market,
  track_id = track_catalogue$track_id
) |>
  left_join(track_catalogue |> select(track_id, popularity_weight), by = "track_id") |>
  left_join(platforms, by = "platform") |>
  left_join(markets |> select(market, market_stream_factor, market_revenue_factor),
            by = "market") |>
  left_join(fx_rates, by = c("month", "market")) |>
  mutate(
    month_index = as.integer(format(month, "%m")) - 1L,
    streams = as.integer(round(
      7000 * popularity_weight * platform_stream_factor * market_stream_factor *
        (1 + 0.025 * month_index) * exp(rnorm(n(), mean = 0, sd = 0.22))
    )),
    # Local currency is the synthetic reported source value; convert it to GBP.
    gross_revenue_local = round(
      streams / 1000 * illustrative_gbp_per_1000 *
        market_revenue_factor * fx_local_per_gbp, 2),
    gross_revenue_gbp = round(gross_revenue_local / fx_local_per_gbp, 2),
    source_statement_id = paste(platform, market, format(month, "%Y%m"), sep = "_"),
    record_id = sprintf("R%06d", row_number())
  ) |>
  select(record_id, source_statement_id, month, platform, market,
         track_id, streams, local_currency, fx_local_per_gbp,
         gross_revenue_local, gross_revenue_gbp)

distribution_agreements <- tidyr::expand_grid(
  label_id = labels$label_id,
  platform = platforms$platform,
  market = markets$market
) |>
  mutate(agreement_id = sprintf("D%03d", row_number()),
         label_share_pct = sample(seq(65L, 80L), n(), replace = TRUE) / 100) |>
  select(agreement_id, label_id, platform, market, label_share_pct)

# Simplified fictional monthly minimum guarantee (GBP) for each deal;
# applied once per month/label/platform/market, NOT per streaming record.
deal_terms <- distribution_agreements |>
  transmute(deal_id = paste0("G", agreement_id), label_id, platform, market,
            minimum_guarantee_gbp = sample(c(0, 80, 160, 300), n(), replace = TRUE),
            effective_from = as.Date("2026-01-01"),
            effective_to = as.Date("2026-06-30"))

finance_ledger <- streaming_statements |>
  left_join(track_catalogue |> select(track_id, label_id), by = "track_id") |>
  left_join(distribution_agreements, by = c("label_id", "platform", "market")) |>
  mutate(expected_label_revenue_gbp = gross_revenue_gbp * label_share_pct) |>
  group_by(month, label_id, market) |>
  summarise(recorded_label_revenue_gbp = round(sum(expected_label_revenue_gbp), 2),
            .groups = "drop") |>
  arrange(month, label_id, market) |>
  mutate(
    # Same two named exceptions as the original demo (not row-number-dependent).
    recorded_label_revenue_gbp = round(case_when(
      month == as.Date("2026-01-01") & label_id == "L02" & market == "DE" ~
        recorded_label_revenue_gbp + 125.40,
      month == as.Date("2026-02-01") & label_id == "L02" & market == "GB" ~
        recorded_label_revenue_gbp - 90,
      TRUE ~ recorded_label_revenue_gbp
    ), 2),
    ledger_entry_id = sprintf("F%04d", row_number())
  ) |>
  select(ledger_entry_id, month, label_id, market, recorded_label_revenue_gbp)

stopifnot(nrow(track_catalogue) == 30L,
          nrow(streaming_statements) == 2700L,
          nrow(distribution_agreements) == 45L,
          nrow(deal_terms) == 45L,
          nrow(finance_ledger) == 90L,
          anyDuplicated(streaming_statements$record_id) == 0L,
          !anyNA(streaming_statements),
          all(streaming_statements$gross_revenue_gbp >= 0))

for (nm in c("track_catalogue", "streaming_statements",
             "distribution_agreements", "finance_ledger", "fx_rates", "deal_terms")) {
  readr::write_csv(get(nm), file.path("data/raw", paste0(nm, ".csv")))
}
cat("Extended synthetic data created: 2700 streaming records, 90 ledger groups, 5 markets (including KR).\n")
