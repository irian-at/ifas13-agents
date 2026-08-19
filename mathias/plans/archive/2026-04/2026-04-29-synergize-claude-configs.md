# Plan: Synergize Claude Configs in ifas13-agents

## Context

Manfred and Mathias each maintain their own `CLAUDE.local.md` and `claude-settings.local.json` in the ifas13-agents repo. These are symlinked into the ifas13 project via `.claude/settings.local.json` and `CLAUDE.local.md`. The shared `CLAUDE.md` and `.claude/settings.json` are nearly empty. There's significant duplication and the shared layer isn't being used.

## 1. Shared settings.json (`.claude/settings.json`)

Move common permissions that both devs benefit from:

```json
{
  "permissions": {
    "allow": [
      "Read",
      "Grep",
      "Glob",
      "Task",
      "WebSearch",
      "WebFetch",
      "Skill",
      "mcp__jetbrains__*",
      "mcp__idea__*",
      "mcp__ide__*",
      "mcp__context7__*"
    ],
    "deny": [
      "Bash(sudo *)",
      "Bash(rm -rf *)",
      "Bash(rm -r *)",
      "Bash(rmdir *)",
      "Bash(dd *)",
      "Bash(mkfs *)",
      "Bash(kill -9 *)",
      "Bash(pkill *)",
      "Bash(killall *)",
      "Bash(git push --force *)",
      "Bash(git push -f *)",
      "Bash(git push --force-with-lease *)",
      "Bash(git reset --hard *)",
      "Bash(git clean *)",
      "Bash(git branch -D *)",
      "Bash(git checkout -- *)",
      "Bash(git restore *)",
      "Bash(git rebase *)",
      "Bash(git stash drop *)",
      "Bash(chmod 777 *)",
      "Bash(> *)"
    ],
    "ask": []
  }
}
```

**Rationale:**
- Read-only tools are safe for everyone
- MCP tools are project-wide
- Deny list protects against destructive ops — Manfred currently has none

## 2. Personal settings.local.json — keep only personal/platform-specific rules

**Mathias** (`mathias/claude-settings.local.json`): Remove rules now in shared, keep:
```json
{
  "permissions": {
    "allow": [
      "Bash(nmcli connection:*)",
      "Bash(systemctl list-units:*)",
      "Bash(git config:*)",
      "Bash(unzip -l *)",
      "Bash(ifas-dev-tools/scripts/*)",
      "Bash(google-chrome-stable --remote-debugging-port=9222 *)"
    ],
    "deny": [],
    "ask": []
  },
  "hooks": { ... },
  "enabledPlugins": { ... },
  "outputStyle": "default",
  "plansDirectory": "~/dev/projects/ifas13-agents/mathias/plans"
}
```

**Manfred** (`manfred/claude-settings.local.json`): Clean up and keep only personal rules:
```json
{
  "permissions": {
    "allow": [
      "Bash(mvn:*)",
      "Bash(git add:*)",
      "Bash(git status:*)",
      "Bash(ls:*)",
      "Bash(find:*)",
      "Bash(curl:*)",
      "Bash(python3:*)",
      "Bash(lsof:*)",
      "Bash(/opt/homebrew/bin/git add:*)",
      "Bash(docs/Rekalkulation/generate-pdf.sh:*)",
      "WebFetch(domain:junit.org)",
      "WebFetch(domain:docs.junit.org)",
      "WebFetch(domain:www.baeldung.com)",
      "WebFetch(domain:nipafx.dev)",
      "WebFetch(domain:github.com)",
      "WebFetch(domain:discourse.hibernate.org)",
      "mcp__chrome-devtools__*"
    ],
    "deny": [],
    "ask": []
  },
  "plansDirectory": ".local/plans"
}
```

**Removed from Manfred's** (now in shared or redundant):
- All `mcp__jetbrains__*` individual rules (covered by wildcard in shared)
- `mcp__context7__*` individual rules (covered by wildcard in shared)
- `WebSearch` (in shared)
- `mcp__ide__getDiagnostics` (covered by `mcp__ide__*` in shared)
- Specific `mvn test`, `mvn compile`, etc. (covered by `Bash(mvn:*)`)
- Specific `git -C /Users/manolito/...` commands (one-off accumulation)
- `Bash(grep:*)`, `Bash(cat:*)`, `Bash(tee:*)`, `Bash(xargs:*)` (Claude should use Read/Grep tools instead)

## 3. Shared CLAUDE.md

Move project knowledge from both `CLAUDE.local.md` files into the shared `CLAUDE.md`. Content to extract:

**From Manfred's CLAUDE.local.md** (most of the 452 lines):
- Project overview, technology stack
- Module structure & architecture
- Key domain concepts (SteuerMeldung, Ermittlungsvorgabe, etc.)
- Data flow description
- Database profiles, Flyway notes
- Package structure conventions
- Common issues & troubleshooting
- Docker development environment
- Code quality / forbiddenapis rules

**From Mathias's CLAUDE.local.md**:
- Build commands, testing commands (already overlap with Manfred's)
- Code conventions table (referencing `.claude/rules/`)

## 4. Personal CLAUDE.local.md — keep only personal preferences

**Mathias**: Communication style, workflow preferences ("I'll run tests myself"), platform-specific notes.

**Manfred**: Platform-specific notes (macOS, `-Pno-proxy -Pplatform-arm64`), refactoring preferences (IDE-only), personal workflow preferences.

## 5. Files to modify

| File | Action |
|------|--------|
| `.claude/settings.json` | Populate with shared permissions |
| `mathias/claude-settings.local.json` | Remove rules now in shared |
| `manfred/claude-settings.local.json` | Clean up and remove shared/redundant rules |
| `CLAUDE.md` | Populate with shared project knowledge |
| `mathias/CLAUDE.local.md` | Trim to personal preferences only |
| `manfred/CLAUDE.local.md` | Trim to personal preferences only |

## 6. Verification

- Confirm symlinks still resolve: `readlink -f` on ifas13's `.claude`, `CLAUDE.md`, `CLAUDE.local.md`
- Confirm merged permissions work: start a new Claude Code session in ifas13, verify Read/Grep/Glob don't prompt
- Confirm deny rules apply: attempt a `sudo` or `rm -rf` command, should be blocked
- Ask Manfred to verify his setup after pulling changes
