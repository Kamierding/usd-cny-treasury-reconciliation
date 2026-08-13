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
4. Validate classification precedence and counterexamples.
5. Add simplified safeguarding calculation.
6. Perform root-cause analysis.
7. Stop adding features and prepare to explain the project clearly.

## Current status

**Stage 0 — Specification complete. No implementation code yet.**

See `PROJECT_SPEC.md` for requirements and `DECISIONS.md` for explicit modeling assumptions.
