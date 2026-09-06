# Pryvance API contract

Kind: reference

This document defines the target application-facing REST contract and conventions for the feature-complete Pryvance vision. Roadmap phases determine when endpoints become operational. Provider-specific APIs remain behind adapters and are not exposed directly to the React client.

The contract is versioned under `/api/v1`. Additive implementation may arrive over time without changing the target domain semantics defined here.

## Conventions

Base path: `/api/v1`

Media type: `application/json` unless uploading/downloading binary evidence or export packages.

Identifiers: opaque UUID strings. Clients must not infer type, order, or ownership from identifiers.

Money:

```json
{
  "amount": "187.43",
  "currency": "USD"
}
```

Decimal monetary values are serialized as strings. Native currency is always retained; converted values include conversion metadata.

Dates: `YYYY-MM-DD` for financial/effective dates; RFC 3339 UTC timestamps for instants/knowledge time.

Pagination: cursor-based for large collections.

```json
{
  "items": [],
  "nextCursor": null
}
```

Optimistic concurrency: mutable resources expose `etag`/version. State-dependent writes use `If-Match`; conflicting writes return `409` or `412`.

Idempotency: retry-sensitive creation/command endpoints accept `Idempotency-Key`.

Authorization is server-side and purpose-aware. A successful identifier lookup does not imply detail, aggregate, calculation, filing-context, or mutation access.

## Error shape

Problem Details semantics:

```json
{
  "type": "validation_error",
  "title": "Allocation does not reconcile",
  "status": 422,
  "detail": "Economic-scope allocations total 180.00 but event amount is 187.43.",
  "traceId": "...",
  "errors": {
    "allocations": ["Allocation total must equal the event amount."]
  }
}
```

Errors never echo raw provider payloads, credentials, document bodies, AI-sensitive context, or recovery material.

## Identity, household membership and authorization

### `GET /session`
Returns authenticated User Identity, represented Person if any, Household Membership role, active permissions/purpose context, and non-sensitive installation metadata.

### `GET /household`
Returns the single Household root and viewer-visible summary/coverage.

### `GET /household/memberships`
Administrative/authorized list of Household Memberships.

### `POST /household/memberships`
Creates/invites/links a User Identity to Household membership according to the supported authentication flow.

### `PATCH /household/memberships/{membershipId}`
Updates role/status subject to authorization.

### `GET /guardian-relationships`
Lists guardian relationships visible/manageable to the caller.

### `POST /guardian-relationships`
Creates an authorized guardian relationship for a child Person.

## Visibility policies

### `GET /visibility-policies`
Returns policies the caller is authorized to inspect.

### `POST /visibility-policies`
Creates a policy/override specifying allowed uses such as detail, aggregate, Household calculation, filing-context, and mutation.

### `PATCH /visibility-policies/{policyId}`
Creates an auditable change/version. Revoking sharing affects current access to historical detail.

### `POST /visibility-policies/evaluate`
Administrative/debug endpoint that explains the effective authorization decision for a resource/purpose without exposing unauthorized resource data.

## Parties, ownership and economic scopes

### `GET /parties`
Lists viewer-visible People and Financial Entities.

### `POST /parties/persons`
Creates a Person. A login/account connection is not required.

### `POST /parties/entities`
Creates a Financial Entity such as LLC, trust, or business.

### `GET /parties/{partyId}`
Returns permitted Party metadata, ownership relationships, Coverage, and summary facts.

### `GET /party-ownerships`
Filters: `ownerPartyId`, `entityPartyId`, `effectiveAt`.

### `POST /party-ownerships`
Creates an effective-dated ownership relationship. Cyclic entity-ownership graphs are rejected.

### `PATCH /party-ownerships/{ownershipId}`
Creates/updates effective dating without rewriting prior effective history.

### `GET /economic-scopes`
Lists authorized Household, Person, Financial Entity, and Asset scopes used for planning/reporting/allocation.

### `GET /economic-scopes/{scopeId}`
Returns scope identity, represented object, permitted Coverage and summary.

## Assets, ownership and liabilities

### `GET /assets`
Filters: `type`, `ownerPartyId`, `scopeId`, `includeDisposed`.

### `POST /assets`
Creates a manual/general Asset.

### `POST /assets/properties`
Creates a Real Estate Property specialization.

