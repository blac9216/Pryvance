# Propagating the skills to a repository

This repository's `.claude/skills/` and `.claude/agents/` are **canonical**. Every other
repository's copies, and every machine's home directory (`~/.claude/skills/`,
`~/.claude/agents/`), are **installed copies** synced from here — the direction is
repo → installed, never the reverse. Cloud sessions cannot see `~/.claude/skills` or
`~/.claude/agents`, so each repository still needs its own on-disk copy under
`.claude/skills/` and `.claude/agents/`, even though this repository's copy is the
source of truth.

The set of skills and agent definitions to propagate is not restated here — read
[manifests/family.json](../manifests/family.json), the shipped manifest `audit.sh` also
reads, so the two lists cannot drift against each other.

Procedure (an agent does this on request; there is no script by design):
1. For each skill named in `manifests/family.json`: `diff -r
   <this-repo>/.claude/skills/<skill> <target>/.claude/skills/<skill>`. For each agent
   definition named there: `diff <this-repo>/.claude/agents/<name>.md
   <target>/.claude/agents/<name>.md`.
2. Copy over any that differ (`rm -rf` the old, `cp -r` the new — no merging), from this
   repository's copy to the target.
3. If the target repository keeps a `.agents/skills/` discovery directory, symlink there.
4. Commit `AI: sync workflow skills` in the target. Protected default branch → branch +
   PR (the docs fast path does not apply: too many files); unprotected → push to `main`
   only when the owner has authorised direct pushes for skill propagation.
5. Verify, run from this repository's side: `md5sum` of each `SKILL.md` and each agent
   definition named in `manifests/family.json` equals this repository's own copy.
6. Installed copies elsewhere: the agent definitions also install to `~/.claude/agents/`
   on that machine, by the same sync — a session resolving an agent definition by name
   from a different repository needs it there too, not only in that repository's own
   tree.

After `capture` changes a manifest, propagate `configure-workflow` the same way.

## Per-file notes

Files added to this skill that are not covered by the generic procedure above get a row
here.

| New reference | Propagates like | Does not propagate |
|---|---|---|
| [session-log-archive.md](session-log-archive.md) | Every other file under `.claude/skills/configure-workflow/` — the `diff -r` in step 1 already covers it | The `\| Session-log archive \| <owner>/<repo> \|` row it writes, which lives in the repo's own `docs/process/work-tracking.md` and is repo-specific, same as the reviewer identity row |
