# Pure analysis helpers. All figures and deal terms are synthetic.
TOLERANCE_GBP <- 0.50
MARKET_NAMES <- c(GB = "United Kingdom", US = "United States", DE = "Germany",
                  JP = "Japan", KR = "South Korea")

money_text <- function(x, digits = 0) {
  if (length(x) != 1L || is.na(x) || !is.finite(x)) return("—")
  if (x < 0) paste0("−£", formatC(abs(x), format = "f", digits = digits, big.mark = ","))
  else paste0("£", formatC(x, format = "f", digits = digits, big.mark = ","))
}
num_text <- function(x) {
  if (length(x) != 1L || is.na(x)) return("—")
  formatC(x, format = "f", digits = 0, big.mark = ",")
}
market_name <- function(x) {
  result <- unname(MARKET_NAMES[as.character(x)])
  result[is.na(result)] <- as.character(x)[is.na(result)]
  result
}

# Missing counterpart is always an exception. A small monetary residual is not.
classify_reconciliation <- function(d, tolerance = TOLERANCE_GBP) {
  d$variance_gbp <- round(as.numeric(d$recorded_label_revenue_gbp) -
                            as.numeric(d$expected_label_revenue_gbp), 2)
  d$reconciliation_status <- dplyr::case_when(
    is.na(d$expected_label_revenue_gbp) ~ "Missing expected allocation",
    is.na(d$recorded_label_revenue_gbp) ~ "Missing recorded revenue",
    abs(d$variance_gbp) > tolerance ~ "Mismatch",
    TRUE ~ "Matched"
  )
  d$exception_variance_gbp <- dplyr::if_else(
    d$reconciliation_status == "Matched", 0, d$variance_gbp,
    missing = NA_real_
  )
  d$direction <- dplyr::case_when(
    d$reconciliation_status == "Matched" ~ "Within tolerance",
    is.na(d$variance_gbp) ~ "Missing counterpart",
    d$variance_gbp > 0 ~ "Over-recorded",
    d$variance_gbp < 0 ~ "Under-recorded",
    TRUE ~ "No variance"
  )
  d$variance_pct <- dplyr::if_else(
    !is.na(d$expected_label_revenue_gbp) & d$expected_label_revenue_gbp != 0,
    100 * d$variance_gbp / d$expected_label_revenue_gbp, NA_real_
  )
  d$exception_key <- paste(format(as.Date(d$month), "%Y-%m-%d"), d$label_id,
                           d$market, sep = "|")
  d
}

# Exact sequential decomposition of R = S * sum(market_share * market_rate).
# Volume is at prior mix and rates; mix is at current volume/prior rates;
# within-market monetisation is the residual at current market weights.
revenue_bridge <- function(streaming) {
  by_month <- streaming |>
    dplyr::group_by(month, market) |>
    dplyr::summarise(revenue = sum(gross_revenue_gbp, na.rm = TRUE),
                     streams = sum(streams, na.rm = TRUE), .groups = "drop")
  months <- sort(unique(as.Date(by_month$month)))
  if (length(months) < 2) return(NULL)
  m0 <- months[length(months) - 1L]
  m1 <- months[length(months)]
  a <- by_month[by_month$month == m0, c("market", "revenue", "streams")]
  b <- by_month[by_month$month == m1, c("market", "revenue", "streams")]
  names(a)[2:3] <- c("revenue0", "streams0")
  names(b)[2:3] <- c("revenue1", "streams1")
  d <- dplyr::full_join(a, b, by = "market")
  d[is.na(d)] <- 0
  S0 <- sum(d$streams0)
  S1 <- sum(d$streams1)
  if (S0 <= 0 || S1 <= 0) return(NULL)
  w0 <- d$streams0 / S0
  w1 <- d$streams1 / S1
  r0 <- ifelse(d$streams0 > 0, 1000 * d$revenue0 / d$streams0, 0)
  r1 <- ifelse(d$streams1 > 0, 1000 * d$revenue1 / d$streams1, 0)
  R0 <- sum(d$revenue0)
  R1 <- sum(d$revenue1)
  volume <- (S1 - S0) * sum(w0 * r0) / 1000
  mix <- S1 * sum((w1 - w0) * r0) / 1000
  within_rate <- S1 * sum(w1 * (r1 - r0)) / 1000
  # Preserve exact accounting identity, subject to floating point precision.
  stopifnot(isTRUE(all.equal(R0 + volume + mix + within_rate,
                             R1, tolerance = 0.0001)))
  list(month0 = m0, month1 = m1, start = R0, end = R1,
       volume = volume, mix = mix, rate = within_rate)
}

