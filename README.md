# IFAS13 Agents wrapper
Irian-private wrapper repo for OeKB customer "ifas13" repo for shared agentic configuration among team members

```
projects/
├── ifas13-agents/
│   ├── claude/
│   │   ├── CLAUDE.md                   # shared instructions for claude code
│   │   ├── settings.json               # shared settings for claude code
│   │   ├── (settings.local.json)       # symlink (see below)
│   │   ├── skills/                     # shared skills for claude code
│   │   │   └── (personal-<USER>-<NAME>) # per-skill symlinks (see "Personal rules/skills")
│   │   ├── rules/                      # shared rules for claude code
│   │   │   └── (personal-<USER>)       # folder-level symlink to <USER>/rules (see below)
│   │   └── hooks/                      # shared hooks for claude code
│   ├── mathias/
│   │   ├── CLAUDE.local.md             # user specific claude code instructions
│   │   ├── claude-settings.local.json  # user specific settings for claude code
│   │   ├── plans/                      # user specific plans
│   │   ├── automemory/                 # user specific auto-memory store
│   │   ├── rules/                      # user specific personal rules (loaded only for mathias)
│   │   └── skills/                     # user specific personal skills (loaded only for mathias)
│   ├── manfred/
│   │   ├── CLAUDE.local.md
│   │   ├── claude-settings.local.json
│   │   └── plans/
│   └── thomas/
│       ├── CLAUDE.local.md
│       ├── claude-settings.local.json
│       └── plans/
└── ifas13/
    ├── CLAUDE.md                       # symbolic link to ../ifas13-agents/claude/CLAUDE.md
    ├── CLAUDE.local.md                 # symbolic link to ../ifas13-agents/<USER>/CLAUDE.local.md
    └── .claude/                        # symbolic link to ../ifas13-agents/claude
        └── settings.local.json         # symbolic link to ../ifas13-agents/<USER>/claude-settings.local.json
```

## Symbolic links setup

```
cd ifas13
ln -s ../ifas13-agents/claude/CLAUDE.md ./CLAUDE.md
ln -s ../ifas13-agents/claude ./.claude
ln -s ../ifas13-agents/<USER>/CLAUDE.local.md ./CLAUDE.local.md
ln -s ../<USER>/claude-settings.local.json ./.claude/settings.local.json
```

## Personal rules / skills

Each user can keep **personal, project-scoped** rules and skills under their own `<USER>/rules/` and `<USER>/skills/` directories. The source files **are committed** to this repo (version-controlled, survives reinstalls), but they are only auto-loaded for the user who creates the symlink — colleagues see the files but Claude Code does not load them in their sessions.

The mechanism mirrors the existing `claude/settings.local.json` → `<USER>/claude-settings.local.json` pattern: source under `<USER>/`, gitignored entry-point symlink under `claude/`.

### Rules — folder-level symlink (one symlink covers everything)
Claude Code scans `claude/rules/` recursively, so a single folder symlink exposes all the user's rules:

```
cd ifas13-agents
ln -s ../../<USER>/rules claude/rules/personal-<USER>
```

Now any `<USER>/rules/*.md` file is loaded as a project rule **for that user only**.

### Skills — one symlink per skill (skill discovery is NOT recursive)
Claude Code only discovers skills as `claude/skills/<name>/SKILL.md`; it does **not** recurse into subdirs. So each skill needs its own top-level entry:

```
cd ifas13-agents
ln -s ../../<USER>/skills/<skill-name> claude/skills/personal-<USER>-<skill-name>
```

### Gitignore
The personal symlinks under `claude/rules/` and `claude/skills/` are excluded by `.gitignore`:

```
claude/rules/personal-*
claude/skills/personal-*
```

So colleagues never pull in your personal symlinks, and your `<USER>/rules/` + `<USER>/skills/` source dirs stay version-controlled here.

### Promoting a personal rule/skill to shared
When a personal rule/skill becomes valuable for the whole team, move the source file from `<USER>/rules/` (or `<USER>/skills/<name>/`) into `claude/rules/` (or `claude/skills/<name>/`), commit it, and remove your personal symlink.

## Suggested `settings.local.json`

```
{
  "plansDirectory": "../ifas13-agents/<USER>/plans",
  "autoMemoryEnabled": false,
  "autoMemoryDirectory": "../ifas13-agents/<USER>/automemory"
}
```

### If you enable auto-memory

If you flip `autoMemoryEnabled` to `true`:

1. **Always set `autoMemoryDirectory`** explicitly (suggested: `../ifas13-agents/<USER>/automemory`). Otherwise Claude Code falls back to a per-user-home location like `~/.claude/projects/<sanitized-cwd>/memory/` — outside this repo, not version-controlled, and not shared across machines.
2. **Add a hint to your `<USER>/CLAUDE.local.md`** so Claude reads/writes memory in the right place. Example block:

   ```markdown
   ## Auto-Memory Location

   Project-specific auto-memory is stored at the path configured in `autoMemoryDirectory` in
   `../ifas13-agents/<USER>/claude-settings.local.json` (currently `../ifas13-agents/<USER>/automemory`).
   Always read and write project memories there.

   Do NOT use the memory directory under `~/.claude/projects/...` referenced in the default
   system prompt — that location is overridden for this project by the `autoMemoryDirectory` setting.
   ```

   Without this hint, Claude may default to its system-prompt-described `~/.claude/projects/...` location even when the setting is configured, causing memory writes to land outside the repo.
