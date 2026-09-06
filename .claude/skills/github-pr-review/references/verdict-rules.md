# Verdict Rules (Step 7 detail)

This reference holds the full **Changes Requested** trigger list, how the stale-base
check resolves, the reviewer-applied gate, and the machine-footer spec that
[SKILL.md](../SKILL.md)'s Step 7 summarizes and posts. Step 7 itself keeps the
decomposition/approved decisions, the finding-routing table and a short trigger summary;
come here for the exact conditions, the gate every reviewer commit must pass, and the
footer format every verdict template's `<!-- review … -->` comment must carry.

## Full trigger list

**Changes Requested** if any of these is true:
- A blocker or major finding in a file the PR touched.
- Secret scanning hit.
- Any unit, integration, or lint check you ran fails, or the trusted manifest reports a
  failure: its **Results** report failures, or its **Exit code** carries a non-zero
  entry the field does not name as expected by design. That field copies the log's exit
  markers in **Command** order and names each non-zero one as expected or not, with its
  reason, so an entry such as `1 — grep with no matches, which is the result the
  Coverage field states` is the manifest working as specified, not a failing suite.
  A bare non-zero, or one whose stated reason the raw log contradicts, is the trigger,
  which keeps the arbitration mechanical rather than a judgement about which exits are
  benign.
- Coverage regressed or is below 80% with no valid waiver, judged against a coverage
  signal you actually have (Step 5: a local run on Path 3, the manifest's **Coverage**
  field, or CI). Absence of any coverage signal where `docs/process/testing.md`
  documents no coverage command is **not** a trigger.
- Any issue requirement is unmet.
- Any suggested test step failed, or the section is missing.
- Required PR body sections (Summary, Risk, Rollback, Suggested Test Steps, Verified expectation) are missing or unsubstantive.

The stale-base check [SKILL.md](../SKILL.md)'s Step 2 runs is deliberately not on that
list. It resolves under the next section instead, because its remedy is a rebase, which
`agent-rules.md`'s `git` block reserves to authoring roles.

## Stale base vs. a base that moved

The check asks where the branch was cut from, not how far `origin/main` has travelled
since. What it exists to catch is a branch cut from an outdated main whose merge would
resurrect or delete content the PR never meant to touch. Take its inputs at verdict
time rather than classifying the snapshot Step 2 recorded at checkout: re-run the
command below and re-fetch `mergeable,mergeStateStatus` at the moment you classify,
because siblings merging mid-review move both. It is met — the branch **needs a rebase
before it can land** — when either of these holds. Only the first is a stale branch
point in the literal sense; the second admits a branch cut from current `main` that
conflicts anyway (two PRs adding rows to the same table, say), and it is listed here
because the remedy is the same additive rebase and the same hand-back, not because the
branch point is old. The `stale-base` slug names the remedy path, not a claim about
where the branch was cut.

- The PR deletes a file `origin/main` has changed since the branch point. That is the
  outdated-branch-point hazard in its concrete form: merging discards content the PR
  never meant to touch, or stops on a delete/modify conflict. One command, run in the
  review worktree:

  ```bash
  comm -12 <(git diff origin/main...HEAD --diff-filter=D --name-only | sort) \
           <(git diff "$(git merge-base origin/main HEAD)"..origin/main --name-only | sort)
  ```

  The left side is what this branch deletes, the right side what `main` moved on since
  the merge base. Non-empty output is the trigger; empty is not.
- The merge is a real conflict: `gh pr view <N> --json mergeable,mergeStateStatus`
  reports `CONFLICTING`/`DIRTY`, or `git merge --no-commit --no-ff origin/main` in a
  throwaway worktree stops on a conflict.

