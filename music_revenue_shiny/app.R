# Music Revenue Intelligence | Shiny portfolio dashboard
# Fictional music, financial data and agreements. Source of truth: R/BigQuery.
library(shiny)
library(bslib)
library(dplyr)
library(plotly)
library(DT)
library(readr)
library(DBI)
library(bigrquery)
source("R/analytics.R", local = TRUE)

BQ_PROJECT <- Sys.getenv("MUSIC_BQ_PROJECT", "music-revenue-intelligence")
BQ_DATASET <- Sys.getenv("MUSIC_BQ_DATASET", "streaming_revenue_analytics")
BQ_BILLING <- Sys.getenv("MUSIC_BQ_BILLING", BQ_PROJECT)
ISSUE_FILE <- "data/processed/issue_register.csv"

# ----------------------------------------
# Data access and validation
# ----------------------------------------
read_from_bigquery <- function() {
  bigrquery::bq_auth()
  con <- DBI::dbConnect(bigrquery::bigquery(), project = BQ_PROJECT,
                        dataset = BQ_DATASET, billing = BQ_BILLING, bigint = "numeric")
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)
  qualified <- function(t) paste0("`", BQ_PROJECT, ".", BQ_DATASET, ".", t, "`")
  query_table <- function(t) DBI::dbGetQuery(con, paste("SELECT * FROM", qualified(t)))
  raw_names <- c("track_catalogue", "streaming_statements",
                 "distribution_agreements", "finance_ledger")
  raw <- stats::setNames(lapply(raw_names, query_table), raw_names)
  # Existing BigQuery projects may not have optional extended tables yet.
  terms <- tryCatch(query_table("deal_terms"), error = function(e) NULL)
  meta <- tryCatch(query_table("pipeline_runs"), error = function(e) NULL)
  list(streaming = query_table("v_streaming_enriched"),
       reconciliation = query_table("v_revenue_reconciliation"),
       raw = raw, terms = terms, pipeline_meta = meta)
}

read_from_local <- function() {
  required <- c("streaming_statements", "track_catalogue",
                "distribution_agreements", "finance_ledger")
  paths <- file.path("data", "raw", paste0(required, ".csv"))
  if (!all(file.exists(paths))) {
    stop("Missing local CSV files. Run source('generate_data.R') or source('generate_data_extended.R') first.")
  }
  raw <- stats::setNames(lapply(paths, function(path)
    readr::read_csv(path, show_col_types = FALSE)), required)
  terms <- if (file.exists("data/raw/deal_terms.csv"))
    readr::read_csv("data/raw/deal_terms.csv", show_col_types = FALSE) else NULL

  # Local-mode version of the two BigQuery views, using the same join grain.
  enriched <- raw$streaming_statements |>
    dplyr::left_join(raw$track_catalogue, by = "track_id") |>
    dplyr::left_join(raw$distribution_agreements,
                     by = c("label_id", "platform", "market")) |>
    dplyr::mutate(expected_label_revenue_gbp = gross_revenue_gbp * label_share_pct)
  expected <- enriched |>
    dplyr::group_by(month, label_id, label_name, market) |>
    dplyr::summarise(streaming_records = dplyr::n(),
      expected_label_revenue_gbp = round(sum(expected_label_revenue_gbp), 2),
      .groups = "drop")
  recon <- dplyr::full_join(expected, raw$finance_ledger,
                            by = c("month", "label_id", "market"))
  meta <- if (file.exists("data/processed/pipeline_run_metadata.csv"))
    readr::read_csv("data/processed/pipeline_run_metadata.csv",
                    show_col_types = FALSE) else NULL
  list(streaming = enriched, reconciliation = recon,
       raw = raw, terms = terms, pipeline_meta = meta)
}

normalise_data <- function(data) {
  needed_s <- c("record_id", "month", "market", "platform", "artist_name",
                "label_id", "label_name", "streams", "gross_revenue_gbp",
                "expected_label_revenue_gbp", "label_share_pct")
  needed_r <- c("month", "label_id", "market", "expected_label_revenue_gbp",
                "recorded_label_revenue_gbp")
  miss <- c(setdiff(needed_s, names(data$streaming)),
            setdiff(needed_r, names(data$reconciliation)))
  if (length(miss)) stop("Missing required columns: ", paste(unique(miss), collapse = ", "))
  data$streaming$month <- as.Date(data$streaming$month)
  data$reconciliation$month <- as.Date(data$reconciliation$month)
  for (nm in c("streams", "gross_revenue_gbp", "expected_label_revenue_gbp",
               "label_share_pct")) {
    data$streaming[[nm]] <- as.numeric(data$streaming[[nm]])
  }
  for (nm in c("expected_label_revenue_gbp", "recorded_label_revenue_gbp")) {
    data$reconciliation[[nm]] <- as.numeric(data$reconciliation[[nm]])
  }
  if (!nrow(data$streaming)) stop("No streaming records returned.")
  if (anyDuplicated(data$streaming$record_id)) {
    stop("Duplicate streaming records: check the SQL joins before reporting revenue.")
  }
  if (anyDuplicated(data$reconciliation[c("month", "label_id", "market")])) {
    stop("Duplicate month/label/market reconciliation groups.")
  }
  data$reconciliation <- classify_reconciliation(data$reconciliation)
  if (!is.null(data$terms) && nrow(data$terms)) {
    data$terms$minimum_guarantee_gbp <- as.numeric(data$terms$minimum_guarantee_gbp)
  }
  data$quality <- quality_summary(data$raw, data$streaming, data$reconciliation)
  data
}

read_issues <- function() {
  if (!file.exists(ISSUE_FILE)) return(data.frame(
    exception_key = character(), suspected_cause = character(),
    owner = character(), issue_status = character(), note = character(),
    last_updated = character(), stringsAsFactors = FALSE))
  d <- as.data.frame(readr::read_csv(ISSUE_FILE, show_col_types = FALSE))
  for (nm in c("exception_key", "suspected_cause", "owner", "issue_status",
               "note", "last_updated")) if (!nm %in% names(d)) d[[nm]] <- ""
  d
}

