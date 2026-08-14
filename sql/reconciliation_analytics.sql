-- Module 2.2: reconciliation analytics
-- Requires production reconciliation_results in data/reconciliation.db.
-- Run from the project root:
--   sqlite3 data/reconciliation.db < sql/reconciliation_analytics.sql

.bail on
.headers on

DROP VIEW IF EXISTS reconciliation_analytics_base;
CREATE VIEW reconciliation_analytics_base AS
WITH localized AS (
    SELECT
        *,
        datetime(
            booking_timestamp_utc,
            CASE
                -- New York DST began March 9 in the fixed 2025 simulation.
                WHEN booking_date >= '2025-03-09' THEN '-4 hours'
                ELSE '-5 hours'
            END
        ) AS booking_timestamp_new_york
    FROM reconciliation_results
),
measured AS (
    SELECT
        *,
        CASE WHEN bank_record_count > 0 THEN 1 ELSE 0 END AS is_settled,
        CASE WHEN settlement_delay_calendar_days > 0 THEN 1 ELSE 0 END AS is_late,
        (julianday(execution_timestamp_utc) - julianday(booking_timestamp_utc))
            * 24.0 AS quote_to_execution_hours,
        ABS(fx_execution_funding_variance_usd)
            AS absolute_fx_funding_variance_usd,
        CASE
            WHEN partner = 'PARTNER_A'
                 AND time(booking_timestamp_new_york) < '16:00:00'
                THEN 'BEFORE_CUTOFF'
            WHEN partner = 'PARTNER_B'
                 AND time(booking_timestamp_new_york) < '14:00:00'
                THEN 'BEFORE_CUTOFF'
            ELSE 'AFTER_CUTOFF'
        END AS cutoff_group
    FROM localized
)
SELECT
    *,
    CASE
        WHEN quote_to_execution_hours < 2 THEN '<2 hours'
        WHEN quote_to_execution_hours < 8 THEN '2-8 hours'
        WHEN quote_to_execution_hours < 24 THEN '8-24 hours'
        WHEN quote_to_execution_hours < 72 THEN '24-72 hours'
        ELSE '72+ hours'
    END AS duration_bucket,
    CASE
        WHEN quote_to_execution_hours < 2 THEN 1
        WHEN quote_to_execution_hours < 8 THEN 2
        WHEN quote_to_execution_hours < 24 THEN 3
        WHEN quote_to_execution_hours < 72 THEN 4
        ELSE 5
    END AS duration_bucket_order,
    CASE
        WHEN source_amount_usd < 5000 THEN '<$5k'
        WHEN source_amount_usd < 10000 THEN '$5k-$10k'
        WHEN source_amount_usd < 25000 THEN '$10k-$25k'
        ELSE '$25k+'
    END AS payment_size_bucket,
    CASE
        WHEN source_amount_usd < 5000 THEN 1
        WHEN source_amount_usd < 10000 THEN 2
        WHEN source_amount_usd < 25000 THEN 3
        ELSE 4
    END AS payment_size_bucket_order
FROM measured;

-- Normalized variance uses settled expected FX funding as the exposure base.
-- Signed bps preserves direction; absolute bps measures total magnitude.

DROP TABLE IF EXISTS analytics_partner;
CREATE TABLE analytics_partner AS
SELECT
    partner,
    COUNT(*) AS transaction_count,
    SUM(is_settled) AS settled_transaction_count,
    SUM(is_late) AS late_settlement_count,
    ROUND(100.0 * SUM(is_late) / NULLIF(SUM(is_settled), 0), 2)
        AS late_settlement_rate_pct,
    ROUND(AVG(settlement_delay_calendar_days), 2)
        AS average_timing_variance_days,
    ROUND(SUM(COALESCE(fx_execution_funding_variance_usd, 0)), 2)
        AS signed_fx_funding_variance_usd,
    ROUND(SUM(COALESCE(absolute_fx_funding_variance_usd, 0)), 2)
        AS absolute_fx_funding_variance_usd,
    ROUND(
        10000.0 * SUM(COALESCE(fx_execution_funding_variance_usd, 0))
            / NULLIF(
                SUM(
                    CASE WHEN is_settled = 1
                         THEN expected_fx_execution_source_amount_usd
                    END
                ),
                0
            ),
        2
    ) AS signed_normalized_fx_variance_bps,
    ROUND(
        10000.0 * SUM(COALESCE(absolute_fx_funding_variance_usd, 0))
            / NULLIF(
                SUM(
                    CASE WHEN is_settled = 1
                         THEN expected_fx_execution_source_amount_usd
                    END
                ),
                0
            ),
        2
    ) AS absolute_normalized_fx_variance_bps