### `GET /assets/{assetId}`
Returns permitted metadata, ownership, valuations, liabilities, Evidence and Coverage.

### `PATCH /assets/{assetId}`
Updates mutable descriptive facts subject to Audit.

### `GET /asset-ownerships`
Filters by Asset/Party/effective date.

### `POST /asset-ownerships`
Creates effective-dated Asset Ownership.

### `GET /assets/{assetId}/valuations`
Returns Valuation Observations with source/provenance.

### `POST /assets/{assetId}/valuations`
Creates a manual/provider-derived valuation observation without overwriting prior observations.

### `GET /liabilities`
Filters: `partyId`, `assetId`, `accountId`, `type`, `asOf`.

### `POST /liabilities`
Creates a manual/general Liability.

### `GET /liabilities/{liabilityId}`
Returns balance/terms/links/coverage/evidence as permitted.

## Accounts and ownership

### `GET /accounts`
Filters: `partyId`, `scopeId`, `type`, `connectionStatus`, `includeClosed`.

### `GET /accounts/{accountId}`
Returns ownership, visibility summary, permitted balance, Coverage, source mappings, statement/sync state.

### `POST /accounts`
Creates a manual Account or placeholder awaiting provider mapping.

### `PATCH /accounts/{accountId}`
Updates user-managed metadata. Provider identity is changed only through explicit remap workflow.

### `GET /account-ownerships`
Returns effective-dated ownership relationships.

### `POST /account-ownerships`
Creates effective-dated Account Ownership.

### `GET /accounts/{accountId}/coverage`
Returns fact-family/date coverage such as transactions, balances, statements, holdings, contributions, cost basis, payroll reconciliation, etc.

## Source records and observations

### `GET /source-records/{sourceRecordId}`
Returns source metadata/raw-reference fields only when authorized. Provider payload exposure is deliberately limited.

### `POST /manual-observations`
Creates a provenance-bearing manual Source Record/fact observation.

Example uses: spouse-published annual income, manually observed insurance value, old property valuation, manual balance.

### `GET /source-records/{sourceRecordId}/relationships`
Returns supersedes/pending-posted/correction/duplicate/related-source relationships.

### `GET /source-records/{sourceRecordId}/reconciliation`
Returns Financial Event/Account Entry links and deterministic reconciliation metadata.

## Imports

### `POST /imports`
Creates an import session for Account/source type.

### `POST /imports/{importId}/file`
Uploads CSV/OFX/QFX or supported historical source material.

### `GET /imports/{importId}/preview`
Returns parser result and deterministic identity/conflict analysis.

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
Returns import history, file hashes, account mapping, and source date ranges.

## Financial events and account entries

### `GET /financial-events`
Primary normalized-ledger query.

Filters may include `from`, `to`, `accountId`, `partyId`, `economicScopeId`, `categoryId`, `merchantId`, `role`, `reviewStatus`, `hasReceipt`, `assetId`, `minAmount`, `maxAmount`, `currency`.

### `POST /financial-events`
Creates a manual Financial Event through a manual Source Record/reconciliation workflow; manual events do not bypass provenance.

### `GET /financial-events/{eventId}`
Returns authorized normalized event, Account Entries, source reconciliation, allocations, obligations, evidence, Audit references and Provenance.

### `PATCH /financial-events/{eventId}`
Changes mutable interpretation fields such as canonical merchant, notes, category/scope allocation, privacy override, or verified role. Source Records remain immutable.

### `GET /financial-events/{eventId}/entries`
Returns linked Account Entries.

### `POST /financial-events/{eventId}/allocations`
Creates/replaces a validated allocation set by dimension. Category hierarchy and Economic Scope invariants are enforced.

### `GET /account-entries`
Filters by Account, event, dates, amount, reconciliation state.

### `POST /financial-events/{eventId}/reconcile-source`
Administrative/user-assisted command to bind source observations to an event/entry where deterministic matching could not decide.

## Categories, merchants and rules

### `GET /categories`
Returns validated hierarchy including parent, grouping/selectable state, lifecycle metadata.

### `POST /categories`
Creates a category/grouping. Invalid parent relationships are rejected.

### `PATCH /categories/{categoryId}`
Changes mutable metadata/effective behavior subject to historical semantics.

### `GET /merchants`
Lists canonical Merchants/Counterparties and authorized aggregate metadata.

