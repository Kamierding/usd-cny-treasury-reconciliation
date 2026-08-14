-- Module 2: USD-CNY payment reconciliation
-- Run from the project root:
--   sqlite3 data/reconciliation.db < sql/reconciliation.sql
--
-- Reconciliation state answers whether the payment settled as expected.
-- Economic variance columns separately attribute fee and FX funding economics.

.bail on
.headers on
.mode csv

.read sql/reconciliation_schema.sql

.import --skip 1 data/ledger.csv ledger
.import --skip 1 data/bank_transactions.csv bank_transactions

DROP TABLE IF EXISTS reconciliation_parameters;
CREATE TABLE reconciliation_parameters AS
SELECT
    '2025-03-31' AS as_of_date,
    0.00 AS settlement_tolerance_cny;

.read sql/reconciliation_logic.sql

.headers on
.mode csv
.once data/reconciliation_results.csv
SELECT *
FROM reconciliation_results
ORDER BY partner_instruction_id;

.output stdout
.mode column
SELECT
    reconciliation_state,
    COUNT(*) AS payment_count,
    ROUND(SUM(ABS(COALESCE(fx_execution_funding_variance_usd, 0))), 2)
        AS absolute_fx_funding_variance_usd,
    ROUND(SUM(ABS(COALESCE(fee_variance_usd, 0))), 2)
        AS absolute_fee_variance_usd,
    SUM(CASE WHEN settlement_delay_calendar_days > 0 THEN 1 ELSE 0 END)
        AS settled_late_count
FROM reconciliation_results
GROUP BY reconciliation_state
ORDER BY reconciliation_state;
