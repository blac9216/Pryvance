# ADR-0014: Use tiered content-addressed object storage with configurable recovery targets

Status: Proposed
Date: 2026-09-06

## Context

Pryvance retains original receipts, statements, tax forms, insurance records and other evidence indefinitely by default. Keeping every original unpacked on the primary SSD can consume substantial space over the lifetime of the Household. The user still needs old evidence to be recoverable/viewable, included in disaster recovery, and protected when stored on untrusted cloud providers.

Cold storage and disaster recovery overlap but are not identical. A Household may want local cold storage plus cloud backup, or may want an encrypted Google Drive/cloud cold archive to serve as the durable offsite object-recovery copy directly.

## Decision Drivers

- Preserve immutable original evidence and SHA-based identity.
- Bound primary/hot disk growth.
- Support local volume/HDD/NAS and cloud targets.
- Rehydrate individual old objects on demand.
- Avoid one giant mutable ZIP/archive.
- Allow cold cloud copies to satisfy object-backup policy without duplicate uploads.
- Separate PostgreSQL/database backup cadence from bulk object lifecycle.
- Encrypt data before untrusted/offsite storage.

## Considered Options

1. **Content-addressed Stored Objects + configurable hot/cold replicas + immutable archive packs + independent recovery policy** — flexible and recoverable; requires replica/archive catalog and rehydration jobs.
2. **Keep every original raw on primary storage forever** — simple access; unbounded primary disk use.
3. **One monolithic ZIP/tar archive** — simple concept; poor random retrieval, mutation/compaction and failure behavior as lifetime data grows.
4. **Treat backup system as the only document store** — reduces duplication but couples ordinary document retrieval to disaster-recovery tooling and weakens live object lifecycle visibility.

## Decision

Pryvance will identify original evidence by content hash and store one or more Object Replicas on configurable Storage Targets. Hot replicas optimize immediate access. Cold objects are packed into bounded, immutable, indexed Archive Packs and may live on mounted local/NAS/HDD targets or cloud targets.

Untrusted/cloud archive artifacts are encrypted/authenticated locally before upload. The provider credential is independent of content/recovery encryption material.

A Storage Target may be marked recovery-eligible. Therefore an encrypted Google Drive/cloud cold replica may simultaneously satisfy the offsite object-backup requirement; a separate duplicate object backup is optional rather than mandatory.

Database Backup and Object Recovery are separate streams. A logical Recovery Point links a verified encrypted database backup to an Object Recovery Snapshot proving that every Stored Object required by that database snapshot has at least one verified recovery-eligible replica.

## Consequences

- Cold archival can reduce primary-disk use without deleting evidence.
- Old originals may require an asynchronous rehydration before full viewing.
- Archive packs require format/version/index/compaction/integrity management.
- Cloud cold/archive use requires recovery-key-compatible encryption, not provider-managed encryption alone.
- Local cold storage does not automatically count as offsite disaster recovery; target failure-domain/protection state must be visible.
- Restore can reconnect cold archives and lazily rehydrate rather than copying every historical file onto the primary disk.
- Backups can avoid repeatedly uploading unchanged historical objects while still proving object recoverability for each database Recovery Point.
