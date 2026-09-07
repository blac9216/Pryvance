# Maintenance

| Setting | Value |
|---|---|
| Worktree root | sibling worktrees outside the main checkout; exact machine path belongs in local guidance |
| Agent scratch dir | machine-local scratch outside the repository tree |
| Allowed write locations | issue worktree, configured scratch directory, and explicitly authorized generated-output paths |
| Test resource prefix (containers/volumes/networks) | unique Compose project name `pryvance-it-<run-id>`; see [testing.md](testing.md#local-database-topology) |
| Host thresholds | use machine-local guidance; no repository-wide numeric thresholds are declared yet |
| Shared sequence resources (serialise) | `backend/src/Pryvance.Web/Infrastructure/Persistence/Migrations/`, including `PryvanceDbContextModelSnapshot.cs` |

## Parallel-work maintenance rule

Before each parallel wave, compare the candidate issues' `area:*` labels from [labels.md](labels.md). Overlapping area sets are treated as a conflict risk and should be serialized unless the orchestrator has inspected the concrete file scopes and established that the diffs cannot overlap.

Database migrations are explicitly sequence-sensitive even when two backend changes otherwise appear independent. Serialize migration files and the context model snapshot, then regenerate a migration after rebasing when another schema change lands first.
