# ADR-0001: Adopt the design-docs documentation standard

Status: Proposed
Date: 2026-09-05

## Context

Pryvance begins as an empty repository but is expected to accumulate durable architecture, domain, security, API, and workflow decisions over a long-lived personal-finance product. The owner already maintains a `design-docs` skill in the `storage` repository that defines ADR, C4, glossary, rationale, and Diátaxis conventions.

## Decision Drivers

- Keep architecture history reconstructable from the repository.
- Prevent design vocabulary and rationale from drifting as AI-assisted development accelerates.
- Reuse the owner's existing documentation conventions across repositories.
- Avoid committed transient specs and planning artifacts becoming stale pseudo-authority.

## Considered Options

1. **Adopt the existing design-docs standard** — consistent with the owner's other work and provides automated drift checks; adds documentation ceremony.
2. **Maintain a single free-form architecture document** — low setup cost; decisions and history become difficult to audit.
3. **Use external/wiki-only design notes** — flexible; disconnects design truth from the code revision that implements it.

## Decision

Pryvance adopts the owner's design-docs standard with C4 architecture, MADR ADRs, a root glossary, Diátaxis directories, rationale indexes, and documentation integrity checks.

## Consequences

- Durable architectural decisions are recorded as ADRs and indexed.
- The repository contains outcomes, not transient design specs, interrogation logs, or plans.
- Domain terminology is maintained in `CONTEXT.md` and used consistently by the design set.
- Documentation structure is checked in CI and may require maintenance alongside code changes.
