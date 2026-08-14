-- Module 3.1: safeguarding analysis
-- Requires the production tables created by sql/safeguarding.sql.
-- Run from the project root:
--   sqlite3 data/safeguarding.db < sql/safeguarding_analysis.sql

.bail on
.headers on

-- Explicit US banking holidays for the current 2025 simulation period.
-- Add any extra holidays here if the source simulation used --us-holiday.
DROP TABLE IF EXISTS safeguarding_analysis_us_holidays;
CREATE TABLE safeguarding_analysis_us_holidays (
    holiday_date TEXT PRIMARY KEY,
    holiday_name TEXT NOT NULL
);
INSERT INTO safeguarding_analysis_us_holidays VALUES
    ('2025-01-01', 'New Year''s Day'),
    ('2025-01-20', 'Martin Luther King Jr. Day'),
    ('2025-02-17', 'Presidents Day');

DROP VIEW IF EXISTS safeguarding_analysis_calendar;
CREATE VIEW safeguarding_analysis_calendar AS
WITH RECURSIVE bounds AS (
    SELECT
        MIN(balance_date) AS start_date,
        date(MAX(balance_date), '+10 days') AS end_date
    FROM safeguarding_results
),
calendar(calendar_date, end_date) AS (
    SELECT start_date, end_date FROM bounds
    UNION ALL
    SELECT date(calendar_date, '+1 day'), end_date
    FROM calendar
    WHERE calendar_date < end_date
)
SELECT
    c.calendar_date,
    CASE
        WHEN CAST(strftime('%w', c.calendar_date) AS INTEGER) IN (0, 6)
            THEN 0
        WHEN h.holiday_date IS NOT NULL THEN 0
        ELSE 1
    END AS is_us_banking_day,
    CASE
        WHEN h.holiday_date IS NOT NULL THEN 'US_HOLIDAY'
        WHEN CAST(strftime('%w', c.calendar_date) AS INTEGER) IN (0, 6)
            THEN 'WEEKEND'
        ELSE 'US_BANKING_DAY'
    END AS day_type,
    h.holiday_name
FROM calendar AS c
LEFT JOIN safeguarding_analysis_us_holidays AS h
    ON h.holiday_date = c.calendar_date;

-- Per-payment residual after the external fee and FX funding debit. Positive
-- residuals schedule sweeps; negative residuals schedule operating top-ups.
DROP TABLE IF EXISTS safeguarding_settlement_residuals;
CREATE TABLE safeguarding_settlement_residuals AS
WITH residuals AS (
    SELECT
        b.value_date,
        l.payment_id,
        l.partner_instruction_id,
        l.customer_id,
        l.partner,
        l.payment_method,
        l.source_amount_usd,
        b.fee_amount_usd,
        b.fx_execution_source_amount_usd,
        ROUND(
            l.source_amount_usd
            - b.fee_amount_usd
            - b.fx_execution_source_amount_usd,
            2
        ) AS execution_residual_usd
    FROM safeguarding_bank_transactions AS b
    JOIN safeguarding_ledger AS l
        ON l.partner_instruction_id = b.partner_instruction_id
    WHERE b.external_status = 'SETTLED'
),
scheduled AS (
    SELECT
        r.*,
        (
            SELECT MIN(c.calendar_date)
            FROM safeguarding_analysis_calendar AS c
            WHERE c.calendar_date > r.value_date
              AND c.is_us_banking_day = 1
        ) AS scheduled_operating_date
    FROM residuals AS r
)
SELECT
    s.*,
    CASE
        WHEN execution_residual_usd < 0 THEN 'TOP_UP'
        WHEN execution_residual_usd > 0 THEN 'SWEEP'
        ELSE 'NONE'
    END AS operating_action,
    ABS(execution_residual_usd) AS operating_action_amount_usd,
    CAST(
        julianday(scheduled_operating_date) - julianday(value_date)
        AS INTEGER
    ) AS calendar_days_to_operating_action,
    (
        SELECT COUNT(*)
        FROM safeguarding_analysis_calendar AS c
        WHERE c.calendar_date > s.value_date
          AND c.calendar_date < s.scheduled_operating_date
          AND c.day_type = 'WEEKEND'
    ) AS intervening_weekend_days,
    (
        SELECT COUNT(*)
        FROM safeguarding_analysis_calendar AS c
        WHERE c.calendar_date > s.value_date
          AND c.calendar_date < s.scheduled_operating_date
          AND c.day_type = 'US_HOLIDAY'
    ) AS intervening_us_holidays
