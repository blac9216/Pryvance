---
name: configure-workflow
description: Set up or audit a GitHub repository for the github-workflow skill — the Project board (fields, views, workflows), the canonical label set plus repo area labels, branch rulesets, account grants, the optional reviewer account, and the docs/process files the workflow reads. Use it for a fresh repo ("configure this repo for the workflow"), for auditing or repairing an already-configured one ("audit the workflow setup", "labels drifted", "add an area label"), for capturing an edited Project as the new standard ("make this board the template"), and when the github-workflow skill reports a missing fixture (no area labels, no docs/process, no Claimed by field). Idempotent: safe to re-run.
argument-hint: apply | audit | capture [--owner <login> --project <n>]
---

# Configure a repository for the workflow

The github-workflow skill assumes a set of fixtures exist and are exact: a Project with three
custom fields and a known set of views and automations, a closed label set with canonical
colours, a default branch that only accepts pull requests, an automation account that can
write to all of it, and `docs/process/` files that carry everything repo-specific. This skill
creates them, keeps them in sync, and turns your edited Project into the standard for the
next repository. Everything deterministic is a script; everything that needs judgment or
your credentials is a guided step.

`scripts/*` never discover their own configuration or interpret prose — every
repository-specific value they need is an argument you derive and pass in, never a file
they read at runtime — see
[github-workflow/references/github-tools.md](../github-workflow/references/github-tools.md)
§ Extraction vs. interpretation and #736's no-discovery boundary.

## Two kinds of steps

| Automation-owned (the session runs these) | Owner-owned (your credentials or the UI) |
|---|---|
| labels, Project fields/views, docs/process scaffolding, the audit | creating the Project and granting the automation account admin; branch rulesets; collaborator grants; Project workflows and view group-by/sort (UI only); the reviewer account |

Owner-owned scripts take the token as **input** (`GH_TOKEN`); they never read a vault. To run
one for the owner, use the `with-secrets` skill to inject the owner's token into that one
command — discover the key name from that skill's inventory or ask. If no token is
available, print the exact command for the owner to run themselves.

## `apply` — the order

1. **Orient.** `gh auth status` (automation account, needs `repo`, `project`, `read:org`);
   `gh repo view`; does `docs/process/` exist; is there a Project already
   (`gh project list --owner <login>`). Read `AGENTS.md`/`CLAUDE.md` and `.gitignore` as they
   are now — you will propose edits to them later, not overwrite them.
2. **The Project.** If none exists, ask the owner to create it — brief steps in
   [references/owner-wizard.md](references/owner-wizard.md) — and to say anything that
   changes how it is managed (a board shared by several repositories, an org-owned board).
   Then `scripts/project.sh --owner <login> --project <number>` brings it to the manifest and
   prints the UI checklist (workflows, group-by, sort) for the owner. Shared boards: apply
   the baseline first, then the multi-repo additions by hand —
   [references/shared-projects.md](references/shared-projects.md).
3. **Grants.** `scripts/grant.sh` (owner token) adds the automation account as collaborator
   and Project admin, and the reviewer account if one exists. Verify with `gh project list`
   under the automation account.
4. **Labels.** Propose the repo's `area:*` set from its top-level layout (coarse — a handful,
   e.g. backend / frontend / deploy / docs / ci, plus whatever the repo actually splits on),
   confirm with the owner, then write it as a JSON file —
   `[{"name":"area:x","color":"hex","description":"…"}]` — and hand it to
   `scripts/labels.sh --repo <owner/name> --areas <file>` (both required). It creates/corrects
   the canonical set, creates the areas, and prunes labels outside both when no open issue
   carries them (it reports the ones it kept). The same `--areas` file feeds `process-docs.sh`
   next, so it renders `labels.md`'s table from the identical input rather than the table being
   parsed back.
