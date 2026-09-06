# Session-log archive (optional)

`save-log.sh` in the github-workflow skill needs a durable destination for the session
log: a private repository it can PUT the whole local file into. This step creates or
verifies that repository, grants write access, and writes its location where every
consuming repo already learns repo-specific facts — `docs/process/work-tracking.md`.
Skip it and `save-log.sh` has nowhere to write; nothing else in the workflow depends on
it, so skipping is safe.

## Why a repository, not a gist

A secret gist is not private — anyone with the link can read it, and gists cap reads at
1 MB, which a growing session log will eventually exceed. A repository set to **private**
has neither limit and uses the same collaborator-grant machinery already in place for
every other repo this skill configures.

## Why the location lives in `docs/process/work-tracking.md`

`save-log.sh` and every other script that needs a repo-specific fact — the board id, the
reviewer identity, the required checks — reads it from `docs/process/work-tracking.md`.
The archive location is exactly that kind of fact: one value, specific to this
repository, that other tooling must discover the same way every time.

## Set up

This is an owner-wizard step: walk the owner through it interactively rather than
picking a name yourself. No owner-specific repository name belongs in this file or in
any skill prose — the example below is illustrative only.

1. Ask the owner for `<owner>/<repo>` to use as the archive. Suggest `<owner>/workflow-logs`
   as a default if they have no preference.
2. Check whether it exists: `gh repo view <owner>/<repo> --json isPrivate,name`.
   - If it does not exist, create it private: `gh repo create <owner>/<repo> --private`.
   - If it exists but is not private, stop and tell the owner — do not flip visibility on
     a repository you did not create without asking first.
3. Grant the automation account write access:
   `gh api -X PUT repos/<owner>/<repo>/collaborators/<machine-account> -f permission=push`.
   If `docs/process/work-tracking.md` already names a reviewer identity (not the
   single-account fallback), grant it too, the same way, with its own login.
   On a **user-owned** repository, this PUT does not grant access to an account that is
   not already a collaborator — it creates a **pending invitation** (HTTP 201 with an
   invitation object, rather than the 204 returned when the account is already a
   collaborator). The account cannot push until it accepts. Tell the owner so, and
   either wait for acceptance or have the account accept it itself: `gh api -X PATCH
   /user/repository_invitations/<id>` under its own token (find `<id>` via
   `gh api repos/<owner>/<repo>/invitations`). An
   org-owned repository adds collaborators without an invitation, so this step does not
   apply there.
4. Write the location into `docs/process/work-tracking.md`'s configuration table, next to
   the existing `Reviewer identity` row:
   `| Session-log archive | <owner>/<repo> |`
   If the owner declines this step, write `| Session-log archive | none — session logs
   stay scratch-only |` instead, so the fallback is a declared fact rather than a silent
   gap.

## Audit

Three checks, read-only. Skip all three — report "not configured (optional)" — when
`docs/process/work-tracking.md` has no `Session-log archive` row naming a repository
(the `none — …` fallback row reports the same way).

1. **The row is present.**
   `grep -n '| Session-log archive |' docs/process/work-tracking.md`
   A gap here is a missing declaration, the same class as a missing reviewer-identity
   row — the fallback row still counts as present.
2. **The repository exists and is private.**
   `gh repo view <owner>/<repo> --json isPrivate --jq .isPrivate`
   Must print `true`. A `404` here means the named repository does not exist (or the
   token cannot see it); anything but `true` is a gap.
3. **The grant is present.**
   `gh api repos/<owner>/<repo>/collaborators/<machine-account>/permission --jq .permission`
   Must print `write` or `admin`. Repeat for the reviewer account when
   `docs/process/work-tracking.md` names one.
   A `none` result may mean "invited, not accepted", not "never granted" — check
   `gh api repos/<owner>/<repo>/invitations` for a pending entry naming the account
   before treating it as a from-scratch gap.
