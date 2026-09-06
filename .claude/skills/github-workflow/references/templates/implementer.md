# Implementer Dispatch Template

Dispatch with `subagent_type: workflow-implementer`. Background. One agent per issue (or
one cohesive group named explicitly). Standing rules (no-subagents, bounded-wait,
git rules, log filenames, CI gate, quiet reporting) live in the agent definition
(`.claude/agents/workflow-implementer.md`) — do not re-type them here. The one
exception is the evidence-manifest field spec below: it is the emitted artifact's
format, not a standing rule, and is spelled out on purpose. Fill every `<…>`
below from `docs/process` and the `*.local.md` files; copy commands in, do not reference
them.

````text
You are an implementer subagent for <repo> at <abs path>. Read <path to the repo's
sanitization/public-repo rule> first and obey it absolutely. Implement issue #<N> ONLY,
then stop. [Deferred batch: implement issues #<a>, #<b>, #<c> — batch `<unit>`, one
PR, `Closes` each — and nothing else; `<N>` below is the primary issue for evidence and
the worktree name.]

Do NOT touch the main checkout at <path>.
Worktree: `git -C <repo> worktree add <worktree root>/issue-<N> -b <N>-<slug>`.
Scratch: `<scratch root from docs/process>`, under a **uniquely-named subdirectory**
(e.g. `<scratch root>/issue<N>-<short-tag>/`) — never `/tmp` directly, never inside the
repo tree, never a guessable shared name another agent could also pick.
Board: assign #<N> to yourself (`gh issue edit <N> --add-assignee @me`) and set it to **In progress** now: `gh project item-edit --project-id <id>
--id <item id> --field-id <status field> --single-select-option-id <in-progress id>`.
Claim: this work is under claim <claim id>. [Other live claims / parallel agents:
<claim id> owns area:<x> (#…) — do not touch <files/areas>; keep shared-file edits
additive.] [Shared sequence resource: <migration numbers etc.> — verify at branch
time against the tree AND open PRs; state the assumption in the PR body.]

Task: `gh issue view <N>` for the full body and acceptance criteria. Read <epic #E,
design docs, merged PRs and code this builds on — enumerate them>. Scope boundaries:
<what this slice is NOT; sibling issues that own the rest>.

Deliver: <numbered concrete deliverables including the tests that must exist>.
Keep it review-sized (≤ ~400 net LOC / ≤ 15 files); if an honest split is needed, land
<which half> first with `Refs #<N>` and the exact remainder listed.

Testing: <exact unit / integration / lint / sanitize commands with environment>. Before
pushing, hand-check any AC of the shape `grep '<phrase>' <file>` against the resolved
file yourself — the wrap norm can split a phrase across a line break, so the AC's own
grep can silently stop matching. `check-ac-phrases.sh`, which used to automate this, was
retired per the 2026-09-05 owner ruling on #732 (item 2): it read an AC's prose to learn
what phrase to look for, then decided whether that phrase was "present" in another
document's prose — interpretive on both ends. There is no mechanical replacement yet.
[Token discipline: <local-model-delegate paragraph if the repo uses it>.]

Posting comments: every comment you post on an issue or PR — the evidence manifest
below, a correction on another thread, anything — goes through
`bash .claude/skills/github-workflow/scripts/post-comment.sh <issue-or-pr> <body-file>`
from the repo root. Compose the body in a file first; the script refuses a body that is
a bare `@`-prefixed path, posts with `-F body=@<file>`, reads the comment back, and
prints its URL. Never `gh … --body "@<path>"` — `@` has no meaning to `--body` and the
literal path is posted silently. In a cloud-sandbox dispatch, where the script is
unavailable, post with `gh api … -F body=@<file>` or the `add_issue_comment` MCP tool
and re-read the posted comment yourself before trusting it.

