#!/usr/bin/env bash
set -euo pipefail

ROOT=""
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --root=*) ROOT="${1#--root=}"; shift ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --out=*) OUT="${1#--out=}"; shift ;;
    -h|--help) echo "Usage: audit.sh --out <path> [--root <repo-root>]"; exit 0 ;;
    *) echo "audit: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$OUT" ] || { echo "audit: --out is required" >&2; exit 2; }
[ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ROOT="$(cd "$ROOT" && pwd)"

findings=0
report() { printf '%s\n' "$*" | tee -a "$OUT"; findings=$((findings+1)); }
: > "$OUT"

[ -f "$ROOT/docs/doc-manifest.md" ] || { report 'docs/doc-manifest.md DESIGNSET_MISSING'; echo "audit: $findings findings"; exit 1; }

for path in \
  CONTEXT.md \
  docs/README.md \
  docs/explanation/architecture.md \
  docs/explanation/domain-model.md \
  docs/explanation/security.md \
  docs/explanation/roadmap.md \
  docs/reference/api-contract.md \
  docs/adr/README.md; do
  [ -e "$ROOT/$path" ] || report "$path DESIGNSET_MISSING"
done

for heading in '## Context' '## Container' '## Component'; do
  grep -qF "$heading" "$ROOT/docs/explanation/architecture.md" || report "docs/explanation/architecture.md C4_MISSING_HEADING $heading"
done
[ "$(grep -c '^```mermaid$' "$ROOT/docs/explanation/architecture.md" || true)" -ge 3 ] || report 'docs/explanation/architecture.md C4_MISSING_DIAGRAM'

if ! bash "$ROOT/scripts/docs/check-pointers.sh" --root "$ROOT"; then findings=$((findings+1)); fi
if ! bash "$ROOT/scripts/docs/adr-index.sh" --root "$ROOT" --check; then findings=$((findings+1)); fi

echo "audit: $findings findings"
[ "$findings" -eq 0 ] || exit 1
