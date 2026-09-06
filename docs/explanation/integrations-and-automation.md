# Integrations, AI, alerts, and automation

Kind: explanation

Pryvance integrates with external systems through explicit capabilities and security boundaries. Provider-specific details stay behind adapters so the domain does not become dependent on one bank aggregator, mail provider, cloud-storage vendor, AI runtime, or notification service.

## External Connection

An External Connection represents an authorized link to an external service.

Core fields/concepts:

- provider/provider type;
- owning User Identity or administrative owner;
- authentication method;
- credential/secret reference;
- granted scopes;
- granted Pryvance capabilities;
- connection health;
- authorization/verification timestamps;
- provider account/resource mappings where applicable;
- revocation/reauthorization state.

Authentication methods may include:

- OAuth2/OIDC-style delegated authorization;
- API key/token;
- local bridge;
- app password;
- client certificate;
- provider-specific mechanisms.

Pryvance does not assume every provider supports OAuth.

## Capability model

Capabilities are granted independently so connecting one provider feature does not imply access to unrelated data.

Initial capabilities include:

- `BankData`;
- `MailRead`;
- `MailSend`;
- `CloudStorage`;
- `MarketData`;
- `AiInference`;
- `NotificationDelivery`.

Example: a Google account used only for encrypted Drive backups should not implicitly grant Gmail read/send access. Receipt ingestion and alert delivery may use separate grants even when the provider is the same.

## Credential handling

- credentials/tokens are encrypted at rest when persisted;
- secrets never appear in ordinary API responses;
- secrets are not written to logs;
- credentials are never sent to AI;
- scopes follow least privilege;
- revocation/failure produces connection-health state and Alert where appropriate;
- provider reauthorization after restore is acceptable and preferred to exporting every operational secret inside the financial backup.

## Banking/provider adapters

Provider adapters translate external account/transaction/balance data into immutable Source Records and Coverage observations.

Adapters may support polling, webhooks, or both. Provider webhook processing requires signature verification/replay protection where supported.

A provider connection may expose only partial history or fact families. Provider coverage is stored explicitly so file imports/manual observations can coexist without assuming the live feed is complete.

Provider account identity maps to Pryvance Account identity through an explicit mapping/reconciliation layer; remapping is an administrative workflow rather than silently changing Account identity.

## Mail integrations

Mail connections may be used for:

- receipt ingestion;
- financial-document ingestion;
- outbound alert/notification email.

Read and send are independent capabilities. Ingestion should operate on explicit mailbox/folder/query rules and retain source-message provenance without requiring Pryvance to become a general mail client.

Provider adapters may use direct APIs, IMAP/SMTP through a local bridge, or another supported mechanism. The internal domain receives normalized mail-source observations rather than depending on Gmail/Proton-specific structures.

## Cloud-storage integrations

Cloud storage is primarily used for encrypted Backup Envelopes. The destination adapter stores opaque ciphertext and sanitized metadata/remote identifiers.

The backup recovery secret is independent from cloud credentials. Cloud compromise must not decrypt retained backups.

The provider-neutral destination contract should support create/upload, list/status, retrieve, delete/prune, and verification metadata required by backup health while preserving provider-specific capabilities behind the adapter.

## Market-data integrations

Market-data adapters provide Price Observations and Security reference metadata. They are evidence sources, not authority over investment ownership/transactions.

Every price observation includes source, timestamp/date, currency, and Provenance. Multiple providers/manual observations can coexist.

## AI provider abstraction

AI is provider-neutral. Local LM Studio/OpenAI-compatible service is the expected common configuration but not a restriction.

The provider interface supports the capabilities Pryvance needs rather than exposing arbitrary database access:

- structured extraction;
- classification/normalization;
- constrained question answering;
- summarization;
- embeddings where configured;
- tool/function calling through Pryvance-defined tools.

Provider configuration records endpoint/provider, model, capability flags, authentication reference, local/remote classification, limits, and enabled state.

## AI redaction gateway

All AI-bound context passes through application authorization and a redaction/minimization layer.

Sensitive values are removed or replaced by stable request-scoped placeholders by default, including:

