# PR Body Template

The **Suggested Test Steps**, **Risk**, and **Rollback** sections are required. If
the PR is part of an epic, reference it (`Part of #<epic>`) below the `Closes` line. Closing keywords go on their
own line at the top — never inside prose, where they close the wrong things at merge.

Closing keywords must live in the PR **body** — GitHub only links issues from keywords
in the body, not from commit messages, even when those commits are on the PR's branch.
For multi-issue PRs, put every `Closes #<issue>` on its own line. This matters most at
merge: on squash, GitHub composes the commit message per the repository's
default-commit-message setting (PR title / title+description / title+commit details) and can
silently drop closing keywords that only existed in individual commits, closing fewer
issues than intended (or none). Before merging, verify `closingIssuesReferences` on the
PR matches every issue you intend to close, and pass the PR body explicitly via
`--body-file` to the squash so the keywords survive.

## Claims about another PR or issue

Any claim about what happened to another PR or issue — that it merged, that it aborted,
that its review found or missed something — carries the **permalink to the comment that
establishes it**, inline, in whichever artifact makes the claim. Open that comment and
read the line you are relying on before citing it. A claim whose own source says the
opposite reads as support, survives a skim, and — because a PR body is what
`--body-file` passes to the squash — lands uncorrectably in the repository's history. A
claim you cannot back with a permalink is not support: delete it rather than soften it,
and let the argument stand on what you can show.

**The duty is on whichever agent makes the claim, in any role.** It is stated here
because this is the artifact that most often carries such a claim, not because it is
author-side: it binds a PR body, an evidence manifest and a `Fixes Applied` comment, and
it binds a review verdict, a merge-verification report and a calibration rationale
exactly as hard. A verdict is at least as durable as a body — it is what later rounds,
calibrators and deferred issues quote from — so an uncited claim there travels further,
not less far, than one written here. Every artifact stating this duty points at this
section rather than restating it, so the halves cannot drift apart.

`github-pr-review`'s attack-list item 14, literal-text verification, is the other half
of the same rule and not a substitute for it: item 14 has a reviewer open the cited
document and compare its literal text against a claim it is **checking**, and so catches
an inverted claim already written; this rule stops one being written, whoever writes it.

```markdown
Closes #<issue>
Closes #<issue2>   <!-- one line per issue for multi-issue PRs -->

## Summary
What changed and why.

## Risk
What could regress, what areas are touched indirectly, blast radius.
Be honest — "no risk" is rarely true.

## Rollback
How to revert if this introduces a regression. Usually `git revert <sha>`,
but flag any state migrations, schema changes, or destructive operations that
complicate a clean revert.

## Suggested Test Steps
Concrete, change-specific steps a fresh reviewer can follow to validate this PR.
Each step must be reproducible and state its expected result. For enhancements,
align these 1:1 with the issue's Acceptance Criteria.

Write every step against the PR's own content, never against a moving remote ref.
A step whose result depends on where `origin/main` happens to point — an ancestry check
(`git merge-base --is-ancestor origin/main HEAD`), a two-dot base comparison
(`git diff origin/main..HEAD`) — passes for the author at push time and fails for a
reviewer minutes later, as soon as an unrelated PR merges; since a failed suggested step
is an unconditional Changes-Requested trigger, such a step turns the verdict into a race
against merges this PR has nothing to do with. Base staleness is already the reviewer's
own pre-merge check, so it does not belong in this list.

A three-dot range is the one exception: `git diff origin/main...HEAD` diffs from the
merge base of the two refs, and that merge base does not move when `origin/main`
advances — a commit added to the base branch after this branch's point of divergence is
not an ancestor of HEAD and cannot change where the two histories parted. The reviewer
sees what the author saw, so a three-dot step is reproducible and allowed; the two-dot
and `--is-ancestor` forms above read `origin/main`'s current tip and are not.

`check-test-steps.sh` no longer enforces this rule mechanically: the `NAMES`/`PATTERNS`
moving-ref check was interpretation of prose and was removed per the 2026-09-05 owner
ruling on #732 (item 4, issue #752). Hand-check your own step list against the rule
above before posting. `check-test-steps.sh --check-shas` still holds every 40-hex commit
SHA named anywhere in the body — a `## Rollback` or mutation-probe SHA — to being an
ancestor of the current head, which a mid-review rebase or force-push can silently
break; run it (`--body-file` reads local disk and issues no API call at all) before you
post:

    bash .claude/skills/github-workflow/scripts/check-test-steps.sh --body-file <body.md> --check-shas

It reports each unreachable SHA and the body section that carries it, exits 1 when any
was found, 0 when every SHA in the body is reachable (including when the body names
none), and without `--check-shas` checks nothing at all.

1. <step> — expected: <result>
2. <step> — expected: <result>

## Verified expectation
`n/a` | `pending-live` — <what only the real stack can prove>. Copied from the issue;
the reviewer sets the board's `Verified` field from this line at merge.
```
