# ADR-0006: Separate visibility, filing access, ownership and data coverage

Status: Proposed
Date: 2026-09-05

## Context

Pryvance must support Household cooperation without requiring every Person to expose all Accounts, transactions, Documents, or payroll. A spouse may share only retirement balances, authorize selected income facts for Household funding calculations, or keep discretionary/gift transactions entirely private. Tax preparation introduces another purpose: a Joint Tax Filing Context may require access to tax Documents that ordinary Household financial visibility does not grant.

At the same time, reports must distinguish hidden/incomplete data from a known zero, and privacy must hold across derived surfaces such as search, AI, Review, alerts, exports and semantic indexes—not only the transaction UI.

## Decision Drivers

- Preserve financial independence inside one Household.
- Prevent private-record existence/details from leaking through derived views.
- Allow selected facts to participate in shared calculations without exposing sources.
- Permit explicit Joint Tax Filing Context access without making tax documents globally shared.
- Make incomplete Coverage explicit in reporting.
- Allow current sharing revocation to remove historical detail access going forward.
- Leave room for stronger cryptographic privacy later without redesigning ownership semantics.

## Considered Options

1. **Independent ownership, Visibility Policy, Tax Filing Context access and Coverage models** — expressive and privacy-preserving; more authorization/reporting complexity.
2. **Account/Party ownership implies visibility** — easy to implement; fails selective sharing and filing-context requirements.
3. **Binary shared/private flag** — simple; cannot express balance-only, aggregate-only, calculation-only, tax-context, or purpose-specific access.

## Decision

Pryvance will model ownership, Visibility Policy, Tax Filing Context access and Coverage as independent concerns.

Authorization distinguishes at least detail visibility, aggregate inclusion, Household calculation use, filing-context use/access, and mutation/management permission.

The effective policy is evaluated before serialization, search/indexing, Review, analytics, AI/tool context, notifications, exports, counts/autocomplete, evidence traversal and other derived surfaces.

Current authorization controls current access to historical detail. Audit preserves prior policy state, but an old sharing grant does not keep old records exposed after sharing is revoked.

## Consequences

- A Person can participate in Household Funding without exposing payroll/W-2 detail.
- A Joint Tax Filing Context can grant designated preparer access to required tax Documents without globally exposing unrelated personal finances.
- An Individual filing context can still permit selected tax facts for Household calculations while source Documents remain private.
- Private records are not represented by placeholder rows or leaked through search counts, Review items, AI retrieval, alerts or exports.
- Reports can label partial Coverage and use `Known Net Worth` rather than presenting incomplete totals as authoritative.
- Derived indexes/artifacts inherit source privacy/purpose restrictions.
- Application privacy does not claim protection against the trusted server/database administrator; cryptographic client-side privacy is a separate future decision.
