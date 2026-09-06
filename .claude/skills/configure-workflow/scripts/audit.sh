#!/usr/bin/env bash
# audit.sh — one command: is this repo fully configured for the github-workflow skill? Exit 1 on any gap. Read-only.
# The expected skill/agent family comes from a shipped manifest (--family), not a
# hardcoded list, so adding a role is one manifest edit (#782, decision C4).
# Usage: audit.sh --owner <login> --project <number> --machine <login> --repo owner/name --family <path> --areas <areas.json>
# --areas is the area-set JSON file written in SKILL.md step 4 and handed to labels.sh /
# process-docs.sh — a JSON array of {"name":"area:x","color":"hex","description":"…"}
# objects. It is NOT docs/process/labels.md: that table is *rendered from* this JSON and
# labels.sh rejects it (exit 2). It is threaded straight through to `labels.sh --audit`.
# Exit codes: 2 usage (a required flag missing, an unknown flag, an unusable --family
# manifest, or labels.sh itself refusing its arguments) — no gap is ever reported as
# drift when the tool could not run; 1 any gap found; 0 configured.
source "$(dirname "$0")/_lib.sh"
die(){ say "$*"; exit 2; }
OWNER=""; NUM=""; MACHINE=""; REPO=""; FAMILY=""; AREAS=""
while [ $# -gt 0 ]; do case $1 in --owner) OWNER=$2; shift 2;; --project) NUM=$2; shift 2;; --machine) MACHINE=$2; shift 2;; --repo) REPO=$2; shift 2;; --family) FAMILY=$2; shift 2;; --areas) AREAS=$2; shift 2;; *) say "unknown arg $1"; exit 2;; esac; done
[ -n "$OWNER" ] && [ -n "$NUM" ] && [ -n "$MACHINE" ] && [ -n "$REPO" ] && [ -n "$FAMILY" ] && [ -n "$AREAS" ] || die "usage: audit.sh --owner <login> --project <n> --machine <login> --repo owner/name --family <path> --areas <path>"
[ -f "$FAMILY" ] || die "family manifest not found: $FAMILY"
[ -r "$FAMILY" ] || die "family manifest not readable: $FAMILY"
jq -e '.' "$FAMILY" >/dev/null 2>&1 || die "family manifest is not valid JSON: $FAMILY"
jq -e '(.skills|type=="array") and (.agents|type=="array")' "$FAMILY" >/dev/null 2>&1 || die "family manifest missing skills[]/agents[] arrays: $FAMILY"
# An empty array is still an array, and a herestring of "" yields one empty iteration —
# a spurious ok plus a spurious GAP for a name that does not exist. Refuse it outright.
jq -e '.skills|length>0' "$FAMILY" >/dev/null 2>&1 || die "family manifest has an empty skills[] array: $FAMILY"
jq -e '.agents|length>0' "$FAMILY" >/dev/null 2>&1 || die "family manifest has an empty agents[] array: $FAMILY"
family_json=$(jq -c '.' "$FAMILY")
mapfile -t skills_list < <(jq -r '.skills[]' <<<"$family_json")
mapfile -t agents_list < <(jq -r '.agents[]' <<<"$family_json")
fail=0; ok(){ say "  ok   $*"; }; bad(){ say "  GAP  $*"; fail=1; }
say "== labels"
# Exit 1 is real drift; exit 2 is labels.sh refusing its own arguments (a missing,
# unreadable or non-JSON --areas file) and must fail loudly rather than masquerade as
# drift whose offered remedy — "run labels.sh" — reproduces the same exit 2.
# `lerr=$(...)` alone would abort under _lib.sh's `set -e` on any non-zero exit before
# the case could read it; the AND-OR list is exempt and still yields labels.sh's status.
lerr=$("$HERE/labels.sh" --repo "$REPO" --areas "$AREAS" --audit 2>&1 >/dev/null) && lrc=0 || lrc=$?
case $lrc in
  0) ok "canonical + area labels in sync" ;;
  1) bad "labels drift (run labels.sh)" ;;
  2) die "labels.sh usage/--areas error (--areas $AREAS): $lerr" ;;
  *) die "labels.sh failed unexpectedly (exit $lrc, --areas $AREAS): $lerr" ;;
esac
say "== project"
if perr=$("$HERE/project.sh" --owner "$OWNER" --project "$NUM" --audit 2>&1 >/dev/null); then ok "fields/views/workflows match manifest"
elif grep -q '^error:' <<<"$perr"; then bad "project.sh field-resolution error: $(grep -m1 '^error:' <<<"$perr")"
else bad "project drift (run project.sh; check UI workflows)"; fi
say "== grants";   sc=$(gh auth status 2>&1 | grep -o "scopes: .*" || true); grep -q "project" <<<"$sc" && ok "automation token has project scope" || bad "automation token lacks 'project' scope ($sc)"
perm=$(gh api "repos/$REPO/collaborators/$MACHINE/permission" --jq .permission 2>/dev/null || echo unknown); [ "$perm" = write ] || [ "$perm" = admin ] && ok "$MACHINE has $perm on $REPO" || bad "$MACHINE permission: $perm"
say "== ruleset";  rs=$(gh api "repos/$REPO/rules/branches/$(gh api repos/$REPO --jq .default_branch)" --jq 'map(.type)|unique|join(",")' 2>/dev/null || echo ""); grep -q pull_request <<<"$rs" && ok "default branch requires PRs ($rs)" || bad "no pull_request rule visible on the default branch (owner: rulesets.sh) — or the automation account cannot read rules"
say "== docs/process"; for f in work-tracking labels testing validation maintenance overnight failure-modes; do p="docs/process/$f.md"; if [ ! -f "$p" ]; then bad "$p missing"; elif grep -qE '\{\{[A-Z_]+\}\}|<owner' "$p"; then bad "$p has unfilled markers"; else ok "$p"; fi; done
say "== repo files"; grep -qs '^\*\.local\.md' .gitignore && ok ".gitignore ignores *.local.md" || bad ".gitignore lacks '*.local.md'"
grep -qs 'docs/process' AGENTS.md CLAUDE.md 2>/dev/null && ok "agent instructions point at docs/process" || bad "AGENTS.md/CLAUDE.md do not mention docs/process (agent: propose the pointer)"
say "== skills"; for s in "${skills_list[@]}"; do [ -d ".claude/skills/$s" ] && ok "$s present in repo" || bad ".claude/skills/$s missing (propagate from ~/.claude/skills)"; done
say "== agents"; for a in "${agents_list[@]}"; do [ -f ".claude/agents/$a" ] && ok "$a present in repo" || bad ".claude/agents/$a missing (propagate from ~/.claude/agents)"; done
[ $fail = 0 ] && say "AUDIT: configured" || { say "AUDIT: gaps found"; exit 1; }
