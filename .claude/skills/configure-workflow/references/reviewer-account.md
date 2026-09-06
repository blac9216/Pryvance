# Reviewer account (optional)

GitHub refuses reviews on your own pull request, so with a single automation account the
review verdict is a comment plus the merge. A second account makes reviews **native**:
Approve / Request changes, a ruleset that requires one approval, and auto-merge.

## Set up
1. Create a GitHub account for the reviewer (e.g. `<machine>-reviewer`). Enable 2FA.
2. Create a fine-grained or classic PAT for it with `repo` and `project` scopes.
3. Store the PAT in the owner's secrets mechanism (the `with-secrets` skill's inventory
   names the entry; do not hard-code the name anywhere in scripts).
4. Grant it: `scripts/grant.sh … --reviewer <login>` (collaborator write + Project admin).
   On a user-owned repository, a fresh account gets a pending invitation rather than an
   immediate grant — `grant.sh` reports "invited (pending acceptance)" vs "granted" so
   you know which happened; the account must accept before step 5 or step 6 can rely on
   its access.
5. Re-run `scripts/rulesets.sh --reviewer-account` so the ruleset requires one approval.
6. Record in `docs/process/work-tracking.md`'s configuration table:
   `| Reviewer identity | <login> via GH_TOKEN (with-secrets entry <name>); native reviews required. |`

## How it is used
Reviewer agents receive the token as `GH_TOKEN` in their own process — never `gh auth
switch`, which is global and races with other agents. `github-pr-review` submits the native
review and still posts the `## PR Review — …` comment with the detail.

## Skipping it
Write `| Reviewer identity | none — single account; the review comment plus the merge are
the verdict of record |` into `docs/process/work-tracking.md`'s configuration table.
`scripts/audit.sh` does not read this row or report a mode — the mode is declared here, in
`work-tracking.md`, and the reviewer skill reads it directly and falls back accordingly.
