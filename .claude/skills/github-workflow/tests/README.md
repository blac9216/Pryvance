# github-workflow scripts tests

Hermetic tests for `../scripts/*.sh`. Every test in this directory follows the same
harness shape, first established in `plan-work/tests/test_history.sh` and
`plan-work/tests/test_timeline_classifier.sh` — copy it rather than inventing a new one.
The one exception is `test_agent_rules_drift.sh`, which tests
`../references/agent-rules.md` against `../../../agents/workflow-*.md` rather than a
script: it needs no mocked `gh` (a pure file diff, no network involved) but keeps the
same `report()` / fail-counter and `LANG=C` conventions. It also cross-checks each
definition's `<!-- mirrors: … -->` declaration line against the blocks the file actually
carries, in both directions, so deleting a whole mirrored block fails instead of passing
silently; diffs every `<!-- rubric:<slug> -->` block against the same-slug block in
`../../github-pr-review/SKILL.md`, and fails when a rubric block SKILL.md marks is
mirrored by no definition at all; and fails a definition that opens the same slug twice,
which extraction would otherwise collapse into the later copy.

Its fixtures are mutations rather than mocks: a self-test phase copies the three real
sources into the scratch dir, applies exactly one defect per case — a one-word edit to
either side of a mirrored block, a deleted copy, a duplicated slug — and re-invokes the
script against the copy through `DRIFT_RULES` / `DRIFT_AGENTS_DIR` /
`DRIFT_RUBRIC_SOURCE`, with `DRIFT_SELFTEST=0` on the nested run so it does not recurse.
Each case asserts both the non-zero exit and the diagnostic it expects, so a mutation
that fails the run for an unrelated reason is not counted as proof. Add a case there for
every check added to that file, per [Proving an assertion is
load-bearing](#proving-an-assertion-is-load-bearing-mutation-probe). Anything reporting
through `report()` must run in the current shell — a helper called in a command
substitution sets `fail=1` in a subshell, and the run prints `FAIL:` lines and still
exits 0.

## Shape

- **Mocked `gh` on `PATH`.** Write a fake `gh` executable to a private scratch dir and
  prepend it to `PATH` only for the invocation under test
  (`PATH="$BIN:$PATH" "$SCRIPT_UNDER_TEST" …`). The real `gh` (and the network) must
  never be reachable from the test.
- **Fixtures in a private mktemp dir.** `WORK="$(mktemp -d "${TMPDIR:-/tmp}/<name>-test.XXXXXX")"`
  with a `trap 'rm -rf "$WORK"' EXIT`. Nothing is written outside `$WORK`. Point the
  fixture directory at the mock via an env var the mock reads (e.g.
  `MOCK_GH_FIXTURES`) — never a hardcoded path.
- **The mock routes by endpoint shape**, applies the script's actual `--jq` expression
  against the fixture JSON with the real `jq` binary (`jq -c -r "$jq_expr" "$fixture"` —
  `-r` unquotes scalar results the same way `gh api --jq` does), and refuses any
  non-GET verb (`-X`, `--method=`, or the glued `-XPOST` spelling) rather than silently
  serving a read fixture. Most scripts under test are read-only; for those, a test that
  never proves the mock rejects a write verb hasn't proven the script never issues one.
- **No network, ever.** Nothing in a fixture or in the script under test should reach
  past the mock; a test that could pass by accident against the real API is not
  hermetic.
- **`report()` / fail counter**, not `set -e` abort-on-first-mismatch: accumulate every
  assertion failure via a shared `fail=0; report(){ echo "FAIL: $*" >&2; fail=1; }` and
  exit 1 only at the end, once every check has run — a single run should surface every
  defect, not just the first one.
- **Locale pinning where it matters.** Pin `LANG=C`/`LC_ALL=C` (or `en_US.UTF-8`, if the
  script's own defect class needs it — see `test_timeline_classifier.sh`'s header) and
  say why in a comment.
- **Crash-path diagnostics.** Capture the script's stdout/stderr to files under the
  scratch dir and `cat` them to stderr before reporting a failure, so a crash mid-run
  doesn't race the `EXIT` cleanup trap and lose the log.

## Adding a new script's test

1. Copy `test_preflight.sh`'s structure: fixtures block, mock `gh` heredoc, a
   `run_<script>()` helper that captures stdout/stderr and dumps them on non-zero exit,
   then one assertion block per behavior the script's issue's Acceptance Criteria name.
2. Route only the endpoints your script actually calls — the mock does not need to be
   generic across scripts.
3. If your script needs genuine multi-page coverage (an endpoint where reading only
   page 1 would silently produce a wrong answer), give the mock two fixture files and
   have it concatenate them only when `--paginate` is present — see `test_preflight.sh`'s
   comments fixtures for the pattern. A test that only ever exercises a single page
   cannot catch a future regression that drops `--paginate` from the script.
4. Assert the write-verb refusal directly against the mock (call `gh api -X POST …`
   under `PATH="$BIN:$PATH"` and check it fails) — don't rely on the script under test
   happening to attempt a write on some other path.

## Running

Each test file is self-contained and executable on its own:

```bash
bash .claude/skills/github-workflow/tests/test_preflight.sh
```

Exit 0 with a one-line summary on success; non-zero with `FAIL: …` lines on stderr
(one per failed assertion) on failure. No suite runner exists yet — run the files you
touched directly, or run all of them with:

```bash
for f in .claude/skills/github-workflow/tests/test_*.sh; do bash "$f" || echo "FAILED: $f"; done
```

`test_scripts_executable.sh`'s depth-1 self-test provenance check requires a
Linux-shaped `/proc` (to verify a claimed parent pid is alive). On a host without one it
refuses the depth-1 nonce, which fails that suite **closed** rather than open, but means
the suite exits non-zero there instead of degrading. This is a recorded, deliberate
choice, not a gap: a `ps -o ppid=` fallback would need its own fixture to be
load-bearing per the mutation-probe rule below, and the only cheap way to reach that
fixture is a seam that redirects the liveness check to a fake `/proc` — itself a
forgery vector, since a caller who can redirect the check can fake liveness the same
way it could fake ancestry (#852, #860). Every agent host in this repository is Linux
today, so this requirement is not currently live.

A script under test that writes (not read-only, e.g. `stamp-claim.sh`) needs its mock to
record every mutation call it sees so a refusal path can prove zero mutations were
issued — see `test_stamp_claim.sh`'s `mutations.log` for the pattern.

Negative cases (argument errors, refusals) need the mock on `PATH` exactly as much as the
success paths do: a case that passes only because a guard fires before the first `gh`
call stops being hermetic the moment that guard regresses, and then the real,
authenticated `gh` runs. Route every negative case through one helper that sets
the mock env — `test_board_audit.sh`'s `run_argerr <expected-exit> <label> <args…>` — and
back it with a tripwire: the mock appends every invocation to a call log and marks any
call arriving without the harness env as `UNMOCKED-CONTEXT`, which the end of the suite
asserts never appears. That turns a would-be network call into a named assertion failure,
which is what a mutation probe needs it to be.

`test_session_log_slugs.sh` is a second exception alongside `test_agent_rules_drift.sh`:
it also tests reference docs rather than a script — `../references/formats/session-log.md`'s
five canonical checklist-slug lists against that same file's own worked examples, against
`../references/templates/session-card.md`'s Checklists block, and against the owning-reference
prose checklist for each of the triage/dispatch/report-handling/close checklists — so it
needs no mocked `gh` either, and keeps the same `report()` / fail-counter and `LANG=C`
conventions. `test_evidence_single_source.sh` is a third: a pure read of two reference
files, no script or `gh` call involved. `test_rule_pointer_drift.sh` is a fourth: decision
A2 (spike #285) puts the extraction-vs-interpretation family rule once in
`../references/github-tools.md` § Extraction vs. interpretation, and holds every sibling
skill that ships a `scripts/` directory (read from `../../configure-workflow/manifests/family.json`,
minus `github-workflow` and `github-pr-review`, which hold the rule) to a one-line pointer
at that section in its own `SKILL.md` — `gitlab-workflow`, `interrogate` and
`with-secrets` ship no `scripts/` and carry no pointer, which is the scoping rule working
as intended, not a gap. Same shape again: no `gh` call, `report()` / fail-counter,
`LANG=C`, and a self-test phase mutating scratch copies of the manifest, the canonical
file and each sibling's `SKILL.md`. Every suite in this directory carries the literal
token `UNMOCKED-CONTEXT` somewhere in its file (`grep -L 'UNMOCKED-CONTEXT'
.claude/skills/github-workflow/tests/test_*.sh` returns nothing) — for these four
file-vs-file suites that is a one-line comment stating the exemption explicitly, since
there is no mock to wire a tripwire into; every other suite carries the live mechanism
described below.

## Proving an assertion is load-bearing (mutation probe)

A check with no failing fixture is not known to be load-bearing: an assertion that only
checks a trailer, summary or count can pass after the behavior it guards has been
deleted. Before trusting a new guard's test, mutate a throwaway copy of the thing under
test — comment out or invert the one line the guard depends on — and re-run the suite
against that copy; the suite must fail. `test_board_audit.sh`'s `--max-rows`
bullet-count assertions, its `updated_at` walk-bound filter, and its `actor_filter`
exclusion target are probed this way, and `test_agent_rules_drift.sh`'s self-test phase
is the same probe applied to a file diff.

`test_post_comment.sh` is the third writer suite, and the shape to copy when the script
under test *writes and then reads its own write back*. Its mock records every `gh api`
invocation to `calls.log`, so each of the refusal paths proves zero calls were issued —
the refuse-before-any-write contract — while the success paths assert the exact call
count (POST + read-back GET). Beyond recording, the mock also **serves** state: comment
id → stored body, plus the id's owning issue/PR number, one file per id under
`$MOCK_GH_STATE`. That is what lets the suite reproduce the very defect the script
guards (`MOCK_GH_STORE_LITERAL=1` stores the raw `@<path>` argument instead of reading
the file, so the read-back guard can be seen firing) and inject benign `gh` stderr noise
on the POST branch and the GET branch independently, which is how the read-back call's
stream handling is pinned. A writer whose guard depends on what the API stored needs a
mock that can lie about what it stored; a mock that only records calls cannot test that
guard at all.

`test_save_log.sh` follows the same writer-mock pattern for a Contents-API PUT instead
of a GraphQL mutation, with one difference the payload size forces: the PUT body never
arrives as a `-f` argument (a base64 body in a single argv element dies at
MAX_ARG_STRLEN long before the 1 MB bound the script advertises), so the mock refuses
`-f content=` outright — a deliberate regression guard — and instead reads the request
body from the file named by `--input`, exactly as the real API would. Each PUT's
base64 `content` is decoded to its own file, so a test asserts byte-identity with `cmp`
against the real local file rather than re-deriving a hash; `message`, `sha` and the
decoded body/hash are what land in `mutations.log`, never `content` itself. The
zero-PUT proof on the unchanged-content path, the per-PUT `sha` assertion on the
changed-content/conflict-retry paths, and leaving `git hash-object` un-mocked (it is
deterministic and network-free enough to leave real rather than faked) all still apply.
