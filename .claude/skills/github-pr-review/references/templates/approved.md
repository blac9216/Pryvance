# Review Approved Template

Post as a comment on the PR after a clean review. Post it through `post-comment.sh` per
the dispatch prompt's Posting line (cloud sandbox: `add_issue_comment`, then re-read the
posted comment). Most postings follow performing the squash-merge yourself — the posted
comment plus the merge are the approval of record, there is no separate formal "approve"
step — then hand back to the parent for worktree/branch cleanup. The **Hand-back
variant** below is the one exception: the review is still clean and still the approval
of record, but the posting precedes any merge, because the parent — not this reviewer —
carries the PR the rest of the way.  You write the trailing machine-readable review
footer yourself; its rules are in
[verdict-rules.md](../verdict-rules.md#the-machine-footer). Here `findings` mirrors this
verdict's Notes list, each `blocking: false` — nothing blocks on an approval — and an
empty array is correct when Notes is empty. Confidence is a separate axis: a Notes item
may sit below 80 because Step 6.5's gate moved it off the Findings table, or at or above
80 because it is verified and real yet blocks nothing. Give each entry the confidence
you settled on and the severity it carries.

```markdown
## PR Review — Approved

**Round**: <N>
**Reviewer**: contextless review agent (github-pr-review skill)
**Verdict**: Approved — merged
**Helpers**: <count · model · purpose · tokens, one per helper, or `none`>

### Summary
One paragraph: what was reviewed and the overall state [; relayed head `<sha>` re-verified for findings <ids>].

### Issue Coverage
All requirements from #X verified resolved and ticked on the issue; pending-live: <list or none>.

### Attack list
| Probe | Result |
| ----- | ------ |
| Spec fidelity / scope | found nothing — <what was checked> |
| Correctness | |
| Silent failures | |
| Behavioural tests | |
| Concurrency / ordering | |
| Security surface | |
| Drift guards | |
| History (blame, prior PRs) | |
| Comments match code | |
| Standards & smells | |
| Guard-test mutation | |
| Unreadable-directory probe | |
| Merged-tree test | |
| Literal-text verification | |

### Notes (not required — non-blocking, any confidence)
| # | Severity | Confidence | Note |
| - | -------- | ---------- | ---- |
| 1 | blocker / major / minor / note | <0-100> | ... |

### Test Results
- CI: green
- Path taken: <Skip entirely | Trust the evidence (manifest) | Run tests yourself>
- Unit tests: pass — <counts> (trusted via manifest, round <R>) | pass — <counts, self-run> | n/a — Path 1 skip
- Integration tests: pass — <counts> (trusted via manifest, round <R>) | pass — <counts, self-run> | n/a — Path 1 skip
- Lint: clean (trusted via manifest, round <R>) | clean — self-run | n/a — no lint documented
- Coverage: <N>% (base <M>%) — no regression, at or above 80% (trusted via manifest, round <R>) | n/a — no coverage command in docs/process/testing.md
- Secret scan: clean
- Suggested test steps: all <Y> passed

### Reviewer-applied
- `<sha>` — finding <F> (<severity note>): <one line on what changed>
  ```diff
  <the commit's diff, verbatim>
  ```
  Gate: trailer ✓ · files in diff ✓ · strip-compare `<command>` → IDENTICAL (or: exempt, Markdown) · lines this round: <n>/10 · suite: <green — how>
- *(none)* if nothing was applied

### Deferred Items
- #<n>: <short title> — filed during this review
- seen again: #<n> — <short title>, parked hit, not reopened
- reopened: #<n> — <short title>, second sighting
- *(none)* if nothing was deferred

Squash-merged[; remote branch deletion verified (local only)]. Board: Verified = <n/a | pending-live>. [Native review: approved under <reviewer account>.] Handing back to parent for cleanup.

<!-- review {"v":1,"round":<N>,"verdict":"approved","findings":[]} -->
```
 A non-empty Reviewer-applied section forces the hand-back variant below — the merge
lines above are never posted on such a round. Relayed findings (SKILL.md Step 7 § Relay)
are not listed there: their commits are the implementer's and appear in its `## Fixes
Applied` comment; the Summary names the relayed head instead.

## Hand-back variant

Use this variant, instead of the merge lines above, when the review is otherwise clean
but the reviewer cannot land the PR itself. Three cases reach it, and they are
exclusive. Two are a PR that is non-CLEAN at verdict time: a shared-constant race, or a
branch that needs a rebase as
[verdict-rules.md](../verdict-rules.md#stale-base-vs-a-base-that-moved) qualifies it —
not a base that merely advanced during the review, which that reference discharges on
evidence instead. The third is a round in which the reviewer committed reviewer-applied
fixes; SKILL.md Step 7 is what keeps it from coinciding with the other two. In every
case the reviewer still records the approval — the review itself found nothing blocking
— but does **not** merge, does not rebase, and
does not touch the branch further: it hands back to the parent. Replace the verdict
line and the closing paragraph with:

```markdown
**Verdict**: Approved — hand-back: shared-constant race, merge deferred to the merge-verifier

<!-- handback: shared-constant-race -->
```

and

```markdown
Not merged — handing back to the parent for the rebase and merge-verification round.
Board: `Verified` is left to the merge-verifier — it sets `Verified` to <n/a |
pending-live> when it merges (on PASS; on PASS or FAIL for `reviewer-applied`), not this
comment.

<!-- review {"v":1,"round":<N>,"verdict":"approved","handback":true,"findings":[]} -->
```

The marker's slug names which case handed back — `shared-constant-race` above,
`stale-base` for a branch that needs a rebase, `reviewer-applied` for a round carrying
the reviewer's own commits — so the parent reads the reason it is dispatching for
without parsing the prose. The verdict line says the same thing in words. On the third
case the two replacements read:

```markdown
**Verdict**: Approved — hand-back: reviewer-applied, merge deferred to the merge-verifier

<!-- handback: reviewer-applied -->
```

and "Not merged — handing back to the parent for the merge-verification round." in the
closing paragraph — there is no rebase on that path.

Between the first two, `shared-constant-race` wins: post it when the conflict is in a
file this PR and the sibling that merged first both changed for the same self-counting
constant — the shape
[orchestration.md](../../../github-workflow/references/orchestration.md#entry-path-the-shared-constant-race)
hands `workflow-rebase` its union rule for — and `stale-base` for every other conflict
or stale-deletion hit. Same pair of agents either way; the slug only tells the rebase
agent which resolution rule it is under.

The rest of the template — Issue Coverage, Attack list, Notes, Test Results,
Reviewer-applied, Deferred Items — is unchanged; deferring the merge does not change
what the review found. The `handback` key is additive to the footer schema:
`preflight.sh` and every other consumer that reads `verdict` alone still sees
`"approved"` and needs no change; only a consumer that specifically wants to distinguish
a merged approval from a deferred one reads `handback`. The orchestrator locates this
variant by grepping the PR's comment thread for the `<!-- handback: … -->` marker, then
dispatches the round the slug names.
