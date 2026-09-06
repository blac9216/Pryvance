# ADR-0004: Preserve immutable Source Records and derive linked Financial Events

Status: Proposed
Date: 2026-09-05

## Context

Pryvance ingests overlapping financial observations from multiple providers, historical files, receipts, statements, documents, mail, and manual entry. Provider records can transition from pending to posted, be corrected, overlap imported history, or represent opposite sides of one internal movement. User interpretation can also change without the source observation being wrong.

A single mutable transaction row would destroy evidence needed for deduplication, reconciliation, audit, historical coverage, and explainability. At the same time, a strict one-source-to-one-transaction model cannot cleanly represent linked credit-card payments, multi-source evidence, or corrections.

## Decision Drivers

- Preserve exact source observations.
- Make re-import/synchronization idempotent.
- Support pending→posted, correction/supersession, duplicate and related-source relationships.
- Represent one economic event with multiple Account Entries when money moves across Accounts.
- Reconcile multiple Source Records to one event/entry without deleting evidence.
- Keep user corrections in the derived layer while preserving source history.
- Allow manual observations to use the same provenance model as provider data.

## Considered Options

1. **Immutable Source Records + Source Relationships + Reconciliation Links + Financial Events/Account Entries** — strongest explainability and linking; more explicit model complexity.
2. **Immutable source row + one normalized transaction per source row** — simpler; fails multi-source/multi-entry relationships.
3. **Single mutable transaction table** — easy CRUD; loses original evidence and makes reconciliation ambiguous.
4. **Full application event sourcing** — complete mutation history; unnecessary complexity for the current target compared with Source Records + Audit Entries.

## Decision

Pryvance will store immutable Source Records and explicit Source Relationships, then derive normalized Financial Events containing one or more Account Entries. Reconciliation Links associate any number of Source Records with the event/entry they support.

Source Records are never edited to represent posting, category, privacy, merchant normalization, or corrected interpretation. New source observations plus relationships describe supersession/correction.

Manual financial entry creates a manual Source Record rather than bypassing the evidence layer.

## Consequences

- Credit-card payments can link the checking outflow and card inflow as one non-spending Financial Event.
- Internal transfers can have multiple Account Entries without double-counting spending.
- Pending and posted provider observations remain independently auditable.
- Historical file and live-provider overlap can reconcile without deleting one source.
- Deduplication/source identity remains deterministic rather than AI-owned.
- Provider/file payload evidence is independent from category, Merchant, scope, privacy and later user interpretation.
- Audit Entry records changes to derived interpretation; Source Record immutability is not used as a substitute for application mutation history.
- Storage and reconciliation complexity are higher, but financial history remains explainable and recoverable.
