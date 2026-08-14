# USD–CNY Treasury Reconciliation & Safeguarding
## Project Brief

*A synthetic cross-border payments case study examining reconciliation, FX execution, settlement timing, and simplified client-money controls.*

I built this project to examine how Treasury should interpret differences across a cross-border payment lifecycle. **All transactions, customers, partners, and results are synthetic.** `GlobalPay` and both payment partners are fictional.

## 1. The Treasury Problem

A USD→CNY payment creates several views of the same transaction: customer obligation and balance; internal payment booking, quoted FX, expected fee, and expected settlement date; actual partner processing, executed FX, and value date; beneficiary settlement; and designated cash position.

Those views will not always agree at the same time. A booked payment may remain within its contractual settlement window. The USD required to fund a fixed CNY commitment may change between quote and execution. Cash may leave the designated account on value date while an operating top-up follows on the next US banking day.

The Treasury question is therefore not simply, “Do the numbers match?” It is: **What caused the difference, what kind of difference is it, and what action—if any—is required?** I used three categories:

1. **Operational difference:** a missing, overdue, duplicated, or incorrect settlement outcome requiring investigation.
2. **Timing difference:** a payment is pending or settles later than expected, without necessarily being economically or operationally incorrect.
3. **Economic difference:** fee or FX execution changes the funding economics while the beneficiary settlement can still be correct.

## 2. How I Structured the Project

The project follows a control and analytical workflow:

```text
Synthetic customer activity → internal booking → independent partner processing
→ external settlement → reconciliation → root-cause analytics
→ simplified client-money control
```

I deliberately separated the internal and external perspectives. Both originate from the same accepted payment instruction, but the partner process does not create settlement rows by copying ledger-calculated amounts or dates and then perturbing them. Internal booking freezes the customer commitment, expected fee, and contractual settlement expectation. External processing independently applies the partner contract, execution-time FX, processing duration, and value-date rules.

Reconciliation therefore evaluates observable records rather than inheriting an answer from the simulator. Differences arise from cutoffs, calendars, FX movement, service time, and cash-transfer timing—not planted labels or target exception rates.

## 3. Reconciliation: Difference Does Not Always Mean Break

The reconciliation framework keeps operational state separate from analytical variance. In the generated March 31 as-of sample, 461 payments were `MATCHED` and 13 were `TIMING_PENDING`. Sixteen payments settled later than their contractual expectation but ultimately agreed with the committed beneficiary amount and remained operationally matched.

The matched population contained $4,217.72 of absolute FX funding variance, while fee variance was $0 and CNY settlement variance was ¥0. The FX variance reflects the change in USD required to fund the fixed CNY commitment at the executed rate. It does not imply that the beneficiary received the wrong amount.

A transaction can therefore have non-zero economic variance and still reconcile correctly. Settlement lateness is tracked separately from final reconciliation state. A payment may require investigation while overdue, but if it subsequently settles correctly, the historical lateness remains an operational performance signal rather than an unresolved reconciliation break. The 461-to-13 outcome describes this sample only, not a real-world target match rate.

## 4. What the Analytics Revealed

Partner A processed 270 transactions with a 3.77% late-settlement rate; Partner B processed 204 with a 3.06% late rate. Their absolute FX funding variances were almost identical—$2,110.35 for A and $2,107.37 for B—despite different counts. Normalized by expected FX funding, Partner B was higher at 15.49 bps versus 11.85 bps for Partner A.

The sample also showed an association between cutoff timing, execution duration, and FX variance. After-cutoff payments averaged 32.01 hours from quote to execution versus 3.79 hours before cutoff. Their normalized absolute FX variance was 16.47 bps versus 11.11 bps. This does not establish causation, but it identifies after-cutoff processing and longer quote-to-execution windows as useful dimensions for further Treasury review.

The relationship was not monotonic. The 72+ hour bucket had the highest normalized absolute variance at 20.24 bps, but only 15 observations; the 24–72 hour bucket was lower than the 8–24 hour bucket. Payment-size buckets were also non-monotonic. More periods and observations would be needed before drawing broader conclusions.

## 5. Simplified Client-Money / Safeguarding Control

