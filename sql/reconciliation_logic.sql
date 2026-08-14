-- Reusable reconciliation logic.
-- Requires ledger, bank_transactions, and reconciliation_parameters tables.

-- Variance sign conventions:
--   fee variance = actual - expected; positive means higher partner cost.
--   FX funding variance = actual - expected; positive means more USD required.
--   settlement variance = actual - expected; positive means excess CNY settled.
--   settlement delay = actual value date - expected date; positive means late.

DROP VIEW IF EXISTS ledger_grouped;
CREATE VIEW ledger_grouped AS
SELECT
    partner_instruction_id,
    COUNT(*) AS ledger_record_count,
    MIN(payment_id) AS payment_id,
    MIN(customer_id) AS customer_id,
    MIN(entity) AS entity,
    MIN(partner) AS ledger_partner,
    MIN(payment_method) AS ledger_payment_method,
    MIN(booking_timestamp_utc) AS booking_timestamp_utc,
    MIN(booking_date) AS booking_date,
    MIN(source_currency) AS source_currency,
    MIN(source_amount_usd) AS source_amount_usd,
    MIN(destination_currency) AS destination_currency,
    MIN(quoted_fx_rate) AS quoted_fx_rate,
    MIN(expected_partner_fee_usd) AS expected_partner_fee_usd,
    MIN(expected_net_source_amount_usd) AS expected_net_source_amount_usd,
    MIN(expected_fx_execution_source_amount_usd)
        AS expected_fx_execution_source_amount_usd,
    MIN(quoted_destination_amount_cny) AS expected_settlement_amount_cny,
    MIN(expected_settlement_date) AS expected_settlement_date,
    MIN(ledger_status) AS ledger_status
FROM ledger
GROUP BY partner_instruction_id;

DROP VIEW IF EXISTS bank_grouped;
CREATE VIEW bank_grouped AS
SELECT
    partner_instruction_id,
    COUNT(*) AS bank_record_count,
    MIN(bank_txn_id) AS bank_txn_id,
    MIN(bank_reference) AS bank_reference,
    MIN(partner) AS bank_partner,
    MIN(payment_method) AS bank_payment_method,
    MIN(execution_timestamp_utc) AS execution_timestamp_utc,
    MIN(execution_date) AS execution_date,
    MIN(value_date) AS value_date,
    MIN(source_currency) AS funding_currency,
    MIN(fee_amount_usd) AS actual_fee_amount_usd,
    MIN(fx_execution_source_amount_usd)
        AS actual_fx_execution_source_amount_usd,
    MIN(executed_fx_rate) AS executed_fx_rate,
    MIN(settlement_currency) AS settlement_currency,
    MIN(settlement_amount_cny) AS actual_settlement_amount_cny,
    MIN(external_status) AS external_status
FROM bank_transactions
GROUP BY partner_instruction_id;

DROP VIEW IF EXISTS reconciliation_universe;
CREATE VIEW reconciliation_universe AS
SELECT partner_instruction_id FROM ledger_grouped
UNION
SELECT partner_instruction_id FROM bank_grouped;

DROP VIEW IF EXISTS reconciliation_base;
CREATE VIEW reconciliation_base AS
SELECT
    u.partner_instruction_id,
    l.payment_id,
    b.bank_txn_id,
    b.bank_reference,
    l.customer_id,
    l.entity,
    COALESCE(l.ledger_partner, b.bank_partner) AS partner,
    COALESCE(l.ledger_payment_method, b.bank_payment_method) AS payment_method,
    COALESCE(l.ledger_record_count, 0) AS ledger_record_count,
    COALESCE(b.bank_record_count, 0) AS bank_record_count,
    l.booking_timestamp_utc,
    l.booking_date,
    l.expected_settlement_date,
    b.execution_timestamp_utc,
    b.execution_date,
    b.value_date,
    l.source_currency,
    l.source_amount_usd,
    l.destination_currency,
    l.quoted_fx_rate,
    b.executed_fx_rate,
    l.expected_partner_fee_usd,
    b.actual_fee_amount_usd,
    l.expected_net_source_amount_usd,
    l.expected_fx_execution_source_amount_usd,
    b.actual_fx_execution_source_amount_usd,
    l.expected_settlement_amount_cny,
    b.actual_settlement_amount_cny,
    l.ledger_status,
    b.external_status,
    p.as_of_date,
    p.settlement_tolerance_cny
