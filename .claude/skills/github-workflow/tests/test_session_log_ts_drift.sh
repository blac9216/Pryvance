#!/usr/bin/env bash
# test_session_log_ts_drift.sh — proves every session-log write performed by
# this skill's helper scripts stamps `ts` in the form
# `references/formats/session-log.md` pins — `%FT%TZ`, second precision, from
# `date -u +%FT%TZ`. Not at the five sites the #743 fix's review
# (<https://github.com/blac9216/storage/pull/762#issuecomment-5552314187>)
# audited by hand, but at whatever set this enumeration finds in the tree today.
#
# ---------------------------------------------------------------------------
# SCOPE — read this before asking "is my new writer covered?"
# ---------------------------------------------------------------------------
# IN SCOPE: every file under this skill's `scripts/` directory, found by a
# recursive `find` over that directory. Not a `*.sh` glob and not a flat listing
# — a writer added as `scripts/newthing` (no extension) or `scripts/lib/emit.sh`
# (a subdirectory) is enumerated exactly like the thirteen `.sh` files there
# today. Every file found is read; a file that cannot be read is a failure, not
# a skip.
#
# OUT OF SCOPE, and stated so a reader never has to infer it from a regex:
#   * Anything outside `scripts/`. `tests/` is excluded on purpose — its suites
#     construct deliberately malformed session-log lines as fixtures (grep
#     `tests/test_save_log.sh` for `--arg ts` to see four of them), so scanning
#     it would report fixture drift as production drift. `references/` is prose.
#     The skill's convention is that every executable helper lives in
#     `scripts/`; a session-log writer placed anywhere else is invisible here.
#     This is a final decision, not a placeholder (#811): closing it would need
#     an allowlist, a per-file opt-out marker, or some other convention that
#     tells a production writer from a test fixture without depending on the
#     directory it sits in, and adopting one is a layout decision for the whole
#     skill, not a change to one test file. None is adopted, and none is
#     planned from inside this file. This list is the directory boundary only;
#     it is not the whole account of what this guard cannot see. The rest of
#     that account — the residual fail-opens that survive the fail-closed
#     rules below — is written out in STATED FAIL-OPENS, and the two lists
#     together are the account. Do not read either one as "and nothing else".
#   * `date` output at runtime. This guard reasons about format strings
#     statically; it never executes a script. `stall-check.sh` and
#     `log-consistency-check.sh` are documented the same way.
#   * Every key but `ts`. JSON structure, event-name spelling and the rest of
#     the schema belong to `test_session_log_slugs.sh` and to the
#     per-script suites.
#   * `ts` values that cross a file boundary. Resolution searches the writer's
#     own file only. No writer in the tree sources `ts` from another file; if
#     one ever does, this guard reports it UNRESOLVED and fails — it does not
#     pass it over. That is a stated limit that fails closed, not a blind spot.
#   * `stamp-claim.sh`'s `NOW_TS` (a different thing from `home-deferred.sh`'s
#     function of the same name): it feeds the board's `Claimed by` field, which
#     `formats/claim.md` pins to minute precision deliberately. It reaches no
#     session-log sink, so the sink pass below never selects it, and it reaches
#     no `ts` binding, so the writer pass never selects it either.
#
# Everything in scope is either classified as a writer whose `ts` format is
# resolved and asserted, or classified as a non-writer for a stated structural
# reason, or reported as a failure.
#
# Two shapes used to blind both passes at once (#818): a `jq` invocation
# reached only through a shell variable (`JQ=jq; $JQ -nc …`), and a writer
# whose body sits inside a heredoc fed to an interpreter (`bash <<HD`). The
# first revision of those fixes matched the two spellings #818 happened to
# name, and PR #840's review then reproduced NINE near neighbours that each
# still exited 0 on real drift: `JQ="jq -n"`, `JQ=$(command -v jq)`,
# `TOOLS=(jq)` + `${TOOLS[0]}`, `env bash <<HD`, `command bash <<HD`,
# `SH=bash; $SH <<HD`, `cat <<HD | bash`, a function that execs `bash` used as
# the opener, and `if …; then JQ=jq; else JQ=jq; fi` (which the alias finder's
# line-start anchor missed — the same anchor bug #819a fixed in the resolver,
# reintroduced here). A table of spellings is a snapshot, and a snapshot goes
# stale silently. So both detectors now FAIL CLOSED on the shape rather than
# recognising a list of spellings:
#   * HEREDOCS. A heredoc body is blanked only when the guard can positively
#     classify its opener as an inert data consumer: the opener must be a
#     literal command word (not `$VAR`, not a substitution, not an
#     assignment-prefixed statement), its basename must be on the small
#     %HEREDOC_INERT allowlist below, and the statement must not pipe the
#     heredoc onward (`cat <<HD | bash`). ANY other opener — `env bash`,
#     `command bash`, `$SH`, a shell function, a command this guard has never
#     heard of — is reported by name and fails. The blanking stage sits
#     upstream of BOTH passes, so a writer hidden in an executed heredoc body
#     is invisible to both; "two structurally independent passes" cannot be
#     the answer here, which is why this one is an allowlist and not a
#     denylist.
#   * INDIRECT COMMAND WORDS. A variable whose assignments are all exactly
#     `VAR=jq` (found after a line start OR any shell separator, so the
#     single-line `then`/`else` form is seen) is registered as an alias and
#     `$VAR` is hunted as an alternate spelling of `jq`. ANY OTHER variable
#     used in command-word position whose assignments mention `jq` at all —
#     `JQ="jq -n"`, `JQ=$(command -v jq)`, `TOOLS=(jq)` read back as
#     `${TOOLS[0]}` — is reported by name and fails, because the invocation it
#     performs cannot be enumerated.
# Note what does NOT back these up: the pass-A/pass-B cross-check is not a
# general backstop for an indirection the guard cannot see. Pass B recognises
# a sink only by the target variable's NAME (`LOG`, `*_LOG_PATH`, …), so a
# writer appending to an off-pattern sink leaves pass B with nothing to
# cross-check. What the cross-check does give is the converse, and #840's
# round 2 showed the earlier wording here overclaimed it, so it is now stated
# as narrowly as the code warrants: EVERY writer pass A enumerates is
# accounted for, by one of exactly two outcomes and never by silence.
#   - If the shell variable the invocation is assigned to can be read, that
#     variable must reach a pass-B sink, so an off-pattern sink turns an
#     enumerated writer into a loud failure rather than a quiet pass. "Can be
#     read" means `VAR=$(jq …)` or `VAR="$(jq …)"`, with or without a
#     `local`/`declare`/`export`/`readonly`/`typeset` prefix and its flags,
#     and with or without a quoted command word (`VAR=$("$JQ" …)`).
#   - If it cannot be read — a direct redirect with no assignment at all, a
#     pipeline, an array element, a nested substitution — the site is
#     REPORTED by name and line, because the cross-check cannot run for it.
#     Reporting is the point: skipping such a site was itself the fail-open
#     (#818-4).
# What is NOT claimed: that pass B backstops a writer pass A never enumerated
# at all. The protection therefore comes from pass A being fail-closed about
# invocations it cannot classify — not from the two passes covering for each
# other.
#
# The previous revision of this guard had a `next unless`
# chain that dropped `--argjson ts`, an unquoted `--arg ts $X`, a
# double-quoted filter, a variable event key, and any filter that was not a
# bare `{…}` object literal — silently, each one a fail-open. Those are gone;
# see "How enumeration works" for what replaced them.
#
# ---------------------------------------------------------------------------
# STATED FAIL-OPENS — what still gets past, written down rather than implied
# ---------------------------------------------------------------------------
# The rules above fail closed on the shapes they cover; they do not make the
# guard complete, and this file will not claim that again (#818-4, #840). What
# is known to get past, as of this revision:
#   * A command name that never spells `jq` literally in the file — assembled
#     from pieces (`J=j; Q=q; "$J$Q" -nc …`), read from another file, or
#     supplied by the environment. The indirection rule keys on the literal
#     token `jq` appearing in an assignment; a value that never contains it is
#     not seen. (A writer built this way is still caught if its payload
#     variable reaches an on-pattern sink — pass B reports a payload assigned
#     by anything other than a recognised `jq` invocation — but not otherwise.)
#   * A session-log append whose target variable's name is off pass B's
#     `LOG`/`*_LOG`/`*_LOG_PATH`/`*_LOG_FILE` pattern AND whose writer pass A
#     did not enumerate. Both halves TOGETHER are not caught. Either half
#     alone is caught, and by a named failure rather than a quiet pass: an
#     off-pattern sink whose writer pass A did enumerate fails the
#     writer-to-sink cross-check described above, under whichever of its two
#     outcomes applies; an on-pattern sink fed by a writer pass A did not
#     enumerate fails pass B's own payload check. Before #840 round 2 the
#     "either half alone" claim was false for every assignment spelling but
#     `VAR=$(` — `VAR="$(jq …)"`, the commonest one, was enumerated and then
#     silently exempted. It holds now because the capture reads the other
#     spellings and reports the ones it still cannot read.
#   * `eval` of a string built at runtime, and any other construct whose text
#     does not exist statically. This guard never executes code.
#   * Everything the OUT OF SCOPE list above names, chiefly writers outside
#     `scripts/` (#811).
# A shape not on this list is not thereby covered — it is merely one nobody
# has reproduced yet. The honest reading is "these are the holes we know
# about", never "these are all the holes".
#
# ---------------------------------------------------------------------------
# WHY THIS SHAPE — the defect that produced it
# ---------------------------------------------------------------------------
# The first version of this guard enumerated by matching one *syntactic shape*
# of jq filter: `jq -n[c] … '{…event:"NAME"…ts:$ts…}'`, anchored at a literal
# `{`. `home-deferred.sh` builds one of its two `event:"triage"` lines with an
# object-*merge* filter (`'$rec + {ts:$ts, …}'`), so that writer was invisible,
# and splicing it to minute precision left the guard printing OK and exiting 0
# — reproducing, one level up, the exact false confidence #763 exists to
# prevent. A regex describing the filter shapes that happened to exist on the
# day it was written is a snapshot, and a snapshot goes stale silently.
#
# So enumeration is no longer keyed on any filter shape. It is keyed on the two
# things that structurally define a session-log write and cannot be restyled
# away: the write has a **timestamp binding** and it reaches a **log sink**.
#
# ---------------------------------------------------------------------------
# HOW ENUMERATION WORKS — two independent passes that must agree
# ---------------------------------------------------------------------------
# Each in-scope file is parsed by a small shell-aware tokenizer (comments and
# heredoc bodies blanked first, so prose that mentions `jq` is never mistaken
# for code) rather than scanned by a line regex.
#
# PASS A — the writer pass. Every `jq` invocation in the file is tokenized into
# shell words, honouring single quotes, double quotes, `$(…)` nesting and
# backslash-newline continuations. "Every invocation" also includes one
# reached only through a shell variable: a bare `VAR=jq` (or `"jq"`/`'jq'`)
# assignment is tracked first, and `$VAR`/`${VAR}` is then treated as an
# alternate spelling of the command word `jq` when hunting for invocations
# (#818 shape 1) — not just the literal token. Options are consumed against a
# table of jq's own flags, so the *filter* is identified positionally as the
# first operand — never by what it looks like. An invocation is a writer candidate
# if it binds a jq variable named `ts` (`--arg`, `--argjson`, `--rawfile` or
# `--slurpfile` — all four, not just `--arg`), or if its filter constructs a
# `ts:` key at all. A candidate must then yield BOTH a `ts` binding and a
# literal `event:"NAME"` key, or it is a failure. Concretely, and each of these
# was a silent drop before:
#   * `--argjson ts` / `--rawfile ts` — recognised as a binding like `--arg ts`.
#   * `--arg ts $X` unquoted — the tokenizer yields the same word as `"$X"`.
#   * a double-quoted filter — quoting is stripped before the filter is read,
#     so `"{ts:\$ts, event:\"note\"}"` reads identically to the quoted form.
#   * a filter that is an expression (`$rec + {…}`, `.a|.b`, `reduce …`) — the
#     filter is whatever word sits in the first operand position; its interior
#     syntax is never matched against.
#   * a variable event key (`event:$ev`) — FAILS, named, as unclassifiable.
#   * an unrecognised jq option — FAILS rather than being skipped past.
#
# PASS B — the sink pass. Independently, every place the file *appends to a
# session-log path* is located: a `>>` redirection onto a variable whose name is
# `LOG`, `LOG_PATH`, `LOG_FILE` or any `*_LOG`/`*_LOG_PATH`/`*_LOG_FILE`, plus
# every call to a log-helper function — a function discovered to contain such a
# redirection, which is how `home-deferred.sh`'s `emit_log` is found without
# this guard hardcoding its name. For each sink the payload variable is
# extracted (from the enclosing `{ … } >> "$LOG"` group when the redirection is
# on the closing brace, as `save-log.sh` writes it), and every assignment to
# that variable in the file is classified into exactly three outcomes: built by
# `jq` (checked by pass A); a pure literal with no command substitution AND no
# `ts:`/`event:` key, which is a separator written alongside the line rather
# than the line itself (`save-log.sh`'s `WRITE_BACK_PREFIX` is the only one in
# the tree); or ANYTHING ELSE — a `printf`, a heredoc, a `cat`, a literal that
# does look like a session-log object, a mix of forms — which FAILS. That is
# what closes the "printf/heredoc-built line" hole: such a line reaches a sink
# but is not jq-built, so pass B names it.
#
# THE PASSES MUST AGREE, in both directions:
#   * every pass-A writer's line variable must reach a pass-B sink — a
#     `ts`-bearing, `event`-keyed line that is built and then never logged is
#     reported, not assumed harmless;
#   * every pass-B jq-built payload must be a pass-A writer — a line that
#     reaches the log but that pass A did not classify is reported.
# Neither pass alone can go blind the way the shape regex did: pass A would
# have to miss a `ts` binding (it reads jq's own option grammar), and pass B
# would have to miss the append (it reads the redirection, not the builder).
#
# ---------------------------------------------------------------------------
# HOW `ts` IS RESOLVED — and why multiple definitions are a finding
# ---------------------------------------------------------------------------
# A site's raw `--arg ts EXPR` text is resolved iteratively within its own file:
#   1. EXPR containing a `date` call yields its format. The format is found by
#      walking the invocation's WORDS quote-aware and taking the single
#      argument that begins with `+` — not by a flat regex reaching for the
#      first `+` after `date`, which lifted a `+`-token out of an earlier
#      argument and resolved `date -u -d "$(printf %s +%FT%TZ)" +%Y-%m-%dT%H:%MZ`
#      to `%FT%TZ`, passing genuine drift silently (#840). A `date` call with
#      no `+` argument, with more than one, or whose format argument is itself
#      a substitution stays UNRESOLVED, which fails.
#   2. EXPR of the form `$(FUNC)` resolves FUNC's body (`home-deferred.sh`'s
#      `NOW_TS(){ date -u +%FT%TZ; }`).
#   3. EXPR of the form `$VAR` resolves VAR's assignments (`stamp-claim.sh`'s
#      `LOG_TS`, `preflight.sh`/`board-audit.sh`'s `GENERATED_AT`). An
#      assignment is found at line start OR right after a shell separator
#      token (`;`, `&&`, `||`, `then`, `else`, `elif`, `do`, `{`) on the same
#      line, and each candidate's right-hand side is read only up to the next
#      unquoted separator — not to end of line — so a single-line
#      `if …; then X=A; else X=B; fi` yields TWO separate definitions, A and
#      B, rather than one assignment whose text swallows the other (#819a).
#   4. Anything else is UNRESOLVED, which is a failure, never a skip.
# Resolution is depth-capped, so a self-referential chain fails loudly as
# UNRESOLVED instead of looping.
#
# When a name has MORE THAN ONE definition or assignment, this guard does not
# pick one. It resolves them all and requires them to agree; a disagreement is
# reported as AMBIGUOUS and fails. Taking the first definition (as the previous
# revision did for functions) is simply wrong — bash is last-wins for both
# functions and variables — but taking the last is not right either, because
# textual order is not reachability: a drifted assignment that actually reaches
# the write, followed by a correct one that never executes, would pass. Neither
# rule is sound without evaluating the script, which is out of scope, so the
# honest answer is to refuse to guess. Two definitions that agree cost nothing;
# two that disagree are a real ambiguity a human should look at.
#
# A bare empty value (`VAR=""` / `VAR=''` / `VAR=`) is the one exception: it is
# dropped before resolution rather than counted as a sibling that "fails to
# resolve", because an empty declare-then-assign carries no format to disagree
# with in the first place (#819b) — a routine `GENERATED_AT=""` ahead of the
# real assignment is not ambiguity. Anything else that fails to resolve is
# still a real disagreement and still fails: a definition using a `date`
# invocation this resolver's grammar cannot parse at all is not treated as an
# absence just because it also does not resolve.
#
# ---------------------------------------------------------------------------
# THE LEDGER — keyed per site, so a vanished site is a failure
# ---------------------------------------------------------------------------
# KNOWN_SITES below is a cross-check, never a scope: enumeration always scans
# the whole in-scope set and anything it finds that is not on the ledger fails
# as a new/unrecognised writer, while a ledger entry enumeration does not find
# fails as a removed or reshaped one.
#
# Keys are `file:event#ordinal`, the ordinal being that (file, event) pair's
# position in file order. Per-SITE, not per (file, event): the previous
# revision keyed on (file, event), which meant `home-deferred.sh`'s two
# `triage` sites collapsed to one key and the both-directions cross-check was
# satisfied while one of them was missing entirely. A key set that cannot count
# sites cannot notice a lost site. With ordinals, deleting either `triage` site
# leaves one `home-deferred.sh:triage#N` unmatched and the guard fails.
#
# The cross-check itself compares PER (file, event) COUNTS, not per ordinal
# key (#820): an ordinal is recomputed from whatever this run's enumeration
# finds, in file order, every time — it is not a stable identity a missing
# site can be named by. Deleting either of two same-named sites always leaves
# the same count mismatch (`ledger expects 2 …; enumeration found 1`), which
# detects the loss exactly as reliably as a per-key comparison did, without
# ever naming the wrong surviving ordinal as the one that vanished.
#
# Finding zero writers at all is a failure distinct from both — the
# vacuous-pass case #763 names explicitly.
#
# ---------------------------------------------------------------------------
# Follows this directory's harness conventions (see tests/README.md): a
# `report()` / fail-counter accumulator so one run surfaces every defect rather
# than aborting on the first, and LANG=C / LC_ALL=C pinning for the byte-level
# parsing below.
#
# UNMOCKED-CONTEXT: not applicable. This suite issues no `gh` invocation at all
# (grep the file: none) — a pure static read of the `scripts/` tree — so there
# is no mock to bypass and no tripwire to wire up, the same exemption
# `test_agent_rules_drift.sh` documents for itself (#568).
#
# Perl dependency: the quote-aware, multi-line tokenizer below needs a real
# parser, not a line-oriented `awk`/`sed` scan — `test_check_test_steps.sh`
# already carries the same dependency and documents why (grep its header for
# "perl-less"). A host with no `perl` on PATH cannot run this guard at all; it
# fails loudly rather than silently reporting zero findings as a pass.
set -euo pipefail
export LANG=C LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${TSDRIFT_SCRIPTS_DIR:-$SCRIPT_DIR/../scripts}"
# Canonicalise so messages and the `rel="${f#"$SCRIPTS_DIR"/}"` trim below both
# work against the same spelling of the path. A missing directory is left as
# given; the walk below reports it.
if [ -d "$SCRIPTS_DIR" ]; then SCRIPTS_DIR="$(cd "$SCRIPTS_DIR" && pwd)"; fi
EXPECT_FORMAT="${TSDRIFT_EXPECT_FORMAT:-%FT%TZ}"

