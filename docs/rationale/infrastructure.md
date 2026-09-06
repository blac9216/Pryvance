# Rationale Index — infrastructure/

Kind: explanation

Local implementation reasoning for Docker, deployment, persistence, networking, CI, and operations lives here when code/configuration needs durable context. Pointers use `# why: docs/rationale/infrastructure.md#<kebab-slug>`.

Entries are added only when implementation exists; each entry explains the constraint or trade-off rather than restating configuration and ends with a `Refs:` line.

### skill-fixture-pointers
Installed workflow skills include negative-test fixtures and reference examples whose rationale targets belong to synthetic repositories.
The repository pointer check skips skill tests and references so those examples do not fail Pryvance CI; other skill files and Pryvance code remain checked.
Keep canonical skill copies unchanged so propagation remains reproducible.
Refs: scripts/docs/check-pointers.sh, .claude/skills/design-docs/scripts/check-pointers.sh
