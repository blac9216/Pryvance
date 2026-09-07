# Documentation manifest — as adopted here

This repository follows the `design-docs` skill standard mirrored from the owner's `storage` repository. The design documents describe the feature-complete target architecture approved so far; the roadmap sequences implementation rather than defining later architecture by itself. `docs/explanation/future-features.md` is a durable explanation of deferred opportunities and does not expand the approved target architecture until an item is separately researched, decided, and promoted.

## Design set
- docs/explanation/architecture.md
- docs/explanation/domain-model.md
- docs/explanation/planning-and-forecasting.md
- docs/explanation/wealth-records-and-tax.md
- docs/explanation/integrations-and-automation.md
- docs/explanation/storage-and-recovery.md
- docs/explanation/operations-and-jobs.md
- docs/explanation/security.md
- docs/explanation/roadmap.md
- docs/explanation/future-features.md
- docs/reference/api-contract.md
- docs/reference/operations-api.md
- docs/reference/data-model.md
- docs/reference/alert-catalog.md
- docs/adr/
- docs/rationale/
- CONTEXT.md

## Diátaxis directories
tutorials: docs/tutorials/ · how-to: docs/how-to/ · reference: docs/reference/ · explanation: docs/explanation/
Index: docs/README.md

## ADRs
Directory: docs/adr/ · Range in use: 0001–0015 · Normalisation ADR: none — all ADRs created post-adoption
Index markers: `<!-- adr-index:start -->` / `<!-- adr-index:end -->` in docs/adr/README.md

## Rationale areas
- backend → docs/rationale/backend.md
- frontend → docs/rationale/frontend.md
- infrastructure → docs/rationale/infrastructure.md
- ai-data → docs/rationale/ai-data.md

## Glossary
CONTEXT.md at repo root · domain model: docs/explanation/domain-model.md · persistence reference: docs/reference/data-model.md

## CI
`check-pointers.sh` and `adr-index.sh --check` run in: .github/workflows/docs-checks.yml
Scripts source: scripts/docs/

## Design path
Durable decisions are recorded in ADRs, rationale, the glossary, and the declared design set. Specs, plans, interrogation records and audit gap reports are not committed. Deferred opportunity context may be preserved in `docs/explanation/future-features.md`, but it is not an approved design decision until promoted through the normal design process. Adopted under ADR-0001.