### `GET /merchants/{merchantId}/aliases`
Returns aliases/provenance.

### `POST /merchants/{merchantId}/aliases`
Adds verified alias/normalization relationship.

### `GET /rules`
Returns deterministic rules, priority, enabled state, match count, last match.

### `POST /rules`
Creates explicit criteria/actions.

### `PATCH /rules/{ruleId}`
Updates effective rule state with Audit.

### `POST /rules/{ruleId}/test`
Evaluates against authorized historical data without mutation.

## Review inbox

### `GET /review-items`
Filters: `type`, `status`, `confidenceMax`, `entityType`, `economicScopeId`, `ownerModule`.

### `GET /review-items/{reviewItemId}`
Returns authorized reason, evidence, candidate resolutions and history.

### `POST /review-items/{reviewItemId}/resolve`
Domain-specific resolution command.

```json
{
  "resolution": "accept_suggestion",
  "createRule": true
}
```

Resolution is validated by the owning module and audited.

## Recurring patterns and expected cash flow

### `GET /recurring-patterns`
Filters by status, Merchant, Account, scope, type.

### `POST /recurring-patterns`
Creates/accepts an explicit recurring pattern.

### `PATCH /recurring-patterns/{patternId}`
Changes expected cadence/amount/tolerance/status.

### `POST /recurring-patterns/detect`
Runs authorized deterministic/anomaly analysis and creates candidates/Review Items rather than silently activating uncertain recurrence.

### `GET /expected-cash-flows`
Returns future occurrences from accepted patterns/explicit schedules for a requested horizon.

## Budgets and versioning

### `GET /budget-plans`
Filters by Economic Scope/year/effective date.

### `POST /budget-plans`
Creates a Budget Plan root.

### `GET /budget-plans/{planId}/versions`
Returns effective-dated versions.

### `POST /budget-plans/{planId}/versions`
Creates a new plan version with annual targets, monthly defaults and overrides. Prior effective versions are preserved.

### `GET /budget-status`
Parameters: `year`, optional `month`, `economicScopeId`, optional `knowledgeAt`.

Returns annual target, expected-through-period, actual, variance, annual remaining, months remaining, safe monthly spend, Coverage and plan-version identity.

## Household funding and fairness

### `GET /funding-plans`
Returns Household Funding Plan roots and effective versions.

### `POST /funding-plans`
Creates a plan root.

### `POST /funding-plans/{planId}/versions`
Creates an effective-dated Funding Plan Version including eligible-income definition, Commitments/Reserves/Goals, contribution method/targets and correction policy.

### `GET /funding-status`
Parameters: `period`, optional `knowledgeAt`.

Returns target, accepted cash/direct-deposit contribution, approved credits, cumulative Funding Reconciliation variance, correction policy, and recommended future percentage/amount per Party.

### `GET /funding-reconciliations`
Filters by plan/version/Party/period.

### `POST /funding-reconciliations/{reconciliationId}/correction-policy`
Explicitly selects informational/carry-forward/N-period/future-percentage/one-time/convert-to-obligation/reset policy as permitted.

### `POST /funding-plans/{planId}/recalculate-history`
Recomputes selected historical fairness using current authorized facts while preserving original recommendations/knowledge snapshots in Audit.

### `POST /funding-reconciliations/{reconciliationId}/convert-to-obligation`
Explicit opt-in conversion of selected funding variance to debtor/creditor semantics.

## Obligations and settlements

### `GET /obligations`
Returns explicit obligations visible to the caller.

### `POST /obligations`
Creates an explicit responsibility difference where domain rules permit it.

### `POST /settlements`
Creates a Settlement and applies it to selected Obligations. Settlement does not create new spending/income.

## Commitments, reserves and savings goals

### `GET /commitments`
Filters by scope, Account, date range, status/type.

### `POST /commitments`
Creates a known/estimated Commitment.

### `GET /reserve-buckets`
Returns scope-level earmarks and funded status.

### `POST /reserve-buckets`
Creates a Reserve Bucket and target/rule.

### `POST /reserve-buckets/{bucketId}/funding-policy`
Updates eligible Accounts/allocation policy without moving physical cash by itself.

### `GET /savings-goals`
Returns targets/progress/forecast status.

### `POST /savings-goals`
Creates goal amount/date/priority/linkage.

