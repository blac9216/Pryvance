# Sign-off Request (chat + epic comment)
Epic comment posted with `.claude/skills/github-workflow/scripts/post-comment.sh <epic> <body-file>`
(by hand: `gh api -X POST repos/<o>/<r>/issues/<epic>/comments -F body=@<file>`).
```markdown
Research for <story> is complete: <n> lanes, <m> findings that change the design, <k> unresolved.
Composite: <link>. Nothing downstream starts until you ratify or amend.
Ratify as-is, or tell me which findings to strike or change.
```
