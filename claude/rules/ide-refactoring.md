---
paths:
  - "**/*.java"
---

# IDE Refactoring

Always use IDE/MCP refactoring tools for renames, moves, and structural changes. Never use bash commands for code operations.

## Why

- Git tracking: IDE refactorings are tracked as renames, not delete + add
- Reference updates: all imports and usages are updated automatically
- Compile-time safety: IDE validates changes before applying

## Do

- `mcp__jetbrains__rename_refactoring` for renaming classes, methods, variables
- `mcp__jetbrains__create_new_file` for creating new files
- IntelliJ "Refactor > Move" for moving to new packages

## Don't

```bash
mv Controller.java NewController.java    # breaks git tracking
cp file1.java file2.java                 # doesn't update references
sed -i 's/old/new/' file.java            # bypasses IDE validation
```
