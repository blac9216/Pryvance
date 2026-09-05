#!/usr/bin/env bash
set -euo pipefail

ROOT=""
ADR_DIR="docs/adr"
MODE="print"
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --root=*) ROOT="${1#--root=}"; shift ;;
    --adr-dir) ADR_DIR="${2:-}"; shift 2 ;;
    --adr-dir=*) ADR_DIR="${1#--adr-dir=}"; shift ;;
    --check) MODE="check"; shift ;;
    --write) MODE="write"; shift ;;
    -h|--help) echo "Usage: adr-index.sh [--root R] [--adr-dir D] [--check|--write]"; exit 0 ;;
    *) echo "adr-index: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$ROOT" ] || ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ROOT="$(cd "$ROOT" && pwd)"
DIR="$ROOT/$ADR_DIR"
[ -d "$DIR" ] || { echo "adr-index: missing $ADR_DIR" >&2; exit 2; }

truncate() {
  local text="$1" max=100 cut
  if [ "${#text}" -le "$max" ]; then printf '%s' "$text"; return; fi
  cut="${text:0:$max}"
  if [[ "$cut" == *[[:space:]]* ]]; then cut="${cut%[[:space:]]*}"; fi
  printf '%s…' "$cut"
}

cell_list() {
  local value="$1"
  value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  [ -n "$value" ] && printf '%s' "$value" || printf -- '-'
}

build_table() {
  echo '| # | Title | Status | Supersedes | Superseded by | Amends | Amended by | Decision |'
  echo '|---|---|---|---|---|---|---|---|'
  for file in "$DIR"/[0-9][0-9][0-9][0-9]-*.md; do
    [ -e "$file" ] || continue
    base="$(basename "$file")"
    num="${base%%-*}"
    title="$(grep -m1 '^# ' "$file" | sed -E 's/^# ADR-[0-9]+:[[:space:]]*//')"
    status="$(head -n 15 "$file" | sed -n -E 's/^[[:space:]]*(- )?(\*\*)?Status:(\*\*)?[[:space:]]*([^[:space:];,]+).*$/\4/p' | head -n1)"
    case "$status" in Proposed|Accepted|Superseded|Deprecated) ;; *) echo "$base: invalid/missing Status" >&2; return 1 ;; esac
    supersedes="$(head -n 15 "$file" | sed -n -E 's/^Supersedes:[[:space:]]*(.*)$/\1/p' | head -n1)"
    supersededby="$(head -n 15 "$file" | sed -n -E 's/^Superseded[- ]by:[[:space:]]*(.*)$/\1/p' | head -n1)"
    amends="$(head -n 15 "$file" | sed -n -E 's/^Amends:[[:space:]]*(.*)$/\1/p' | head -n1)"
    amendedby="$(head -n 15 "$file" | sed -n -E 's/^Amended[- ]by:[[:space:]]*(.*)$/\1/p' | head -n1)"
    decision="$(awk '/^## Decision[[:space:]]*$/{f=1;next} f && /^## /{exit} f && NF{print;exit}' "$file")"
    decision="$(truncate "$decision")"
    printf '| [%s](%s) | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$num" "$base" "$title" "$status" \
      "$(cell_list "$supersedes")" "$(cell_list "$supersededby")" \
      "$(cell_list "$amends")" "$(cell_list "$amendedby")" "$decision"
  done
}

TABLE="$(build_table)" || exit 1
README="$DIR/README.md"
START='<!-- adr-index:start -->'
END='<!-- adr-index:end -->'

case "$MODE" in
  print) printf '%s\n' "$TABLE" ;;
  check)
    [ -f "$README" ] || { echo "README.md: ADR_INDEX_DRIFT missing" >&2; exit 1; }
    EXISTING="$(sed -n "/$START/,/$END/p" "$README" | sed '1d;$d')"
    [ "$EXISTING" = "$TABLE" ] || { echo "README.md: ADR_INDEX_DRIFT generated table differs" >&2; exit 1; }
    echo 'ADR index up to date'
    ;;
  write)
    [ -f "$README" ] || touch "$README"
    tmp="$(mktemp)"
    awk -v start="$START" -v end="$END" -v table="$TABLE" '
      BEGIN { inblock=0; found=0 }
      $0==start { print start; print table; inblock=1; found=1; next }
      $0==end { print end; inblock=0; next }
      !inblock { print }
      END { if (!found) { print ""; print start; print table; print end } }
    ' "$README" > "$tmp"
    mv "$tmp" "$README"
    echo "wrote $README"
    ;;
esac
