#!/usr/bin/env bash
# test_audit.sh — regression test for audit.sh, the design-docs skill's
# Tier 1 (mechanical) drift auditor. Builds fixture repos per case under a
# private scratch dir under $TMPDIR (or /tmp), runs audit.sh against them,
# and asserts exit status, report contents, and finding codes.
# Self-contained: no network access, no repository content read.
#
# See ../../github-workflow/tests/README.md for this directory's harness
# conventions (report()/fail-counter, mutation-probe rule). audit.sh takes
# no `gh` argument and this suite mocks no `gh`, so — like that README's
# file-vs-script exceptions (test_agent_rules_drift.sh etc.) — it carries
# the UNMOCKED-CONTEXT exemption comment below instead of a live mock
# tripwire.
#
# UNMOCKED-CONTEXT: this suite calls no `gh` — audit.sh (and the
# check-pointers.sh/adr-index.sh it shells out to) operate purely on local
# fixture files, so there is nothing to mock and no tripwire to wire;
# exempt per github-workflow/tests/README.md's UNMOCKED-CONTEXT convention.
#
# Mutation probe: case_missing_root and case_manifest_line_missing below
# are the named probes for #789's finding-not-default change and #790's
# --root-required change respectively — each fails (wrong exit code or
# missing MANIFEST_LINE_MISSING finding) under the pre-change script,
# spliced in as scripts/audit.sh.pre-change during review.
#
# Uses [[:digit:]] rather than [0-9] in any pattern match, per this repo's
# locale-collation-range convention (a bash `[0-9]` range test matches
# non-ASCII digits under a UTF-8 locale).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT_SH="$SCRIPT_DIR/../scripts/audit.sh"
ADR_INDEX_SH="$SCRIPT_DIR/../scripts/adr-index.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/audit-test.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

fail=0
report() { echo "FAIL: $*" >&2; fail=1; case_failed=1; }

# run_case NAME — runs case function NAME, tracking + printing PASS/FAIL for
# just that case (report() may fire multiple times per case; case_failed
# only needs to go from 0 to 1 once).
run_case() {
  local name="$1"
  case_failed=0
  "$name"
  if [ "$case_failed" -eq 0 ]; then
    echo "PASS: $name"
  else
    echo "FAIL: $name"
  fi
}

# make_fixture NAME — creates an empty repo dir under $WORK/fixtures/NAME
# with the standard doc skeleton ready to populate, and echoes its path.
make_fixture() {
  local dir="$WORK/fixtures/$1"
  mkdir -p "$dir/docs/adr" "$dir/docs/rationale" "$dir/docs/tutorials" \
    "$dir/docs/how-to" "$dir/docs/reference" "$dir/docs/explanation" \
    "$dir/docs/process" "$dir/src"
  printf '%s' "$dir"
}

# run_audit FIXTURE_DIR — runs audit.sh against a fixture, writing its
# report to $WORK/<basename>.report.md, capturing stdout/stderr/exit code
# into globals for assertions.
run_audit() {
  local dir="$1"
  local out
  out="$WORK/$(basename "$dir").report.md"
  set +e
  AU_STDOUT=$("$AUDIT_SH" --root "$dir" --out "$out" 2>"$WORK/stderr.log")
  AU_RC=$?
  set -e
  AU_STDERR="$(cat "$WORK/stderr.log")"
  AU_REPORT="$out"
  : "$AU_STDOUT"  # audit.sh's stdout is the report path + summary line; not asserted directly, AU_REPORT is used instead
}

# write_documentation_standard DIR — writes a minimally valid
# docs/doc-manifest.md into DIR, matching templates/doc-manifest.md's
# shape (design set, Diátaxis dirs, ADR dir, rationale areas, glossary).
write_documentation_standard() {
  local dir="$1"
  cat > "$dir/docs/doc-manifest.md" <<'EOF'
# Documentation manifest — as adopted here

## Design set
- docs/explanation/architecture.md
- docs/explanation/domain-model.md
- docs/reference/api-contract.md
- docs/adr/
- docs/rationale/
- CONTEXT.md

## Diátaxis directories
tutorials: docs/tutorials/ · how-to: docs/how-to/ · reference: docs/reference/ · explanation: docs/explanation/
Index: docs/README.md

## ADRs
Directory: docs/adr/

## Rationale areas
- backend → docs/rationale/backend.md

## Glossary
CONTEXT.md at repo root · domain model: docs/explanation/domain-model.md
EOF
}

