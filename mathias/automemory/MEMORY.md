# Memory Index

## User
- [Communication style](user_style.md) — prefers direct, raw, unfiltered communication
- [NixOS / fish / IntelliJ](user_nixos_fish_shell.md) — NixOS + home-manager, fish shell, comma (`,`) for ad-hoc nixpkgs CLI tools

## Feedback
- [Only change what was asked](feedback_only-change-what-was-asked.md) — Don't silently rewrite unrelated content; properties files in this repo are ISO-8859-1 and Edit/Write will re-save them as UTF-8.
- [Plan file naming](feedback_plan-file-naming.md) — First action after plan approval: mv the slug file to mathias/plans/ as YYYY-MM-DD-<descriptive-kebab-name>.md (ExitPlanMode hook injects a reminder with the date).
- [Check project settings, not just defaults](feedback_check-project-settings-not-just-defaults.md) — `plansDirectory` and `autoMemoryDirectory` are overridden in `claude-settings.local.json`; honor those, not the default `~/.claude/...` paths the system prompt suggests.

## Project
- [Recalc historical fidelity](project_recalc-historical-fidelity.md) — Recalc of old SteuerMeldung versions must match legacy's behavior at that time, not current legacy; don't "clean up" version gates that mirror dated OeKBSD changes.
- [Recalc fixture data recovery](project_recalc-fixture-data-recovery.md) — Missing meldung/ISIN in a grossfile fixture? Recover from a LATER grossfile's export-AFTER snapshot, undoing that grossfile's mutations (exclude what it created; re-source pre-T any OPE predecessor it ended — FIN ones stay null).
- [gueltBis = active-meldung discriminator](project_gueltbis-active-meldung-discriminator.md) — Legacy keys "active" off `guelt_bis is null`, not status; check gueltBis before treating an ERR_MELDID_FEHLT deviation as missing data — present-but-ended = validation bug, not a data problem.
- [_LIEFERUNG codes are clones](project_lieferung-codes-are-clones.md) — The four *_LIEFERUNG ValidationMsgCodes must stay exact clones (text + args) of their twins; change one twin, change the other + its factory.
- [_LIEFERUNG tests were tautological](project_lieferung-tests-tautological.md) — Assert ValidationMsg text against literal strings, not formatMessage(<same args>); MessageFormat silently renders missing args as literal `{n}`.
- [KONTROLL tolerance (legacy)](project_kontroll-tolerance-legacy.md) — INFO_KONTROLL_1 & Kontrollsummen use absolute dToleranz=10.0 (Stichtag≥2017-02-01, else 0.9), 10-NK operands, in c_st_meldung.cpp CheckKontrollsummen(); new system's infoKontroll1 doesn't apply it yet. Legacy .cpp is ISO-8859-1 → use grep -a.
- [gf1 field-diff null-vs-zero](project_gf1-fielddiff-null-vs-zero.md) — gf1's ~11151 GrossfileRecalc error field diffs are benign: new system omits zero country-vector entries (filterZeroValuesForCountries) that legacy wrote as explicit 0.0000, and the newReturnVsOldReturn config is strict about it. No calc bug, no data loss.
- [STM guelt_ab unique-key test flake](project_stm-gueltab-unique-key-test-flake.md) — Multi-row SteuerMeldung test seeding with a shared now() for guelt_ab collides on AK_STUER_BEH_ALT_KEY_STEUER_M on coarse clocks; use a deterministic per-row timestamp.
- [ValidationSetting flags have two effects](project_validationsetting-flags-have-two-effects.md) — Each recalc-artifact flag drives both the delta-report severity AND (via SteuerlicheErmittlungRecalcOptions.ignore*Errors) the meldung's result status; wiring only the report half leaves the STATUS_* return-file diffs in place.


