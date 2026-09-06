# Work tracking — the four-layer shape in this repository

<!-- Scaffolded by configure-workflow. The general shape is defined by the github-workflow skill; this file holds only what is specific here. -->

| Layer | Here |
|---|---|
| Project board | [{{PROJECT_TITLE}} #<owner: project number>]({{PROJECT_URL}}) — owner `<owner: login>`; automation account `<owner: login>` (admin) |
| Milestones | delivery stories only; hardening/CI/tooling stay milestone-less |
| Epics | one domain per epic; events in comments |
| Issues | ≥1 `area:*` from [labels.md](labels.md) |

Board field ids (for scripts and dispatch prompts) — no script here prints these (`project.sh`
prints only a workflows/views UI checklist, and its `fid()` resolves field ids internally
without printing them); get them with `gh project field-list <n> --owner <owner> --format json`
(field ids and, for single-select fields, their option ids are both in that output) and fill
the table by hand:
<owner: field id table, one row per field: name | field id | option ids (if single-select)>

Reviewer identity and session-log archive, as table rows — the same form every other
configured value in this document already uses:

| Configuration | Value |
|---|---|
| Reviewer identity | {{REVIEWER_IDENTITY}} |
| Session-log archive | {{SESSION_LOG_ARCHIVE}} |

<!-- Reviewer identity: "none — single account; the review comment plus the merge are
     the verdict of record", or "<login> via GH_TOKEN; native reviews required by the
     ruleset". Session-log archive: "none — session logs stay scratch-only", or the
     archive repository in owner/name form. -->

Local deviations from the skill's defaults: <!-- owner: none, or list them -->
