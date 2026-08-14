# USD-CNY Treasury Reconciliation Simulation

## 1. Project Purpose

Build a small, defensible Treasury Operations simulation for a fictional cross-border payments company processing payments from U.S. customers in USD to Chinese beneficiaries in RMB (modeled as CNY for the MVP).

The project should demonstrate how a Treasury Operations analyst can:

- reconcile internal ledger records against external bank/payment-partner settlement records;
- report payment reconciliation state separately from economic variance attribution;
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

The reconciliation engine must independently infer the resulting payment state from the records it receives.

Payment reconciliation state and economic variance attribution are separate concepts. A payment can settle correctly and on time while still producing fee or FX execution economics. Those economics must be measured, not relabeled as an operational settlement break.

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
- `partner_instruction_id`
- `customer_id`
- `entity`
- `partner`
- `payment_method`
- `booking_timestamp_utc`
- `booking_date`
- `source_currency`
- `source_amount_usd`
- `destination_currency`
- `quoted_fx_rate`
- `expected_partner_fee_usd`
- `expected_net_source_amount_usd`
- `expected_fx_execution_source_amount_usd`
- `quoted_destination_amount_cny`
- `expected_settlement_date`
- `ledger_status`

### 5.2 `bank_transactions`

Represents what the external banking/payment side actually reports.

Suggested fields:

- `bank_txn_id`
- `partner_instruction_id`
- `partner`
- `bank_reference`
- `payment_method`
- `execution_timestamp_utc`
- `execution_date`
- `value_date`
- `source_currency`
- `fee_amount_usd`
- `fx_execution_source_amount_usd`
- `executed_fx_rate`
- `settlement_currency`
- `settlement_amount_cny`
- `external_status`

The external table does not repeat customer gross or net USD fields. It reports the partner's actual fee and USD FX funding requirement without implying that GlobalPay handed the customer's principal directly to the partner.

### 5.3 `customer_balances`

Represents simplified client-money obligations.

Suggested fields:

- `balance_date`
- `customer_id`
- `entity`
- `currency`
- `opening_balance`
- `funding_inflows`
- `accepted_payment_debits`
- `customer_balance`

### 5.4 `designated_account_balances`

Represents the independently rolled-forward USD balance in the simplified
designated client-money bank account.

Fields:

- `balance_date`
- `control_cutoff_timestamp_local`
- `account_id`
- `entity`
- `currency`
- `opening_balance_usd`
- `cleared_customer_receipts_usd`
- `operating_topups_usd`
- `partner_fx_funding_debits_usd`
- `partner_fee_debits_usd`
- `operating_sweeps_usd`
- `closing_balance_usd`

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

The customer-facing CNY amount is committed at booking and does not change when the partner executes FX. The internal expected USD funding requirement and the external actual USD funding requirement preserve the quote-versus-execution economics needed for later analysis. USD funding requirements are rounded upward to cents so the fixed CNY commitment is fully funded.

### 7.3 Reporting / revaluation FX rate

A separate closing rate used if CNY balances are converted into the Treasury reporting currency.

Treasury reporting currency for the project:

`USD`

Do not use the transaction execution rate as the reporting rate unless explicitly justified.

---

## 8. Value-Date Mechanics

`booking_date`, `expected_settlement_date`, `execution_date`, and `value_date` must have separate meanings.

`expected_settlement_date` is frozen at booking from the booking timestamp, contractual cutoff/readiness rules, settlement calendar, and contractual partner lag. It must not depend on realized execution timing.

`execution_date` and `value_date` arise independently from actual partner processing. Ordinary seeded service-time variation can move execution to a later business day and therefore cause realized value date to diverge from the internal expectation.

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

## 9. Reconciliation State and Economic Attribution

### 9.1 Payment reconciliation state

The reconciliation engine must independently derive one primary operational state for each relevant payment / settlement state.

Target reconciliation states:

- `MATCHED`: one internal record and one external settlement exist, and beneficiary CNY agrees; any realized settlement delay remains a separate timing measure;
- `TIMING_PENDING`: no external settlement exists, but the expected date is still in the future;
- `OVERDUE_SETTLEMENT`: no external settlement exists and the expected date has passed;
- `UNEXPLAINED_AMOUNT`: an external settlement exists but beneficiary CNY does not agree with the committed amount;
- `MISSING_LEDGER`: an external record exists without an internal booking;
- `DUPLICATE`: more than one internal or external record exists for the reconciliation key.

`MISSING_LEDGER` and `DUPLICATE` describe conditions the later reconciliation design may need to handle. The normal analytical simulator must not fabricate those conditions merely to make every state appear.

