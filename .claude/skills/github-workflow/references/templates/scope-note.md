# Scope Note Comment Template

Post on the issue when a review finds one of its acceptance criteria to be a planning
defect — it contradicts the issue's own Summary/Proposed Changes, the parent epic's
Scope, or the ratified design record — and the orchestrator rewrites the AC through a
body-file edit. Not for an AC that is merely inconvenient to satisfy: that AC stays as
written and the PR keeps working against it. See orchestration.md's "AC amendment"
section for the full procedure.

```markdown
### Scope note — <date>

**Flagging review**: PR #<pr>, round <n>.
**Old AC**: <verbatim text of the removed/replaced criterion>.
**New AC**: <verbatim text of the criterion now in the issue body>.
**Delivering sibling**: #<issue> | none.
**Reason**: <one line — why the old AC was a planning defect, not an inconvenience>.
```
