# Work tracking — Pryvance

The repository follows the github-workflow shape: Project board → delivery-story milestones → epics → issues. Repository-specific process lives under `docs/process/`.

| Layer | Here |
|---|---|
| Project board | [Pryvance #7](https://github.com/users/blac9216/projects/7), owned by `blac9216`; dedicated to `blac9216/Pryvance`. |
| Milestones | Delivery stories only; hardening/CI/tooling may remain milestone-less. |
| Epics | Cohesive multi-issue themes; events live in comments. |
| Issues | Must carry the canonical type/priority metadata plus ≥1 `area:*` conflict-lock label from [labels.md](labels.md). |

## Area locking

`area:*` labels are orchestration concurrency controls. They describe likely overlapping Git diff territory rather than product ownership. Multiple labels are expected for cross-cutting work. The orchestrator should avoid implementing issues concurrently when their area sets intersect unless it has inspected the concrete scopes and established that they cannot collide.

## Project fields

The board uses the standard fields and views from `.claude/skills/configure-workflow/manifests/project.json`. Refresh IDs after recreating a field or replacing its options:

```sh
gh project field-list 7 --owner blac9216 --format json
```

| Configuration | Value |
|---|---|
| Repository | `blac9216/Pryvance` |
| Project owner | `blac9216` |
| Project number | `7` |
| Project ID | `PVT_kwHOBk6Ni84BimKa` |
| Automation account | `machine-blac9216` |

| Field | Field ID | Options (name → ID) |
|---|---|---|
| Status | `PVTSSF_lAHOBk6Ni84BimKazhhdnP0` | `Triage` → `9ac86186`; `Backlog` → `d863bd3d`; `Ready` → `4c5f838f`; `In progress` → `8b91652a`; `In review` → `e1a402ce`; `Done` → `6a0cc7fb` |
| Verified | `PVTSSF_lAHOBk6Ni84BimKazhhe6-Q` | `n/a` → `982e218a`; `pending-live` → `0cc3fb5d`; `live-verified` → `90e87c2d`; `live-failed` → `30a29626` |
| Claimed by | `PVTF_lAHOBk6Ni84BimKazhhe6-U` | Free text |

## Board administration

Keep the standard nine views in sync with the manifest. Board columns use Status; Roadmap groups by Milestone. In Project Workflows, enable auto-add for this repository with `is:issue is:open`, auto-add sub-issues, item added → Triage, and item closed → Done. Leave pull-request status automations and auto-archive off. Reopened issues are re-triaged by maintenance.

Configure default-branch protection with `bash .claude/skills/configure-workflow/scripts/rulesets.sh --repo blac9216/Pryvance --check design-docs` under an owner token. The standard requires PRs, the always-reporting documentation check, up-to-date branches, linear history, and protection against deletion/force pushes, with administrator bypass.

## Optional configuration

| Configuration | Value |
|---|---|
| Reviewer identity | none — single account; the review comment plus the merge are the verdict of record |
| Session-log archive | none — session logs stay scratch-only |

Local deviations from the canonical workflow: none currently declared.
