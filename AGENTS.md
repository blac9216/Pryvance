# Agent guidance

Before changing Pryvance architecture or domain behavior:

1. Read `CONTEXT.md` for canonical terminology.
2. Read `docs/adr/README.md` first, then open only relevant active ADRs.
3. Read the matching target-state C4/domain/security/API/explanation document from `docs/`.
4. Treat the design set as the intended feature-complete architecture approved so far. The roadmap sequences implementation; a later roadmap phase is not permission to implement an incompatible shortcut now.
5. Preserve the design path: decisions are discussed/planned on GitHub, then durable outcomes are recorded in the design set.
6. Do not commit transient design specs, interrogation transcripts, plans, research notes, or audit gap reports.
7. A code/configuration warning that needs durable local reasoning should use a `# why:` / `// why:` pointer into the appropriate `docs/rationale/*.md` file.
8. Update diagrams, domain invariants, API contract, security/privacy rules, and roadmap sequencing together when a change crosses those boundaries.
9. When a hard-to-reverse, surprising decision with real alternatives changes, create a new ADR rather than rewriting an Accepted ADR. Proposed ADRs may be refined while the architecture PR remains under review.
10. Do not infer that unimplemented means undesigned. Check the target-state docs before introducing new tables/endpoints/providers.

Pryvance's design set is declared in `docs/doc-manifest.md`.
