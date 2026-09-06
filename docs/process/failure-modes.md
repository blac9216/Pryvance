# Repo-specific failure modes

General workflow failure modes live in the canonical github-workflow skill. Record only Pryvance-specific failures that have actually occurred, with the guard that prevents recurrence.

- **Documentation design drift** — ADR index or rationale pointers can fall out of sync with the declared design set. Guard: the required `design-docs` CI job runs `scripts/docs/check-pointers.sh --root .` and `scripts/docs/adr-index.sh --root . --check` on every PR.
- **Parallel work collides through shared persistence metadata** — otherwise-unrelated backend issues can both touch migrations/schema metadata. Guard: apply `area:db` whenever database schema/migrations/mappings are expected in the diff and serialize overlapping area locks.
