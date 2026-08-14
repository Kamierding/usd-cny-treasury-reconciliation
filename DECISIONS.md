# Project Decisions

This file records explicit modeling choices so that assumptions remain visible and defendable.

## D001 — Corridor

**Decision:** Model one core corridor: USD -> RMB, represented as CNY in the MVP.

**Reason:** The project is designed to focus deeply on FX, fees, settlement timing, reconciliation, and client-money controls rather than spread effort across many currencies.

**Status:** Accepted.

---

## D002 — Treasury Reporting Currency

**Decision:** Use USD as the Treasury reporting currency.

**Reason:** Source payments originate in USD and a single reporting currency is required before cross-currency balances can be aggregated honestly.

**Status:** Accepted.

---

## D003 — Error Generation Principle

**Decision:** Do not assign reconciliation-error labels during normal transaction generation.

**Reason:** Operational mechanics should produce observable outcomes. The reconciliation engine should infer classifications independently so that analytical findings are not circular.

**Exception:** Deterministic synthetic cases may later be created exclusively for software tests.

**Status:** Accepted.

---

## D004 — Explained Differences vs. True Breaks

**Decision:** Treat contractual fees, expected FX differences, and settlement timing separately from genuine operational failures.

**Reason:** A mismatch between two records does not automatically require remediation. Treasury Operations must distinguish explainable economic/timing differences from unexplained or overdue items.

**Status:** Accepted.

---

## D005 — Fee Treatment

**Decision:** Initial partner configurations will deduct fees from USD principal before FX conversion.

**Reason:** This produces an inspectable separation between fee effect and FX execution effect.

**Note:** This is a fictional contractual assumption and can be changed later if the project models another partner structure.

**Status:** Accepted for Module 1B.

---

## D006 — Booking Date vs. Value Date

**Decision:** Store booking date/time and value date separately.

**Reason:** A ledger item can be booked before external settlement becomes effective. This distinction is necessary to prevent ordinary T+1/T+2 timing from being mislabeled as a true break.

**Status:** Accepted.

---

## D007 — Safeguarding Scope

**Decision:** Use a simplified client-money balance comparison for the MVP.

**Reason:** The project's purpose is to demonstrate control logic, not reproduce jurisdiction-specific regulatory safeguarding calculations.

**Status:** Accepted.

---

## D008 — Module 1B Customer Balance Definition

**Decision:** `customer_balance` is the closing USD liability recorded in GlobalPay's simplified customer subledger for an individual customer after recognized funding credits and accepted payment debits.

**Reason:** This keeps the customer subledger balance distinct from a production available-balance calculation and from any later safeguarding requirement. The simulator does not model holds, reserves, or withdrawal availability. A requested payment that exceeds the customer's balance is rejected and never becomes a booked ledger payment; its amount is never silently reduced.

**Status:** Accepted.

---

## D009 — Module 1B Date Vocabulary

**Decision:** Use four distinct lifecycle dates: `booking_date` is GlobalPay's acceptance date; `expected_settlement_date` is the contractual expectation frozen at booking from the booking timestamp, contractual cutoff/readiness rule, settlement calendar, and contractual lag; `execution_date` is when the partner actually executes FX; and `value_date` is when CNY settlement becomes economically effective. Expected timing does not call or depend on realized partner execution timing.

**Reason:** Keeping these meanings separate makes cutoff, weekend, FX execution, and settlement timing inspectable. Realized execution consumes independently seeded service minutes only during partner banking hours, so value date can move beyond the contractual expectation without an injected delay flag.

**Status:** Accepted.

---

## D010 — Module 1B Settlement Behavior

**Decision:** Generate B2B bookings only on configured business days. Model partner cutoffs, a Monday-Friday joint USD/CNY settlement calendar, and partner-specific T+1/T+2 settlement lags. The default simulation calendar includes the relevant 2025 US bank holidays and China's New Year, Spring Festival, and Qingming closures; additional US and China holidays can be supplied explicitly. Do not model partner capacity, queues, retries, cancellations, duplicate settlement, or deliberately missing records in Module 1B.

