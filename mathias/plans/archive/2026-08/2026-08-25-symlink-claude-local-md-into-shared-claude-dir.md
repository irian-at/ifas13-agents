# Symlink `claude/CLAUDE.local.md` → `mathias/CLAUDE.local.md`

## Context

`/home/sma/dev/projects/ifas13-agents/claude` is the shared, git-tracked Claude config
directory for the IFAS13 work; `ifas13/.claude` is a symlink pointing at it. Per-developer
files live under `ifas13-agents/mathias/` and are linked into the shared dir instead of being
committed — the existing precedent is:

```
claude/settings.local.json -> ../mathias/claude-settings.local.json
```

The goal is the same treatment for the personal `CLAUDE.local.md`, so it is picked up as
`.claude/CLAUDE.local.md` without ever landing in the repo.

## Change

Create one relative symlink (relative, to match `settings.local.json` and stay valid through
the `.claude` symlink and any worktree):

```bash
ln -s ../mathias/CLAUDE.local.md /home/sma/dev/projects/ifas13-agents/claude/CLAUDE.local.md
```

## Git

Nothing to do — `/home/sma/dev/projects/ifas13-agents/.gitignore` line 4 already contains
`claude/CLAUDE.local.md`, so the new link is ignored by default. No `git add`, no
`.git/info/exclude` edit, no commit.

## Verification

```bash
ls -l  /home/sma/dev/projects/ifas13-agents/claude/CLAUDE.local.md   # link -> ../mathias/CLAUDE.local.md
head -3 /home/sma/dev/projects/oekb/ifas13/.claude/CLAUDE.local.md   # resolves through .claude symlink
git -C /home/sma/dev/projects/ifas13-agents status --short           # link must NOT appear
git -C /home/sma/dev/projects/ifas13-agents check-ignore -v claude/CLAUDE.local.md
```

## Note

`ifas13/CLAUDE.local.md` already symlinks to the same target, so afterwards both
`./CLAUDE.local.md` and `./.claude/CLAUDE.local.md` point at one file. Harmless (worst case
the content is loaded twice into context); removing the older root-level link is a separate
decision and not part of this change.
