---
name: gitlab-workflow
description: GitLab issue-driven workflow for tracking all work. Use when creating issues, branches, commits, or MRs on GitLab projects.
argument-hint: issue
---

# GitLab Issue Workflow

This defines how Claude Code agents should track work using GitLab issues. All work follows an issue-first workflow.

## Issue-First Rule

Create a GitLab issue **immediately before writing any code**. No code changes without a corresponding issue. This applies to both bugs discovered during testing and enhancements/features requested by the user.

## Bug Template

Use this template when something is broken or not working as expected:

```markdown
## Description
What is broken and how it manifests. Include exact error messages or log output.

## Discovery
How and when this was discovered. What operation or test triggered it.
Include the sequence of events that led to finding the problem.

## Root Cause (if known)
Technical explanation of why it happens. If unknown, state what has been investigated so far.

## Affected Files
| File | Relevance |
| ---- | --------- |
| `path/to/file` | Why this file is involved |

## Impact
What is affected (features, output, user experience, other components).

## Possible Fixes
- Option A: Description of approach and trade-offs
- Option B: Alternative approach if applicable
```

## Enhancement Template

Use this template for new features, improvements, or refactoring requested by the user:

```markdown
## Summary
What is being added or changed and why.

## Motivation
Why this enhancement is needed. What problem it solves or what capability it adds.
Include user request context if applicable.

## Current Behavior
How things work today (if applicable). What is missing or insufficient.

## Proposed Changes
- Change 1: Description and rationale
- Change 2: Description and rationale

## Affected Files
| File | Relevance |
| ---- | --------- |
| `path/to/file` | Why this file is involved |

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2

## Risks / Considerations
Anything that could go wrong, break existing behavior, or needs special attention.
```

## Issue Labels

Apply standard labels to every issue:

| Label | When to use |
| ----- | ----------- |
| `bug` | Something isn't working |
| `enhancement` | New feature or improvement |
| `help` | Requires human intervention — agent is blocked |

The `help` label signals that the agent cannot resolve the issue autonomously. Always post a comment explaining what was tried and why it's blocked before adding this label.

## Progress Comments

As you work an issue, add structured comments so that a human or another agent can pick up where you left off:

```markdown
## Progress Update

**Status**: investigating | in-progress | testing | blocked

### What was done
- Step-by-step list of actions taken

### Findings
- What was learned from each step

### Current state
- Where things stand right now

### Next steps
- What remains to be done

### Blockers (if any)
- What is preventing progress and what help is needed
```

## Branches and Worktrees

Create a branch for each issue before starting work. Branch names follow the pattern `<issue-number>-<short-description>`.

To allow multiple agents to work on different issues concurrently, always create a **temporary git worktree** instead of switching branches in the main checkout:

```bash
git worktree add /tmp/issue-10 -b 10-short-description
cd /tmp/issue-10
```

All commits for that issue go in its worktree. Do not commit directly to `main`. When done (after the MR is created or the worktree is no longer needed), clean up:

```bash
git worktree remove /tmp/issue-10
git branch -d 10-short-description
```

## Commits

All AI-authored commits use the `AI:` prefix:

```bash
git commit -m "AI: fix description of what was fixed"
```

## Merge Requests

Both unit tests and integration tests must pass before creating a merge request. Do not create an MR if either suite fails — fix the failures first.

When both pass, push the branch and create a merge request using the `glab` CLI. Use `--remove-source-branch` so the branch is automatically removed after merge:

```bash
git push -u origin 10-short-description
glab mr create --title "Fix short description of fix" --description "Closes #10" --remove-source-branch
```

The MR title should be concise (under 70 characters). Reference the issue number with `Closes #N` in the description so it auto-closes on merge. Add the same labels as the issue.

## Deferred Items

If a bug is found but is out of scope or not worth fixing immediately, open an issue with the full template above so it can be addressed later. Do not silently skip it.
