# Documentation manifest — as adopted here

This repository follows the `design-docs` skill standard mirrored from the owner's `storage` repository. This file records Pryvance's adopted shape.

## Design-set intent

The design set describes the feature-complete target architecture approved so far. The roadmap sequences implementation; capabilities implemented later are still designed in the target-state explanation/reference documents before implementation begins.

## Design set
- docs/explanation/architecture.md
- docs/explanation/domain-model.md
- docs/explanation/planning-and-forecasting.md
- docs/explanation/wealth-records-and-tax.md
- docs/explanation/integrations-and-automation.md
- docs/explanation/security.md
- docs/explanation/roadmap.md
- docs/reference/api-contract.md
- docs/adr/
- docs/rationale/
- CONTEXT.md

## Diátaxis directories
tutorials: docs/tutorials/ · how-to: docs/how-to/ · reference: docs/reference/ · explanation: docs/explanation/
Index: docs/README.md

## ADRs
Directory: docs/adr/ · Range in use: 0001–0012 · Normalisation ADR: none — all ADRs created post-adoption
Index markers: `<!-- adr-index:start -->` / `<!-- adr-index:end -->` in docs/adr/README.md

## Rationale areas
- backend → docs/rationale/backend.md
- frontend → docs/rationale/frontend.md
- infrastructure → docs/rationale/infrastructure.md
- ai-data → docs/rationale/ai-data.md

## Glossary
CONTEXT.md at repo root · domain model: docs/explanation/domain-model.md

## CI
`check-pointers.sh` and `adr-index.sh --check` run in: .github/workflows/docs-checks.yml
Scripts source: scripts/docs/

## Design path
Durable decisions are recorded in ADRs, rationale, the glossary, and the target-state C4/design set. Specs, plans, interrogation records, and audit gap reports are not committed. Adopted under ADR-0001.