5. **docs/process.** `scripts/process-docs.sh` scaffolds the seven files, filling only what
   you pass it as a flag (`--project-title`, `--project-url`, `--unit-cmd`, `--lint-cmd`,
   `--worktree-root`, `--reviewer <login|none>`, `--archive <owner/repo|none>`,
   `--areas <file>`) — it makes no `gh` call and reads no file outside `templates/` and the
   `--areas` file, so every value is yours to derive and pass in. An omitted flag leaves its
   `{{MARKER}}` in place, exactly like an unfilled `<owner: …>` marker. Derive what you can
   from the repository — CI workflows, existing docs, README — and interview the owner only
   for what you genuinely cannot derive (live systems, thresholds, overnight limits). Show
   drafts before writing. `<owner: …>` markers and `{{MARKERS}}` left behind fail the audit.
   Board field/option ids for `work-tracking.md`'s field-id table are not printed by any
   script here — `project.sh` prints only a workflows/views UI checklist, and `fid()` resolves
   field ids internally without printing them — so get them yourself with
   `gh project field-list <n> --owner <owner> --format json` (field ids and, for single-select
   fields, their option ids are both in that output) and fill the table by hand.
6. **Ruleset.** `scripts/rulesets.sh --repo owner/name [--check <name>]…` (owner token)
   applies the default-branch ruleset: require a PR, the required checks you pass as
   repeated `--check <name>` arguments — read them from `docs/process/testing.md`'s "##
   Required checks" section yourself and pass them back; giving none means "require a PR
   but no checks" — strict up-to-date, no force-push/deletion, linear history, admin
   bypass. Before running it, confirm every required check **always reports** on PRs — a
   path-filtered workflow that never runs on a docs PR blocks that PR forever.
7. **Reviewer account (optional).** [references/reviewer-account.md](references/reviewer-account.md).
   If the owner skips it, write the row `| Reviewer identity | none — single account; the
   review comment plus the merge are the verdict of record |` into
   `docs/process/work-tracking.md`'s configuration table so the fallback is a declared
   fact.
8. **Session-log archive (optional).** [references/session-log-archive.md](references/session-log-archive.md).
   Walk the owner through naming or creating a private repository for `save-log.sh` to
   archive session logs into, grant it the same way as the automation and reviewer
   accounts, and write the row `| Session-log archive | <owner>/<repo> |` into
   `docs/process/work-tracking.md`'s configuration table. If the owner skips it, write
   `| Session-log archive | none — session logs stay scratch-only |` instead, so the
   fallback is a declared fact.
9. **Repo files.** Read `.gitignore`, `AGENTS.md`/`CLAUDE.md` and any worktree convention;
   propose the minimal edits (ignore `*.local.md`; a pointer that process lives in
   `docs/process/` and work follows the github-workflow skill) and let the owner decide.
   Apply only what they approve.
