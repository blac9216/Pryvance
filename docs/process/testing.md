# Testing

## Required checks

- `design-docs`
- `secret + household-data scan`

Required check names are taken from the always-reporting GitHub Actions PR jobs. Both jobs run on every pull request with no path filter and are therefore suitable required checks for the default-branch ruleset.

## Commands

Pryvance has a runnable ASP.NET Core / React application shell, but application test suites arrive in issue #13. The executable checks currently cover application builds, documentation integrity, and repository sanitization:

| Suite | Command | Environment |
|---|---|---|
| backend restore | `dotnet restore Pryvance.slnx` | .NET 10 SDK |
| backend build | `dotnet build Pryvance.slnx --no-restore` | .NET 10 SDK |
| frontend install | `npm ci --prefix src/Pryvance.Web/ClientApp` | Node.js 20+ and npm |
| frontend build | `npm run --silent build --prefix src/Pryvance.Web/ClientApp` | Node.js 20+ and npm |
| production publish | `dotnet publish src/Pryvance.Web/Pryvance.Web.csproj --no-restore` | .NET 10 SDK, Node.js 20+, and npm |
| rationale pointers | `bash scripts/docs/check-pointers.sh --root .` | repository checkout |
| ADR index | `bash scripts/docs/adr-index.sh --root . --check` | repository checkout |
| sanitizer self-tests | `cd .github/sanitize && python3 -m unittest discover -p 'test_*.py' -v` | repository checkout; Python 3 stdlib only |
| repo-specific sanitize scan | `python3 .github/sanitize/scan_repo_specific.py` | repository checkout |
| generic secret scan | `gitleaks detect --source . --no-banner` | repository checkout with gitleaks available; CI additionally scopes PR history as documented in `sanitize.yml` |

## Local application shell

Build the client, then start the same-origin application host:

```sh
npm ci --prefix src/Pryvance.Web/ClientApp
npm run --silent build --prefix src/Pryvance.Web/ClientApp
dotnet run --project src/Pryvance.Web/Pryvance.Web.csproj
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
