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
│   │   ├── rules/                      # rules skills for claude code
│   │   └── hooks/                      # hooks skills for claude code
│   ├── mathias/       
│   │   ├── CLAUDE.local.md             # user specific claude code instructions
│   │   ├── claude-settings.local.json  # user specific settings for claude code
│   │   ├── plans/                      # user specific plans
│   │   └── archive/
│   ├── manfred/       
│   │   ├── CLAUDE.local.md             # user specific claude code instructions
│   │   ├── claude-settings.local.json  # user specific settings for claude code
│   │   └── plans/                      # user specific plans
│   └── thomas/       
│       ├── CLAUDE.local.md             # user specific claude code instructions
│       ├── claude-settings.local.json  # user specific settings for claude code
│       └── plans/                      # user specific plans
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


## Suggested `settings.local.json`

```
{
  "plansDirectory": "../ifas13-agents/<USER>/plans",
  "autoMemoryEnabled": false,
  "autoMemoryDirectory": "~/my-custom-memory-dir"
}
```
