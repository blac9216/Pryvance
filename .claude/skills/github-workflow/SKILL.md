---
name: github-workflow
description: Issue-driven GitHub workflow for a repository organised as Project board → delivery-story milestones → domain epics → issues. Use it whenever work touches GitHub state or code in such a repo — picking up an issue, epic or milestone ("work epic 1176", "work the triage queue", "next ready"), running solo or as the sole orchestrator of parallel subagents (serial/parallel, interactive/overnight), branching, committing, opening or handing off a PR, triaging filed issues, running live validation, asking for "status", "good morning", "morning cleanup", or a session handoff. Consult it before writing any code so the board stays honest from the first minute.
argument-hint: <issue|epic|milestone|triage|next> [solo|serial|parallel] [overnight]
---

# GitHub workflow

One skill, two roles. **Solo**: this session implements. **Orchestrated**: this session is the
*sole* orchestrator of background subagents and never implements, reviews or merges
non-trivial work itself. In both roles the reviewer is always a fresh, contextless agent
running `github-pr-review`. Everything the workflow knows about *state* lives on GitHub —
the Project board, milestones, epics, issues and PR comments — never in chat memory. A
session that cannot be reconstructed from GitHub after a crash was not run correctly.

The repository carries its own specifics. This skill is general: repo names, paths,
commands, label values, testing recipes and environment nuance come from
`docs/process/*.md` (committed) and `*.local.md` (never committed). If something you need
is not there, that is a gap in the repo's process docs — file it, do not improvise it into
the skill. See [references/process-dir.md](references/process-dir.md).

## The shape you are working in

| Layer | What it is | What it holds |
|---|---|---|
| **Project board** | The one guaranteed home of every issue. | `Status` column, `Verified`, `Claimed by`. Closed items stay as the verification ledger. |
| **Milestone** | A multi-epic delivery story. Optional — only feature stories get one. | Description = rolled-up state (rewritten wholly, rarely) + dated decision ledger. No comment thread. |
| **Epic** | One domain inside a story, or a milestone-less theme. Always >1 child. | Goal/scope/design pointer in the body; **events in the comment thread**. ≤100 children. |
| **Issue** | The work. | Under an epic when it groups; otherwise directly on the board. |

Columns: **Triage → Backlog → Ready → In progress → In review → Done**. `Verified`:
`n/a · pending-live · live-verified · live-failed`. Labels classify (type, severity,
priority, `concern:*`, ≥1 `area:*`, `deferred` = filed-out-of-scope provenance,
`backlog` = not released for work — "agents, don't work it" — with or without a
milestone); fields track state. Native mechanisms over prose: sub-issues for
hierarchy, `blocked by` dependencies for sequence, close reasons
(`completed`/`not planned`/`duplicate`), task-list checkboxes for acceptance criteria,
a plain `git branch` per issue for the linked branch.

## Entry — resolve target, mode, horizon

Every invocation resolves three things before anything is read or written:

- **Target**: an issue, an epic, a milestone, the Triage queue, or "next Ready by priority".
- **Mode**: `solo` · `orchestrated serial` · `orchestrated parallel`.
- **Horizon**: `interactive` · `overnight`.

Infer what the target shape makes obvious — a single issue is solo; a large milestone is
orchestrated parallel. An epic is ambiguous. **When unsure, ask one question; never
default.** A wrong mode wastes a night, a question costs a line.

Three keywords bypass target resolution because they act on the running session rather
than on work: `status` and `good morning`
([references/overnight-and-status.md](references/overnight-and-status.md)), and `save`,
which archives the session log now — `save-log.sh --log <scratch>/session.jsonl`, the
same call `status`, `good morning` and the Close checklist make automatically — and
prints the archive commit URL, or says that no archive is configured. `save` changes
nothing else: no brief, no freeze, no claim released.

## The flow

The numbers are the order things happen. Each step names the reference that holds its
detail; read the reference when you reach the step, not before.

**0. Startup checklist** — thirteen items, in order: items 1–12 each write one
`startup-item` session-log line, and item 13 closes the checklist with a single
`startup-complete` event
([references/formats/session-log.md](references/formats/session-log.md)). Step 0
subsumes the former flow steps 1–4; the later steps keep their historical numbers, so a
reference like "step 5" still means the same step it always did.
**Hard rule: no dispatch and no implementation before
`startup-complete` exists in the log.**
A session that stops at its opening question still leaves a log line saying so.

