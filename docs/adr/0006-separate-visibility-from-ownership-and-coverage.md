# ADR-0006: Separate visibility from ownership and data coverage

Status: Proposed
Date: 2026-09-05

## Context

Pryvance must support household cooperation without requiring every Person to expose all accounts or transactions. A spouse may share only retirement balances or household-relevant transfers; private discretionary or gift transactions may need to remain entirely undisclosed. At the same time, reports must distinguish hidden/incomplete data from zero.

## Decision Drivers

- Preserve financial independence inside a household.
- Prevent private transaction existence/details from leaking through shared views.
- Allow household calculations to use selected facts without exposing their sources.
- Make incomplete household/investment coverage explicit in reporting.
- Leave room for stronger per-user privacy later without redesigning ownership semantics.

## Considered Options

1. **Independent visibility policy and coverage models** — expressive and privacy-preserving; more authorization/reporting complexity.
2. **Account ownership implies visibility** — easy to implement; fails selective sharing and gift/privacy requirements.
3. **Binary shared/private flag** — simple; cannot express balance-only, aggregate-only, or calculation-without-detail scenarios.

## Decision

Pryvance will model account/record ownership, visibility permissions, and source-data coverage as separate concerns; authorization distinguishes detail visibility, aggregate inclusion, and household-calculation use.

## Consequences

- A Person can participate in Household Funding without exposing payroll transactions.
- Private records are filtered server-side and are not represented by placeholder rows in unauthorized views.
- Reports can label partial coverage and use `Known Net Worth` rather than presenting incomplete totals as authoritative.
- Application privacy does not claim protection against the trusted server/database administrator; cryptographic client-side privacy is a separate future decision.
