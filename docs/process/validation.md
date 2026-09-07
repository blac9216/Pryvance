# Live validation

Pryvance has a local synthetic Compose stack for implementation validation, but no
deployed stack for live validation. A local run may verify readiness, migration history,
a PostgreSQL round-trip, and restart persistence using only its uniquely named Compose
containers, networks, and disposable volume. Any mutation must use synthetic data and
the run must remove only its own resources.

These local checks do not establish authenticated end-to-end product behavior; that
acceptance remains with #19. No issue should be marked as requiring live proof solely
because a deployed runtime does not yet exist.

When a real stack exists, define here:

- which systems a validation run touches;
- whether those actions are read-only or mutating;
- the threshold for batching `pending-live` verification;
- what counts as an unacceptable workaround;
- where validation evidence is stored outside the repository tree;
- which credentials mechanism/pointer is used from `*.local.md`.

Credentials and environment-specific inventories must remain outside committed process docs.
