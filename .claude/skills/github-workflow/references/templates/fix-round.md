# Fix-Round Dispatch Template

Dispatch with `subagent_type: workflow-fix`. Choose the tier at dispatch time per
`orchestration.md`'s Routing table: mid tier (Claude: Sonnet) by default, large tier
(Claude: Opus) when the round contains a design-shaped finding (architecture/contract
change, concurrency/race, security model, cross-module refactor), is a final-entering
round, or the reviewer labelled it design-shaped. Works in the EXISTING author worktree
so branch/PR continuity holds. Standing rules (no-subagents, bounded-wait, git rules,
log filenames, CI gate, never set In review, quiet reporting) live in the agent
definition (`.claude/agents/workflow-fix.md`) — do not re-type them here. The one
exception is the evidence-manifest field spec below: it is the emitted artifact's
format, not a standing rule, and is spelled out on purpose.

````text
You are a fix-round subagent for PR #<P> in <owner>/<repo> (<sanitization rule
pointer>). Work in the existing author worktree <worktree root>/issue-<N> (branch
<branch>). Scratch: `<scratch root from docs/process>`, under a **uniquely-named
subdirectory** — never `/tmp` directly, never inside the repo tree. Board: ensure #<N>
is assigned to the acting account and set it to **In progress** now (<item-edit
command>).

`<R>` throughout this template is the number of the review round whose findings this fix
agent was dispatched to fix — the round posted as the `**Round**: <R>` line of a
`## PR Review — Changes Requested` verdict (or `## Review Findings — relay` on a relay
fallback). A resume for a relay on this same round does not increment it: every `<R>`
below, including the relay-log suffix's, names that one unchanged round number.

Read the round-<R> findings at <link: the `## PR Review — Changes Requested` comment,
or the `## Review Findings — relay` comment on a relay fallback> and fix EVERY finding:
1. <finding → the fix expected, incl. the class-killing guard when the finding is an
   instance of a known class>
2. …

Posting comments: every comment you post — the evidence manifest below, `## Fixes
Applied`, a correction on another thread — goes through
`bash .claude/skills/github-workflow/scripts/post-comment.sh <issue-or-pr> <body-file>`
from the repo root: compose the body in a file, and the script refuses a bare
`@`-prefixed path, posts with `-F body=@<file>`, reads it back and prints the URL.
Never `gh … --body "@<path>"` — the literal path is posted silently. In a cloud-sandbox
dispatch, where the script is unavailable, post with `gh api … -F body=@<file>` or
`add_issue_comment` and re-read the posted comment yourself before trusting it.

Evidence: after the suite run for this round, post a `## Test Evidence — round <R>` PR
comment (a manifest, not prose) with the same fields the implementer emits, computed
from the run you just did, through `post-comment.sh` as above.

The full field spec (Command, Env, Head SHA, Exit code, Results, Log SHA-256, Raw log,
Lint state, Coverage, the footer, and the default recipe) is single-sourced in
`templates/implementer.md`'s Evidence section — read it from there rather than a copy
here. That includes the rule governing **Exit code**'s shape (when the field is written
as sub-bullets and when it may stay inline) and the conformance properties
`check-manifest.sh` enforces, each stated once, in that section, and not restated
here — the skeleton below simply shows the shape it produces. Only the deltas below are
round-specific:

- **Round number** — every `round 0` in `implementer.md`'s recipe and manifest becomes
  this fix round's `<R>` (in the `LOG=` path, the `jq` invocation, the manifest heading,
  and the footer's `round` key).
- **Log name** — `<scratch>/evidence/issue<N>/test-r<R>.log`, `<N>` still the dispatch
  prompt's primary issue even when this round folds in another.
- **Folded issue** — when this round folds an additional issue into the PR, extend the
  **Command** field to also cover the folded issue's own check, and add a matching
  Suggested Test Step to the PR body; a fold that skips either leaves the next reviewer
  with nothing to arbitrate against for it.
- **Footer's `issue`** — still the dispatch prompt's primary issue (the one this PR's
  implementer round was dispatched for), never the folded issue.

Any claim you make about **another PR's or issue's outcome** — in this manifest, in the
PR body, or in any comment you post — carries the permalink to the comment that
establishes it, per the pr-body template's **Claims about another PR or issue**. Read
that comment and the line you are relying on first; with no permalink to cite, drop the
claim instead of asserting it.

Worked example of the footer for a command list whose second member exits non-zero by
design and whose first carries a backtick — `jq -n --arg` escapes it, so the footer
still parses:

