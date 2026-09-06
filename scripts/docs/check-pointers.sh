#!/usr/bin/env bash
set -euo pipefail

ROOT=""
FORMAT="text"

while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --root=*) ROOT="${1#--root=}"; shift ;;
    --format) FORMAT="${2:-}"; shift 2 ;;
    --format=*) FORMAT="${1#--format=}"; shift ;;
    -h|--help) echo "Usage: check-pointers.sh [--root <repo-root>] [--format text|json]"; exit 0 ;;
    *) echo "check-pointers: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ "$FORMAT" = "text" ] || [ "$FORMAT" = "json" ] || { echo "check-pointers: bad format" >&2; exit 2; }
[ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ROOT="$(cd "$ROOT" && pwd)"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
cd "$ROOT"

POINTER_RE='docs/rationale/[^ ]+\.md#[[:lower:][:digit:]-]+'

grep -rIn --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=bin --exclude-dir=obj -E "(#|//|<!--)[[:space:]]*why:[[:space:]]*$POINTER_RE" . 2>/dev/null | while IFS= read -r match; do
  file="${match%%:*}"
  # why: docs/rationale/infrastructure.md#skill-fixture-pointers
  case "$file" in
    ./.claude/skills/*/tests/*|./.claude/skills/*/references/*) continue ;;
  esac
  rest="${match#*:}"
  line="${rest%%:*}"
  body="${rest#*:}"
  pointer="$(printf '%s\n' "$body" | grep -oE "$POINTER_RE" | head -n1 || true)"
  [ -n "$pointer" ] || continue
  target="${pointer%%#*}"
  slug="${pointer#*#}"
  if [ ! -f "$target" ]; then
    printf '%s\t%s\tPOINTER_BAD_FILE\t%s\n' "${file#./}" "$line" "$target" >> "$TMP"
  elif ! grep -qxF "### $slug" "$target"; then
    printf '%s\t%s\tPOINTER_UNRESOLVED\t%s#%s\n' "${file#./}" "$line" "$target" "$slug" >> "$TMP"
  fi
done || true

for rationale in docs/rationale/*.md; do
  [ -e "$rationale" ] || continue
  awk -v file="$rationale" '
    function finish() {
      if (slug == "") return
      if (lines < 2 || lines > 6) printf "%s\t%d\tENTRY_LENGTH\t%s has %d body lines\n", file, start, slug, lines
      if (!refs) printf "%s\t%d\tENTRY_NO_REFS\t%s\n", file, start, slug
    }
    /^### / {
      finish(); slug=$0; sub(/^### /,"",slug); start=NR; lines=0; refs=0; count[slug]++;
      if (count[slug] > 1) printf "%s\t%d\tSLUG_DUPLICATE\t%s\n", file, NR, slug
      next
    }
    /^## / { finish(); slug=""; next }
    slug != "" && /^Refs:/ { refs=1; next }
    slug != "" && $0 !~ /^[[:space:]]*$/ { lines++ }
    END { finish() }
  ' "$rationale" >> "$TMP"
done

COUNT="$(wc -l < "$TMP" | tr -d '[:space:]')"
if [ "$FORMAT" = "json" ]; then
  printf '['
  first=1
  while IFS=$'\t' read -r file line code message; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"file":"%s","line":%s,"code":"%s","message":"%s"}' "$file" "$line" "$code" "${message//\"/\\\"}"
  done < "$TMP"
  printf ']\n'
else
  while IFS=$'\t' read -r file line code message; do
    printf '%s:%s: %s %s\n' "$file" "$line" "$code" "$message"
  done < "$TMP"
fi

echo "check-pointers: $COUNT findings" >&2
[ "$COUNT" -eq 0 ] || exit 1
