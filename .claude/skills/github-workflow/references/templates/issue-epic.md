# Epic Issue Template

An epic is one domain inside a delivery story (or a milestone-less theme). It exists so
the larger intent survives context compaction: its **body** holds the durable goal and
scope; its **comment thread** holds the events — what landed, what a review found, what
was decided. Nothing in the body is a log. Always more than one child; never more than
100 (closed children count). Labels: `epic` + ≥1 `area:*` + a `size:*` label. Assign the
milestone if the domain belongs to a story.

An epic has no net LOC of its own — it delivers through its children — so it sizes by
planned scope at filing instead: **S** = 2-4 planned children, one obvious sequence;
**M** = 5-8, or fewer with real cross-child dependencies; **L** = more than 8, or the
domain spans more than one story. Unlike a code issue, `size:l` on an epic is **not**
the "must be split before filing" tripwire — decomposition into sub-issues is the
epic's entire purpose, so a large epic is exactly the expected shape, not a filing
defect. Read it instead as a triage signal to double-check the 100-child cap stays
comfortably clear and that the epic's own scope (not just its children's) still fits
one domain rather than several that should be sibling epics.

```markdown
## Goal
The single objective this domain delivers, in two or three sentences a reader can
absorb with nothing else loaded.

## Motivation
Why it matters and what it unblocks.

## Scope
What is in.

### Non-goals
What is deliberately out — usually "owned by sibling epic #N".

## Design
Pointers into `docs/` (architecture, ADRs, contract sections). Point, do not copy. Owner
decisions for this domain are recorded as comments on this epic.

## Sub-issues
Linked as native sub-issues; order lives in `blocked by` dependencies and `priority:*`.
Any hard ordering that dependencies cannot express is stated here in one line.

## Status
One line: what is in flight, what is blocked, what is next. Rewritten whole on every touch.
```
