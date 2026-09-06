# Review Findings (Changes Requested) Template

Post as a comment on the PR when the verdict is Changes Requested. Post it through
`post-comment.sh` per the dispatch prompt's Posting line (cloud sandbox:
`add_issue_comment`, then re-read the posted comment). Then hand control back to the
parent — the parent owns fixing the findings.

You write the trailing machine-readable review footer yourself; its rules are in [verdict-rules.md](../verdict-rules.md#the-machine-footer). Every row that stayed on
a Findings table belongs in `findings` (`id` = its `#`, `severity` from the table,
`confidence` ≥ 80, `blocking: true`); Notes-list items append with `blocking: false`,
keeping the severity you gave them.

```markdown
## PR Review — Changes Requested

**Round**: <N>
**Reviewer**: contextless review agent (github-pr-review skill)
**Verdict**: Changes requested
**Helpers**: <count · model · purpose · tokens, one per helper, or `none`>

### Summary
One paragraph: what was reviewed and the overall state.

### Issue Coverage
| Requirement (from #X) | Status | Notes |
| --------------------- | ------ | ----- |
| <criterion> | met / unmet / pending-live | ... (ticked on the issue when met) |

### Findings — Spec (does not do what was asked / does more)
| # | Severity | Confidence | Location (permalink) | Problem | Required change |
| - | -------- | ---------- | -------------------- | ------- | --------------- |
| 1 | blocker / major / minor / note | ≥80 | `https://github.com/…/blob/<sha>/path#L…-L…` | ... | ... |

### Findings — Standards (how it is written)
| # | Severity | Confidence | Location (permalink) | Problem | Required change |
| - | -------- | ---------- | -------------------- | ------- | --------------- |

### Attack list
| Probe | Result |
| ----- | ------ |
| Spec fidelity / scope | found (<what>) / found nothing / not applicable (why) / not probed (why) |
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
- CI: <status>
- Path taken: <Skip entirely | Trust the evidence (manifest) | Run tests yourself>
- Unit tests: <pass/fail — counts> (trusted via manifest, round <R>) | <pass/fail — counts, self-run> | n/a — Path 1 skip
- Integration tests: <pass/fail — counts> (trusted via manifest, round <R>) | <pass/fail — counts, self-run> | n/a — Path 1 skip
- Lint: <clean / regressed — details> (trusted via manifest, round <R>) | n/a — no lint documented
- Coverage: <N>% (base <M>%) — <regression? meets 80%? waiver?> (trusted via manifest, round <R>) | n/a — no coverage command in docs/process/testing.md
- Secret scan: <clean / hits>
- Suggested test steps: <X of Y passed>

### Required Before Merge
- [ ] <finding 1>
- [ ] <finding 2>

### Deferred Items
- #<n>: <short title> — filed during this review
- seen again: #<n> — <short title>, parked hit, not reopened
- reopened: #<n> — <short title>, second sighting
- *(none)* if nothing was deferred

<!-- review {"v":1,"round":<N>,"verdict":"changes_requested","findings":[{"id":"1","severity":"blocker","confidence":90,"blocking":true}]} -->
```
