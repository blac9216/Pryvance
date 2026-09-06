# Labels

The canonical set (types, severity, priority, concern, regression, backlog, deferred, parked, help, question, documentation) is provisioned by the configure-workflow skill and is a closed set — never invent a label. This file owns the repo-specific **area** set: what part of the codebase an issue touches, so orchestrators can deconflict parallel work. At least one per issue; several when the work is cross-cutting. Keep it coarse.

These areas are **merge-conflict / concurrency locks**, not product-domain ownership labels. Assign every area whose file territory is likely to appear in the issue's diff. Two issues whose `area:*` sets intersect should not be implemented in parallel unless the orchestrator has inspected the concrete file scopes and deliberately determined they are safe.

| Label | Colour | Covers |
|---|---|---|
| area:backend | d1e8ff | ASP.NET Core application code, domain/application services, REST endpoints, workers/jobs, provider adapters, and backend tests/configuration likely to share those files. |
| area:frontend | d1e8ff | React/PWA routes, components, client state, styling, client API bindings, and frontend tests/tooling colocated with the app. |
| area:db | d1e8ff | PostgreSQL schema, migrations, ORM/data-access mappings, seeds/reference data, database initialization, and other persistence metadata that can serialize otherwise-unrelated backend work. |
| area:ai-data | d1e8ff | AI orchestration, extraction/enrichment pipelines, search/vector indexing, embeddings, model/tool schemas, and their specialized configuration. |
| area:infrastructure | d1e8ff | Docker/Compose, deployment/runtime configuration, storage mounts/targets, networking, backup/runtime infrastructure, and operational environment scripts. |
| area:ci-tooling | d1e8ff | `.github/workflows`, repository automation, build/test tooling, developer scripts, `.claude`, and project-wide configuration files. |
| area:docs | d1e8ff | `docs/**`, ADRs, rationale, `CONTEXT.md`, architecture diagrams, README/contributor/process documentation, and documentation-only validation tooling when the diff is primarily documentation. |

Cross-cutting issues carry multiple area labels. Examples:

- backend persistence work: `area:backend` + `area:db`;
- backend integration-test CI work: `area:backend` + `area:ci-tooling`;
- API implementation plus contract updates: `area:backend` + `area:docs`;
- semantic search persistence: `area:backend` + `area:ai-data` + `area:db` when all three file territories are expected.

Add or split an area only when actual repository structure shows a recurring conflict surface that this set cannot describe cleanly.
