# IFAS13 Agents wrapper
Irian-private wrapper repo for OeKB customer "ifas13" repo for shared agentic configuration among team members

```
projects/
├── ifas13-agents/
│   ├── mathias/       
│   │   ├── plans/
│   │   └── archive/
│   ├── manfred/       
│   │   └── plans/
│   ├── thomas/       
│   │   └── plans/
│   ├── CLAUDE.md           # shared instructions for claude code
│   ├── CLAUDE.local.md     # private claude code instructions (gitignored)
│   ├── AGENTS.md           # shared instruction for codex
│   ├── .claude/
│   │   ├── (settings.local.json)   # .gitignore
│   │   ├── settings.json
│   │   ├── skills/
│   │   ├── rules/
│   │   └── hooks/
│   └── .codex/
│       ├── skills/  # ?
│       ├── rules/   # ?
│       └── ...
└── ifas13/
    ├── CLAUDE.md           # symbolic link
    ├── CLAUDE.local.md     # symbolic link
    ├── AGENTS.md           # symbolic link
    ├── .claude/            # symbolic link
    └── .codex/             # symbolic link
```

## Symbolic links setup

```
cd ifas13
ln -s ../ifas13-agents/CLAUDE.md .
ln -s ../ifas13-agents/CLAUDE.local.md .
ln -s ../ifas13-agents/.claude .
```


## Suggested `settings.local.json`

```
{
  "autoMemoryEnabled": false,
  "autoMemoryDirectory": "~/my-custom-memory-dir",
  "plansDirectory": "../ifas13-agents/mathias/plans"
}
```
