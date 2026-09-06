# Work tracking — Pryvance

The repository follows the github-workflow shape: Project board → delivery-story milestones → epics → issues. Repository-specific process lives under `docs/process/`.

| Layer | Here |
|---|---|
| Project board | Not configured yet. Create/configure the owner Project using the canonical configure-workflow Project manifest, then record its title, number, URL, owner, automation account, field ids, and option ids here. |
| Milestones | Delivery stories only; hardening/CI/tooling may remain milestone-less. |
| Epics | Cohesive multi-issue themes; events live in comments. |
| Issues | Must carry the canonical type/priority metadata plus ≥1 `area:*` conflict-lock label from [labels.md](labels.md). |

## Area locking

`area:*` labels are orchestration concurrency controls. They describe likely overlapping Git diff territory rather than product ownership. Multiple labels are expected for cross-cutting work. The orchestrator should avoid implementing issues concurrently when their area sets intersect unless it has inspected the concrete scopes and established that they cannot collide.

## Project fields

The canonical workflow requires `Status`, `Verified`, and `Claimed by` fields plus the configured standard views/workflows. Once the Project exists, record its field and single-select option ids here from:

`gh project field-list <number> --owner blac9216 --format json`

Do not invent or copy ids from another Project.

## Optional configuration

| Configuration | Value |
|---|---|
| Reviewer identity | none — single account; the review comment plus the merge are the verdict of record |
| Session-log archive | none — session logs stay scratch-only |

Local deviations from the canonical workflow: none currently declared.