fail=0
report(){ echo "FAIL: $*" >&2; fail=1; }

if ! command -v perl >/dev/null 2>&1; then
  report "perl not found on PATH — this guard cannot run without it (see header)"
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/session-log-ts-drift.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# The ledger. One entry per PHYSICAL WRITER SITE, keyed file:event#ordinal
# where the ordinal counts that (file, event) pair in file order. See the
# header's ledger section for why a (file, event) key was not enough.
# ---------------------------------------------------------------------------
KNOWN_SITES="
save-log.sh:note#1
board-audit.sh:note#1
preflight.sh:preflight#1
stamp-claim.sh:claim-stamp#1
stamp-claim.sh:claim#1
home-deferred.sh:triage#1
home-deferred.sh:triage#2
home-deferred.sh:triage#3
"

# ---------------------------------------------------------------------------
# The parser. Emits one TSV record per line, tag in field 1:
#   SITE <line> <event> <ts_expr> <assigned_var>   a classified writer site
#   SINK <line> <payload_var> <how>                a session-log append
#   NOTLINE <line> <var>                           sink payload that is a
#                                                  literal separator, not a line
#   ERR  <line> <message>                          unclassifiable — a failure
# ---------------------------------------------------------------------------
cat > "$WORK/enumerate.pl" <<'PERL_ENUMERATE'
use strict; use warnings;
my ($file, $base) = @ARGV;
open(my $fh, "<", $file) or do { print "ERR\t0\tcannot read $file: $!\n"; exit 0; };
local $/; my $raw = <$fh>; close $fh;

