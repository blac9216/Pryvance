# Testing

## Required checks

- `design-docs`
- `secret + household-data scan`

Required check names are taken from the always-reporting GitHub Actions PR jobs. Both jobs run on every pull request with no path filter and are therefore suitable required checks for the default-branch ruleset.

## Commands

Pryvance does not yet have the target ASP.NET Core / React implementation tree or application test suites. Do not invent placeholder unit/integration/lint commands. Until Phase 0 establishes them, the committed executable checks are the documentation integrity and repository sanitization checks used by CI:

| Suite | Command | Environment |
|---|---|---|
| rationale pointers | `bash scripts/docs/check-pointers.sh --root .` | repository checkout |
| ADR index | `bash scripts/docs/adr-index.sh --root . --check` | repository checkout |
| sanitizer self-tests | `cd .github/sanitize && python3 -m unittest discover -p 'test_*.py' -v` | repository checkout; Python 3 stdlib only |
| repo-specific sanitize scan | `python3 .github/sanitize/scan_repo_specific.py` | repository checkout |
| generic secret scan | `gitleaks detect --source . --no-banner` | repository checkout with gitleaks available; CI additionally scopes PR history as documented in `sanitize.yml` |

Run the sanitizer self-tests and repo-specific scan before pushing changes that add or alter examples, fixtures, logs, documents, imports, environment material, or sanitizer logic. The CI `sanitize` workflow remains the authoritative hard gate because it also performs the history-aware gitleaks scan.

When the application solution is introduced, add the exact unit, integration, lint, and coverage commands here in the same change that makes those commands real.

## Synthetic Household fixtures

Committed Household-shaped example/demo/test material belongs under `fixtures/synthetic-household/` and must be synthetic from inception. See that directory's `README.md` before adding fixtures. Do not derive committed fixtures from real Household records by masking, redaction, perturbation, or field replacement.

## Isolation on a shared host

No application stack exists yet, so there are currently no container/project-name/port collision rules beyond keeping each issue in its own Git worktree. When Docker Compose and integration stacks are introduced, define deterministic per-worktree project/resource prefixes here before parallel integration testing is enabled.

## Live testing

Pointer only: environment-specific recipes belong in `docs/testing.local.md` (untracked).
