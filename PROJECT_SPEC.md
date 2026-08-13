# USD-CNY Treasury Reconciliation Simulation

## 1. Project Purpose

Build a small, defensible Treasury Operations simulation for a fictional cross-border payments company processing payments from U.S. customers in USD to Chinese beneficiaries in RMB (modeled as CNY for the MVP).

The project should demonstrate how a Treasury Operations analyst can:

- reconcile internal ledger records against external bank/payment-partner settlement records;
- distinguish explained economic differences from genuine operational breaks;
- analyze fees, FX execution, and value-date timing;
- monitor open reconciliation items and aging;
- perform a simplified client-money / safeguarding balance check; and
- use root-cause analysis to identify concentrations of operational risk.

The project is intentionally narrow. It is not meant to reproduce Airwallex's real infrastructure, regulatory methodology, or production systems.

---

## 2. Business Scenario

A fictional payments company, `GlobalPay`, supports U.S. businesses that pay suppliers or beneficiaries in China.

Core corridor:

`USD -> RMB (CNY)`

Simplified lifecycle:

1. A customer submits a payment instruction in USD.
2. GlobalPay records the payment in its internal ledger at a quoted USD/CNY FX rate.
3. A payment partner applies its contractual fee.
4. FX is executed at the rate available at execution time.
5. Settlement occurs on a later value date according to the partner's settlement rule.
6. Treasury receives external bank / settlement records.
7. The reconciliation process compares internal expectations with external settlement outcomes.

---

## 3. Core Intellectual Principle

### Do not generate labeled reconciliation errors.

The simulator must generate operational events and normal payment mechanics.

Examples:

- contractual partner fees;
- quoted FX versus executed FX;
- T+1 / T+2 settlement rules;
- weekends and business-day value dates;
- execution failures;
- retry behavior;
- delayed settlement.

The reconciliation engine must independently infer the resulting classification from the records it receives.

Analytical findings must emerge from the simulation output. They must not be predetermined by assigning labels during data generation.

Synthetic deterministic cases may later be created for software tests, but they must remain separate from the analytical dataset.

---

## 4. Scope

### MVP includes

- two entities or operating perspectives if useful, but one USD-CNY corridor;
- USD source currency;
- CNY destination currency;
- at least two payment partners with different fee and settlement rules;
- quoted versus executed FX rates;
- booking date and value date;
- three core datasets/tables;
- SQL-based reconciliation logic;
- aging of genuine open items;
- one simplified safeguarding/client-money check;
- root-cause analysis by partner and operational dimension.

### Explicitly out of scope for the first version

- production-grade regulatory safeguarding logic;
- real customer or bank data;
- full treasury rebalancing optimization;
- multi-currency liquidity optimization;
- four-page BI dashboards;
- machine learning;
- LLM agents;
- complex microservices;
- production cloud deployment.

---

## 5. Core Data Tables

### 5.1 `ledger`

Represents what GlobalPay's internal system believes should happen.

Suggested fields:

- `payment_id`
- `customer_id`
- `booking_timestamp`
- `booking_date`
- `source_currency`
- `source_amount`
- `destination_currency`
- `quoted_fx_rate`
- `quoted_destination_amount`
- `payment_type`
- `partner`
- `expected_settlement_date`
- `ledger_status`

### 5.2 `bank_transactions`

Represents what the external banking/payment side actually reports.

Suggested fields:

- `bank_txn_id`
- `payment_id`
- `partner`
- `bank_reference`
- `booking_timestamp`
- `booking_date`
- `value_date`
- `source_currency`
- `gross_source_amount`
- `fee_amount`
- `fee_currency`
- `executed_fx_rate`
- `settlement_currency`
- `settlement_amount`
- `external_status`

### 5.3 `customer_balances`

Represents simplified client-money obligations.

Suggested fields:

- `date`
- `customer_id`
- `entity`
- `currency`
- `customer_balance`

---

## 6. Payment-Partner Mechanics

At least two partners should have different operating rules.

Example only:

### Partner A

- fee: `0.60%` of USD source amount;
- fee deducted before FX conversion;
- settlement: T+1 business day.

### Partner B

- fee: `0.35% + USD 5`;
- fee deducted before FX conversion;
- settlement: T+2 business days.

These are fictional assumptions for the simulation and must be documented in `DECISIONS.md`.

---

## 7. FX Mechanics

The project must separate three concepts:

### 7.1 Quoted FX rate

The rate shown or booked internally when the payment is initiated.

### 7.2 Executed FX rate

The rate actually used when the payment is converted.

### 7.3 Reporting / revaluation FX rate

A separate closing rate used if CNY balances are converted into the Treasury reporting currency.