FROM scheduled AS s;

-- Aggregate scheduled operating adjustments independently, then compare them
-- with the account roll-forward amounts actually posted on each date.
DROP TABLE IF EXISTS safeguarding_operating_schedule;
CREATE TABLE safeguarding_operating_schedule AS
SELECT
    scheduled_operating_date,
    ROUND(SUM(CASE WHEN execution_residual_usd < 0
                   THEN -execution_residual_usd ELSE 0 END), 2)
        AS scheduled_topup_usd,
    ROUND(SUM(CASE WHEN execution_residual_usd > 0
                   THEN execution_residual_usd ELSE 0 END), 2)
        AS scheduled_sweep_usd,
    COUNT(CASE WHEN execution_residual_usd < 0 THEN 1 END)
        AS topup_payment_count,
    COUNT(CASE WHEN execution_residual_usd > 0 THEN 1 END)
        AS sweep_payment_count
FROM safeguarding_settlement_residuals
GROUP BY scheduled_operating_date;

-- A causal date is a settlement date whose net execution residual is negative.
DROP TABLE IF EXISTS safeguarding_shortfall_cause_dates;
CREATE TABLE safeguarding_shortfall_cause_dates AS
WITH grouped AS (
    SELECT
        value_date,
        scheduled_operating_date,
        COUNT(*) AS settlement_count,
        COUNT(CASE WHEN execution_residual_usd < 0 THEN 1 END)
            AS negative_residual_settlement_count,
        COUNT(CASE WHEN execution_residual_usd > 0 THEN 1 END)
            AS positive_offset_settlement_count,
        ROUND(SUM(execution_residual_usd), 2) AS net_execution_residual_usd,
        ROUND(SUM(CASE WHEN execution_residual_usd < 0
                       THEN -execution_residual_usd ELSE 0 END), 2)
            AS negative_residual_amount_usd,
        ROUND(SUM(CASE WHEN execution_residual_usd > 0
                       THEN execution_residual_usd ELSE 0 END), 2)
            AS positive_offset_amount_usd,
        MAX(calendar_days_to_operating_action)
            AS calendar_days_to_operating_action,
        MAX(intervening_weekend_days) AS intervening_weekend_days,
        MAX(intervening_us_holidays) AS intervening_us_holidays
    FROM safeguarding_settlement_residuals
    GROUP BY value_date, scheduled_operating_date
    HAVING ROUND(SUM(execution_residual_usd), 2) < 0
),
new_date_residuals AS (
    SELECT value_date, ROUND(SUM(execution_residual_usd), 2) AS net_residual_usd
    FROM safeguarding_settlement_residuals
    GROUP BY value_date
)
SELECT
    g.*,
    ABS(g.net_execution_residual_usd) AS initial_shortfall_amount_usd,
    r.control_status AS control_status_on_value_date,
    a.operating_topups_usd AS posted_topup_usd,
    a.operating_sweeps_usd AS posted_sweep_usd,
    os.scheduled_topup_usd,
    os.scheduled_sweep_usd,
    CASE
        WHEN a.balance_date IS NULL THEN 'OUTSIDE_AS_OF'
        WHEN ROUND(a.operating_topups_usd - os.scheduled_topup_usd, 2) = 0
         AND ROUND(a.operating_sweeps_usd - os.scheduled_sweep_usd, 2) = 0
            THEN 'YES'
        ELSE 'NO'
    END AS operating_adjustment_posted_as_scheduled,
    transfer_result.control_status AS control_status_on_operating_date,
    CASE
        WHEN transfer_result.balance_date IS NULL THEN 'OUTSIDE_AS_OF'
        WHEN transfer_result.control_status = 'PASS' THEN 'YES'
        ELSE 'NO'
    END AS control_resolved_on_operating_date,
    COALESCE(nr.net_residual_usd, 0) AS new_settlement_residual_on_operating_date_usd
