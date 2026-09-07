# Testing

## Required checks

- `design-docs`
- `secret + household-data scan`

Required check names are taken from the always-reporting GitHub Actions PR jobs. Both jobs run on every pull request with no path filter and are therefore suitable required checks for the default-branch ruleset.

## Commands

Pryvance has a runnable ASP.NET Core / React application shell, but application test suites arrive in issue #12. The executable checks currently cover application builds, documentation integrity, and repository sanitization:

| Suite | Command | Environment |
|---|---|---|
| backend restore | `dotnet restore backend/Pryvance.slnx` | .NET 10 SDK |
| backend build | `dotnet build backend/Pryvance.slnx --no-restore` | .NET 10 SDK |
| frontend install | `npm ci --prefix frontend` | Node.js `^20.19.0 || >=22.12.0` and npm |
| frontend build | `npm run --silent build --prefix frontend` | Node.js `^20.19.0 || >=22.12.0` and npm |
| production publish | `dotnet publish backend/src/Pryvance.Web/Pryvance.Web.csproj --no-restore` | .NET 10 SDK, Node.js `^20.19.0 || >=22.12.0`, and npm |
| rationale pointers | `bash scripts/docs/check-pointers.sh --root .` | repository checkout |
| ADR index | `bash scripts/docs/adr-index.sh --root . --check` | repository checkout |
| sanitizer self-tests | `cd .github/sanitize && python3 -m unittest discover -p 'test_*.py' -v` | repository checkout; Python 3 stdlib only |
| repo-specific sanitize scan | `python3 .github/sanitize/scan_repo_specific.py` | repository checkout |
| generic secret scan | `gitleaks detect --source . --no-banner` | repository checkout with gitleaks available; CI additionally scopes PR history as documented in `sanitize.yml` |

## CI coverage map

Both workflows run for every pull request and for pushes to `main`; neither has a path
filter.

| Required check | Workflow | What it covers | What it does not cover |
|---|---|---|---|
| `design-docs` | `.github/workflows/docs-checks.yml` | Rationale-pointer resolution and ADR-index consistency | Application restore, build, publish, or runtime behavior |
| `secret + household-data scan` | `.github/workflows/sanitize.yml` | Sanitizer self-tests, a history-aware gitleaks scan, and the Pryvance-specific repository scan | Application restore, build, publish, or runtime behavior |

Application runtime confidence therefore comes from the documented local commands and
review evidence until application CI suites are introduced.

## Local application shell

Build the client, then start the same-origin application host:

```sh
npm ci --prefix frontend
npm run --silent build --prefix frontend
dotnet run --project backend/src/Pryvance.Web/Pryvance.Web.csproj
```

Open the HTTP URL printed by ASP.NET Core. The shell calls `GET /api/v1/health` on that
host and shows the returned application version when the connection succeeds.

Run the sanitizer self-tests and repo-specific scan before pushing changes that add or alter examples, fixtures, logs, documents, imports, environment material, or sanitizer logic. The CI `sanitize` workflow remains the authoritative hard gate because it also performs the history-aware gitleaks scan.

Add exact unit, integration, lint, and coverage commands in the same change that makes each command real.

## Synthetic Household fixtures

Committed Household-shaped example/demo/test material belongs under `fixtures/synthetic-household/` and must be synthetic from inception. See that directory's `README.md` before adding fixtures. Do not derive committed fixtures from real Household records by masking, redaction, perturbation, or field replacement.

## Isolation on a shared host

The application can run directly from a worktree. Docker Compose and integration-test resources arrive in later Phase 0A issues; define deterministic per-worktree project/resource prefixes before parallel integration testing is enabled.

## Live testing

Pointer only: environment-specific recipes belong in `docs/testing.local.md` (untracked).
