# Evidence Paths (Step 5 detail)

This reference holds the full mechanics behind [SKILL.md](../SKILL.md)'s Step 5
decision of which evidence path to take — the three paths in full (Skip entirely,
Mechanical trust test, Run tests yourself), the coverage rule that applies on the first
two, and the standing scrutiny points and coverage-waiver rule that apply regardless of
path. Step 5 itself keeps only the decision of which path applies and when; come here
for the exact conditions each path requires.

## Contents

- [Path 1 — Skip entirely](#path-1--skip-entirely)
- [Path 2 — Mechanical trust test](#path-2--mechanical-trust-test)
- [Coverage on the evidence path (Paths 1 and 2)](#coverage-on-the-evidence-path-paths-1-and-2)
- [Path 3 — Run tests yourself (fallback)](#path-3--run-tests-yourself-fallback)
- [Reproduce pass/fail, not exact counts](#reproduce-passfail-not-exact-counts)
- [Standing scrutiny points](#standing-scrutiny-points)
- [Coverage Waiver](#coverage-waiver)

### Path 1 — Skip entirely

Skip local test execution altogether only when **all three** hold:

1. CI is green on the PR's exact current head SHA.
2. The diff touches only surfaces listed in the repo's CI-coverage map — a named
   section in `docs/process/testing.md`. **No CI-coverage map in the repo → no skip**,
   and file the missing map as a process-doc gap (deferred item, Step 8).
3. No finding from Step 3 needs a local run to arbitrate.

The three conditions are conjunctive for cloud reviewers exactly as for local ones.

### Path 2 — Mechanical trust test

No `## Test Evidence` comment for this round at all (older PR, or an
implementer/fix agent that skipped emission) → no manifest to trust-test →
Path 3, symmetric with check 2's no-command degradation below.

**Cloud reviewers** have no disk from which to read a raw log, so check 3 below is
unavailable to them and Path 3 is not reachable at all: a cloud review resolves on
Path 1, or on checks 1 and 2 plus CI status, and otherwise — a missing manifest
included — records the evidence as unarbitrable in-sandbox and relies on CI status.

When skip-entirely does not apply, before running anything yourself, check the
manifest against reality — three checks, purely mechanical, no judgment:

1. Manifest **Head SHA** == the PR's current head SHA (`gh pr view <N> --json
   headRefOid` or the MCP equivalent). A stale manifest (posted before a later push)
   fails this.
2. Manifest **Command** matches the command documented in `docs/process/testing.md`.
   If `testing.md` documents no suite command, this check cannot be arbitrated and
   therefore **fails** — take Path 3 and file the missing command as a process-doc
   gap (deferred item, Step 8). Never record it as vacuously passed. **Exception:**
   when `docs/process/testing.md` states, verbatim, "no suites — review-only" (never
   a reviewer-judged equivalent — not even a pre-existing sentence that only says
   suites are not *required*), the check passes instead when the manifest's
   **Command** is the PR issues' own stated Acceptance-Criteria check commands and
   the manifest's **Env** quotes that no-suites declaration verbatim — the absence is
   then arbitrable by construction rather than a silent permanent failure. Do not
   accept a different `testing.md` clause in its place: the doc may separately carry
   a lint-state phrase (e.g. "not installed — review-only" about a linter) that reads
   similarly but arbitrates the manifest's **Lint state** bullet, not this exception
   — citing the lint phrase alone still fails this check.
3. Manifest **Raw log** — open the path the **Raw log** field names (local reviewers
   only; cloud reviewers skip this check and rely on 1 and 2 plus CI). The field must
   carry the **resolved absolute path**, not the unexpanded `<scratch>` placeholder
   (or any other unexpanded variable) — a manifest naming the literal placeholder
   fails this check, since no such path exists on disk. Otherwise the check passes
   when, and only when, **all four** of the following hold:

   1. The raw log exists at the path stated in the manifest.
   2. Recomputing its hash — `sha256sum` on that file — **equals the manifest's Log
      SHA-256 field exactly**. A missing **Log SHA-256** field fails the same as a
      mismatch: there is nothing to recompute against. Do not substitute reading the
      file's contents for recomputing and comparing the hash.
   3. The log carries the invocation of every command the **Command** field names.
      This is decidable, not a judgment call: for each command in **Command**, the log
      contains that command line itself, verbatim as the field types it — echoed by the
      runner — followed by that command's own output and its `[exit=N]` line, the
      marker `implementer.md`'s recipe and `check-manifest.sh` require. A command that
      legitimately produces no output satisfies this condition the same way: the echoed
      invocation followed immediately by its `[exit=N]` line. Only for a log a script
      did not produce may another runner marker stand in — a blank line, the next
      echoed invocation, or the end of the log. A log that names a command
      only in a prose section header fails this condition — the literal command string
      must appear in the log. A manifest claiming a run its log does not contain fails
      the check the same as a hash mismatch, since there is then nothing in the log to
      arbitrate that claim against.
   4. Where the log asserts a sequence or set equality, it prints the per-index
      comparison — a conclusion the printed output does not support fails check 3.
      For example, a sequence-equality assertion that prints only `MATCH: True`
      rather than the per-index comparison (or both lengths and an explicit length
      assertion) the evidence spec requires does not satisfy this condition; the
      conclusion may still be correct, but it is simply not evidenced, so the
      manifest is not trustable on that check.

   Any of the four failing fails check 3, regardless of how plausible the rest of
   the manifest looks. Nothing further is part of it: whether the path's trailing
   segments match the `evidence/issue<N>/test-r<R>.log` convention is not checked
   here — it is the authors' convention (`implementer.md`'s evidence spec), not a
   reviewer gate.

**All checks pass** → Path 2 holds: evaluate the evidence as given; do **not** re-run
the suite. Record the manifest's **Results** in your Test Results section, attributed to
the manifest and marked as trusted via the mechanical checks.

**Any mismatch, staleness, or a Step-3 finding the evidence cannot arbitrate** → Path 3.

### Coverage on the evidence path (Paths 1 and 2)

When you have not run tests, take coverage from, in order: the manifest's **Coverage**
field, then CI's coverage report on the exact head SHA. The field is required, never
optional, and carries exactly one of two values — each mechanically checkable:

1. **The coverage command that was run**, with its result, when
   `docs/process/testing.md` names one. Accept it as the manifest states it.
2. **`none — <quoted line>`**, quoting the exact line of `docs/process/testing.md`
   that says the repo has no coverage command. Confirm *two* things here, not one:
   that the quoted line exists in `testing.md` verbatim, **and** that the line is that
   doc's statement about coverage. A real line that never mentions coverage does not
   satisfy this — string presence alone is not the check.

When `grep -i coverage docs/process/testing.md` returns nothing, the doc says nothing
about coverage at all. The only accepted value is then exactly
`none — testing doc has no coverage section`, and you verify it by running that grep
and seeing it return nothing — there is no line to quote, so demanding one would be
unsatisfiable.

A **Coverage** value in neither form, or a quoted line failing either half of value 2,
fails the manifest's coverage claim: coverage is unavailable, not proven. Either way
coverage is **explicitly not blocking** on this path — record `n/a — no coverage
command in docs/process/testing.md` in **your own Test Results section**, citing what
you checked, and move on. That `n/a` is the reviewer's value and never a manifest one:
a **Coverage** field carrying it is in neither accepted form and fails value 2. Never
re-run a suite solely to produce a coverage number; that would defeat Paths 1 and 2.

### Path 3 — Run tests yourself (fallback)

Reached only when Path 1 does not apply **and** Path 2's trust test failed. Run only the
tests relevant to the diff — map each changed file to its test files/suites. Run **every
suite you can** (the full-suite fallback) only when the diff's test relevance cannot be
determined at all.

Use the commands and environment from the repo's `docs/process/testing.md` and
`*.local.md` (the dispatch copies them in). If the project has a project-local testing
skill, follow it.

**Unit tests** mock external dependencies; **integration tests** exercise real code
against real dependencies (real network, filesystem, services, etc.). Both must pass.
How the project separates them is up to its testing skill (if any), `CLAUDE.md`, or
convention.

- **Unit tests** — every one you run on this path must pass.
- **Integration tests** — every one you run on this path must pass. Run them however
  the project specifies.
- **Lint** — run the project linter. Discover the command from the project's lint
  config, `CLAUDE.md`, or common manifests (`package.json`, `pyproject.toml`, etc.).
  Any new warning/error introduced by this PR is a finding.
- **Coverage** — enforced on this path, and only when the repo documents a coverage
  command. Generate the report; the PR passes only if coverage **does not regress
  versus the base branch** AND is **at least 80%**. Compare against the base branch
  number, not the PR's own claim. If a diff-relevant run cannot produce a
  whole-project coverage number, say so and fall back to the evidence-path coverage
  rule above rather than expanding the run.

**Baseline coverage handling:** if the base branch's coverage is already below 80%
(e.g., a greenfield repo just starting QA, or an early PR in a coverage-raising
series), do not block on absolute coverage — only on regression. The 80% bar applies
once the project crosses it. The first PR in such a series should generally include or
be followed by a coverage-raising effort.

Any failing test, lint regression, or coverage regression you observe on this path is a
blocker finding.

### Reproduce pass/fail, not exact counts

Whenever you do run tests yourself (Path 3, diff-relevant or full), compare **pass/fail
status**, not exact counts — counts drift as `main` moves between the implementer's run
and yours. A suite that passes with different totals than the manifest's **Results** is
not a mismatch by itself; a suite that fails, or newly fails a case the manifest
reported passing, is.

### Standing scrutiny points

Independent of which path you took, apply these on every review:

- **Absence assertions need a positive self-check.** A claim that something does not
  happen (no leak, no regression, nothing left behind) is not evidence until you show
  the check that would have caught it if it did.
- **Migrations with a backfill need a pre-migration row seeded** before you apply the
  migration, so the backfill path actually runs against real pre-existing data instead
  of an empty table.
- **Splice testing a fixture** — reverting a fix so a fixture can be shown red, then
  restoring it, the instrument for a fixture that cannot tell buggy from fixed — needs
  a restore step that does not reach for a forbidden git command mid-splice, since the
  working tree at that point can legitimately hold an edit the agent still needs. The
  safe recipe and the reason `git checkout --` (and its adjacent forms) is wrong there
  specifically live in `github-workflow/references/agent-rules.md`'s `rule:git` block,
  not here.

### Coverage Waiver

If the PR contains code that genuinely cannot be exercised in the CI environment
(e.g., a PowerShell `if ($IsWindows)` branch, a Python `if sys.platform == 'win32'`
branch, or a JavaScript `if (process.platform === 'win32')` branch, when CI runs on
Linux), the author must include a `## Coverage Waiver` section in the PR body that
lists:

- The specific file:line ranges being waived
- Why they cannot be covered
- How the behavior is verified manually instead

Verify the waiver is legitimate. Anything not in the waiver still counts against the
80% threshold. A missing or vague waiver for code below 80% is a finding.