FROM grouped AS g
JOIN safeguarding_results AS r
    ON r.balance_date = g.value_date
LEFT JOIN designated_account_balances AS a
    ON a.balance_date = g.scheduled_operating_date
LEFT JOIN safeguarding_operating_schedule AS os
    ON os.scheduled_operating_date = g.scheduled_operating_date
LEFT JOIN safeguarding_results AS transfer_result
    ON transfer_result.balance_date = g.scheduled_operating_date
LEFT JOIN new_date_residuals AS nr
    ON nr.value_date = g.scheduled_operating_date;

-- All settlements on a causal date are retained: negative rows are drivers;
-- positive rows show the offsets that reduced the resulting shortfall.
DROP TABLE IF EXISTS safeguarding_shortfall_settlements;
CREATE TABLE safeguarding_shortfall_settlements AS
SELECT
    r.value_date,
    r.scheduled_operating_date,
    r.payment_id,
    r.partner_instruction_id,
    r.customer_id,
    r.partner,
    r.payment_method,
    r.source_amount_usd,
    r.fee_amount_usd,
    r.fx_execution_source_amount_usd,
    r.execution_residual_usd,
    CASE
        WHEN r.execution_residual_usd < 0 THEN 'SHORTFALL_DRIVER'
        WHEN r.execution_residual_usd > 0 THEN 'POSITIVE_OFFSET'
        ELSE 'NEUTRAL'
    END AS residual_role,
    c.net_execution_residual_usd AS causal_date_net_residual_usd,
    c.initial_shortfall_amount_usd,
    r.calendar_days_to_operating_action,
    r.intervening_weekend_days,
    r.intervening_us_holidays,
    COUNT(d.balance_date) AS active_shortfall_day_count,
    GROUP_CONCAT(d.balance_date, '|') AS active_shortfall_dates
FROM safeguarding_settlement_residuals AS r
JOIN safeguarding_shortfall_cause_dates AS c
    ON c.value_date = r.value_date
LEFT JOIN safeguarding_results AS d
    ON d.control_status = 'SHORTFALL'
   AND d.balance_date >= r.value_date
   AND d.balance_date < r.scheduled_operating_date
GROUP BY r.partner_instruction_id;