**Reason:** Cutoffs, independently sampled processing effort, banking hours, and business-day lags establish the normal payment lifecycle. The as-of extract can omit valid future settlements or reveal naturally late processing without manufacturing operational breaks.

**Status:** Accepted.

---

## D011 — Module 1B FX Execution

**Decision:** For the USD-to-CNY corridor, calculate the executed rate as `execution-time market rate * (1 - partner spread bps / 10,000)`. Freeze the hourly simulated market rate on weekends and configured bank-closure dates. `quoted_destination_amount_cny` is the beneficiary amount committed at booking and is not changed by the partner's executed rate. Internal `expected_fx_execution_source_amount_usd` uses the quoted rate; external `fx_execution_source_amount_usd` uses the executed rate. Both divide the fixed CNY commitment using Decimal arithmetic and round upward to USD cents.

**Reason:** The destination amount is quoted as CNY per USD, so the partner spread reduces the executed rate. Holding the beneficiary commitment fixed separates customer quote economics from partner execution economics. Currency rounding may leave a small residual when rounded USD is multiplied by the executed rate; that residual is not an operational break. No reporting/revaluation rate or stored margin/P&L field is introduced in Module 1B.

**Status:** Accepted.

---

## D012 — Module 1B Fee Independence

**Decision:** The internal process freezes an expected contractual fee at booking, while the partner process independently assesses the actual fee from the original customer USD instruction. The external settlement extract reports the actual fee, executed rate, USD FX funding requirement, and settled CNY. It does not publish customer gross or net USD fields that imply the customer principal was literally handed to the partner.

**Reason:** The two amounts may agree because the same contract governs them, but the external output must never copy the ledger's calculated fee.

**Status:** Accepted.

## D013 — Module 1B Default Partner Contracts

**Decision:** Partner A charges 0.60% of gross USD, has a 16:00 New York cutoff, settles T+1, and applies a 4 bps execution spread. Partner B charges 0.35% plus USD 5, has a 14:00 New York cutoff, settles T+2, and applies a 2 bps execution spread. GlobalPay's quote spread is 12 bps. `LOCAL_BANK_TRANSFER` and `SWIFT` are retained as descriptive outbound payment methods but do not alter the partner contracts in Module 1B.

**Reason:** The contrasting fictional contracts make fee, FX, cutoff, and settlement mechanics observable without injecting reconciliation outcomes.

**Status:** Accepted.

---

## D014 — Module 1B Independent Partner Processing

**Decision:** Partner A service effort is sampled from a triangular 15/45/240-minute distribution and Partner B from a triangular 30/90/360-minute distribution. Service minutes are consumed between 09:00 and 17:00 New York time on joint settlement business days and carry into the next business day when necessary. Each partner uses its own deterministic random stream derived from the master seed.

**Reason:** Continuous service-time mechanics create ordinary realized timing variation without capacity queues, arbitrary delay flags, or a target exception percentage.

**Status:** Accepted.

---

## D015 — Module 2 Reconciliation State and Variance

**Decision:** Implement reconciliation in SQLite with one operational state and separate economic measures. State precedence is `DUPLICATE`, `MISSING_LEDGER`, `TIMING_PENDING` or `OVERDUE_SETTLEMENT`, `UNEXPLAINED_AMOUNT`, then `MATCHED`. Fee and FX funding variances do not change payment state. The normal simulator is not modified to manufacture otherwise unreachable states.

**Reason:** Operational settlement questions and economic attribution answer different Treasury questions and must remain independently inspectable.

**Variance signs:** Fee variance is actual minus expected; FX funding variance is actual minus expected; CNY settlement variance is actual minus committed; settlement delay is actual value date minus expected settlement date. Positive values mean higher partner fee, more USD required, excess CNY settled, and later settlement respectively.

**Status:** Accepted.

---

## D016 — Module 2 Deterministic State Tests