10. **Skills.** The repo needs its own installed copy of every skill and agent in the
    family (cloud sessions cannot see this repository's canonical copy directly) —
    [references/propagation.md](references/propagation.md).
11. **Audit.** `scripts/audit.sh --owner <login> --project <number> --machine <login> --repo
    owner/name --family manifests/family.json --areas <areas.json>` — every
    fixture present and exact, or a list of gaps. Re-run until clean; that is the exit.
    `--areas` takes the **same area-set JSON file you wrote in step 4** and handed to
    `labels.sh` and `process-docs.sh` — the `[{"name":"area:x","color":"hex",
    "description":"…"}]` array. It is **not** `docs/process/labels.md`: that table is
    *rendered from* this JSON (step 4), never parsed back, and passing it makes
    `labels.sh` exit 2 — which `audit.sh` now reports as a usage error rather than as
    label drift. Step 4 names no home for the file, so keep it alongside your session
    card for the life of the session and pass that path here. (`--family` is
    skill-relative shorthand, like `scripts/audit.sh` itself; it and `--areas` are both
    resolved against the process cwd when you actually invoke the script, so pass their
    paths as seen from wherever you run it.)

## `audit`

Run `scripts/audit.sh` alone for every mandatory fixture — it is read-only and exits
non-zero on any gap. The expected skill/agent family it checks for comes from
`manifests/family.json` (`--family`, required, alongside `--repo`), not a hardcoded
list — adding a role to the family is one manifest edit. `--areas <areas.json>` is also
required and is threaded straight through to `labels.sh --audit`, so it must be the
same area-set **JSON** file step 4 wrote and handed to `labels.sh` and
`process-docs.sh` — kept alongside your session card, since step 4 names no home for
it. `docs/process/labels.md` is not that file: it is the table `process-docs.sh`
renders *from* the JSON, and `labels.sh` rejects it (exit 2). `audit.sh` distinguishes
the two outcomes — `labels.sh` exit 1 is real drift and reports
`GAP labels drift`, while exit 2 is a usage/`--areas` error and aborts with
`labels.sh usage/--areas error` naming the path, so a mis-passed file can never be
silently reported as drift. Run it when the workflow skill
reports a missing fixture, after anyone edits the Project by hand, and before trusting a
repo you have not configured yourself. The two optional steps carry no code in
`audit.sh`; you run their checks
yourself, by hand, from their own reference files, and each reports "not configured
(optional)" when the owner skipped the step: the reviewer account has no dedicated
check ([references/reviewer-account.md](references/reviewer-account.md) — read the
`| Reviewer identity | … |` row in `docs/process/work-tracking.md` yourself), and the
session-log archive has three
([references/session-log-archive.md](references/session-log-archive.md): row present,
repository exists and is private, grant present).

## `capture` — make an edited Project the standard

The owner edits the board in the UI; the manifest must follow, or the next repository gets
the old shape. `scripts/capture.sh --owner <login> --project <number>` snapshots fields, options,
views (layout, filter, columns, group-by, sort) and enabled workflows into
`manifests/project.json`. Show the owner the diff of the manifest before committing to it,
then propagate the skill so every copy carries the new standard. Group-by and sort are
captured for the checklist; the API cannot set them.

## What lives where

- **Manifests** ([manifests/](manifests/)): `labels.json` (canonical set — the contract),
  `project.json` (the board standard), `rulesets.json` (the branch rules), `family.json`
  (the expected skill and agent set — read, never restated). One standard for every
  repository; repo-specific values never go here.
- **Repo-specific** values live in the repo's `docs/process/`: area labels, required
  check names, test commands, worktree root, thresholds, overnight limits, reviewer
  identity. This skill's agent reads that directory once, at configuration time, to
  derive those values and build the session card. github-workflow reads the session card
  (`<scratch>/session-card.md`) at runtime and after every resume; `docs/process/` is
  what built the card, not a file the running session re-derives values from itself.
- **Templates** ([templates/process/](templates/process/)): the seven `docs/process` files
  with `{{MARKERS}}` the script fills and `<owner: …>` markers you fill.

## Things that will bite

- The automation account cannot create a Project on a personal account, cannot read or
  write rulesets without admin, and cannot see the owner's branch protection at all — a
  `404` from those endpoints means "not your role", not "does not exist".
- Project workflows and view group-by/sort exist only in the UI; the checklist is the
  mechanism. Workflows are *readable*, so the audit verifies they are enabled.
- Large boards cost GraphQL points; the scripts read each field/view list once.
- Deleting a label removes it from closed issues too; that is why pruning checks open
  issues only and reports rather than deletes when a non-canonical label is still in use.
- The `scripts/*.sh` require **bash ≥ 4** (case-folding parameter expansion, e.g.
  `${var,,}`, is bash-4-only and fails at expansion time on bash 3.2 — still the system
  `/bin/bash` on macOS — with `bash: ${acct,,}: bad substitution`, a runtime error rather
  than a parse/syntax error or a graceful failure). `_lib.sh` enforces this with an
  explicit version check that fails with a named message before any script does real
  work.