-- Daily active residuals exactly bridge the bank-account control difference:
-- value_date <= cutoff < scheduled operating adjustment date.
DROP TABLE IF EXISTS safeguarding_shortfall_days;
CREATE TABLE safeguarding_shortfall_days AS
WITH active_residuals AS (
    SELECT
        s.balance_date,
        s.required_client_money_usd,
        s.designated_account_balance_usd,
        s.surplus_shortfall_usd,
        -s.surplus_shortfall_usd AS shortfall_amount_usd,
        s.operating_topups_usd,
        s.operating_sweeps_usd,
        c.day_type,
        COUNT(CASE WHEN r.execution_residual_usd < 0 THEN 1 END)
            AS active_negative_settlement_count,
        COUNT(CASE WHEN r.execution_residual_usd > 0 THEN 1 END)
            AS active_positive_offset_count,
        ROUND(COALESCE(SUM(CASE WHEN r.execution_residual_usd < 0
                                THEN -r.execution_residual_usd END), 0), 2)
            AS active_negative_residual_usd,
        ROUND(COALESCE(SUM(CASE WHEN r.execution_residual_usd > 0
                                THEN r.execution_residual_usd END), 0), 2)
            AS active_positive_offset_usd,
        ROUND(COALESCE(SUM(r.execution_residual_usd), 0), 2)
            AS net_active_execution_residual_usd
    FROM safeguarding_results AS s
    JOIN safeguarding_analysis_calendar AS c
        ON c.calendar_date = s.balance_date
    LEFT JOIN safeguarding_settlement_residuals AS r
        ON r.value_date <= s.balance_date
       AND r.scheduled_operating_date > s.balance_date
    WHERE s.control_status = 'SHORTFALL'
    GROUP BY s.balance_date
),
numbered AS (
    SELECT
        *,
        ROW_NUMBER() OVER (ORDER BY balance_date) AS shortfall_row_number,
        julianday(balance_date)
            - ROW_NUMBER() OVER (ORDER BY balance_date) AS episode_key
    FROM active_residuals
),
identified AS (
    SELECT
        *,
        DENSE_RANK() OVER (ORDER BY episode_key) AS episode_id
    FROM numbered
),
next_dates AS (
    SELECT
        i.*,
        (
            SELECT MIN(c.calendar_date)
            FROM safeguarding_analysis_calendar AS c
            WHERE c.calendar_date > i.balance_date
              AND c.is_us_banking_day = 1
        ) AS next_us_banking_date
    FROM identified AS i
)
SELECT
    n.episode_id,
    n.balance_date,
    n.day_type,
    CASE
        WHEN n.day_type != 'US_BANKING_DAY'
         AND prior.control_status = 'SHORTFALL' THEN 'YES'
        ELSE 'NO'
    END AS non_business_day_extended_shortfall,
    n.required_client_money_usd,
    n.designated_account_balance_usd,
    n.surplus_shortfall_usd,
    n.shortfall_amount_usd,
    n.active_negative_settlement_count,
    n.active_negative_residual_usd,
    n.active_positive_offset_count,
    n.active_positive_offset_usd,
    n.net_active_execution_residual_usd,
    ROUND(n.surplus_shortfall_usd - n.net_active_execution_residual_usd, 2)
        AS residual_bridge_difference_usd,
    n.operating_topups_usd,
    n.operating_sweeps_usd,
    n.next_us_banking_date,
    next_account.operating_topups_usd AS next_us_banking_day_topup_usd,
    next_result.control_status AS next_us_banking_day_control_status,
    CASE
        WHEN next_result.balance_date IS NULL THEN 'OUTSIDE_AS_OF'
        WHEN next_result.control_status = 'PASS' THEN 'YES'
        ELSE 'NO'
    END AS resolved_by_next_us_banking_day
FROM next_dates AS n
LEFT JOIN safeguarding_results AS prior
    ON prior.balance_date = date(n.balance_date, '-1 day')
LEFT JOIN designated_account_balances AS next_account
    ON next_account.balance_date = n.next_us_banking_date
LEFT JOIN safeguarding_results AS next_result
    ON next_result.balance_date = n.next_us_banking_date;

