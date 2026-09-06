# shared helpers — sourced by the other scripts
# shellcheck shell=bash
set -euo pipefail
# Enforce the bash >= 4 floor these scripts rely on (case-folding parameter
# expansion, e.g. ${var,,}, in grant.sh) with a named failure instead of the
# runtime "bad substitution" bash 3.2 (still the system /bin/bash on macOS)
# would hit at expansion time. The check itself is bash-3-safe:
# BASH_VERSINFO exists since bash 2.
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  printf '%s\n' "configure-workflow scripts require bash >= 4 (found: ${BASH_VERSION:-unknown}); on macOS install a newer bash (e.g. 'brew install bash') and invoke scripts with that binary" >&2
  exit 3
fi
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034 # consumed by scripts that source this file (rulesets.sh, project.sh, …), not here
MANIFESTS="$HERE/../manifests"
DRY=${DRY_RUN:-0}
say(){ printf '%s\n' "$*" >&2; }
run(){ if [ "$DRY" = 1 ]; then printf 'DRY: ' >&2; printf '%q ' "$@" >&2; printf '\n' >&2; else "$@"; fi; }
need(){ command -v "$1" >/dev/null || { say "missing: $1"; exit 3; }; }
# LIB_SKIP_GH: set as a plain (non-exported) shell variable by a script,
# immediately before sourcing this file, that makes no `gh` call at all —
# e.g. process-docs.sh, whose contract is that it never shells out to `gh`
# and reads no file outside templates/ and its own --areas file. Every
# other script keeps the default (gh required) unchanged. An *exported*
# LIB_SKIP_GH — i.e. one inherited from the ambient environment rather than
# set by the calling script's own body — is deliberately not honoured: it
# would otherwise silently disable the gh-presence check for every script
# that sources this file, not just the one script whose contract permits
# it, degrading a clear "missing: gh" (exit 3) into a bare, later
# "gh: command not found" the first time the script actually tries to call
# gh. Clearing it here still leaves a same-shell assignment made just above
# the `source` line intact, since that assignment is not exported.
case "$(declare -p LIB_SKIP_GH 2>/dev/null || true)" in *"declare -x"*) unset LIB_SKIP_GH;; esac
[ "${LIB_SKIP_GH:-0}" = 1 ] || need gh
need jq
repo_nwo(){ gh repo view --json nameWithOwner --jq .nameWithOwner; }
gql(){ # gql "<query>" '<variables json>' → runs via --input so list/ID variables are typed correctly
  local q=$1 v=${2:-'{}'}; if [ "$DRY" = 1 ]; then say "DRY gql: ${q:0:80}… vars=$v"; return 0; fi
  jq -n --arg q "$q" --argjson v "$v" '{query:$q,variables:$v}' | gh api graphql --input -; }
# validate_areas <file> — refuse (say the defect, return 1) unless <file> is
# a JSON array of {"name","color","description"} string-valued objects whose
# every name starts with "area:". Shared by labels.sh and process-docs.sh,
# which both take this same --areas JSON shape as an argument.
validate_areas(){
  local f=$1 bad
  jq -e 'type=="array"' "$f" >/dev/null 2>&1 || { say "--areas: not a JSON array of objects: $f"; return 1; }
  bad=$(jq -r '
    .[] |
    if type != "object" then "entry is not an object: \(.)"
    elif ((has("name") and has("color") and has("description")) | not) then "entry missing name/color/description: \(.)"
    elif ([.name,.color,.description] | map(type=="string") | all | not) then "entry name/color/description must all be strings: \(.)"
    elif (.name | startswith("area:") | not) then "entry name does not start with \"area:\": \(.name)"
    else empty end
  ' "$f" 2>&1 | head -1)
  [ -z "$bad" ] || { say "--areas: malformed entry — $bad"; return 1; }
}
