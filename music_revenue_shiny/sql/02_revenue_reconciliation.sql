-- A £0.50 absolute tolerance is applied in the Shiny dashboard to exceptions.
-- Financial amounts round to 2 decimals before comparison. Missing counterparts are exceptions.
CREATE OR REPLACE VIEW
  `music-revenue-intelligence.streaming_revenue_analytics.v_revenue_reconciliation` AS
WITH expected AS (
  SELECT month, label_id, label_name, market,
         COUNT(*) AS streaming_records,
         ROUND(SUM(expected_label_revenue_gbp), 2) AS expected_label_revenue_gbp
  FROM `music-revenue-intelligence.streaming_revenue_analytics.v_streaming_enriched`
  GROUP BY month, label_id, label_name, market
)
SELECT
  COALESCE(e.month, l.month) AS month,
  COALESCE(e.label_id, l.label_id) AS label_id,
  e.label_name,
  COALESCE(e.market, l.market) AS market,
  l.ledger_entry_id,
  e.streaming_records,
  e.expected_label_revenue_gbp,
  ROUND(CAST(l.recorded_label_revenue_gbp AS NUMERIC), 2) AS recorded_label_revenue_gbp,
  ROUND(ROUND(CAST(l.recorded_label_revenue_gbp AS NUMERIC), 2)
          - e.expected_label_revenue_gbp, 2) AS variance_gbp,
  CASE
    WHEN e.month IS NULL THEN 'Missing expected allocation'
    WHEN l.ledger_entry_id IS NULL OR l.recorded_label_revenue_gbp IS NULL
      THEN 'Missing recorded revenue'
    WHEN ABS(ROUND(CAST(l.recorded_label_revenue_gbp AS NUMERIC), 2)
                 - e.expected_label_revenue_gbp) > 0.50 THEN 'Mismatch'
    ELSE 'Matched'
  END AS reconciliation_status
FROM expected AS e
FULL OUTER JOIN `music-revenue-intelligence.streaming_revenue_analytics.finance_ledger` AS l
  ON e.month = l.month AND e.label_id = l.label_id AND e.market = l.market;
