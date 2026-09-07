# Rationale Index — CI required checks

Kind: explanation

### always-reporting-backend-check
The required `backend tests` job must report for every pull request, including changes that do not need .NET tests.
Its gate accepts a skipped test job only when the path filter explicitly reports no backend input changed.
Filter failures, missing outputs, cancellations, and applicable test failures remain blocking failures.
Refs: .github/workflows/backend.yml, docs/process/testing.md, #14
