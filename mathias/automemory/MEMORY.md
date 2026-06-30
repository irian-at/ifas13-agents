# Memory Index

## User
- [Communication style](user_style.md) — prefers direct, raw, unfiltered communication
- [NixOS / fish / IntelliJ](user_nixos_fish_shell.md) — NixOS + home-manager, fish shell, comma (`,`) for ad-hoc nixpkgs CLI tools

## Feedback
- [Only change what was asked](feedback_only-change-what-was-asked.md) — Don't silently rewrite unrelated content; properties files in this repo are ISO-8859-1 and Edit/Write will re-save them as UTF-8.
- [Plan file naming](feedback_plan-file-naming.md) — Rename the plan file from the random session slug to a descriptive kebab-case name before exiting plan mode.
- [Check project settings, not just defaults](feedback_check-project-settings-not-just-defaults.md) — `plansDirectory` and `autoMemoryDirectory` are overridden in `claude-settings.local.json`; honor those, not the default `~/.claude/...` paths the system prompt suggests.

## Project
- [Recalc historical fidelity](project_recalc-historical-fidelity.md) — Recalc of old SteuerMeldung versions must match legacy's behavior at that time, not current legacy; don't "clean up" version gates that mirror dated OeKBSD changes.
- [gf3 missing stmIds recovered from gf4](project_gf3-missing-stmids-recovered-from-gf4.md) — 649492/649539/649548/649550 gone from sybase-gast but recoverable from gf4-d20260807 fixture via `merge_yaml.py --extract`.
- [gf6 UPDATE on ended meldung / guelt_bis](project_gf6-update-on-ended-meldung-guelt-bis.md) — an Altsystem "Melde-ID nicht vorhanden" deviation can be a code bug, not missing data: legacy keys "active" off `guelt_bis is null`; check gueltBis before reaching for recover/prune.
- [gf7 missing data recovered from gf8](project_gf7-missing-data-recovered-from-gf8.md) — gf7 fixture missing all 20 ISINs + 11 predecessors; recovered from gf8 snapshot, but OPE predecessors gf7 mutated (gueltBis set / confirmed) must be re-sourced pre-T from gf1-export-AFTER.
- [gf8 recovery + SN-Frist gap](project_gf8-recovery-and-sn-frist-gap.md) — gf8's 4 error deviations: 2 missing-data (LU0145634076/LU0125743475 recovered from gf2/gf5 fixtures, no time-filter needed), 2 are a real SN-during-Frist code gap (Selbstnachweis JA vs NEIN), not data; baseline → (5,0,0,2,0,0).