Once a payment is accepted, its USD amount leaves the modeled customer subledger balance, but the underlying client obligation does not disappear before external settlement. It moves into a pending outbound obligation. The simplified daily requirement is therefore:

```text
Required client money
= customer subledger obligations
+ pending outbound obligations
```

I compare that requirement with designated-account cash to calculate a daily surplus or shortfall. The designated account is independently rolled forward using cleared customer receipts, actual partner FX funding debits, partner fee debits, company top-ups, and company sweeps. It is not back-solved from the required amount or desired control result.

That independence makes a shortfall meaningful within the model: it represents a difference between observable obligations and separately generated cash flows. This is an educational control model, not a jurisdiction-specific regulatory safeguarding methodology.

## 6. What the Safeguarding Analysis Revealed

Across 90 daily controls, the model produced 14 shortfall days grouped into five episodes. Total daily shortfall exposure was $295.82, the average was $21.13, the maximum was $34.86, and the longest episode lasted five calendar days. The exposure total counts a carried shortfall at each daily cutoff, so it is not a distinct cash-loss amount.

The analysis identified 21 negative-residual driver settlements totaling $244.02 and 24 positive-residual settlements totaling $87.22. The largest individual driver was `PAY-000087` at -$60.20. The residual bridge tied exactly to the daily control: the maximum unexplained bridge difference was $0.00.

These shortfalls were not injected as arbitrary failures. They emerged when settlement economics produced negative execution residuals and the corresponding company top-up posted on the next US banking day. Six weekend days and the January 20 US holiday extended active episodes. Within this educational model, that is a control and investigation signal—not a statement that a regulatory breach occurred.

## 7. From Finding to Treasury Action

| Observation | Interpretation | Illustrative Treasury response |
|---|---|---|
| Payment not settled; expected date has not passed | Timing state | Monitor through the contractual date and avoid premature escalation. |
| Payment remains unsettled after the expected date | Operational exception | Age the item, confirm partner status, investigate the payment path, and escalate under the applicable threshold. |
| FX funding differs from internal expectation | Economic variance | Review execution timing, quoted and executed rates, and exposure; do not automatically classify it as payment failure. |
| Partner fee differs from contractual expectation | Fee/control variance | Validate contract and rate configuration, then investigate the partner charge. |
| Beneficiary CNY differs from the committed amount | Settlement exception | Investigate promptly because the customer-facing obligation did not settle as booked. |
| Designated cash is below the simplified client-money requirement | Client-money control exception | Identify the residual and timing drivers, ensure the required funding or top-up, and investigate persistence. |

These responses illustrate how I would structure investigation in the model. Actual escalation thresholds, ownership, and regulatory treatment would depend on a firm's policies and jurisdiction.

## 8. What I Learned

1. **Reconciliation is classification and judgment, not only matching.** The same numerical difference can require monitoring, economic explanation, or operational escalation depending on its cause and lifecycle stage.
2. **FX, fees, settlement amount, and value date must remain separate.** Each dimension points to a different control question and a different potential action.
3. **Root-cause analysis needs absolute and normalized measures.** Transaction volume, payment size, or total dollars alone can obscure relative exposure and small-sample effects.
4. **Client-money monitoring follows the obligation through the lifecycle.** Summing customer balances alone omits accepted outbound funds that remain attributable to customers until settlement.

## Project Takeaway

Effective Treasury reconciliation is not about forcing every difference to zero. It is about maintaining transparent views of obligations and cash, separating economic and timing effects from true operational exceptions, and linking each exception to an appropriate investigation or funding action.

## 9. Limitations

- All data is synthetic, `GlobalPay` is fictional, and the partners are fictional.
- USD→CNY payment, FX, fee, and settlement mechanics are simplified and deterministic.
- The project does not use or reproduce Airwallex systems, processes, or data.
- The safeguarding control does not implement any jurisdiction-specific regulatory methodology.
- This is not production payment infrastructure, and the findings are not industry benchmarks.

For implementation details and assumptions, see the [repository overview](../README.md), [project specification](../PROJECT_SPEC.md), and [decision log](../DECISIONS.md).