## Cash forecast

### `GET /cash-forecast`
Parameters: `economicScopeId`, `from`, `to`, optional account set/scenario.

Returns opening liquidity, Expected Cash Flows, Commitments, protected reserves, Funding Plan contributions, goal contributions, projected balances/free cash, Coverage, and risks.

### `GET /free-cash`
Returns deterministic `actually free` cash for a requested scope/horizon with assumptions/components.

## Account statements and credit-card payoff

### `GET /accounts/{accountId}/statements`
Returns authorized statement summaries/source coverage.

### `GET /accounts/{accountId}/statements/{statementId}`
Returns statement period, balance, due date, minimum, payment/credit status, APR/grace facts when known, and Evidence.

### `GET /credit-cards/{accountId}/payoff-forecast`
Returns full-statement-payoff ability/risk using authorized liquidity, expected income/spending, Commitments, reserves and future card activity.

The response distinguishes known facts from assumptions and does not initiate payments.

## Scenarios / What If

### `GET /scenarios`
Lists authorized scenarios.

### `POST /scenarios`
Creates an isolated planning Scenario from an observed baseline.

### `POST /scenarios/{scenarioId}/assumptions`
Creates/updates explicit assumptions.

### `POST /scenarios/{scenarioId}/run`
Runs projection and returns horizon, assumptions, Coverage/limitations, calculation version and results.

### `POST /scenarios/{scenarioId}/promote`
Explicitly creates future plan versions from selected scenario decisions; observed ledger state is never mutated directly.

## Receipts

### `POST /receipts`
Uploads/captures immutable receipt evidence and queues processing.

### `GET /receipts`
Filters processing/match/review state subject to visibility.

### `GET /receipts/{receiptId}`
Returns authorized original metadata, extracted facts, Receipt Items, reconciliation, match candidates and Provenance.

### `POST /receipts/{receiptId}/match`
Confirms/changes associated Financial Event.

### `PUT /receipts/{receiptId}/line-items`
Updates user-verified normalized items/category/scope allocations while preserving original extraction provenance.

## Documents and extracted facts

### `POST /documents`
Uploads immutable evidence and queues classification/extraction.

### `GET /documents`
Filters: `documentType`, `partyId`, `assetId`, `economicScopeId`, `taxYear`, `issuer`, `verificationStatus`.

### `GET /documents/{documentId}`
Returns permitted metadata/extracted facts.

### `GET /documents/{documentId}/content`
Authorized binary/preview stream; storage path never exposed.

### `GET /extracted-facts`
Queries authorized facts by schema/field/source/effective period/verification state.

### `POST /extracted-facts/{factId}/verify`
Verifies/corrects a derived fact without replacing original evidence.

### `GET /evidence/{evidenceId}`
Returns permitted evidence/provenance graph links.

## Payroll

### `GET /payroll-records`
Returns structured pay periods/pay stubs permitted to the caller.

### `GET /payroll-records/{payrollId}`
Returns gross/tax/deduction/benefit/retirement/net-pay facts plus reconciliation to Account Entry where available.

### `POST /payroll-records/{payrollId}/reconcile-deposit`
Confirms/changes net-pay bank-deposit reconciliation.

## Tax filing contexts and workspace

### `GET /tax/filing-contexts`
Filters by tax year/mode/participant.

### `POST /tax/filing-contexts`
Creates a `joint` or `individual` filing context with participants.

### `POST /tax/filing-contexts/{contextId}/access-grants`
Creates filing-specific preparer/document/fact access subject to participant/administrative authorization.

### `GET /tax/filing-contexts/{contextId}/documents`
Returns only Documents authorized for that filing context.

### `GET /tax/filing-contexts/{contextId}/checklist`
Returns expected/received/missing/uncertain tax-document state.

### `GET /tax/filing-contexts/{contextId}/workspace`
Returns authorized tax-year summaries, rental/investment/payroll evidence groupings, candidate classifications, incomplete-data notices and provenance.

### `POST /tax/filing-contexts/{contextId}/exports`
Creates an audited accountant/tax-preparer export package containing only authorized selected materials/summaries.

### `GET /tax/exports/{exportId}`
Returns export status/manifest.

### `GET /tax/exports/{exportId}/content`
Authorized download of the completed ZIP/package.

## Investments

### `GET /securities`
Returns canonical instruments/reference data.

