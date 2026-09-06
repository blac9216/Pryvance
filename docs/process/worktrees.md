# Worktrees

Use one Git worktree per active implementation/review branch. The main checkout is for orchestration and repository inspection, not issue implementation.

## Root

The exact machine path is environment-specific and belongs in local guidance. Use a sibling directory outside the main Pryvance checkout so worktrees do not nest inside one another.

## Naming

- issue implementation: `issue-<number>-<short-slug>`
- review/fix work uses the existing issue worktree unless the canonical workflow explicitly requires a separate one
- delete the worktree after merge/close once no active process depends on it

## Conflict safety

Before creating or dispatching parallel worktrees, compare the issues' `area:*` labels from [labels.md](labels.md). Intersecting area sets indicate likely overlapping diffs and should be serialized unless the orchestrator has inspected the concrete file paths and determined they cannot collide.
