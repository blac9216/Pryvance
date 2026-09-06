# Testing

## Required checks

- `design-docs`

The required check name is taken from the current GitHub Actions PR job. It runs on every pull request and is therefore the required check for the default-branch ruleset.

## Commands

Pryvance does not yet have the target ASP.NET Core / React implementation tree or application test suites. Do not invent placeholder unit/integration/lint commands. Until Phase 0 establishes them, the committed executable checks are the documentation integrity checks used by CI:

| Suite | Command | Environment |
|---|---|---|
| rationale pointers | `bash scripts/docs/check-pointers.sh --root .` | repository checkout |
| ADR index | `bash scripts/docs/adr-index.sh --root . --check` | repository checkout |

When the application solution is introduced, add the exact unit, integration, lint, coverage, and sanitize commands here in the same change that makes those commands real.

## Isolation on a shared host

No application stack exists yet, so there are currently no container/project-name/port collision rules beyond keeping each issue in its own Git worktree. When Docker Compose and integration stacks are introduced, define deterministic per-worktree project/resource prefixes here before parallel integration testing is enabled.

## Live testing

Pointer only: environment-specific recipes belong in `docs/testing.local.md` (untracked).
