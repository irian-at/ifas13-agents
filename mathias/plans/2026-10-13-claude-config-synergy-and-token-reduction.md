# Claude config: synergy and token reduction (ifas13-agents)

2026-10-13 — analysis and plan only; nothing changed yet.

## Glossary

| Term | Meaning |
|---|---|
| T1 | personal only (`mathias/`), no colleague impact — do directly |
| T2 | global file, but never loaded into anyone's context (README, skill internals) — low risk |
| T3 | global file loaded into every colleague's context (`claude/CLAUDE.md`, `claude/rules/`, `claude/settings.json`) — propose to the team first |
| always-on | injected into every session's context |
| path-scoped | rule with `paths:` frontmatter, injected only once a matching file is touched |
| ~tok | bytes / 4, rough estimate |

## 1. What loads when (ifas13 session, today)

| File | bytes | ~tok | loaded |
|---|---|---|---|
| `claude/CLAUDE.md` (via `.claude/`) | 13 449 | 3 360 | always-on |
| `mathias/CLAUDE.local.md` | 1 365 | 340 | always-on (once — the second link `.claude/CLAUDE.local.md` is not loaded separately) |
| `mathias/automemory/MEMORY.md` | 12 206 | 3 050 | always-on |
| skill descriptions (`code-review-ifas` only, see 2.1) | — | ~40 | always-on |
| `mathias/rules/commit-messages.md` | 4 110 | 1 030 | `**/*` → effectively always-on |
| Java bundle: `java-conventions` 1 030, `code-comments` 460, `forbidden-apis` 310, `ide-refactoring` 200, `english-method-names` 250, `reuse-before-reimplementing` 320 | 10 309 | 2 570 | any `*.java` |
| `testing-conventions.md` | 1 510 | 380 | `**/test/**` |
| `database-conventions.md` | 4 581 | 1 150 | persistence / flyway / repository |
| `flyway-one-file-per-feature` + `flyway-versions-after-merge` | 4 352 | 1 090 | `**/db/migration/**` |
| `plan-file-naming.md` | 1 840 | 460 | `**/plans/*.md` |
| `async-processing.md` | 698 | 170 | service / config |
| `web-authorization.md` | 1 317 | 330 | `ifas-web/**` |
| 48 memory files | 106 KB | — | recalled on relevance, not always-on |

Typical Java session: **≈ 10.4 K tokens** of config (CLAUDE.md 3.4 K + MEMORY.md 3.1 K + commit rule 1.0 K + Java bundle 2.6 K + local 0.3 K). The two biggest always-on items are `CLAUDE.md` and `MEMORY.md`, together 60 %.

`~/.claude` (home-manager): rules empty, skills `discuss`/`digest-memory`/`visualize`/`herdr`, command `ucp`, output style `scannable`, hooks `relocate-plan-file.sh`/`herdr-agent-state.sh`. No overlap with the project layer except the `discuss` feedback memory (2.5).

## 2. Findings

### 2.1 Broken: the three personal skills are not discovered

`claude/skills/personal-mathias` is a **folder** symlink (created 2026-09-22) to `mathias/skills/`, so the skills sit at depth 2 (`claude/skills/personal-mathias/<skill>/SKILL.md`). Skill discovery is not recursive — the README says so and this session's skill list confirms it: `code-review-ifas` (depth 1) is listed, `validation-discrepancy`, `merge-yaml-export-extension`, `find-missing-isins-for-yaml-extension` are not. They have been invisible to the Skill tool since 2026-09-22.

The README's own instruction is per-skill symlinks: `claude/skills/personal-mathias-<skill>`.

Side effect once fixed: their descriptions become always-on. They are 119 / 108 / 65 words (`code-review-ifas`: 28) — ≈ 400 tokens. Trim to ≤ 40 words each before re-linking.

