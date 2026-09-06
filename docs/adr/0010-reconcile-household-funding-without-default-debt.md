# ADR-0010: Reconcile Household funding without default interpersonal debt

Status: Proposed
Date: 2026-09-06

## Context

Pryvance needs to help partners fund shared expenses/savings fairly without making the relationship feel like accounts receivable between spouses. Actual contribution proportions may differ from fair targets because income is estimated, evidence arrives later, direct-deposit percentages change infrequently, or one Person pays a shared cost personally.

A later W-2 or payroll fact may reveal that a prior-year proportional split should have been different. Treating every variance as `Alex owes Jordan` would be technically possible but undesirable as the default Household model.

## Decision Drivers

- Support shared-finance fairness without business-like debtor/creditor language by default.
- Let partners retain separate accounts/discretionary income.
- Allow annual/historical reconciliation when better income evidence arrives.
- Allow correction through future direct-deposit/contribution percentages.
- Preserve explicit Obligation/Settlement semantics when a Household intentionally wants them.

## Considered Options

1. **Funding Reconciliation with configurable correction policy; direct debt only by opt-in** — matches partnership model and supports flexible correction; requires separate funding/debt concepts.
2. **Every contribution variance creates an Obligation** — mechanically clear; overstates interpersonal debt and produces unwanted settlement churn.
3. **Ignore historical variance** — simplest; cannot maintain fairness when estimates/income change.

## Decision

Pryvance will represent shared-funding fairness through Funding Reconciliation. It compares target and accepted actual contributions and carries a cumulative variance under the Funding Plan's correction policy.

Supported correction policies may include informational-only, carry-forward, correct over N periods, adjust future percentages, one-time corrective contribution, reset/forgive, or explicit conversion of selected variance into an Obligation.

Funding variance does not become interpersonal debt unless the Household explicitly chooses a debt/settlement disposition.

## Consequences

- Household partners can use one shared funding mechanism rather than frequent reimbursements.
- Newly discovered annual income facts can trigger retrospective fairness analysis and future percentage recommendations.
- Direct-deposit percentages can be adjusted infrequently while variance carries forward across periods/years.
- Personally funded shared expenses may be credited under Funding Plan policy without automatically creating reimbursement debt.
- Obligation/Settlement remains available for non-spousal reimbursements, explicit loans, or chosen direct settlements.
- Forecasting/planning must distinguish funding variance from payable debt.
