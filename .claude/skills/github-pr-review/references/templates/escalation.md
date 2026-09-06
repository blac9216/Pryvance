# Escalation Template

Post as a comment on the PR when the PR class's round cap is reached (`orchestration.md`
§ PR class and round caps) and the PR is still not clean. Post it through
`post-comment.sh` per the dispatch prompt's Posting line (cloud sandbox:
`add_issue_comment`, then re-read the posted comment). Apply the `help` label to the PR
and its issue, then hand back to the parent — a human must take over.  You write the
trailing machine-readable review footer yourself; its rules are in
[verdict-rules.md](../verdict-rules.md#the-machine-footer). `findings` mirrors
Outstanding Findings, each `blocking: true`. `id`, `severity` and `confidence` are
carried forward from the Changes-Requested round that raised the finding — that round's
Findings table is their source — and the list below restates all three, so the footer
has something above it to be checked against.

```markdown
## PR Review — Escalated

**Round**: <cap + 1> (cycle cap reached)
**Verdict**: Blocked — human review needed
**Helpers**: <count · model · purpose · tokens, one per helper, or `none`>

After <cap> review cycles the PR still has unresolved findings. `help` label applied.

### Outstanding Findings
| # | Severity | Confidence | Finding | Raised in round |
| - | -------- | ---------- | ------- | --------------- |
| 1 | blocker / major / minor / note | <0-100> | <finding> | <R> |

### What was tried across rounds
- Round 1: <summary>
- Round 2: <summary>
- Round 3: <summary>

<!-- review {"v":1,"round":<cap + 1>,"verdict":"escalated","findings":[{"id":"1","severity":"blocker","confidence":85,"blocking":true}]} -->
```
