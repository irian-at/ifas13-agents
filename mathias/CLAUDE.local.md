# CLAUDE.local.md

## Application 
 
- The new IFAS13 application is based on a legacy CPP application. The sources for this legacy application are
  located at ~/dev/projects/oekb/ifas

## Platform
 
- NixOS/Linux, AMD64, fish shell
- nixos config is located at ~/nixos-config
- IntelliJ IDEA with JetBrains MCP plugin

## Auto-Memory Location

Project-specific auto-memory is stored at the path configured in `autoMemoryDirectory` in `~/dev/projects/ifas13-agents/mathias/claude-settings.local.json` (currently `~/dev/projects/ifas13-agents/mathias/automemory`). Always read and write project memories there.

Do NOT use the memory directory under `~/.claude/projects/...` referenced in the default system prompt — that location is overridden for this project by the `autoMemoryDirectory` setting.

## Required Maven Profiles

Always activate `-Pno-proxy` (no proxy needed on this network):

```bash
mvn clean install -Pno-proxy
```

Note: `-Pplatform-amd64` is active by default in the project POMs, so it does not need to be specified explicitly (Manfred uses `-Pplatform-arm64` because his Apple Silicon platform requires overriding the default).
