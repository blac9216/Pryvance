# Pryvance API contract

Kind: reference

This document defines the initial application-facing REST contract and conventions. It is a target contract for implementation; provider-specific APIs remain behind adapters and are not exposed directly to the React client.

## Conventions

Base path: `/api/v1`

Media type: `application/json` unless uploading/downloading binary evidence.

Identifiers: opaque UUIDs represented as strings. Clients must not infer type, order, or ownership from identifiers.

Money representation:

```json
{
  "amount": "187.43",
  "currency": "USD"
}
```

Decimal monetary values are serialized as strings to avoid client floating-point ambiguity.

Dates: `YYYY-MM-DD` for financial dates; RFC 3339 UTC timestamps for instants.

Pagination: cursor-based for large ledgers.

```json
{
  "items": [],
  "nextCursor": null
}
```

Optimistic concurrency: mutable derived resources expose an `etag`/version. Updates that depend on prior state use `If-Match`; conflicting writes return `409` or `412`.

Idempotency: import, settlement, backup-run, and other retry-sensitive creation endpoints accept `Idempotency-Key`.

## Error shape

```json
{
  "type": "validation_error",
  "title": "Allocation does not reconcile",
  "status": 422,
  "detail": "Beneficiary allocations total 180.00 but the event amount is 187.43.",
  "traceId": "...",
  "errors": {
    "allocations": ["Allocation total must equal event amount."]
  }
}
```

Errors use Problem Details semantics. Sensitive provider/document/model/backup-key content must not be copied into errors.

## Household and parties

### `GET /household`
Returns the current Household summary and viewer-visible coverage.

### `GET /parties`
Lists viewer-visible People and Financial Entities.

### `POST /parties/persons`
Creates a Person. Connecting accounts is not required.

### `POST /parties/entities`
Creates a Financial Entity such as a rental property.

### `GET /parties/{partyId}`
Returns Party metadata, viewer-visible coverage, and permitted summary fields.

## Accounts

### `GET /accounts`
Filters: `partyId`, `type`, `scope`, `connectionStatus`, `includeClosed`.

### `GET /accounts/{accountId}`
Returns ownership, visibility summary, balance when permitted, coverage, source connections, and sync state.

### `POST /accounts`
Creates a manual Account or placeholder account awaiting provider mapping.

### `PATCH /accounts/{accountId}`
Updates user-managed metadata, ownership, and permitted visibility configuration. Provider source identity is immutable after mapping except through an explicit remap workflow.

### `GET /accounts/{accountId}/coverage`
Returns date/fact-family coverage such as transactions, balances, holdings, contributions, and cost basis.

## Financial events

### `GET /financial-events`
Primary ledger query.

Filters may include:

- `from`, `to`
- `accountId`
- `partyId`
- `reportingScopeId`
- `categoryId`, `subcategoryId`
- `merchant`
- `role`
- `reviewStatus`
- `hasReceipt`
- `entityId`
- `minAmount`, `maxAmount`

Private records are filtered server-side before serialization.

### `GET /financial-events/{eventId}`
Returns normalized event data, source references, allocations, obligations, evidence, and viewer-visible provenance.

### `PATCH /financial-events/{eventId}`
Updates mutable interpretation fields such as normalized merchant, notes, category allocation, beneficiary allocation, privacy override, and review state. Source Records are never edited here.

### `POST /financial-events/{eventId}/allocations`
Creates/replaces a validated allocation set for a dimension.

### `POST /financial-events/{eventId}/obligations`
Creates an explicit responsibility difference where domain rules permit it.

## Source records and imports

### `POST /imports`
Creates an import session for an Account and source type.

### `POST /imports/{importId}/file`
Uploads CSV/OFX/QFX source material.

### `GET /imports/{importId}/preview`
Returns parsed record counts and deterministic analysis:

```json
{
  "detected": 3214,
  "new": 3007,
  "alreadyImported": 176,
  "possibleDuplicates": 18,
  "conflicts": 13
}
```

### `POST /imports/{importId}/commit`
Idempotently persists approved Source Records and queues normalization/reconciliation.

### `GET /imports`
Returns import history and source date ranges.

## Review inbox

### `GET /review-items`
Filters: `type`, `status`, `confidenceMax`, `entityType`, `reportingScopeId`.

### `GET /review-items/{reviewItemId}`
Returns reason, evidence, suggestions, and allowed resolutions.

### `POST /review-items/{reviewItemId}/resolve`
Example:

```json
{
  "resolution": "accept_suggestion",
  "createRule": true
}
```

Resolution commands are domain-specific and validated by the owning module.

## Rules

### `GET /rules`
Returns deterministic rules, priority, enabled state, match count, and last match.

### `POST /rules`
Creates a rule from explicit criteria/actions.

### `PATCH /rules/{ruleId}`
Changes priority, enabled state, criteria, or action.

### `POST /rules/{ruleId}/test`
Evaluates a rule against historical records without mutation.

## Budgets

### `GET /budgets/{year}`
Returns the effective Budget for a Reporting Scope.

### `PUT /budgets/{year}`
Creates/replaces year-specific targets without rewriting other years.

### `GET /budget-status`
Parameters: `year`, optional `month`, `reportingScopeId`.

Category status includes annual target, expected-through-period, actual, variance, remaining annual budget, months remaining, and safe monthly spend.

## Household funding

### `GET /funding-plans/{year}`
Returns effective Household Funding Plans and contribution policy.

### `PUT /funding-plans/{year}`
Creates/replaces future/effective plan configuration subject to versioning rules.

### `GET /funding-status`
Parameters: `year`, `month`.

