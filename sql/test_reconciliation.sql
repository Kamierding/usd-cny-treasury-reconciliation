-- Isolated deterministic tests for Module 2 reconciliation precedence.
-- These fixtures are software tests only; they never enter the analytical CSVs.
-- Run from the project root:
--   sqlite3 :memory: < sql/test_reconciliation.sql

.bail on
.headers on
.mode column

.read sql/reconciliation_schema.sql

INSERT INTO ledger (
    payment_id,
    partner_instruction_id,
    customer_id,
    entity,
    partner,
    payment_method,
    booking_timestamp_utc,
    booking_date,
    source_currency,
    source_amount_usd,
    destination_currency,
    quoted_fx_rate,
    expected_partner_fee_usd,
    expected_net_source_amount_usd,
    expected_fx_execution_source_amount_usd,
    quoted_destination_amount_cny,
    expected_settlement_date,
    ledger_status
)
VALUES
    ('PAY-MATCH-E', 'CASE_MATCHED_ECON', 'C-01', 'GLOBALPAY_US',
     'PARTNER_A', 'LOCAL_BANK_TRANSFER', '2025-03-07T14:00:00Z',
     '2025-03-07', 'USD', 106.00, 'CNY', 7.00, 6.00, 100.00,
     100.00, 700.00, '2025-03-10', 'BOOKED'),
    ('PAY-MATCH-L', 'CASE_MATCHED_LATE', 'C-02', 'GLOBALPAY_US',
     'PARTNER_A', 'LOCAL_BANK_TRANSFER', '2025-03-07T15:00:00Z',
     '2025-03-07', 'USD', 106.00, 'CNY', 7.00, 6.00, 100.00,
     100.00, 700.00, '2025-03-10', 'BOOKED'),
    ('PAY-PENDING', 'CASE_PENDING', 'C-03', 'GLOBALPAY_US',
     'PARTNER_B', 'SWIFT', '2025-03-31T15:00:00Z', '2025-03-31',
     'USD', 106.00, 'CNY', 7.00, 6.00, 100.00, 100.00, 700.00,
     '2025-04-02', 'BOOKED'),
    ('PAY-OVERDUE', 'CASE_OVERDUE', 'C-04', 'GLOBALPAY_US',
     'PARTNER_B', 'SWIFT', '2025-03-17T15:00:00Z', '2025-03-17',
     'USD', 106.00, 'CNY', 7.00, 6.00, 100.00, 100.00, 700.00,
     '2025-03-20', 'BOOKED'),
    ('PAY-AMOUNT', 'CASE_AMOUNT', 'C-05', 'GLOBALPAY_US',
     'PARTNER_A', 'LOCAL_BANK_TRANSFER', '2025-03-07T14:00:00Z',
     '2025-03-07', 'USD', 106.00, 'CNY', 7.00, 6.00, 100.00,
     100.00, 700.00, '2025-03-10', 'BOOKED'),
    ('PAY-DUP-L1', 'CASE_DUP_LEDGER', 'C-06', 'GLOBALPAY_US',
     'PARTNER_A', 'LOCAL_BANK_TRANSFER', '2025-03-31T14:00:00Z',
     '2025-03-31', 'USD', 106.00, 'CNY', 7.00, 6.00, 100.00,
     100.00, 700.00, '2025-04-02', 'BOOKED'),
    ('PAY-DUP-L2', 'CASE_DUP_LEDGER', 'C-06', 'GLOBALPAY_US',
     'PARTNER_A', 'LOCAL_BANK_TRANSFER', '2025-03-31T14:00:00Z',
     '2025-03-31', 'USD', 106.00, 'CNY', 7.00, 6.00, 100.00,
     100.00, 700.00, '2025-04-02', 'BOOKED'),
    ('PAY-DUP-B', 'CASE_DUP_BANK', 'C-07', 'GLOBALPAY_US',
     'PARTNER_B', 'SWIFT', '2025-03-07T14:00:00Z', '2025-03-07',
     'USD', 106.00, 'CNY', 7.00, 6.00, 100.00, 100.00, 700.00,
     '2025-03-10', 'BOOKED');