1. **`log-open`** — Session log opened: first action, before resolving anything or
   asking any question. The log is always on, interactive or not, so `status` works at
   any moment.
2. **`quiet-mode`** — Quiet mode on: the standing quiet rule (Rules, below) applies
   from here forward.
3. **`target-mode-horizon`** — Target/mode/horizon resolved: see Entry, above.
4. **`orient`** — Orient: read, in order: `docs/process/*.md`, every `*.local.md`, the
   target's milestone description, the target epic's body and its recent comments, the
   board slice for the target. Re-derive review rounds from PR comments. Derive state
   from GitHub only.
5. **`agent-defs`** — Agent-defs check: verify that each of the six `subagent_type`s
   this suite defines — `workflow-implementer`, `workflow-fix`, `workflow-reviewer`,
   `workflow-rebase`, `workflow-merge-verifier`, `workflow-calibrator` — resolves:
   locally, `ls .claude/agents/workflow-*.md`; on a harness with its own agent registry,
   check that list too. Routing-table rows with no `workflow-*` definition (the
   validation agent, other helpers) are outside this check. A definition that has not
   landed yet is a silent drop to the parent session's own model at dispatch time
   ([references/platform-claude.md § Subagent type pinning and model
   precedence](references/platform-claude.md#subagent-type-pinning-and-model-precedence)),
   so a missing definition is caught here, once, rather than re-diagnosed at every
   affected dispatch: for any role whose definition fails to resolve, splice
   [references/agent-rules.md](references/agent-rules.md) verbatim into that role's
   dispatch prompt for the rest of the session, and log it.
6. **`session-card`** — Session card written: write `<scratch>/session-card.md` from
   [references/templates/session-card.md](references/templates/session-card.md): facts
   and pointers only, never a restated rule. A long session's early context degrades
   under compaction, which keeps only a summary the model did not choose to write; a
   short self-authored card survives that pass because re-reading it at every transition
   puts it back into the fresh window rather than leaving its content to that summary.
   So the card is regenerated wholly whenever target or mode changes, is re-read at the
   first `card-read` slug of every other logged checklist, and again after any compaction
   ([references/platform-claude.md § Post-compaction
   re-read](references/platform-claude.md#post-compaction-re-read)).
7. **`concurrent-check`** — Concurrent-session check: read every non-empty `Claimed by`
   across the board, including everything In progress / In review, before touching
   anything; that is where collisions live. Skip as a dispatch stamp, never a lock:
   every value carrying the literal trailing ` (stamp)` marker, on any issue, parented
   or standalone, plus every unmarked legacy (pre-#744) value on a **parented** issue
   (the pre-#744 rule, parent presence, still resolves that one case — see
   [references/claims.md § Two roles](references/claims.md)'s "Legacy values and
   migration" for why). Every other non-empty value — marker-less, and either
   post-#744 or on a standalone issue — is a coordination lock, subject to the stale
   rule.
8. **`claim`** — Epic-level claim taken and logged: take a claim id and write it to
   `Claimed by` on the epic (or the standalone issue). Refuse anything live-claimed by
   someone else; take over stale claims with an event comment.
   [references/claims.md](references/claims.md).
9. **`timeline-sanity`** — Timeline sanity check (cheap tier): read `due_on` and
   milestone start states from the data Orient (item 4) already fetched; flag anything
   that looks off (e.g. a past-due `due_on` on an open item) in the brief. Never
   recompute the timeline or run a script here — that is the full pass. Session start
   only, never mid-run. Full-pass conditions:
   [references/timeline.md](references/timeline.md).
10. **`readiness-gate`** — Readiness gate: the target must look like planning produced
    it: template-shaped bodies, provable acceptance criteria, type + `area:*` labels, an
    epic with >1 child, a milestone with epics, dependencies set where order matters. If
    it does not, **stop and ask** — "this doesn't look like it has been through
    planning; proceed anyway?" — and do nothing until answered. This skill never
    decomposes work; a separate planning skill does. A Ready issue with ≥1 ticked
    acceptance-criteria checkbox does **not** stop the gate — it is a
    possibly-partially-delivered flag, not a planning defect. Instead, at pick time the
    orchestrator re-evaluates the issue's real state against merged history and comments
    any scope drift on the issue before dispatching it.
11. **`maintenance`** — Maintenance pass: run the full pass
    ([references/maintenance.md](references/maintenance.md)): triage drain (with
    sequencing), host audit, cleanup, rule audit, state audit. Runs here, on every
    resume, before each parallel wave or every three serial issues, and on "morning
    cleanup".
12. **`heartbeat`** — Heartbeat cron armed, on every horizon; see
    [references/overnight-and-status.md § Heartbeat](references/overnight-and-status.md#heartbeat).
13. **`startup-complete` logged** — names any consciously skipped item and why.
    **No dispatch or implementation before this event exists in the log.**

**5. Execute** — per issue: pick next by dependencies then priority → worktree →
implement (solo: you; orchestrated: implementer agent) → PR from template → contextless
review, fresh agent every round, round cap by PR class → fix rounds → the merge **closes
the issue** → reviewer sets `Verified` → cleanup → **event comment on the epic**. Board
columns have exactly one owner each — see
[references/orchestration.md](references/orchestration.md) for the loop, the dispatch
rules, the model Routing table and parallel safety.

**6. Validate** — live validation is a defined tight loop with its own epic: run →
findings → fix-wave → re-run until green. You decide *when*; you must consider it and log
the decision at the named triggers. [references/validation.md](references/validation.md).

**7. Overnight** — quiet chat, structured log, owner-gated decisions routed around with
`help`; the heartbeat (item 12, above) keeps running underneath regardless of horizon.
[references/overnight-and-status.md](references/overnight-and-status.md).

**8. Status and the morning ritual** — `status` = brief without stopping. `good morning`
= freeze dispatch, drain in-flight, brief, then the owner's Q&A and drift correction;
`morning cleanup` on request runs validation-if-warranted and maintenance, reports, and
asks: handoff or continue. Same reference.

**9. Handoff** — a chat-only structured handoff
([references/templates/handoff.md](references/templates/handoff.md)); release claims;
write memory. Nothing goes to the issues — continuous state maintenance is the handoff.

## Rules that do not bend

- **Issue first.** No code without an issue. Assign the issue to the acting account when
  work starts — the first `assigned` event is the estimator's start timestamp; the *claim*
  is the coordination signal.
- **Never merge your own work.** Every non-trivial PR is approved and squash-merged by a
  fresh `github-pr-review` agent. The one exception is the fast path: ≤3 files, ≤50
  changed lines, zero executable code, nothing under `docs/adr/` — `[trivial]` in the
  title, self-merge after CI. If you are wondering whether it qualifies, it does not.
- **Close at merge.** Acceptance criteria must be provable when the PR merges. Proof that
  review cannot supply (a live environment, real vendor tooling, a third party) becomes
  `Verified: pending-live`, never a reason to hold the issue open. Holding issues open for
  unprovable proof is what drives an epic past the 100-child cap.
- **Deferred items are filed immediately.** The moment you write or think "out of scope",
  "for this PR", "pre-existing", "noted, non-blocking", "worked around", "minor", "we can
  address later" — stop, dup-scan, file it (type + `deferred` + `concern:*` or
  `documentation` + `area:*`, with a `Spawned by #<N>` or `Spawned by PR #<P> round <R>`
  line in the Home section naming the discovering issue or the PR and review round),
  then continue. The one exception is a reviewer's own routing: a finding
  `github-pr-review` Step 7 applies or relays is closed by its commit, not by an
  issue. It has no parent — never a
  sub-issue of the discovering work's epic, and never of the issue that spawned it:
  closed children count against the 100-sub-issue cap, and one night of review
  follow-ups once filled an epic on its own. Attach it to the milestone the
  discovering work belongs to when one exists, else it lands in Triage — parentless in
  a milestone keeps the ledger without spending the cap. The orchestrator's triage
  completes its labels (exactly one `priority:*`; `severity:*` on bugs), sequences it,
  and homes it. Before pushing, grep your own diff and notes for those phrases. Agents
  chronically under-file: every such phrase in a subagent's report becomes an issue the
  orchestrator files before the next dispatch. Filing is unchanged by any of this —
  what triage may do with a filed item is not: at `home`, triage may **park** it
  instead of scheduling it, per [references/maintenance.md](references/maintenance.md)
  § 1 step 6.
- **Every deferred filing carries a `Unit:` line.** It is the structured marker
  `batch-deferred.sh` groups residual work by (#751), that triage normalises at
  [references/maintenance.md](references/maintenance.md) § 1 step 9, and that the parked
  dup-scan (`github-pr-review` SKILL.md Step 8) matches a new finding against — three
  readers, two of them scripts, so the line is defined lexically rather than by example.
  It is required on every `deferred` item and appears on no other issue: it is only ever
  paired with the provenance line.
  - **Lexical form.** In the body's raw text (what the API returns, not the rendered
    HTML): a line beginning at column 1 with the exact ASCII key `Unit:` —
    case-sensitive, no bold, no backticks, no list marker before it — then one or more
    spaces or tabs, then the value. The value runs to end of line; leading and trailing
    whitespace is stripped; nothing else may share the line — no trailing comment, no
    trailing punctuation, no second path. The **first** matching line in the body is the
    marker and any later one is ignored. Extraction is `grep -m1 -E '^Unit:[[:blank:]]+'` plus
    a strip: one line, no PCRE, no multi-line parsing.
  - **Value.** Exactly one of three forms and nothing else: a **repo-relative file
    path** (`.claude/skills/github-workflow/scripts/batch-deferred.sh`); a
    **repo-relative directory path** with a trailing `/`
    (`.claude/skills/github-workflow/references/templates/`); or an **`area:*` label**
    (`area:skills`) when the finding has no path at all — a decision, a process
    question, a finding about the workflow rather than a file. Repo-relative, not
    skill-relative: it is the rooting the body's Affected Files table already uses, so
    the marker and the table cannot disagree, and a skill-relative `references/` names
    six different directories in this repo with nothing in the line to say which.
  - **Choosing the value.** Take the files the fix would touch, in Affected Files order.
    No files at all → the `area:*` form. Otherwise reduce each file to its **batch key**
    (step 9's normalisation: a script and its own test share one key). One key → write
    that key's own value (the script path, the shared directory with its trailing `/`,
    or the area label), and where the key is a script/test pair name the **script**,
    never the test. More than one key → name the **deepest directory containing every
    file those keys name**, with a floor: that directory must be strictly below the
    component root
    (`.claude/skills/<skill>/` for a skill file, else the repo's first path segment). If
    the deepest common directory is at or above the floor, the files share no unit: name
    the **first Affected Files row's** file, leave the rest to the table, and consider
    whether the finding is really two issues. Worked example — `scripts/a.sh`,
    `tests/test_a.sh`, `scripts/b.sh`: the pair collapses, keys are `a` and `b`, their
    deepest common directory is the skill root which is the floor, so `Unit:` is the
    first row's file, not `scripts/`.
  - **A missing line is a filing defect, not a date stamp.** Before this rule there were
    no `Unit:` lines, so an unmarked issue may predate it; after it, an unmarked issue
    may equally be a filer that skipped a required line, and nothing in the body
    distinguishes the two — so no reader may treat absence as evidence of age. What each
    reader does is split by what a wrong guess costs. `batch-deferred.sh` **refuses**:
    it excludes the item from every batch with that reason recorded, because a guessed
    unit puts real work in the wrong batch silently. Triage **repairs**: step 9 works
    the choosing rule above against the body by hand, writes the line, and derives from
    it — that repair is how the backlog converts. The dup-scan **degrades**: the
    reviewer infers the unit the item would carry (`github-pr-review`'s match
    predicate), where a wrong candidate costs one reviewer's judgement and nothing
    else, since a candidate is not a hit until that reviewer says so.
- **Events in comments; state in descriptions.** Epic bodies hold goal, scope, a design
  pointer and one Status line. What landed, what a review found, what was decided goes in
  the epic's comments ([references/templates/epic-event.md](references/templates/epic-event.md)).
  Milestone descriptions are rewritten wholly — never patched — and only when a story-wide
  assumption changes; the change goes in the dated decision ledger, which is never deleted.
- **Design lives in `docs/`.** Bodies point at docs; they do not copy them. Owner
  decisions (grill answers) are posted on the domain epic's thread.
- **Every body edit goes through a file.** Write the body to a file, `--body-file` it,
  verify the resulting length. Never process substitution — it has silently blanked bodies.
- **Record state before compaction.** If the context window is getting tight, write
  pending state (event comments, board moves, log lines) before doing anything else.
  See [references/platform-claude.md](references/platform-claude.md#post-compaction-re-read)
  for what this harness's compaction does to a context window and the session-card
  re-read that follows it.
- **The board is only as honest as its last update.** Move columns at the moment the
  transition happens, by the role that owns the column. A stale board is a process defect:
  the moment sessions stop trusting it they collide again.
- **Quiet.** One line to chat on dispatch, merge, blocked-on-owner, escalation and
  validation result; a short summary every ten logged events; everything else goes to the
  log. `status` exists so you never have to narrate.

## Branches, worktrees, commits, PRs

- Branch per issue via plain `git branch` (through the
  `git worktree add … -b <N>-<slug>` form in
  [references/templates/implementer.md](references/templates/implementer.md) /
  [references/github-tools.md](references/github-tools.md)). Work in a **worktree** at
  the repo's worktrees process doc's documented root (`docs/process/worktrees.md`) —
  never in the main checkout when anything else may be running there.
  Keep the worktree until the PR merges (fix rounds need it); then remove it and `-D` the
  local branch (a squash merge leaves it unmerged).
- Commits: `AI:` prefix, one logical change each; squash on merge.
- PR title `<type>(<scope>): <description>` (≤70 chars, imperative, lowercase). Body per
  [references/templates/pr-body.md](references/templates/pr-body.md) — Summary, Risk,
  Rollback, Suggested Test Steps, Verified expectation. Mirror the issue's labels onto the
  PR. Draft PRs get no reviewer until un-drafted.
- Before opening: unit + integration suites and the linter, using the commands in
  `docs/process/testing.md` / `testing.local.md`; sanitization scan per the repo's rules.
- Regressions: same area → reopen the original with a `## Regression` comment and the
  `regression` label; different area → new bug with `regression`, citing the PR.

## Templates and formats

GitHub- and chat-facing bodies live in [references/templates/](references/templates/) —
this list is exhaustive, so a template added later belongs here too: `issue-bug`,
`issue-enhancement`, `issue-chore`, `issue-epic`, `issue-validation-epic`,
`milestone-description`, `epic-event`, `pr-body`, `fixes-applied`, `issue-metrics`,
`scope-note`, `implementer`, `fix-round`, `review-dispatch`, `validation-dispatch`,
`brief`, `handoff`, `session-card`. Machine-read records live in
[references/formats/](references/formats/): `session-log`, `claim`,
`maintenance-report`, `validation-log`. Fill every section; the structure is what lets
the owner read every session the same way. Prose inside sections is yours. Skill text
states rules, never their provenance — dated rulings, session references and
repo-specific issue numbers live on the epics' decision threads, not here; illustrative
format and template examples are not provenance. Fenced code blocks and pasteable
one-liners are exempt from prose wrap-width norms — they are copied verbatim, so
wrapping them would break the thing they exist to be pasted as. Elsewhere, wrap to
minimise raggedness against the paragraph's prevailing width, not to greedily fill each
line: a line short only because the next unbreakable atom (a link, inline code span, or
other unsplittable token) would overflow it is not a violation, so the norm cannot be
falsified by an atom's mere length. The same norm applies to comment paragraphs in `.sh`
scripts under `.claude/skills/`, wrapped against each file's own prevailing comment
width — there is no separate rule for scripts. A rewrap changes no words, and the
checkable form of that claim for a `#`-prefixed comment paragraph is
`git diff --word-diff --word-diff-regex='[A-Za-z0-9_.:()|-]+'` over the paragraph being
empty — the regex excludes the comment marker, which a rewrap necessarily relocates and
which a bare `--word-diff` would otherwise report as a changed word. State an
acceptance criterion about a rewrap in that form, never as "word-diff zero".

The rules every dispatched agent follows are single-sourced in
[references/agent-rules.md](references/agent-rules.md) — the `workflow-*` definitions
mirror its blocks verbatim, and a dispatch prompt splices it in directly when a
definition fails to resolve. Environment mapping (local `gh` vs GitHub MCP) is in
[references/github-tools.md](references/github-tools.md); observed failure modes worth
checking for are in [references/failure-modes.md](references/failure-modes.md).
