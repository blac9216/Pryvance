# Pryvance security and privacy model

Kind: explanation

Pryvance stores highly sensitive household financial data. The initial security posture assumes a trusted self-host operator, private-network access, least exposure, explicit application authorization, immutable source evidence, and local AI by default.

## Trust boundaries

```mermaid
flowchart LR
    User[Authorized browser/PWA]
    Tail[Tailscale / private LAN]
    App[Pryvance application]
    DB[(PostgreSQL)]
    Store[(Private document store)]
    AI[Local AI host]
    Ext[External financial/email providers]

    User --> Tail --> App
    App --> DB
    App --> Store
    App --> AI
    App --> Ext
```

The Docker host and database administrator are trusted in the initial model. Application privacy controls protect household members from ordinary in-app disclosure; they do not claim cryptographic protection against a server administrator with direct database/filesystem access.

## Network posture

- PostgreSQL is not published outside the Docker network.
- Receipt/document storage is not served as a public directory.
- The application is intended for LAN or Tailscale access rather than direct public internet exposure.
- LM Studio/OpenAI-compatible AI endpoints are restricted to the LAN or tailnet and are not exposed broadly.
- TLS is provided by the private access layer or an optional future reverse proxy when needed.

## Identity and authorization

The first deployment may have one operator identity, but the domain and API must not assume global visibility forever.

Authorization is evaluated independently for:

- viewing record detail;
- including private data in aggregates visible to another Person;
- using otherwise hidden data for a household calculation;
- modifying ownership, visibility, allocations, obligations, or verification state.

Private data must be filtered before serialization. UI hiding is not an authorization boundary.

## Visibility levels

Initial account-level presets may include:

- Private
- Balance only
- Summary only
- Shared transactions only
- Full access

Transaction/document overrides may be more restrictive. Gift/private transactions must not leak existence, merchant, date, or amount through placeholder rows unless the owner explicitly permits an aggregate that includes them.

## Sensitive data handling

- Do not log SSNs, full account numbers, access tokens, document bodies, receipt images, or model prompts/results containing sensitive source material by default.
- Redact or omit fields not required for a model task before sending content to AI.
- Secrets are supplied through environment/secret mechanisms, never committed configuration.
- Full-disk encryption and encrypted backups are deployment requirements for real household data.
- Export and backup workflows must preserve ownership and visibility metadata.

## Document and receipt storage

Original files are immutable evidence and identified by cryptographic hash. Application records reference stored objects rather than using user-controlled filenames as paths. Downloads are authorized through application endpoints; storage paths are never directly exposed.

## AI boundary

AI is optional and untrusted for correctness.

- AI does not receive unrestricted database access.
- AI calls narrow application tools or receives bounded input selected by application code.
- AI cannot directly mutate system-of-record facts without application validation and authorization.
- Arithmetic, totals, deduplication, transfer matching, budget calculations, visibility enforcement, and known-form semantics remain deterministic application responsibilities.
- Low-confidence or non-reconciling AI output creates a Review Item.

## External provider tokens

Provider credentials/tokens are encrypted at rest when application-level secret storage is introduced and are never returned through general API representations. Provider webhooks, if adopted, require signature verification and replay protection.

## Threat priorities

1. accidental household-member disclosure;
2. public/network exposure of the service or database;
3. secret leakage through logs/configuration;
4. malicious or malformed document/import content;
5. AI prompt/data leakage;
6. silent corruption of financial truth through automation;
7. backup loss or unencrypted backup exposure.

## Future cryptographic privacy

Client-side/per-user encryption could protect private records even from the server administrator, but it conflicts with server-side search, analytics, reconciliation, AI, and recovery. It is explicitly deferred until a household member requires that stronger guarantee. The current schema should avoid assumptions that would make a later encrypted-private-record envelope impossible.
