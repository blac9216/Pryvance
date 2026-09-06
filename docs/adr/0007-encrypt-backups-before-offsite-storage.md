# ADR-0007: Encrypt offsite recovery data before storage

Status: Proposed
Date: 2026-09-05

## Context

Pryvance stores highly sensitive financial data and immutable evidence. Local-only recovery is insufficient for disk/host/theft/fire/site failure. Cloud providers such as Google Drive are useful destinations but must not become trusted with plaintext Household data.

The object-vault design also separates hot/cold lifecycle from database backup. Historical objects may already exist as encrypted cloud Archive Packs that are suitable disaster-recovery copies; repeatedly bundling/re-uploading all immutable Documents with every database backup would waste bandwidth/storage.

Recovery must therefore protect database state and object evidence coherently while allowing their physical backup streams to be independent.

## Decision Drivers

- Untrusted/offsite providers receive only ciphertext.
- Complete host loss remains recoverable with separately held recovery material.
- Database backups can run independently from large immutable-object storage.
- Existing verified cloud cold replicas may satisfy object disaster recovery without redundant duplicate upload.
- A selected database snapshot must prove every required Stored Object is recoverable.
- Destination/provider choice remains replaceable.
- Pryvance does not invent cryptographic primitives.
- Restore/recovery health is designed/tested rather than emergency-only.

## Considered Options

1. **Separate encrypted Database Backup + verified Object Recovery, linked by a coherent Recovery Point** — avoids immutable-data reupload while preserving full recoverability; requires object-replica manifests/protection verification.
2. **One monolithic encrypted database+all-documents bundle per backup** — conceptually simple; repeatedly moves large unchanged evidence and conflicts with tiered storage.
3. **Plaintext/provider-managed encryption only** — operationally simple; provider/account compromise remains inside confidentiality boundary.
4. **External host backup tooling only** — mature tooling may help, but application-level object/database coherence, status and restore semantics are harder to guarantee.

## Decision

Pryvance will encrypt/authenticate all recovery data locally before it leaves trusted storage and will separate physical Database Backup from Object Recovery while linking them through a versioned Recovery Point manifest.

1. A Database Backup is a transaction-consistent PostgreSQL logical backup plus application/schema/catalog metadata. It is encrypted locally before transfer.
2. For each database snapshot, an Object Recovery Snapshot identifies every Stored Object required by that database state and verifies at least one recovery-eligible Object Replica for each.
3. A recovery-eligible Object Replica may be a dedicated object-backup copy or an encrypted cloud cold Archive Pack. Pryvance does not require a redundant second upload when a verified cold cloud replica already satisfies disaster-recovery policy.
4. A logical Backup Set/Recovery Point links the database artifact and object manifest; it is not required to be one physical archive.
5. Untrusted/cloud object Archive Packs and Database Backups use vetted authenticated encryption/envelope encryption. Provider credentials cannot decrypt them.
6. Recovery/content-encryption keys are independent from provider OAuth/API credentials. The separately held Recovery Secret supports complete-host-loss recovery through a vetted key-wrapping/envelope mechanism.
7. Restore stages the database, verifies format/schema, validates required object availability/integrity, and only then permits live recovery. Cold archives may remain cold and be rehydrated lazily after restore.
8. Retention/pruning never removes the last known-good Recovery Point or an object replica still required to satisfy retained recovery policy.
9. Runtime/provider credentials need not be recoverable from financial backups; reauthorization after disaster recovery is acceptable.

## Consequences

- Database backup cadence can remain frequent without repeatedly uploading multi-gigabyte immutable vault data.
- Cold encrypted Google Drive storage can double as the document/object backup copy when policy marks it recovery-eligible.
- Local/NAS cold storage is not automatically offsite disaster recovery; protection/failure-domain state must be visible.
- Recovery health requires database verification **and** complete required-object protection.
- Restore tests can reconnect cold archives and lazily rehydrate rather than restoring every old original to primary SSD.
- Losing both host state and separately held Recovery Secret makes encrypted remote recovery intentionally impossible.
- Concrete encryption/compression engines remain implementation choices constrained by these trust/integrity requirements.
