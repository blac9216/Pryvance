# ADR-0012: Model external connections by capability and authentication method

Status: Proposed
Date: 2026-09-06

## Context

Pryvance may connect to bank aggregators, mail systems, cloud storage, market-data services, AI providers, and notification delivery services. Some providers use OAuth, others use API keys, app passwords, local bridges, certificates, or provider-specific flows. A single provider may expose multiple capabilities that should not all be granted together.

Hard-coding provider names or treating `OAuth connection` as the domain concept would couple the product to current providers and make least-privilege authorization difficult.

## Decision Drivers

- Keep provider-specific authentication replaceable.
- Request/store only the capabilities/scopes required for a feature.
- Allow the same provider to be connected separately for Mail Read, Mail Send, Cloud Storage, etc.
- Support providers that do not expose standard OAuth flows.
- Keep operational credentials out of AI, logs and ordinary financial-domain APIs.

## Considered Options

1. **External Connection with capability + authentication-method model** — provider-neutral and least-privilege; requires adapter/configuration layer.
2. **OAuth Connection as universal abstraction** — simple for some cloud providers; inaccurate for bridges/API-key providers and conflates auth with capability.
3. **Provider-specific integration tables/services only** — fastest first implementation; creates duplicated credential/health/scope semantics.

## Decision

Pryvance will model an External Connection with provider, owner, authentication method, credential reference, granted provider scopes, granted Pryvance capabilities, health and verification state.

Capabilities include Bank Data, Mail Read, Mail Send, Cloud Storage, Market Data, AI Inference and Notification Delivery. Authentication methods may include OAuth2, API key/token, local bridge, app password, client certificate or provider-specific mechanisms.

Least privilege is mandatory: one capability grant does not imply another simply because both use the same provider account.

## Consequences

- Google Drive backup does not automatically imply Gmail access.
- Mail Read and Mail Send can be authorized independently.
- Proton/local-bridge-style or API-key providers fit the same internal model without pretending to be OAuth.
- Provider credentials are encrypted at rest, omitted from normal API/logging, and never sent to AI.
- Provider adapters translate external behavior into stable Pryvance capabilities/domain Source Records.