### `GET /investment-accounts`
Returns authorized Accounts and Coverage by balances/holdings/transactions/cost basis/contributions.

### `GET /investment-accounts/{accountId}/holdings`
Returns Position Snapshots for an as-of date/source selection.

### `GET /investment-accounts/{accountId}/activity`
Returns investment Financial Events/transactions.

### `GET /investment-accounts/{accountId}/tax-lots`
Returns cost-basis/tax-lot facts with Coverage.

### `GET /investment-accounts/{accountId}/performance`
Parameters include period/method. Returns methodology, Coverage sufficiency and metric; insufficient data returns partial/unavailable state rather than fabricated values.

### `GET /securities/{securityId}/prices`
Returns Price Observations and Provenance.

## Insurance

### `GET /insurance-policies`
Filters by owner/insured/type/status.

### `POST /insurance-policies`
Creates/links a Policy from manual or document-derived information.

### `GET /insurance-policies/{policyId}`
Returns permitted coverage, premium, permanent-value, beneficiary and Evidence facts.

### `GET /insurance-policies/{policyId}/values`
Returns dated cash/cash-surrender/death-benefit/policy-loan observations as applicable.

### `GET /insurance-policies/{policyId}/illustrations`
Returns immutable illustration metadata/projected series with source Document.

### `GET /insurance-policies/{policyId}/projection-comparison`
Compares observed policy values with selected historical illustration projections without treating projections as observed assets.

### `POST /insurance/discovery`
Runs authorized merchant/recurrence/document analysis and creates Policy-link/add suggestions rather than inventing policy facts.

## Property / real estate

### `GET /properties`
Returns authorized Real Estate Assets.

### `GET /properties/{assetId}/financial-summary`
Returns rental income, operating expense, owner funding, liabilities, selected tax/capital candidates, valuations and Coverage.

### `GET /properties/{assetId}/mortgages`
Returns linked mortgage/liability facts/statement coverage.

### `GET /properties/{assetId}/leases`
Returns authorized lease facts/Documents.

### `GET /properties/{assetId}/security-deposits`
Returns liability-oriented deposit balances/movements.

The property API is a projection over shared Asset/Liability/Ledger/Records models, not a separate transaction store.

## Net worth

### `GET /net-worth`
Parameters: `economicScopeId`, optional `asOf`, optional `knowledgeAt`, reporting currency.

Returns Known Net Worth, canonical components, ownership path/attribution, deduplication metadata, Coverage notices, valuation sources/staleness and completeness indicator.

## Analytics

### `POST /analytics/query`
Executes a typed deterministic query from UI/AI/internal jobs. Queries identify purpose/scope and cannot request unauthorized detail by changing parameters.

### `POST /analytics/compare-knowledge`
Compares `as-known-then` and `as-known-now` calculations for supported domains such as funding fairness or net worth.

### `POST /analytics/anomalies`
Runs supported deterministic/statistical anomaly analysis and returns/creates authorized candidates/Alerts.

## Search

### `GET /search`
Authorization-aware global search across permitted transactions, merchants, receipts, documents, policies, assets, etc.

Private data must not leak through counts/snippets/facets.

### `POST /search/semantic`
Optional semantic retrieval over authorized indexed content. Results include source/evidence identity and never bypass Visibility Policy.

## AI

### `GET /ai/providers`
Returns sanitized configured provider/model capability state.

### `POST /ai/ask`
Runs an authorized AI companion query.

```json
{
  "question": "Why was August household spending higher than normal?",
  "economicScopeId": "...",
  "period": { "from": "2026-08-01", "to": "2026-08-31" }
}
```

Response contains narrative plus structured internal citations/evidence references. Data is authorized/minimized/redacted before provider invocation.

### `POST /ai/extract`
Internal/privileged structured extraction endpoint for Records workflows; accepts bounded evidence references rather than arbitrary filesystem paths.

AI configuration endpoints never return secrets and remote-provider activation requires explicit administrative opt-in/disclosure.

## External connections

### `GET /external-connections`
Lists sanitized connection state: provider, owner, capabilities, auth method, health, scopes and last verification.

### `POST /external-connections`
Creates a provider connection setup workflow.

### `PATCH /external-connections/{connectionId}`
Changes granted capabilities/configuration subject to reauthorization requirements.

