# Agent guidance

## ⚠️ THIS IS A PUBLIC REPOSITORY — SANITIZATION IS MANDATORY

Pryvance is public on GitHub and is designed to process highly sensitive Household financial, tax, identity, insurance, property, document, credential, and recovery data. Nothing derived from a real Household may be committed.

Before every commit, verify that the diff contains none of the following:

- credentials, API/access/refresh tokens, private keys, certificates with private material, recovery secrets, encryption keys, or provider secrets;
- SSNs/tax IDs, full payment-card numbers, bank routing/account numbers, IBANs, policy identifiers, or other real financial/identity identifiers;
- real Household financial records, provider exports, statements, receipts, tax documents, insurance/property documents, database dumps, backups, recovery artifacts, screenshots, or copied document bodies;
- real email addresses, local/private hostnames, LAN/private-network addresses, Tailscale/internal infrastructure identifiers, or environment-specific configuration;
- logs, traces, command output, AI prompts/results, or error captures containing real Household/provider/environment data.

Rules of thumb:

- Committed examples, demos, seeds, imports, documents, and test fixtures are **synthetic from inception**. Never sanitize by lightly editing, redacting, masking, or perturbing real Household material and committing the result.
- The canonical committed fixture home is `fixtures/synthetic-household/`; grow that fictional Household incrementally as implemented tests/features need it.
- Prefer reserved example domains and RFC documentation network ranges. Use invalid placeholders when a checksum-valid sensitive-shaped value is unnecessary.
- A test that truly needs a valid sensitive-shaped identifier should construct it narrowly inside the test when practical, rather than publishing a reusable realistic-looking fixture value.
- If sensitive real data or a secret is committed, even briefly, treat it as an incident: stop further pushes, tell the user immediately, rotate any exposed secret, and rewrite affected history as appropriate.
- When in doubt, leave it out.

The mechanical hard gate is `.github/workflows/sanitize.yml`: it self-tests the Pryvance-specific detector, runs gitleaks, and scans the tracked repository for high-confidence Household/environment identifier shapes. Do not weaken or broadly exempt that gate to make a fixture pass; fix the fixture or make the smallest explicitly justified detector change with regression tests.

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
