# USD–CNY Treasury Reconciliation & Safeguarding Simulation

This project builds a synthetic USD→CNY cross-border payment environment to examine Treasury reconciliation, settlement timing, FX execution economics, and simplified client-money controls. It connects transaction-level payment activity to operational states, partner performance, and daily funding exposure.

**All transactions, customers, partners, and results are synthetic.**

## Business Problem

A cross-border payment appears differently across internal booking records, partner or bank settlement records, customer obligations, and designated cash balances. Treasury must connect those views while distinguishing:

- true operational breaks from payments that are legitimately pending;
- contractual timing from late settlement;
- FX execution, fee, and beneficiary-settlement variance; and
- required client money from cash actually held in a designated account.

The objective is not to treat every difference as an error. It is to determine which differences are expected economics or timing effects and which require operational attention.

## System Workflow

```text
Customer funding
      ↓
Customer balance
      ↓
USD→CNY payment instruction
      ↓
Internal booking / quoted FX
      ↓
Partner processing / executed FX
      ↓
External settlement
      ↓
Reconciliation
      ↓
Treasury analytics
```

The client-money control is a separate but connected view:

```text
Customer balances
        +
Pending outbound obligations
        ↓
Required client money
        ↕
Designated account balance
        ↓
Surplus / shortfall control
```

## What I Built

1. **Payment simulation**
   - USD→CNY transactions processed through two fictional partners;
   - partner-specific fees, cutoffs, processing times, and T+1/T+2 settlement;
   - customer-facing quoted FX separated from partner-executed FX; and
   - customer balances and business-day settlement calendars.

2. **Reconciliation framework**
   - internal ledger bookings reconciled to external settlements;
   - operational payment states with explicit precedence;
   - separate fee, FX funding, CNY settlement, and timing variances; and
   - aging for payments that remain open beyond their expected date.

3. **Treasury reconciliation analytics**
   - partner settlement performance;
   - before-cutoff versus after-cutoff behavior;
   - quote-to-execution duration; and
   - payment-size and FX funding exposure.

4. **Simplified safeguarding/client-money control**
   - customer subledger and pending outbound obligations;
   - independent designated-account roll-forward;
   - daily required client-money obligations versus designated-account cash; and
   - operating top-up and sweep timing across the US banking calendar.

## Key Results

**SIMULATION RESULTS — generated sample only**

| Area | Metric | Result |
|---|---|---:|
| Reconciliation | Operationally `MATCHED` payments | 461 |
| Reconciliation | `TIMING_PENDING` payments at the as-of date | 13 |
| Reconciliation | Late but ultimately operationally matched settlements | 16 |
| Reconciliation | Absolute FX funding variance | $4,217.72 |
| Reconciliation | Fee variance | $0.00 |
| Reconciliation | CNY settlement variance | ¥0.00 |
| Partner analytics | Partner A late-settlement rate | 3.77% |
| Partner analytics | Partner B late-settlement rate | 3.06% |
| Cutoff analytics | Average quote-to-execution time, after cutoff | 32.01 hours |
| Cutoff analytics | Average quote-to-execution time, before cutoff | 3.79 hours |
| Cutoff analytics | Normalized absolute FX variance, after cutoff | 16.47 bps |
| Cutoff analytics | Normalized absolute FX variance, before cutoff | 11.11 bps |
| Safeguarding | Daily controls | 90 |
| Safeguarding | Shortfall days / consecutive episodes | 14 / 5 |
| Safeguarding | Average shortfall | $21.13 |
| Safeguarding | Maximum shortfall | $34.86 |
| Safeguarding | Longest shortfall episode | 5 calendar days |

## Selected Findings

1. **Cutoff timing was associated with both longer execution time and higher normalized FX variance.** After-cutoff payments averaged 32.01 hours from quote to execution versus 3.79 hours before cutoff; normalized absolute FX variance was 16.47 bps versus 11.11 bps.

2. **Partner transaction volume did not explain absolute FX variance by itself.** Partner A processed 270 payments and Partner B processed 204, yet their absolute FX funding variances were similar at $2,110.35 and $2,107.37. Partner B's normalized variance was higher: 15.49 bps versus 11.85 bps.

3. **Late settlement was not automatically an unresolved break.** Sixteen payments settled after their contractual date but agreed with the committed beneficiary amount and were ultimately classified as `MATCHED`.

4. **Simulated safeguarding shortfalls emerged from execution residuals and cash-transfer timing rather than injected failure labels.** Six weekend days and one US holiday extended active shortfall episodes.

The duration/FX relationship was not monotonic across every duration bucket, so these results do not establish a general causal relationship. All findings describe this generated sample only and are not industry benchmarks.

## Key Design Principle: No Planted Breaks

The simulator does not inject target mismatch percentages, target reconciliation failure rates, arbitrary missing settlements, or arbitrary safeguarding shortfalls. Differences emerge from observable business mechanics:

- FX movement between quote and execution;
- contractual cutoff rules and partner processing time;
- settlement calendars and value dates;
- execution residuals; and
- operating top-up and sweep timing.

This keeps the control design independent: reconciliation and safeguarding logic analyze the records they receive rather than reading hidden answer labels from the simulator.

## Technical Stack

- **Python:** deterministic seeded simulation, partner processing, and designated-account cash flows;
- **SQL / SQLite:** reconciliation states, control calculations, validation tests, and Treasury analytics;
- **CSV:** transparent input and output datasets;
- **Git / GitHub:** version control and project documentation.

USD and CNY calculations use `Decimal` arithmetic, including ceiling-to-cent funding of a fixed beneficiary CNY commitment.

## Repository Structure

```text
src/                 Payment and designated-account simulation
sql/                 Reconciliation, validation, analytics, and safeguarding SQL
data/                Synthetic source records and generated analytical outputs
PROJECT_SPEC.md       Business requirements and control definitions
DECISIONS.md          Explicit assumptions and modeling decisions
```

## Reproduce the Analysis

Run these commands from the repository root. Python 3 and the SQLite command-line interface are required.

```bash
# 1. Generate the synthetic payment, settlement, and customer-balance data
python3 -B src/generate_transactions.py

# 2. Run production reconciliation and export reconciliation results
sqlite3 data/reconciliation.db < sql/reconciliation.sql

# 3. Validate reconciliation-state precedence with isolated fixtures
sqlite3 :memory: < sql/test_reconciliation.sql

# 4. Produce reconciliation analytics
sqlite3 data/reconciliation.db < sql/reconciliation_analytics.sql

# 5. Generate the independent designated-account roll-forward
python3 -B src/generate_designated_account.py

# 6. Run the daily simplified client-money control
sqlite3 data/safeguarding.db < sql/safeguarding.sql

# 7. Validate safeguarding identities and calendar rules
sqlite3 data/safeguarding.db < sql/test_safeguarding.sql

# 8. Analyze safeguarding shortfalls and their settlement drivers
sqlite3 data/safeguarding.db < sql/safeguarding_analysis.sql
```

The default transaction run uses seed `20250301` and produces an end-of-day March 31, 2025 as-of extract.

## Assumptions & Limitations

- All transactions, customers, and payment partners are synthetic; `GlobalPay` is fictional.
- The project does not use or represent Airwallex systems, processes, or data.
- USD→CNY payment, fee, FX, and settlement mechanics are deliberately simplified.
- The safeguarding framework is educational and does not implement any jurisdiction's regulatory safeguarding methodology.
- Results describe one deterministic simulation and are not industry benchmarks.
- The project demonstrates Treasury analytical and control reasoning, not production payment infrastructure.