INSERT INTO bank_transactions (
    bank_txn_id,
    partner_instruction_id,
    bank_reference,
    partner,
    payment_method,
    execution_timestamp_utc,
    execution_date,
    value_date,
    source_currency,
    fee_amount_usd,
    fx_execution_source_amount_usd,
    executed_fx_rate,
    settlement_currency,
    settlement_amount_cny,
    external_status
)
VALUES
    ('BNK-MATCH-E', 'CASE_MATCHED_ECON', 'REF-MATCH-E', 'PARTNER_A',
     'LOCAL_BANK_TRANSFER', '2025-03-07T16:00:00Z', '2025-03-07',
     '2025-03-10', 'USD', 6.00, 101.00, 6.930693, 'CNY', 700.00,
     'SETTLED'),
    ('BNK-MATCH-L', 'CASE_MATCHED_LATE', 'REF-MATCH-L', 'PARTNER_A',
     'LOCAL_BANK_TRANSFER', '2025-03-11T16:00:00Z', '2025-03-11',
     '2025-03-12', 'USD', 6.00, 100.00, 7.00, 'CNY', 700.00,
     'SETTLED'),
    -- Deliberate CNY difference used only to test UNEXPLAINED_AMOUNT.
    ('BNK-AMOUNT', 'CASE_AMOUNT', 'REF-AMOUNT', 'PARTNER_A',
     'LOCAL_BANK_TRANSFER', '2025-03-07T16:00:00Z', '2025-03-07',
     '2025-03-10', 'USD', 6.00, 100.15, 7.00, 'CNY', 701.00,
     'SETTLED'),
    -- External-only row used only to test MISSING_LEDGER.
    ('BNK-ORPHAN', 'CASE_MISSING_LEDGER', 'REF-ORPHAN', 'PARTNER_B',
     'SWIFT', '2025-03-14T16:00:00Z', '2025-03-14', '2025-03-17',
     'USD', 6.00, 100.00, 7.00, 'CNY', 700.00, 'SETTLED'),
    ('BNK-DUP-1', 'CASE_DUP_BANK', 'REF-DUP-1', 'PARTNER_B', 'SWIFT',
     '2025-03-07T16:00:00Z', '2025-03-07', '2025-03-10', 'USD',
     6.00, 100.00, 7.00, 'CNY', 700.00, 'SETTLED'),
    ('BNK-DUP-2', 'CASE_DUP_BANK', 'REF-DUP-2', 'PARTNER_B', 'SWIFT',
     '2025-03-07T16:01:00Z', '2025-03-07', '2025-03-10', 'USD',
     6.00, 100.00, 7.00, 'CNY', 700.00, 'SETTLED');

CREATE TABLE reconciliation_parameters AS
SELECT
    '2025-03-31' AS as_of_date,
    0.00 AS settlement_tolerance_cny;

.read sql/reconciliation_logic.sql

CREATE TABLE test_assertions (
    test_name TEXT NOT NULL,
    passed INTEGER NOT NULL CHECK (passed = 1)
);

INSERT INTO test_assertions
SELECT 'matched_with_fx_variance',
       reconciliation_state = 'MATCHED'
       AND fee_variance_usd = 0
       AND fx_execution_funding_variance_usd = 1
FROM reconciliation_results
WHERE partner_instruction_id = 'CASE_MATCHED_ECON';

INSERT INTO test_assertions
SELECT 'late_settlement_remains_matched',
       reconciliation_state = 'MATCHED'
       AND settlement_delay_calendar_days = 2
FROM reconciliation_results
WHERE partner_instruction_id = 'CASE_MATCHED_LATE';

INSERT INTO test_assertions
SELECT 'future_due_is_pending',
       reconciliation_state = 'TIMING_PENDING'
       AND aging_days IS NULL
FROM reconciliation_results
WHERE partner_instruction_id = 'CASE_PENDING';

INSERT INTO test_assertions
SELECT 'past_due_is_overdue',
       reconciliation_state = 'OVERDUE_SETTLEMENT'
       AND aging_days = 11
       AND aging_bucket = '>7 days'
FROM reconciliation_results
WHERE partner_instruction_id = 'CASE_OVERDUE';

INSERT INTO test_assertions
SELECT 'cny_difference_is_unexplained',
       reconciliation_state = 'UNEXPLAINED_AMOUNT'
       AND settlement_variance_cny = 1
FROM reconciliation_results
WHERE partner_instruction_id = 'CASE_AMOUNT';

INSERT INTO test_assertions
SELECT 'external_only_is_missing_ledger',
       reconciliation_state = 'MISSING_LEDGER'
FROM reconciliation_results
WHERE partner_instruction_id = 'CASE_MISSING_LEDGER';

INSERT INTO test_assertions
SELECT 'duplicate_ledger_precedes_pending',
       reconciliation_state = 'DUPLICATE'
       AND ledger_record_count = 2
       AND bank_record_count = 0
FROM reconciliation_results
WHERE partner_instruction_id = 'CASE_DUP_LEDGER';

INSERT INTO test_assertions
SELECT 'duplicate_bank_precedes_amount_checks',
       reconciliation_state = 'DUPLICATE'
       AND ledger_record_count = 1
       AND bank_record_count = 2
FROM reconciliation_results
WHERE partner_instruction_id = 'CASE_DUP_BANK';

INSERT INTO test_assertions
SELECT 'all_expected_states_are_covered',
       COUNT(DISTINCT reconciliation_state) = 6
FROM reconciliation_results;

SELECT test_name, 'PASS' AS result
FROM test_assertions
ORDER BY test_name;
