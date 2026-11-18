-- Synthetic reporting view. Requires a streaming table with local-currency columns.
CREATE OR REPLACE VIEW
  `music-revenue-intelligence.streaming_revenue_analytics.v_streaming_enriched` AS
SELECT
  s.record_id,
  s.source_statement_id,
  s.month,
  s.platform,
  s.market,
  s.track_id,
  c.track_name,
  c.artist_id,
  c.artist_name,
  c.label_id,
  c.label_name,
  s.streams,
  s.local_currency,
  CAST(s.fx_local_per_gbp AS NUMERIC) AS fx_local_per_gbp,
  CAST(s.gross_revenue_local AS NUMERIC) AS gross_revenue_local,
  CAST(s.gross_revenue_gbp AS NUMERIC) AS gross_revenue_gbp,
  CAST(a.label_share_pct AS NUMERIC) AS label_share_pct,
  CAST(s.gross_revenue_gbp AS NUMERIC) * CAST(a.label_share_pct AS NUMERIC)
    AS expected_label_revenue_gbp
FROM `music-revenue-intelligence.streaming_revenue_analytics.streaming_statements` AS s
LEFT JOIN `music-revenue-intelligence.streaming_revenue_analytics.track_catalogue` AS c
  ON s.track_id = c.track_id
LEFT JOIN `music-revenue-intelligence.streaming_revenue_analytics.distribution_agreements` AS a
  ON c.label_id = a.label_id
 AND s.platform = a.platform
 AND s.market = a.market;
