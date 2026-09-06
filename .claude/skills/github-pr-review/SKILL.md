---
name: github-pr-review
description: Independent, contextless review of a pull request created via the github-workflow skill, in both the cloud sandbox (GitHub MCP tools) and locally (gh CLI). Use when reviewing a PR — verify the linked issue is solved, resolve testing on the evidence paths, walk the suggested test steps, then request changes or squash-merge. You are the only party that lands the PR; the authoring conversation never merges its own work.
argument-hint: pr-number
---

# GitHub PR Review

An independent review of a pull request created through the [github-workflow](../github-workflow/SKILL.md) skill. This skill is meant to be run by a **subagent that has no context of how the PR was built**. Each review round starts fresh.

## Your Role

- You are a fresh, **adversarial** reviewer. Assume the PR has defects and that your job is to find them; an approval is the exception and must be earned with evidence. The author's report is a set of claims, not facts. You did **not** write this PR and have no knowledge of the author's intent.
- The PR description, the linked issue, the diff, and the existing PR/issue comments are your **only** source of truth. Do not assume the author's choices were correct — verify them.
- A review that finds nothing must say what it probed and why nothing was found (the attack list in Step 3 makes that concrete). "Looks good" is not a verdict.
- You may spawn exactly one helper type — `workflow-calibrator`, for Step 6.5's confidence scoring — and never spawn a helper above your own tier (see `github-workflow`'s Routing table for tier names, e.g. `small (Claude: Haiku)`). Never delegate the review itself.
- **You are the only party that lands this PR.** The conversation that wrote the code does not approve or merge its own work — that separation is the rule that keeps everyone honest, and it holds because you and the author both follow it, not because of any tooling limitation. You record your verdict by posting the `## PR Review — …` comment and, on a clean review, performing the squash-merge yourself. The comment plus the merge are the approval of record; there is no separate formal "approve" step.
- **Never merge a PR that still has unresolved findings.** Merge only after a clean review.
- **You may close the smallest findings yourself, and only those.** On an otherwise-clean round Step 7 routes every finding: a `note` in a touched file you commit under the reviewer-applied gate; a `minor` inside the diff the orchestrator relays to the implementer within the round. A round in which you committed anything is landed by the merge-verifier, never by you.

## Environment: cloud sandbox vs. local

This skill runs in one of two environments and the operations below are written as actions, not raw commands:

