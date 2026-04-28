# CLAUDE.local.md (Draft for Manfred)

This is a suggested replacement for your CLAUDE.local.md. Most of your original content has been moved to the shared `CLAUDE.md` and `.claude/rules/`. Only platform-specific and personal preferences remain here.

## Platform

- macOS, ARM64 (Apple Silicon)
- Homebrew for package management

## Required Maven Profiles

**IMPORTANT:** Always activate these Maven profiles when running `mvn` commands:

```bash
mvn clean install -Pno-proxy -Pplatform-arm64
```

- `no-proxy` - Disables proxy settings
- `platform-arm64` - Required for ARM64/Apple Silicon

## Workflow Preferences

- Always git stage newly added files
- Place implementation docs in `.local/docs/` (not in `docs/`)

## What moved where

The following content from your original CLAUDE.local.md is now shared:

| Original section | New location |
|-----------------|--------------|
| Project Overview | `CLAUDE.md` |
| Technology Stack | `CLAUDE.md` |
| Build & Test Commands | `CLAUDE.md` (without platform profiles) |
| Running the Application | `CLAUDE.md` |
| Docker Development Environment | `CLAUDE.md` |
| Development Tools | `CLAUDE.md` |
| Module Structure | `CLAUDE.md` |
| Key Domain Concepts | `CLAUDE.md` |
| Data Flow | `CLAUDE.md` |
| Testing Strategy | `CLAUDE.md` + `.claude/rules/testing-conventions.md` |
| Database Profiles | `CLAUDE.md` + `.claude/rules/database-conventions.md` |
| Package Structure Convention | `CLAUDE.md` |
| Code Quality / forbiddenapis | `.claude/rules/forbidden-apis.md` |
| Java Variable Declarations | `.claude/rules/java-conventions.md` |
| Lombok Best Practices | `.claude/rules/java-conventions.md` |
| Asynchronous Processing | `.claude/rules/async-processing.md` |
| Refactoring & File Operations | `.claude/rules/ide-refactoring.md` |
| Common Issues | `CLAUDE.md` |
| Annotation Processing | `CLAUDE.md` |

### References that need attention

Your original file referenced rules that don't exist in the shared repo. These are now covered by shared rules:

- `.claude/rules/run-tests.md` -> `.claude/rules/testing-conventions.md`
- `.claude/rules/git-commits.md` -> consider creating as a personal rule
- `.claude/rules/time-date-handling.md` -> covered by `.claude/rules/forbidden-apis.md` (temporal utilities)
- `.claude/rules/flyway-migrations.md` -> `.claude/rules/database-conventions.md`
- `.claude/rules/java-variables.md` -> `.claude/rules/java-conventions.md`
- `.claude/rules/lombok.md` -> `.claude/rules/java-conventions.md`