FROM reconciliation_analytics_base
GROUP BY partner;

DROP TABLE IF EXISTS analytics_duration_bucket;
CREATE TABLE analytics_duration_bucket AS
SELECT
    duration_bucket,
    duration_bucket_order,
    COUNT(*) AS transaction_count,
    ROUND(AVG(quote_to_execution_hours), 2)
        AS average_quote_to_execution_hours,
    ROUND(SUM(fx_execution_funding_variance_usd), 2)
        AS signed_fx_funding_variance_usd,
    ROUND(SUM(absolute_fx_funding_variance_usd), 2)
        AS absolute_fx_funding_variance_usd,
    ROUND(AVG(absolute_fx_funding_variance_usd), 2)
        AS average_absolute_fx_variance_usd,
    ROUND(
        10000.0 * SUM(fx_execution_funding_variance_usd)
            / NULLIF(SUM(expected_fx_execution_source_amount_usd), 0),
        2
    ) AS signed_normalized_fx_variance_bps,
    ROUND(
        10000.0 * SUM(absolute_fx_funding_variance_usd)
            / NULLIF(SUM(expected_fx_execution_source_amount_usd), 0),
        2
    ) AS absolute_normalized_fx_variance_bps
FROM reconciliation_analytics_base
WHERE is_settled = 1
GROUP BY duration_bucket, duration_bucket_order;

DROP TABLE IF EXISTS analytics_cutoff;
CREATE TABLE analytics_cutoff AS
WITH grouped AS (
    SELECT
        partner,
        cutoff_group,
        COUNT(*) AS transaction_count,
        SUM(is_settled) AS settled_transaction_count,
        SUM(is_late) AS late_settlement_count,
        AVG(settlement_delay_calendar_days) AS average_timing_variance_days,
        AVG(quote_to_execution_hours) AS average_quote_to_execution_hours,
        SUM(COALESCE(fx_execution_funding_variance_usd, 0))
            AS signed_fx_funding_variance_usd,
        SUM(COALESCE(absolute_fx_funding_variance_usd, 0))
            AS absolute_fx_funding_variance_usd,
        SUM(
            CASE WHEN is_settled = 1
                 THEN expected_fx_execution_source_amount_usd
            END
        ) AS settled_expected_fx_funding_usd
    FROM reconciliation_analytics_base
    GROUP BY partner, cutoff_group
    UNION ALL
    SELECT
        'ALL_PARTNERS' AS partner,
        cutoff_group,
        COUNT(*) AS transaction_count,
        SUM(is_settled) AS settled_transaction_count,
        SUM(is_late) AS late_settlement_count,
        AVG(settlement_delay_calendar_days) AS average_timing_variance_days,
        AVG(quote_to_execution_hours) AS average_quote_to_execution_hours,
        SUM(COALESCE(fx_execution_funding_variance_usd, 0))
            AS signed_fx_funding_variance_usd,
        SUM(COALESCE(absolute_fx_funding_variance_usd, 0))
            AS absolute_fx_funding_variance_usd,
        SUM(
            CASE WHEN is_settled = 1
                 THEN expected_fx_execution_source_amount_usd
            END
        ) AS settled_expected_fx_funding_usd
    FROM reconciliation_analytics_base
    GROUP BY cutoff_group
)
SELECT
    partner,
    cutoff_group,
    transaction_count,
    settled_transaction_count,
    late_settlement_count,
    ROUND(
        100.0 * late_settlement_count
            / NULLIF(settled_transaction_count, 0),
        2
    ) AS late_settlement_rate_pct,
    ROUND(average_timing_variance_days, 2) AS average_timing_variance_days,
    ROUND(average_quote_to_execution_hours, 2)
        AS average_quote_to_execution_hours,
    ROUND(signed_fx_funding_variance_usd, 2)
        AS signed_fx_funding_variance_usd,
    ROUND(absolute_fx_funding_variance_usd, 2)
        AS absolute_fx_funding_variance_usd,
    ROUND(
        10000.0 * signed_fx_funding_variance_usd
            / NULLIF(settled_expected_fx_funding_usd, 0),
        2
    ) AS signed_normalized_fx_variance_bps,
    ROUND(
        10000.0 * absolute_fx_funding_variance_usd
            / NULLIF(settled_expected_fx_funding_usd, 0),
        2
    ) AS absolute_normalized_fx_variance_bps
