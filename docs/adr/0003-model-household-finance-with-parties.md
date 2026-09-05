# ADR-0003: Model people and financial entities as Parties

Status: Proposed
Date: 2026-09-05

## Context

Pryvance must support personal, shared, child, investment, and rental-property finances without assuming a two-person household or requiring every household member to connect all accounts. Account ownership, economic benefit, contribution responsibility, and reporting scope must remain distinct.

## Decision Drivers

- Support any number of household members, including future children.
- Support incomplete participation and partial account visibility.
- Reuse the same mechanics for rental properties and future financial entities.
- Avoid hard-coded spouse/owner fields that force later schema rewrites.
- Keep funding source separate from beneficiary and responsibility.

## Considered Options

1. **General Party abstraction with Person and Financial Entity kinds** — flexible and consistent across household/property use cases; requires explicit relationship modeling.
2. **Separate spouse/child/property tables with feature-specific foreign keys** — straightforward initially; creates duplicated allocation and ownership logic.
3. **Treat accounts as the primary ownership unit** — simple transaction model; cannot represent personally funded shared expenses or people with no connected accounts cleanly.

## Decision

Pryvance will use Party as the canonical actor in ownership, allocation, obligation, contribution, and reporting relationships, with Person and Financial Entity as the initial Party kinds.

## Consequences

- A Person may exist without any connected Account.
- Children use the same Person model with guardian permissions layered separately.
- Rental properties are Financial Entities rather than a separate transaction universe.
- Account ownership never implies economic allocation or settlement responsibility.
- Reporting scopes can project Household, Person, or Financial Entity views over one ledger.
