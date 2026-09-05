# ADR-0004: Preserve immutable Source Records and derive Financial Events

Status: Proposed
Date: 2026-09-05

## Context

Pryvance will ingest financial activity from multiple providers, historical files, receipts, documents, and manual corrections. Provider descriptions, pending/posted states, imported records, and later categorization or household allocations can change independently. Overwriting the imported representation would destroy evidence needed for deduplication, reconciliation, debugging, and provenance.

## Decision Drivers

- Preserve exact provider/import evidence.
- Make re-import and synchronization idempotent.
- Support pending-to-posted transitions and cross-source reconciliation.
- Let user corrections evolve without falsifying source history.
- Provide auditable provenance for every derived financial fact.

## Considered Options

1. **Immutable Source Records plus normalized Financial Events** — preserves evidence and separates source from interpretation; adds storage and mapping complexity.
2. **Single mutable transaction table** — simple CRUD model; loses original evidence and makes later reconciliation ambiguous.
3. **Event-source every application mutation** — complete history; much higher implementation complexity than the product currently requires.

## Decision

Pryvance will store immutable Source Records for provider/import facts and derive normalized Financial Events for application semantics, allocations, rules, privacy, and reporting.

## Consequences

- Provider/file payloads are retained independently from user-facing categorization.
- Deduplication uses source identity and deterministic fingerprints rather than AI judgment.
- Financial Events may reference multiple pieces of Evidence over time.
- User edits affect derived interpretation, not the original Source Record.
- Storage requirements are higher, but financial history remains explainable and recoverable.