FROM reconciliation_universe u
LEFT JOIN ledger_grouped l USING (partner_instruction_id)
LEFT JOIN bank_grouped b USING (partner_instruction_id)
CROSS JOIN reconciliation_parameters p;

DROP TABLE IF EXISTS reconciliation_results;
CREATE TABLE reconciliation_results AS
WITH measured AS (
    SELECT
        *,
        ROUND(actual_fee_amount_usd - expected_partner_fee_usd, 2)
            AS fee_variance_usd,
        ROUND(
            actual_fx_execution_source_amount_usd
                - expected_fx_execution_source_amount_usd,
            2
        ) AS fx_execution_funding_variance_usd,
        ROUND(
            actual_settlement_amount_cny - expected_settlement_amount_cny,
            2
        ) AS settlement_variance_cny,
        CASE
            WHEN value_date IS NULL OR expected_settlement_date IS NULL THEN NULL
            ELSE CAST(
                julianday(value_date) - julianday(expected_settlement_date)
                AS INTEGER
            )
        END AS settlement_delay_calendar_days
    FROM reconciliation_base
),
stated AS (
    SELECT
        *,
        CASE
            WHEN ledger_record_count > 1 OR bank_record_count > 1
                THEN 'DUPLICATE'
            WHEN ledger_record_count = 0 AND bank_record_count > 0
                THEN 'MISSING_LEDGER'
            WHEN ledger_record_count > 0 AND bank_record_count = 0
                 AND expected_settlement_date > as_of_date
                THEN 'TIMING_PENDING'
            WHEN ledger_record_count > 0 AND bank_record_count = 0
                 AND expected_settlement_date <= as_of_date
                THEN 'OVERDUE_SETTLEMENT'
            WHEN actual_settlement_amount_cny IS NULL
                THEN 'UNEXPLAINED_AMOUNT'
            WHEN ABS(COALESCE(settlement_variance_cny, 0))
                 > settlement_tolerance_cny
                THEN 'UNEXPLAINED_AMOUNT'
            ELSE 'MATCHED'
        END AS reconciliation_state
    FROM measured
),
aged AS (
    SELECT
        *,
        CASE
            WHEN reconciliation_state = 'OVERDUE_SETTLEMENT'
                THEN MAX(
                    0,
                    CAST(
                        julianday(as_of_date)
                            - julianday(expected_settlement_date)
                        AS INTEGER
                    )
                )
            WHEN reconciliation_state IN (
                'UNEXPLAINED_AMOUNT',
                'MISSING_LEDGER',
                'DUPLICATE'
            )
                THEN MAX(
                    0,
                    CAST(
                        julianday(as_of_date)
                            - julianday(
                                COALESCE(
                                    value_date,
                                    expected_settlement_date,
                                    booking_date
                                )
                            )
                        AS INTEGER
                    )
                )
            ELSE NULL
        END AS aging_days
    FROM stated
)
SELECT
    partner_instruction_id,
    payment_id,
    bank_txn_id,
    bank_reference,
    customer_id,
    entity,
    partner,
    payment_method,
    ledger_record_count,
    bank_record_count,
    booking_timestamp_utc,
    booking_date,
    expected_settlement_date,
    execution_timestamp_utc,
    execution_date,
    value_date,
    source_currency,
    source_amount_usd,
    destination_currency,
    quoted_fx_rate,
    executed_fx_rate,
    expected_partner_fee_usd,
    actual_fee_amount_usd,
    expected_net_source_amount_usd,
    expected_fx_execution_source_amount_usd,
    actual_fx_execution_source_amount_usd,
    expected_settlement_amount_cny,
    actual_settlement_amount_cny,
    fee_variance_usd,
    fx_execution_funding_variance_usd,
    settlement_variance_cny,
    settlement_delay_calendar_days,
    reconciliation_state,
    aging_days,
    CASE
        WHEN aging_days IS NULL THEN NULL
        WHEN aging_days <= 1 THEN '0-1 day'
        WHEN aging_days <= 3 THEN '2-3 days'
        WHEN aging_days <= 7 THEN '4-7 days'
        ELSE '>7 days'
    END AS aging_bucket,
    ledger_status,
    external_status,
    as_of_date
FROM aged;

CREATE INDEX IF NOT EXISTS idx_reconciliation_state
    ON reconciliation_results (reconciliation_state);
CREATE INDEX IF NOT EXISTS idx_reconciliation_partner
    ON reconciliation_results (partner);