FROM grouped;

DROP TABLE IF EXISTS analytics_payment_size;
CREATE TABLE analytics_payment_size AS
SELECT
    payment_size_bucket,
    payment_size_bucket_order,
    COUNT(*) AS transaction_count,
    SUM(is_settled) AS settled_transaction_count,
    ROUND(SUM(source_amount_usd), 2) AS total_source_volume_usd,
    ROUND(SUM(COALESCE(fx_execution_funding_variance_usd, 0)), 2)
        AS signed_fx_funding_variance_usd,
    ROUND(SUM(COALESCE(absolute_fx_funding_variance_usd, 0)), 2)
        AS absolute_fx_funding_variance_usd,
    ROUND(
        10000.0 * SUM(COALESCE(fx_execution_funding_variance_usd, 0))
            / NULLIF(
                SUM(
                    CASE WHEN is_settled = 1
                         THEN expected_fx_execution_source_amount_usd
                    END
                ),
                0
            ),
        2
    ) AS signed_normalized_fx_variance_bps,
    ROUND(
        10000.0 * SUM(COALESCE(absolute_fx_funding_variance_usd, 0))
            / NULLIF(
                SUM(
                    CASE WHEN is_settled = 1
                         THEN expected_fx_execution_source_amount_usd
                    END
                ),
                0
            ),
        2
    ) AS absolute_normalized_fx_variance_bps
FROM reconciliation_analytics_base
GROUP BY payment_size_bucket, payment_size_bucket_order;

.mode csv
.once data/analytics_partner.csv
SELECT * FROM analytics_partner ORDER BY partner;

.once data/analytics_duration_bucket.csv
SELECT *
FROM analytics_duration_bucket
ORDER BY duration_bucket_order;

.once data/analytics_cutoff.csv
SELECT *
FROM analytics_cutoff
ORDER BY CASE WHEN partner = 'ALL_PARTNERS' THEN 2 ELSE 1 END,
         partner,
         cutoff_group DESC;

.once data/analytics_payment_size.csv
SELECT *
FROM analytics_payment_size
ORDER BY payment_size_bucket_order;

.output stdout
.mode column

SELECT 'PARTNER' AS analytical_table, *
FROM analytics_partner
ORDER BY partner;

SELECT 'DURATION' AS analytical_table, *
FROM analytics_duration_bucket
ORDER BY duration_bucket_order;

SELECT 'CUTOFF' AS analytical_table, *
FROM analytics_cutoff
ORDER BY CASE WHEN partner = 'ALL_PARTNERS' THEN 2 ELSE 1 END,
         partner,
         cutoff_group DESC;

SELECT 'PAYMENT_SIZE' AS analytical_table, *
FROM analytics_payment_size
ORDER BY payment_size_bucket_order;