`claude/commands/personal-mathias` is the same folder-symlink shape. Commands *are* discovered recursively but namespaced — check in a fresh session whether `/commit` or `/personal-mathias:commit` is what resolves (both are `disable-model-invocation`, so the model's list cannot tell).

### 2.2 Duplicates across layers

| Content | Lives in | Also in | Action |
|---|---|---|---|
| Database profiles list (h2-db1…, postgres-*, sybase-*) | `claude/CLAUDE.md` §Database Profiles | `database-conventions.md` §Multi-Database Support, verbatim | T3: drop from CLAUDE.md, keep in the rule |
| All 8 global rules | `claude/rules/*.md` | `code-review-ifas/IFAS13_CONVENTIONS.md` (11 KB copy, "synced from .claude/rules") — already drifted: lacks Formatting, Declared Types, local-`@Nullable`, "describe the code not the change", DatabaseSchemaTool, `web-authorization` entirely; has an orphan "Writer Pattern / OutputStreamTextWriterHelper" section that exists in no rule | T2: delete the copy; SKILL.md step 1 does `cat .claude/rules/*.md` instead |
| Annotation processing / MapStruct rebuild | `claude/CLAUDE.md` §Code Quality | same file §Common Issues | T3: keep one |
| "Never run IfasMainApplication" | `claude/CLAUDE.md` §Running | same file §Common Issues | T3: keep one |
| Coding-conventions table (rule file → content) | `claude/CLAUDE.md` | the rules themselves (self-loading) | T3: one line ("rules under `.claude/rules/` load by path") |
| One-time Maven bootstrap (25 lines) | `claude/CLAUDE.md` | needed once per machine | T3: move to `ifas13-agents/README.md` or `docs/`, leave a 2-line pointer with the two symptom strings |
| English method names | `mathias/rules/english-method-names.md` | `feedback_english-method-names.md` (full text, "hält nur noch die Herkunft fest") | T1: delete memory; rule's `## Why` already has date + origin |
| Flyway one file per feature | `mathias/rules/flyway-one-file-per-feature.md` | `feedback_flyway-one-file-per-feature.md` (full text) | T1: delete memory |
| Plan file naming | `mathias/rules/plan-file-naming.md` | `feedback_plan-file-naming.md` (full text) + `feedback_check-project-settings-not-just-defaults.md` | T1: delete both memories |
| No `@Nullable` on locals | `claude/rules/java-conventions.md` §Null Safety | `feedback_no-nullable-on-local-variables.md` | T1: delete memory |
| Commit rule precedence | `mathias/rules/commit-messages.md` header | `feedback_read-personal-rules-before-committing.md` (2.5 KB "please obey the rule") | T1: delete; one line in `CLAUDE.local.md` |
| Platform (NixOS, fish, IntelliJ) | `mathias/CLAUDE.local.md` §Platform | `user_nixos_fish_shell.md` | T1: merge the 3 extra bullets (comma, `CLAUDE_CODE_SHELL=bash`, nixos-config path) into CLAUDE.local.md, delete memory |
| Post-T snapshot mutations (OPE predecessors, gueltBis) | `merge-yaml-export-extension/SKILL.md` §Gotcha | `project_recalc-fixture-data-recovery.md`, half of `project_gueltbis-active-meldung-discriminator.md` | T1: skill is the home for the procedure; memory keeps the fact only |
| Fondspreise status log | `project_fondspreise-stufe-split.md` (3.8 KB, "Stand 2026-10-12", "Stand 2026-10-12 (abends)") | `plans/fondspreise/tracker.md` (70 KB) | T1: memory → pointer + the two durable facts (branch not merged, V067–V069 void) |
| Staged-index caveat | `user_intellij-git-add.md` | qualifies `commit-messages.md` Mechanics 2 ("if anything is staged, commit exactly that") | T1: fold into the rule, delete memory |

### 2.3 Stale or wrong

- `mathias/rules/plan-file-naming.md` §"The rename cannot happen during plan mode": claims the harness writes to `~/.claude/plans/<slug>.md` and ignores `plansDirectory` (#19537). The hook `relocate-plan-file.sh` (nixos-config, newer) says the opposite and `~/.claude/plans/` is empty. Cut the section to: "plan lands in `plansDirectory` under a slug; rename after ExitPlanMode as the hook reminder says". ≈ −250 tok. Same staleness in `feedback_plan-file-naming.md` and `feedback_check-project-settings-not-just-defaults.md` (deleted anyway).
- `mathias/CLAUDE.local.md` §Auto-Memory Location: the harness now injects the configured directory into the system prompt itself (this session: "persistent file-based memory at …/mathias/automemory/"). Section and the README advice that spawned it are obsolete. T1 delete; T2 README.
- `claude/rules/database-conventions.md` DatabaseSchemaTool command carries `-Pplatform-arm64` — Manfred's platform, in a shared rule (amd64 is the POM default). T3.
- `claude/rules/ide-refactoring.md` names `mcp__jetbrains__rename_refactoring`; the servers here are `idea` and `plugin:hm:jetbrains` → tool ids differ. T3, verify the real id first.
- `code-review-ifas/SKILL.md`: `Task` tool (now `Agent`), `cat CLAUDE.md .claude/CLAUDE.md` (root file does not exist here). T2.
- `ifas13-agents/README.md`: instructs `ln -s … ./CLAUDE.md` **and** `.claude` → both `CLAUDE.md` and `.claude/CLAUDE.md` are project-memory locations, so anyone following it loads CLAUDE.md twice (≈ 3.4 K tok). Mathias has no root link (correct). T2: drop the root-link line, say why.
- `.claude/CLAUDE.local.md` → `../mathias/CLAUDE.local.md` (added 2026-08-25): not loaded (only the root link shows in the system reminder). Dead weight; remove to end the "is it loaded twice?" question. T1.
- Manfred: `manfred/CLAUDE.local.md` is still the 18.6 KB pre-April file (Spring Boot 3.5.6, modules `ifas-web-app`/`ifas-domain-stamm` that do not exist, Sybase 7433) — ≈ 4.7 K tokens of stale duplicate of the shared CLAUDE.md every session; `manfred/CLAUDE.local-draft.md` (2.5 KB) has been ready since 2026-04-29. Not ours to edit; tell him.

### 2.4 Layers fighting each other

Committing: harness ("branch before committing on default branch") ← `claude/CLAUDE.md` §Git Conventions ("HARD RULE: check the branch name before every commit", `feat/`… prefixes, 25 lines) ← `mathias/rules/commit-messages.md` ("commit straight onto master, no trailers, outranks CLAUDE.md") ← `feedback_read-personal-rules-before-committing.md` ("really, read the rule"). Four layers, three of them spending tokens to cancel the previous one.

- T1: keep the personal rule as the single statement; drop the memory; one precedence line in `CLAUDE.local.md`.
- T3 proposal: scope the global HARD RULE to "branches created for worktrees/remote work" (what it is about) so it stops reading as "always branch". No content loss for colleagues.

Shared `claude/settings.json` is still `{allow:[],deny:[]}` — step 1 of the 2026-04-29 plan was never done. Mathias's `settings.local.json` carries the full deny list; Manfred's has none. T3 proposal: deny list + read-only allows to shared.

### 2.5 Memory store (48 files)

Memory recall is relevance-based; behaviours that should hold *every time* belong in a rule or `CLAUDE.local.md`, procedures belong in a skill, facts stay memories.

**Promote** (then delete the memory):

| Memory | To |
|---|---|
| `feedback_chunked-implementation-via-opus-subagents` | `CLAUDE.local.md` §Workflow, 4 lines |
| `feedback_glossary-for-symbols-and-refs` | `CLAUDE.local.md` §Communication, 1 line |
| `feedback_discuss-prose-alternatives-not-cards` | `~/.claude/skills/discuss/SKILL.md` (nixos-config), 2 lines |
| `user_style` | `CLAUDE.local.md` §Communication, 1 line |
| `feedback_only-change-what-was-asked` | 1 line in `CLAUDE.local.md` + new `mathias/rules/properties-encoding.md` (`paths: **/*.properties`, 4 lines: ISO-8859-1, Edit/Write re-save as UTF-8, use byte-level tools) |
| `project_fondspreise-naming-rules` (4.8 KB of naming decisions + history) | new `mathias/rules/fondspreise-naming.md` (`paths: **/fondspreise/**`), decisions only, no dates/history, ≈ 1.2 KB |
| `project_headless-launch-devtools-npe` (full launch recipe + curl/CSRF) | new `mathias/skills/run-ifas-headless/SKILL.md` — the built-in `run` skill looks for a project skill first |
| `project_quick-recalc-undo-single-update`, `project_grossfile-yaml-trimming`, `project_yaml-export-entity-tags-have-digits`, procedure half of `project_recalc-fixture-data-recovery` | `merge-yaml-export-extension/SKILL.md` as sections (undo one UPDATE; strip with FondsYamlStripTool + prove by diff; `[A-Z0-9_]+` tag regex) |

**Delete** (covered elsewhere, see 2.2): `feedback_english-method-names`, `feedback_flyway-one-file-per-feature`, `feedback_plan-file-naming`, `feedback_check-project-settings-not-just-defaults`, `feedback_no-nullable-on-local-variables`, `feedback_read-personal-rules-before-committing`, `user_nixos_fish_shell`, `user_intellij-git-add`.

**Merge**: `project_lieferung-codes-are-clones` + `project_lieferung-tests-tautological` → one file (same topic, cross-referencing each other).

**Trim** (keep current truth, cut the narrative):

| Memory | bytes | cut |
|---|---|---|
| `project_gf1-fielddiff-null-vs-zero` | 7 162 | "EARLIER WRONG CONCLUSION", "Resolution (2026-07-21)", "CORRECTED 2026-07-23" narration; split the legacy return-file col-4 rule into its own memory (`project_legacy-return-col4-vorherige`) → ≤ 2.5 KB + 1 KB |
| `project_kontroll-tolerance-legacy` | 4 513 | "History that misled a previous session" paragraph → ≤ 3 KB |
| `project_fondspreise-stufe-split` | 3 817 | status log → pointer to `tracker.md` + 2 facts → ≤ 1.2 KB |
| `project_validationsetting-flags-have-two-effects` | 3 545 | −20 %, keep both halves + the load-bearing paragraph |

**Keep as is**: the Sybase cluster (`char-padding`, `testcontainer-credentials`, `temporal-type-storage`, `jtds-shared-calendar-race`, `test-stage-sybase-layout`, `schema-freeze`), `db-context-blind-spot`, `checklieferfristen`, `korrekturfrist`, `zufluss`, `stb-auslieferformat`, `stm-delivery-chain`, `stm-gueltab-flake`, `csvsource-limits`, `bundlesof-cleaner`, `quick-recalc-stale-test-classes`, `legacy-file-charsets`, `preismeldung-log-format`, `native-datalist`, `web-ui-constraints`, `importexport-nn`, `recalc-historical-fidelity`, `gueltbis-discriminator` (fact half), `feedback_check-active-fixture`, `feedback_job-counters-vs-protocol` (retype to `project`).

Result: 48 → ≈ 31 files.

**`MEMORY.md`**: 50 index lines, 1 363 words (27 words/line; several lines are paragraphs). Rewrite every hook to ≤ 12 words — the index is a lookup table, the file holds the content. With ≈ 31 lines: ≈ 400 words ≈ **0.8 K tok (from 3.1 K)**.

## 3. Plan

### Step 1 — T1: skills

1. Trim the three descriptions to ≤ 40 words (trigger phrases only; the "what it explains" prose goes into the body).
2. `rm claude/skills/personal-mathias`; `ln -s ../../mathias/skills/<skill> claude/skills/personal-mathias-<skill>` × 3 (gitignored by `claude/skills/personal-*`).
3. Fold the four procedure memories into `merge-yaml-export-extension/SKILL.md`; add `mathias/skills/run-ifas-headless/SKILL.md`; link both.
4. Fresh session: skill list shows all five; `/commit` resolves (note the name it resolves under).

### Step 2 — T1: `CLAUDE.local.md`

Rewrite to: Application (legacy path) · Platform (+ comma, `CLAUDE_CODE_SHELL=bash`, nixos-config path) · Maven profiles · Precedence (one line: `mathias/rules/` outrank `.claude/CLAUDE.md` and harness defaults; commits: master, no trailers) · Communication (raw/direct; glossary for symbols and numbered refs; in /discuss prose/table + one open question, no option cards) · Workflow (chunks, persistence first, live wiring last; Opus subagent per chunk; no commits on his behalf; step list first; only change what was asked) · Settings overrides (`plansDirectory`, `autoMemoryDirectory` in `claude-settings.local.json`). Drop §Auto-Memory Location. Target ≈ 2 KB (from 1.4 KB) — grows 0.15 K tok, retires 11 memories.

Remove the dead `claude/CLAUDE.local.md` symlink.

### Step 3 — T1: personal rules

- `plan-file-naming.md`: cut the stale plan-mode section (2.3) → ≈ 1 KB.
- `commit-messages.md`: Mechanics 2 gets the staged-index caveat from `user_intellij-git-add` (2 lines). Optionally shorten the two wrong/correct examples.
- New `fondspreise-naming.md` (`paths: **/fondspreise/**`), new `properties-encoding.md` (`paths: **/*.properties`).

### Step 4 — T1: memory consolidation

Apply 2.5 (promote → delete → merge → trim), then rewrite `MEMORY.md`. Run `/digest-memory` afterwards as a cross-check, not instead.

### Step 5 — T2: README + skill internals (global, not context-loaded)

- README: drop the root `CLAUDE.md` symlink line (double load), drop the "add an Auto-Memory hint" section, keep the per-skill symlink instruction and add the folder-symlink trap as a warning.
- `code-review-ifas`: delete `IFAS13_CONVENTIONS.md`, step 1 `cat .claude/CLAUDE.md .claude/rules/*.md`, `Task` → `Agent`, drop the IFAS13-Specific Checks list (it is the rules).

### Step 6 — T3: proposals for the team (one PR / message, each item separable)

| Change | ~tok saved per colleague session | risk |
|---|---|---|
| `CLAUDE.md`: drop §Database Profiles (dup of rule) | 150 | none |
| `CLAUDE.md`: bootstrap → README + 2-line pointer | 220 | none (pointer keeps the symptoms) |
| `CLAUDE.md`: conventions table → 1 line | 170 | none |
| `CLAUDE.md`: Common Issues dedupe (MapStruct, IfasMainApplication) | 80 | none |
| `CLAUDE.md`: Git Conventions scoped to worktree branches, shortened | 150 | low — same rule, narrower wording |
| `database-conventions.md`: remove `-Pplatform-arm64` from the shared command | — | none (Manfred's local says to add it) |
| `ide-refactoring.md`: real MCP tool ids | — | verify first |
| `settings.json`: shared deny list + read-only allows (2026-04-29 plan step 1) | — | low — adds protection only |
| Manfred: adopt `CLAUDE.local-draft.md` | ≈ 4 700 for him | his call |

CLAUDE.md total: ≈ 3 360 → ≈ 2 600 tok.

### Step 7 — verify

- `/context` in a fresh ifas13 session before Step 1 and after Step 4 (and after Step 6 lands): record the memory/rules lines.
- Skill list contains the three personal skills + `run-ifas-headless`.
- Touch a `.java`, a migration and a `.properties` file: the expected rules appear, nothing else.
- `grep -rl '\[\[' mathias/automemory` — every `[[link]]` still resolves after the deletes.

## 4. Expected effect (typical Java session)

| | now | after T1 | after T1 + T3 |
|---|---|---|---|
| `CLAUDE.md` | 3 360 | 3 360 | 2 600 |
| `MEMORY.md` | 3 050 | 800 | 800 |
| `CLAUDE.local.md` | 340 | 500 | 500 |
| skill descriptions | 40 | 200 | 200 |
| `commit-messages.md` | 1 030 | 1 000 | 1 000 |
| Java bundle | 2 570 | 2 570 | 2 570 |
| **total** | **≈ 10 400** | **≈ 8 400 (−19 %)** | **≈ 7 700 (−26 %)** |

Honest framing: the token saving is ≈ 2–3 K per session. The larger gains are that three skills work again, 11 behaviours become deterministic (rule/CLAUDE.local instead of recall), four layers stop contradicting each other on commits, and the stale plan-mode/auto-memory text is gone.

## 5. Open points

- `feedback_read-personal-rules-before-committing` exists because the rule was ignored twice. Proposed replacement is the one precedence line in `CLAUDE.local.md` (always-on, 25 words). If that proves insufficient, the stronger fix is dropping `paths:` from `commit-messages.md` so it is always-on regardless of file access — same cost as today.
- `run-ifas-headless` could be a shared skill, but Manfred's launch differs (Podman, arm64, `exec:java`). Keep personal.
