# Observed failure modes (general)

All observed in real sessions; the maintenance rule audit looks for the first four.
Repo-specific ones belong in the repo's `docs/process/failure-modes.md`.

- **Implementers writing into the main checkout** before creating their worktree. A
  dirty main checkout is the tell; a report that "smells off" is the prompt to check.
- **Agents spawning subagents** despite the rule. Order full disclosure and personal
  verification of the delegated diff; tell the reviewer to treat it as unverified
  first-draft code.
- **Stalled agents "waiting for a notification"** that never comes — implementers and
  reviewers alike. On this harness only the top-level session is notified when a
  backgrounded task finishes; no such notification ever reaches a subagent, so an agent
  that ends its turn waiting for one waits forever while still looking alive (see
  [platform-claude.md](platform-claude.md) for the harness detail). Prevent it by making
  foreground-only waiting explicit in the dispatch prompt rather than leaving the agent
  to infer it; recover by resuming the agent with: the notification will never arrive;
  plain foreground calls only; here are the remaining steps.
- **Usage-limit death** mid-task: the report is the limit message, the work is
  uncommitted in the worktree. Resume the same agent; step 1 is "commit the WIP".
- **Model inheritance**: an agent running on the wrong tier because the dispatch omitted
  `model`. Set it explicitly at every dispatch; the resolution chain is canonical in
  [platform-claude.md](platform-claude.md#subagent-type-pinning-and-model-precedence).
- **Body edits via process substitution** blank the body while printing a success URL.
  File + `--body-file` + length check, always. A script that asserts before writing can
  abort silently after a successful-looking run — grep to confirm the edit landed.
- **Status sections rot** under incremental patching into self-contradiction. Rewrite
  wholly.
- **Stale-base branches**: a rebase-less branch whose merge would delete files that
  landed on main since. The reviewer runs condition 1 of
  `github-pr-review/references/verdict-rules.md` § *Stale base vs. a base that moved*
  at verdict time — the `comm -12` of the PR's three-dot deletions against `main`'s
  changes since the merge base — and on a genuine stale base approves with the
  hand-back variant so the orchestrator's `workflow-rebase` does the rebase: the
  reviewer never rebases the branch under review.
- **Reviewer over-deference to design framing**: a capability loss waved through as
  "by design" — re-check the cited design yourself; non-goals get stretched.
- **Reviewers merge-then-comment**: a merged PR with no verdict for a minute is the
  ordering race, not a violation.
- **Closing keywords in prose** (`closes #N` in a sentence) close the wrong things at
  merge. Keywords only on their own line at the top of the body.
- **Agents under-file deferrals**: every "worth a follow-up" in a report is an unfiled
  issue until the orchestrator files it.
- **Board listing at scale** burns API points fast; filter or paginate rather than
  listing everything on each check.
- **Parent auto-close**: GitHub auto-closes a parent issue the moment its last sub-issue
  closes, even on a Refs-only PR that never mentions the parent. A parent closing
  unexpectedly is this, not a bug in the PR — reopen it and re-home the sub-issue as a
  sibling instead of a child.
- **Shared stash across worktrees**: `git stash` refs are repo-wide, not per-worktree —
  one agent's `stash pop` can collide with or clobber another agent's stashed work. The
  remedy is the standing ban on `stash`/`reset --hard` plus a throwaway worktree for any
  baseline diff.
- **Mergeable stuck UNKNOWN → DIRTY**: checks never fire on a PR whose mergeable state
  wedges at UNKNOWN and then flips DIRTY with no run queued. Closing and reopening the
  PR or pushing an empty commit both fail to retrigger it — the wedge is a stale merge
  computation, not a missing trigger. Only a rebase that actually resolves the conflict
  unwedges it; treat a DIRTY state with no checks as "rebase now", not "retry the same
  no-op twice more".
- **Paginated comments silently truncated**: `gh pr view --json comments` returns a
  fixed page and drops the rest with no error or warning, so a long thread looks
  shorter than it is and late feedback goes unseen. Read comments only through the
  paginated comments API — `gh api repos/<o>/<r>/issues/<N>/comments --paginate`, or an
  MCP call that paginates — never the single-shot `--json comments` field, whenever a
  thread could plausibly exceed one page.
- **Per-issue REST loops exhaust the hourly quota**: looping a REST call once per
  issue burns the shared 5,000/hr budget fast on any board of real size, and the loop
  usually notices only after it is already rate-limited mid-pass. Batch equivalent
  reads into a single GraphQL query, resume incrementally from where a prior pass left
  off rather than restarting cold, and stop deliberately before the wall instead of
  running until the API enforces it.
- **Broad process kills on a shared host**: `pkill -f` and `killall`-style kills match
  by name or pattern across the whole host, not just the caller's own subtree, so they
  can take out a sibling agent's in-flight work with no warning. Kill only pids this
  session itself started and recorded (e.g. from a `.pid` sentinel file), never a
  pattern broad enough to catch another agent's process.
- **Tool state leaking into the repo tree**: letting `gh`, XDG config/cache dirs, or
  similar tool state default to paths under the repo root litters `git status` with
  untracked files and risks one landing in a commit. Point every such tool at a
  scratch or home-relative location up front, and treat unexplained untracked files
  under tool-looking names as a sign the redirection is missing, not as noise to
  `git add -A` past.
- **AC grep phrases split by a line wrap**: an acceptance criterion of the shape
  `grep -n '<phrase>' <file>` reads fine to a human even when the target file's prose
  wraps the phrase across two lines — the eye rejoins it, `grep` does not. It happened
  four times on one PR round and once more on another before anyone noticed.
  `check-ac-phrases.sh`, which used to catch this by extracting the phrase from an
  issue's prose and re-running the grep, was retired per the 2026-09-05 owner ruling on
  #732 (item 2) — it was interpretive on both ends (see `github-tools.md`'s "Extraction
  vs. interpretation") and produced more residuals than any other script this milestone.
  There is no mechanical replacement yet; until one lands, run the AC's own named
  `grep` by hand against the target file before pushing.
- **A mis-posted `--body "@file"` comment**: `gh pr comment --body "@/path/to/file.md"`
  does not read the file — only `--body-file` does — so the literal path string is
  posted as a roughly 100-byte comment and `gh` reports success with a normal comment
  URL. The symptom is silent in both directions: the poster sees a working link, and a
  mechanical reader (e.g. `preflight.sh`) sees an ordinary non-manifest comment and
  reports one manifest fewer than the round actually produced, with no error naming
  what went missing. The remedy is always composing the comment in a file and posting
  it with `--body-file <path>` (or `gh api … -F body=@file`) — never `--body "@<path>"`.
  This recurred three times despite the prose above being repeated in six files, so
  the remedy is now also mechanical: post every issue/PR comment through
  `.claude/skills/github-workflow/scripts/post-comment.sh`, which refuses a body file
  that is missing, empty, or whose entire contents, trimmed, are a bare `@`-prefixed
  path-shaped token with no whitespace anywhere (a body that merely opens with an
  `@mention` is not refused — neither `@user please re-check` nor a mention alone on
  line 1 with the message beneath it), then reads the posted comment back and fails —
  a distinct exit code, naming the comment URL — if the whole stored body is a bare
  `@`-prefixed token or its first line does not match the file's first line.
- **Reaching for `git checkout --`/`git restore` to "undo an edit"**: the `git` block
  used to name only `git stash` and `git reset --hard`, so an agent trying to unstage a
  hunk or re-split a working tree into per-issue commits had no forbidden command in its
  way when it reached for `git checkout -- <path>` or `git restore` instead — both
  discard uncommitted work exactly as destructively as the two that were named. The
  tell is a `Self-corrections` line mentioning `checkout`/`restore`/`clean`, or an
  edit reported as made that the diff does not show (confirm with an unexpected empty
  `git diff --numstat` before trusting a report of "unchanged"). The mitigation: write
  the change to a patch under your own scratch directory (`git diff > <scratch>/x.patch`)
  and re-apply the pieces with `git apply`/`git apply -R`, or commit first and amend —
  never an undo command that can drop work you have not committed yet.
- **`kill -0` treated as a liveness test at bounded-wait cleanup**: it succeeds on a
  zombie whose exit status has not been reaped, so it cannot distinguish a live process
  from your own already-finished child, and a signal sent on its say-so can land on a
  sibling agent's process if the pid was recycled. Hit three times in one session, across
  three different roles, all converging on the same remedy independently. The tell is a
  `Self-corrections` line naming `kill`/`kill -0`, or a report that signals a pid with no
  check that the job was still running. The mitigation is structural, not a prohibition
  to remember: the bounded-wait poll clears `<log>.pid` the moment it sees the `EXIT=`
  sentinel, so the cleanup kill only ever has a pid file to act on when the job is
  genuinely still running — an absent pid file means there is nothing left to kill.
- **Same-tier `fork` helper spawned instead of a calibrator dispatch**: a reviewer
  reached for a general "continue/resume this agent" action when it meant to dispatch a
  fresh `workflow-calibrator`, spawning a same-tier (or higher) helper that is not the
  one permitted type — `Agent(<type>)` allowlist syntax only restricts spawn types for
  an agent running as the main thread, so inside a subagent definition a listed `Agent`
  tool is simply unrestricted, and `helper-tier`'s prose is the whole control. It burned
  ~129k tokens on output that was correctly discarded, and cost nothing else because the
  agent caught and reported it unprompted. The tell is an unexplained large
  `helpers[].tokens` entry with no `purpose`, or a `Self-corrections` line naming a
  spawn that was not `workflow-calibrator`. The mitigation is prose guarding prose —
  there is no mechanical enforcement available (`platform-claude.md` § `tools:`
  allowlist semantics) — so `helper-tier` now states the single permitted dispatch form
  verbatim (`subagent_type: workflow-calibrator`, mid tier) rather than leaving the
  agent to recall it from a description.
- **A board `--paginate` query naming its own cursor variable instead of `$endCursor`**:
  `gh` only substitutes the previous page's cursor into a variable named exactly
  `$endCursor`; any other name (`$after`, `$cursor`) leaves nothing for it to
  substitute, so the call silently re-requests page one forever. The tell is a query
  that returns valid data slowly and never finishes, followed by `RATE_LIMIT` errors
  surfacing in *other*, unrelated agents' calls once the shared secondary GraphQL limit
  is exhausted — the failure looks nothing like a pagination bug from where it
  surfaces. The mitigation is the recipe in
  [github-tools.md § Reading the board](github-tools.md#reading-the-board-pagination-and-the-cursor-name-trap):
  use gh's `$endCursor` name in the `--paginate` form, or write an explicit page loop
  that reads and passes `pageInfo.endCursor` itself.
