-- Module 3: simplified educational client-money control
-- Run from the project root:
--   sqlite3 data/safeguarding.db < sql/safeguarding.sql
--
-- This is not a jurisdiction-specific legal safeguarding methodology.
-- The required amount is measured at the end-of-day New York cutoff after
-- same-day receipts, operating transfers, and value-date partner debits.

.bail on
.headers on
.mode csv

DROP TABLE IF EXISTS safeguarding_ledger;
CREATE TABLE safeguarding_ledger (
    payment_id TEXT NOT NULL,
    partner_instruction_id TEXT NOT NULL,
    customer_id TEXT NOT NULL,
    entity TEXT NOT NULL,
    partner TEXT NOT NULL,
    payment_method TEXT NOT NULL,
    booking_timestamp_utc TEXT NOT NULL,
    booking_date TEXT NOT NULL,
    source_currency TEXT NOT NULL,
    source_amount_usd REAL NOT NULL,
    destination_currency TEXT NOT NULL,
    quoted_fx_rate REAL NOT NULL,
    expected_partner_fee_usd REAL NOT NULL,
    expected_net_source_amount_usd REAL NOT NULL,
    expected_fx_execution_source_amount_usd REAL NOT NULL,
    quoted_destination_amount_cny REAL NOT NULL,
    expected_settlement_date TEXT NOT NULL,
    ledger_status TEXT NOT NULL
);

DROP TABLE IF EXISTS safeguarding_bank_transactions;
CREATE TABLE safeguarding_bank_transactions (
    bank_txn_id TEXT NOT NULL,
    partner_instruction_id TEXT NOT NULL,
    bank_reference TEXT NOT NULL,
    partner TEXT NOT NULL,
    payment_method TEXT NOT NULL,
    execution_timestamp_utc TEXT NOT NULL,
    execution_date TEXT NOT NULL,
    value_date TEXT NOT NULL,
    source_currency TEXT NOT NULL,
    fee_amount_usd REAL NOT NULL,
    fx_execution_source_amount_usd REAL NOT NULL,
    executed_fx_rate REAL NOT NULL,
    settlement_currency TEXT NOT NULL,
    settlement_amount_cny REAL NOT NULL,
    external_status TEXT NOT NULL
);

DROP TABLE IF EXISTS safeguarding_customer_balances;
CREATE TABLE safeguarding_customer_balances (
    balance_date TEXT NOT NULL,
    customer_id TEXT NOT NULL,
    entity TEXT NOT NULL,
    currency TEXT NOT NULL,
    opening_balance REAL NOT NULL,
    funding_inflows REAL NOT NULL,
    accepted_payment_debits REAL NOT NULL,
    customer_balance REAL NOT NULL
);

DROP TABLE IF EXISTS designated_account_balances;
CREATE TABLE designated_account_balances (
    balance_date TEXT NOT NULL,
    control_cutoff_timestamp_local TEXT NOT NULL,
    account_id TEXT NOT NULL,
    entity TEXT NOT NULL,
    currency TEXT NOT NULL,
    opening_balance_usd REAL NOT NULL,
    cleared_customer_receipts_usd REAL NOT NULL,
    operating_topups_usd REAL NOT NULL,
    partner_fx_funding_debits_usd REAL NOT NULL,
    partner_fee_debits_usd REAL NOT NULL,
    operating_sweeps_usd REAL NOT NULL,
    closing_balance_usd REAL NOT NULL
);

.import --skip 1 data/ledger.csv safeguarding_ledger
.import --skip 1 data/bank_transactions.csv safeguarding_bank_transactions
.import --skip 1 data/customer_balances.csv safeguarding_customer_balances
.import --skip 1 data/designated_account_balances.csv designated_account_balances

DROP VIEW IF EXISTS actual_settlement_dates;
CREATE VIEW actual_settlement_dates AS
SELECT
    partner_instruction_id,
    MIN(value_date) AS value_date
FROM safeguarding_bank_transactions
WHERE external_status = 'SETTLED'
GROUP BY partner_instruction_id;

DROP TABLE IF EXISTS safeguarding_results;
CREATE TABLE safeguarding_results AS
WITH control_dates AS (
    SELECT DISTINCT balance_date
    FROM safeguarding_customer_balances
),
customer_obligations AS (
    SELECT
        balance_date,
        ROUND(SUM(customer_balance), 2) AS customer_subledger_obligation_usd
    FROM safeguarding_customer_balances
    WHERE currency = 'USD'
    GROUP BY balance_date
),
pending_obligations AS (
    SELECT
        d.balance_date,
        COUNT(l.partner_instruction_id) AS pending_payment_count,
        ROUND(COALESCE(SUM(l.source_amount_usd), 0), 2)
            AS pending_outbound_obligation_usd
    FROM control_dates AS d
    LEFT JOIN safeguarding_ledger AS l
        ON l.ledger_status = 'BOOKED'
       AND l.source_currency = 'USD'
       AND l.booking_date <= d.balance_date
    LEFT JOIN actual_settlement_dates AS s
        ON s.partner_instruction_id = l.partner_instruction_id
    WHERE s.value_date IS NULL OR s.value_date > d.balance_date
    GROUP BY d.balance_date
),
measured AS (
    SELECT
        a.balance_date,
        a.control_cutoff_timestamp_local,
        c.customer_subledger_obligation_usd,
        p.pending_payment_count,
        p.pending_outbound_obligation_usd,
        ROUND(
            c.customer_subledger_obligation_usd
            + p.pending_outbound_obligation_usd,
            2
        ) AS required_client_money_usd,
        a.closing_balance_usd AS designated_account_balance_usd,
        ROUND(
            a.closing_balance_usd
            - c.customer_subledger_obligation_usd
            - p.pending_outbound_obligation_usd,
            2
        ) AS surplus_shortfall_usd,
        a.opening_balance_usd,
        a.cleared_customer_receipts_usd,
        a.operating_topups_usd,
        a.partner_fx_funding_debits_usd,
        a.partner_fee_debits_usd,
        a.operating_sweeps_usd
    FROM designated_account_balances AS a
    JOIN customer_obligations AS c
        ON c.balance_date = a.balance_date
    JOIN pending_obligations AS p
        ON p.balance_date = a.balance_date
)
SELECT
    *,
    CASE
        WHEN surplus_shortfall_usd >= 0 THEN 'PASS'
        ELSE 'SHORTFALL'
    END AS control_status
FROM measured;

.headers on
.mode csv
.once data/safeguarding_results.csv
SELECT *
FROM safeguarding_results
ORDER BY balance_date;

.output stdout
.mode column
SELECT
    control_status,
    COUNT(*) AS control_days,
    ROUND(MIN(surplus_shortfall_usd), 2) AS minimum_surplus_shortfall_usd,
    ROUND(MAX(surplus_shortfall_usd), 2) AS maximum_surplus_shortfall_usd
FROM safeguarding_results
GROUP BY control_status
ORDER BY control_status;
