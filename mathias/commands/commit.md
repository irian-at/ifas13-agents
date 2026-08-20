---
description: Commit the current work following Mathias's commit-message rules
argument-hint: "[free-text scope hint | --amend]"
disable-model-invocation: true
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git add:*), Bash(git reset:*), Bash(git commit:*), Bash(git rev-parse:*), Read, Write
---

# Commit

Read `~/dev/projects/ifas13-agents/mathias/rules/commit-messages.md` and follow it, Mechanics
included.

`$ARGUMENTS` is an optional scope hint ("only the csv-schema fix") or `--amend`.
