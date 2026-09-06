# ADR-0008: Separate Economic Scopes from Parties and Assets

Status: Proposed
Date: 2026-09-06

## Context

Pryvance needs to express that value can be `for Household`, `for a Person`, `for an LLC`, or `for a specific property` while separately representing who legally/economically owns Accounts, entities, and Assets.

Using Party for every allocation target would force Household and Property into actor semantics they do not naturally have. Using Asset or Account ownership as the reporting target would make shared spending and indirect ownership difficult to represent.

## Decision Drivers

- Keep `who owns` separate from `what the value belongs to`.
- Support Household, Person, Financial Entity and Asset reporting/planning using one allocation model.
- Allow a Financial Entity to own multiple Assets and be owned by one or more Parties.
- Allow one Asset to contribute to multiple reporting scopes without double counting its canonical value.
- Avoid treating a real-estate property as a legal/financial actor merely to reuse allocation fields.

## Considered Options

1. **Separate Party, Asset, and Economic Scope concepts** — clearest semantics and future ownership/net-worth traversal; adds explicit scope mapping.
2. **Make Household and Asset subtypes of Party** — one foreign key for everything; conflates actors with owned things/collaboration boundaries.
3. **Use Account/entity IDs directly as reporting scopes** — simple initially; cannot cleanly represent Household and non-account Assets.

## Decision

Pryvance will model:

- **Party** for actors (`Person`, `Financial Entity`);
- **Asset** for owned economic items such as real estate;
- **Economic Scope** as the canonical allocation/planning/reporting target representing Household, Person, Financial Entity, or Asset.

Ownership relationships remain Party-based and effective-dated. Financial Entity ownership may be recursive but cycles are forbidden.

Net-worth/reporting traversal uses canonical economic item identity and ownership paths to prevent double counting when the same Asset appears through multiple scopes.

## Consequences

- `Household` can be an allocation/planning scope without becoming a Party.
- `123 Main Street` can be an Asset/Economic Scope while `Rental LLC` remains a Financial Entity Party.
- Person→Entity→Asset ownership can contribute correctly to Person net worth.
- Budgeting/funding/property reporting can share one Economic Scope abstraction.
- Queries must distinguish scope attribution from ownership and must deduplicate canonical economic items during aggregation.