DROP TABLE IF EXISTS safeguarding_shortfall_episodes;
CREATE TABLE safeguarding_shortfall_episodes AS
WITH episode_stats AS (
    SELECT
        episode_id,
        MIN(balance_date) AS start_date,
        MAX(balance_date) AS end_date,
        COUNT(*) AS consecutive_calendar_days,
        SUM(CASE WHEN day_type = 'US_BANKING_DAY' THEN 1 ELSE 0 END)
            AS us_banking_days,
        SUM(CASE WHEN day_type = 'WEEKEND' THEN 1 ELSE 0 END)
            AS weekend_days,
        SUM(CASE WHEN day_type = 'US_HOLIDAY' THEN 1 ELSE 0 END)
            AS us_holiday_days,
        ROUND(SUM(shortfall_amount_usd), 2)
            AS cumulative_daily_shortfall_exposure_usd,
        ROUND(AVG(shortfall_amount_usd), 2) AS average_shortfall_usd,
        ROUND(MAX(shortfall_amount_usd), 2) AS maximum_shortfall_usd
    FROM safeguarding_shortfall_days
    GROUP BY episode_id
),
resolved AS (
    SELECT
        e.*,
        CASE WHEN r.control_status = 'PASS' THEN r.balance_date END
            AS resolution_date,
        r.control_status AS next_calendar_day_control_status,
        r.operating_topups_usd AS resolution_date_topup_usd
    FROM episode_stats AS e
    LEFT JOIN safeguarding_results AS r
        ON r.balance_date = date(e.end_date, '+1 day')
)
SELECT
    *,
    CASE
        WHEN resolution_date IS NOT NULL AND resolution_date_topup_usd > 0
            THEN 'YES'
        WHEN next_calendar_day_control_status IS NULL THEN 'OPEN_AS_OF'
        ELSE 'NO'
    END AS resolved_with_operating_topup,
    CASE WHEN weekend_days + us_holiday_days > 0 THEN 'YES' ELSE 'NO' END
        AS extended_by_weekend_or_us_holiday
FROM resolved;

DROP TABLE IF EXISTS safeguarding_residual_relationship;
CREATE TABLE safeguarding_residual_relationship AS
WITH daily_moments AS (
    SELECT
        COUNT(*) AS n,
        SUM(active_negative_residual_usd) AS sum_x,
        SUM(shortfall_amount_usd) AS sum_y,
        SUM(active_negative_residual_usd * shortfall_amount_usd) AS sum_xy,
        SUM(active_negative_residual_usd * active_negative_residual_usd)
            AS sum_x2,
        SUM(shortfall_amount_usd * shortfall_amount_usd) AS sum_y2
    FROM safeguarding_shortfall_days
),
cause_date_moments AS (
    SELECT
        COUNT(*) AS n,
        SUM(negative_residual_amount_usd) AS sum_x,
        SUM(initial_shortfall_amount_usd) AS sum_y,
        SUM(negative_residual_amount_usd * initial_shortfall_amount_usd)
            AS sum_xy,
        SUM(negative_residual_amount_usd * negative_residual_amount_usd)
            AS sum_x2,
        SUM(initial_shortfall_amount_usd * initial_shortfall_amount_usd)
            AS sum_y2
    FROM safeguarding_shortfall_cause_dates
)
SELECT
    d.n AS shortfall_day_count,
    ROUND((SELECT AVG(active_negative_residual_usd)
           FROM safeguarding_shortfall_days), 2)
        AS average_active_negative_residual_usd,
    ROUND((SELECT AVG(active_positive_offset_usd)
           FROM safeguarding_shortfall_days), 2)
        AS average_active_positive_offset_usd,
    ROUND((SELECT AVG(shortfall_amount_usd)
           FROM safeguarding_shortfall_days), 2)
        AS average_shortfall_usd,
    ROUND(
        (d.n * d.sum_xy - d.sum_x * d.sum_y)
        / NULLIF(
            sqrt(
                (d.n * d.sum_x2 - d.sum_x * d.sum_x)
                * (d.n * d.sum_y2 - d.sum_y * d.sum_y)
            ),
            0
        ),
        4
    ) AS daily_correlation_negative_residual_to_shortfall,
    ROUND(
        (c.n * c.sum_xy - c.sum_x * c.sum_y)
        / NULLIF(
            sqrt(
                (c.n * c.sum_x2 - c.sum_x * c.sum_x)
                * (c.n * c.sum_y2 - c.sum_y * c.sum_y)
            ),
            0
        ),
        4
    ) AS causal_date_correlation_negative_residual_to_shortfall,
    ROUND((SELECT MAX(ABS(residual_bridge_difference_usd))
           FROM safeguarding_shortfall_days), 2)
        AS maximum_residual_bridge_difference_usd
FROM daily_moments AS d
CROSS JOIN cause_date_moments AS c;

