-- Production-invariant checks for the Module 3 daily control.
-- Run after sql/safeguarding.sql from the project root:
--   sqlite3 data/safeguarding.db < sql/test_safeguarding.sql

.bail on
.headers on
.mode column

DROP TABLE IF EXISTS temp.safeguarding_test_assertions;
CREATE TEMP TABLE safeguarding_test_assertions (
    test_name TEXT NOT NULL,
    passed INTEGER NOT NULL CHECK (passed = 1)
);

INSERT INTO safeguarding_test_assertions
SELECT
    'one_control_per_customer_balance_date',
    (SELECT COUNT(*) FROM safeguarding_results)
        = (SELECT COUNT(DISTINCT balance_date)
           FROM safeguarding_customer_balances);

INSERT INTO safeguarding_test_assertions
SELECT
    'required_amount_equals_customer_plus_pending',
    NOT EXISTS (
        SELECT 1
        FROM safeguarding_results
        WHERE ROUND(
            required_client_money_usd
            - customer_subledger_obligation_usd
            - pending_outbound_obligation_usd,
            2
        ) != 0
    );

INSERT INTO safeguarding_test_assertions
SELECT
    'pending_uses_actual_value_date_cutoff',
    NOT EXISTS (
        SELECT 1
        FROM safeguarding_results AS r
        WHERE r.pending_payment_count != (
                  SELECT COUNT(*)
                  FROM safeguarding_ledger AS l
                  WHERE l.ledger_status = 'BOOKED'
                    AND l.booking_date <= r.balance_date
                    AND NOT EXISTS (
                        SELECT 1
                        FROM safeguarding_bank_transactions AS b
                        WHERE b.partner_instruction_id
                              = l.partner_instruction_id
                          AND b.external_status = 'SETTLED'
                          AND b.value_date <= r.balance_date
                    )
              )
           OR ROUND(r.pending_outbound_obligation_usd, 2) != ROUND(
                  COALESCE(
                      (
                          SELECT SUM(l.source_amount_usd)
                          FROM safeguarding_ledger AS l
                          WHERE l.ledger_status = 'BOOKED'
                            AND l.booking_date <= r.balance_date
                            AND NOT EXISTS (
                                SELECT 1
                                FROM safeguarding_bank_transactions AS b
                                WHERE b.partner_instruction_id
                                      = l.partner_instruction_id
                                  AND b.external_status = 'SETTLED'
                                  AND b.value_date <= r.balance_date
                            )
                      ),
                      0
                  ),
                  2
              )
    );

INSERT INTO safeguarding_test_assertions
SELECT
    'partner_debits_use_actual_value_date',
    NOT EXISTS (
        SELECT 1
        FROM designated_account_balances AS a
        WHERE ROUND(a.partner_fx_funding_debits_usd, 2) != ROUND(
                  COALESCE(
                      (
                          SELECT SUM(b.fx_execution_source_amount_usd)
                          FROM safeguarding_bank_transactions AS b
                          WHERE b.external_status = 'SETTLED'
                            AND b.value_date = a.balance_date
                      ),
                      0
                  ),
                  2
              )
           OR ROUND(a.partner_fee_debits_usd, 2) != ROUND(
                  COALESCE(
                      (
                          SELECT SUM(b.fee_amount_usd)
                          FROM safeguarding_bank_transactions AS b
                          WHERE b.external_status = 'SETTLED'
                            AND b.value_date = a.balance_date
                      ),
                      0
                  ),
                  2
              )
    );

INSERT INTO safeguarding_test_assertions
SELECT
    'surplus_shortfall_equals_actual_minus_required',
    NOT EXISTS (
        SELECT 1
        FROM safeguarding_results
        WHERE ROUND(
            surplus_shortfall_usd
            - designated_account_balance_usd
            + required_client_money_usd,
            2
        ) != 0
    );

INSERT INTO safeguarding_test_assertions
SELECT
    'account_balance_rolls_daily',
    NOT EXISTS (
        SELECT 1
        FROM designated_account_balances AS current_day
        JOIN designated_account_balances AS prior_day
          ON prior_day.balance_date = date(current_day.balance_date, '-1 day')
        WHERE ROUND(
            current_day.opening_balance_usd - prior_day.closing_balance_usd,
            2
        ) != 0
           OR ROUND(
                current_day.closing_balance_usd
                - current_day.opening_balance_usd
                - current_day.cleared_customer_receipts_usd
                - current_day.operating_topups_usd
                + current_day.partner_fx_funding_debits_usd
                + current_day.partner_fee_debits_usd
                + current_day.operating_sweeps_usd,
                2
           ) != 0
    );

INSERT INTO safeguarding_test_assertions
SELECT
    'operating_transfers_use_us_banking_days',
    NOT EXISTS (
        SELECT 1
        FROM designated_account_balances
        WHERE operating_topups_usd + operating_sweeps_usd > 0
          AND (
              CAST(strftime('%w', balance_date) AS INTEGER) IN (0, 6)
              OR balance_date IN ('2025-01-01', '2025-01-20', '2025-02-17')
          )
    );

INSERT INTO safeguarding_test_assertions
SELECT
    'control_status_follows_signed_difference',
    NOT EXISTS (
        SELECT 1
        FROM safeguarding_results
        WHERE control_status != CASE
            WHEN surplus_shortfall_usd >= 0 THEN 'PASS'
            ELSE 'SHORTFALL'
        END
    );

INSERT INTO safeguarding_test_assertions
SELECT
    'cutoff_is_new_york_end_of_day',
    NOT EXISTS (
        SELECT 1
        FROM safeguarding_results
        WHERE substr(control_cutoff_timestamp_local, 12, 8) != '23:59:59'
    );

SELECT test_name, 'PASS' AS result
FROM safeguarding_test_assertions
ORDER BY test_name;
