# ADR-0007: Encrypt backups before offsite storage

Status: Proposed
Date: 2026-09-05

## Context

Pryvance stores bank activity, investment data, receipts, tax documents, household allocations, and other highly sensitive financial information. A local-only backup is insufficient for host, disk, theft, fire, or site failure, so recoverable copies must be stored outside the Pryvance host. Cloud storage such as Google Drive is a convenient destination, but the storage provider must not become trusted with plaintext household data.

Offsite encryption also creates a recovery problem: if the host is lost, an encryption key stored only on that host makes the backup useless. The backup design therefore has to protect confidentiality from the storage provider while preserving a separately held recovery path for complete-host-loss scenarios.

## Decision Drivers

- Offsite providers must receive only ciphertext, never plaintext database dumps or documents.
- A complete loss of the Pryvance host must still be recoverable.
- Backup integrity and completeness must be verifiable before a restore is allowed.
- Destination choice must remain replaceable; Google Drive is a provider adapter, not a domain dependency.
- The application must not invent new cryptographic primitives.
- Backup credentials and encryption/recovery keys must be independent so compromise of one does not disclose data.
- Restore must be a designed and testable workflow, not an emergency-only script.

## Considered Options

1. **Pryvance-coordinated, client-side encrypted backup with provider adapters** — keeps consistency and restore semantics inside the product while sending only opaque encrypted artifacts off-host; requires key-recovery UX and backup orchestration.
2. **Plaintext backup to a provider relying on provider-managed encryption at rest** — operationally simple, but the provider/account compromise remains inside the confidentiality boundary and does not meet the privacy goal.
3. **Entirely external host-level backup tooling** — mature tools can provide strong encryption and retention, but application consistency, document/database manifesting, restore compatibility, and user-visible backup health become harder to guarantee from Pryvance itself.

## Decision

Pryvance will coordinate versioned, authenticated, client-side encrypted Backup Sets and upload only encrypted Backup Envelopes to replaceable Backup Destinations.

1. A Backup Set contains a transaction-consistent PostgreSQL logical backup, every immutable receipt/document object referenced by that snapshot, and a manifest containing format version, application/schema version, object identifiers, sizes, and cryptographic hashes.
2. The Backup Set is encrypted locally before transfer using a vetted authenticated-encryption implementation or established backup/encryption engine. Pryvance will not implement a novel cipher or unauthenticated encryption format.
3. The offsite destination adapter receives only the encrypted Backup Envelope plus non-sensitive transport metadata required to store/list it. Google Drive is an intended first destination, but the domain depends on a generic Backup Destination interface.
4. Backup encryption keys are independent from cloud-provider OAuth/API credentials. Provider credentials cannot decrypt a backup.
5. A locally generated backup master/recovery secret must have an explicit export/recovery workflow so complete host loss remains recoverable. The recovery secret is never uploaded in plaintext alongside the backups. Pryvance must warn that loss of the recovery secret makes encrypted backups unrecoverable.
6. Restore decrypts into an isolated staging workflow, verifies the envelope authentication and manifest hashes, checks format/schema compatibility, and only then permits replacement/import into the live installation.
7. Retention is configurable. Failed uploads or failed verification never prune the last known-good backup.
8. Runtime/provider credentials and environment secrets are not required to be recoverable from the financial backup; provider connections may require reauthorization after disaster recovery.

## Consequences

- A Google Drive or other destination compromise does not by itself expose household financial plaintext.
- Losing both the Pryvance host and the separately held recovery secret makes the backups intentionally unrecoverable; recovery-key onboarding and verification are required product work.
- Backup/restore becomes a first-class subsystem with status, scheduling, retention, validation, and provider adapters rather than a deployment afterthought.
- Database consistency and immutable object storage make a manifest-based backup practical without stopping the application for long periods.
- Provider adapters can later support Google Drive, S3-compatible storage, local/NAS targets, or other destinations without changing backup semantics.
- A concrete encryption engine/algorithm can be selected during implementation under the constraints of this ADR without changing the trust boundary established here.