Evidence: after the suite run, post a `## Test Evidence — round 0` PR comment (a
manifest, not prose) with these fields, computed from the run you just did, through
`post-comment.sh` as above. A field this spec marks
optional may be omitted entirely when it does not apply; any other field you are
emitting whose value you cannot know is written as explicit `null` — never estimated.
(Same rule governs the reviewer role's `helpers[].tokens` in `issue-metrics.md` — keep
both consistent if you touch either.)

Generate the manifest from the run; do not compose it from memory afterwards — every
value below is read back out of the log the runner wrote. **Use the recipe below.** It
is the default, not a suggestion an agent departs from casually: `check-manifest.sh`
enforces the *output shape* the recipe produces by construction, not merely the prose
spec above it, so a runner of your own devising is correct only insofar as it reproduces
that shape exactly. Departing from the recipe is a deliberate choice, made only when the
recipe itself cannot fit the task, and even then the replacement runner must still
reproduce every property below — this is not an escape hatch from them. Three properties
have each independently cost a real PR a repost, so name them once, here, rather than
leaving them implicit in the checker's diagnostics:

1. **Field colon.** Every manifest field is written `- **<Field>**:` (or the unbolded
   `- <Field>:`), and a bare em-dash form (`- **<Field>** — <value>`) is also accepted —
   the checker's field regex matches a bullet ending `:`, ` —`, or `: —` after the field
   name. What it does NOT match is a bullet with none of those — `- **Command** value`
   with no colon and no dash is invisible to it and reads as the field never having been
   emitted at all.
2. **Env on one physical line.** The **Env** field's value is a single line of text; the
   checker's field parser reads only that first physical line, so wrapping the value
   across a second line silently truncates it rather than erroring.
3. **The `$ <command>` / `[exit=N]` log shape.** The raw log echoes each command on its
   own line, either bare or prefixed with a runner's own prompt (`$ `, `+ `, or `> `),
   and follows it with its own `[exit=N]` marker before the next command starts. This is
   what the `commands` and `exit-count` checks read the log for; a log shaped any other
   way (a `set -x` trace, a `=== $ cmd` / `--- exit=N` banner, a bare command name in a
   prose section header) is unreadable to those checks regardless of how honest its
   contents are.

**Head SHA**, **Raw log** and **Coverage** are governed by `agent-rules.md`'s Evidence
rule, which your definition mirrors; the bullets carry only how each value is written as
a manifest field.