### `POST /external-connections/{connectionId}/verify`
Checks provider authorization/health without exposing credentials.

### `POST /external-connections/{connectionId}/revoke`
Revokes/disables connection and audits the action.

Provider-specific authorization callback/bootstrap endpoints are implementation adapters, not stable financial-domain contracts.

## Provider sync

### `POST /provider-sync/{connectionId}/runs`
Starts idempotent synchronization.

### `GET /provider-sync/{connectionId}/status`
Returns sanitized status, last success/failure, mapped resources and Coverage dates.

## Alerts and notification delivery

### `GET /alerts`
Filters by status/severity/type/scope/source.

### `GET /alerts/{alertId}`
Returns authorized explanation/evidence/recommended actions.

### `POST /alerts/{alertId}/acknowledge`
Acknowledges/dismisses according to type.

### `GET /notification-preferences`
Returns per-user delivery preferences by Alert type/severity/channel.

### `PUT /notification-preferences`
Updates preferences.

### `GET /notification-destinations`
Returns sanitized in-app/push/email/future destination state.

### `POST /notification-destinations`
Creates/configures destination using External Connection where relevant.

## Scheduled insights

### `GET /scheduled-insights`
Lists recurring analytical jobs authorized to caller.

### `POST /scheduled-insights`
Creates schedule, query type/scope and delivery policy.

### `PATCH /scheduled-insights/{scheduledInsightId}`
Updates schedule/query/delivery settings.

### `POST /scheduled-insights/{scheduledInsightId}/run`
Runs manually under the same authorization rules as scheduled execution.

## Coverage

### `GET /coverage`
Queries fact-family/date/source Coverage by Account, Party, Economic Scope, Asset, provider or other supported resource.

### `GET /coverage/gaps`
Returns explicit known gaps relevant to a requested analytical purpose.

## Audit

### `GET /audit-entries`
Privileged/authorized query by actor, resource, action, period. Responses contain sanitized references and before/after summaries appropriate for the caller, never secrets.

### `GET /audit-entries/{auditEntryId}`
Returns detailed authorized mutation history/provenance links.

## Data retention

### `GET /retention-policy`
Returns configured default/per-class live-evidence retention.

### `PUT /retention-policy`
Updates policy with explicit warning/audit semantics.

### `POST /documents/{documentId}/delete`
Explicit authorized deletion command that reports provenance consequences and whether retained backups may still contain the object.

Equivalent deletion commands apply to supported evidence types; source deletion is never implied by removing a UI link.

## Backup and disaster recovery administration

Backup administration is privileged and never exposes Recovery Secret through ordinary responses.

### `GET /backup/status`
Returns configuration/health without secrets.

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
Lists sanitized Backup Destination state.

### `POST /backup/destinations`
Creates/configures a destination adapter such as Google Drive/S3-compatible storage through an appropriate External Connection.

### `POST /backup/recovery-secret`
Initializes/rotates Recovery Secret through explicit privileged workflow. One-time export is allowed only during explicit secure setup/rotation; no ordinary GET can retrieve it later.

Rotation must not orphan retained backups; the system records/rewraps secret generations as supported.

### `POST /backup/recovery-secret/verify`
Verifies independently stored recovery material.

### `POST /backup/runs`
Starts idempotent Backup Set creation, encryption, upload and verification.

### `GET /backup/runs`
Returns status such as `creating`, `encrypting`, `uploading`, `verifying`, `succeeded`, `failed`.

### `GET /backup/runs/{runId}`
Returns sanitized manifest-level health, destination identity, encrypted size/hash, retention state and errors.

### `POST /backup/restore-tests`
Performs non-destructive isolated restore validation; never overwrites live installation.

### `POST /backup/restores/prepare`
Validates a selected envelope and produces a short-lived restore plan with compatibility/counts/actions. Destructive recovery requires explicit privileged confirmation outside normal navigation.

### `PUT /backup/retention-policy`
Updates backup retention. Pruning cannot delete the last known-good verified recovery point and is never triggered by failed/unverified runs.

## Administrative health

### `GET /health`
Minimal service health suitable for private deployment monitoring.

### `GET /operations/jobs`
Privileged sanitized background-job status for sync, extraction, indexing, alerts, scheduled insights and backup.

Operational responses never expose raw financial/provider/model payloads merely for diagnostics.