- SSNs/tax identifiers;
- full bank/card/account numbers;
- full policy identifiers;
- access tokens/credentials;
- secrets/recovery material;
- other sensitive identifiers not needed for the task.

Example:

```text
Jordan Black -> <PERSON_2>
Checking ending 1234 -> <ACCOUNT_1>
SSN -> <REDACTED_TAX_ID>
```

Stable placeholders preserve useful relationships inside a prompt while reducing exposure.

A feature that genuinely requires an original sensitive value must explicitly declare that need, pass authorization, and surface the resulting privacy implication. Ordinary analytics/explanation should not require such values.

Remote AI use requires explicit operator configuration and disclosure that authorized/minimized data may leave the local environment. Local AI still receives only the minimum necessary context where practical.

## AI tools / endpoints

AI does not receive raw SQL. Pryvance exposes typed internal tools such as:

- `search_financial_events`;
- `spending_by_category`;
- `compare_periods`;
- `find_merchants`;
- `get_budget_status`;
- `get_funding_status`;
- `get_cash_forecast`;
- `get_net_worth`;
- `get_investment_summary`;
- `get_tax_document_status`;
- `search_evidence`;
- `suggest_category`;
- `get_recurring_patterns`.

Every tool executes under the requesting User Identity, Economic Scope, Visibility Policy, filing context, and calculation permissions. A model cannot widen authorization by choosing a different tool argument.

Structured outputs are schema validated before use. AI output may create a candidate fact/Review Item but cannot directly bypass domain invariants.

## Search and embeddings

Search is authorization-aware at indexing and query time. A private item cannot leak through:

- document title/snippet;
- search count;
- autocomplete;
- similarity result;
- vector nearest-neighbor result;
- AI retrieval context.

Embeddings are derived data and inherit source visibility/retention semantics. If a source becomes inaccessible or is deleted under retention policy, indexes are updated accordingly.

## Alert model

Alert represents something Pryvance wants to surface. It is separate from a delivery channel.

Alert sources include:

- provider sync/auth failure;
- backup failure or stale restore test;
- credit-card payoff risk;
- negative/free-cash risk;
- Household funding shortfall/variance;
- missing expected income;
- recurring charge anomaly/forgotten subscription;
- document/tax completeness;
- insurance/policy anomaly;
- investment data-quality issue;
- Review backlog;
- Scheduled Insight.

An Alert records severity, type, source entity/scope, explanation/evidence, created time, status, deduplication key, and optional recommended actions.

## Notification delivery

Delivery preferences map Alerts to configured channels.

Target channels include:

- in-app;
- PWA/Web Push;
- email;
- future adapters.

Channels are tunable by Alert type/severity/scope and User Identity. Domain modules create Alerts; they do not know SMTP, push, or provider details.

This allows a user to attach a mail provider later without changing forecasting, backup, tax, or review modules.

## Scheduled Insights

Scheduled Insight is a recurring analytical definition that invokes typed query services at a configured cadence and creates an Insight/Alert when useful.

Examples:

- weekly cash-flow summary;
- monthly budget/funding status;
- recurring charge changes;
- annual tax-document checklist;
- quarterly investment/insurance update;
- backup health summary.

Scheduled Insights use the same authorization/privacy rules as interactive analytics. They cannot persist an unauthorized snapshot merely because a job ran when a different user was active.

## Background jobs

The logical job subsystem supports:

- bank synchronization;
- mail ingestion;
- document/receipt processing;
- AI extraction/enrichment;
- market-price refresh;
- recurring/anomaly analysis;
- scheduled forecasts/insights;
- notification delivery;
- backup/restore verification;
- search indexing.

Jobs are idempotent where retry is plausible and record sanitized run status. Failures become operational state and may generate Alerts.

## Audit

Administrative/integration actions are auditable:

- connection created/revoked/reauthorized;
- scopes/capabilities changed;
- AI provider enabled/changed;
- remote AI selected;
- notification destination configured;
- backup destination changed;
- retention policy changed;
- scheduled insight created/changed;
- privileged export performed.

Audit records references and sanitized metadata, never raw credentials.
