#!/usr/bin/env bash
# grant.sh — OWNER-run: add the automation account (and optional reviewer account) as repo collaborator + Project admin; verify.
# Usage: GH_TOKEN=<owner token> grant.sh --repo owner/name --owner <login> --project <number> --machine <login> [--reviewer <login>] [--audit]
source "$(dirname "$0")/_lib.sh"
REPO=""; OWNER=""; NUM=""; MACHINE=""; REVIEWER=""; AUDIT=0
while [ $# -gt 0 ]; do case $1 in --repo) REPO=$2; shift 2;; --owner) OWNER=$2; shift 2;; --project) NUM=$2; shift 2;; --machine) MACHINE=$2; shift 2;; --reviewer) REVIEWER=$2; shift 2;; --audit) AUDIT=1; shift;; *) say "unknown arg $1"; exit 2;; esac; done
[ -n "$REPO" ] && [ -n "$OWNER" ] && [ -n "$NUM" ] && [ -n "$MACHINE" ] || { say "usage: grant.sh --repo o/n --owner <login> --project <n> --machine <login> [--reviewer <login>]"; exit 2; }
# Guarded the same way as the per-account node-id lookup below: a failed or empty
# project lookup (bad owner login, nonexistent project number, missing 'project'
# scope, transient 5xx, rate limit) must not abort before the account loop with no
# grants: summary — it must say so, exit nonzero, and never claim "in sync".
# Capture gh's own stderr alongside the named cause: the named message narrows the
# search (bad owner/number/scope) but gh already knows which one it was, and
# swallowing that with 2>/dev/null forced the operator to guess.
proj_err_file=$(mktemp); trap 'rm -f "$proj_err_file"' EXIT
proj=$(gh api graphql -f query='query($o:String!,$n:Int!){user(login:$o){projectV2(number:$n){id viewerCanUpdate}}}' -F o="$OWNER" -F n="$NUM" 2>"$proj_err_file") || proj=""
proj_err=$(cat "$proj_err_file" 2>/dev/null || true)
rm -f "$proj_err_file"
PID=$(jq -r '.data.user.projectV2.id // empty' <<<"${proj:-null}" 2>/dev/null) || PID=""
if [ -z "$PID" ]; then
  say "could not resolve project $NUM for owner $OWNER — check the owner login, the project number, and the token's 'project' scope"
  # gh's own CLI errors are already self-prefixed ("gh: Could not resolve …"); echo
  # the captured text as-is rather than double-prefixing it.
  [ -n "$proj_err" ] && say "$proj_err"
  # Audit-mode wording follows the mode all the way through the pre-loop guard too,
  # so this early-exit path and the end-of-loop summary share one vocabulary.
  if [ $AUDIT = 1 ]; then say "grants: 1 unresolved"; else say "grants: 0 applied, 1 failed"; fi
  exit 1
fi
VIEWER_CAN_UPDATE=$(jq -r '.data.user.projectV2.viewerCanUpdate' <<<"$proj")
# own-account signal: viewerCanUpdate reflects the token this script is currently running as,
# not any named account, so it only narrows the check for whichever account IS that token's
# owner — never inferred for the other account.
VIEWER_LOGIN=$(gh api user --jq .login 2>/dev/null || echo "")
drift=0; applied=0; failed=0
for acct in $MACHINE $REVIEWER; do
  perm=$(gh api "repos/$REPO/collaborators/$acct/permission" --jq .permission 2>/dev/null || echo none)
  if [ "$perm" != write ] && [ "$perm" != admin ]; then
    drift=$((drift + 1))
    if [ $AUDIT = 1 ]; then
      # A "none" permission is ambiguous: never granted, or a pending invitation the account
      # has not yet accepted (the PUT below returns 201-with-invitation, not 204, for a fresh
      # collaborator on a user-owned repo). Check the invitations list so the owner is told
      # which one it is instead of guessing from "none" alone. `gh api` has no `--arg` flag
      # (that belongs to `jq`); pass the raw JSON array to `jq --arg` instead of trying to
      # thread the argument through `gh api` itself. Listing invitations needs admin rights
      # on the repo, so this call 403s for a mere collaborator token — guarded, like every
      # other `gh api` call in this loop, and the 403 case is reported rather than folded
      # silently into "none".
      # --paginate: GET /repos/{o}/{r}/invitations is a paginated collection (30/page
      # by default); a repo carrying more than one page of pending invitations would
      # otherwise miss any invitation past page 1 and misreport it as never granted
      # (#511). `--paginate` and `-i` are awkward together — `gh api --paginate -i`
      # emits one status+header+blank-line+body frame PER PAGE concatenated back to
      # back with no guaranteed separator between one page's body and the next
      # frame's status line, so a body-only single- or multi-frame split cannot
      # reliably tell them apart. Status capture is therefore moved to a SEPARATE,
      # unpaginated `-i` call, made only when the paginated call itself fails — this
      # costs one extra API call on a failure (rare) rather than on every
      # "none"-permission account (the common case), and needs no framing logic at
      # all for the success path below.
      if inv_raw=$(gh api --paginate "repos/$REPO/invitations" 2>/dev/null); then inv_ok=1; else inv_ok=0; inv_raw=""; fi
      inv_status=""
      if [ "$inv_ok" = 0 ]; then
        # A 403 (no admin rights) gets the specific wording above, anything else
        # (5xx, network) gets its own — neither is folded into the other, and a
        # network failure that never produces a status line falls into the
        # "anything else" branch too. Single page only: there is nothing to
        # paginate on a failure this call never needs the body for.
        # `gh api -i` on a non-2xx still exits nonzero even though it wrote a status
        # line; under this file's `pipefail`, `| awk` alone would make the whole
        # pipeline's exit status nonzero and abort the script here — the trailing
        # `|| true` keeps only the awk-derived line, discarding gh's own exit code.
        inv_status=$(gh api "repos/$REPO/invitations" -i 2>/dev/null | awk 'NR==1{print $2}') || true
      fi
      inv=""; inv_parse_ok=1
      if [ "$inv_ok" = 1 ]; then
        if [ -z "${inv_raw//[[:space:]]/}" ]; then
          # An invitations 2xx always has a JSON body (at minimum `[]`); an inv_raw
          # that comes out empty or whitespace-only here means the response itself
          # was unreadable — a literal empty/blank body — never "zero
          # invitations", which would be a non-empty `[]` (#509). `jq -rs` on
          # empty OR whitespace-only stdin slurps ZERO documents, so `$arrays |
          # length` and the input `length` below are both 0, the equality holds,
          # `add // []` yields `[]`, and `inv_parse_ok` would wrongly stay 1 — the
          # same false "never granted" #509 removes, one input class narrower
          # (#537) — unless this is guarded explicitly before calling jq. Stripping
          # `[[:space:]]` (rather than a plain `-z "$inv_raw"` check) catches a
          # non-empty body that is nonetheless all whitespace, not just a
          # literally empty one.
          inv_parse_ok=0
        else
          # A malformed 2xx body (not an array, missing/non-object invitee, non-JSON) must
          # report and continue, never abort mid-loop under this file's set -euo pipefail:
          # `-s` slurps every top-level JSON document `inv_raw` contains — one array
          # per page when `gh --paginate` prints them back to back, or a single
          # already-merged array when it does not — into one list, so the type guard
          # can confirm ALL of them are arrays before merging (one malformed
          # document poisons the whole result instead of being silently dropped);
          # `add // []` flattens that list into a single array either way; `.[0]`
          # (not `| head -1`) means no SIGPIPE on an oversized array either; the
          # `|| { … }` catches a genuine parse failure (non-JSON) that `jq -s`
          # itself rejects outright.
          inv=$(jq -rs --arg a "$acct" '
              map(select(type=="array")) as $arrays
              | if ($arrays | length) == length then
                  ($arrays | add // [] | map(select(((.invitee? // {}) | type == "object") and ((.invitee.login? // "") == $a))) | (.[0].id // empty))
                else "GRANT_SH_PARSE_ERR" end
            ' <<<"$inv_raw" 2>/dev/null) || { inv=""; inv_parse_ok=0; }
          [ "$inv" = "GRANT_SH_PARSE_ERR" ] && { inv=""; inv_parse_ok=0; }
        fi
      fi
      if [ -n "$inv" ]; then
        say "collaborator $acct: $perm — invited, not accepted (pending invitation; nothing to apply until it is accepted)"
      elif [ "$inv_ok" = 0 ]; then
        if [ "$inv_status" = 403 ]; then
          say "collaborator $acct: $perm -> write (invitation check unavailable — listing invitations needs admin rights on $REPO; this token could not confirm whether a pending invitation exists)"
        else
          say "collaborator $acct: $perm -> write (invitation check unavailable — listing invitations failed (HTTP ${inv_status:-no response} — an API or network error, not a permissions error); this token could not confirm whether a pending invitation exists)"
        fi
      elif [ "$inv_parse_ok" = 0 ]; then
        say "collaborator $acct: $perm -> write (invitation check unavailable — listing invitations returned a response this token could not parse; this token could not confirm whether a pending invitation exists)"
      else
        say "collaborator $acct: $perm -> write"
      fi
    else
      say "collaborator $acct: $perm -> write"
      if [ "$DRY" = 1 ]; then
        run gh api -X PUT "repos/$REPO/collaborators/$acct" -f permission=push
      else
        # Distinguish invited from granted: PUT .../collaborators/<acct> returns 204 when the
        # account already had implicit access and was added directly, and 201 with an
        # invitation object for a fresh collaborator on a user-owned repo — pending until it
        # accepts. Same PUT either way; only the status code (not the body) tells them apart.
        status=$(gh api -X PUT "repos/$REPO/collaborators/$acct" -f permission=push -i 2>/dev/null | awk 'NR==1{print $2}')
        case "$status" in
          201) say "collaborator $acct: invited (pending acceptance) — cannot push until the account accepts" ;;
          204) say "collaborator $acct: granted" ;;
          *) say "collaborator $acct: PUT returned status ${status:-unknown} — verify manually" ;;
        esac
      fi
    fi
  fi
  # A failed/unresolvable node-id lookup (deleted/renamed login, transient 5xx, rate limit) is a
  # reported, counted outcome — not a mid-loop abort under set -e — so the remaining accounts
  # still get processed and the run still ends with a summary + nonzero exit.
  uid=$(gh api "users/$acct" --jq .node_id 2>/dev/null) || uid=""
  if [ -z "$uid" ]; then
    drift=$((drift + 1)); failed=$((failed + 1))
    say "project admin $acct: could not resolve account node id — skipped (deleted/renamed login, API error, or rate limit)"
    continue
  fi
  # ProjectV2 has NO queryable field for a NAMED collaborator's role: confirmed by schema
  # introspection (`__type(name:"ProjectV2"){fields{name}}` lists no `collaborators` field;
  # `ProjectV2Collaborator`/`ProjectV2Roles` exist only as the updateProjectV2Collaborators
  # mutation's input types, never as query output). This is a permanent API gap, not a
  # transient failure, so there is nothing to retry or parse here for the general case — never
  # infer "missing" or "in sync" from a malformed/empty response. Two partial signals DO exist
  # and narrow the blanket unknown where they apply (from the schema introspection above):
  # ProjectV2.viewerCanUpdate proves absence (not presence) for the account that
  # owns the running token, and the updateProjectV2Collaborators mutation's own response
  # roster confirms the account landed in apply mode. Neither distinguishes ADMIN from WRITER,
  # so both still land on "unknown" rather than a fabricated role — only the message and the
  # (audit-mode) drift signal get more specific.
  if [ $AUDIT = 1 ]; then
    # GitHub logins are case-insensitive; fold both sides before comparing so a
    # non-canonical --machine/--reviewer case still narrows correctly.
    if [ -n "$VIEWER_LOGIN" ] && [ "${acct,,}" = "${VIEWER_LOGIN,,}" ] && [ "$VIEWER_CAN_UPDATE" = "false" ]; then
      drift=$((drift + 1))
      say "project admin $acct: missing — viewerCanUpdate=false for this token on project $NUM; apply the grant: rerun without --audit"
    else
      say "project admin $acct: unknown — no GraphQL/REST field exposes ProjectV2 collaborator roles; verify manually: https://github.com/users/$OWNER/projects/$NUM/settings/access"
    fi
  else
    # Apply mode asserts the grant, so it must say so: the operator is entitled to a record of
    # every privileged mutation, and the audit-mode "verify manually" pointer would describe a
    # state this branch has just changed. drift=1 keeps the summary from claiming "in sync";
    # applied/failed keep it from claiming "applied" for a mutation that did not land — a
    # swallowed failure here would let the numbered owner sequence in SKILL.md walk past a
    # missing Project admin grant.
    drift=$((drift + 1)); say "project admin $acct: unknown -> ADMIN (re-asserted unconditionally; role is unreadable)"
    if resp=$(gql 'mutation($p:ID!,$u:ID!){updateProjectV2Collaborators(input:{projectId:$p,collaborators:[{userId:$u,role:ADMIN}]}){collaborators(first:100){nodes{__typename ... on User{login} ... on Team{slug}}}}}' "$(jq -n --arg p "$PID" --arg u "$uid" '{p:$p,u:$u}')"); then
      applied=$((applied + 1))
      if [ "$DRY" = 1 ]; then
        :
      # Case-fold both sides (jq ascii_downcase) so a non-canonical --machine/--reviewer
      # case still matches the canonical login/slug in the mutation's roster.
      elif landed=$(jq -r --arg a "$acct" '[.data.updateProjectV2Collaborators.collaborators.nodes[]? | (.login // .slug) | ascii_downcase | select(.==($a|ascii_downcase))] | length' <<<"$resp" 2>/dev/null) && [ "$landed" -gt 0 ] 2>/dev/null; then
        say "project admin $acct: ADMIN grant applied — confirmed present in post-grant collaborator roster"
      else
        say "project admin $acct: ADMIN grant mutation succeeded but $acct not found in the returned roster — verify manually: https://github.com/users/$OWNER/projects/$NUM/settings/access"
      fi
    else
      failed=$((failed + 1)); say "project admin $acct: ADMIN grant mutation FAILED — no grant landed; check token scopes/permissions"
    fi
  fi
done
say "token scopes needed on the automation account: repo, project, read:org (check: gh auth status)"
# Summary + exit status are conditional on what actually happened: audit mode reports drift and
# exits 1 on it; apply mode exits nonzero if any ADMIN mutation failed and never says "applied"
# for work that did not land. DRY_RUN says "would apply" because it mutated nothing.
if [ $AUDIT = 1 ]; then
  [ $drift = 0 ] && { say "grants: in sync"; exit 0; }
  # Every audit-mode termination path gets exactly one grants: line, in audit
  # vocabulary — never the apply-mode "applied/failed" wording, and never silent.
  say "grants: $drift unresolved"
  exit 1
fi
if [ $failed -gt 0 ]; then say "grants: $applied applied, $failed failed"; exit 1; fi
if [ $drift = 0 ]; then say "grants: in sync"
elif [ "$DRY" = 1 ]; then say "grants: would apply (DRY_RUN — nothing mutated)"
else say "grants: applied"; fi
