# Composite Findings Comment Template
Posted on the research epic when every lane has reported.
Post with `.claude/skills/github-workflow/scripts/post-comment.sh <issue> <body-file>`
(by hand: `gh api -X POST repos/<o>/<r>/issues/<issue>/comments -F body=@<file>`).
```markdown
### Composite findings

| # | Finding | Lane | Forces this decision |
|---|---|---|---|
| 1 | <fact that changes the design> | #<lane> | <decision> |

**Unresolved** — <what no lane could establish and the fallback each implies>

**Recommended ratifications** — <the owner's decisions this composite proposes, one line each; the interrogation will confirm or amend them>
```