```json
{"issue":42,"round":1,"head":"0f1e2d3c4b5a69788796a5b4c3d2e1f009182736","exit":0,"log":"/home/agent/scratch/evidence/issue42/test-r1.log","sha256":"3b1f0c9d5e2a47b8c6d0e1f2a3b4c5d6e7f80912a3b4c5d6e7f8091a2b3c4d5e","command":"grep -n 'a `backtick` phrase' docs/process/testing.md; command -v markdownlint markdownlint-cli2"}
```

```markdown
## Test Evidence — round <R>
- Command:
  - `<literal, fully-expanded command line>`
  - `<one bullet per command, verbatim as the log echoes it>`
- Env: <os/runtime versions, from the run's own probe output>
- Head SHA: `<40-char sha>`
- Exit code:
  - 0
  - 1 (expected — `command -v` probe, neither linter installed)
- Results: 42 passed, 0 failed, 1 skipped
- Log SHA-256: `<64-hex digest>`
- Raw log: `/home/agent/scratch/evidence/issue<N>/test-r<R>.log`
- Lint state: markdownlint installed — clean (or: not installed — review-only)
- Coverage: 84.2% (base 83.9%)   (or: none — testing doc has no coverage section)

<!-- evidence {"issue":<N>,"round":<R>,"head":"<40-char sha>","exit":0,"log":"/home/agent/scratch/evidence/issue<N>/test-r<R>.log","sha256":"<64-hex digest>","command":"<cmd one>; <cmd two>"} -->
```

Deferred items: anything you notice and do not fix gets an issue (dup-scan first) per
SKILL.md's Deferred Items rule: type + `deferred` + `concern:*` + `area:*`, a
`Spawned by PR #<P> round <R>` line in the Home section followed on the next line by the
required `Unit:` line (one repo-relative file path, one repo-relative directory path
ending in `/`, or one `area:*` label — that rule states its exact form and how to choose
the value), milestone when one applies, no epic parent. List them in your final message.

Then: <full suites + lint with environment>; sanitize scan; `git fetch origin && git
rebase origin/main` if main moved (resolve <expected areas> additively; verify no stray
deletions with condition 1 of `github-pr-review/references/verdict-rules.md` § Stale
base, run as written there); push (`--force-with-lease` only if rebased); post a
`## Fixes Applied` comment per the fixes-applied template with finding → fix →
evidence. Before pushing, hand-check any AC of the shape `grep '<phrase>' <file>`
against the resolved file yourself — the wrap norm can split a phrase across a line
break, so the AC's own grep can silently stop matching. `check-ac-phrases.sh`, which
used to automate this, was retired per the 2026-09-05 owner ruling on #732 (item 2):
interpretive on both ends, and there is no mechanical replacement yet.

Refresh the PR body before posting `## Fixes Applied`: the body becomes the squash
commit message, so a count it states that this round made stale lands in history
permanently. Re-read it for every self-describing number and enumeration — the commit
count in **Rollback**, probe and test counts in **Summary**, the expected outputs in
**Suggested Test Steps** — and edit any this round changed with
`gh pr edit <P> --body-file <path>` (write the body to a file, never an inline string).
Run `check-test-steps.sh --body-file <path> --check-shas` over it again afterwards —
`--check-shas` catches a body-named SHA (a `## Rollback` commit, a mutation-probe
summary) this round's rebase or force-push left stale, the exact gap issue #640 was
filed on.

Final message: fixes, test counts, comment link. Do not merge; the next reviewer is
dispatched by the orchestrator.

You may be resumed once after this round's verdict, with a relay, on exactly the same
terms `templates/implementer.md`'s closing paragraph states for the implementer — read
the resume contract from there rather than a copy here. As this round's fix agent, you
are the head's author, so a relay on this round's diff resumes you, not the original
implementer: fix exactly the relayed findings in this same worktree and nothing else,
and log the round's own evidence to `<scratch>/evidence/issue<N>/test-r<R>-relay.log`
(`<R>` is the review round unchanged) — the `-relay` suffix keeps it from ever
colliding with this round's own unsuffixed `test-r<R>.log`, since the two are written
by the same agent in the same round but are never the same file.
````

If a finding needs branch-history surgery (e.g. a secret annotation must be in the
introducing commit), the orchestrator explicitly authorises a non-interactive collapse
of the UNMERGED branch (`git reset --soft $(git merge-base origin/main HEAD)` +
recommit) with a before/after `git diff origin/main...HEAD | sha256sum` identity proof.
Never `git rebase -i`; never rewrite anything merged.
