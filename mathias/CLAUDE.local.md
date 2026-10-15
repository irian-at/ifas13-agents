# CLAUDE.local.md

## Application

- IFAS13 replaces a legacy C++ application; its sources are at `~/dev/projects/oekb/ifas`. The `.cpp`
  files are ISO-8859-1 — plain `grep` treats them as binary and finds nothing, use `grep -a`.

## Platform

- NixOS/Linux, AMD64, fish shell; Claude Code runs with `CLAUDE_CODE_SHELL=bash`, so hooks are bash
- Claude Code config (settings, hooks, output style, user-level skills) is home-manager managed in
  `~/nixos-config/modules/claude-code/`; changes there need `nixos-rebuild switch`
- `comma` is installed: any nixpkgs CLI tool missing from PATH runs as `, <tool>`
- IntelliJ IDEA with the JetBrains MCP plugin; Claude Code is started from within IntelliJ

## Maven

Always activate `-Pno-proxy` and `-Pdev-build`: there is no `~/.m2/settings.xml`, so Maven resolves
only from Central, and without `dev-build` the build fails on `jespa:jespa-jakarta:2.0.5`.
`-Pplatform-amd64` is the POM default on this machine (Manfred needs `-Pplatform-arm64` for Apple
Silicon).

```bash
mvn clean install -Pno-proxy,dev-build
```

## Precedence and settings

- `mathias/rules/` (loaded as `.claude/rules/personal-mathias/`) outranks `.claude/CLAUDE.md` and the
  harness defaults wherever they disagree — in particular commits: straight onto `master`, never onto
  `production`/`stable`, no Claude trailers (`commit-messages.md`).
- `plansDirectory` and `autoMemoryDirectory` are overridden in `mathias/claude-settings.local.json`;
  the `~/.claude/...` defaults a prompt may suggest do not apply.

## Workflow

- Only change what was asked. Never let a tool rewrite unrelated bytes (encoding, whitespace, line
  endings); if an edit's diff would touch lines you did not need, narrow it or switch tools.
- Feature work runs in small, independently committable chunks in dependency order: persistence
  (migration + entities + repositories) → pure domain → behaviour change in existing code → live
  wiring last. Nothing in an earlier chunk changes what the running system does.
- Each chunk goes to an Opus subagent (`model: "opus"`) with a self-contained brief (plan sections,
  rule files, exact scope, verification commands, what to report); Fable gathers context, reviews the
  result and reports. Print the numbered step list before dispatching the first chunk.
- No commits on his behalf: leave the verified chunk in the working tree. He stages in IntelliJ or
  asks for `/commit`.