- **Command** — one bullet per command, each a literal command line that runs as
  written: fully expanded (no `$VAR`, no `~`, no `<placeholder>`), quoted exactly as it
  was typed, never a prose paraphrase of a composite step ("the link check over the
  touched files") and never a `&&` chain standing in for several commands. Build this
  field *from the log* — the lines the runner echoed are the field — rather than typing
  it out again, so field and log cannot disagree. The reviewer's Step 5 trust test
  (`github-pr-review/references/evidence-paths.md`, Path 2 check 3, condition 3)
  matches each entry against the log verbatim, so an entry the log renders differently —
  a flag dropped, quoting changed, a path abbreviated — fails a manifest that is
  otherwise honest. The entries must be the commands `docs/process/testing.md` documents:
  the reviewer's check 2 matches this field against that doc, and a command of your own
  choosing in its place fails there however faithfully the log echoes it. Where
  `docs/process/testing.md` documents no suite command but states, verbatim, "no suites —
  review-only", that check passes instead when this field carries the PR issues' own
  stated Acceptance-Criteria check commands and **Env** quotes that declaration verbatim
  — so in that repo the issues' AC commands are what belongs here. Four consequences
  worth stating outright:
  - A command that legitimately produces no output satisfies the check the same way: the
    echoed invocation followed immediately by the runner's own next marker — a recorded
    exit code, a blank line, the next echoed invocation, or the end of the log — is a
    complete rendering of an empty output, not a missing one. End of log is a marker like
    the others: a runner that records neither an exit line nor a trailing blank one leaves
    the last command's empty output with nothing after it, and the reviewer reads that one
    position as an empty output rather than a missing invocation. Most checks here are
    absence greps, so this is the common case; the recipe's `[exit=N]` marker supplies that
    next marker by construction, including for the final command.
  - A loop or a wrapper script is not one command. List the invocations it expanded to,
    each echoed on its own line, because the loop line itself produced no output for the
    reviewer to match.
  - Before posting, confirm each entry with `grep -qF '<entry>' <log>`. That is the same
    comparison the reviewer makes, and it also catches an entry that was listed but
    never actually run.
  - Wrap each entry in a code span that survives the command's own characters — the
    bullet's counterpart of the footer's `jq -n --arg` rule below. A single-backtick span
    closes at the first backtick the command contains, so a command carrying one renders
    as a code span, then prose, then a second span, and a reviewer who copies that bullet
    compares mangled text against an honest log. Wrap a command containing a backtick in
    a two-backtick span with one padding space inside each fence, which is how CommonMark
    lets a code span hold a backtick; widen the fence by one backtick again for a command
    carrying a literal two-backtick run. The recipe below picks the width by
    construction, so a hand-typed bullet is the only place this can go wrong.
- **Env** — one-line summary of the environment (runtime/tool versions, OS, relevant
  env vars) — enough for a reviewer to judge whether it matches theirs. Take the
  versions from the run's own probe output in the log (`uname -a`, `<tool> --version`),
  never from memory: a version the log contradicts is the same defect as a retyped
  digest. When `docs/process/testing.md` declares no suite command (e.g. "no suites —
  review-only"), quote that declaration here **verbatim** — this is what lets the
  reviewer's Command check pass by construction instead of failing for lack of a
  command to arbitrate against. Quote the doc's own **Declaration** sentence and nothing
  else: the same doc carries two look-alikes that read alike and sit within a few lines
  of it, and the reviewer's check 2 excludes both by name, so quoting either fails a
  manifest whose every other claim is true.
  - The first is a pre-existing sentence saying only that suites are not *required*
    (e.g. "no test suites and no CI checks are required on PRs"). That states a policy
    about what a PR must carry; the exception keys off the declaration that there is no
    suite command to arbitrate against, which is a different claim.
  - The second is any conditional **Lint state** phrase the doc also carries (e.g. "not
    installed — review-only" about a linter). That one arbitrates the **Lint state**
    bullet instead; quoting it alone does not satisfy this.

  Find the right line mechanically rather than by eye:
  `grep -n 'no suites — review-only' docs/process/testing.md` names it, and neither
  look-alike matches that phrase.
- **Head SHA** — per `agent-rules.md`'s Evidence rule: the pushed, committed head at
  run time. Record it as the full 40-character SHA in a code span, not an
  abbreviation — the reviewer compares this field against the PR's head SHA exactly.
- **Exit code** — copied from the log's own exit markers, in **Command** order, one
  entry per command. Every non-zero entry is named as expected or not, and why. **The
  shape depends on whether any entry carries an annotation:**
  - **Annotated — one entry per sub-bullet.** As soon as any entry carries prose of its
    own, the whole field is written as an indented sub-bullet list, one entry per line,
    in **Command** order. This is what the recipe below emits by construction
    (`sed 's/^/  - /' "$LOG.exits"`, then annotate the lines that need it):

    ```markdown
    - Exit code:
      - 0
      - 1 (expected — `command -v` probe, neither linter installed)
    ```

  - **Bare — an inline list is fine.** A list carrying no annotation at all may stay
    inline: `0, 0, 1, 0`, or just `0` for a single command. Nothing has to be parsed out
    of prose, so there is nothing to get wrong.
  - **Annotated *and* inline is a manifest defect**, and is reported as one rather than
    parsed or guessed at — `check-manifest.sh`'s `exit-count` check fails a manifest
    written that way, and the fix is to re-post it in the sub-bullet form above. The
    reason is that counting inline entries means splitting on the commas that separate
    them while ignoring the commas inside annotations, and annotation prose routinely
    carries both (`0 — clean, lines 7, 9, 12 matched`). No rule reliably tells the two
    apart, and the failure that matters is the silent one: an entry inflated out of
    prose covers for a missing entry, so a command that exited non-zero reads as clean —
    exactly the drift this field exists to catch. One entry per sub-bullet removes the
    separator, and with it the ambiguity.

  The aggregate form `0 (every command above)` is available only when every marker really
  is `0`; a summary the log contradicts is exactly the drift this field is written to
  prevent. Being the whole field rather than an entry within a list, it stays inline.
  A command that exits non-zero by design — an empty-expectation `grep`, a `command -v`
  probe for a binary that is not installed — is named as expected here, so the reviewer
  arbitrating the manifest against `github-pr-review`'s verdict rules reads a named
  expectation rather than a failing suite.
- **Results** — pass/fail/skip counts as the runner reports them.
  A check that asserts two sequences are equal must **print the comparison, not only its
  conclusion**: a per-index `diff` of the two extracted lists (or, at minimum, both
  lengths plus an explicit length assertion) has to appear in the raw log. A bare
  `MATCH: True` under two lists of visibly different lengths proves nothing — a
  length-truncating comparison prints the same line for a genuine mismatch — and a
  reviewer's trust test reads the log's output, not the code that produced it.
- **Log SHA-256** — `sha256sum <log> | cut -d' ' -f1`, interpolated into the manifest by
  the generating step, never retyped or abbreviated from a hash you read on screen. The
  reviewer recomputes this digest and compares it character for character, so one
  dropped character fails a manifest whose every claim was true. Self-check before
  posting: the value is 64 lowercase hex characters.
- **Raw log** — per `agent-rules.md`'s Evidence rule, which fixes the log's name, its
  owner per round, and the requirement that this field carry the **resolved absolute
  path**. What matters at the manifest: local reviewers open the path straight from this
  field, so it has to be a path they can open, while cloud reviewers never see the file
  and work from the manifest plus CI alone. That asymmetry is why an unexpanded
  placeholder is fatal rather than untidy — it leaves neither kind of reviewer anything
  to check.
- **Lint state** — when `docs/process/testing.md` requires a lint-state line (a
  conditional linter, e.g. "run X if installed, otherwise say so"), include it, naming
  the binary that ran or stating explicitly that none is installed
  (`check-manifest.sh --lint installed` or `--lint not-installed`, per whichever holds).
  Omit only when `docs/process/testing.md` names no linter at all
  (`check-manifest.sh --lint none`, which reports the field n/a rather than requiring
  it — the same two-way split this bullet draws, taken as a mandatory argument instead
  of re-derived by fetching and pattern-matching the doc). The line carries exactly two
  things and nothing else: `testing.md`'s own prescribed phrase, quoted verbatim, and
  the probe results in the literal form `` `command -v <bin>` → exit `<code>` ``, one
  per binary the doc names. No paraphrase of why, and no further claim about the diff
  (which files changed, whether any `.md` was touched) — the reviewer derives those
  from the diff itself, and a supporting claim on this line is one more thing to
  falsify. Example: `not installed — review-only (`command -v markdownlint` → exit 1;
  `command -v markdownlint-cli2` → exit 1)`.
- **Coverage** — **required**, never optional. `agent-rules.md`'s Evidence rule states
  the two values it may carry and the grep that decides between them; the testing
  documentation it speaks of is `docs/process/testing.md` in this repo, so run the grep
  against that file. Two manifest-local points the rule does not cover: never invent a
  line that is not there — the reviewer re-runs the same grep and a quoted line that
  does not exist reads as a fabricated field, not a typo. And `n/a — no coverage command
  in docs/process/testing.md` is a *reviewer's* value, written in its own Test Results
  section when it did not run the suite; this field never carries it.

Any claim you make about **another PR's or issue's outcome** — in this manifest, in the
PR body, or in any comment you post — carries the permalink to the comment that
establishes it, per the pr-body template's **Claims about another PR or issue**. Read
that comment and the line you are relying on first; with no permalink to cite, drop the
claim instead of asserting it.

Close the manifest with a `<!-- evidence {"issue","round","head","exit","log","sha256",
"command"} -->` footer, filled from the same run — a heading typo (`## Test Evidenc —
round 0`, a wrong round number) silently drops the round from a regex-only reader, and
this footer is what `preflight.sh` and other machine consumers read first, falling back
to the bullet list only when a footer is absent. `issue` is the dispatch prompt's
primary issue (the one you were told to implement); `log` is the same resolved absolute
path as the **Raw log** bullet; `sha256` mirrors **Log SHA-256** exactly. `exit` stays a
single number so machine readers keep a stable type: `0` when every command exited as
the **Exit code** field says it was expected to, otherwise the first unexpected non-zero
code — the per-command detail lives in the visible field, not here. A command marked
`expected` that exits `0` anyway leaves this key at `0`; say what happened on the
visible **Exit code** field, on its own sub-bullet (`0 — the \`command -v\` probe was
expected to fail, but markdownlint is installed here`).

`command` is the canonical record of the command list: the **Command** bullets'
literal lines, in run order, joined with `; ` — never a paraphrase, never a shortened
path, never a pointer such as "see Command field above". The separator is `; ` and not
` && ` so the string stays runnable end to end: a `&&` chain stops at the first command
that exits non-zero, and a `command -v` probe or an empty-expectation `grep` exits
non-zero by design, so a `&&`-joined value would not re-run what the manifest says was
run. Emit the footer with `jq -n --arg` (see the recipe) rather than writing the JSON by
hand — a command containing a backtick, a quote or a backslash turns into an invalid
escape when it is hand-interpolated, and a footer that does not parse is read as no
manifest at all — then confirm it with `jq -e`. Keep these seven keys stable across
future edits to this template — any breaking change to their names or meaning adds an
explicit `"v":1` (absent today means version 1) and bumps it from there.

Default recipe — a runner that makes each of the rules above hold by construction.
`run` echoes the command exactly as the manifest will type it, then its output, then its
own exit marker; the bullets, exit list, digest and footer are all read back out of the
log rather than recalled. The `if`/`else` around `eval` keeps a by-design non-zero exit from tripping
`set -e`; the `$LOG.cmds` and `$LOG.exits` sidecars are the source of the Command
bullets and the Exit code list, because a command's own output can print a line that
looks like an echoed invocation or an exit marker. `run` takes an optional `$2` of
`expected` to mark a command whose non-zero exit is by design, so the footer's `exit`
key is computed from the collected markers instead of hardcoded:

```sh
set -euo pipefail
LOG=<scratch>/evidence/issue<N>/test-r0.log; mkdir -p "$(dirname "$LOG")"
: >"$LOG"; : >"$LOG.cmds"; : >"$LOG.exits"
AGG_EXIT=0
run() {  # $1 is the literal command line, quoted exactly as the manifest will carry it
         # $2 = "expected" when a non-zero exit here is by design (never counted below)
  printf '$ %s\n' "$1" >>"$LOG"; printf '%s\n' "$1" >>"$LOG.cmds"
  if eval "$1" >>"$LOG" 2>&1; then rc=0; else rc=$?; fi
  printf '[exit=%d]\n' "$rc" >>"$LOG"; printf '%d\n' "$rc" >>"$LOG.exits"
  if [ "$rc" -ne 0 ] && [ "${2:-}" != expected ] && [ "$AGG_EXIT" -eq 0 ]; then AGG_EXIT=$rc; fi
}
run "grep -n 'no suites — review-only' docs/process/testing.md"
run "command -v markdownlint markdownlint-cli2" expected

# The Command bullets, indented to match the template's `- Command:` sub-bullets, each
# in a code span one backtick wider than the longest backtick run the command contains
# — a single-backtick span would close early on a command carrying a backtick.
awk '{ n = 0; s = $0
       while (match(s, /`+/)) { if (RLENGTH > n) n = RLENGTH; s = substr(s, RSTART + RLENGTH) }
       f = ""; for (i = 0; i <= n; i++) f = f "`"
       if (n > 0) printf "  - %s %s %s\n", f, $0, f; else printf "  - %s%s%s\n", f, $0, f }' \
  "$LOG.cmds"
