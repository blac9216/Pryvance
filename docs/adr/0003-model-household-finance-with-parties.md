# ADR-0003: Model people and financial entities as Parties

Status: Proposed
Date: 2026-09-05

## Context

Pryvance must support arbitrary household members, children, businesses, LLCs, trusts, joint/shared finances, partial participation, investments, and property without hard-coding spouse/child/property-specific ownership fields. Account ownership, legal/economic actors, assets, economic attribution, visibility, and funding responsibility must remain distinct.

A property may be owned directly by a Person or indirectly through a Financial Entity, so treating a property itself as the canonical actor would conflate `who owns` with `what is owned`.

## Decision Drivers

- Support any number of household members, including children without connected Accounts.
- Support Financial Entities that may own Accounts and Assets and may themselves be owned by Parties.
- Avoid spouse/owner/property-specific foreign keys that force later schema rewrites.
- Keep actor identity separate from Asset identity and Economic Scope allocation.
- Allow partial participation/visibility without changing ownership semantics.

## Considered Options

1. **Party abstraction with Person and Financial Entity kinds** — consistent actor model; requires separate Asset/Scope concepts.
2. **Separate spouse/child/business/property actor tables** — straightforward initially; duplicates ownership/allocation logic and conflates assets with actors.
3. **Treat Accounts as primary ownership actors** — simple transaction model; cannot represent people/entities with no connected Account or ownership chains cleanly.

## Decision

Pryvance will use Party as the canonical financial actor, with Person and Financial Entity as the initial Party kinds. Assets and Economic Scopes are separate concepts defined by the domain model; a property is an Asset, not automatically a Financial Entity.

Financial Entities may be owned by one or more Parties through effective-dated percentage relationships. Recursive entity ownership is allowed, but ownership cycles are forbidden.

## Consequences

- A Person may exist without a User Identity or connected Account.
- Children use Person plus guardian permissions rather than child-specific ledger tables.
- LLCs, trusts, and businesses reuse Party ownership/funding semantics.
- Real estate/property is modeled as Asset and may be owned directly by a Person or by a Financial Entity.
- Account ownership never implies Economic Scope allocation, visibility, or contribution responsibility.
- Net-worth traversal can follow Party→Financial Entity→Asset/Account/Liability ownership paths without inventing parallel property accounting.