- **Cloud sandbox** (default for this project's automated review — Claude Code on the web, CI): **no `gh` binary**; use the GitHub MCP tools (`mcp__github__*`) with explicit `owner`/`repo`.
- **Local**: the `gh` CLI.

Read the full mapping and its caveats once at the start: **[../github-workflow/references/github-tools.md](../github-workflow/references/github-tools.md)**. The reviewer role itself runs equally well from either environment — only the orchestrator is declared local-only, and the harness-specific dispatch/tooling detail (subagent pinning, model tiers, tool allowlists) lives in [../github-workflow/references/platform-claude.md](../github-workflow/references/platform-claude.md). The operations this review needs:

| Operation | Local — `gh` | Cloud — GitHub MCP |
| --------- | ------------ | ------------------ |
| Read PR (title/body/refs) | `gh pr view <N> --json …` | `pull_request_read` `get` |
| Read PR diff | `gh pr diff <N>` | `pull_request_read` `get_diff` |
| PR CI / checks | `gh pr checks <N>` | `pull_request_read` `get_check_runs` |
| Read CI logs | `gh run view <id> --log` | `get_job_logs` (`failed_only`) |
| Read issue + comments | `gh issue view <N> --comments` | `issue_read` `get` / `get_comments` |
| Search issues (dup scan) | `gh issue list --search` | `search_issues` / `list_issues` |
| Comment on the PR | `gh pr comment <N>` | `add_issue_comment` (PR number) |
| Label the PR / issue | `gh pr edit --add-label` | `issue_write` `update` on the number |
| Secret scan | _(local scanner, e.g. gitleaks)_ | `run_secret_scanning` |
| Squash-merge | `gh pr merge <N> --squash --body-file <file>` (see "If Approved") | `merge_pull_request` (`merge_method: squash`) |

## Time-Box

A single review round should not exceed ~10 minutes of wall-clock work. If you are spending materially longer than that, the PR is too large — go to the size sanity check in Step 3 and request decomposition instead of dragging the review out.

## Step 0 — Pre-flight

Before spending your own context, resolve deterministic pre-flight facts — head SHA,
review-round count, latest verdict, CI state, and Test-Evidence manifest hash
verdicts — so the round starts from facts instead of a guess. Take them one of three
ways, depending on what the dispatch carries:

**(a) The dispatch prompt carries a `## Pre-flight` block** (the orchestrator ran
`preflight.sh <P> --markdown` and pasted it in). Read it in place of gathering the
facts yourself, then do one spot-check: the block's Head SHA must equal the PR's head
SHA right now (`gh pr view <N> --json headRefOid`, or `pull_request_read` `get` in the
cloud). A mismatch means the block describes an earlier push — **abort this round and
report a re-dispatch request to the orchestrator**, stating why (the block's head SHA
does not match the PR's current head).

**(b) The block is absent and you are local.** Run the script yourself:
`.claude/skills/github-workflow/scripts/preflight.sh <P> --markdown` (from the repo
root, or pass `--repo owner/name`). Read its output the same way as (a); no spot-check
is needed since you just generated it.

**(c) The block is absent and you are in the cloud sandbox.** `preflight.sh` shells
out to `gh` and there is no `gh` binary here, so do the minimal manual check via
paginated MCP reads instead — see [github-tools.md's Scripts
section](../github-workflow/references/github-tools.md#scripts) for the by-hand
equivalent (paginated `get_comments` for the round count and latest verdict, `get` for
state/draft/head SHA, `get_check_runs` for CI).

In every branch: `gh pr view --json comments` is never used for any of this — it
silently truncates a long comment thread and would undercount review rounds or miss
the latest verdict. The paginated comments API (`gh api --paginate
repos/<o>/<r>/issues/<pr>/comments?per_page=100`) or the paginated MCP call is the only
authoritative thread read; `preflight.sh` itself follows this rule.

With the facts in hand: if the PR is closed, a draft, already carries an unanswered
`## PR Review — …` comment, or is at the round cap, stop and report that instead of
reviewing. Then list `docs/process/*.md` and `*.local.md` yourself — neither pre-flight
path returns them — you read those next.

## Step 1 — Gather Context

Read everything before forming an opinion:

- Read the PR's title, body, and head/base refs (`pull_request_read` `get`, or `gh pr view <N> --json title,body,headRefName,baseRefName` — **never** append `comments` to that flag; see Step 0's pagination rule). Read **all** its comments through the paginated read that rule names (`get_comments`, or `gh api --paginate repos/<o>/<r>/issues/<pr>/comments?per_page=100`). Prior review rounds and the author's "Fixes Applied" responses are the context this review builds on.
- Extract the linked issue from the PR body (`Closes #X`) and read it in full, including every comment (`issue_read`, or `gh issue view X --comments`). **If the issue links a parent epic (`Part of #<epic>`), read the epic too** — its Goal and Design tell you what the larger work is for, which is how you judge whether this slice actually fits.
- **Determine the review round.** Reuse the count from Step 0's pre-flight facts rather than re-reading the thread — it already came from the paginated comments read above. If Step 0 branch (c) left the count unresolved, count existing `## PR Review — Changes Requested` and `## PR Review — Decomposition Requested` comments from the same paginated read used above. This review is round `count + 1`. A round counts only when one of those comments was posted — pushes to the branch without a review comment do not increment the round.
- If the count already equals the PR class's round cap (`orchestration.md` § PR class and round caps: 3 for executable-code, 2 for test-only/doc-only), do not start another — go straight to **Escalation** below.

## Step 2 — Check Out the PR and Claim the Column

Set the linked issue's board Status to **In review** now — you own that column; the dispatch tells you the field and option ids. Then work in a dedicated worktree under the repo's documented worktree root (`docs/process/worktrees.md`; never `/tmp` if the repo says containers cannot see it) so the author's worktree is never disturbed:

```bash
git fetch origin
git worktree add <worktree root>/review-pr<N> origin/<headRefName>
cd <worktree root>/review-pr<N>
```

Take the stale-base inputs before anything else: two-dot `git diff origin/main..HEAD --diff-filter=D --stat` and `git merge-base --is-ancestor origin/main HEAD`. Neither is a pass/fail on its own — a non-empty list and a false ancestor are equally what a base that merely advanced under a fine PR produces, so record the output and read [references/verdict-rules.md](references/verdict-rules.md#stale-base-vs-a-base-that-moved) at verdict time for which case you are in and how each resolves. Classify verdict-time inputs, not this snapshot: at verdict time re-fetch the PR's `mergeable,mergeStateStatus` and re-run that reference's own deletion command, because siblings merging mid-review change both. Never rebase the branch yourself and never merge main into it. Remove the worktree when the review is done.

## Step 2.5 — Check CI Status First

Before running anything locally, check the PR's CI status (`pull_request_read` `get_check_runs`, or `gh pr checks <N>`):

- If CI is **failing**, read the failure logs first (`get_job_logs` with `failed_only: true`, or `gh run view <run-id> --log`). A real, reproducible CI failure is itself a blocker finding — don't waste time running locally before recording it.
- If CI is **green**, still run the suggested test steps locally — CI may not cover everything (especially network-gated or platform-specific paths).
- If CI is **missing** for a change that should have it (the project has a CI workflow and this PR did not trigger it), that itself is a finding.

## Step 3 — Review the Diff: the attack list

Read every changed file (`pull_request_read` `get_diff`, or `gh pr diff <N>`). Then work the attack list. Every probe gets exactly one outcome word in the verdict's attack-list table — **found (<what>)**, **found nothing**, **not applicable (why)**, or **not probed (why)** — and no probe carries a report rule of its own, so a silent bullet is not a bullet without a report obligation. The list is what makes "found nothing" mean something:

1. **Spec fidelity** — every acceptance criterion, and nothing beyond the issue (scope creep is a finding).
2. **Correctness on the changed lines** — logic, null/empty, boundaries, off-by-one.
3. **Silent failures** — catch blocks that swallow, fallbacks that hide, log-and-continue, broad exception types, defaults on error.
4. **Tests cover behaviour** — negative cases, error paths; would a regression of this change be caught, or do the tests mirror the implementation?
5. **Concurrency / ordering** — races, retries, idempotency, partial failure, boot-order assumptions.
6. **Security surface** — injection, secrets in argv/logs/env, permissions and grants, trust of inputs, anything the repo's sanitization rule forbids.
7. **Drift guards** — closed sets copied from old sources, migrations/ledgers, convention tests that should enumerate reality and do not.
8. **History** — `git blame` on the touched code, and comments on prior PRs that touched the same files (prior findings recur).
9. **Comments and docs match the code** — stale comments are findings when the PR touched the line.
10. **Standards and smells** — the repo's documented standards first (a documented standard overrides any baseline); then the usual smells (duplication, mysterious names, feature envy, speculative generality) as *labelled heuristics*, never hard violations.
11. **Guard-test mutation check** — for any test whose name claims guard, constraint, or lockstep behaviour, break the guarded condition and confirm the test fails, because a guard test that cannot fail proves nothing. If breaking the condition means mutating a tracked file mid-review, restore it with the splice-restore recipe in `github-workflow/references/agent-rules.md`'s `rule:git` block — never a bare git restore.
12. **Unreadable-directory probe** — against any code that walks a filesystem, inject an unreadable, permission-denied entry and confirm the walk surfaces the failure instead of treating it as empty or absent, because a swallowed permission error hides real filesystem damage as silent success. Undo the injected entry with the same splice-restore recipe in `github-workflow/references/agent-rules.md`'s `rule:git` block, not an ad hoc cleanup.
13. **Merged-tree test** — when the PR is adjacent to a shared schema or contract, merge it into a throwaway worktree (`git merge --no-commit`) and run the tests there instead of on the branch, because a PR can be MERGEABLE and CLEAN on its own branch and still break the moment it lands beside a sibling's concurrent contract change.
14. **Literal-text verification** — for every defect-fix or citation claim, open the cited document and compare its literal text against the claim, hunting for inversion, because a claim that reads the opposite of its source passes a skim and fails the first person who checks it. Your own claims about another PR or issue carry a permalink, per [`pr-body.md`](../github-workflow/references/templates/pr-body.md) § **Claims about another PR or issue**.

Separate what you find into **Spec** findings (the PR does not do what was asked, or does more) and **Standards** findings (how it is written), and report them under those headings — one axis must not mask the other.

### Size Sanity

If the diff is **> ~400 net LOC changed** or **touches > 15 files**, do not perform a full review. Post the `## PR Review — Decomposition Requested` template and stop. The author should split the work into smaller issues/PRs (and, if they haven't, open an epic to track them — see the github-workflow skill).

Exceptions where size is acceptable: pure renames, generated-file regenerations, lockfile updates, mechanical formatting passes. The diff in those cases is mechanically simple and review value lies in spot-checking, not line-by-line review.

### Style Guide Check

If the repository contains a `style-guide/` directory at the repo root, treat every `*.md` file inside as authoritative for the language(s) it covers. For each style-guide file relevant to the PR's diff (e.g., `powershell-style-guide.md` applies when the PR touches `*.ps1` / `*.psm1`; `python-style-guide.md` applies to `*.py`; etc. — match by language):

- **Read it before reviewing the diff.** Treat its rules as a first-class checklist.
- **Check every added or modified line** against each numbered rule. Pre-existing violations on lines the PR does NOT touch are out of scope; new violations the PR introduces are findings.
- **Severity follows the rule's intent.** A "must" / "always" / "do not" rule is generally a `major` finding; a "should" / "prefer" / "avoid" rule is generally `minor`. Use judgment — egregious violations of a "should" rule can be major; trivial drift on a "must" can be minor.
- **Cite the rule by section number** in the finding (e.g., "violates §3.1 — code at column 0 inside an `InModuleScope` block").

If `style-guide/` exists but no file matches the PR's language(s), that's not a finding — just note it in the summary.

### Secret Scanning

Scan the PR's changed content for secrets. In the cloud sandbox, pass the diff hunks / changed-file contents to the `run_secret_scanning` MCP tool (it scans content you provide, not a ref). Locally, run a secret scanner such as gitleaks over the diff. Any hit is a **blocker** finding. Beyond posting it in the review, the finding must require all three of:

1. **Remove the secret from the diff** (sanitize the file).
2. **Rewrite git history** to purge every commit that ever contained the secret — sanitizing the latest commit does NOT expunge the secret from history. Use `git filter-repo` (preferred) or interactive rebase, then force-push the rewritten branch (`git push --force-with-lease`). Every commit SHA on the branch will change; that's expected.
3. **Rotate the credential upstream** — revoke and regenerate the actual key/token at the issuing system. Once a secret has been pushed to a remote (even briefly), assume it is compromised. History rewriting hides it from future clones but does not unleak it.

The follow-up review round must verify all three were done. If a later round finds the secret still present in `git log -p` history on the head ref, that is itself a blocker and the round restarts.

## Step 4 — Verify Issue Resolution

Every requirement in the linked issue must be satisfied:

- **Enhancement issues:** each Acceptance Criteria checkbox is genuinely met — and **tick the box on the issue** when you prove it (native checkboxes are the coverage record; the table in your comment mirrors them).
- **Chore issues:** the check the issue's Verification section describes holds, and the diff changed only what the Summary names.
- **Bug issues:** the described failure no longer reproduces and the root cause is addressed.

Record each requirement as met or unmet — an unmet requirement is a blocker finding. A criterion that can only be proven on the real environment is **not unmet**: note it as `pending-live`, and confirm the PR's *Verified expectation* line says so. Acceptance criteria are supposed to be provable at merge; if an issue's criteria are largely unprovable, say so — that is a planning defect worth an issue.

An acceptance criterion can also be *wrong* rather than unmet: it contradicts the issue's own Summary or Proposed Changes section, its parent's Scope (or the milestone's Scope / Non-goals, for a milestone-direct issue), or the ratified design record it was drawn from. Report that as a planning defect for the orchestrator's [AC-amendment procedure](../github-workflow/references/orchestration.md#ac-amendment) — naming the AC and the exact conflicting text — not as a finding against the PR's code. This is a finding like any other, not a way to wave a failing PR through: every other criterion still has to be met, and the round's verdict still reflects whatever else was found.

## Step 5 — Evaluate Evidence, Then Test

The implementer (round 0), the fix agent (every later round) and the relayed
implementer (`## Test Evidence — round <R> (relay)`, Step 7 § Relay) post a
`## Test Evidence — round <R>` manifest comment carrying exactly these fields —
**Command**, **Env**, **Head SHA**, **Exit code**, **Results**, **Log SHA-256**,
**Raw log**, **Lint state**, and a **Coverage** field that is required, never optional
— and, in local environments, leave the untruncated log at the path the **Raw log**
field names, by convention `evidence/issue<N>/test-r<R>.log` under the agent's scratch
directory, recorded as the **resolved absolute path** (never the unexpanded `<scratch>`
placeholder). That set is the producer's set: read
[../github-workflow/references/templates/implementer.md](../github-workflow/references/templates/implementer.md)
for what each field must contain, and judge the manifest against it rather than against
a second definition kept here. **Lint state** is where the lint-state phrase belongs
whenever `docs/process/testing.md` asks for one — including in a repo that declares no
suites, where it is a different sentence from the no-suites declaration **Env** quotes;
a manifest carrying the phrase in **Env** instead has stated the substance in the wrong
field. For a PR that closes more than one issue, `<N>` is whichever one the manifest
itself states it keyed off — its **primary issue** — falling back to the first
`Closes #<N>` line in the PR body when the manifest is silent.

Testing resolves on exactly one of three paths, evaluated in order. Take the first that
applies and do not fall through to a later one for any other reason:

1. **Skip entirely** — no local run, evidence not even needed.
2. **Trust the evidence** — the manifest passes the mechanical trust test; evaluate it
   without re-running.
3. **Run tests yourself** — the fallback, scoped to the diff.

Take Path 1 only when CI is green on the exact head SHA, the diff touches only
surfaces in the repo's documented CI-coverage map, and no Step 3 finding needs a local
run to arbitrate — otherwise check Path 2's mechanical trust test (Head SHA, Command,
and Raw log/hash/content checks against the manifest); a manifest that passes all of it
is trusted as given, and anything else (no manifest, a mismatch, staleness, or a
Step-3 finding the evidence cannot arbitrate) falls to Path 3, running only the tests
relevant to the diff yourself. The full mechanics of each path, the coverage rule that
applies on Paths 1 and 2, and the standing scrutiny points and coverage-waiver rule that
apply regardless of path are in
[references/evidence-paths.md](references/evidence-paths.md#contents), whose Contents
names the section for each.

## Step 6 — Walk the Suggested Test Steps

The PR body contains a **Suggested Test Steps** section specific to these changes. Execute each step exactly as written and compare against its expected result. Record every step as pass or fail. A failed step is a blocker finding.

If the PR has no Suggested Test Steps section, that itself is a finding — the author must add one.

## Step 6.5 — Calibrate the findings (mid tier)

Dispatch a fresh `subagent_type: workflow-calibrator` (mid tier (Claude: Sonnet), see
`github-workflow`'s Routing table) rather than scoring findings yourself or pasting the
rubric into a helper below your own tier: a small-tier scorer anchors on a handful of
round numbers instead of discriminating between findings, and this score is checked
against the 80-point confidence gate below, so an anchored scorer defeats the gate it
exists to operate. Hand it the full findings list, the diff, the repo's standards
files, and the rubric below verbatim — never your verdict draft, severity assignments,
or Required Before Merge list: a scorer that knows the intended verdict stops
discriminating and starts agreeing.

`workflow-calibrator.md` carries a verbatim copy of the marked block below. Change one
side and re-copy into the other in the same commit:
`github-workflow/tests/test_agent_rules_drift.sh` diffs them and fails on any
difference, in either direction.

<!-- rubric:step-6.5 -->
Score each finding 0–100 for confidence that it is real and matters:

- 0: false positive on light scrutiny, or pre-existing on lines the PR did not touch.
- 25: might be real, could not be verified; stylistic and not in a documented standard.
- 50: verified real but a nitpick or rare in practice; not important relative to the PR.
- 75: double-checked, very likely hit in practice, materially affects functionality, or an explicit documented-standard violation.
- 100: confirmed, frequent, evidence directly shows it.

Findings scoring **below 80 leave the Findings table** and go to a *Notes (not required)* section. Severity (blocker/major/minor/note) is yours; the score is the gate on whether it blocks. This is what keeps a four-finding review from being one real finding and three restatements of taste.

Cite every finding with a **full-SHA permalink** (`https://github.com/<o>/<r>/blob/<40-char sha>/<path>#L<a>-L<b>`, one line of context each side) so it is clickable on GitHub.
<!-- /rubric -->

Expect exactly one JSON array back and nothing else: `[{"id": "<finding id>", "confidence": <integer 0-100>, "rationale": "<what was checked>"}]`, one object per finding, in the order given. The calibrator's claims are helper output, not fact, under the mirrored `helper-tier` rule — re-verify every score before it counts, override any score your own check contradicts, and record the override (what it returned, what you set instead, and why) in the verdict.

## Step 6.6 — Enumerate Helpers (handoff)

Every hand-back to the parent — Approved, Changes Requested, Decomposition Requested, or
Escalation — closes with a **helper enumeration**: one line per helper spawned this
round (Step 6.5 calibration, or any other), giving **count · model · purpose · tokens
(where visible)**. Never spawn a helper above your own tier — `workflow-calibrator` is
the only permitted helper type — and give the model as a tier with the Claude example
inline, e.g. `mid (Claude: Sonnet)` or `small (Claude: Haiku)`. Take tokens from the
helper's task notification; if the harness does not surface them, record explicit `null`
rather than estimate it. If no helpers ran this round, say `Helpers: none`.

The enumeration goes in the posted verdict comment — each of the four templates in
[Verdict Templates](#verdict-templates) below carries a `**Helpers**:` line for it. Your
return message to the parent may repeat it but the comment is the record of truth.

```
Helpers: 1 — mid (Claude: Sonnet) × calibrate-findings (1,204 tok)
```

These are the same field names (`model`, `purpose`, `tokens`) as the `helpers` array on
the reviewer `report` event in [session-log.md](../github-workflow/references/formats/session-log.md)
and the reviewer role's `helpers` key in
[issue-metrics.md](../github-workflow/references/templates/issue-metrics.md).

## Step 7 — Verdict

**Decomposition Requested** if size sanity triggered in Step 3.

**Changes Requested** if any of these is true: a blocker or major finding in a file the
PR touched; a secret scanning hit; a unit, integration, or lint check (or the trusted
manifest) fails; coverage regressed or is below 80% with no valid waiver; any issue
requirement is unmet; any suggested test step failed or the section is missing; a
required PR body section is missing or unsubstantive. This is a summary — the full,
exact trigger list (with the coverage-signal caveat, the non-triggering absence case,
and the stale-base check's own separate resolution) is in
[references/verdict-rules.md](references/verdict-rules.md#full-trigger-list) and is what
you decide against, not this paragraph.

Otherwise: **Approved**.

### Route every finding

Routing runs only on a round no trigger above has already sent to Changes Requested or
Decomposition Requested: on those rounds every finding, whatever its severity, goes into
the Findings tables and the fix agent takes them all. On a round that is otherwise
Approved, route each finding — Findings tables and Notes list alike — by its severity
crossed with its location. The table is exhaustive and every cell has exactly one
outcome:

| Severity | In the diff | In a file the PR touched, outside the diff | In a file the PR did not touch |
| -------- | ----------- | ------------------------------------------ | ------------------------------ |
| `note` | reviewer-applied | reviewer-applied | file |
| `minor` | relay | file | file |
| `major` / `blocker` | changes-requested | changes-requested | file |

`note` is the one severity below `minor`: a finding whose fix changes nothing that runs
— a comment, a docstring, whitespace, wording in a Markdown file — which is why it is
the only severity a reviewer may close by committing. `minor` and above are defects in
behaviour or against a documented standard and belong to an author. Step 6.5's rubric
names the four severities; the calibrator scores confidence, never severity.

- **reviewer-applied** — you fix it yourself, under the gate below.
- **relay** — you post the findings and stop without a verdict; the orchestrator relays
  them to the resumed implementer and resumes you with the new head, in this same round.
  A `minor` Step 6.5 scored below 80 is **file**, not relay: only a confident finding
  earns the implementer's resume.
- **changes-requested** — the trigger list above has already taken this round; the row
  is here so the table is exhaustive.
- **file** — a deferred issue, per Step 8.

Order within the round: relay first, apply second, and apply only once the relayed head
has re-verified clean — a relayed head that leaves a relayed finding unresolved ends the
round in Changes Requested with no reviewer commits on the branch. A relay returns a new
head before you commit anything, so the implementer never pushes over your commits, and
your reviewer-applied commits are the last change to the branch before the verdict.
Before posting the relay comment, dry-run gate conditions 1–4 on every fix you intend to
apply, and route each fix that would fail per verdict-rules § Reviewer-applied gate,
*What fails the gate*: a condition 3 failure means the finding is a `minor`, not a
`note`, and it joins the relay comment when it is in the diff; a condition 2 or 4
failure is **file**. A gate failure you discover only after the relay is **file** —
there is no second relay. A gate failure never becomes a Changes Requested.
A `major` or `blocker` in an untouched file is still **file**: it is not this PR's
defect, and the issue it becomes carries the severity. A PR that is non-CLEAN at verdict
time (a shared-constant race, or verdict-rules § Stale base) may still relay, but gets no
reviewer-applied commits at all: route its `note` findings **file** and post the
hand-back the conflict calls for, so the merge-verifier never verifies a rebase and
reviewer commits in one round.

### Reviewer-applied fixes

For every finding routed **reviewer-applied**, commit the fix on the PR's branch
yourself — one commit per finding, in your review worktree, with the trailer

```
Reviewer-applied: PR #<P> round <R> finding <F>
```

where `<F>` is the finding's id in your tables. Every such commit must pass the
**reviewer-applied gate** in
[references/verdict-rules.md](references/verdict-rules.md#reviewer-applied-gate). Run
gate conditions 1–4 yourself before pushing, confirm condition 5 on the pushed head
before posting the verdict, and record each under `### Reviewer-applied` in the verdict,
with the commit SHA, the finding id and the diff quoted verbatim. The suite run for condition 5 is the evidence for your commits — no
`## Test Evidence` manifest is posted for them, and the round's manifest stays keyed to
the head it names. A relayed round leaves two round-`<R>` manifests on the thread and in
the pre-flight block — the author's and the `(relay)` one; the one whose **Head SHA** is
the relayed head is the one Step 5's trust test runs against. Your review worktree is
detached, so push with
`git push origin HEAD:refs/heads/<headRefName>`, never `--force`.

A round in which you committed anything **cannot end in an ordinary merge**. Post the
verdict with the [hand-back variant](references/templates/approved.md#hand-back-variant)
and the `reviewer-applied` slug, then stop: the orchestrator dispatches the
merge-verifier, which runs the gate over your commits and lands the PR. A commit that
fails the gate there is reverted and the PR still merges (verdict-rules § Reviewer-applied
gate, *Handling a failed gate*, which also says what to do with a fix you are not sure
passes).

### Relay

For findings routed **relay**, post a comment headed `## Review Findings — relay`
carrying the Findings tables for those items and nothing else — no verdict, no footer.
Then end your turn with a report that names the relay. The orchestrator resumes the
implementer with those findings and, when it reports the new head, resumes you with the
head SHA, the commit list and the `## Test Evidence — round <R> (relay)` manifest the
implementer posted for that head. On resume, re-verify **only** the relayed findings against those commits —
the rest of your review stands — run Step 5's trust test against the new manifest, and
leave the board at **In review** throughout: the relay is part of your round, so the
resumed implementer makes no column move —
post the verdict for the round as usual, naming the relayed head in its Summary. The
round number does not change. One relay per round: if the relayed head does not resolve
every relayed finding, or introduces a new one, the verdict is Changes Requested.

### The machine footer

Every verdict template in [Verdict Templates](#verdict-templates) ends with a
`<!-- review {"v":1,"round":N,"verdict":"…","findings":[…]} -->` footer that you fill in
yourself the same round you post the comment. The exact footer format — field
meanings, the `preflight.sh` fallback when a footer is absent, and the
calibrator-override rule for `confidence` — is in
[references/verdict-rules.md](references/verdict-rules.md#the-machine-footer).

### Class cap: test-only / doc-only PRs

Test-only and doc-only PRs (mechanical from diff paths, and conservative — a path
classes test-only only under a test root or by a pattern the repo's
`docs/process/testing.md` documents, so a repo documenting no test conventions has no
test-only PRs; anything uncertain falls through to executable-code and keeps three
rounds — see [orchestration.md](../github-workflow/references/orchestration.md#pr-class-and-round-caps))
get one fix cycle, not three. On such a PR's **round 2**, if the findings that remain
are not severity-worthy (no blocker or major finding — severity is your own judgment;
Step 6.5's score is only the gate on whether a finding is confident enough to count at
all), **merge anyway** — do not post a third Changes Requested. Route every non-severe
residual per Step 7's table exactly as on an approved round — a relay or a
reviewer-applied commit spends no round, so the cap is untouched — note the cap in your
verdict comment, then proceed to **If Approved**. Only a
blocker or major finding still justifies Changes Requested on a test-only/doc-only PR's
round 2; a genuine severity-worthy defect is never merged around.

The class cap governs **findings only**. It never overrides **any** of the
unconditional Changes-Requested triggers — read the complete list in
[references/verdict-rules.md](references/verdict-rules.md#full-trigger-list), not the
summary Step 7 prints, and treat no subset as the whole. If any of those triggers is
true, the verdict is Changes Requested on a test-only/doc-only PR at any round, cap or
no cap.

## Step 8 — File Deferred Items for Non-Blocking Findings

Filed items land in the board's Triage column automatically; label them with the type, `deferred`, the matching `concern:*` (or `documentation`), and at least one `area:*` from the repo's closed set. Do not set priority or dependencies — sequencing is the orchestrator's at triage. The issue has no parent — never a sub-issue of the PR's epic, and never of the issue the PR closes: closed children count against the 100-sub-issue cap, and a night of review follow-ups once filled an epic on its own. Attach it to the milestone the PR's work belongs to when one exists, else file it straight to Triage — parentless in a milestone keeps the ledger without spending the cap. Instead of a parent, its body carries provenance: a `Spawned by PR #<P> round <R>` line naming the PR under review and the review round that found it (the canonical form is in `maintenance.md` § 1, `provenance`).

Before posting the Approval, Changes Requested, or Decomposition Requested template, **file a deferred issue for every finding Step 7's routing table sent to `file`**. This is the [github-workflow](../github-workflow/SKILL.md) skill's Deferred Items Rule, applied to your review.

What qualifies:

- Any finding, of any severity, in a file the PR did not touch — style drift, a linter warning, a pre-existing bug, a code smell, an unused path.
- A `minor` finding in a touched file but outside the diff.
- A `minor` finding inside the diff that Step 6.5 scored below 80.
- A finding that failed the reviewer-applied gate and is not in the diff.
- Anything you described in your review as "noted, non-blocking", "out of scope", "pre-existing", "worth a follow-up", or similar.

If you wrote the phrase, you owe an issue — unless the finding was applied or relayed, in which case its commit closes it and it is listed under `### Reviewer-applied` or in the relay comment instead.

**Before filing, scan for duplicates — both open issues and closed `parked` ones.**
Don't open a second ticket for a problem that already has one, and don't let a parked
finding get silently re-filed either: parking only reduces noise if the next
contextless reviewer can find the parked record. Search by the finding's unit (the
value the `Unit:` line below carries) and by keywords, in both states:

- Open, as before: `search_issues` / `list_issues` filtered by the `deferred` label,
  or `gh issue list --state open --search "<keywords>"`.
- Closed and `parked`: `gh issue list --state all --label parked --search "<unit>"`
  (local); `search_issues` with `is:closed label:parked` (cloud sandbox).

**What comes back is candidates, not hits.** GitHub's search tokenizes a path: a
`--search "scripts/<x>.sh"` matches every issue whose body carries `scripts`, `<x>` or
`sh` as a token, so a path query over a `deferred` label routinely returns a majority of
issues that merely share a word with your finding. Quoting does not narrow it — a
`--search '"<x>.sh" in:body'` query returns a comparably large, not a smaller, result
set than the unquoted form. The query narrows the pile; it decides nothing.

**The match predicate — yours, and applied by reading, not by counting results.** A
candidate is a **hit** only when, on reading its body, it describes the **same defect**
in the **same unit** as your finding: its `Unit:` line (or, absent one, the unit you
would give it) resolves to the same unit as yours, *and* the problem it describes is the
one you just found rather than a different problem in the same file. Same file, different
defect — not a hit. Same defect, different file — not a hit. If the body does not let
you decide, it is **not** a hit: file your finding as a new issue. That asymmetry is
deliberate. A duplicate issue is cheap and triage folds it at `dedupe`; a wrong `Seen
again:` on an unrelated parked issue is not visible anywhere, and two of them reopen work
the owner parked on purpose — the one action owner decision 6 reserves for a genuine
recurrence signal. Nothing below this paragraph applies to a candidate you have not
judged a hit; a candidate that is not a hit is simply not mentioned anywhere.

**An open-issue hit:** add a comment on it referencing this PR as the rediscovery
context and link to it in your review template's Deferred Items section instead of
filing a new one.

**A parked hit:** never file a new issue for it. Post `Seen again: PR #<P> round <R>
— <one line>` on the parked issue instead, and list it in the Deferred Items section
as `seen again: #<n>`. Before posting, count the `Seen again:` comments already on the
issue:

- **Zero** existing — this is the first sighting. Post the comment. Leave the issue
  closed and `parked`.
- **Exactly one** existing — this is the second sighting. Post the comment, then
  **reopen the issue and remove the `parked` label** (leave `deferred` and every other
  label as-is) — the orchestrator re-adds it to the board. List it as `reopened: #<n>`
  instead of `seen again: #<n>`. **Exception:** if the issue carries a `Rejected:`
  comment, post the sighting comment only and do **not** reopen it — a rejected item
  stays parked and stays found by this dup-scan until the owner's milestone review
  revisits it; a reviewer never overrides that rejection by repetition. List it as
  `seen again: #<n>` in this case, since it was not reopened.
- **Two or more** existing on an issue found **parked** — under the triage `home`
  step's work-now condition (c) and its floor (`github-workflow`
  `references/maintenance.md` § 1 step 6), an item carrying two or more `Seen again:`
  comments stays work-now and is not re-parked, so this combination should only ever
  occur when a `Rejected:` comment overrides reactivation. Check for one first: if
  present, this is the ordinary rejected-item case — post the sighting comment, list it
  as `seen again: #<n>`, and do not reopen it, exactly as the rejection exception
  above. If no `Rejected:` comment is present, the item was re-parked in violation of
  the floor; post the sighting comment, list it as `seen again: #<n>`, reopen it anyway
  (the floor's guarantee licenses this, not the raw comment count), and note the
  violation in your review so triage can see where it went wrong.

Triage decides *whether* to park an item, not the reviewer (that decision, and the
park mechanics, are #799's territory) — the reviewer's only duties here are running
this dup-scan, posting the sighting comment, and (below) the `Unit:` line at filing.

**Filing.** Use the Bug or Enhancement template from the github-workflow skill ([../github-workflow/references/templates/](../github-workflow/references/templates/)), apply the `deferred` label plus the matching `concern:*` (or `documentation`), and put the `Spawned by PR #<P> round <R>` provenance line **and**, on the line immediately after it, the required `Unit:` line — one repo-relative file path, one repo-relative directory path ending in `/`, or one `area:*` label; its lexical form, how to choose the value and what a missing line means are in the github-workflow skill's Deferred Items rule — in the Home section, in place of a parent. Each filed (or referenced existing) issue goes in the review template's `### Deferred Items` section so the audit trail is on the PR.

"Noted, non-blocking" is not a parking place — it either blocks the merge or it has an issue number next to it before the review template is posted.

## Verdict Templates

Post one of these as a comment on the PR. Only load the one matching your verdict:

| Verdict | Template |
| ------- | -------- |
| Changes Requested | [references/templates/changes-requested.md](references/templates/changes-requested.md) |
| Decomposition Requested | [references/templates/decomposition-requested.md](references/templates/decomposition-requested.md) |
| Approved | [references/templates/approved.md](references/templates/approved.md) |
| Escalation (cap reached) | [references/templates/escalation.md](references/templates/escalation.md) |

## If Changes Requested

1. Post the **Changes Requested** template as a comment on the PR.
2. Do **not** merge. Hand control back to the parent agent — the parent owns fixing the findings.
3. Remove your review worktree.

The parent will fix the findings, post a `## Fixes Applied` comment, and spawn a new contextless review agent for the next round.

## If Decomposition Requested

1. Post the **Decomposition Requested** template.
2. Do **not** merge. The parent must split the work into smaller issues/PRs.
3. This counts as a round (Step 1's round count includes it).
4. Remove your review worktree.

## If Approved

Before merging, verify the PR's `closingIssuesReferences` matches every issue you
intend to close — `gh pr view <N> --json closingIssuesReferences` (cloud sandbox:
read the same field off the PR object). GitHub derives this only from closing keywords
in the PR **body**, not from commit messages, so a mismatch here means a `Closes` line
is missing or malformed. Fix the PR body before merging rather than closing the issue
by hand afterward.

Use the **hand-back variant** (`references/templates/approved.md` § Hand-back variant)
instead of merging when the PR is otherwise clean but non-CLEAN at verdict time — most
commonly a shared file whose constant counts its own entries and a sibling PR merged
first, or a genuinely stale base — and whenever this round carries a reviewer-applied
commit of yours (Step 7). Post the hand-back verdict, then stop: do not merge,
do not rebase, do not merge `main` into the branch, and do not set `Verified` on the
board — the merge-verifier owns that write on PASS. Resolving a conflict is authoring
(`agent-rules.md`'s `git` block) and needs its own verification, so the parent
dispatches `workflow-rebase` to resolve additively and push, then
`workflow-merge-verifier` to confirm the resulting delta is exactly the rebase before
merging. On the `reviewer-applied` slug there is no rebase: the parent dispatches the
merge-verifier directly, and its delta check is the reviewer-applied gate over your
commits.

Squash-merge the PR yourself — this is the approval of record.

- **Cloud sandbox:** `merge_pull_request` with `merge_method: "squash"`. There is no MCP tool to delete the head branch and `merge_pull_request` has no delete-branch option, so rely on the repo's "automatically delete head branches" setting or leave the branch for cleanup — do not block the merge on branch deletion.
- **Local:** run the merge from a **neutral cwd** outside the repo (not the review worktree, not the author's worktree) and pass `--repo` explicitly, because `gh pr merge --delete-branch` runs a post-merge local-checkout step that fails when the cwd is inside a worktree whose base branch is checked out elsewhere. A default squash writes its own commit message and can silently drop closing keywords that only lived in individual commits — for any multi-issue PR, write the PR body to a file and pass it explicitly with `--body-file` so every `Closes` line survives into the squash commit:
  ```bash
  cd /tmp
  gh pr view <N> --repo <owner>/<repo> --json body -q .body > /tmp/squash-body.md
  gh pr merge <N> --repo <owner>/<repo> --squash --body-file /tmp/squash-body.md --delete-branch
  ```
  Then verify the remote branch is actually gone (`--delete-branch` is best-effort):
  ```bash
  BRANCH=<headRefName>
  if gh api "repos/<owner>/<repo>/branches/$BRANCH" >/dev/null 2>&1; then
      gh api -X DELETE "repos/<owner>/<repo>/git/refs/heads/$BRANCH"
  fi
  ```
  A `404` from the first call means the branch is already gone — that's the success case.

In both environments:
- If the merge is blocked by conflicts, do not resolve them yourself — post the
  hand-back variant above and stop.
- If a required check is failing, investigate and fix the cause — never bypass it.

After merging: set the board's `Verified` field from the PR's *Verified expectation* line (`n/a` or `pending-live`; the dispatch gives the ids — Done is set by automation when the issue closes), post the **Approved** template as a comment, remove your review worktree, and hand back to the parent for cleanup (local worktree/branch removal).

**Native reviews.** When the dispatch gives you a reviewer identity (`GH_TOKEN` for a second account), also submit the native review — `gh pr review <N> --approve` / `--request-changes --body-file` — under that identity; the comment carries the detail and the native state carries the verdict, and branch rules can require it. With one account GitHub refuses reviews on the author's own PR, so the comment plus the merge remain the approval of record.

## Escalation (cycle cap reached)

If the round count already equals the PR class's cap and the PR is still not clean, do not loop further:

1. Post the **Escalation** template.
2. Apply the `help` label to both the issue and the PR (locally `gh issue edit X --add-label help` / `gh pr edit <N> --add-label help`; in the cloud, `issue_write` `update` with `labels` on each number).
3. Hand back to the parent — a human must take over.