# --- code-only copy: comment bodies and heredoc bodies blanked to spaces so
# --- prose that mentions jq or event:"…" is never parsed as code. Offsets are
# --- preserved byte for byte, so line numbers stay true.
my $code = $raw;
# @out/emit/lineno declared here, BEFORE the blanking block below, because the
# blanking block itself now calls emit() for an executed heredoc (#818 shape
# 2) — it needs a fully-initialized @out to push onto at the point it runs,
# not one declared later in program order.
my @out;
sub lineno { my ($p) = @_; return 1 + (substr($code, 0, $p) =~ tr/\n//); }
sub emit { push @out, join("\t", @_); }

# A heredoc whose opener feeds an interpreter (#818 shape 2): the blanking
# below is one stage upstream of BOTH passes, so a writer hidden inside an
# executed heredoc body defeats the "two structurally independent passes"
# argument entirely — neither pass ever sees the text at all. Rather than
# blank it and let it vanish quietly, the opener is reported here as
# unclassifiable, named, before blanking proceeds.
# An ALLOWLIST of consumers whose heredoc body is inert data, not code. A
# denylist of interpreters was the first attempt and it was a snapshot: `env
# bash <<HD`, `command bash <<HD`, `SH=bash; $SH <<HD`, `cat <<HD | bash` and
# a function that execs `bash` all walked past it (#840 finding 1). Anything
# not positively classifiable as one of these is reported, not blanked.
my %HEREDOC_INERT = map { $_ => 1 } qw(cat tee jq grep sort uniq head tail wc tr fold column);
# Returns ($basename, undef) when the opener is a literal command word, or
# (undef, $why) when it is anything this guard cannot read as one — a `$VAR`
# opener, an assignment-prefixed statement, a substitution.
sub heredoc_opener_command {
  my ($text, $pos) = @_;
  my $sep = -1;
  for (my $q = $pos - 1; $q >= 0; $q--) {
    my $cc = substr($text, $q, 1);
    if ($cc eq "\n" || $cc eq ";" || $cc eq "(" || $cc eq "|" || $cc eq "&") { $sep = $q; last; }
  }
  my $stmt = substr($text, $sep + 1, $pos - $sep - 1);
  $stmt =~ s/^[ \t]+//;
  my $shown = substr($stmt, 0, 60); $shown =~ s/\s+/ /g; $shown =~ s/\s+$//;
  return (undef, "its opener `$shown` is not a literal command word (a variable, a substitution or an assignment prefix), so what consumes the body cannot be determined statically")
    unless $stmt =~ /^([A-Za-z0-9_.\/-]+)(?=[ \t]|\z)/;
  (my $base = $1) =~ s{.*/}{};
  return ($base, undef);
}
# True when the heredoc's own statement pipes onward: `cat <<HD | bash` is a
# shell heredoc wearing an inert opener.
sub heredoc_stmt_pipes {
  my ($text, $pos) = @_;
  my $n = length $text;
  my ($j, $sq, $dq) = ($pos, 0, 0);
  while ($j < $n) {
    my $ch = substr($text, $j, 1);
    if ($sq) { $sq = 0 if $ch eq "'"; $j++; next; }
    if ($dq) { if ($ch eq "\\") { $j += 2; next; } $dq = 0 if $ch eq '"'; $j++; next; }
    if ($ch eq "\\") { $j += 2; next; }
    if ($ch eq "'") { $sq = 1; $j++; next; }
    if ($ch eq '"') { $dq = 1; $j++; next; }
    return 0 if $ch eq "\n" || $ch eq ";";
    return 1 if $ch eq "|";
    $j++;
  }
  return 0;
}
{
  my @c = split //, $raw;
  my $n = scalar @c;
  my ($i, $sq, $dq, $prev_ws) = (0, 0, 0, 1);
  my @pending_heredocs;
  while ($i < $n) {
    my $ch = $c[$i];
    if ($ch eq "\n") {
      $sq = 0; $dq = 0; $prev_ws = 1; $i++;
      for my $hd (@pending_heredocs) {
        my ($tag, $dash) = @$hd;
        while ($i < $n) {
          my $eol = index($raw, "\n", $i); $eol = $n if $eol < 0;
          my $line = substr($raw, $i, $eol - $i);
          my $t = $line; $t =~ s/^\s+// if $dash; $t =~ s/\s+$//;
          for my $k ($i .. $eol - 1) { $c[$k] = " "; }
          $i = $eol + 1;
          last if $t eq $tag;
        }
      }
      @pending_heredocs = ();
      next;
    }
    if ($sq) { $sq = 0 if $ch eq "'"; $i++; next; }
    if ($dq) {
      if ($ch eq "\\") { $i += 2; next; }
      $dq = 0 if $ch eq '"';
      $i++; next;
    }
    if ($ch eq "\\") { $i += 2; $prev_ws = 0; next; }
    if ($ch eq "'") { $sq = 1; $i++; $prev_ws = 0; next; }
    if ($ch eq '"') { $dq = 1; $i++; $prev_ws = 0; next; }
    if ($ch eq "#" && $prev_ws) {
      while ($i < $n && $c[$i] ne "\n") { $c[$i] = " "; $i++; }
      next;
    }
    if ($ch eq "<" && $i + 1 < $n && $c[$i+1] eq "<" && $i + 2 < $n && $c[$i+2] eq "<") {
      # `<<<` is a here-STRING, not a here-document. Consume all three so the
      # second `<` is never re-examined and mistaken for a `<<TAG` opener —
      # which would blank the rest of the file as a heredoc body.
      $i += 3; $prev_ws = 1; next;
    }
    if ($ch eq "<" && $i + 1 < $n && $c[$i+1] eq "<") {
      if (substr($raw, $i) =~ /^<<(-?)\s*(?:'([^'\n]+)'|"([^"\n]+)"|([A-Za-z_][A-Za-z0-9_]*))/) {
        my $dash = $1 ? 1 : 0;
        my $tag = defined $2 ? $2 : defined $3 ? $3 : $4;
        my ($opener, $why) = heredoc_opener_command($raw, $i);
        my $ln = 1 + (substr($raw, 0, $i) =~ tr/\n//);
        if (!defined $opener) {
          emit("ERR", $ln, "heredoc \`<<$tag\`: $why — a heredoc body is blanked only when its opener is positively classifiable as an inert data consumer, and this one is not; blanking it and moving on would be exactly the silent drop #818 exists to close");
        } elsif (!$HEREDOC_INERT{$opener}) {
          emit("ERR", $ln, "heredoc opener \`$opener <<$tag\` is not on this guard's inert-consumer allowlist (cat, tee, jq, grep, sort, uniq, head, tail, wc, tr, fold, column) — its body may be executed rather than read as data, and this guard never executes code, so a session-log writer inside it cannot be verified; blanking it and moving on would be exactly the silent drop #818 exists to close");
        } elsif (heredoc_stmt_pipes($raw, $i)) {
          emit("ERR", $ln, "heredoc \`$opener <<$tag\` is piped onward within its own statement (\`cat <<HD | bash\` is a shell heredoc in disguise) — the consumer of the body cannot be identified, so it is reported rather than blanked");
        }
        push @pending_heredocs, [$tag, $dash];
        $i += length($&); $prev_ws = 0; next;
      }
    }
    $prev_ws = ($ch =~ /[\s;|&()<>]/) ? 1 : 0;
    $i++;
  }
  $code = join "", @c;
}

# --- grab a $( … ) region verbatim, quote- and nesting-aware.
# --- $i points at the "(". Returns (inner_text, index_after_close).
sub grab_paren {
  my ($s, $i) = @_;
  my $n = length $s;
  my ($depth, $j) = (0, $i);
  while ($j < $n) {
    my $ch = substr($s, $j, 1);
    if ($ch eq "\\") { $j += 2; next; }
    if ($ch eq "'") { my $k = index($s, "'", $j + 1); return (undef, $n) if $k < 0; $j = $k + 1; next; }
    if ($ch eq '"') {
      $j++;
      while ($j < $n) {
        my $d = substr($s, $j, 1);
        if ($d eq "\\") { $j += 2; next; }
        if ($d eq '$' && substr($s, $j + 1, 1) eq "(") {
          my (undef, $nj) = grab_paren($s, $j + 1); return (undef, $n) unless defined $nj; $j = $nj; next;
        }
        last if $d eq '"';
        $j++;
      }
      return (undef, $n) if $j >= $n;
      $j++; next;
    }
    if ($ch eq "(") { $depth++; $j++; next; }
    if ($ch eq ")") { $depth--; $j++; return (substr($s, $i + 1, $j - $i - 2), $j) if $depth == 0; next; }
    $j++;
  }
  return (undef, $n);
}

# --- tokenize a command starting at $pos into shell words. Each word is
# --- [text_with_quoting_removed, quote_marks_seen]. Stops at an unquoted
# --- command terminator. Returns (\@words, $error_or_undef).
sub tokenize {
  my ($s, $pos) = @_;
  my $n = length $s;
  my (@words, $w, $q);
  my $i = $pos;
  while ($i < $n) {
    my $ch = substr($s, $i, 1);
    if ($ch eq "\\") {
      my $nx = substr($s, $i + 1, 1);
      if ($nx eq "\n") { $i += 2; next; }
      $w = "" unless defined $w; $w .= $nx; $q = defined $q ? $q : ""; $i += 2; next;
    }
    if ($ch eq "'") {
      my $k = index($s, "'", $i + 1);
      return (\@words, "unterminated single quote") if $k < 0;
      $w = "" unless defined $w; $w .= substr($s, $i + 1, $k - $i - 1); $q = ($q // "") . "S";
      $i = $k + 1; next;
    }
    if ($ch eq '"') {
      my $j = $i + 1; my $acc = "";
      while ($j < $n) {
        my $d = substr($s, $j, 1);
        if ($d eq "\\") {
          my $nx = substr($s, $j + 1, 1);
          if ($nx eq "\n") { $j += 2; next; }
          $acc .= ($nx =~ /["\\\$`]/) ? $nx : "\\$nx"; $j += 2; next;
        }
        if ($d eq '$' && substr($s, $j + 1, 1) eq "(") {
          my ($inner, $nj) = grab_paren($s, $j + 1);
          return (\@words, "unterminated command substitution") unless defined $inner;
          $acc .= '$(' . $inner . ')'; $j = $nj; next;
        }
        last if $d eq '"';
        $acc .= $d; $j++;
      }
      return (\@words, "unterminated double quote") if $j >= $n;
      $w = "" unless defined $w; $w .= $acc; $q = ($q // "") . "D";
      $i = $j + 1; next;
    }
    if ($ch eq '$' && substr($s, $i + 1, 1) eq "(") {
      my ($inner, $nj) = grab_paren($s, $i + 1);
      return (\@words, "unterminated command substitution") unless defined $inner;
      $w = "" unless defined $w; $w .= '$(' . $inner . ')'; $q = ($q // "") . "C";
      $i = $nj; next;
    }
    if ($ch =~ /[ \t]/) {
      if (defined $w) { push @words, [$w, $q // ""]; $w = undef; $q = undef; }
      $i++; next;
    }
    last if $ch =~ /[\n;|&()<>]/;
    $w = "" unless defined $w; $w .= $ch; $q = $q // ""; $i++;
  }
  push @words, [$w, $q // ""] if defined $w;
  return (\@words, undef);
}

# --- jq's option grammar. Anything not listed is unrecognised, and an
# --- unrecognised option is a failure, never something to skip past.
my %JQ_OPT_2 = map { $_ => 1 } qw(--arg --argjson --slurpfile --rawfile);
my %JQ_OPT_1 = map { $_ => 1 } qw(--indent -f --from-file -L);
my %JQ_OPT_0 = map { $_ => 1 } qw(
  -n --null-input -c --compact-output -r --raw-output -j --join-output
  -e --exit-status -s --slurp -R --raw-input -a --ascii-output -S --sort-keys
  --tab --unbuffered --stream --stream-errors --seq --raw-output0 -h --help
  -V --version -C --color-output -M --monochrome-output --binary -b
);
my %JQ_OPT_REST = map { $_ => 1 } qw(--args --jsonargs);

# =========================================================================
# PASS A — the writer pass.
# =========================================================================
# An invocation through a shell variable holding the literal command name
# `jq` (`JQ=jq; $JQ -nc …`) is still a jq invocation — the literal token `jq`
# is not the only spelling of "run jq" (#818, shape 1). Found by the same
# simple assignment shape date_fmt-adjacent code elsewhere in this file does
# not need: a bare `VAR=jq` / `VAR="jq"` / `VAR='jq'` line.
# --- RHS of an assignment, from just after the `=` to the next unquoted
# --- statement separator. Same shape as resolve.pl's grab_value; duplicated
# --- rather than shared because the two Perl programs are separate files.
sub grab_rhs {
  my ($s, $i) = @_;
  my $n = length $s;
  my $start = $i;
  while ($i < $n) {
    my $ch = substr($s, $i, 1);
    if ($ch eq "\\") { $i += 2; next; }
    if ($ch eq "'") { my $k = index($s, "'", $i + 1); $i = ($k < 0 ? $n : $k + 1); next; }
    if ($ch eq '"') {
      $i++;
      while ($i < $n) {
        my $d = substr($s, $i, 1);
        if ($d eq "\\") { $i += 2; next; }
        last if $d eq '"';
        $i++;
      }
      $i++; next;
    }
    if ($ch eq '$' && substr($s, $i + 1, 1) eq "(") {
      my (undef, $after) = grab_paren($s, $i + 1);
      $i = (defined $after ? $after : $n); next;
    }
    if ($ch eq "(" && $i == $start) {
      my (undef, $after) = grab_paren($s, $i);
      $i = (defined $after ? $after : $n); next;
    }
    last if $ch eq "\n" || $ch eq ";";
    last if $ch eq "&" && substr($s, $i + 1, 1) eq "&";
    last if $ch eq "|" && substr($s, $i + 1, 1) eq "|";
    $i++;
  }
  my $val = substr($s, $start, $i - $start);
  $val =~ s/\s+$//;
  return $val;
}

# Every assignment in the file, keyed by name, its RHS read with grab_rhs. The
# anchor is a line start OR any shell separator — NOT line start alone, which
# is the bug #819a fixed in the resolver and which the first revision of this
# alias finder reintroduced here, missing `if …; then JQ=jq; else JQ=jq; fi`
# (#840 finding 1, and #842).
my %var_rhs;
while ($code =~ /(?:\A|\n|;|&&|\|\||\{|\bthen\b|\belse\b|\belif\b|\bdo\b)[ \t]*([A-Za-z_][A-Za-z0-9_]*)=/g) {
  my ($name, $apos) = ($1, $-[1]);
  push @{ $var_rhs{$name} }, [ grab_rhs($code, pos($code)), lineno($apos) ];
}
# A name is an alias for `jq` only when EVERY assignment to it is exactly the
# bare command word.
my %jq_alias;
for my $name (keys %var_rhs) {
  my @vals = map { $_->[0] } @{ $var_rhs{$name} };
  next unless @vals;
  next if grep { $_ !~ /^(?:"jq"|'jq'|jq)$/ } @vals;
  $jq_alias{$name} = 1;
}
# FAIL CLOSED on every other indirection (#840 finding 1). Any variable used
# in command-word position whose assignments mention `jq` in a form other than
# the bare alias above — `JQ="jq -n"`, `JQ=$(command -v jq)`, `TOOLS=(jq)`
# read back as `${TOOLS[0]}` — performs an invocation this guard cannot
# enumerate, so it is named and failed rather than dropped. The alternative,
# adding each new spelling to a table as it is discovered, is the snapshot
# this whole file exists to argue against.
# Command-word position is found by a quote-aware walk, not by a regex over
# the whole file: `$code` still contains jq FILTERS verbatim (only comments
# and heredoc bodies are blanked), and jq's own filter language spells its
# variables `$name` and its pipes `|` exactly as the shell does, so a flat
# regex reads `map(select(...)) as $missing_ts` inside a quoted filter as a
# shell command word. Only offsets outside quotes are considered.
sub check_indirect_jq {
  my ($name, $var_rhs, $reported) = @_;
  return if $jq_alias{$name};
  return if $reported->{$name}++;
  my $vals = $var_rhs->{$name} or return;
  my @jqish = grep { $_->[0] =~ /(?:\A|[^A-Za-z0-9_.\/-])jq(?:[^A-Za-z0-9_.\/-]|\z)/ } @$vals;
  return unless @jqish;
  my $shown = substr($jqish[0][0], 0, 60); $shown =~ s/\s+/ /g;
  emit("ERR", $jqish[0][1], "\`\$$name\` is used as a command word and is assigned a value mentioning \`jq\` (\`$name=$shown\`) in a form this guard cannot classify as the plain alias \`$name=jq\` — the jq invocation it performs cannot be enumerated, so it is reported rather than dropped (#818/#840)");
}
{
  my %reported;
  my $n = length $code;
  my ($i, $sq, $dq, $cmdpos) = (0, 0, 0, 1);
  while ($i < $n) {
    my $ch = substr($code, $i, 1);
    if ($sq) { $sq = 0 if $ch eq "'"; $i++; next; }
    if ($dq) {
      if ($ch eq "\\") { $i += 2; next; }
      $dq = 0 if $ch eq '"';
      $i++; next;
    }
    if ($ch eq "\n") { $cmdpos = 1; $i++; next; }
    if ($ch eq ";" || $ch eq "|" || $ch eq "&" || $ch eq "(" || $ch eq "{") { $cmdpos = 1; $i++; next; }
    if ($ch eq " " || $ch eq "\t") { $i++; next; }
    if ($ch eq "\\") { $cmdpos = 0; $i += 2; next; }
    if ($cmdpos) {
      # `then`/`else`/`elif`/`do` keep the next word in command position.
      if (substr($code, $i) =~ /^(?:then|else|elif|do)(?=[ \t\n])/) { $i += length($&); next; }
      # `$VAR …`, `${VAR} …`, `${ARR[0]} …` and the quoted `"$VAR" …` form.
      if (substr($code, $i) =~ /^"?\$\{?([A-Za-z_][A-Za-z0-9_]*)(?:\[[^\]\n]*\])?\}?"?(?=[ \t])/) {
        check_indirect_jq($1, \%var_rhs, \%reported);
        $i += length($&); $cmdpos = 0; next;
      }
    }
    if ($ch eq "'") { $sq = 1; $i++; $cmdpos = 0; next; }
    if ($ch eq '"') { $dq = 1; $i++; $cmdpos = 0; next; }
    $cmdpos = 0; $i++;
  }
}
my $alias_alt = join("|", map { quotemeta($_) } sort keys %jq_alias);
my $cmdword_re = $alias_alt eq ""
  ? qr/jq/
  : qr/(?:jq|\$\{?(?:$alias_alt)\}?)/;

my %site_ordinal;
my @sites;
# The command word may itself be quoted — `"$JQ" -nc …` is as much an
# invocation as `$JQ -nc …`, and matching only the bare form left a tenth
# writer shape passing silently behind an off-pattern sink (found by probing
# this fix against its own near neighbours, #840). Both spellings are matched;
# tokenizing resumes after the closing quote, hence `$+[0]` rather than an
# offset computed from the command word's own length.
while ($code =~ /(?:\A|[\s;|&(\$`])(?:"($cmdword_re)"|($cmdword_re))(?=[ \t])/g) {
  my $word = defined $1 ? $1 : $2;
  my $jqpos = defined $1 ? $-[1] : $-[2];
  my $ln = lineno($jqpos);
  my ($words, $terr) = tokenize($code, $+[0]);
  if (defined $terr) { emit("ERR", $ln, "jq invocation could not be tokenized ($terr) — unparsable, treated as a finding, not a skip"); next; }

  my ($ts_expr, $ts_flag, $filter, $filter_q, $opt_err, $rest_positional);
  my $k = 0;
  while ($k < scalar @$words) {
    my ($t, $qm) = @{ $words->[$k] };
    if (!$rest_positional && $qm eq "" && $t eq "--") { $rest_positional = 1; $k++; next; }
    if (!$rest_positional && $qm eq "" && $t =~ /^-./) {
      if ($JQ_OPT_2{$t}) {
        my $name = $words->[$k+1] ? $words->[$k+1][0] : undef;
        my $val  = $words->[$k+2] ? $words->[$k+2][0] : undef;
        unless (defined $name && defined $val) { $opt_err = "`$t` at end of invocation with no name/value pair"; last; }
        if ($name eq "ts") { $ts_expr = $val; $ts_flag = $t; }
        $k += 3; next;
      }
      if ($JQ_OPT_1{$t}) { $k += 2; next; }
      if ($JQ_OPT_0{$t}) { $k += 1; next; }
      if ($JQ_OPT_REST{$t}) { $rest_positional = 1; $k += 1; next; }
      if ($t =~ /^-[ncrjesRaSChMVb]+$/) { $k += 1; next; }
      $opt_err = "unrecognised jq option `$t`"; last;
    }
    if (!defined $filter) { $filter = $t; $filter_q = $qm; }
    $k++;
  }
  if (defined $opt_err) { emit("ERR", $ln, "jq invocation not classifiable: $opt_err — this guard refuses to guess whether it is a session-log writer"); next; }

  my $builds_ts_key = (defined $filter && $filter =~ /(?<![\w."'])ts\s*:/) ? 1 : 0;
  next unless defined($ts_expr) || $builds_ts_key;

  unless (defined $filter) {
    emit("ERR", $ln, "jq invocation binds a `ts` variable but has no filter operand this guard can read (a `\$FILTER` variable, or a filter read from a file) — cannot classify as a session-log writer");
    next;
  }
  if ($filter_q eq "" && $filter =~ /^\$/) {
    emit("ERR", $ln, "jq filter is the shell variable `$filter` — its text is not visible here, so a `ts`-bearing invocation cannot be classified; inline the filter or exclude it deliberately");
    next;
  }
  unless (defined $ts_expr) {
    emit("ERR", $ln, "jq filter constructs a `ts:` key but the invocation binds no shell-supplied `ts` (no --arg/--argjson/--rawfile/--slurpfile ts) — its timestamp format cannot be verified");
    next;
  }
  my $event;
  if ($filter =~ /event\s*:\s*"([^"]+)"/) {
    $event = $1;
  } elsif ($filter =~ /event\s*:/) {
    emit("ERR", $ln, "session-log writer has a non-literal `event:` key (a variable or expression) — the event name cannot be read statically, so this site cannot be ledgered; make it a literal or exclude it deliberately");
    next;
  } else {
    emit("ERR", $ln, "jq invocation binds `--arg ts` but constructs no `event:` key — this guard cannot tell whether it is a session-log write; classify it explicitly");
    next;
  }

  # The variable this invocation is assigned to, in the spellings shells
  # actually use. `VAR=$(jq …)` is only one of them: the substitution is
  # ordinarily double-quoted (`VAR="$(jq …)"`), the command word inside it may
  # itself be quoted (`VAR=$("$JQ" …)`, `VAR="$("$JQ" …)"`), and the assignment
  # may carry a `local`/`declare`/`export`/`readonly`/`typeset` prefix with its
  # own flags. Matching only the bare form left every other spelling holding
  # the sentinel `-`, which the cross-check below then dropped in silence —
  # the exact fail-open this guard exists to eliminate (#818-4, #840 round 2).
  # `$jqpos` is the offset of the command word itself, INSIDE its quotes when
  # it is quoted, which is what the optional trailing `"` absorbs.
  my $assigned = "-";
  if (substr($code, 0, $jqpos) =~ /
        (?:\A|[\s;|&(])                                         # command start
        (?:(?:local|declare|export|readonly|typeset)
           [ \t]+ (?:-[A-Za-z]+ [ \t]+)* )?                      # optional prefix
        ([A-Za-z_][A-Za-z0-9_]*) =                               # the variable
        "?                                                       # optional quoted RHS
        \$\( \s*                                                 # the substitution
        "?                                                       # optional quoted cmd word
      \z/x) { $assigned = $1; }

  my $ord = ++$site_ordinal{"$base:$event"};
  emit("SITE", $ln, $event, $ts_expr, $assigned, $ts_flag, $ord);
  push @sites, { line => $ln, event => $event, var => $assigned };
}

# =========================================================================
# PASS B — the sink pass.
# =========================================================================
my $LOGVAR = qr/(?:[A-Z0-9_]+_)?LOG(?:_PATH|_FILE)?/;

# Function bodies, so a log-helper can be discovered by what it contains
# rather than by being named `emit_log` in this guard.
my %fnbody;
while ($code =~ /(?:\A|\n)[ \t]*(?:function[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(\)[ \t]*\{/g) {
  my ($name, $open) = ($1, $+[0] - 1);
  my $n = length $code; my ($depth, $j) = (0, $open);
  while ($j < $n) {
    my $ch = substr($code, $j, 1);
    if ($ch eq "\\") { $j += 2; next; }
    if ($ch eq "'") { my $k2 = index($code, "'", $j + 1); last if $k2 < 0; $j = $k2 + 1; next; }
    if ($ch eq '"') { my $k2 = $j + 1; while ($k2 < $n) { my $d = substr($code,$k2,1); if ($d eq "\\") { $k2 += 2; next; } last if $d eq '"'; $k2++; } $j = $k2 + 1; next; }
    if ($ch eq "{") { $depth++; $j++; next; }
    if ($ch eq "}") { $depth--; $j++; last if $depth == 0; next; }
    $j++;
  }
  $fnbody{$name} = [$open, $j];
}
my @helpers = sort grep {
  my ($s2, $e2) = @{ $fnbody{$_} };
  substr($code, $s2, $e2 - $s2) =~ />>[ \t]*"?\$\{?$LOGVAR\}?"?/;
} keys %fnbody;

# Payload extraction for one sink region.
sub payloads_of {
  my ($region) = @_;
  my (@vars, @errs);
  push @errs, "built by a heredoc" if $region =~ /<<-?\s*['"]?[A-Za-z_]/;
  push @errs, "built by `cat`" if $region =~ /(?:\A|[\s;|&(])cat[ \t]+[^|;\n]*>>/;
  while ($region =~ /(?:\A|[\s;|&({])(?:printf|echo)[ \t]+(?:(?:-\S+|'[^']*'|"[^"]*")[ \t]+)*?"?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"?/g) {
    push @vars, $1;
  }
  return (\@vars, \@errs);
}

my @sinkrecs;
while ($code =~ />>[ \t]*"?\$\{?($LOGVAR)\}?"?/g) {
  my $mpos = $-[0];
  my $ln = lineno($mpos);
  my $in_helper = 0;
  for my $h (@helpers) { my ($s2, $e2) = @{ $fnbody{$h} }; $in_helper = 1 if $mpos >= $s2 && $mpos < $e2; }

  # Region: the sink's own line, widened to the enclosing `{ … }` group when
  # the redirection sits on the closing brace (save-log.sh writes it that way).
  my $ls = rindex($code, "\n", $mpos) + 1;
  my $le = index($code, "\n", $mpos); $le = length($code) if $le < 0;
  my $region = substr($code, $ls, $le - $ls);
  if ($region =~ /^[ \t]*\}/) {
    my $back = substr($code, 0, $ls);
    my @lines = split /\n/, $back, -1;
    my $acc = ""; my $found = 0;
    for (my $z = $#lines; $z >= 0 && $z > $#lines - 200; $z--) {
      $acc = $lines[$z] . "\n" . $acc;
      if ($lines[$z] =~ /^[ \t]*\{[ \t]*$/) { $found = 1; last; }
    }
    $region = $acc . $region if $found;
  }
  my ($vars, $errs) = payloads_of($region);
  for my $e (@$errs) { emit("ERR", $ln, "session-log append is $e — its payload is not a jq-built line this guard can classify"); }
  my @keep = grep { !($in_helper && /^[0-9]+$/) } @$vars;
  if (!@keep && !@$errs) {
    if ($in_helper) {
      # A helper writing its own parameter: call sites carry the payload.
    } else {
      emit("ERR", $ln, "session-log append whose payload variable could not be identified — cannot verify the line it writes was built with a pinned `ts`");
    }
  }
  push @sinkrecs, { line => $ln, vars => \@keep };
}

# Calls to log-helper functions are sinks too.
for my $h (@helpers) {
  my ($hs, $he) = @{ $fnbody{$h} };
  while ($code =~ /(?:\A|\n)[ \t]*\Q$h\E[ \t]+(\S[^\n]*)/g) {
    my $mpos = $-[0];
    next if $mpos >= $hs - length($h) - 8 && $mpos < $he;
    my $ln = lineno($mpos);
    my $arg = $1;
    if ($arg =~ /^"?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"?/) {
      push @sinkrecs, { line => $ln, vars => [$1] };
    } else {
      emit("ERR", $ln, "call to log-helper `$h` with an argument this guard cannot resolve to a variable (`$arg`) — the line it logs cannot be checked");
    }
  }
}

# Classify every sink payload variable's assignments.
my %payload_is_jq;
my %seen_payload;
for my $s (@sinkrecs) {
  for my $v (@{ $s->{vars} }) {
    next if $seen_payload{$v}++;
    my @rhs;
    while ($code =~ /(?:\A|\n)[ \t]*\Q$v\E=((?:[^\n\\]|\\\n|\\.)*)/g) { push @rhs, $1; }
    unless (@rhs) {
      emit("ERR", $s->{line}, "session-log append writes `\$$v`, which has no assignment in this file — its origin, and so its `ts` format, cannot be established");
      next;
    }
    my ($njq, $nlit, $nother) = (0, 0, 0);
    for my $r (@rhs) {
      if ($r =~ /^\s*\$\(\s*jq[ \t]/) { $njq++; }
      elsif ($r !~ /\$\(/ && $r !~ /`/) { $nlit++; }
      else { $nother++; }
    }
    if ($nother || ($njq && $nlit)) {
      emit("ERR", $s->{line}, "session-log append writes `\$$v`, which is assigned by something other than a single `jq` invocation (printf, a heredoc, a command substitution, or a mix of forms across " . scalar(@rhs) . " assignments) — a line not built by jq carries a `ts` this guard cannot resolve");
      next;
    }
    if ($njq) { $payload_is_jq{$v} = 1; }
    elsif (grep { /(?:"|\\")ts(?:"|\\")?\s*:/ || /event\s*:/ } @rhs) {
      # A pure literal is normally a separator written alongside the line
      # (save-log.sh's WRITE_BACK_PREFIX). One that looks like a session-log
      # object is a hand-rolled line with a hardcoded `ts` — the same
      # fail-open as the printf case, so it fails the same way.
      emit("ERR", $s->{line}, "session-log append writes `\$$v`, whose assignments are string literals that already look like a session-log object (a `ts:` or `event:` key) — a hand-written line carries a `ts` no format resolution can check");
    }
    else { emit("NOTLINE", $s->{line}, $v); }
  }
}

# The two passes must agree, in both directions.
for my $s (@sites) {
  if ($s->{var} eq "-") {
    # No silent exit. A writer whose assigned variable cannot be determined
    # is one the cross-check cannot run for, so it is REPORTED rather than
    # dropped — `next if ... eq "-"` was itself the fail-open (#818-4, #840).
    emit("ERR", $s->{line}, "writer site builds a session-log line (a `ts` binding and an `event:\"$s->{event}\"` key) but is not a plain variable assignment this guard can read (`VAR=\$(…)`, `VAR=\"\$(…)\"`, with or without a `local`/`declare`/`export`/`readonly`/`typeset` prefix and with or without a quoted command word) — it may be a direct redirect, a pipeline, an array element or a nested substitution, so the writer-to-sink cross-check cannot run for it and it is reported rather than dropped (#818-4)");
    next;
  }
  emit("ERR", $s->{line}, "writer site builds `\$$s->{var}` with a `ts` binding and an `event:\"$s->{event}\"` key, but `\$$s->{var}` never reaches a session-log append in this file — either it is not a session-log write (say so) or the append is in a shape pass B cannot see")
    unless $payload_is_jq{ $s->{var} };
}
my %site_var = map { $_->{var} => 1 } @sites;
for my $v (sort keys %payload_is_jq) {
  emit("ERR", 0, "`\$$v` is jq-built and reaches a session-log append, but no jq invocation assigning it was classified as a writer by pass A — the two passes disagree")
    unless $site_var{$v};
}

print "$_\n" for @out;
PERL_ENUMERATE

# ---------------------------------------------------------------------------
# The resolver. Resolves a raw ts expression to a date(1) format string within
# its own file. Multiple definitions/assignments must AGREE (see header):
# prints the format, or UNRESOLVED:<why>, or AMBIGUOUS:<why>.
# ---------------------------------------------------------------------------
cat > "$WORK/resolve.pl" <<'PERL_RESOLVE'
use strict; use warnings;
my ($file, $expr) = @ARGV;
open(my $fh, "<", $file) or do { print "UNRESOLVED:cannot read $file: $!"; exit 0; };
local $/; my $content = <$fh>; close $fh;

# Split a `date` invocation into shell WORDS, starting just after the command
# word. Quote-aware: a `$(…)` or a quoted argument collapses into the word it
# is part of and never contributes an argument boundary of its own. Stops at
# the end of the invocation.
sub date_words {
  my ($text, $i) = @_;
  my $n = length $text;
  my (@words, $cur, $have);
  $cur = ""; $have = 0;
  while ($i < $n) {
    my $ch = substr($text, $i, 1);
    if ($ch eq "\\") { $cur .= substr($text, $i + 1, 1); $have = 1; $i += 2; next; }
    if ($ch eq "'") {
      my $k = index($text, "'", $i + 1);
      return () if $k < 0;
      $cur .= substr($text, $i + 1, $k - $i - 1); $have = 1; $i = $k + 1; next;
    }
    if ($ch eq '"') {
      $i++;
      while ($i < $n) {
        my $d = substr($text, $i, 1);
        if ($d eq "\\") { $cur .= substr($text, $i + 1, 1); $i += 2; next; }
        last if $d eq '"';
        $cur .= $d; $i++;
      }
      return () if $i >= $n;
      $have = 1; $i++; next;
    }
    if ($ch eq '$' && substr($text, $i + 1, 1) eq "(") {
      my ($depth, $j) = (0, $i + 1);
      while ($j < $n) {
        my $d = substr($text, $j, 1);
        if ($d eq "\\") { $j += 2; next; }
        if ($d eq "'") { my $k = index($text, "'", $j + 1); $j = ($k < 0 ? $n : $k + 1); next; }
        if ($d eq '"') {
          $j++;
          while ($j < $n) { my $e = substr($text, $j, 1); if ($e eq "\\") { $j += 2; next; } last if $e eq '"'; $j++; }
          $j++; next;
        }
        if ($d eq "(") { $depth++; $j++; next; }
        if ($d eq ")") { $depth--; $j++; last if $depth == 0; next; }
        $j++;
      }
      $cur .= "\x00SUB\x00"; $have = 1; $i = $j; next;
    }
    if ($ch eq " " || $ch eq "\t") { push @words, $cur if $have; $cur = ""; $have = 0; $i++; next; }
    last if $ch eq "\n" || $ch eq ";" || $ch eq "|" || $ch eq "&" || $ch eq ")" || $ch eq "`" || $ch eq ">" || $ch eq "<";
    $cur .= $ch; $have = 1; $i++;
  }
  push @words, $cur if $have;
  return @words;
}

sub date_fmt {
  my ($text) = @_;
  # The format flag is the ARGUMENT that begins with `+`, identified by
  # walking the invocation's words — never by a flat regex. `date\s+[^+\n]*\+(\S+)`
  # takes the first `+` ANYWHERE after `date`, which need not be the format
  # flag: `date -u -d "$(printf %s +%FT%TZ)" +%Y-%m-%dT%H:%MZ` resolved to
  # `%FT%TZ` and passed genuine drift silently (#840 finding 2). Walking words
  # keeps #819a's own shape working (`date -u -d "@$EPOCH" +%FT%TZ`, which the
  # older anchored `(?:-u\s+)?` could not parse at all) while a call whose
  # format argument cannot be identified stays UNRESOLVED, which fails loudly.
  while ($text =~ /(?:\A|[\s;|&(`\$])date(?=[ \t])/g) {
    my @words = date_words($text, pos($text));
    my @fmts = grep { /^\+/ } @words;
    next unless @fmts;                    # this `date` has no format argument
    return undef if @fmts > 1;            # two `+` arguments — refuse to guess
    my $fmt = $fmts[0];
    $fmt =~ s/^\+//;
    return undef if $fmt eq "";           # a bare `+`
    return undef if $fmt =~ /\x00SUB\x00/; # format built by a substitution
    return $fmt;
  }
  return undef;
}

# --- grab an assignment's RHS text starting right after the `=`, stopping at
# --- the first unquoted statement separator (`;`, newline, `&&`, `||`) —
# --- quote- and `$(...)`-nesting-aware, so a single-line
# --- `if …; then X=A; else X=B; fi` yields TWO separate RHS bodies instead of
# --- one match's capture swallowing the rest of the line (#819a).
sub grab_value {
  my ($s, $i) = @_;
  my $n = length $s;
  my $start = $i;
  while ($i < $n) {
    my $ch = substr($s, $i, 1);
    if ($ch eq "\\") { $i += 2; next; }
    if ($ch eq "'") { my $k = index($s, "'", $i + 1); $i = ($k < 0 ? $n : $k + 1); next; }
    if ($ch eq '"') {
      $i++;
      while ($i < $n) {
        my $d = substr($s, $i, 1);
        if ($d eq "\\") { $i += 2; next; }
        last if $d eq '"';
        $i++;
      }
      $i++; next;
    }
    if ($ch eq '$' && substr($s, $i + 1, 1) eq "(") {
      my ($depth, $j) = (0, $i + 1);
      while ($j < $n) {
        my $d = substr($s, $j, 1);
        if ($d eq "\\") { $j += 2; next; }
        if ($d eq "'") { my $k = index($s, "'", $j + 1); $j = ($k < 0 ? $n : $k + 1); next; }
        if ($d eq '"') {
          $j++;
          while ($j < $n) { my $e = substr($s, $j, 1); if ($e eq "\\") { $j += 2; next; } last if $e eq '"'; $j++; }
          $j++; next;
        }
        if ($d eq "(") { $depth++; $j++; next; }
        if ($d eq ")") { $depth--; $j++; last if $depth == 0; next; }
        $j++;
      }
      $i = $j; next;
    }
    last if $ch eq "\n" || $ch eq ";";
    last if $ch eq "&" && substr($s, $i + 1, 1) eq "&";
    last if $ch eq "|" && substr($s, $i + 1, 1) eq "|";
    $i++;
  }
  my $val = substr($s, $start, $i - $start);
  $val =~ s/\s+$//;
  return $val;
}

my $DEPTH_CAP = 8;
sub resolve {
  my ($cur, $depth) = @_;
  return ("UNRESOLVED", "resolution exceeded the depth cap of $DEPTH_CAP (a self-referential or over-long chain)") if $depth > $DEPTH_CAP;
  $cur =~ s/^\s+|\s+$//g;
  if (defined(my $f = date_fmt($cur))) { return ("OK", $f); }

  my @bodies; my $what;
  if ($cur =~ /^\$\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)$/) {
    my $fn = $1; $what = "function $fn";
    while ($content =~ /(?:\A|\n)[ \t]*(?:function[ \t]+)?\Q$fn\E[ \t]*\(\)[ \t]*\{(.*?)\}/gs) { push @bodies, $1; }
    return ("UNRESOLVED", "`$cur` names a function with no definition in this file") unless @bodies;
  } elsif ($cur =~ /^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$/) {
    my $var = $1; $what = "variable $var";
    # Assignment start: line start, or preceded by a shell separator token
    # (`;`, `&&`, `||`, `then`, `else`, `elif`, `do`, `{`) — not just line
    # start, so a single-line `if …; then X=…; else X=…; fi` is seen (#819a).
    # `grab_value` (not a greedy `[^\n]*` capture) stops each body at the next
    # unquoted separator, so two assignments on one line yield two bodies,
    # not one body with the second assignment's text appended to the first.
    while ($content =~ /(?:\A|\n|;|&&|\|\||\{|\bthen\b|\belse\b|\belif\b|\bdo\b)[ \t]*\Q$var\E=/g) {
      push @bodies, grab_value($content, pos($content));
    }
    return ("UNRESOLVED", "`$cur` has no assignment in this file (a positional parameter, an inherited export, or an environment variable)") unless @bodies;
  } else {
    return ("UNRESOLVED", "`$cur` is not a `date` call, a `\$(FUNC)` call, or a `\$VAR` this resolver's grammar covers");
  }

  my (%fmts, @probs, $n_bodies);
  $n_bodies = scalar @bodies;
  for my $b (@bodies) {
    my $trimmed = $b; $trimmed =~ s/^\s+|\s+$//g;
    # A bare empty value (`""`, `''`, or nothing at all — the routine
    # declare-then-assign `VAR=""` ahead of the real assignment) carries no
    # format to (dis)agree with at all, so it is dropped before resolution
    # rather than resolved and counted as a disagreement (#819b). Anything
    # else that fails to resolve — including a body this resolver's grammar
    # simply cannot parse — is a real problem and stays in @probs below; it
    # is not an "absence" just because it also failed to resolve.
    next if $trimmed eq "" || $trimmed eq '""' || $trimmed eq "''";
    my ($st, $val) = resolve($b, $depth + 1);
    if ($st eq "OK") { $fmts{$val} = 1; } else { push @probs, $val; }
  }
  if (@probs && !%fmts) { return ("UNRESOLVED", $probs[0]); }
  if (!%fmts && !@probs) {
    # Every definition was a bare-empty placeholder — genuinely no format
    # anywhere to resolve to.
    return ("UNRESOLVED", "`$cur` names $what, whose only " . ($n_bodies == 1 ? "definition is" : "definitions are") . " a bare empty value with no date format");
  }
  if (@probs) {
    return ("AMBIGUOUS", "$n_bodies definition(s) of $what, and " . scalar(@probs) . " of them do not resolve to a date format at all (" . join("; ", @probs) . ")");
  }
  my @k = sort keys %fmts;
  if (@k > 1) {
    return ("AMBIGUOUS", scalar(@bodies) . " definitions of $what resolve to DIFFERENT formats (" . join(", ", map { "`$_`" } @k) . "); bash takes the last, but textual order is not reachability, so this guard refuses to guess — collapse them to one");
  }
  return ("OK", $k[0]);
}

my ($status, $val) = resolve($expr, 0);
print $status eq "OK" ? $val : "$status:$val";
PERL_RESOLVE

# ---------------------------------------------------------------------------
# Enumerate. Every file under SCRIPTS_DIR, recursively, whatever it is named.
# ---------------------------------------------------------------------------
RECORDS="$WORK/records.tsv"
: > "$RECORDS"
FILELIST="$WORK/files.txt"
if ! find "$SCRIPTS_DIR" -type f 2>/dev/null | LC_ALL=C sort > "$FILELIST"; then
  report "could not walk $SCRIPTS_DIR — an unwalkable scripts directory is a finding, not an empty set"
fi
FILE_COUNT=$(wc -l < "$FILELIST" | tr -d ' ')
if [ "$FILE_COUNT" -eq 0 ]; then
  report "no files found under $SCRIPTS_DIR — nothing was scanned, which is a vacuous pass and is treated as a failure"
fi
while IFS= read -r f; do
  [ -n "$f" ] || continue
  # Display/ledger name is the path RELATIVE to SCRIPTS_DIR, not the basename:
  # `lib/emit-note` and `emit-note` are different writers and must not collide.
  rel="${f#"$SCRIPTS_DIR"/}"
  if [ ! -r "$f" ]; then
    report "$rel: unreadable — an unreadable file in $SCRIPTS_DIR is a finding, not a skip"
    continue
  fi
  # Field 1 is the absolute path (so the resolver reads the right file even in
  # a subdirectory); field 2 is the relative display name used in messages and
  # ledger keys.
  perl "$WORK/enumerate.pl" "$f" "$rel" | sed "s|^|$f\t$rel\t|" >> "$RECORDS"
done < "$FILELIST"

# ---------------------------------------------------------------------------
# Report every parser finding, then resolve every writer site.
# ---------------------------------------------------------------------------
FOUND_KEYS="$WORK/found_keys.txt"
: > "$FOUND_KEYS"
TOTAL_SITES=0
TAB="$(printf '\t')"

while IFS="$TAB" read -r path base tag line a b c d e; do
  [ -n "$tag" ] || continue
  case "$tag" in
    ERR)
      report "$base:$line: $a"
      ;;
    NOTLINE)
      : # a literal separator written alongside a log line (save-log.sh's
        # WRITE_BACK_PREFIX); classified, reported by the accounting line below.
      ;;
    SITE)
      event="$a"; ts_expr="$b"; assigned="$c"; ts_flag="$d"; ordinal="$e"
      TOTAL_SITES=$((TOTAL_SITES + 1))
      resolved="$(perl "$WORK/resolve.pl" "$path" "$ts_expr" 2>/dev/null || echo "UNRESOLVED:resolver crashed")"
      case "$resolved" in
        UNRESOLVED:*)
          report "$base:$line event=\"$event\": \`$ts_flag ts\` value \`$ts_expr\` did not resolve to a date(1) format — ${resolved#UNRESOLVED:}. An unresolvable site is a finding, not a skip: #763 exists because a guard that quietly passes over what it cannot parse reports false confidence"
          ;;
        AMBIGUOUS:*)
          report "$base:$line event=\"$event\": \`$ts_flag ts\` value \`$ts_expr\` is AMBIGUOUS — ${resolved#AMBIGUOUS:}"
          ;;
        "$EXPECT_FORMAT")
          : # pinned, as required
          ;;
        *)
          report "$base:$line event=\"$event\": resolved ts format \`$resolved\` (from \`$ts_flag ts $ts_expr\`) does not match the pinned \`$EXPECT_FORMAT\` (references/formats/session-log.md)"
          ;;
      esac
      : "${assigned:-}" "${ordinal:-}"
      printf '%s:%s\n' "$base" "$event" >> "$WORK/raw_events.txt"
      ;;
  esac
done < "$RECORDS"

if [ "$TOTAL_SITES" -eq 0 ]; then
  report "enumeration found zero session-log writers under $SCRIPTS_DIR — vacuous pass, treated as failure"
fi

# Per-site keys: file:event#ordinal, ordinal in file order.
if [ -s "$WORK/raw_events.txt" ]; then
  awk '{ n[$0]++; printf "%s#%d\n", $0, n[$0] }' "$WORK/raw_events.txt" > "$FOUND_KEYS"
fi

# ---------------------------------------------------------------------------
# Ledger cross-check, both directions, per site.
# ---------------------------------------------------------------------------
NORM_KNOWN="$WORK/known_norm.txt"
printf '%s\n' "$KNOWN_SITES" | sed '/^[[:space:]]*$/d' | LC_ALL=C sort -u > "$NORM_KNOWN"
NORM_FOUND="$WORK/found_norm.txt"
LC_ALL=C sort -u "$FOUND_KEYS" > "$NORM_FOUND" 2>/dev/null || : > "$NORM_FOUND"

# Compared PER (file, event) BASE, not per ordinal-suffixed key (#820): the
# ordinal is a property of what THIS RUN's enumeration found, recomputed in
# file order every time, never a stable identity a missing site can be named
# by. Two ordinal sets of the same size are always the same set (ordinals are
# 1..N with no gaps), so a count comparison per base is exactly as sensitive
# as the old per-key comparison and never names a specific surviving ordinal
# as the one that vanished when more than one same-named site exists.
KNOWN_COUNTS="$WORK/known_counts.txt"
sed -E 's/#[0-9]+$//' "$NORM_KNOWN" | LC_ALL=C sort | uniq -c | awk '{print $2"\t"$1}' > "$KNOWN_COUNTS"
FOUND_COUNTS="$WORK/found_counts.txt"
sed -E 's/#[0-9]+$//' "$NORM_FOUND" | LC_ALL=C sort | uniq -c | awk '{print $2"\t"$1}' > "$FOUND_COUNTS" 2>/dev/null || : > "$FOUND_COUNTS"
BASES="$WORK/bases.txt"
{ cut -f1 "$KNOWN_COUNTS"; cut -f1 "$FOUND_COUNTS"; } | LC_ALL=C sort -u > "$BASES"

while IFS= read -r base; do
  [ -n "$base" ] || continue
  kc="$(awk -F'\t' -v b="$base" '$1==b{print $2}' "$KNOWN_COUNTS")"
  fc="$(awk -F'\t' -v b="$base" '$1==b{print $2}' "$FOUND_COUNTS")"
  kc="${kc:-0}"; fc="${fc:-0}"
  if [ "$kc" != "$fc" ]; then
    if [ "$kc" -eq 0 ]; then
      report "new/unrecognized session-log writer site(s) found: $base ($fc site(s)) — not on the ledger (KNOWN_SITES in this file); verify its ts format and add it deliberately"
    elif [ "$fc" -eq 0 ]; then
      report "ledger expects $kc $base site(s); enumeration found none — that writer was removed, renamed, or reshaped past what this guard can classify"
    else
      report "ledger expects $kc $base site(s); enumeration found $fc — a site under this (file, event) pair was added or removed. With more than one same-named site, the specific one cannot be named by ordinal (ordinals are recomputed from whatever enumeration finds, not a stable per-site identity — see the header's ledger section and #820)"
    fi
  fi
done < "$BASES"

if [ "$fail" -eq 0 ]; then
  echo "OK: $TOTAL_SITES session-log writer site(s) across $(wc -l < "$NORM_FOUND" | tr -d ' ') ledger key(s), in $FILE_COUNT file(s) under $SCRIPTS_DIR — all resolve to $EXPECT_FORMAT, ledger matches, and every logged line is accounted for by both the writer pass and the sink pass"
  exit 0
fi
exit 1