DROP TABLE IF EXISTS safeguarding_analysis_summary;
CREATE TABLE safeguarding_analysis_summary AS
SELECT
    COUNT(*) AS shortfall_day_count,
    ROUND(SUM(shortfall_amount_usd), 2) AS total_daily_shortfall_exposure_usd,
    ROUND(AVG(shortfall_amount_usd), 2) AS average_shortfall_usd,
    ROUND(MAX(shortfall_amount_usd), 2) AS maximum_shortfall_usd,
    (SELECT COUNT(*) FROM safeguarding_shortfall_episodes)
        AS shortfall_episode_count,
    (SELECT MAX(consecutive_calendar_days)
     FROM safeguarding_shortfall_episodes)
        AS longest_consecutive_shortfall_days,
    (SELECT COUNT(*) FROM safeguarding_shortfall_episodes
     WHERE resolution_date IS NOT NULL) AS resolved_episode_count,
    (SELECT COUNT(*) FROM safeguarding_shortfall_episodes
     WHERE resolution_date IS NULL) AS open_episode_count_as_of,
    SUM(CASE WHEN non_business_day_extended_shortfall = 'YES'
             AND day_type = 'WEEKEND' THEN 1 ELSE 0 END)
        AS weekend_extension_days,
    SUM(CASE WHEN non_business_day_extended_shortfall = 'YES'
             AND day_type = 'US_HOLIDAY' THEN 1 ELSE 0 END)
        AS us_holiday_extension_days,
    (SELECT COUNT(*) FROM safeguarding_shortfall_cause_dates)
        AS causal_settlement_date_count,
    (SELECT COUNT(*) FROM safeguarding_shortfall_settlements
     WHERE residual_role = 'SHORTFALL_DRIVER')
        AS shortfall_driver_settlement_count,
    (SELECT ROUND(SUM(-execution_residual_usd), 2)
     FROM safeguarding_shortfall_settlements
     WHERE residual_role = 'SHORTFALL_DRIVER')
        AS shortfall_driver_residual_amount_usd,
    (SELECT ROUND(SUM(positive_offset_amount_usd), 2)
     FROM safeguarding_shortfall_cause_dates)
        AS positive_offset_amount_usd,
    (SELECT ROUND(SUM(initial_shortfall_amount_usd), 2)
     FROM safeguarding_shortfall_cause_dates)
        AS distinct_causal_shortfall_amount_usd,
    (SELECT COUNT(*) FROM safeguarding_shortfall_cause_dates
     WHERE control_resolved_on_operating_date = 'YES')
        AS causal_dates_resolved_on_operating_date,
    (SELECT COUNT(*) FROM safeguarding_shortfall_cause_dates
     WHERE control_resolved_on_operating_date = 'NO')
        AS causal_dates_not_resolved_due_to_new_activity,
    (SELECT COUNT(*) FROM safeguarding_shortfall_cause_dates
     WHERE control_resolved_on_operating_date = 'OUTSIDE_AS_OF')
        AS causal_dates_outside_as_of
FROM safeguarding_shortfall_days;

.mode csv
.once data/safeguarding_analysis_summary.csv
SELECT * FROM safeguarding_analysis_summary;

.once data/safeguarding_shortfall_days.csv
SELECT * FROM safeguarding_shortfall_days ORDER BY balance_date;

.once data/safeguarding_shortfall_episodes.csv
SELECT * FROM safeguarding_shortfall_episodes ORDER BY episode_id;

.once data/safeguarding_shortfall_cause_dates.csv
SELECT * FROM safeguarding_shortfall_cause_dates ORDER BY value_date;

.once data/safeguarding_shortfall_settlements.csv
SELECT *
FROM safeguarding_shortfall_settlements
ORDER BY value_date, execution_residual_usd, partner_instruction_id;

.once data/safeguarding_residual_relationship.csv
SELECT * FROM safeguarding_residual_relationship;

.output stdout
.mode column
SELECT * FROM safeguarding_analysis_summary;
