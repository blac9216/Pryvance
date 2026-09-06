#!/usr/bin/env bash
# rulesets.sh — OWNER-run (needs repo admin): apply the default-branch ruleset from manifests/rulesets.json.
# Required status-check names are the caller's own — the agent already wrote the repo's
# "## Required checks" testing doc section, so it passes those same names back rather than
# this script re-reading that file at runtime (#780, decision A1).
# Usage: GH_TOKEN=<owner token> rulesets.sh --repo owner/name [--check <name>]... [--reviewer-account] [--audit]
# Exit codes: 2 usage (missing --repo, or an unknown flag); 4 rulesets unavailable (free-plan
# private repo); 5 needs repo admin; 1 drift under --audit, or any other API failure; 0 ok.
source "$(dirname "$0")/_lib.sh"
REPO=""; REVIEWER=0; AUDIT=0; declare -a CHECK_NAMES=()
while [ $# -gt 0 ]; do case $1 in --repo) REPO=$2; shift 2;; --check) CHECK_NAMES+=("$2"); shift 2;; --reviewer-account) REVIEWER=1; shift;; --audit) AUDIT=1; shift;; *) say "unknown arg $1"; exit 2;; esac; done
[ -n "$REPO" ] || { say "usage: rulesets.sh --repo owner/name [--check <name>]... [--reviewer-account] [--audit]"; exit 2; }
M="$MANIFESTS/rulesets.json"; NAME=$(jq -r .name "$M")
if [ "${#CHECK_NAMES[@]}" -eq 0 ]; then
  say "warning: no --check given — ruleset will require a PR but no checks"; checks='[]'
else
  checks=$(printf '%s\n' "${CHECK_NAMES[@]}" | jq -R . | jq -sc 'map({context:.})')
fi
approvals=$(jq -r ".rules.pull_request.required_approving_review_count_$([ $REVIEWER = 1 ] && echo with_reviewer_account || echo single_account)" "$M")
body=$(jq -n --arg name "$NAME" --argjson checks "$checks" --argjson approvals "$approvals" --argjson m "$(cat "$M")" '{
  name:$name, target:"branch", enforcement:"active",
  conditions:{ref_name:{include:["~DEFAULT_BRANCH"],exclude:[]}},
  bypass_actors:[{actor_id:5,actor_type:"RepositoryRole",bypass_mode:$m.bypass.mode}],
  rules:[
    {type:"pull_request",parameters:{required_approving_review_count:$approvals,dismiss_stale_reviews_on_push:$m.rules.pull_request.dismiss_stale_reviews_on_push,require_code_owner_review:false,require_last_push_approval:$m.rules.pull_request.require_last_push_approval,required_review_thread_resolution:false}},
    {type:"required_status_checks",parameters:{strict_required_status_checks_policy:$m.rules.required_status_checks.strict_required_status_checks_policy,required_status_checks:$checks}},
    {type:"non_fast_forward"},{type:"deletion"},{type:"required_linear_history"}]}')
if ! list=$(gh api "repos/$REPO/rulesets" 2>&1); then
  if grep -q "Upgrade to GitHub Pro" <<<"$list"; then say "rulesets are not available on private repositories under the free plan — make the repo public or upgrade; recording as a known gap"; exit 4; fi
  if grep -qE "403|404" <<<"$list"; then say "cannot read rulesets on $REPO — this needs repo admin (owner token)"; exit 5; fi
  say "$list"; exit 1; fi
existing=$(jq -r --arg n "$NAME" '.[]|select(.name==$n)|.id' <<<"$list")
if [ -z "$existing" ]; then say "create ruleset $NAME (checks: $(jq -r 'map(.context)|join(", ")' <<<"$checks"))"; [ $AUDIT = 1 ] && exit 1; run gh api -X POST "repos/$REPO/rulesets" --input - <<<"$body" --jq '.id' >/dev/null
else
  live=$(gh api "repos/$REPO/rulesets/$existing")
  # signature covers every manifest-controlled ruleset parameter, not just types/checks/approvals/enforcement:
  # bypass_actors and the remaining pull_request/required_status_checks parameters (SKILL.md's
  # "every fixture present and exact" must hold for the ruleset too), plus target and conditions.ref_name,
  # and the two hardcoded (not yet manifest-driven) pull_request booleans this script itself renders
  # (a ruleset retargeted off the default branch previously audited as "in sync").
  sig_filter='{
    target,
    conditions_ref_name:{
      include:([.conditions.ref_name.include[]?]|sort),
      exclude:([.conditions.ref_name.exclude[]?]|sort)
    },
    types:[.rules[].type]|sort,
    checks:([.rules[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context]|sort),
    approvals:([.rules[]|select(.type=="pull_request")|.parameters.required_approving_review_count][0]),
    enforcement,
    bypass_actors:([.bypass_actors[]?|{actor_id,actor_type,bypass_mode}]|sort_by(.actor_id,.actor_type)),
    pr_dismiss_stale_reviews_on_push:([.rules[]|select(.type=="pull_request")|.parameters.dismiss_stale_reviews_on_push][0]),
    pr_require_last_push_approval:([.rules[]|select(.type=="pull_request")|.parameters.require_last_push_approval][0]),
    pr_require_code_owner_review:([.rules[]|select(.type=="pull_request")|.parameters.require_code_owner_review][0]),
    pr_required_review_thread_resolution:([.rules[]|select(.type=="pull_request")|.parameters.required_review_thread_resolution][0]),
    required_status_checks_strict_policy:([.rules[]|select(.type=="required_status_checks")|.parameters.strict_required_status_checks_policy][0])
  }'
  want_sig=$(jq -S "$sig_filter" <<<"$body")
  live_sig=$(jq -S "$sig_filter" <<<"$live")
  if [ "$want_sig" = "$live_sig" ]; then say "ruleset $NAME: in sync"; exit 0; fi
  say "ruleset $NAME drift:"; diff <(echo "$live_sig") <(echo "$want_sig") >&2 || true
  [ $AUDIT = 1 ] && exit 1
  run gh api -X PUT "repos/$REPO/rulesets/$existing" --input - <<<"$body" --jq '.id' >/dev/null; fi
say "ruleset applied. Reminder: every required check must ALWAYS report on PRs (path-filtered workflows need an always-report job) or merges block forever."
