# Issue Metrics Closing Comment

Posted by the orchestrator (or the session, in solo mode) on the issue after its PR
merges — the last comment on the issue. It puts the estimate made at filing next to what
actually happened, so planning calibrates against reality. Fill what you know. A whole
top-level key may be omitted when the session had no source for it at all (a session
that never ran CI may omit `ci_seconds` entirely); a value inside a key you *are*
emitting that you cannot know is written as explicit `null` — never estimated. This is
the same rule stated in [implementer.md](implementer.md)'s Evidence section — keep both
consistent if you touch either. The HTML comment is parsed by the planning skill's
`history.sh`; the visible lines are for people. The fenced blocks below (including the
`jq` one-liner further down) are pasteable — wrap exempt, see the convention in
[github-workflow/SKILL.md](../../SKILL.md).

```markdown
### Closed — metrics

Estimate: <size class> · <est. cycle> · <est. completion date> → Actual: started <date>
(<assigned | first commit | PR open>), merged <date>, <n> review round(s), <k> finding(s),
+<add>/−<del> in <files> files. Deferred issues spawned: <list | none>.

<!-- metrics {"issue":<N>,"pr":<P>,"estimate":{"size":"S|M|L","cycle_days":<x>,"due":"<date>"},
"started":"<ISO>","start_source":"assigned|first-commit|pr-open|issue-created","pr_opened":"<ISO>","merged":"<ISO>",
"rounds":<n>,"findings":[<per round>],"additions":<a>,"deletions":<d>,"files":<f>,"ci_seconds":<s>,
"roles":{"implementer":{"model":"…","tokens":<t>,"seconds":<s>},"fix":{"model":"…","tokens":<t>,"seconds":<s>},
"reviewer":{"model":"…","tokens":<t>,"seconds":<s>,"helpers":[{"model":"…","purpose":"…","tokens":<t>}]},
"rebase":{"model":"…","tokens":<t>,"seconds":<s>},"merge-verifier":{"model":"…","tokens":<t>,"seconds":<s>}},
"dispatch_to_pr_seconds":<s>,"deferred":[<issue numbers>],"verified":"n/a|pending-live","v":2} -->
```

Footer `"v":2` adds two optional `roles{}` keys: `rebase` and `merge-verifier`, one
object each in the plain `{model,tokens,seconds}` shape — the same base shape every
other role uses, minus `helpers`, since neither role is reviewer-shaped and each
typically runs once per issue with nothing analogous to spawn. Omit either key entirely
when that role never ran on this issue, same as any other optional key in this footer; a
run whose token/duration numbers are unknown still gets the key with explicit `null`
values rather than being omitted, since the role itself is known to have run. `v` itself
is recorded once it is first non-1; a footer with no `v` key is implicitly version 1.
Template follows practice here: pre-existing footers stay valid exactly as posted, with
no retroactive edit to bring them into the shape below — this file was rewritten to
match what the orchestrator already emits, not the other way around. Consumers must
accept **both** spellings a role object can carry: this file's `model` (a string, the
last role's report to carry one) and the **models-only shape** some already-posted
footers carry instead — a role object with only `models` (an array) and no `model` key
at all, same field name and meaning as this file's optional `models` companion. The
read rule is `.model // (.models | last)`: prefer `model` when present, otherwise fall
back to the last entry of `models`. A models-only footer's per-role `rounds` key, where
present, is ignored by that same rule — it has no equivalent in the shape below and
carries no information a consumer needs.

