---
name: user_nixos_fish_shell
description: User runs NixOS with home-manager, fish as interactive shell, CLAUDE_CODE_SHELL=bash for Claude Code. comma (`,`) is enabled for ad-hoc nixpkgs invocation.
metadata:
  type: user
  originSessionId: 2d06199c-90d2-457b-b1d2-50a667625a74
  modified: 2026-09-22T09:28:02.026Z
---
- NixOS with home-manager for system configuration
- Fish shell as interactive shell
- Claude Code config managed via `/home/sma/nixos-config/modules/claude-code/default.nix`
- CLAUDE_CODE_SHELL set to bash via NixOS home-manager (so hooks run through bash)
- IntelliJ as IDE (Claude Code started from within IntelliJ)
- Hook scripts are Python (.py) for shell-agnostic execution
- Settings changes require `nixos-rebuild switch` for global config, restart for project-level
- `comma` is installed: any nixpkgs CLI tool not on PATH (e.g. `jq`, `ripgrep`) can be run as `, <tool>` without installing it. Use this in scripts/hooks instead of assuming a tool is missing.

