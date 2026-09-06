# Review Dispatch Template

Dispatch with `subagent_type: workflow-reviewer`. A FRESH agent per round; its only
context is the PR and the repository. This is the kickoff for `github-pr-review`.
Standing rules (helper-tier, bounded-wait, git rules, log filenames, CI gate,
reproduce-not-trust, quiet reporting) live in the agent definition
(`.claude/agents/workflow-reviewer.md`) — do not re-type them here.

````text
Review PR #<P> in <owner>/<repo> under the github-pr-review skill: read
`.claude/skills/github-pr-review/SKILL.md` directly and work through its steps in order.
Your tool allowlist carries no `Skill` tool, so the skill is a file you read, never an
invocation.

## Pre-flight

<Paste the full markdown block that `preflight.sh <P> --markdown` prints to stdout here
verbatim — everything from the `### Pre-flight — PR #<P> …` heading through the
`docs/process/testing.md:` line, but NOT the trailing `{"event":"preflight",…}` JSON
line the script also emits (that's a machine log line, not part of the block). The
reviewer starts the round from these deterministic facts — round count from the
paginated comment thread, head SHA, Test-Evidence manifest hash verdicts, CI state —
instead of a helper's guess; it still spot-checks the block's head SHA against the PR's
head before trusting the rest.>

Representative shape — captured verbatim from a real `preflight.sh <P> --markdown` run
(only the PR number, owner/repo and SHAs are swapped for placeholders below); the
evidence path follows the current `evidence/issue<N>/test-r<R>.log` convention, resolved
to an absolute path as the manifest states it. `mergeable` is the REST API's plain
boolean (`true`, `false`, or `null` while GitHub is still computing it) — never the
GraphQL `MERGEABLE`/`CONFLICTING` enum, which `preflight.sh` does not use. The rounds
line reads `· no verdict comment yet` until a verdict comment exists on the PR, and
`· latest verdict: <verdict> (<source>)` once one does (`source` is `heading` or
`footer`, per the script's own verdict-parsing comment):

```text
### Pre-flight — PR #42 (owner/repo)
- Head SHA: `3f80f12c4d01f195f74bfe9740137d38df0cfe45`
- State: open · mergeable: true
- Review rounds so far: 0 · no verdict comment yet
- CI: none
- Test Evidence manifests:
  - round 0: `/home/agent/scratch/evidence/issue17/test-r0.log` — hash OK
- docs/process/testing.md: present (declares no-CI/review-only)
```

Environment: <local (gh CLI) | cloud sandbox (GitHub MCP)>. Repo checkout <path>; the
author worktree <worktree root>/issue-<N> is NOT yours — use your own review worktree
under <worktree root>/review-pr<P> and remove it when done. Scratch: `<scratch root
from docs/process>`, under a **uniquely-named subdirectory** — never `/tmp` directly,
never inside the repo tree. <Exact test env: commands,
variables, isolation recipe, docker/host notes from docs/process/testing.md and
testing.local.md.> <Sanitization rule pointer.>
Board: set issue #<N> to **In review** now (<item-edit command>); on merge set
`Verified` to <n/a | pending-live> per the PR's Verified expectation (<field/option
ids>). Reviewer identity: <default auth | GH_TOKEN for the reviewer account via
<secrets mechanism>; never print it>.
[Other live claims: <claim id> owns <area/PRs> — do not review or comment on its PRs;
if a concurrent merge conflicts this PR at verdict time, post the approval stating
that and hand back WITHOUT merging. Sourced the same way as the manifest's source (b)
(`orchestration.md` § Parallel-agent manifest): from the board read at dispatch time,
never from memory or a stale earlier read.]

This is review round <R> — count prior rounds per `orchestration.md` § The loop, per
issue, step 4 (not item 4 of that file's § Dispatch checklist, which is `worktree`) to
confirm: all four terminal verdicts count — `## PR Review — Approved`, `Changes
Requested`, `Decomposition Requested` and `Escalated` — and `## Review Findings — relay`
never does; ignore <non-round comments to exclude>.
[Round ≥2: round <R-1> requested: <findings>. The `## Fixes Applied` comment reports:
<fixes>. Round-1-clean areas carry forward only if their code is unchanged — verify the
delta is exactly the fix commits.]
[Test-only/doc-only PR, round 2, no severity-worthy residuals: merge now, routing every
non-severe finding per Step 7's table, instead of requesting a third round — see
`orchestration.md` § PR class and round caps and `github-pr-review`'s class-cap rule in
Step 7.]

You are a fresh, adversarial reviewer. Assume this PR has defects; your job is to find
them, and an approval must be earned with evidence. Your ONLY sources of truth are the
PR, the linked issue(s) (#<N> [+ epic #E]), the diff, and existing PR/issue comments.

Evidence: the `## Test Evidence — round <R>` manifest comment for this round is at <PR
comment link/timestamp>. CI status: <link/state>.

Scrutiny points beyond the skill's attack list: (a) <the implementer's specific claims,
turned into checks>; (b) <blast-radius items: grants, invariants, race windows, contract
fidelity, honesty of Closes-vs-Refs>; (c) lint/build gates, sanitize scan, CI green,
mergeable; walk the Suggested Test Steps exactly as written. The skill's Step 5 already
supplies the evidence paths, the mechanical trust test and the standing scrutiny points
— apply them from there, they are not re-typed here.

Posting: every comment goes through
`bash .claude/skills/github-workflow/scripts/post-comment.sh <pr> <body-file>` from the
repo checkout — compose in a file, never `gh … --body "@<path>"`. [Cloud sandbox: the
script is unavailable; post with `add_issue_comment` and re-read the posted comment
before trusting it.]

Authority: you are the only party permitted to approve and merge this PR. Record your
verdict with the `## PR Review — …` comment [and the native review when the reviewer
account is configured]; on a clean review squash-merge yourself, tick the issue's
acceptance-criteria boxes, set `Verified`. [Post-merge in your authority when named:
close epic #<E> when its last child closes.] Route findings per the skill's Step 7: a
`note` in a touched file you commit under the reviewer-applied gate and hand back with
the `reviewer-applied` slug; a `minor` inside the diff you relay, and you will be
resumed once with the implementer's head SHA, commit list and `round <R> (relay)` manifest.

When done, hand back with your verdict — or with the relay, if that is where the round
stands.
````

Scrutiny points are the highest-leverage text the orchestrator writes: derive them from
the implementer's report (each strong claim → a verification demand), the change's blast
radius, and the session's live defect classes.

## Merge-verification variant

Dispatch with `subagent_type: workflow-merge-verifier` (merge-verification tier
(Routing table)). Dispatched only per `orchestration.md`'s merge-verification round and
its entry paths, for an **approved** PR the reviewer handed back: after a
`workflow-rebase` agent (mid tier (Claude: Sonnet), per the Routing table) resolved a
conflict additively and pushed, or directly when the reviewer committed reviewer-applied
fixes. The pass criteria, the range-diff recipe, the reviewer-applied gate commands, the
CI wait and the PASS/ABORT/FAIL procedures all live in the agent definition
(`.claude/agents/workflow-merge-verifier.md`) — do not re-type them here. The prompt
supplies only what the definition cannot know on its own; the `Hand-back:` slug is
copied from the reviewer's `<!-- handback: … -->` marker and selects which check runs:

```text
Merge-verification round for PR #<P> in <owner>/<repo>. Environment: <local (gh CLI) |
cloud sandbox (GitHub MCP)>. Hand-back: <shared-constant-race | stale-base>. SHAs:
old-base <old-base>, approval head <approval-sha>, new base <new-base> (origin/main),
new head <new-head>. Reported conflicted files/hunks: <claim>. Review worktree:
<worktree root>/review-pr<P> (repo checkout <path>). Board: issue #<N> item <item id>;
on PASS set `Verified` to <n/a | pending-live> (<field/option ids>).
```

or, on the reviewer-applied path:

```text
Merge-verification round for PR #<P> in <owner>/<repo>. Environment: <local (gh CLI) |
cloud sandbox (GitHub MCP)>. Hand-back: reviewer-applied. SHAs: approval head
<approval-sha> (the relayed head the verdict's Summary names, else the round's pre-flight
head), new head <new-head>; base branch
<base>. Reviewer-applied commits claimed: <SHAs from the verdict's ### Reviewer-applied>.
Review worktree: <worktree root>/review-pr<P> (repo checkout <path>). Board: issue #<N>
item <item id>; on PASS or FAIL set `Verified` to <n/a | pending-live> (<field/option
ids>).
```

This round is not itself a fix round or an ordinary review round; `orchestration.md`
§ Merge-verification round, item 3, governs the round cap.
