#!/usr/bin/env bash
# project-items-walk.sh — the paginated ProjectV2 `items()` GraphQL walk
# shared by batch-deferred.sh (#738's board-Status exclusion) and
# board-audit.sh (Part (a)'s project-items listing), which independently
# re-implemented the identical pagination loop — same project id, same
# `node(id:$id){...on ProjectV2{items(first:100,after:$cursor){pageInfo{...}
# nodes{...}}}}` query shape — before this extraction (#867).
#
# Sourced, not executed: defines gh_project_items_walk and nothing else.
# It is deliberately NOT the whole query: each caller still owns its own
# query text (the `nodes{...}` field selection differs — board-audit.sh
# wants `claimedBy`, batch-deferred.sh wants `status`) and its own
# extraction jq filter, applied to the walk's output afterward. What is
# genuinely identical between the two callers, and the only thing this
# file shares, is the cursor loop itself and the fail-closed guard against
# a `hasNextPage: true` with no usable `endCursor` (originally added to
# batch-deferred.sh only, as #858 round-1 finding N7; board-audit.sh never
# carried it, and gains it here as a byproduct of sharing the loop — a
# reliability improvement, not a change to either script's read-only
# GET-only contract, since GitHub has never been observed to return that
# shape and the guard only ever fires on a shape that would otherwise
# spin forever).
#
# Requires from the caller's environment: `gh`, `jq` on PATH, a `die()`
# function (both callers already define one, same shape), and a writable
# `$WORK` scratch directory (both callers already create one) — this file
# adds no dependency beyond what both scripts already require.

gh_project_items_walk(){ # gh_project_items_walk <project-id> <query> <out-file> [label]
  # Walks <query> (a `node(id:$id){...on ProjectV2{items(first:100,
  # after:$cursor){...}}}` GraphQL document taking $id and optional $cursor)
  # to exhaustion, appending each page's raw JSON response as one line to
  # <out-file> (truncated first). The caller then extracts whatever fields
  # it needs from each page with its own jq filter run over <out-file>
  # WITHOUT `-s`/`--slurp` — jq's default multi-document input applies a
  # filter once per top-level JSON value in the stream, one per line here,
  # reproducing exactly the per-page extraction each caller used to do
  # inline inside its own loop.
  #
  # [label] names the query in `die`'s message (default "project-items"):
  # batch-deferred.sh's walk is a board-Status query, not an items listing,
  # so it passes "project-status" to keep the pre-extraction message an
  # operator debugging a rate-limit or auth failure already knows (round-1
  # finding 3).
  local project_id="$1" query="$2" out_file="$3" label="${4:-project-items}"
  local cursor="" page has_next
  : > "$out_file"
  while :; do
    if [ -n "$cursor" ]; then
      page=$(gh api graphql -f query="$query" -f id="$project_id" -f cursor="$cursor" 2>"$WORK/gql.err") \
        || die "GraphQL $label query failed: $(cat "$WORK/gql.err")"
    else
      page=$(gh api graphql -f query="$query" -f id="$project_id" 2>"$WORK/gql.err") \
        || die "GraphQL $label query failed: $(cat "$WORK/gql.err")"
    fi
    printf '%s\n' "$page" >> "$out_file"
    has_next=$(jq -r '.data.node.items.pageInfo.hasNextPage' <<<"$page")
    cursor=$(jq -r '.data.node.items.pageInfo.endCursor' <<<"$page")
    [ "$has_next" = "true" ] || break
    # A hasNextPage:true with no usable cursor would otherwise re-request
    # page 1 with the literal string "null" forever; refusing costs nothing
    # and cannot loop (originally #858 round-1 finding N7).
    case "$cursor" in
      ''|null) die "GraphQL $label pagination: hasNextPage is true but endCursor is '$cursor'" ;;
    esac
  done
}
