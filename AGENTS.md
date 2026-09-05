# Agent guidance

Before changing Pryvance architecture or domain behavior:

1. Read `CONTEXT.md` for canonical terminology.
2. Read `docs/adr/README.md` first, then open only relevant active ADRs.
3. Read the matching C4/domain/security/API document from `docs/`.
4. Preserve the design path: decisions are discussed/planned on GitHub, then durable outcomes are recorded in the design set.
5. Do not commit transient design specs, interrogation transcripts, plans, research notes, or audit gap reports.
6. A code/configuration warning that needs durable local reasoning should use a `# why:` / `// why:` pointer into the appropriate `docs/rationale/*.md` file.
7. Update diagrams and prose together when architecture changes.
8. When a hard-to-reverse, surprising decision with real alternatives changes, create a new ADR rather than rewriting an Accepted ADR.

Pryvance's initial design set is declared in `docs/doc-manifest.md`.
