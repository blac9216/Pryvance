# Fixes Applied Template

Post on the PR after addressing a round of review findings; the orchestrator then
dispatches a fresh reviewer for the next round — or, on a relay, resumes the same
reviewer within the round.

```markdown
## Fixes Applied — Round <N>

Responding to the round <N> review findings above.

### Changes Made
| Finding # | Resolution | Commit |
| --------- | ---------- | ------ |
| 1 | What was changed | `abc1234` |

### Verification
- Unit tests: pass — <counts>
- Integration tests: pass — <counts>
- Lint: clean
- Coverage: <N>% | none — <quoted testing.md line>

Ready for re-review.
```
