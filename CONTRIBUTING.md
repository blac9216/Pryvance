# Contributing to Pryvance

Thanks for helping improve Pryvance. The project is intentionally architecture-led and privacy-sensitive, so contributions should preserve the documented design, security boundaries, and issue-driven workflow rather than introducing local shortcuts.

## Start with an issue

Non-trivial changes should begin with a GitHub issue. Before implementing:

1. Read [`CONTEXT.md`](CONTEXT.md) for canonical terminology.
2. Read [`AGENTS.md`](AGENTS.md) for repository guidance.
3. Read the relevant design material under [`docs/`](docs/), including active ADRs when applicable.
4. Read [`docs/process/`](docs/process/) for the repository workflow, testing, labels, worktrees, and validation rules.
5. Confirm the issue has the appropriate `area:*` conflict-lock labels before starting work.

Large or design-changing proposals should be discussed before implementation. Accepted architecture is not overridden by an implementation shortcut or prototype behavior.

## Development workflow

Pryvance uses an issue-driven pull-request workflow. Work should be performed on a branch/worktree associated with the issue and proposed through a pull request to `main`.

Keep a pull request focused on one issue or one explicitly planned cohesive group. Do not mix unrelated cleanup into a feature or bug fix. If you discover unrelated work, file it separately.

Do not commit:

- secrets, credentials, tokens, recovery material, or private keys;
- real Household financial, identity, tax, insurance, document, or other sensitive data;
- environment-specific `*.local.md` files;
- transient plans, interrogation transcripts, audit scratch notes, or research artifacts that the repository guidance says should remain uncommitted.

## Testing

Run the commands documented in [`docs/process/testing.md`](docs/process/testing.md) that apply to your change.

At the current repository stage, the committed required CI check is `design-docs`, backed by:

```sh
bash scripts/docs/check-pointers.sh --root .
bash scripts/docs/adr-index.sh --root . --check
```

When application unit, integration, lint, coverage, or security-scan commands are introduced, `docs/process/testing.md` becomes the authority for those commands.

## Documentation and design changes

Update prose and diagrams together when architecture changes. Changes to hard-to-reverse or surprising accepted decisions should normally be recorded through a new ADR rather than rewriting history.

For persistence/schema work, consult [`docs/reference/data-model.md`](docs/reference/data-model.md). For API changes, consult the relevant API reference. For security-sensitive changes, consult [`docs/explanation/security.md`](docs/explanation/security.md) and [`SECURITY.md`](SECURITY.md).

## Pull requests

A useful pull request should:

- identify the issue it resolves;
- explain the change and any important design implications;
- keep the diff scoped to the planned work;
- update documentation where behavior or architecture changes;
- include test evidence appropriate to the change;
- avoid unresolved TODOs that hide required correctness or security work.

All contributions are subject to review and may be declined when they conflict with the target architecture, security/privacy requirements, licensing policy, or project scope.

## Contributor license grant

Pryvance is distributed under **GNU AGPL-3.0-only**. The project also intends to preserve the ability to offer the software under alternative or commercial license terms in the future.

By intentionally submitting a copyrightable contribution for inclusion in Pryvance, you represent that you have the right to submit it and, upon acceptance of the contribution, you:

1. retain ownership of your copyright;
2. license the contribution to recipients as part of Pryvance under GNU AGPL-3.0-only; and
3. grant the maintainer of the canonical Pryvance repository a perpetual, worldwide, non-exclusive, royalty-free, irrevocable license, with the right to sublicense, to use, reproduce, modify, prepare derivative works of, publicly display, publicly perform, distribute, and otherwise license the contribution under the project's open-source license or under alternative license terms.

To the extent you control patent claims necessarily infringed by your accepted contribution, you also grant a perpetual, worldwide, non-exclusive, royalty-free, irrevocable patent license to make, have made, use, offer to sell, sell, import, and otherwise transfer the contribution as incorporated into Pryvance.

This grant does **not** transfer ownership of your contribution. It exists so accepted third-party contributions do not prevent future dual licensing or commercial licensing of Pryvance.

If you are contributing on behalf of an employer or another organization, you are responsible for ensuring you have authority to make these grants.

For a substantial external contribution, maintainers may ask for explicit written confirmation of this contributor license grant in the pull request before merging. This policy should be reviewed by qualified counsel before the project begins accepting significant third-party contributions at scale.

## Code of Conduct

Participation in the project is governed by [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## Security issues

Do not report vulnerabilities in a public issue. Follow [`SECURITY.md`](SECURITY.md).