**Decision:** Validate reconciliation state and precedence with isolated in-memory SQLite fixtures that cover all six target states. Synthetic duplicate, missing-ledger, and CNY-difference cases exist only in `sql/test_reconciliation.sql`; they are never added to the analytical simulator or generated CSVs.

**Reason:** Edge states and precedence require deterministic software tests, while analytical findings must continue to emerge only from ordinary payment mechanics.

**Status:** Accepted.

---

## D017 — Module 2.2 Reconciliation Analytics

**Decision:** Build reconciliation analytics only from production `reconciliation_results`. Transaction counts include all reconciliation rows unless the table requires an execution timestamp; duration buckets therefore contain settled rows only. Late-settlement rates use settled transactions as the denominator; average timing variance uses settled rows; and normalized FX variance divides aggregate variance by aggregate expected FX funding before multiplying by 10,000.

**Buckets:** Quote-to-execution duration uses `<2 hours`, `2-8 hours`, `8-24 hours`, `24-72 hours`, and `72+ hours`. Payment size uses `<$5k`, `$5k-$10k`, `$10k-$25k`, and `$25k+`. Before/after-cutoff status uses each partner's New York cutoff and the applicable 2025 EST/EDT offset.

**Reason:** Explicit denominators and non-overlapping buckets keep signed dollars, absolute dollars, and normalized basis-point measures interpretable without manufacturing conclusions.

**Status:** Accepted.

---

## D018 — Module 3 Simplified Client-Money Control

**Decision:** At each 23:59:59 America/New_York cutoff, define required client money as the sum of closing customer subledger balances and accepted outbound USD obligations that have not reached an actual external value date. A payment with a settled value date on or before the cutoff date is no longer pending. Compare this requirement with the independently rolled-forward closing balance of one designated USD client-money account.

**Account sequence:** The initial opening balance is funded to the first day's opening customer subledger obligation. From that starting condition, the account is not back-solved from later requirements. Each cutoff applies opening balance, cleared customer receipts, scheduled operating top-ups, actual-value-date partner FX and fee debits, scheduled operating sweeps, closing balance, then the obligation/control comparison. Payment booking moves value from a customer's subledger balance to a pending outbound obligation without moving designated-account cash.

**Calendars:** Beneficiary settlement uses the joint USD/CNY settlement calendar established in Module 1B. Operating top-ups and sweeps use the US banking calendar only. For each settled payment, `source_amount_usd - fee_amount_usd - fx_execution_source_amount_usd` determines the operating transfer: a positive residual is swept out on the next US banking day and a negative residual is topped up on the next US banking day.

**Reason:** Separate obligation and bank-account processes make the control non-circular. Normal FX execution economics and banking-calendar timing can produce temporary surplus or shortfall without injecting a target result or modifying the payment simulator.

**Scope:** This is an educational control model, not the legal safeguarding methodology of any jurisdiction or company.

**Status:** Accepted.

---

## D019 — Module 3.1 Safeguarding Analysis Attribution

**Decision:** Analyze only the production `safeguarding_results` and its source account, ledger, and external settlement tables. A settlement's execution residual is active from its value date until, but not including, its scheduled next-US-banking-day operating adjustment. The signed sum of active residuals must bridge exactly to the designated-account surplus or shortfall.

**Attribution:** Negative residuals are shortfall drivers and positive residuals are offsets. A causal settlement date is a value date on which the aggregate residual is negative. Settlement-level output retains both signs so the net shortfall is not overstated. Operating-adjustment posting and return to `PASS` are reported separately because new value-date activity can replace a deficit on the same day an older one is cleared.

**Duration:** Consecutive shortfall episodes use calendar-day islands. Weekend and explicit US-holiday days are reported separately. Cumulative daily shortfall exposure is an exposure-day measure and is not presented as a distinct cash amount.

**Reason:** This preserves the mechanical causal chain and prevents circular or exaggerated attribution while supporting the requested duration, resolution, calendar, and residual-size analysis.

**Status:** Accepted.
