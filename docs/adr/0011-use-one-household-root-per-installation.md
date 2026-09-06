# ADR-0011: Use one Household root per Pryvance installation

Status: Proposed
Date: 2026-09-06

## Context

Pryvance is a self-hosted household financial platform rather than a multi-tenant SaaS product. The target feature set supports many People, children, Financial Entities, Assets, Accounts, filing contexts, and privacy policies inside one household, but it does not need to isolate unrelated households inside one database/application instance.

Building generic multi-tenancy would add tenant routing, data-isolation, administration, migration, authorization, backup, and operational complexity without serving the intended deployment model.

## Decision Drivers

- Keep self-hosted deployment and recovery simple.
- Avoid SaaS-style tenant complexity unrelated to the product goal.
- Permit arbitrary internal household complexity without hard-coded spouse assumptions.
- Keep backups/restores scoped to one Household financial universe.
- Preserve the ability for different Household members to have separate identities/privacy within that one installation.

## Considered Options

1. **One Household root per installation** — simplest deployment/security/backup model and matches intended use; separate unrelated households require separate installations.
2. **Multiple unrelated Households per installation** — potentially useful for hosting family/friends; substantially increases isolation/admin complexity.
3. **Global multi-tenant SaaS architecture** — unnecessary operational/product scope.

## Decision

A Pryvance installation will have exactly one Household root. It may contain any number of People, Financial Entities, Assets, Accounts, and User Identities, but unrelated households are represented by separate Pryvance installations.

## Consequences

- Domain/API queries can assume one Household collaboration root while still enforcing per-Person visibility.
- Backups/restores represent one Household universe.
- There is no tenant ID threaded through every domain table merely for hypothetical SaaS hosting.
- A user who wants to host unrelated households runs separate deployments/databases.
- This decision does not weaken multi-user application privacy inside the Household.
