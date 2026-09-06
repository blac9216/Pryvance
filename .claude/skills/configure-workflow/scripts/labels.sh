#!/usr/bin/env bash
# labels.sh — apply the canonical label set plus repo area:* labels from a
# JSON file, and prune extras.
# Usage: labels.sh --repo owner/name --areas <file> [--no-prune] [--audit]
# --areas is a JSON array of {"name":"area:x","color":"hex","description":"…"}
# objects; every name must start with "area:". Both --repo and --areas are
# required — either missing exits 2 before any `gh` call.
# Exit codes: 0 in sync (or applied, non-audit); 1 --audit found drift;
# 2 bad usage or a malformed --areas file; 3 missing dependency (_lib.sh).
# Class: writer (gh label create/edit/delete) — read-only under --audit;
# DRY_RUN=1 prints the commands instead of running them. Idempotent.
source "$(dirname "$0")/_lib.sh"
REPO=""; AREAS=""; PRUNE=1; AUDIT=0
while [ $# -gt 0 ]; do case $1 in
  --repo) REPO=$2; shift 2;;
  --areas) AREAS=$2; shift 2;;
  --no-prune) PRUNE=0; shift;;
  --audit) AUDIT=1; shift;;
  *) say "unknown arg $1"; exit 2;;
esac; done
usage(){ say "usage: labels.sh --repo owner/name --areas <file> [--no-prune] [--audit]"; exit 2; }
[ -n "$REPO" ] || usage
[ -n "$AREAS" ] || usage
[ -f "$AREAS" ] || { say "--areas file not found: $AREAS"; exit 2; }
validate_areas "$AREAS" || exit 2

want=$(jq -c '.labels[]' "$MANIFESTS/labels.json")
areas=$(jq -c '.[]' "$AREAS")
want=$(printf '%s\n%s\n' "$want" "$areas")
have=$(gh label list --repo "$REPO" --limit 300 --json name,color,description | jq -c '.[]')
drift=0
while IFS= read -r l; do [ -n "$l" ] || continue
  n=$(jq -r .name <<<"$l"); c=$(jq -r .color <<<"$l"); d=$(jq -r .description <<<"$l")
  cur=$(jq -c --arg n "$n" 'select(.name==$n)' <<<"$have")
  if [ -z "$cur" ]; then drift=1; say "create  $n"; [ $AUDIT = 1 ] || run gh label create "$n" --repo "$REPO" --color "$c" --description "$d"
  elif [ "$(jq -r .color <<<"$cur")" != "$c" ] || [ "$(jq -r .description <<<"$cur")" != "$d" ]; then drift=1; say "correct $n"; [ $AUDIT = 1 ] || run gh label edit "$n" --repo "$REPO" --color "$c" --description "$d"
  fi
done <<<"$want"
if [ $PRUNE = 1 ]; then
  wanted_names=$(jq -r .name <<<"$want" | sort)
  while IFS= read -r n; do [ -n "$n" ] || continue
    if ! grep -qx "$n" <<<"$wanted_names"; then
      open_issues=$(gh issue list --repo "$REPO" --state open --label "$n" --limit 1 --json number --jq length)
      open_prs=$(gh pr list --repo "$REPO" --state open --label "$n" --limit 1 --json number --jq length)
      if [ "$open_issues" = 0 ] && [ "$open_prs" = 0 ]; then drift=1; say "prune   $n (unused)"; [ $AUDIT = 1 ] || run gh label delete "$n" --repo "$REPO" --yes
      else drift=1; say "KEEP    $n — non-canonical but on open issues/PRs; retag them first"; fi
    fi
  done <<<"$(jq -r .name <<<"$have")"
fi
[ $drift = 0 ] && say "labels: in sync" || { [ $AUDIT = 1 ] && exit 1; say "labels: applied"; }
