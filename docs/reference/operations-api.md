# Operational and integration API contract

Kind: reference

This is an authoritative companion to [`api-contract.md`](api-contract.md) for storage lifecycle, jobs, AI/provider configuration, mail-ingestion rules, FX providers, and detailed recovery operations. All endpoints use the same `/api/v1`, authorization, Problem Details, idempotency, Money, pagination, and secret-handling conventions defined by the main API contract.

## Storage targets

### `GET /storage/targets`
Returns sanitized configured Storage Targets, capabilities, trust/encryption requirements, health, capacity when available, and whether the target is recovery-eligible.

### `POST /storage/targets`
Creates a local/mounted/cloud target. Cloud targets reference an External Connection; credentials are not embedded in the Storage Target resource.

### `PATCH /storage/targets/{targetId}`
Updates capabilities/policy-compatible configuration. Changes that would leave required objects unprotected are rejected or require an explicit migration plan.

### `POST /storage/targets/{targetId}/verify`
Runs target access/integrity/capacity checks and returns a Job ID when asynchronous.

## Storage policy and status

### `GET /storage/policy`
Returns hot/cold/archive/protection rules, target assignments, retention and capacity thresholds.

### `PUT /storage/policy`
Updates policy. Validation explains whether cold target also satisfies object disaster recovery or whether an independent recovery target is required.

### `GET /storage/status`
Returns hot/cold byte/object counts, archive-pack state, unprotected objects, reclaimable bytes, target health and last archive/verification/compaction results.

### `GET /stored-objects/{objectId}/replicas`
Returns authorized/sanitized replica state without exposing raw filesystem paths/provider secrets.

### `POST /stored-objects/{objectId}/rehydrate`
Creates an interactive-priority `object.rehydrate` Job. Idempotent if a verified hot replica already exists or compatible rehydration is running.

## Archive packs

### `GET /storage/archive-packs`
Filters by target/state/created range and returns pack size/object count/reclaimable bytes/verification state.

### `GET /storage/archive-packs/{packId}`
Returns sanitized manifest metadata and health.

### `POST /storage/archive-packs/compact`
Starts policy-driven compaction; accepts optional target/pack selection and returns Job ID. It never mutates a sealed pack in place.

## FX configuration and observations

### `GET /fx/providers`
Returns sanitized configured FX-rate providers and capability/health state.

### `POST /fx/providers`
Creates/configures an FX adapter/provider through an External Connection or provider-specific public/authenticated configuration.

### `PATCH /fx/providers/{providerId}`
Changes provider settings/priority/enabled state without returning secrets.

### `POST /fx/providers/{providerId}/verify`
Checks connectivity/capabilities.

### `GET /fx/rates`
Parameters include `base`, `quote`, `from`, `to`, `source`. Returns sourced FX Rate Observations and Provenance.

### `POST /fx/refresh`
Queues historical/current rate refresh for requested pair/date range. Returns Job ID.

### `GET /settings/reporting-currency`
Returns Household default/home reporting currency and display settings.

### `PUT /settings/reporting-currency`
Changes default reporting currency. It never rewrites native Money. Reports may still override currency explicitly.

## AI provider configuration

### `GET /ai/providers`
Returns sanitized configured providers/models/capabilities/local-vs-remote classification and enabled state.

### `POST /ai/providers`
Creates a provider configuration. Secret credentials are submitted through the protected setup flow and never returned.

### `PATCH /ai/providers/{providerId}`
Updates endpoint/model/capability/limits/remote classification/settings subject to authorization.

### `POST /ai/providers/{providerId}/verify`
Runs a bounded provider capability/health test without exposing Household financial data unless the explicit test requires authorized sample content.

### `POST /ai/providers/{providerId}/enable`
Enables provider. Remote providers require explicit disclosure/acknowledgement of data-egress implications.

### `POST /ai/providers/{providerId}/disable`
Disables provider without deleting audit/configuration history.

## Mail ingestion rules

### `GET /mail-ingestion-rules`
Returns authorized rules by External Connection/status/type.

### `POST /mail-ingestion-rules`
Creates an ingestion rule with connection, mailbox/folder/query/sender constraints, evidence type intent, processing policy and effective state.

### `PATCH /mail-ingestion-rules/{ruleId}`
Changes rule criteria/state subject to Audit.

### `POST /mail-ingestion-rules/{ruleId}/test`
Evaluates against provider/mail metadata without mutating the vault unless explicitly requested by a separate import action.

### `POST /mail-ingestion-rules/{ruleId}/run`
Queues `mail.ingest` under normal authorization/provider limits.

Read/send capabilities remain independent; creating an ingestion rule requires Mail Read, not Mail Send.

## Jobs

### `GET /operations/jobs`
Filters by state/type/priority/resource/correlation/time. Returns sanitized current/terminal job status.

### `GET /operations/jobs/{jobId}`
Returns type, producer/trigger, state, priority, scheduled/start/end times, attempts, progress, dependencies/correlation, and sanitized error/result references.

### `POST /operations/jobs/{jobId}/cancel`
Requests cancellation when the job type/state supports it.

### `POST /operations/jobs/{jobId}/retry`
Privileged explicit retry for eligible failed/cancelled jobs; creates/records a new attempt or retry transition without erasing prior attempts.

### `GET /operations/jobs/{jobId}/attempts`
Returns attempt history without secrets/raw document/provider payloads.

## Job schedules

### `GET /operations/schedules`
Returns persistent schedules for backup, provider polling, storage lifecycle, FX/market refresh, anomaly analysis, Scheduled Insights and other supported jobs.

### `POST /operations/schedules`
Creates a supported schedule definition.

### `PATCH /operations/schedules/{scheduleId}`
Changes cadence/enabled state. User-facing cadence is interpreted in Household timezone and persisted with explicit zone semantics.

## Alerts

The stable target taxonomy is defined in [`alert-catalog.md`](alert-catalog.md). `GET /alerts` from the main contract supports `type`, `severity`, `status`, `scope`, `source`, `from`, `to` filters.

### `POST /alerts/{alertId}/snooze`
Snoozes delivery/display escalation until a supplied instant; does not resolve the underlying condition.

### `POST /alerts/{alertId}/resolve`
Explicitly resolves alert types that require user/operator disposition. Auto-resolving alert types are resolved by their source module when the condition clears.

## Detailed recovery streams

The existing `/backup/*` administrative surface represents logical recovery orchestration. The target implementation separates database and object protection internally and exposes detailed health when useful.

### `POST /backup/database/runs`
Starts an encrypted Database Backup job independent of object archival/upload.

### `GET /backup/database/runs`
Lists database backup runs/verified artifacts.

### `GET /backup/objects/status`
Returns required-object protection health: verified recovery-eligible replicas, missing/unprotected count, target distribution and last verification.

### `POST /backup/objects/verify`
Queues verification of object recovery requirements without forcing duplicate upload of objects whose cold replica already satisfies disaster-recovery policy.

### `GET /backup/recovery-points`
Lists logical Recovery Points combining one verified Database Backup and one Object Recovery Snapshot.

### `GET /backup/recovery-points/{recoveryPointId}`
Returns database artifact identity, object manifest/count/protection status, creation/verification times, recovery-secret generation, restore-test status and sanitized target information.

### `POST /backup/recovery-points/{recoveryPointId}/restore-test`
Queues isolated restore validation for the selected coherent recovery point.

A Recovery Point cannot be marked healthy if its database backup succeeds but required Stored Objects are not recoverable.