Treasury reporting currency for the project:

`USD`

Do not use the transaction execution rate as the reporting rate unless explicitly justified.

---

## 8. Value-Date Mechanics

`booking_date` and `value_date` must be separate fields.

A payment can be booked internally before the bank-side settlement becomes effective.

Example:

- booking date: Friday;
- expected settlement rule: T+1 business day;
- value date: Monday.

At Friday cutoff, the external settlement may be absent without representing a true failure.

The reconciliation engine should therefore distinguish:

- an item still inside its expected settlement window; and
- an item whose expected settlement date has passed.

---

## 9. Reconciliation Output

The reconciliation engine must independently derive one primary classification for each relevant payment / settlement state.

Target classifications:

- `MATCHED`
- `EXPLAINED_FEE`
- `EXPLAINED_FX`
- `TIMING_PENDING`
- `OVERDUE_SETTLEMENT`
- `UNEXPLAINED_AMOUNT`
- `MISSING_LEDGER`
- `DUPLICATE`

Important principle:

Not every difference is an operational break.

A contractual fee, expected FX difference, or value-date timing difference can be explainable. Genuine exception handling should focus on items that remain unexplained or breach expected settlement rules.

The implementation must define classification precedence so that overlapping rules do not assign contradictory statuses.

---

## 10. Reconciliation Fields

The final reconciliation result should make the reasoning inspectable.

Suggested output fields:

- `payment_id`
- `partner`
- `source_amount`
- `quoted_fx_rate`
- `executed_fx_rate`
- `expected_fee`
- `actual_fee`
- `expected_net_source_amount`
- `expected_destination_amount`
- `actual_settlement_amount`
- `booking_date`
- `expected_settlement_date`
- `value_date`
- `variance_cny`
- `variance_usd_equivalent`
- `classification`
- `aging_days`

---

## 11. Aging Logic

Aging applies primarily to genuine open operational items.

Example logic:

- before expected settlement date -> `TIMING_PENDING`;
- expected settlement date passed with no settlement -> `OVERDUE_SETTLEMENT`;
- aging begins from the relevant expected settlement or exception date.

Suggested buckets:

- `0-1 day`
- `2-3 days`
- `4-7 days`
- `>7 days`

---

## 12. Simplified Safeguarding / Client-Money Check

For the MVP:

`required_client_funds = SUM(customer_balance)`

`surplus_shortfall = actual_designated_account_balance - required_client_funds`

Classification:

- `PASS` if surplus/shortfall >= 0;
- `SHORTFALL` if surplus/shortfall < 0.

This is a simplified educational control model only. It must not be presented as the legal safeguarding methodology for any real jurisdiction or company.

---

## 13. Root-Cause Analysis

Root-cause analysis is part of the MVP, not a final optional feature.

Analyze genuine exceptions by dimensions such as:

- payment partner;
- payment method;
- payment amount band;
- booking weekday;
- settlement lag;
- exception classification;
- aging bucket.

Questions the analysis should answer include:

- Which partner produces the highest true-break rate?
- Which partner produces the highest dollar exposure from true breaks?
- Are overdue settlements concentrated by weekday or settlement rule?
- Are larger payments disproportionately represented among unresolved items?
- What share of observed mismatches are explained versus genuinely operational?

The answers must be discovered from generated data rather than hard-coded.

---

## 14. Initial Deliverables

First implementation target:

1. `src/generate_transactions.py`
2. generated `ledger.csv`
3. generated `bank_transactions.csv`
4. generated `customer_balances.csv`
5. `sql/reconciliation.sql`
6. `notebooks/analysis.ipynb`

Do not add additional infrastructure until these components work and the Treasury logic can be explained clearly.

---

## 15. Acceptance Criteria

The MVP is successful when the project owner can demonstrate the following without relying on hidden simulator labels:

1. Generate a reproducible synthetic payment dataset.
2. Explain how partner fees change expected settlement amounts.
3. Explain quoted versus executed FX differences.
4. Demonstrate a booking-date versus value-date timing difference.
5. Run reconciliation and distinguish explained differences from genuine breaks.
6. Show when a pending settlement becomes overdue.
7. Calculate aging for unresolved operational items.
8. Run the simplified client-money / safeguarding check.
9. Produce at least one root-cause finding from the generated data.
10. Manually walk through one payment from ledger booking to external settlement and explain every amount.

---

## 16. Interview Standard

Code quality matters, but the project is primarily judged by whether the project owner can defend the financial logic.

For every important rule, the owner should be able to explain:

- why the rule exists;
- what data it requires;
- what would make the rule fail;
- whether the resulting difference is economic, timing-related, or operational;
- what Treasury should do next.
