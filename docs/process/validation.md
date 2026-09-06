# Live validation

Pryvance does not yet have a deployed application/runtime stack to validate. Until Phase 0 establishes one, live validation is not configured and no issue should be marked as requiring live proof solely because implementation runtime does not yet exist.

When a real stack exists, define here:

- which systems a validation run touches;
- whether those actions are read-only or mutating;
- the threshold for batching `pending-live` verification;
- what counts as an unacceptable workaround;
- where validation evidence is stored outside the repository tree;
- which credentials mechanism/pointer is used from `*.local.md`.

Credentials and environment-specific inventories must remain outside committed process docs.
