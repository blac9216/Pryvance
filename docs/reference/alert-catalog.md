# Alert catalog

Kind: reference

Alerts are stable product facts, separate from notification delivery. This catalog defines the core target alert taxonomy so implementation does not invent inconsistent IDs/severities across modules.

New alert types may be added without an ADR when they preserve these semantics. Renaming/removing a shipped stable Alert ID requires compatibility/migration consideration.

## Common fields

Every Alert records at least:

- stable `type`;
- severity (`info`, `warning`, `critical`);
- source module/entity/Economic Scope as applicable;
- created time;
- status (`open`, `acknowledged`, `snoozed`, `resolved`, `dismissed` as supported);
- deduplication key;
- explanation/evidence references appropriate to authorization;
- recommended action(s) when useful;
- originating Job/Calculation Run where applicable.

Thresholds and delivery are configurable where noted. Muting delivery does not necessarily prevent the Alert fact from existing in-app.

## Operations and recovery

| Alert ID | Default severity | Core trigger | Dedup scope |
|---|---|---|---|
| `backup.database_failed` | critical | database backup run exhausted/fails | backup policy/run window |
| `backup.objects_unprotected` | critical | required Stored Objects lack recovery-eligible verified replica | recovery point/policy |
| `backup.restore_test_stale` | warning | restore verification exceeds configured age | installation |
| `backup.recovery_secret_unverified` | critical | offsite recovery configured without verified recovery material | installation |
| `connection.auth_expired` | warning | provider requires reauthorization | connection |
| `sync.failed` | warning | provider sync exhausts retry policy | connection |
| `job.failed` | warning | user/operator-relevant job permanently fails | job type/resource |
| `storage.low_space` | warning | configured target crosses capacity threshold | storage target |
| `storage.target_unavailable` | critical | required target unavailable beyond grace | storage target |
| `object.integrity_failed` | critical | stored/rehydrated object hash/authentication mismatch | stored object/replica |
| `object.rehydration_failed` | warning | interactive archive fetch permanently fails | stored object/request |
| `archive.compaction_failed` | warning | maintenance compaction fails after retry | storage target/pack |

`storage.low_space` thresholds are user configurable. A recovery-eligible target outage is elevated based on whether remaining replicas still satisfy policy.

## Ledger and Coverage

| Alert ID | Default severity | Core trigger |
|---|---|---|
| `statement.reconciliation_difference` | warning | statement calculated closing balance differs beyond tolerance |
| `transfer.unmatched` | info | expected opposite Account Entry remains unresolved beyond match window |
| `coverage.gap` | warning | known data gap affects a selected/report-critical fact family |
| `import.conflict` | info | deterministic import identifies unresolved conflicting source records |
| `account.balance_anomaly` | warning | sourced balance conflicts materially with reconciled ledger/statement |

Statement tolerance is currency/account configurable. Small pending differences may remain Review Items rather than Alerts until the statement is final.

## Cash and credit

| Alert ID | Default severity | Core trigger |
|---|---|---|
| `cash.negative_forecast` | critical | deterministic short-range forecast falls below configured floor |
| `cash.free_cash_low` | warning | projected Free Cash falls below threshold/buffer |
| `card.full_payoff_risk` | warning | forecast cannot cover full statement balance by due date |
| `card.minimum_only_covered` | critical | forecast covers minimum but not configured full-payoff policy |
| `card.payment_missing` | warning | expected card payment has not matched by configured window |
| `commitment.unfunded` | warning | known Commitment lacks projected liquidity by due date |

Credit-card Alerts distinguish statement payoff facts from total current balance and expose forecast assumptions/Coverage.

## Recurring and anomaly

| Alert ID | Default severity | Core trigger |
|---|---|---|
| `income.expected_missing` | warning | accepted expected income misses its occurrence window |
| `recurring.amount_changed` | info | accepted recurring amount moves outside tolerance |
| `recurring.cadence_changed` | info | recurrence timing shifts outside accepted window |
| `recurring.duplicate` | warning | likely duplicate recurring service/charge detected |
| `recurring.forgotten` | info | long-running recurring charge is flagged for review as potentially forgotten |
| `recurring.stopped` | info | accepted recurring item unexpectedly ceases |
| `spending.anomaly` | info | deterministic/statistical analysis flags unusual amount/merchant/frequency |

Anomaly alerts create Review/candidate context; they do not claim fraud or cancel services automatically.

## Planning and funding

| Alert ID | Default severity | Core trigger |
|---|---|---|
| `funding.variance` | info | cumulative Funding Reconciliation exceeds configured display threshold |
| `funding.shortfall` | warning | projected accepted contributions fail current plan requirement |
| `reserve.below_target` | warning | Reserve Bucket drops below configured target/minimum |
| `goal.off_track` | info | Savings Goal projected path misses target date/amount |
| `budget.pace_risk` | info | actual pace materially exceeds remaining Budget plan |

Funding variance is not interpersonal debt. Delivery language must preserve that distinction.

## Tax and records

| Alert ID | Default severity | Core trigger |
|---|---|---|
| `tax.document_missing` | warning | expected U.S. tax Document remains missing past configured/checklist date |
| `tax.evidence_gap` | warning | tax workspace result is missing required supporting evidence |
| `tax.candidate_unverified` | info | material Tax Classification Candidate remains unresolved |
| `document.extraction_failed` | warning | selected document cannot be parsed/extracted after supported attempts |
| `document.retention_pending` | info | configured retention will delete evidence with provenance impact |

Tax alerts are scoped to the authorized Tax Filing Context.

## Investments and wealth

| Alert ID | Default severity | Core trigger |
|---|---|---|
| `investment.price_stale` | info | valuation depends on price older than configured tolerance |
| `investment.cost_basis_gap` | warning | requested tax/performance analysis lacks required basis Coverage |
| `investment.reconciliation_difference` | warning | holdings/statement/provider observations materially disagree |
| `net_worth.coverage_gap` | info | Known Net Worth is materially incomplete for selected scope |
| `fx.rate_stale` | warning | reporting conversion uses rate older than configured tolerance |

## Insurance

| Alert ID | Default severity | Core trigger |
|---|---|---|
| `insurance.premium_without_policy` | info | recurring insurance payment has no linked Insurance Policy |
| `insurance.value_stale` | info | tracked permanent-policy value lacks recent observation |
| `insurance.illustration_variance` | info | observed policy value materially differs from selected illustration expectation |
| `insurance.premium_changed` | info | accepted policy premium changes outside tolerance |

## Review and scheduled insights

| Alert ID | Default severity | Core trigger |
|---|---|---|
| `review.backlog` | info | unresolved Review Items exceed age/count threshold |
| `scheduled_insight.ready` | info | configured Scheduled Insight produced material output |

## Delivery defaults

Critical Alerts are enabled in-app by default and should strongly encourage at least one configured delivery path where appropriate. Warning/info delivery is user-tunable by Alert type, severity, scope and User Identity.

Email/push payloads minimize sensitive detail. Delivery rechecks authorization and can link back to the authenticated app for details.

## Deduplication and lifecycle

Alert producers provide stable deduplication keys so repeated jobs do not create hundreds of equivalent open Alerts. A producer may update evidence/last-seen/count on an existing open Alert.

Resolution can be automatic when the underlying condition clears or explicit when user acknowledgement is required. Snooze suppresses delivery for a period but does not falsify the underlying condition.