Returns target, cash contribution, approved credits, effective contribution, unresolved candidate credits, and remaining amount per contributing Party.

### `POST /obligations/{obligationId}/disposition`
Allowed dispositions include `reimburse`, `credit_contribution`, and `leave_outstanding` when domain rules allow.

### `POST /settlements`
Creates a Settlement and applies it to selected Obligations. It does not create income or expense.

## Receipts

### `POST /receipts`
Uploads/captures receipt evidence and queues processing.

### `GET /receipts`
Filters by processing/match/review state.

### `GET /receipts/{receiptId}`
Returns original metadata, extracted facts, line items, reconciliation, match candidates, and provenance.

### `POST /receipts/{receiptId}/match`
Confirms or changes the associated Financial Event.

### `PUT /receipts/{receiptId}/line-items`
Updates user-verified normalized line items and allocations while preserving original extraction provenance.

## Documents

### `POST /documents`
Uploads immutable financial evidence and queues classification/extraction.

### `GET /documents`
Filters: `documentType`, `partyId`, `entityId`, `taxYear`, `issuer`, `verificationStatus`.

### `GET /documents/{documentId}`
Returns metadata and extracted facts permitted to the viewer.

### `GET /documents/{documentId}/content`
Authorized binary/preview stream. Storage path is never exposed.

### `POST /documents/{documentId}/facts/{factId}/verify`
Marks an extracted fact verified/corrected without replacing the original source artifact.

## Investments and net worth

### `GET /investment-accounts`
Returns investment accounts permitted for the viewer and source coverage by fact family.

### `GET /investment-accounts/{accountId}/holdings`
Returns holdings for an as-of date when permitted.

### `GET /investment-accounts/{accountId}/activity`
Returns investment Financial Events such as contributions, buys, sells, dividends, fees, and distributions.

### `GET /net-worth`
Parameters: `reportingScopeId`, optional `asOf`.

Returns Known Net Worth, components, coverage notices, and whether the result is complete for tracked scopes.

## Rental / financial entity views

### `GET /entities/{entityId}/financial-summary`
Returns income, operating expense, selected liability/capital metrics, owner contributions, and coverage for a Financial Entity.

The endpoint is a projection over shared ledger/document models; it does not imply a separate rental transaction store.

## Analytics

### `POST /analytics/query`
Executes a typed, deterministic analytics request from the UI. Natural-language AI uses the same internal query services rather than generating SQL.

### `POST /ai/ask`
Optional local-AI analysis endpoint.

Request:

```json
{
  "question": "Why was August household spending higher than normal?",
  "reportingScopeId": "...",
  "period": { "from": "2026-08-01", "to": "2026-08-31" }
}
```

Response contains narrative plus structured citations to internal entities/evidence. The endpoint is unavailable when AI is disabled.

## Backup and disaster recovery administration

Backup administration is privileged and never exposes the backup recovery secret through ordinary API responses.

### `GET /backup/status`
Returns backup configuration and health without secrets:

```json
{
  "configured": true,
  "destinationType": "google_drive",
  "lastSuccessfulBackupAt": "2026-09-05T03:00:00Z",
  "lastVerifiedBackupAt": "2026-09-05T03:02:11Z",
  "lastRestoreTestAt": "2026-09-01T12:30:00Z",
  "lastRestoreTestStatus": "passed",
  "recoverySecretVerified": true,
  "retainedBackupCount": 14
}
```

### `GET /backup/destinations`
Lists configured Backup Destinations and sanitized connection state. Provider credentials are never returned.

### `POST /backup/destinations`
Creates/configures a provider adapter such as Google Drive or another supported destination. Provider-specific OAuth details are administrative transport concerns and remain outside the stable domain contract.

### `POST /backup/recovery-secret`
Initializes or rotates the local backup recovery secret through an explicit privileged workflow. The response may return a one-time recovery export only when the operation is specifically designed for secure display/download; the secret is never retrievable later through a normal GET.

Rotation must not silently orphan existing retained backups. A rotation workflow either re-wraps supported backup keys or records which recovery secret generation is required for each retained backup.

### `POST /backup/recovery-secret/verify`
Verifies that the operator can supply the independently stored recovery material before offsite backup is considered fully configured.

### `POST /backup/runs`
Starts an idempotent Backup Set creation, local encryption, upload, and remote verification job.

Response returns a job/run identifier, not the backup contents.

### `GET /backup/runs`
Lists backup runs with status such as `creating`, `encrypting`, `uploading`, `verifying`, `succeeded`, and `failed`.

### `GET /backup/runs/{runId}`
Returns manifest-level health metadata, encrypted size/hash where safe, destination object identifier, errors sanitized of secrets, and retention state.

### `POST /backup/restore-tests`
Downloads a selected known-good Backup Envelope into isolated temporary storage, decrypts/authenticates it, verifies the manifest and schema compatibility, and performs the supported non-destructive restore validation path.

It must never overwrite the live installation.

### `POST /backup/restores/prepare`
Validates a selected Backup Envelope and produces a short-lived restore plan describing compatibility, database/object counts, and required actions. Destructive restore requires an explicit administrative confirmation step outside normal application navigation.

### `PUT /backup/retention-policy`
Updates the retention policy. Pruning cannot delete the last known-good verified recovery point and is not executed as part of a failed/unverified backup run.

## Provider administration

Provider management endpoints are administrative and separate from domain resources. They may create connections, run sync, and expose sanitized status but never return provider secrets.

Provider-specific transaction payloads are retained in Source Records for evidence/debugging but are not part of the stable client contract.