sed 's/^/  - /' "$LOG.exits"                   # the Exit code list, in Command order, from
                                                # the sidecar — never grepped back out of
                                                # "$LOG", where a command's own output can
                                                # print an "[exit=" line of its own
SHA=$(sha256sum "$LOG" | cut -d' ' -f1)        # never retyped
CMD=$(awk '{printf "%s%s", sep, $0; sep="; "} END {print ""}' "$LOG.cmds")
jq -cn --argjson issue <N> --argjson round 0 --arg head "$(git rev-parse HEAD)" \
  --argjson exit "$AGG_EXIT" --arg log "$LOG" --arg sha "$SHA" --arg command "$CMD" \
  '{issue:$issue,round:$round,head:$head,exit:$exit,log:$log,sha256:$sha,command:$command}'
```

Worked check of the two generators, on a run whose first command prints a line that
looks like an exit marker and whose second bullet carries a backtick — the two shapes
that broke the earlier one-liners. Two commands run; the log holds three `[exit=`-prefixed
lines, one of them the first command's own output, so a `grep '^\[exit=' "$LOG"` read-back
would report three exits against two commands and misalign the field from that point on.
The sidecar reports two, and the bullet's fence widens to survive the backtick:

```text
$ run "printf '[exit=99]\n'"; run "grep -c 'no suites' docs/process/testing.md"
grep -c '^\[exit=' "$LOG"   -> 3      # what the log holds: 2 markers + 1 phantom
wc -l < "$LOG.exits"        -> 2      # what the sidecar holds: one per command
sed 's/^/  - /' "$LOG.exits"          # the Exit code list the manifest carries
  - 0
  - 0
```

The bullet generator, over a command containing a backtick, widens the span rather than
closing it early:

```text
  - `` grep -n 'a `backtick` phrase' docs/process/testing.md ``
```

Worked example of the footer that recipe emits, for a command list whose second member
exits non-zero by design and whose first carries a backtick — `jq -n --arg` escapes it,
so the footer still parses:

```json
{"issue":42,"round":0,"head":"0f1e2d3c4b5a69788796a5b4c3d2e1f009182736","exit":0,"log":"/home/agent/scratch/evidence/issue42/test-r0.log","sha256":"3b1f0c9d5e2a47b8c6d0e1f2a3b4c5d6e7f80912a3b4c5d6e7f8091a2b3c4d5e","command":"grep -n 'a `backtick` phrase' docs/process/testing.md; command -v markdownlint markdownlint-cli2"}
```

```markdown
## Test Evidence — round 0
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
- Raw log: `/home/agent/scratch/evidence/issue<N>/test-r0.log`
- Lint state: markdownlint installed — clean (or: not installed — review-only)
- Coverage: 84.2% (base 83.9%)   (or: none — testing doc has no coverage section)

<!-- evidence {"issue":<N>,"round":0,"head":"<40-char sha>","exit":0,"log":"/home/agent/scratch/evidence/issue<N>/test-r0.log","sha256":"<64-hex digest>","command":"<cmd one>; <cmd two>"} -->
```

Then, as the last step of posting evidence, run the checker against your own PR:

```sh
bash .claude/skills/github-workflow/scripts/check-manifest.sh <your PR> --lint installed|not-installed|none
```

`--lint` is mandatory (#748): pass `installed` or `not-installed` per whichever this
round's own **Lint state** bullet actually says, or `none` when
`docs/process/testing.md` names no linter at all (the field is then n/a, never
required) — the checker no longer re-fetches `docs/process/testing.md` to decide this
itself.

It is read-only and re-runs, mechanically, the checks the reviewer's trust test
(`github-pr-review/references/evidence-paths.md`, Path 2) makes by hand: every required
bullet present, the footer parsing with its seven keys and agreeing with the visible
bullets, **Head SHA** equal to the PR's current head, **Raw log** an expanded absolute
path, **Log SHA-256** matching the file, every **Command** entry echoed in the log with
its own `[exit=N]`, and **Env** quoting the right one of the three look-alike sentences.
Run it after the push and after posting, not before: two of those checks compare the
manifest against the PR as it now stands, and neither can be answered from a working
tree. A `FAIL` here is a defect the reviewer would otherwise find at the cost of a full
redundant re-run — fix it, re-run the suite if the fix changed the tree, and re-post.
Exit `3` is not a pass either: it means nothing FAILed but at least one check could not
run, which on your own machine means the **Raw log** bullet does not name the file you
actually wrote.

Run `check-test-steps.sh --check-shas` over the PR body too — `--body-file` works before
you post it, which is the cheaper moment; without `--check-shas` this script now checks
nothing at all:

```sh
bash .claude/skills/github-workflow/scripts/check-test-steps.sh --body-file <body.md> --check-shas
```

It reports any 40-hex commit SHA named anywhere in the body (a `## Rollback` command, a
mutation-probe summary) that is not an ancestor of the current head — the gap a
mid-review rebase or force-push can leave behind (issue #640). Hand-check your own step
list against `pr-body.md`'s moving-ref rule (three-dot ranges are exempt) yourself; that
half is no longer mechanically checked.

Deferred items: anything you notice and do not fix — "out of scope", "pre-existing",
"noted", "later" — gets an issue (dup-scan first) per SKILL.md's Deferred Items rule:
type + `deferred` + `concern:*` + `area:*`, a `Spawned by #<N>` line in the Home
section followed on the next line by the required `Unit:` line (one repo-relative file
path, one repo-relative directory path ending in `/`, or one `area:*` label — that rule
states its exact form and how to choose the value), milestone when one applies, no epic
parent. List them in your report.

When green: push; open a PR (NOT draft) titled `<type>(<scope>): <desc>` with body per
the pr-body template (Suggested Test Steps you ACTUALLY ran, Risk, Rollback, Verified
expectation). `Closes #<N>` on its own line in the PR **body** (or `Refs` + exact
remainder) — for multiple issues, one `Closes #<N>` line per issue; commit messages
alone do not link issues, and a squash-merge can drop them if they aren't in the body.
Mirror the issue labels onto the PR.

Final message: PR number, summary, key decisions, test results, deferred issues filed.
Do not merge. Keep the worktree.

You may be resumed once after this, with a relay. If the reviewer routes `minor`
findings inside your diff as a relay, the orchestrator continues this conversation with
those findings verbatim. On that resume: fix exactly those findings in this same
worktree and nothing else; run the suite, logging to
`<scratch>/evidence/issue<N>/test-r<R>-relay.log`, and post a
`## Test Evidence — round <R> (relay)` manifest for the new head (same fields; `<R>` is
the review round and the footer's `round` stays `<R>`; the `-relay` suffix keeps a later
round-`<R>` fix agent from clobbering it); push to the same
branch (plain push, no force); refresh any count or expected output in the PR body the
fix changed (`gh pr edit <P> --body-file <path>`); post a `## Fixes Applied` comment
through `post-comment.sh` per the fixes-applied template; and reply with the new head
SHA, the commit list and the manifest link. Do not re-read the whole PR, do not touch
findings the relay did not name, and do not file anything new unless the fix itself
surfaced it. That is the only resume you will get; a second set of findings arrives as
a fresh fix-round agent, not as you.
````
