# Proposal: trim and de-duplicate the shared Claude config (`claude/`, `README.md`)

2026-10-13 · for Manfred and Thomas · from Mathias, derived from the analysis in
`2026-10-13-claude-config-synergy-and-token-reduction.md` (same folder).

Patch: `2026-10-13-shared-claude-config-proposal.patch` — review it, or apply from the repo root with
`git apply mathias/plans/2026-10-13-shared-claude-config-proposal.patch` and open a PR. Every item is
its own hunk and can be dropped on its own.

## Why

- `claude/CLAUDE.md` is loaded into every session of every one of us: 13.4 KB ≈ 3 400 tokens. About a
  fifth of it exists a second time elsewhere or is read once per machine.
- `code-review-ifas/IFAS13_CONVENTIONS.md` is an 11 KB copy of `claude/rules/` that has already
  drifted (missing five newer sections, carrying one that exists nowhere else).
- One shared rule carries a platform flag, one names MCP tools by a server name that differs per
  machine.
- The README's symlink instructions make Claude Code load `CLAUDE.md` twice.
- `claude/settings.json` is still `{allow: [], deny: []}` (the April plan's step 1 never happened);
  the deny list against destructive commands lives only in one local settings file.

No coding rule changes. The patch removes copies, states one rule as what it was written for, and
fixes stale mechanics.

## Changes

| # | File | Change | Saves per session | Risk / owner |
|---|---|---|---|---|
| 1 | `claude/CLAUDE.md` | §Database Profiles → one pointer line; the list is verbatim in `database-conventions.md` | ≈ 150 tok | none |
| 2 | `claude/CLAUDE.md` | One-time bootstrap: 25 lines → 8, same two commands and symptom strings | ≈ 120 tok | none |
| 3 | `claude/CLAUDE.md` | §Code Quality + §Coding Conventions table → one section; the rules load themselves by path | ≈ 170 tok | none |
| 4 | `claude/CLAUDE.md` | §Common Issues: drop the MapStruct and IfasMainApplication entries that repeat earlier sections | ≈ 80 tok | none |
| 5 | `claude/CLAUDE.md` | §Git Conventions: same prefixes, same worktree rename rule and gotcha; stated as a worktree/shared-branch rule, local-checkout branching left to each developer | ≈ 100 tok | Manfred wrote it (`2654e63`) — his call |
| 6 | `claude/rules/database-conventions.md` | `-Pplatform-arm64` out of the shared DatabaseSchemaTool command (amd64 is the POM default), "on Apple Silicon add it" note | — | none; Manfred's local file already says to add it |
| 7 | `claude/rules/ide-refactoring.md` | tools named server-independently (`rename_refactoring`, `create_new_file`); the server is `jetbrains` on macOS and `idea` on NixOS | — | none |
| 8 | `claude/settings.json` | shared allow (WebSearch, WebFetch, `mcp__jetbrains__*`, `mcp__idea__*`, `mcp__ide__*`, `mcp__context7__*`) + deny list (`rm -rf`, `git push --force`, `git reset --hard`, `git clean`, `git rebase`, …) | — | adds protection only; afterwards each of us drops the duplicates from `settings.local.json` |
| 9 | `claude/skills/code-review-ifas/` | delete `IFAS13_CONVENTIONS.md`; Step 1 does `cat .claude/CLAUDE.md .claude/rules/*.md`; `Task` → `Agent` | skill-only | none — **already applied on `main` by Mathias, 2026-10-13**; not in the patch |
| 10 | `README.md` | no root `ifas13/CLAUDE.md` link (double load); per-skill symlink warning (a folder link hides the skills — it did for a month); auto-memory hint step dropped (the harness injects the directory itself) | ≈ 3 400 tok for anyone who followed the old instruction | none |
| 11 | `claude/CLAUDE.md` | new §No Agent Attribution: no `Co-Authored-By: Claude` / `Claude-Session` trailers on commits or PRs, with the post-commit grep check — today this lives only in Manfred's and Mathias's personal files, the shared history has none | — | none; makes a team habit explicit |

`claude/CLAUDE.md`: 13 449 → 11 650 bytes (≈ −450 tokens per session for everyone). Patch stat:
5 files, +85 / −107 lines (item 9 is already on `main`).

## After the merge

- **Manfred**: `manfred/CLAUDE.local.md` is still the pre-April 18.6 KB file (Spring Boot 3.5.6,
  modules `ifas-web-app` / `ifas-domain-stamm` that do not exist, Sybase on 7433) — it repeats the
  shared `CLAUDE.md` with stale values in every session, ≈ 4 700 tokens. `manfred/CLAUDE.local-draft.md`
  has been the 2.5 KB replacement since 2026-04-29 (platform, Podman rule, push rule, workflow prefs);
  the "references that need attention" list in it is still accurate. Also check whether
  `ifas13/CLAUDE.md` exists next to `.claude/` — if so, remove the link (#10).
- **Thomas**: set up per the README — only the `.claude` and `CLAUDE.local.md` links, no root
  `CLAUDE.md`; personal rules/skills via `personal-<USER>` links as described.
- **Everyone**: remove from `settings.local.json` what #8 now covers. `claude/rules/personal-<USER>`
  and `claude/skills/personal-<USER>-<skill>` stay personal and gitignored.

## Not in this proposal

- The content of the coding rules (`java-conventions`, `code-comments`, …) — untouched.
- The personal layers (`mathias/`, `manfred/`) — each owner's business.
- Moving the bootstrap text out of `CLAUDE.md` — kept, condensed, so a fresh checkout stays
  self-contained.
