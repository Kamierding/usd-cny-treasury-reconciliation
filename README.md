# USD-CNY Treasury Reconciliation Simulation

A compact Treasury Operations portfolio project that simulates cross-border USD-to-CNY payments and reconciles internal ledger expectations against external settlement records.

## What this project is designed to demonstrate

- payment reconciliation;
- fee-aware matching;
- quoted vs. executed FX analysis;
- booking date vs. value date logic;
- explained variance vs. genuine operational breaks;
- exception aging;
- simplified client-money / safeguarding controls;
- root-cause analysis of reconciliation exceptions.

## Core design principle

The normal simulator does **not** create labeled reconciliation errors. It models payment mechanics and operational events. Reconciliation logic independently determines what happened.

## Initial structure

```text
usd-cny-treasury-reconciliation/
├── README.md
├── PROJECT_SPEC.md
├── DECISIONS.md
├── .gitignore
├── src/
├── sql/
├── notebooks/
└── data/
```

## Planned build order

1. Design and implement the transaction simulator.
2. Review simulator assumptions before adding reconciliation.
3. Build SQL reconciliation logic.
4. Validate reconciliation-state precedence and counterexamples.
5. Add simplified safeguarding calculation.
6. Perform root-cause analysis.
7. Stop adding features and prepare to explain the project clearly.

## Current status

**Module 3.1 — Safeguarding analysis implemented; Module 2 reconciliation and analytics logic is frozen.**

Generate the reproducible default dataset with:

```bash
python3 -B src/generate_transactions.py
```

The default run uses seed `20250301`, generates 500 requested USD-to-CNY payments from January 1 through March 31, 2025, and writes an end-of-day March 31 as-of extract to `data/`. Requests are weekday-oriented and are booked only when the selected customer has sufficient funds; the current default seed produces 474 accepted bookings.

The internal quote freezes the beneficiary's promised CNY amount and the expected USD funding requirement. The external partner record reports only its actual fee, executed rate, ceiling-to-cent USD funding requirement, and settled CNY. Any economic variance, margin, or P&L remains a derived analytical measure rather than a simulator field.

Realized execution consumes independently seeded service time during partner banking hours. This allows actual value date to diverge naturally from the contractual expectation without queue capacity or injected delay flags.

The joint USD/CNY settlement calendar excludes weekends and explicit US and China banking holidays. Additional closures can be supplied with repeatable `--us-holiday YYYY-MM-DD` and `--china-holiday YYYY-MM-DD` options.

`customer_balance` is the closing USD liability in GlobalPay's simplified customer subledger after funding credits and accepted payment debits. It is neither a production available-balance calculation nor, by itself, a safeguarding requirement.

Module 1B intentionally contains no reconciliation classifications, target match rate, capacity rule, retry behavior, safeguarding calculation, dashboard, or root-cause analysis.

Run the SQLite reconciliation from the project root with:

```bash
sqlite3 data/reconciliation.db < sql/reconciliation.sql
```

This recreates `reconciliation_results` in `data/reconciliation.db` and exports `data/reconciliation_results.csv`. The SQL assigns one operational reconciliation state while keeping fee, FX funding, CNY settlement, and timing variances as separate measures. The as-of date is an explicit parameter near the top of `sql/reconciliation.sql` and must match the extract being reconciled.

With the current default seed, the output contains 461 `MATCHED` and 13 `TIMING_PENDING` payments. Sixteen matched payments settled after their contractual date, which remains a timing-performance measure rather than a different payment state. No synthetic duplicates, missing ledgers, fee discrepancies, or CNY amount errors were added to obtain these results.

Run the isolated reconciliation-state tests with:

```bash
sqlite3 :memory: < sql/test_reconciliation.sql
```

The test file covers every target state and precedence boundary without modifying the analytical datasets. `sql/reconciliation_schema.sql` and `sql/reconciliation_logic.sql` are shared by the production run and the fixture tests so the assertions exercise the same SQL used for the generated data.

Run the reconciliation analytics with:

```bash
sqlite3 data/reconciliation.db < sql/reconciliation_analytics.sql
```

This uses the existing production `reconciliation_results` and exports four summary tables:

- `data/analytics_partner.csv`
- `data/analytics_duration_bucket.csv`
- `data/analytics_cutoff.csv`
- `data/analytics_payment_size.csv`

The tables keep signed FX funding variance, absolute FX funding variance, and normalized basis-point measures separate. Late-settlement rates use settled transactions as the denominator. The analytics do not alter simulator or reconciliation outputs.

Generate the independent designated client-money account roll-forward with:

```bash
python3 -B src/generate_designated_account.py
```

This consumes the existing Module 1B datasets and writes
`data/designated_account_balances.csv`. Beneficiary settlements retain their
joint USD/CNY value dates. Operating top-ups and sweeps are scheduled on the
next US banking day, using the same explicit US holiday defaults as the payment
simulation; extra closures can be supplied with repeatable
`--us-holiday YYYY-MM-DD` options.

Run the daily control with:

```bash
sqlite3 data/safeguarding.db < sql/safeguarding.sql
```

This exports `data/safeguarding_results.csv`. At the 23:59:59 New York cutoff,
required client money equals closing customer balances plus accepted outbound
USD payments whose actual external value date has not yet occurred. The actual
designated-account balance is rolled forward separately from observable cash
flows; it is never back-solved from the requirement or control result.

With the current default dataset, the output contains 76 `PASS` days and 14
`SHORTFALL` days. The range is USD -34.86 to USD 170.73 and arises from the
approved next-US-banking-day timing of execution-residual top-ups and sweeps,
not from injected shortfalls or a target pass rate.

Module 3 is explicitly an educational simplification and does not claim to
implement any jurisdiction's legal safeguarding methodology.

Validate the production control identities and calendar rules with:

```bash
sqlite3 data/safeguarding.db < sql/test_safeguarding.sql
```

Run the safeguarding analysis against the existing production control with:

```bash
sqlite3 data/safeguarding.db < sql/safeguarding_analysis.sql
```

The analysis exports:

- `data/safeguarding_analysis_summary.csv`
- `data/safeguarding_shortfall_days.csv`
- `data/safeguarding_shortfall_episodes.csv`
- `data/safeguarding_shortfall_cause_dates.csv`
- `data/safeguarding_shortfall_settlements.csv`
- `data/safeguarding_residual_relationship.csv`

The current production dataset has 14 shortfall days across five consecutive
episodes. Total daily shortfall exposure is USD 295.82, average shortfall is
USD 21.13, and maximum shortfall is USD 34.86. Daily exposure counts a carried
shortfall once per cutoff; it is distinct from the USD 156.80 net amount across
the seven causal settlement dates.

Four episodes resolved after operating top-ups; the March 31 episode remains
open because its scheduled April 1 adjustment is outside the as-of extract.
Six weekend days and the January 20 US holiday extended otherwise active
shortfalls. Settlement-level output identifies 21 negative-residual drivers and
24 positive offsets. The active-residual bridge reproduces every daily control
difference exactly without altering the underlying account or safeguarding
results.

See `PROJECT_SPEC.md` for requirements and `DECISIONS.md` for explicit modeling assumptions.
