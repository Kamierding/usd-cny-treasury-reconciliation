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

**Status:** Provisional; confirm during simulator design review.

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