# ----------------------------------------
# Presentation
# ----------------------------------------
CSS <- "
body { background:#f4f6fa; }
.navbar {border-bottom:1px solid #e2e8f0; box-shadow:0 2px 10px #0f172a0b;}
.navbar-brand {font-weight:800; letter-spacing:-.4px;}
.mark {color:#0b887b; background:none;}
.bslib-sidebar-layout > .sidebar {background:white; border-right:1px solid #e5eaf0;}
.sidebar-heading {color:#7d8ca0; letter-spacing:1.1px; font-size:11px; font-weight:800;}
.content-heading {font-size:28px; font-weight:800; color:#12243a; margin:5px 0 4px;}
.content-subhead {color:#66768a; margin-bottom:18px; font-size:13px;}
.metric-card {background:white; border:1px solid #e3e9f0; border-radius:12px;
 padding:17px; min-height:124px; box-shadow:0 4px 15px #11223308;}
.metric-label {font-size:10.5px; color:#708096; font-weight:800; letter-spacing:.8px; text-transform:uppercase;}
.metric-value {font-size:27px; color:#14283f; font-weight:800; margin:7px 0 2px;}
.metric-detail {font-size:11px; color:#61748b;}
.card {border:1px solid #e3e9f0; border-radius:12px; box-shadow:0 3px 10px #11223307;}
.card-header {background:white; font-weight:750; font-size:14px;}
.card-body {padding:15px 17px;}
.source-chip {background:#e9f6f2; color:#176b5c; font-size:11px; border-radius:7px; padding:9px; margin:10px 0 16px;}
.info-note {font-size:12px; color:#718195; line-height:1.6;}
.page-footer {margin:18px 0; font-size:11px; color:#7a8b9f;}
.warning-box {background:#fff4e5; color:#784d09; padding:12px; border-radius:8px;}
.qa-cell {background:#f4f7fb; border-radius:8px; padding:12px; text-align:center;}
.qa-number {font-size:18px; font-weight:800; color:#1d334d;}
.qa-label {font-size:11px; color:#6b7c90;}
.issue-form {background:#f8fafc; border:1px solid #e4e9f1; border-radius:10px; padding:14px;}
.shiny-input-container {width:100%;}
/* Keep both date fields fully legible rather than clipping the final year. */
.shiny-date-range-input .input-daterange {display:flex; align-items:center; flex-wrap:wrap; gap:6px;}
.shiny-date-range-input .input-daterange input {width:136px !important; min-width:136px;}
.sidebar {min-width:345px;}
.datatables {font-size:12px;}
"

metric <- function(label, value_id, detail_id = NULL, detail = NULL) {
  div(class = "metric-card",
      div(class = "metric-label", label),
      div(class = "metric-value", textOutput(value_id, inline = TRUE)),
      div(class = "metric-detail",
          if (!is.null(detail_id)) textOutput(detail_id, inline = TRUE) else detail))
}
plot_card <- function(title, id, h = "310px") {
  bslib::card(bslib::card_header(title), bslib::card_body(plotlyOutput(id, height = h)))
}
table_card <- function(title, id) {
  bslib::card(bslib::card_header(title), bslib::card_body(DTOutput(id)))
}
month_axis <- function() {
  list(title = "", type = "date", tickformat = "%b %y", dtick = "M1",
       tick0 = "2026-01-01", showgrid = FALSE)
}
base_plot <- function(p) {
  p |>
    plotly::layout(font = list(family = "Arial", size = 11, color = "#34475b"),
                   paper_bgcolor = "white", plot_bgcolor = "white") |>
    plotly::config(displayModeBar = FALSE, responsive = TRUE)
}

ui <- bslib::page_navbar(
  title = tags$span(tags$span("●", class = "mark"), " Music Revenue Intelligence"),
  id = "page",
  theme = bslib::bs_theme(version = 5, bg = "#f4f6fa", fg = "#18283b", primary = "#0c8d7e"),
  fillable = FALSE,
  sidebar = bslib::sidebar(
    width = 365,
    div(class = "sidebar-heading", "DATA & FILTERS"),
    selectInput("source_mode", "Data source",
      choices = c("Google BigQuery" = "bigquery", "Local CSVs" = "local"),
      selected = "bigquery"),
    div(class = "source-chip", textOutput("source_status", inline = TRUE)),
    actionButton("refresh", "Refresh data", class = "btn btn-primary w-100"),
    tags$hr(),
    dateRangeInput("period", "Reporting period", start = "2026-01-01",
                   end = "2026-06-30", format = "dd M yyyy"),
    selectizeInput("markets", "Markets", choices = character(), multiple = TRUE,
                   options = list(placeholder = "All markets")),
    selectizeInput("labels", "Labels", choices = character(), multiple = TRUE,
                   options = list(placeholder = "All labels")),
    conditionalPanel(
      condition = "input.page === 'Commercial Performance' || input.page === 'Deal Operations'",
      selectizeInput("platforms", "Platforms", choices = character(), multiple = TRUE,
                     options = list(placeholder = "All platforms"))
    ),
    conditionalPanel(
      condition = "input.page === 'Revenue Reconciliation'",
      div(class = "info-note", "Reconciliation is at month × label × market level; platform filtering does not apply."),
      div(class = "info-note", strong("Matching rule: "),
          "absolute recorded-versus-expected difference ≤ £0.50; missing entries always count as exceptions.")
    ),
    tags$hr(),
    downloadButton("download_exceptions", "Export exception register",
                   class = "btn btn-outline-secondary w-100"),
    div(class = "page-footer", "Fictional commercial records · GBP · 2026")
  ),
  header = tagList(tags$head(tags$style(HTML(CSS))), uiOutput("load_message")),
  bslib::nav_panel("Commercial Performance",
    div(class = "content-heading", "Commercial performance"),
    div(class = "content-subhead", "Revenue drivers, market mix, artist contribution and anomaly detection."),
    bslib::layout_columns(col_widths = c(3,3,3,3),
      metric("Gross revenue", "kpi_gross", "delta_gross"),
      metric("Streams", "kpi_streams", "delta_streams"),
      metric("Revenue per 1,000", "kpi_rpm", "delta_rpm"),
      metric("Expected label revenue", "kpi_label", "delta_label")
    ),
    bslib::layout_columns(col_widths = c(7,5),
      plot_card("Monthly gross revenue", "monthly_chart", "310px"),
      plot_card("Monetisation by market", "rpm_chart", "310px")
    ),
    bslib::layout_columns(col_widths = c(7,5),
      plot_card("Revenue bridge · volume / mix / rate", "bridge_chart", "360px"),
      bslib::card(bslib::card_header("Key insights"),
                  bslib::card_body(uiOutput("commercial_insights")))
    ),
    bslib::layout_columns(col_widths = c(6,6),
      plot_card("Revenue by platform and market", "platform_chart", "325px"),
      table_card("Top artists · monetisation and share", "artist_table")
    ),
    bslib::card(bslib::card_header("Commercial anomaly monitor · 3-month rolling baseline"),
                bslib::card_body(uiOutput("anomaly_summary"), DTOutput("anomaly_table"))),
    div(class = "page-footer", "Revenue bridge uses an exact sequential decomposition. Three preceding months are used for each anomaly baseline; no look-ahead.")
  ),
  bslib::nav_panel("Revenue Reconciliation",
    div(class = "content-heading", "Revenue reconciliation"),
    div(class = "content-subhead", "Exception-only financial exposure, issue ownership and follow-up actions."),
    bslib::layout_columns(col_widths = c(3,3,3,3),
      metric("Reconciliation rate", "kpi_rate", detail = "Groups within £0.50 or exactly matched"),
      metric("Exceptions detected", "kpi_exceptions", detail = "Missing entries or > £0.50 discrepancy"),
      metric("Absolute exposure", "kpi_abs", detail = "Exceptions only · no offsetting"),
      metric("Net exception variance", "kpi_net", detail = "Recorded minus expected · exceptions only")
    ),
    bslib::layout_columns(col_widths = c(7,5),
      plot_card("Monthly recorded − expected · signed exceptions", "variance_chart", "320px"),
      plot_card("Exception exposure by market", "market_variance_chart", "320px")
    ),
    bslib::card(bslib::card_header("Exception register"),
      bslib::card_body(
        checkboxInput("exceptions_only", "Show exceptions only", TRUE),
        DTOutput("recon_table")
      )
    ),
    bslib::card(bslib::card_header("Issue follow-up · local portfolio register"),
      bslib::card_body(
        div(class = "issue-form",
          bslib::layout_columns(col_widths = c(6,6),
            selectInput("issue_key", "Exception", choices = character()),
            selectInput("issue_status", "Resolution status",
                        choices = c("Open", "Queried", "Resolved"))
          ),
          bslib::layout_columns(col_widths = c(6,6),
            selectInput("suspected_cause", "Suspected cause (not confirmed)",
              choices = c("Unconfirmed", "Timing", "FX conversion", "Missing statement",
                          "Rate / contract terms", "Duplicate posting", "Other")),
            textInput("issue_owner", "Owner", value = "Unassigned")
          ),
          textAreaInput("issue_note", "Follow-up / evidence", rows = 2,
                        placeholder = "Document evidence or a market follow-up, not an assumed root cause."),
          actionButton("save_issue", "Save issue update", class = "btn btn-primary"),
          div(class = "info-note", "Issue updates are saved locally to data/processed/issue_register.csv. They do not alter the source ledger or BigQuery.")
        )
      )
    ),
    bslib::card(bslib::card_header("Data quality checks"), bslib::card_body(uiOutput("quality_panel"))),
    div(class = "page-footer", "Ledger amounts are simulated from the allocation model with two deliberate exceptions. No real-world root cause has been established.")
  ),
  bslib::nav_panel("Deal Operations",
    div(class = "content-heading", "Deal operations · recharge / rebill simulation"),
    div(class = "content-subhead", "Monthly contractual allocation plus an illustrative minimum-guarantee floor."),
    bslib::layout_columns(col_widths = c(6,6),
      plot_card("Illustrative recharge composition", "recharge_chart", "320px"),
      bslib::card(bslib::card_header("Calculation method"),
        bslib::card_body(
          tags$p("Expected allocation = gross streaming revenue × label share."),
          tags$p("Guarantee top-up = max(monthly minimum guarantee − expected allocation, £0)."),
          tags$p("Illustrative recharge = expected allocation + guarantee top-up."),
          div(class = "info-note", "This is a simplified demonstration, not a representation of Universal Music contract accounting. Rate/guarantee assumptions are fictional and do not represent a legally payable amount.")
        )
      )
    ),
    table_card("Deal-level monthly recharge worksheet", "recharge_table"),
    table_card("Proposed corrective rebills · for review only", "rebill_table"),
    bslib::card(bslib::card_header("FX and Korea coverage"), bslib::card_body(uiOutput("fx_info")))
  ),
  bslib::nav_panel("Methodology",
    div(class = "content-heading", "Methodology & limitations"),
    bslib::card(bslib::card_body(
      tags$h4("Data provenance"),
      tags$p("All artist names, labels, platforms' simulated royalty rates, contract terms, streaming activity, FX assumptions and finance values in this project are fictional. No commercial platform statements or real contracts were used."),
      tags$h4("Reconciliation & matching rule"),
      tags$p("Expected label revenue = platform gross revenue in GBP × fictional label share. Expected values are summed to month / label / market and rounded to pennies. The recorded ledger is model-derived with two intentional changes."),
      tags$p("A group matches when both sides exist and the absolute two-decimal variance is at most £0.50. Exceptions have larger variances or a missing counterpart. KPI exposure sums exception rows only, so insignificant residuals do not inflate the reported exception amount."),
      tags$h4("Revenue bridge"),
      tags$p("An exact sequential decomposition between the most recent two months in the selection separates total streaming volume, market-share mix, and within-market revenue per stream. Results depend on decomposition order and show descriptive effects, not causal attribution."),
      tags$h4("Anomalies"),
      tags$p("A market is flagged when monthly revenue or revenue per 1,000 streams differs by more than two standard deviations from the previous three months. Requires a nonzero baseline standard deviation. Flags identify candidates for investigation, not confirmed errors."),
      tags$h4("Issue ownership & controls"),
      tags$p("Owners, causes and resolution states are analyst-maintained scenario fields stored locally. A suspected cause is not a verified cause. No amendments are posted to BigQuery or the finance ledger."),
      tags$h4("FX & geography"),
      tags$p("The optional generate_data_extended.R adds South Korea and fictional monthly local-currency conversion factors. These are NOT actual historical FX rates. The original four-market generator remains usable in the dashboard."),
      tags$h4("Refresh behaviour"),
      tags$p("The R pipeline replaces synthetic source tables and rebuilds two BigQuery views. The dashboard's Refresh button re-queries data; it does not itself schedule the pipeline or automatically post financial corrections.")
    ))
  )
)

# ----------------------------------------
# Server
# ----------------------------------------
server <- function(input, output, session) {
  stored <- reactiveVal(NULL)
  last_error <- reactiveVal(NULL)
  loaded_at <- reactiveVal(NULL)
  issue_state <- reactiveVal(read_issues())

  fetch_data <- function() {
    last_error(NULL)
    tryCatch({
      result <- withProgress(message = "Refreshing data", value = 0, {
        incProgress(0.25, detail = "Reading source tables and reporting views")
        raw <- if (identical(input$source_mode, "bigquery"))
          read_from_bigquery() else read_from_local()
        incProgress(0.45, detail = "Validating joins, dates and financial measures")
        normalise_data(raw)
      })
      stored(result)
      loaded_at(Sys.time())
      updateSelectizeInput(session, "markets",
        choices = stats::setNames(sort(unique(as.character(result$streaming$market))),
                                  market_name(sort(unique(as.character(result$streaming$market))))),
        selected = character())
      updateSelectizeInput(session, "labels",
        choices = sort(unique(as.character(result$streaming$label_name))),
        selected = character())
      updateSelectizeInput(session, "platforms",
        choices = sort(unique(as.character(result$streaming$platform))),
        selected = character())
      updateDateRangeInput(session, "period",
        start = min(result$streaming$month),
        end = as.Date(format(max(result$streaming$month) + 32, "%Y-%m-01")) - 1)
    }, error = function(e) {
      last_error(conditionMessage(e))
      showNotification("Could not refresh data; check the error message.", type = "error", duration = 8)
    })
  }
  observeEvent(input$source_mode, fetch_data(), ignoreInit = FALSE)
  observeEvent(input$refresh, fetch_data())

  output$source_status <- renderText({
    if (!is.null(last_error())) return("Connection failed")
    if (is.null(stored())) return("Connecting…")
    sprintf("%s · dashboard refreshed %s",
      if (identical(input$source_mode, "bigquery")) "BigQuery" else "Local CSV",
      format(loaded_at(), "%d %b %H:%M"))
  })
  output$load_message <- renderUI({
    if (is.null(last_error())) return(NULL)
    div(class = "warning-box", tags$b("Data refresh failed: "),
        last_error(), tags$br(),
        "Try Local CSVs or check BigQuery permissions, schema and view definitions.")
  })

  # Filters that are meaningful for BOTH commercial and finance analyses.
  all_periods_filtered <- reactive({
    x <- req(stored())$streaming
    if (length(input$markets)) x <- x |> filter(market %in% input$markets)
    if (length(input$labels)) x <- x |> filter(label_name %in% input$labels)
    if (length(input$platforms)) x <- x |> filter(platform %in% input$platforms)
    x
  })
  date_filter <- function(x) {
    if (!is.null(input$period) && length(input$period) == 2L && !anyNA(input$period)) {
      x <- x |> filter(month >= input$period[1] & month <= input$period[2])
    }
    x
  }
  filtered_streaming <- reactive(date_filter(all_periods_filtered()))
  filtered_reconciliation <- reactive({
    x <- req(stored())$reconciliation
    if (length(input$markets)) x <- x |> filter(market %in% input$markets)
    if (length(input$labels)) x <- x |> filter(label_name %in% input$labels)
    date_filter(x)
  })
  monthly_commercial <- reactive({
    filtered_streaming() |>
      group_by(month) |>
      summarise(revenue = sum(gross_revenue_gbp, na.rm = TRUE),
                streams = sum(streams, na.rm = TRUE),
                label_revenue = sum(expected_label_revenue_gbp, na.rm = TRUE),
                .groups = "drop") |>
      mutate(rpm = if_else(streams > 0, revenue / streams * 1000, NA_real_)) |>
      arrange(month)
  })
  month_delta <- function(column) {
    d <- monthly_commercial()
    if (nrow(d) < 2) return("MoM: not available · select ≥2 months")
    previous <- d[[column]][nrow(d) - 1L]
    latest <- d[[column]][nrow(d)]
    if (!is.finite(previous) || previous == 0) return("MoM: no comparison base")
    pct <- 100 * (latest / previous - 1)
    paste0(format(d$month[nrow(d)], "%b"), " vs ",
           format(d$month[nrow(d)-1], "%b"), ": ",
           sprintf("%+.1f%%", pct))
  }
  output$kpi_gross <- renderText(money_text(sum(filtered_streaming()$gross_revenue_gbp, na.rm = TRUE)))
  output$kpi_streams <- renderText(num_text(sum(filtered_streaming()$streams, na.rm = TRUE)))
  output$kpi_rpm <- renderText({
    d <- filtered_streaming()
    s <- sum(d$streams, na.rm = TRUE)
    money_text(if (s > 0) sum(d$gross_revenue_gbp, na.rm = TRUE) * 1000 / s else NA_real_, 2)
  })
  output$kpi_label <- renderText(money_text(sum(filtered_streaming()$expected_label_revenue_gbp, na.rm = TRUE)))
  output$delta_gross <- renderText(month_delta("revenue"))
  output$delta_streams <- renderText(month_delta("streams"))
  output$delta_rpm <- renderText(month_delta("rpm"))
  output$delta_label <- renderText(month_delta("label_revenue"))

  output$monthly_chart <- renderPlotly({
    d <- monthly_commercial()
    validate(need(nrow(d) > 0, "No revenue data for the selected filters."))
    base_plot(plot_ly(d, x = ~month, y = ~revenue,
      type = "scatter", mode = "lines+markers", fill = "tozeroy",
      line = list(color = "#0c8d7e", width = 3),
      fillcolor = "rgba(12,141,126,0.13)",
      marker = list(size = 7),
      hovertemplate = "%{x|%b %Y}<br>Revenue: £%{y:,.2f}<extra></extra>")) |>
      layout(xaxis = month_axis(), yaxis = list(title = "Gross revenue (£)", rangemode = "tozero"),
             margin = list(l = 68, r = 12, b = 40, t = 12))
  })

  output$rpm_chart <- renderPlotly({
    d <- filtered_streaming() |>
      group_by(market) |>
      summarise(revenue = sum(gross_revenue_gbp), streams = sum(streams), .groups = "drop") |>
      mutate(rpm = if_else(streams > 0, revenue / streams * 1000, NA_real_),
             market_full = market_name(market)) |>
      arrange(rpm)
    validate(need(nrow(d) > 0, "No market data."))
    d$market_full <- factor(d$market_full, levels = d$market_full)
    base_plot(plot_ly(d, x = ~rpm, y = ~market_full, type = "bar",
      orientation = "h", marker = list(color = "#147f89"),
      text = ~sprintf("£%.2f", rpm), textposition = "outside",
      hovertemplate = "%{y}<br>£%{x:.2f} / 1,000 streams<extra></extra>")) |>
      layout(xaxis = list(title = "Revenue (£) per 1,000 streams", range = c(0, max(d$rpm, na.rm = TRUE) * 1.24)),
             yaxis = list(title = ""), margin = list(l = 105, r = 42, t = 12, b = 52))
  })

  output$platform_chart <- renderPlotly({
    d <- filtered_streaming() |>
      group_by(market, platform) |>
      summarise(revenue = sum(gross_revenue_gbp), .groups = "drop") |>
      mutate(market_full = market_name(market))
    validate(need(nrow(d) > 0, "No platform data."))
    base_plot(plot_ly(d, x = ~market_full, y = ~revenue, color = ~platform,
      type = "bar", colors = c("#0c8d7e", "#4a74bf", "#d39e5b"),
      hovertemplate = "%{fullData.name}<br>%{x}<br>£%{y:,.2f}<extra></extra>")) |>
      layout(barmode = "stack", xaxis = list(title = ""),
             yaxis = list(title = "Gross revenue (£)", rangemode = "tozero"),
             legend = list(orientation = "h", x = 0, y = -0.3),
             margin = list(l = 65, r = 15, t = 10, b = 75))
  })

  
  output$artist_table <- renderDT({
    
    d <- filtered_streaming() |>
      group_by(artist_name, label_name) |>
      summarise(
        streams = sum(streams),
        revenue = sum(gross_revenue_gbp),
        .groups = "drop"
      ) |>
      arrange(desc(revenue)) |>
      mutate(
        rpm = if_else(
          streams > 0,
          1000 * revenue / streams,
          NA_real_
        ),
        contribution = if (sum(revenue) > 0) {
          100 * revenue / sum(revenue)
        } else {
          rep(0, dplyr::n())
        }
      ) |>
      transmute(
        Artist = artist_name,
        Label = label_name,
        Revenue = vapply(revenue, money_text, character(1), digits = 2),
        Streams = vapply(streams, num_text, character(1)),
        `£ / 1K` = sprintf("£%.2f", rpm),
        `Revenue share` = sprintf("%.1f%%", contribution)
      )
    
    validate(need(nrow(d) > 0, "No artist data."))
    
    DT::datatable(
      d,
      rownames = FALSE,
      options = list(
        pageLength = 7,
        lengthChange = FALSE,
        searching = FALSE,
        scrollX = TRUE,
        dom = "tip"
      )
    )
  })
  

  
  bridge <- reactive(revenue_bridge(filtered_streaming()))
  
  output$bridge_chart <- renderPlotly({
    
    b <- bridge()
    
    validate(need(
      !is.null(b),
      "Select at least two months to decompose revenue changes."
    ))
    
    # Define the correct order of the waterfall
    steps <- c(
      format(b$month0, "%b %y"),
      "Streaming volume",
      "Market mix",
      "Within-market rate",
      format(b$month1, "%b %y")
    )
    
    values <- c(
      b$start,
      b$volume,
      b$mix,
      b$rate,
      b$end
    )
    
    # Format labels; totals do not need +/- signs
    labels <- paste0(
      ifelse(
        seq_along(values) %in% c(1, 5),
        "",
        ifelse(values >= 0, "+", "−")
      ),
      "£",
      formatC(
        abs(values),
        format = "f",
        digits = 0,
        big.mark = ","
      )
    )
    
    base_plot(
      plot_ly(
        type = "waterfall",
        x = steps,
        y = values,
        
        measure = c(
          "absolute",
          "relative",
          "relative",
          "relative",
          "total"
        ),
        
        text = labels,
        textposition = "outside",
        
        increasing = list(
          marker = list(color = "#0c8d7e")
        ),
        
        decreasing = list(
          marker = list(color = "#d37354")
        ),
        
        totals = list(
          marker = list(color = "#4677b4")
        ),
        
        connector = list(
          line = list(color = "#9db1c3")
        ),
        
        hovertemplate = "%{x}<br>£%{y:,.2f}<extra></extra>"
      )
    ) |>
      layout(
        xaxis = list(
          title = "",
          type = "category",
          categoryorder = "array",
          categoryarray = steps
        ),
        
        yaxis = list(
          title = "Gross revenue (£)"
        ),
        
        margin = list(
          l = 66,
          r = 12,
          t = 20,
          b = 80
        )
      )
  })
  
  commercial_anomalies <- reactive({
    # Calculate from the complete historical time series, then apply date selection.
    d <- rolling_anomalies(all_periods_filtered())
    date_filter(d)
  })
  output$anomaly_summary <- renderUI({
    d <- commercial_anomalies()
    if (!nrow(d)) return(tags$p(class = "info-note",
      "No flags above ±2 standard deviations under the preceding three-month baseline for these filters. This does not prove the data is error-free."))
    tags$p(class = "info-note", nrow(d),
           " candidate anomalies found. These are statistical flags, not confirmed problems.")
  })
  output$anomaly_table <- renderDT({
    d <- commercial_anomalies()
    if (!nrow(d)) return(DT::datatable(data.frame(Message = "No current flags"),
                                       options = list(dom = "t"), rownames = FALSE))
    d <- d |>
      mutate(Month = format(month, "%b %Y"), Market = market_name(market),
             Observed = if_else(metric == "Gross revenue",
                 sprintf("£%.2f", observed), sprintf("£%.2f / 1K", observed)),
             `Prior mean` = sprintf("%.2f", baseline)) |>
      select(Month, Market, Metric = metric, Observed, `Prior mean`,
             `Z-score` = z_score, Direction = direction)
    DT::datatable(d, options = list(pageLength = 6, searching = FALSE,
                                   lengthChange = FALSE, scrollX = TRUE, dom = "tip"),
                  rownames = FALSE)
  })

  
  output$commercial_insights <- renderUI({
    
    d <- filtered_streaming()
    
    validate(need(
      nrow(d) > 0,
      "No data for the selected filters."
    ))
    
    # 1. Calculate market performance
    market <- d |>
      group_by(market) |>
      summarise(
        revenue = sum(gross_revenue_gbp, na.rm = TRUE),
        streams = sum(streams, na.rm = TRUE),
        .groups = "drop"
      ) |>
      mutate(
        share = if (sum(revenue) > 0) {
          100 * revenue / sum(revenue)
        } else {
          rep(NA_real_, n())
        },
        rpm = if_else(
          streams > 0,
          1000 * revenue / streams,
          NA_real_
        )
      ) |>
      arrange(desc(revenue))
    
    top <- market[1, ]
    
    # Helper: signed currency for bridge effects
    signed_money <- function(x) {
      paste0(
        if (x >= 0) "+" else "−",
        money_text(abs(x), 2)
      )
    }
    
    insights <- list()
    
    # 2. Explain month-on-month revenue performance
    b <- bridge()
    
    if (!is.null(b)) {
      
      change <- b$end - b$start
      
      change_pct <- if (b$start > 0) {
        100 * change / b$start
      } else {
        NA_real_
      }
      
      movement <- if (change >= 0) "increased" else "decreased"
      
      pct_label <- if (is.finite(change_pct)) {
        sprintf(" (%+.1f%%)", change_pct)
      } else {
        ""
      }
      
      insights[[length(insights) + 1]] <- tags$p(
        tags$strong("Revenue performance: "),
        sprintf(
          "Gross revenue %s by %s%s between %s and %s.",
          movement,
          money_text(abs(change), 2),
          pct_label,
          format(b$month0, "%B"),
          format(b$month1, "%B")
        )
      )
      
      # 3. Explain the revenue bridge
      drivers <- c(
        "streaming volume" = b$volume,
        "geographic market mix" = b$mix,
        "within-market monetisation" = b$rate
      )
      
      largest <- names(which.max(abs(drivers)))
      
      insights[[length(insights) + 1]] <- tags$p(
        tags$strong("Revenue drivers: "),
        sprintf(
          "Volume contributed %s, market mix %s and within-market monetisation %s. The largest component was %s.",
          signed_money(b$volume),
          signed_money(b$mix),
          signed_money(b$rate),
          largest
        )
      )
    }
    
    # 4. Explain market concentration
    insights[[length(insights) + 1]] <- tags$p(
      tags$strong("Market exposure: "),
      sprintf(
        "%s generated %.1f%% of selected revenue (%s), making it the largest market.",
        market_name(top$market),
        top$share,
        money_text(top$revenue, 0)
      )
    )
    
    # 5. Identify the highest-monetising market
    valid_rates <- market |>
      filter(is.finite(rpm))
    
    if (nrow(valid_rates) > 0) {
      
      best <- valid_rates |>
        arrange(desc(rpm)) |>
        slice(1)
      
      insights[[length(insights) + 1]] <- tags$p(
        tags$strong("Monetisation: "),
        sprintf(
          "%s generated the highest revenue per 1,000 streams at £%.2f.",
          market_name(best$market),
          best$rpm
        )
      )
    }
    
    # 6. Explain a possible commercial implication
    if (!is.null(b)) {
      
      implication <- if (b$mix < 0) {
        paste(
          "The negative market-mix contribution suggests",
          "streaming shifted towards relatively",
          "lower-monetising markets. Monitor whether",
          "this pattern continues."
        )
      } else if (b$mix > 0) {
        paste(
          "Geographic market mix supported revenue.",
          "Monitor whether this favourable",
          "distribution of streams persists."
        )
      } else {
        paste(
          "Geographic market mix had no material",
          "effect in this decomposition."
        )
      }
      
      insights[[length(insights) + 1]] <- tags$p(
        tags$strong("Commercial implication: "),
        implication
      )
    }
    
    tags$div(
      insights,
      tags$small(
        class = "text-muted",
        "Analysis uses synthetic data. Bridge effects are descriptive, not causal."
      )
    )
    
  })
  

  # --------------------------------------
  # Reconciliation + issue register
  # --------------------------------------
  register <- reactive({
    d <- filtered_reconciliation()
    issues <- issue_state()
    d <- left_join(d, issues, by = "exception_key")
    d$issue_status <- ifelse(is.na(d$issue_status),
                             ifelse(d$reconciliation_status == "Matched", "—", "Open"),
                             d$issue_status)
    d$suspected_cause <- ifelse(is.na(d$suspected_cause), "Unconfirmed", d$suspected_cause)
    d$owner <- ifelse(is.na(d$owner), "Unassigned", d$owner)
    d
  })
  exceptions <- reactive(register() |> filter(reconciliation_status != "Matched"))

  output$kpi_rate <- renderText({
    d <- filtered_reconciliation()
    if (!nrow(d)) return("—")
    sprintf("%.1f%%", 100 * mean(d$reconciliation_status == "Matched"))
  })
  output$kpi_exceptions <- renderText(num_text(nrow(exceptions())))
  output$kpi_abs <- renderText(money_text(
    sum(abs(exceptions()$variance_gbp), na.rm = TRUE), 2))
  output$kpi_net <- renderText(money_text(
    sum(exceptions()$variance_gbp, na.rm = TRUE), 2))

  output$variance_chart <- renderPlotly({
    d <- exceptions() |>
      filter(!is.na(variance_gbp)) |>
      group_by(month, direction) |>
      summarise(variance = sum(variance_gbp), .groups = "drop")
    validate(need(nrow(d) > 0, "No material exception variance for these filters."))
    base_plot(plot_ly(d, x = ~month, y = ~variance, color = ~direction,
      type = "bar", colors = c("Over-recorded" = "#c66e42", "Under-recorded" = "#4279bb"),
      hovertemplate = "%{x|%b %Y}<br>Variance: £%{y:,.2f}<extra></extra>")) |>
      layout(xaxis = month_axis(),
             yaxis = list(title = "Recorded minus expected (£)", zeroline = TRUE,
                          zerolinecolor = "#405a72", zerolinewidth = 2),
             legend = list(orientation = "h", x = 0, y = -0.25),
             barmode = "relative", margin = list(l = 66, r = 14, t = 12, b = 65))
  })

  output$market_variance_chart <- renderPlotly({
    d <- exceptions() |>
      filter(!is.na(variance_gbp)) |>
      mutate(market_full = market_name(market)) |>
      group_by(market_full, direction) |>
      summarise(variance = sum(variance_gbp), .groups = "drop")
    validate(need(nrow(d) > 0, "No material exception variance by market."))
    base_plot(plot_ly(d, x = ~variance, y = ~market_full, color = ~direction,
      type = "bar", orientation = "h",
      colors = c("Over-recorded" = "#c66e42", "Under-recorded" = "#4279bb"),
      hovertemplate = "%{y}: £%{x:,.2f}<extra></extra>")) |>
      layout(xaxis = list(title = "Signed exception variance (£)", zeroline = TRUE,
                          zerolinecolor = "#405a72"),
             yaxis = list(title = ""), showlegend = FALSE,
             margin = list(l = 100, r = 16, t = 14, b = 55))
  })

  selected_register <- reactive({
    d <- register()
    if (isTRUE(input$exceptions_only)) d <- d |> filter(reconciliation_status != "Matched")
    d |> arrange(desc(abs(variance_gbp)))
  })
  output$recon_table <- renderDT({
    d <- selected_register()
    if (!nrow(d)) return(DT::datatable(data.frame(Message = "No records for this selection"),
                                       options = list(dom = "t"), rownames = FALSE))
    d <- d |>
      mutate(
        Month = format(month, "%b %Y"),
        Market = market_name(market),
        Expected = vapply(expected_label_revenue_gbp, money_text, character(1), digits = 2),
        Recorded = vapply(recorded_label_revenue_gbp, money_text, character(1), digits = 2),
        Variance = vapply(variance_gbp, money_text, character(1), digits = 2),
        `Variance %` = ifelse(is.finite(variance_pct),
                              sprintf("%+.2f%%", variance_pct), "—")
      ) |>
      select(Month, Label = label_name, Market, Expected, Recorded,
             Variance, `Variance %`, Direction = direction,
             `Match check` = reconciliation_status, Owner = owner,
             `Suspected cause` = suspected_cause, `Follow-up` = issue_status)
    DT::datatable(d, rownames = FALSE, options = list(pageLength = 8,
      lengthChange = FALSE, searching = TRUE, scrollX = TRUE, dom = "ftip"))
  })

  observe({
    d <- exceptions()
    keys <- d$exception_key
    labels <- paste(format(d$month, "%b %Y"), d$label_id,
                    market_name(d$market), sep = " · ")
    selected <- isolate(input$issue_key)
    if (length(keys) && (is.null(selected) || !selected %in% keys)) selected <- keys[[1]]
    updateSelectInput(session, "issue_key", choices = stats::setNames(keys, labels),
                      selected = selected)
  })
  observeEvent(input$issue_key, {
    current <- issue_state()
    found <- current[current$exception_key == input$issue_key, , drop = FALSE]
    if (!nrow(found)) {
      updateSelectInput(session, "issue_status", selected = "Open")
      updateSelectInput(session, "suspected_cause", selected = "Unconfirmed")
      updateTextInput(session, "issue_owner", value = "Unassigned")
      updateTextAreaInput(session, "issue_note", value = "")
    } else {
      updateSelectInput(session, "issue_status", selected = found$issue_status[[1]])
      updateSelectInput(session, "suspected_cause", selected = found$suspected_cause[[1]])
      updateTextInput(session, "issue_owner", value = found$owner[[1]])
      updateTextAreaInput(session, "issue_note", value = found$note[[1]])
    }
  })
  observeEvent(input$save_issue, {
    req(input$issue_key)
    updates <- issue_state()
    updates <- updates[updates$exception_key != input$issue_key, , drop = FALSE]
    updated <- data.frame(
      exception_key = input$issue_key,
      suspected_cause = input$suspected_cause,
      owner = trimws(input$issue_owner),
      issue_status = input$issue_status,
      note = input$issue_note,
      last_updated = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
      stringsAsFactors = FALSE
    )
    updates <- bind_rows(updates, updated)
    dir.create(dirname(ISSUE_FILE), recursive = TRUE, showWarnings = FALSE)
    ok <- tryCatch({
      readr::write_csv(updates, ISSUE_FILE)
      TRUE
    }, error = function(e) {
      showNotification(paste("Could not save issue file:", conditionMessage(e)),
                       type = "error")
      FALSE
    })
    if (ok) {
      issue_state(updates)
      showNotification("Issue updated locally; ledger data is unchanged.", type = "message")
    }
  })
  output$download_exceptions <- downloadHandler(
    filename = function() paste0("reconciliation_exceptions_", Sys.Date(), ".csv"),
    content = function(file) readr::write_csv(exceptions(), file)
  )

  output$quality_panel <- renderUI({
    x <- req(stored())
    q <- x$quality
    last_run <- "Not available (pipeline metadata not found)"
    if (!is.null(x$pipeline_meta) && nrow(x$pipeline_meta) &&
        "run_utc" %in% names(x$pipeline_meta)) {
      last_run <- as.character(x$pipeline_meta$run_utc[[1]])
    }
    cards <- list(
      c("Source rows (4 core tables)", num_text(q$raw_rows)),
      c("Source null values", num_text(q$nulls)),
      c("Duplicate source keys", num_text(q$duplicate_keys)),
      c("Unmatched catalogue rows", num_text(q$unmatched_catalogue)),
      c("Unmatched agreements", num_text(q$unmatched_agreements)),
      c("Reconciliation groups", num_text(q$reconciliation_groups))
    )
    tagList(
      div(style = "display:grid;grid-template-columns:repeat(auto-fit,minmax(145px,1fr));gap:8px;",
        lapply(cards, function(card) div(class = "qa-cell",
          div(class = "qa-number", card[[2]]),
          div(class = "qa-label", card[[1]])))),
      div(class = "info-note", paste0("Pipeline last run (UTC): ", last_run)),
      div(class = "info-note", "The dashboard refresh time is not the same as the pipeline ingestion time. Match tolerance is shown separately from source-data QA checks.")
    )
  })

  # --------------------------------------
  # Recharge and FX demonstration
  # --------------------------------------
  recharge_data <- reactive(calculate_recharges(filtered_streaming(), req(stored())$terms))
  output$recharge_chart <- renderPlotly({
    d <- recharge_data() |>
      group_by(month) |>
      summarise(allocation = sum(expected_label_revenue_gbp, na.rm = TRUE),
                topup = sum(guarantee_topup_gbp, na.rm = TRUE), .groups = "drop")
    validate(need(nrow(d) > 0, "No deal data for current filters."))
    base_plot(plot_ly(d, x = ~month) |>
      add_bars(y = ~allocation, name = "Expected allocation",
               marker = list(color = "#0c8d7e"),
               hovertemplate = "%{x|%b %Y}<br>Allocation £%{y:,.2f}<extra></extra>") |>
      add_bars(y = ~topup, name = "Guarantee top-up",
               marker = list(color = "#d39e5b"),
               hovertemplate = "%{x|%b %Y}<br>Top-up £%{y:,.2f}<extra></extra>")) |>
      layout(barmode = "stack", xaxis = month_axis(),
             yaxis = list(title = "Illustrative recharge (£)", rangemode = "tozero"),
             legend = list(orientation = "h", x = 0, y = -0.3),
             margin = list(l = 67, b = 68, r = 12, t = 12))
  })
  output$recharge_table <- renderDT({
    d <- recharge_data()
    validate(need(nrow(d) > 0, "No deal allocations for these filters."))
    view <- d |>
      arrange(desc(guarantee_topup_gbp), desc(illustrative_recharge_gbp)) |>
      transmute(
        Month = format(month, "%b %Y"), Label = label_name,
        Market = market_name(market), Platform = platform,
        `Deal ID` = deal_id,
        `Effective share` = sprintf("%.1f%%", effective_share_pct),
        `Expected allocation` = vapply(expected_label_revenue_gbp, money_text,
                                        character(1), digits = 2),
        `Monthly guarantee` = vapply(minimum_guarantee_gbp, money_text,
                                      character(1), digits = 2),
        `Top-up` = vapply(guarantee_topup_gbp, money_text, character(1), digits = 2),
        `Illustrative recharge` = vapply(illustrative_recharge_gbp, money_text,
                                          character(1), digits = 2)
      )
    DT::datatable(view, rownames = FALSE,
       options = list(pageLength = 10, lengthChange = FALSE,
                      searching = TRUE, scrollX = TRUE, dom = "ftip"))
  })
  output$rebill_table <- renderDT({
    d <- exceptions()
    if (!nrow(d)) return(DT::datatable(data.frame(Message = "No corrective rebills proposed"),
                                       rownames = FALSE, options = list(dom = "t")))
    d <- d |>
      mutate(`Proposed rebill` = -variance_gbp,
             Month = format(month, "%b %Y"),
             Market = market_name(market)) |>
      transmute(Month, Label = label_name, Market,
                `Recorded − expected` = vapply(variance_gbp, money_text,
                                                character(1), digits = 2),
                `Proposed rebill` = vapply(`Proposed rebill`, money_text,
                                           character(1), digits = 2),
                `Review status` = "Requires evidence and approval")
    DT::datatable(d, rownames = FALSE,
      options = list(pageLength = 8, lengthChange = FALSE,
                     searching = FALSE, scrollX = TRUE, dom = "tip"))
  })
  output$fx_info <- renderUI({
    x <- req(stored())$streaming
    mk <- sort(unique(as.character(x$market)))
    has_local <- all(c("local_currency", "fx_local_per_gbp",
                       "gross_revenue_local") %in% names(x))
    actual_fx <- has_local && any(as.character(x$local_currency) != "GBP")
    tagList(
      tags$p(strong("Covered markets: "), paste(market_name(mk), collapse = ", ")),
      if (!"KR" %in% mk) div(class = "warning-box",
        "Korea is not yet in this dataset. Run source('generate_data_extended.R') then source('run_pipeline.R'), and refresh."),
      tags$p(if (actual_fx)
        "FX demonstration active: statements include fictional local currency, a simulated local-units-per-GBP rate, and converted GBP gross revenue."
      else
        "This source currently has GBP reporting values only (or a GBP passthrough). Run the optional extended generator to demonstrate FX conversion."),
      tags$p(class = "info-note",
        "KR coverage does not imply real BTS or Stray Kids data. All performers and records remain fictional.")
    )
  })
}

shinyApp(ui, server)