# write_clean_adr DIR — one fully-formed MADR ADR plus an up-to-date
# generated index, via adr-index.sh --write (never reimplemented here).
write_clean_adr() {
  local dir="$1"
  cat > "$dir/docs/adr/0001-example.md" <<'EOF'
# ADR-0001: Example decision

Status: Accepted
Date: 2026-01-01

## Context

Text.

## Decision Drivers

- driver

## Considered Options

1. **Option** — pro; con.

## Decision

Chose option.

## Consequences

- consequence
EOF
  cat > "$dir/docs/adr/README.md" <<'EOF'
# ADRs

<!-- adr-index:start -->
<!-- adr-index:end -->
EOF
  "$ADR_INDEX_SH" --root "$dir" --adr-dir "$dir/docs/adr" --write >/dev/null
}

# ---------------------------------------------------------------------------
# Case: adopted-clean fixture — exit 0, report exists, "Tier 1 findings: 0".
# ---------------------------------------------------------------------------
case_adopted_clean() {
  local dir; dir="$(make_fixture clean)"
  write_documentation_standard "$dir"
  write_clean_adr "$dir"

  cat > "$dir/docs/rationale/backend.md" <<'EOF'
## app.py

### backend-example

Line one of reasoning.
Line two of reasoning.

Refs: #1
EOF
  cat > "$dir/src/app.py" <<'EOF'
# why: docs/rationale/backend.md#backend-example
x = 1
EOF

  cat > "$dir/docs/explanation/architecture.md" <<'EOF'
# Architecture

Kind: explanation

## Context

```mermaid
graph TD; A-->B;
```

## Container

```mermaid
graph TD; A-->B;
```

## Component

```mermaid
graph TD; A-->B;
```
EOF
  cat > "$dir/docs/explanation/domain-model.md" <<'EOF'
# Domain model

Kind: explanation

**Widget** is a thing.
EOF
  cat > "$dir/docs/reference/api-contract.md" <<'EOF'
# API contract

Kind: reference

Body.
EOF
  cat > "$dir/CONTEXT.md" <<'EOF'
# CONTEXT.md — glossary

## Terms

**Widget** — a thing.
EOF
  cat > "$dir/docs/README.md" <<'EOF'
# Docs index

- [architecture](explanation/architecture.md)
- [domain-model](explanation/domain-model.md)
- [api-contract](reference/api-contract.md)
EOF

  run_audit "$dir"
  [ "$AU_RC" -eq 0 ] || report "adopted_clean: expected exit 0, got $AU_RC (stderr: $AU_STDERR)"
  [ -f "$AU_REPORT" ] || report "adopted_clean: expected report file at $AU_REPORT"
  grep -qF "Tier 1 findings: 0" "$AU_REPORT" || report "adopted_clean: expected 'Tier 1 findings: 0' in report, got: $(cat "$AU_REPORT" 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# Case: not-adopted fixture (no docs/doc-manifest.md) — exit 2.
# ---------------------------------------------------------------------------
case_not_adopted() {
  local dir; dir="$(make_fixture notadopted)"
  run_audit "$dir"
  [ "$AU_RC" -eq 2 ] || report "not_adopted: expected exit 2, got $AU_RC"
  grep -qF "not adopted" <<<"$AU_STDERR" || report "not_adopted: expected 'not adopted' on stderr, got: $AU_STDERR"
  [ -f "$AU_REPORT" ] || report "not_adopted: expected a minimal report to still be written"
  grep -qiF "doc-manifest.md" "$AU_REPORT" || report "not_adopted: expected report to mention doc-manifest.md, got: $(cat "$AU_REPORT" 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# Case: usage error — missing --out.
# ---------------------------------------------------------------------------
case_usage_error() {
  local dir; dir="$(make_fixture usage)"
  set +e
  "$AUDIT_SH" --root "$dir" >/dev/null 2>"$WORK/usage.err"
  local rc=$?
  set -e
  [ "$rc" -eq 2 ] || report "usage_error: expected exit 2, got $rc"
}

# ---------------------------------------------------------------------------
# Case: usage error — missing --root, naming the flag (before reading
# anything: no docs/doc-manifest.md is written for this fixture).
# ---------------------------------------------------------------------------
case_missing_root() {
  local out="$WORK/missing-root.report.md"
  set +e
  "$AUDIT_SH" --out "$out" >/dev/null 2>"$WORK/missing-root.err"
  local rc=$?
  set -e
  [ "$rc" -eq 2 ] || report "missing_root: expected exit 2, got $rc"
  grep -qF -- "--root" "$WORK/missing-root.err" || report "missing_root: expected the error to name --root, got: $(cat "$WORK/missing-root.err")"
  [ -f "$out" ] || : # nothing should have been written; absence is fine, not asserted either way
}

# ---------------------------------------------------------------------------
# Case: each doc-manifest.md line/section audit.sh reads is a
# MANIFEST_LINE_MISSING finding (exit 1) when absent — never a silent
# default. One sub-fixture per removed line, built by deleting exactly
# that line/section from an otherwise-valid write_documentation_standard()
# manifest. This is the named mutation probe for #789: each sub-case fails
# (no MANIFEST_LINE_MISSING, or a wrongly-defaulted value) under the
# pre-change script, which defaulted the Glossary and ADR Directory lines
# and merely NOTEd the rest.
# ---------------------------------------------------------------------------
case_manifest_line_missing() {
  local dir manifest

  # 1. "## Design set" section missing entirely.
  dir="$(make_fixture mlm-designset)"
  write_documentation_standard "$dir"
  manifest="$dir/docs/doc-manifest.md"
  sed -i '/^## Design set$/,/^## Diátaxis directories$/{/^## Diátaxis directories$/!d}' "$manifest"
  run_audit "$dir"
  [ "$AU_RC" -eq 1 ] || report "mlm-designset: expected exit 1, got $AU_RC"
  grep -qF "MANIFEST_LINE_MISSING" <<<"$AU_STDERR" || report "mlm-designset: expected MANIFEST_LINE_MISSING, got: $AU_STDERR"
  grep -qiF "design set" <<<"$AU_STDERR" || report "mlm-designset: expected the finding to mention 'Design set', got: $AU_STDERR"

  # 2. Diátaxis directories line missing (heading kept, data line dropped).
  dir="$(make_fixture mlm-diataxis)"
  write_documentation_standard "$dir"
  manifest="$dir/docs/doc-manifest.md"
  sed -i '/^tutorials:.*how-to:.*reference:.*explanation:/d' "$manifest"
  run_audit "$dir"
  [ "$AU_RC" -eq 1 ] || report "mlm-diataxis: expected exit 1, got $AU_RC"
  grep -qiF "MANIFEST_LINE_MISSING" <<<"$AU_STDERR" || report "mlm-diataxis: expected MANIFEST_LINE_MISSING, got: $AU_STDERR"
  grep -qiF "diátaxis" <<<"$AU_STDERR" || report "mlm-diataxis: expected the finding to mention Diátaxis, got: $AU_STDERR"

  # 3. "Index:" line missing.
  dir="$(make_fixture mlm-index)"
  write_documentation_standard "$dir"
  manifest="$dir/docs/doc-manifest.md"
  sed -i '/^Index:/d' "$manifest"
  run_audit "$dir"
  [ "$AU_RC" -eq 1 ] || report "mlm-index: expected exit 1, got $AU_RC"
  grep -qiF "MANIFEST_LINE_MISSING" <<<"$AU_STDERR" || report "mlm-index: expected MANIFEST_LINE_MISSING, got: $AU_STDERR"
  grep -qiF "index" <<<"$AU_STDERR" || report "mlm-index: expected the finding to mention Index, got: $AU_STDERR"

  # 4. "Directory:" line (ADRs) missing — must not silently default to
  # docs/adr/, so the finding fires even though docs/adr/ happens to exist.
  dir="$(make_fixture mlm-adrdir)"
  write_documentation_standard "$dir"
  manifest="$dir/docs/doc-manifest.md"
  sed -i '/^Directory:/d' "$manifest"
  write_clean_adr "$dir"
  run_audit "$dir"
  [ "$AU_RC" -eq 1 ] || report "mlm-adrdir: expected exit 1, got $AU_RC"
  grep -qiF "MANIFEST_LINE_MISSING" <<<"$AU_STDERR" || report "mlm-adrdir: expected MANIFEST_LINE_MISSING, got: $AU_STDERR"
  grep -qiF "directory" <<<"$AU_STDERR" || report "mlm-adrdir: expected the finding to mention Directory, got: $AU_STDERR"
  grep -qF "ADR_NO_DATE" <<<"$AU_STDERR" && report "mlm-adrdir: MADR checks should be skipped (never defaulted to docs/adr/), but got ADR_NO_DATE: $AU_STDERR"

  # 5. "## Rationale areas" section missing.
  dir="$(make_fixture mlm-rationale)"
  write_documentation_standard "$dir"
  manifest="$dir/docs/doc-manifest.md"
  sed -i '/^## Rationale areas$/,/^## Glossary$/{/^## Glossary$/!d}' "$manifest"
  run_audit "$dir"
  [ "$AU_RC" -eq 1 ] || report "mlm-rationale: expected exit 1, got $AU_RC"
  grep -qiF "MANIFEST_LINE_MISSING" <<<"$AU_STDERR" || report "mlm-rationale: expected MANIFEST_LINE_MISSING, got: $AU_STDERR"
  grep -qiF "rationale areas" <<<"$AU_STDERR" || report "mlm-rationale: expected the finding to mention Rationale areas, got: $AU_STDERR"

  # 6. Glossary line missing entirely — must not default to CONTEXT.md.
  dir="$(make_fixture mlm-glossary)"
  write_documentation_standard "$dir"
  manifest="$dir/docs/doc-manifest.md"
  sed -i '/^CONTEXT\.md at repo root/d' "$manifest"
  run_audit "$dir"
  [ "$AU_RC" -eq 1 ] || report "mlm-glossary: expected exit 1, got $AU_RC"
  grep -qiF "MANIFEST_LINE_MISSING" <<<"$AU_STDERR" || report "mlm-glossary: expected MANIFEST_LINE_MISSING, got: $AU_STDERR"
  grep -qiF "glossary" <<<"$AU_STDERR" || report "mlm-glossary: expected the finding to mention Glossary, got: $AU_STDERR"
  grep -qF "GLOSSARY_MISSING" <<<"$AU_STDERR" && report "mlm-glossary: glossary check should be skipped (never defaulted to CONTEXT.md), but got GLOSSARY_MISSING: $AU_STDERR"

  # 7. "domain model:" fragment missing, Glossary line otherwise intact.
  dir="$(make_fixture mlm-domainmodel)"
  write_documentation_standard "$dir"
  manifest="$dir/docs/doc-manifest.md"
  sed -i 's/^CONTEXT\.md at repo root.*/CONTEXT.md at repo root/' "$manifest"
  run_audit "$dir"
  [ "$AU_RC" -eq 1 ] || report "mlm-domainmodel: expected exit 1, got $AU_RC"
  grep -qiF "MANIFEST_LINE_MISSING" <<<"$AU_STDERR" || report "mlm-domainmodel: expected MANIFEST_LINE_MISSING, got: $AU_STDERR"
  grep -qiF "domain model" <<<"$AU_STDERR" || report "mlm-domainmodel: expected the finding to mention 'domain model:', got: $AU_STDERR"
}

# ---------------------------------------------------------------------------
# Case: one fixture triggering every required Tier 1 finding code, plus a
# forwarded ENTRY_NO_REFS from check-pointers.sh. Asserts the report groups
# them under per-code headers.
# ---------------------------------------------------------------------------
case_all_findings() {
  local dir; dir="$(make_fixture findings)"
  write_documentation_standard "$dir"

  # ADR_MISSING_SECTION: drop Decision Drivers/Considered Options/Consequences.
  cat > "$dir/docs/adr/0001-example.md" <<'EOF'
# ADR-0001: Example decision

Status: Accepted
Date: 2026-01-01

## Context

Text.

## Decision

Chose option.
EOF
  cat > "$dir/docs/adr/README.md" <<'EOF'
# ADRs

<!-- adr-index:start -->
<!-- adr-index:end -->
EOF
  "$ADR_INDEX_SH" --root "$dir" --adr-dir "$dir/docs/adr" --write >/dev/null

  # DOC_OUTSIDE_KIND_DIR: a doc directly under docs/, not in a kind dir.
  cat > "$dir/docs/stray.md" <<'EOF'
# Stray

Kind: reference

Body.
EOF

  # DOC_KIND_MISMATCH: Kind: doesn't match its directory.
  cat > "$dir/docs/reference/mismatched.md" <<'EOF'
# Mismatched

Kind: explanation

Body.
EOF

  # ARCH_NO_DIAGRAM: architecture.md's Context level has no mermaid block.
  # Also produces the INDEX_MISSING_DOC finding (not linked from README).
  cat > "$dir/docs/explanation/architecture.md" <<'EOF'
# Architecture

Kind: explanation

## Context

No diagram in this section.

## Container

```mermaid
graph TD; A-->B;
```

## Component

```mermaid
graph TD; A-->B;
```
EOF

  # GLOSSARY_TERM_UNLISTED: domain-model term not in CONTEXT.md.
  cat > "$dir/docs/explanation/domain-model.md" <<'EOF'
# Domain model

Kind: explanation

**Widget** is a thing.
**Gadget** is another thing.
EOF
  cat > "$dir/CONTEXT.md" <<'EOF'
# CONTEXT.md — glossary

## Terms

**Widget** — a thing.
EOF

  # INDEX_MISSING_DOC: README does not link mismatched.md or architecture.md.
  cat > "$dir/docs/README.md" <<'EOF'
# Docs index

- [domain-model](explanation/domain-model.md)
EOF

  # DESIGNSET_MISSING: docs/reference/api-contract.md is listed but absent.

  # ENTRY_NO_REFS, forwarded verbatim from check-pointers.sh.
  cat > "$dir/docs/rationale/backend.md" <<'EOF'
## app.py

### backend-example

Line one of reasoning.
Line two of reasoning.
EOF
  cat > "$dir/src/app.py" <<'EOF'
# why: docs/rationale/backend.md#backend-example
x = 1
EOF

  run_audit "$dir"
  [ "$AU_RC" -eq 1 ] || report "all_findings: expected exit 1, got $AU_RC"

  local report_body
  report_body="$(cat "$AU_REPORT" 2>/dev/null || true)"

  local code
  for code in ADR_MISSING_SECTION DOC_OUTSIDE_KIND_DIR DOC_KIND_MISMATCH \
    INDEX_MISSING_DOC GLOSSARY_TERM_UNLISTED ARCH_NO_DIAGRAM \
    DESIGNSET_MISSING ENTRY_NO_REFS; do
    grep -qF "$code" <<<"$AU_STDERR" || report "all_findings: expected $code on stderr"
    grep -qF "### $code" <<<"$report_body" || report "all_findings: expected report to group findings under '### $code'"
  done
}

# ---------------------------------------------------------------------------
# Case: ADR header block has no Date: line — ADR_NO_DATE.
# ---------------------------------------------------------------------------
case_adr_no_date() {
  local dir; dir="$(make_fixture adr_no_date)"
  write_documentation_standard "$dir"

  cat > "$dir/docs/adr/0001-example.md" <<'EOF'
# ADR-0001: Example decision

Status: Accepted

## Context

Text.

## Decision Drivers

- driver

## Considered Options

1. **Option** — pro; con.

## Decision

Chose option.

## Consequences

- consequence
EOF
  cat > "$dir/docs/adr/README.md" <<'EOF'
# ADRs

<!-- adr-index:start -->
<!-- adr-index:end -->
EOF
  "$ADR_INDEX_SH" --root "$dir" --adr-dir "$dir/docs/adr" --write >/dev/null

  run_audit "$dir"
  [ "$AU_RC" -eq 1 ] || report "adr_no_date: expected exit 1, got $AU_RC"
  grep -qF "ADR_NO_DATE" <<<"$AU_STDERR" || report "adr_no_date: expected ADR_NO_DATE on stderr, got: $AU_STDERR"
  grep -qF "### ADR_NO_DATE" "$AU_REPORT" || report "adr_no_date: expected report to group under '### ADR_NO_DATE'"
}

# ---------------------------------------------------------------------------
# Case: a doc inside a Diátaxis kind directory has no Kind: line in its
# first 5 lines — DOC_KIND_MISSING.
# ---------------------------------------------------------------------------
case_doc_kind_missing() {
  local dir; dir="$(make_fixture doc_kind_missing)"
  write_documentation_standard "$dir"
  write_clean_adr "$dir"

  cat > "$dir/docs/how-to/setup.md" <<'EOF'
# Setup

No Kind: line anywhere in this file's opening lines.
EOF

  run_audit "$dir"
  [ "$AU_RC" -eq 1 ] || report "doc_kind_missing: expected exit 1, got $AU_RC"
  grep -qF "DOC_KIND_MISSING" <<<"$AU_STDERR" || report "doc_kind_missing: expected DOC_KIND_MISSING on stderr, got: $AU_STDERR"
  grep -qF "### DOC_KIND_MISSING" "$AU_REPORT" || report "doc_kind_missing: expected report to group under '### DOC_KIND_MISSING'"
}

# ---------------------------------------------------------------------------
# Case: the index links a .md target that does not exist — INDEX_DEAD_LINK.
# ---------------------------------------------------------------------------
case_index_dead_link() {
  local dir; dir="$(make_fixture index_dead_link)"
  write_documentation_standard "$dir"
  write_clean_adr "$dir"

  cat > "$dir/docs/README.md" <<'EOF'
# Docs index

- [missing](explanation/missing.md)
EOF

  run_audit "$dir"
  [ "$AU_RC" -eq 1 ] || report "index_dead_link: expected exit 1, got $AU_RC"
  grep -qF "INDEX_DEAD_LINK" <<<"$AU_STDERR" || report "index_dead_link: expected INDEX_DEAD_LINK on stderr, got: $AU_STDERR"
  grep -qF "### INDEX_DEAD_LINK" "$AU_REPORT" || report "index_dead_link: expected report to group under '### INDEX_DEAD_LINK'"
}

# ---------------------------------------------------------------------------
# Case: a link inside an HTML comment (e.g. the template's commented-out
# placeholder rows) is not a real link — no INDEX_DEAD_LINK even though its
# target does not exist. Also covers a multi-line comment block.
# ---------------------------------------------------------------------------
case_index_dead_link_in_comment() {
  local dir; dir="$(make_fixture index_dead_link_in_comment)"
  write_documentation_standard "$dir"
  write_clean_adr "$dir"

  cat > "$dir/docs/README.md" <<'EOF'
# Docs index

## Tutorials
<!-- - [Title](tutorials/file.md) — one line -->

## How-to
<!--
- [Title](how-to/file.md) — one line
- [Other](how-to/other.md) — another line
-->
EOF

  run_audit "$dir"
  grep -qF "INDEX_DEAD_LINK" <<<"$AU_STDERR" && report "index_dead_link_in_comment: expected no INDEX_DEAD_LINK finding, got: $AU_STDERR"
  return 0
}

# ---------------------------------------------------------------------------
# Case: the glossary file declared by doc-manifest.md does not exist —
# GLOSSARY_MISSING.
# ---------------------------------------------------------------------------
case_glossary_missing() {
  local dir; dir="$(make_fixture glossary_missing)"
  write_documentation_standard "$dir"
  write_clean_adr "$dir"
  # CONTEXT.md deliberately not created.

  run_audit "$dir"
  [ "$AU_RC" -eq 1 ] || report "glossary_missing: expected exit 1, got $AU_RC"
  grep -qF "GLOSSARY_MISSING" <<<"$AU_STDERR" || report "glossary_missing: expected GLOSSARY_MISSING on stderr, got: $AU_STDERR"
  grep -qF "### GLOSSARY_MISSING" "$AU_REPORT" || report "glossary_missing: expected report to group under '### GLOSSARY_MISSING'"
}

# ---------------------------------------------------------------------------
# Case: a glossary with a duplicate term entry and a term entry that leaks
# an implementation-detail (code path) reference — GLOSSARY_DUPLICATE,
# GLOSSARY_IMPLEMENTATION_DETAIL.
# ---------------------------------------------------------------------------
case_glossary_bad_terms() {
  local dir; dir="$(make_fixture glossary_bad_terms)"
  write_documentation_standard "$dir"
  write_clean_adr "$dir"

  cat > "$dir/CONTEXT.md" <<'EOF'
# CONTEXT.md — glossary

## Terms

**Widget** — a thing.
**Widget** — a duplicate thing.
**Config** — see `src/config.cs` for details.
EOF

  run_audit "$dir"
  [ "$AU_RC" -eq 1 ] || report "glossary_bad_terms: expected exit 1, got $AU_RC"

  local report_body
  report_body="$(cat "$AU_REPORT" 2>/dev/null || true)"

  local code
  for code in GLOSSARY_DUPLICATE GLOSSARY_IMPLEMENTATION_DETAIL; do
    grep -qF "$code" <<<"$AU_STDERR" || report "glossary_bad_terms: expected $code on stderr"
    grep -qF "### $code" <<<"$report_body" || report "glossary_bad_terms: expected report to group findings under '### $code'"
  done
}

# ---------------------------------------------------------------------------
# Case: glossary term extraction from the domain-model doc only counts bold
# text at the start of a line as a term when it is <=4 words and has none
# of # ( ) , : — a cross-reference or a long emphasised fragment is prose,
# not a term, and must not trigger GLOSSARY_TERM_UNLISTED. A short bold
# term genuinely missing from CONTEXT.md still must.
# ---------------------------------------------------------------------------
case_glossary_term_extraction_rule() {
  local dir; dir="$(make_fixture glossary_term_extraction_rule)"
  write_documentation_standard "$dir"
  write_clean_adr "$dir"

  cat > "$dir/docs/explanation/domain-model.md" <<'EOF'
# Domain model

Kind: explanation

**Roll-off (issue #708, epic #706)** is a cross-reference, not a term.

**This bold fragment runs on for quite a few words here** is prose emphasis.

**Site** is a real, unlisted term.
EOF
  cat > "$dir/docs/explanation/architecture.md" <<'EOF'
# Architecture

Kind: explanation

## Context

```mermaid
graph TD; A-->B;
```

## Container

```mermaid
graph TD; A-->B;
```

## Component

```mermaid
graph TD; A-->B;
```
EOF
  cat > "$dir/docs/reference/api-contract.md" <<'EOF'
# API contract

Kind: reference

Body.
EOF
  cat > "$dir/CONTEXT.md" <<'EOF'
# CONTEXT.md — glossary

## Terms

**Widget** — a thing.
EOF
  cat > "$dir/docs/rationale/backend.md" <<'EOF'
## app.py

### backend-example

Line one of reasoning.
Line two of reasoning.

Refs: #1
EOF
  cat > "$dir/src/app.py" <<'EOF'
# why: docs/rationale/backend.md#backend-example
x = 1
EOF
  cat > "$dir/docs/README.md" <<'EOF'
# Docs index

- [Architecture](explanation/architecture.md)
- [Domain model](explanation/domain-model.md)
- [API contract](reference/api-contract.md)
EOF

  run_audit "$dir"
  grep -qF "'Roll-off (issue #708, epic #706)'" <<<"$AU_STDERR" && report "glossary_term_extraction_rule: cross-reference bold must not read as a term, got: $AU_STDERR"
  grep -qF "This bold fragment runs on for quite a few words here" <<<"$AU_STDERR" && report "glossary_term_extraction_rule: long prose bold must not read as a term, got: $AU_STDERR"
  grep -qF "GLOSSARY_TERM_UNLISTED" <<<"$AU_STDERR" || report "glossary_term_extraction_rule: expected GLOSSARY_TERM_UNLISTED for 'Site', got: $AU_STDERR"
  grep -qF "term 'Site'" <<<"$AU_STDERR" || report "glossary_term_extraction_rule: expected finding to name 'Site', got: $AU_STDERR"
  return 0
}

# ---------------------------------------------------------------------------
# Case: architecture.md is missing one of the three required C4 level
# headings — ARCH_MISSING_LEVEL.
# ---------------------------------------------------------------------------
case_arch_missing_level() {
  local dir; dir="$(make_fixture arch_missing_level)"
  write_documentation_standard "$dir"
  write_clean_adr "$dir"

  # No '## Component' heading at all.
  cat > "$dir/docs/explanation/architecture.md" <<'EOF'
# Architecture

Kind: explanation

## Context

```mermaid
graph TD; A-->B;
```

## Container

```mermaid
graph TD; A-->B;
```
EOF

  run_audit "$dir"
  [ "$AU_RC" -eq 1 ] || report "arch_missing_level: expected exit 1, got $AU_RC"
  grep -qF "ARCH_MISSING_LEVEL" <<<"$AU_STDERR" || report "arch_missing_level: expected ARCH_MISSING_LEVEL on stderr, got: $AU_STDERR"
  grep -qF "### ARCH_MISSING_LEVEL" "$AU_REPORT" || report "arch_missing_level: expected report to group under '### ARCH_MISSING_LEVEL'"
}

# ---------------------------------------------------------------------------
# Case: architecture.md has all three C4 level headings but out of the
# required Context/Container/Component order — ARCH_LEVEL_ORDER.
# ---------------------------------------------------------------------------
case_arch_level_order() {
  local dir; dir="$(make_fixture arch_level_order)"
  write_documentation_standard "$dir"
  write_clean_adr "$dir"

  # Component appears first in the file, ahead of Context and Container.
  cat > "$dir/docs/explanation/architecture.md" <<'EOF'
# Architecture

Kind: explanation

## Component

```mermaid
graph TD; A-->B;
```

## Context

```mermaid
graph TD; A-->B;
```

## Container

```mermaid
graph TD; A-->B;
```
EOF

  run_audit "$dir"
  [ "$AU_RC" -eq 1 ] || report "arch_level_order: expected exit 1, got $AU_RC"
  grep -qF "ARCH_LEVEL_ORDER" <<<"$AU_STDERR" || report "arch_level_order: expected ARCH_LEVEL_ORDER on stderr, got: $AU_STDERR"
  grep -qF "### ARCH_LEVEL_ORDER" "$AU_REPORT" || report "arch_level_order: expected report to group under '### ARCH_LEVEL_ORDER'"
}

# ---------------------------------------------------------------------------
# Case: <repo> in the report title is filled from `git remote get-url
# origin`'s basename with .git stripped, when the root is a git repo with an
# origin remote configured.
# ---------------------------------------------------------------------------
case_repo_name_from_origin() {
  local dir; dir="$(make_fixture reponame)"
  (cd "$dir" && git init -q && git remote add origin https://example.com/org/My-Repo.git)
  run_audit "$dir"
  head -n1 "$AU_REPORT" | grep -qF "My-Repo" \
    || report "repo_name_from_origin: expected report title to use origin basename 'My-Repo', got: $(head -n1 "$AU_REPORT" 2>/dev/null)"
  if head -n1 "$AU_REPORT" | grep -qF ".git"; then
    report "repo_name_from_origin: expected '.git' suffix stripped from the report title, got: $(head -n1 "$AU_REPORT" 2>/dev/null)"
  fi
}

# ---------------------------------------------------------------------------
# Case: a doc-manifest.md section missing (here, the Diátaxis directories
# line) surfaces as a "## Skipped checks" section in the report, not buried
# as a NOTE inside Tier 1, and the Summary line counts it.
# ---------------------------------------------------------------------------
# Regression: ARCH_NO_DIAGRAM must be deterministic — the old
# `sed | grep -q` pipeline raced SIGPIPE under pipefail and fired ~50% of runs.
case_arch_diagram_deterministic() {
  local dir; dir="$(make_fixture archdet)"
  write_documentation_standard "$dir"
  cat > "$dir/docs/explanation/architecture.md" <<'MD'
# Architecture

## Context

```mermaid
graph TD; u-->s
```

## Container

```mermaid
graph TD; a-->b
```

## Component

```mermaid
graph TD; c-->d
```
MD
  local run
  for run in $(seq 1 20); do
    run_audit "$dir"
    if grep -q "ARCH_NO_DIAGRAM" "$AU_REPORT" 2>/dev/null || printf '%s' "$AU_STDERR" | grep -q "ARCH_NO_DIAGRAM"; then
      report "arch_deterministic: spurious ARCH_NO_DIAGRAM on run $run"
      return
    fi
  done
}

# ---------------------------------------------------------------------------
# Regression: ADR_NO_DATE must be deterministic — the same `head | grep -q`
# SIGPIPE-under-pipefail race as ARCH_NO_DIAGRAM above, different pipeline.
case_adr_date_deterministic() {
  local dir; dir="$(make_fixture datedet)"
  write_documentation_standard "$dir"
  cat > "$dir/docs/adr/0001-dated.md" <<'MD'
# ADR-0001: Dated decision

Status: Accepted
Date: 2026-08-30

## Context
c
## Decision Drivers
d
## Considered Options
o
## Decision
x
## Consequences
q
MD
  local run
  for run in $(seq 1 20); do
    run_audit "$dir"
    # match the finding line, not the gap-report template's C2 chore text
    # which always contains the literal code list
    if grep -q "ADR_NO_DATE no Date: line" "$AU_REPORT" 2>/dev/null || printf '%s' "$AU_STDERR" | grep -q "ADR_NO_DATE no Date: line"; then
      report "adr_date_deterministic: spurious ADR_NO_DATE on run $run"
      return
    fi
  done
}

# ---------------------------------------------------------------------------
case_skipped_checks() {
  local dir; dir="$(make_fixture skipped)"
  write_documentation_standard "$dir"
  # Drop the "## Diátaxis directories" heading and its tutorials:/how-to:/
  # reference:/explanation: line, leaving the rest of doc-manifest.md intact.
  sed -i '/^## Diátaxis directories$/,+1d' "$dir/docs/doc-manifest.md"
  write_clean_adr "$dir"

  run_audit "$dir"
  local summary_line
  summary_line="$(grep -m1 'Skipped checks:' "$AU_REPORT" 2>/dev/null || true)"
  printf '%s\n' "$summary_line" | grep -qE 'Skipped checks: [1-9][0-9]*' \
    || report "skipped_checks: expected 'Skipped checks: N' with N >= 1 in the Summary line, got: $summary_line"
  grep -qF '## Skipped checks' "$AU_REPORT" \
    || report "skipped_checks: expected a '## Skipped checks' section in the report"
}

run_case case_adopted_clean
run_case case_not_adopted
run_case case_usage_error
run_case case_missing_root
run_case case_manifest_line_missing
run_case case_all_findings
run_case case_adr_no_date
run_case case_doc_kind_missing
run_case case_index_dead_link
run_case case_index_dead_link_in_comment
run_case case_glossary_missing
run_case case_glossary_bad_terms
run_case case_glossary_term_extraction_rule
run_case case_arch_missing_level
run_case case_arch_level_order
run_case case_repo_name_from_origin
run_case case_skipped_checks
run_case case_arch_diagram_deterministic
run_case case_adr_date_deterministic

if [ "$fail" -ne 0 ]; then
  echo "test_audit: FAILED" >&2
  exit 1
fi

echo "test_audit: PASS ($(grep -c "^run_case " "${BASH_SOURCE[0]}") cases)"
exit 0
