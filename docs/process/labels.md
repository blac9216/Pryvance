# Labels

The canonical set (types, severity, priority, concern, regression, backlog, deferred, parked, help, question, documentation) is provisioned by the configure-workflow skill and is a closed set — never invent a label. This file owns the repo-specific **area** set: what part of the codebase an issue touches, so orchestrators can deconflict parallel work. At least one per issue; several when the work is cross-cutting. Keep it coarse.

These areas are **merge-conflict / concurrency locks**, not product-domain ownership labels. Assign every area whose file territory is likely to appear in the issue's diff. Two issues whose `area:*` sets intersect should not be implemented in parallel unless the orchestrator has inspected the concrete file scopes and deliberately determined they are safe.

| Label | Colour | GitHub description |
|---|---|---|
| area:backend | d1e8ff | ASP.NET Core services, REST endpoints, workers, provider adapters, and backend tests. |
| area:frontend | d1e8ff | React/PWA components, routes, state, styling, API bindings, and frontend tests/tooling. |
| area:db | d1e8ff | PostgreSQL schema, migrations, data-access mappings, seeds, and persistence metadata. |
| area:ai-data | d1e8ff | AI orchestration, extraction, search/vector indexing, embeddings, and model/tool schemas. |
| area:infrastructure | d1e8ff | Docker/Compose, deployment, storage mounts, networking, backups, and environment scripts. |
| area:ci-tooling | d1e8ff | GitHub workflows, repository automation, build/test tooling, scripts, and workflow skills. |
| area:docs | d1e8ff | Design, ADRs, rationale, glossary, diagrams, contributor/process docs, and documentation checks. |

The `area:db` lock includes initialization and generated persistence metadata; `area:ci-tooling` includes `.claude` and project-wide configuration. Cross-cutting issues carry multiple area labels. Examples:

- backend persistence work: `area:backend` + `area:db`;
- backend integration-test CI work: `area:backend` + `area:ci-tooling`;
- API implementation plus contract updates: `area:backend` + `area:docs`;
- semantic search persistence: `area:backend` + `area:ai-data` + `area:db` when all three file territories are expected.

Add or split an area only when actual repository structure shows a recurring conflict surface that this set cannot describe cleanly.