# Uses three PREVIOUS months only (no information leakage) for each market.
# A valid flag requires nonzero prior standard deviation and 3 observations.
rolling_anomalies <- function(streaming, lookback = 3L, threshold = 2) {
  d <- streaming |>
    dplyr::group_by(market, month) |>
    dplyr::summarise(revenue = sum(gross_revenue_gbp, na.rm = TRUE),
                     streams = sum(streams, na.rm = TRUE), .groups = "drop") |>
    dplyr::mutate(rpm = dplyr::if_else(streams > 0,
                                      1000 * revenue / streams, NA_real_)) |>
    dplyr::arrange(market, month)
  if (!nrow(d)) return(data.frame())
  signals <- list()
  for (mk in unique(d$market)) {
    x <- d[d$market == mk, ]
    for (metric in c("revenue", "rpm")) {
      for (i in seq_len(nrow(x))) {
        if (i <= lookback) next
        previous <- x[[metric]][seq.int(i - lookback, i - 1L)]
        s <- stats::sd(previous)
        if (!is.finite(s) || s <= 0) next
        z <- (x[[metric]][i] - mean(previous)) / s
        if (is.finite(z) && abs(z) > threshold) {
          signals[[length(signals) + 1L]] <- data.frame(
            month = x$month[i], market = mk,
            metric = if (metric == "rpm") "Revenue per 1,000 streams" else "Gross revenue",
            observed = x[[metric]][i], baseline = mean(previous),
            z_score = round(z, 2),
            direction = ifelse(z > 0, "Above baseline", "Below baseline")
          )
        }
      }
    }
  }
  if (!length(signals)) return(data.frame(
    month = as.Date(character()), market = character(), metric = character(),
    observed = double(), baseline = double(), z_score = double(), direction = character()
  ))
  dplyr::bind_rows(signals)
}

# Source-level checks; keep separate from financial matching rules.
quality_summary <- function(raw, streaming, reconciliation) {
  records <- if (length(raw)) sum(vapply(raw, nrow, numeric(1))) else NA_real_
  nulls <- if (length(raw)) sum(vapply(raw, function(d) sum(is.na(d)), numeric(1))) else NA_real_
  keysets <- list(
    streaming_statements = "record_id",
    track_catalogue = "track_id",
    distribution_agreements = c("label_id", "platform", "market"),
    finance_ledger = c("month", "label_id", "market")
  )
  dupes <- 0L
  for (nm in intersect(names(keysets), names(raw))) {
    dupes <- dupes + sum(duplicated(raw[[nm]][keysets[[nm]]]))
  }
  list(raw_rows = records, nulls = nulls, duplicate_keys = dupes,
       enriched_rows = nrow(streaming), reconciliation_groups = nrow(reconciliation),
       unmatched_catalogue = sum(is.na(streaming$label_id)),
       unmatched_agreements = sum(is.na(streaming$label_share_pct)))
}

# Deal terms are illustrative monthly floors, not real music-rights contracts.
calculate_recharges <- function(streaming, terms) {
  if (!nrow(streaming)) return(data.frame())
  d <- streaming |>
    dplyr::group_by(month, label_id, label_name, market, platform) |>
    dplyr::summarise(gross_revenue_gbp = sum(gross_revenue_gbp),
                     expected_label_revenue_gbp = sum(expected_label_revenue_gbp),
                     .groups = "drop")
  if (is.null(terms) || !nrow(terms)) {
    d$minimum_guarantee_gbp <- 0
    d$deal_id <- NA_character_
  } else {
    keys <- c("label_id", "market", "platform")
    stopifnot(!anyDuplicated(terms[keys]))
    d <- dplyr::left_join(d, terms[, c(keys, "deal_id", "minimum_guarantee_gbp")],
                          by = keys)
  }
  d$minimum_guarantee_gbp[is.na(d$minimum_guarantee_gbp)] <- 0
  d$guarantee_topup_gbp <- pmax(d$minimum_guarantee_gbp -
                                  d$expected_label_revenue_gbp, 0)
  d$illustrative_recharge_gbp <- d$expected_label_revenue_gbp + d$guarantee_topup_gbp
  d$effective_share_pct <- dplyr::if_else(
    d$gross_revenue_gbp > 0,
    round(100 * d$expected_label_revenue_gbp / d$gross_revenue_gbp, 1), NA_real_)
  d
}