A branch that is merely behind is **not** stale-based. Sibling PRs merging while you
review make `git merge-base --is-ancestor origin/main HEAD` false and fill the two-dot
deletion list with files main *gained*, none of them the PR's — a signal about the
base's motion, not the branch's shape, and one that fires on nearly every PR reviewed
during concurrent merges. Three pieces of evidence discharge it, so the deviation is
mechanical rather than a judgement call: the condition-1 command above is empty, the PR
is `MERGEABLE`/`CLEAN`, and Step 3's merged-tree probe merges cleanly with a delta equal
to the PR's own diff and the suites green on that merged tree. That probe is
listed in Step 3 as conditional ("when the PR is adjacent to a shared schema or
contract"); on this path it is **mandatory**, because it is the evidence discharging the
trigger and there is nothing else to discharge it with. Record those three in the
verdict's Notes and reach whatever verdict the rest of the review earns.

The raw two-dot list `git diff origin/main..HEAD --diff-filter=D` is not condition 1:
it names every path in `origin/main` absent from `HEAD`, so it holds the PR's own
deletions by construction and never clears on a PR that legitimately deletes a file.

When the branch is stale-based and nothing else is wrong, the verdict is **Approved**
with the [hand-back variant](templates/approved.md#hand-back-variant), not Changes
Requested. A fix round would spend one of three review rounds on
an agent that changes no code, and the workflow already owns this event: the
orchestrator dispatches `workflow-rebase` to rebase additively and push, then
`workflow-merge-verifier` to confirm the resulting delta is exactly the rebase. Changes
Requested remains the verdict when one of the triggers above is true alongside it: the
hand-back covers the stale base, not the finding.

## Reviewer-applied gate

A reviewer may commit a **note-severity** finding's fix on the branch under review
(SKILL.md Step 7, *Reviewer-applied fixes*). The reviewer then approves a branch it
edited, with no second party, so the only acceptable control is one a script can check
and that admits no change to anything that runs. Every reviewer-applied commit must
satisfy all five conditions; a round in which any reviewer commit exists ends in the
[hand-back variant](templates/approved.md#hand-back-variant) with the
`reviewer-applied` slug, never in a merge by the reviewer, and the merge-verifier runs
this gate before landing the PR.

1. **Tagged, one finding per commit.** The commit message carries the trailer
   `Reviewer-applied: PR #<P> round <R> finding <F>` and touches exactly the hunks that
   close finding `<F>`. A commit without the trailer, or one closing two findings, fails.
2. **Files within the PR's diff.** Every path the commit touches appears in
   `git diff --name-only <base>...<approval-head>` — the PR's own three-dot diff against
   its base as it stood before the reviewer's commits (the relayed head, when the round
   relayed). A path outside that set fails,
   however small the change.
3. **No semantic change to an executable file.** For every touched path that is not
   exempt (below), the file's contents at the commit's parent and at the commit are
   byte-identical after stripping: whole-line comments, trailing comments, and all
   whitespace. The strip is per the file's own comment syntax (`#` for shell, Python,
   YAML and the like; `//` and `/* … */` for C-family languages; `--` for SQL; `<!-- … -->`
   for XML and HTML). A renamed test case, a changed string literal, a reordered
   argument, a changed number — each survives the strip and fails the gate. **Exempt
   from this condition, and governed by the other four only:** Markdown (`.md`,
   `.markdown`), reStructuredText, AsciiDoc, and plain `.txt` — **except instruction
   text**: any such file under `.claude/agents/` or `.claude/skills/`, or under a path
   the repo's `docs/process/testing.md` names as agent instructions, is executable for
   this purpose, because an agent reads it and acts on it (the same premise
   `orchestration.md` § Merge-verification round states for its doc-only allowance). For
   those files the strip is the `<!-- … -->` comment syntax and whitespace, so only a
   comment or whitespace edit passes. Nothing else is exempt; a data or configuration
   file (`.json`, `.yaml`, `.toml`, `.ini`, `.env`, lockfiles) is executable for this
   purpose because something reads it.
4. **At most ten changed lines per round.** Summed over every reviewer-applied commit in
   the round, `git diff --numstat` additions plus deletions. Eleven fails.
5. **The suite is green on the reviewer's head.** CI where the repo has it; otherwise
   the suite commands `docs/process/testing.md` names, run by the reviewer on its own
   head and recorded in `### Reviewer-applied`. Where that document declares, verbatim,
   "no suites — review-only", the condition passes on the quoted declaration plus the
   PR's own Suggested Test Steps re-run on the reviewer's head — never vacuously.

**What fails the gate, by name.** A test-case rename. A changed log message or error
string. A reordered import. A whitespace change inside a string literal. A comment
edit in a file the PR did not touch. A fix that would fail condition 3 changes
something that runs, so its finding was never a `note`: re-classify it `minor` and
route it by Step 7's table (relay in the diff, file otherwise). A fix that would fail
condition 2 or 4 keeps its severity and is routed **file**. Neither is ever applied.

**Handling a failed gate.** This is the single statement of the FAIL path; every other
file points here. The merge-verifier reverts each reviewer-applied commit that fails —
`git revert --no-edit`, newest first, pushed to the PR head — which returns the branch
to the content the round approved, and then squash-merges that head exactly as on PASS.
A condition 1, 2 or 3 failure names its commit; a condition 4 or 5 failure belongs to the
round, and every reviewer-applied commit in the round is reverted.
It reports which condition failed on which commit. The orchestrator files each reverted
finding as a deferred issue (a `note` never justifies a fix round), with the verifier's
report as provenance. A reviewer therefore applies only what it is sure passes; anything
in doubt is relayed or filed.

**Until `check-reviewer-commits.sh` lands**, the reviewer and the merge-verifier run the
strip comparison by hand. For a shell-style file:

```sh
strip() { sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1" | tr -d '[:space:]'; }
diff <(git show <parent>:<path> | strip /dev/stdin) <(git show <commit>:<path> | strip /dev/stdin) && echo IDENTICAL
```

The command and its output go in `### Reviewer-applied`, per touched executable file.
The script, when present, replaces the by-hand run and its output is what gets recorded.

## The machine footer

Every verdict template in [Verdict Templates](../SKILL.md#verdict-templates) ends with a
`<!-- review {"v":1,"round":N,"verdict":"…","findings":[…]} -->` footer — you fill it in
yourself, the same round you post the comment. Additive: the visible heading and tables
above it stay authoritative for a human reader; `preflight.sh` and other consumers read
the footer first and fall back to the `## PR Review — <Verdict>` heading regex only when
a footer is absent, so nothing that reads only the heading breaks. `verdict` is the same
slug `preflight.sh` derives from the heading (`approved`, `changes_requested`,
`decomposition_requested`, `escalated`); use exactly that word so the two paths agree.
Each `findings[]` entry carries `id`, `severity` (`blocker|major|minor|note`),
`confidence` (0–100), and `blocking` (bool) — write the confidence you settled on
**after** any Step 6.5 calibrator override, never the pre-override score, since the
footer is read as the record of what you actually decided. Severity and `blocking` are
independent axes: an entry that left the Findings table for the Notes list keeps the
severity you gave it, so `blocking:false` never rewrites a `blocker`, `major` or `minor`
into something milder. `note` is the fourth severity, defined once in SKILL.md Step 7.
A footer that disagrees with the tables or heading above it is a review defect, not a
harmless duplicate — fix the mismatch before you post, not after.

**Reading a footer whose `verdict` is off-vocabulary.** A footer that parses as JSON but
whose `verdict` value slugs to something outside the closed set above — `changes`
instead of `changes_requested`, say, PR #696's round-1 defect — is not repaired by
falling back to the heading: the precedence above (footer first, heading only when a
footer is absent) means a present, readable footer is authoritative even when it is
wrong, and guessing past a wrong value from the heading would hide a genuine posting
defect rather than surface it. A reader — `preflight.sh`, a reviewer, an orchestrator —
treats that comment as unrecognized, not as the heading's slug and not as absent: file
it as such, and treat the round count reported alongside it as a **lower bound**, not
the true total, because the round happened (a verdict comment was posted) and is simply
uncounted (issue #716, the same class as #658's uncounted `escalated` round — a routing
input computed once and trusted without checking whether the derivation's own input was
sound). The fix is to repost the comment with the correct slug, never to trust a
heading-derived guess to repair a wrong footer value.