Each `roles{}` entry for the three footer roles — `implementer`/`fix`/`reviewer` — still
aggregates **all** `report` events for that role on the issue, not just the last; every
other role on the `report.role` enum (`validation`, `helper`, `calibrator`, any future
member, and a missing `role`) is excluded from this aggregation entirely — `calibrator`
stays recorded only inside a reviewer's `helpers` array, never as its own `roles{}` key,
same as any other helper. Within that allowlist: `tokens` and `seconds` are summed
(`seconds` is the sum of each aggregated event's `duration_s`); `model` is the last
aggregated event's `report.model` — a tier or, where the harness reported one, a
concrete model name, both valid per [session-log.md](../formats/session-log.md) — a
changes-requested round's tokens are additive with the approving round's, never
overwritten. Per-role round counts are not tracked in `roles{}`; the footer's top-level
`rounds` key (review rounds) is the only round count this footer carries. A role running
on more than one model across its events is the designed norm, not an anomaly: fix
rounds are tier-classified per dispatch (mid by default, large for design-shaped
findings — `orchestration.md`'s Routing table), and a doc-only PR's round-1 review runs
at mid while its round-2 review runs at the large review-default tier. When more than
one distinct model ran a role across its
events, add the optional `models` array alongside `model` — the **distinct** values seen,
in the order first encountered — so the record of every tier or model that ran survives
even though `model` alone only names the last; omit `models` entirely when only one
model ran, which is the common case. A `report` event missing its (required) `model`
field contributes nothing to `model`/`models` — the aggregation filters that event's
`model` out, rather than letting an off-schema `null` win as "last" — since the event is
already off-schema upstream per [session-log.md](../formats/session-log.md)'s event
table. If none of a role's `report` events carried a `model` (e.g. a cloud session that
never logged one), `model` is explicit `null` in the footer — never omitted, since the
role itself is known to have run. The `helper` role (see
[session-log.md](../formats/session-log.md)) is never a `roles{}` key, so a directly
dispatched helper's tokens are recorded, if at all, only via a reviewer's `helpers`
array.

The reviewer role's `helpers` array uses the same field names (`model`, `purpose`,
`tokens`) as `report.helpers` in
[session-log.md](../formats/session-log.md) and the handoff enumeration in
[github-pr-review/SKILL.md](../../../github-pr-review/SKILL.md). Numbers the
orchestrator cannot see stay explicit `null` — never estimated.

Sources: the session log filtered to this issue (`jq 'select(.issue==N)' session.jsonl`),
the reviewer's task notification (its tokens/duration), the PR (`gh api …/pulls/P`), the
issue timeline (`gh api …/issues/N/timeline` for the first `assigned` event), and the PR's
`## PR Review` comments for rounds and findings. The aggregation rule above, as one
`jq` call over the session log:

```bash
jq -s '[.[] | select(.event=="report" and .issue==N and (.role=="implementer" or .role=="fix" or .role=="reviewer"))] | reduce .[] as $r ({}; .[$r.role] = ((.[$r.role] // {tokens:0,seconds:0,helpers:[],_models:[]}) | .tokens += ($r.tokens // 0) | .seconds += ($r.duration_s // 0) | .helpers += ($r.helpers // []) | (if $r.model != null then ._models += [$r.model] else . end))) | map_values( (._models | reduce .[] as $m ([]; if (index($m))==null then . + [$m] else . end)) as $distinct | {model: (if (._models|length)>0 then ._models[-1] else null end)} + (if ($distinct|length) > 1 then {models: $distinct} else {} end) + {tokens, seconds} + (if (.helpers|length)==0 then {} else {helpers} end) )' session.jsonl
```

`roles.rebase` and `roles.merge-verifier` are filled directly from that role's own single
`report` event (`{model:$r.model, tokens:$r.tokens, seconds:$r.duration_s}`), not through
the one-liner above — it stays scoped to the three aggregated footer roles on purpose,
since neither of the two new roles accumulates across rounds the way implementer/fix/
reviewer do. The one-liner above builds each role object key-by-key in the same order
as the skeleton above — `model`, an optional `models`, `tokens`, `seconds`, an optional
`helpers` — so a footer built from it reads the same as the skeleton describes; JSON
key order carries no meaning of its own, this is purely so the two stay legible side by
side.
