-- Shared staging schema for analytical reconciliation and isolated SQL tests.

DROP TABLE IF EXISTS ledger;
CREATE TABLE ledger (
    payment_id TEXT,
    partner_instruction_id TEXT,
    customer_id TEXT,
    entity TEXT,
    partner TEXT,
    payment_method TEXT,
    booking_timestamp_utc TEXT,
    booking_date TEXT,
    source_currency TEXT,
    source_amount_usd NUMERIC,
    destination_currency TEXT,
    quoted_fx_rate NUMERIC,
    expected_partner_fee_usd NUMERIC,
    expected_net_source_amount_usd NUMERIC,
    expected_fx_execution_source_amount_usd NUMERIC,
    quoted_destination_amount_cny NUMERIC,
    expected_settlement_date TEXT,
    ledger_status TEXT
);

DROP TABLE IF EXISTS bank_transactions;
CREATE TABLE bank_transactions (
    bank_txn_id TEXT,
    partner_instruction_id TEXT,
    bank_reference TEXT,
    partner TEXT,
    payment_method TEXT,
    execution_timestamp_utc TEXT,
    execution_date TEXT,
    value_date TEXT,
    source_currency TEXT,
    fee_amount_usd NUMERIC,
    fx_execution_source_amount_usd NUMERIC,
    executed_fx_rate NUMERIC,
    settlement_currency TEXT,
    settlement_amount_cny NUMERIC,
    external_status TEXT
);