The implementation must define precedence among reconciliation states so overlapping conditions do not create contradictory operational outcomes.

### 9.2 Economic variance attribution

Fee and FX economics are analytical measures, not reconciliation states:

- fee variance compares independently calculated expected and actual partner fees;
- FX execution funding variance compares expected and actual USD required to fund the fixed beneficiary CNY commitment;
- beneficiary settlement variance compares committed and settled CNY;
- currency-rounding residuals caused only by ceiling-to-cent funding are not operational breaks.

A `MATCHED` payment may have nonzero fee or FX execution variance. Conversely, an overdue payment is an operational timing state even before all economic fields are available.

Important principle:

Not every difference is an operational break.

A contractual fee or expected FX execution difference can be economically attributable without changing payment reconciliation state. Genuine exception handling should focus on absent, late, duplicated, or unexplained settlement outcomes.

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
- `expected_fx_execution_source_amount_usd`
- `actual_fx_execution_source_amount_usd`
- `expected_destination_amount`
- `actual_settlement_amount`
- `booking_date`
- `expected_settlement_date`
- `value_date`
- `fee_variance_usd`
- `fx_execution_funding_variance_usd`
- `settlement_variance_cny`
- `reconciliation_state`
- `aging_days`

The sign convention for every variance must be documented. Margin or P&L remains derived analytics and is not stored as a simulator answer-key field.

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

The daily control distinguishes customer balances, accepted outbound funds
that are pending external settlement, and cash actually held in the designated
account.

At each end-of-day cutoff:

`pending_outbound_obligation = SUM(source_amount_usd for BOOKED payments with booking_date <= cutoff date and no SETTLED external value_date <= cutoff date)`

`required_client_money = SUM(customer_balance) + pending_outbound_obligation`

`surplus_shortfall = actual_designated_account_balance - required_client_money`

The actual designated-account balance is independently rolled forward as:

`closing = opening + cleared customer receipts + operating top-ups - partner FX funding debits - partner fee debits - operating sweeps`

The simulation initializes the first opening account balance to the first day's
opening customer subledger obligation. After that starting condition, no daily
account balance is back-solved from the required amount or control result.

The deterministic end-of-day sequence is opening balance, cleared customer
receipts, scheduled operating top-ups, actual-value-date partner debits,
scheduled operating sweeps, closing balance, then the obligation/control
comparison at 23:59:59 America/New_York. A payment that settles on the cutoff
date is therefore no longer pending at that cutoff.

Beneficiary value dates use the joint USD/CNY settlement calendar. Operating
top-ups and sweeps use the US banking calendar. A positive per-payment execution
residual schedules an operating sweep on the next US banking day; a negative
residual schedules an operating top-up on the next US banking day. The schedule
is driven by payment economics, never by the calculated control result.

Control result:

- `PASS` if surplus/shortfall >= 0;
- `SHORTFALL` if surplus/shortfall < 0.

This is a simplified educational control model only. It must not be presented as the legal safeguarding methodology for any real jurisdiction or company.

### 12.1 Safeguarding analysis

Analyze the production control without modifying its inputs or results. Report:

- shortfall-day count, cumulative daily exposure, average, and maximum;
- consecutive shortfall episodes and their resolution dates;
- settlement-level execution residual drivers and positive offsets;
- whether scheduled operating top-ups and sweeps posted on the next US banking
  day and whether the control returned to `PASS`;
- weekend and US-holiday extension days; and
- the relationship between active negative execution residuals and observed
  shortfall size.

For attribution, a settlement residual remains active from its actual value
date through the day before its scheduled US-calendar operating adjustment.
The daily control difference must equal the sum of active positive and negative
residuals. Negative-residual payments are shortfall drivers; positive residuals
are retained as offsets rather than discarded from the explanation.

`total_daily_shortfall_exposure_usd` is an exposure-day measure and can count a
carried shortfall on more than one cutoff. It must remain separate from the net
amount across distinct causal settlement dates.

---

## 13. Root-Cause Analysis

Root-cause analysis is part of the MVP, not a final optional feature.

Analyze genuine exceptions by dimensions such as:

- payment partner;
- payment method;
- payment amount band;
- booking weekday;
- settlement lag;
- reconciliation state;
- aging bucket.

Questions the analysis should answer include:

- Which partner produces the highest true-break rate?
- Which partner produces the highest dollar exposure from true breaks?
- Are overdue settlements concentrated by weekday or settlement rule?
- Are larger payments disproportionately represented among unresolved items?
- What share of payments are operationally open or broken, independently of their fee and FX economics?
- How are fee and FX execution funding variances distributed among operationally matched payments?

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
5. Run reconciliation and report payment state separately from fee and FX economic attribution.
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
