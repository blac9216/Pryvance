# Agent guidance

Before changing Pryvance architecture or domain behavior:

1. Read `CONTEXT.md` for canonical terminology.
2. Read `docs/adr/README.md` first, then open only relevant active ADRs.
3. Read `docs/explanation/architecture.md` and the matching domain/security explanation.
4. For persistence/schema work, read `docs/reference/data-model.md` before creating migrations.
5. For async/background work, read `docs/explanation/operations-and-jobs.md`; do not add ad-hoc in-memory queues/timers that bypass the durable Job model.
6. For document/object storage or backup work, read `docs/explanation/storage-and-recovery.md` and ADR-0007/0014.
7. For Alert production, use stable types from `docs/reference/alert-catalog.md` or deliberately extend the catalog.
8. For APIs, read both `docs/reference/api-contract.md` and `docs/reference/operations-api.md` as applicable.
9. Preserve the design path: durable decisions are recorded in the design set; the roadmap controls sequencing only.
10. Do not commit transient design specs, interrogation transcripts, plans, research notes, or audit gap reports.
11. Code/config warnings requiring durable local reasoning should use a `# why:` / `// why:` pointer into the appropriate `docs/rationale/*.md` file.
12. Update diagrams and prose together when architecture changes.
13. When a hard-to-reverse, surprising decision changes after its ADR is Accepted, create a new ADR rather than rewriting it.
14. Before issue-driven implementation or orchestration, read `docs/process/` for repository-specific workflow configuration. In particular, treat `area:*` labels from `docs/process/labels.md` as likely Git diff conflict locks for parallel work, not as product-domain ownership labels.
15. Work under the repository's canonical `github-workflow` process when that skill is installed; repository-specific commands, worktree rules, validation limits, and conflict areas live in `docs/process/` rather than in ad-hoc chat/session instructions.

Pryvance's target design set is declared in `docs/doc-manifest.md`.
