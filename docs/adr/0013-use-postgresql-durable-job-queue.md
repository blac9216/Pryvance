# ADR-0013: Use a PostgreSQL-backed durable job queue and transactional outbox

Status: Proposed
Date: 2026-09-06

## Context

Pryvance needs reliable asynchronous work for provider synchronization, imports/reconciliation, document processing, archive/rehydration, market/FX refresh, AI, notifications, indexing, scheduled insights, and backup/recovery. In-memory queues can lose work across process/container failure. Introducing a separate message broker immediately would increase self-hosting complexity before workload justifies it.

Some state changes must reliably trigger asynchronous work. Committing domain state and separately enqueueing a job creates a crash window where one can succeed without the other.

## Decision Drivers

- Durable work across application/container restarts.
- Simple self-hosted deployment using existing PostgreSQL.
- Safe parallel workers and future worker-container extraction.
- Explicit retries, priorities, leases, idempotency and concurrency control.
- Atomic domain-change-to-job handoff where required.
- Avoid premature Redis/RabbitMQ/Kafka operations.

## Considered Options

1. **PostgreSQL job tables + leases + transactional outbox** — durable with existing infrastructure and sufficient expected scale; adds queue-table/worker discipline.
2. **In-memory background queue/timers** — simplest code; loses queued work/state on restart and cannot safely scale workers.
3. **Redis/RabbitMQ broker initially** — mature queue semantics; adds another stateful dependency and deployment/recovery surface.
4. **Kafka/event streaming** — powerful durable log; disproportionate complexity for Household-scale command/background workload.

## Decision

Pryvance will use PostgreSQL as the initial durable job queue and transactional outbox. Workers claim jobs using expiring leases, handlers are idempotent, concurrency is controlled by job/resource keys and configurable limits, and retry/attempt state is persisted.

Persistent schedules create durable Jobs rather than executing domain work directly from timers. User/API actions, outbox/domain events, provider triggers and schedules all feed the same job execution model.

The initial ASP.NET Core process may host worker loops. Additional worker processes/containers may consume the same queue later without changing job semantics.

## Consequences

- No separate broker is required for the initial deployment.
- PostgreSQL becomes part of both application state and work-coordination availability.
- Queue indexes/cleanup/connection-pool behavior must be monitored.
- At-least-once execution is assumed; exactly-once business effects come from idempotent handlers/domain constraints.
- A future broker can replace the transport only if measured scale/operational needs justify it; job/domain contracts should not depend on PostgreSQL-specific details outside the infrastructure adapter.
