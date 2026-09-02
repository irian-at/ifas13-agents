# Memory Index

## User
- [Communication style](user_style.md) — prefers direct, raw, unfiltered communication
- [NixOS / fish / IntelliJ](user_nixos_fish_shell.md) — NixOS + home-manager, fish shell, comma (`,`) for ad-hoc nixpkgs CLI tools

## Feedback
- [English method names](feedback_english-method-names.md) — Methodennamen englisch (write/process/compare); deutsch nur Fachbegriffe in Typ-/Feldnamen oder als Substantiv im Methodennamen.
- [Only change what was asked](feedback_only-change-what-was-asked.md) — Don't silently rewrite unrelated content; properties files in this repo are ISO-8859-1 and Edit/Write will re-save them as UTF-8.
- [Plan file naming](feedback_plan-file-naming.md) — First action after plan approval: mv the slug file to mathias/plans/ as YYYY-MM-DD-<descriptive-kebab-name>.md (ExitPlanMode hook injects a reminder with the date).
- [Check project settings, not just defaults](feedback_check-project-settings-not-just-defaults.md) — `plansDirectory` and `autoMemoryDirectory` are overridden in `claude-settings.local.json`; honor those, not the default `~/.claude/...` paths the system prompt suggests.
- [Read personal rules before committing](feedback_read-personal-rules-before-committing.md) — `mathias/rules/commit-messages.md` wins over CLAUDE.md and the harness: commit onto master, no Claude trailers, no fixture specifics.

## Project
- [Sybase schema freeze](project_sybase-schema-freeze.md) — Keine neuen Tabellen/Spalten in Sybase (Alt wie Neu); Neues nach Postgres, Business-Tabellen NICHT nach infra (Muster ausschuettung_tmp); Sybase-Migration 2027. Parallelbetrieb = eigene Neusystem-Sybase + Diff-Job-Muster.
- [Recalc historical fidelity](project_recalc-historical-fidelity.md) — Recalc of old SteuerMeldung versions must match legacy's behavior at that time, not current legacy; don't "clean up" version gates that mirror dated OeKBSD changes.
- [Recalc fixture data recovery](project_recalc-fixture-data-recovery.md) — Missing meldung/ISIN in a grossfile fixture? Recover from a LATER grossfile's export-AFTER snapshot, undoing that grossfile's mutations (exclude what it created; re-source pre-T any OPE predecessor it ended — FIN ones stay null).
- [gueltBis = active-meldung discriminator](project_gueltbis-active-meldung-discriminator.md) — Legacy keys "active" off `guelt_bis is null`, not status; check gueltBis before treating an ERR_MELDID_FEHLT deviation as missing data — present-but-ended = validation bug, not a data problem.
- [_LIEFERUNG codes are clones](project_lieferung-codes-are-clones.md) — The four *_LIEFERUNG ValidationMsgCodes must stay exact clones (text + args) of their twins; change one twin, change the other + its factory.
- [_LIEFERUNG tests were tautological](project_lieferung-tests-tautological.md) — Assert ValidationMsg text against literal strings, not formatMessage(<same args>); MessageFormat silently renders missing args as literal `{n}`.
- [KONTROLL tolerance (legacy)](project_kontroll-tolerance-legacy.md) — INFO_KONTROLL_1 & Kontrollsummen use absolute dToleranz=10.0 (Stichtag≥2017-02-01, else 0.9), 10-NK operands, in c_st_meldung.cpp CheckKontrollsummen(); new system's infoKontroll1 doesn't apply it yet. Legacy .cpp is ISO-8859-1 → use grep -a.
- [gf1 field-diff null-vs-zero](project_gf1-fielddiff-null-vs-zero.md) — gf1's ~11151 GrossfileRecalc error field diffs are benign: new system omits zero country-vector entries (filterZeroValuesForCountries) that legacy wrote as explicit 0.0000, and the newReturnVsOldReturn config is strict about it. No calc bug, no data loss.
- [STM guelt_ab unique-key test flake](project_stm-gueltab-unique-key-test-flake.md) — Multi-row SteuerMeldung test seeding with a shared now() for guelt_ab collides on AK_STUER_BEH_ALT_KEY_STEUER_M on coarse clocks; use a deterministic per-row timestamp.
- [ValidationSetting flags have two effects](project_validationsetting-flags-have-two-effects.md) — Each recalc-artifact flag drives both the delta-report severity AND (via SteuerlicheErmittlungRecalcOptions.ignore*Errors) the meldung's result status; wiring only the report half leaves the STATUS_* return-file diffs in place.
- [CheckLieferfristen status reachability](project_checklieferfristen-status-reachability.md) — ERR_FRIST_NOSN/ERR_FRIST_SN fire for NEW, CONFIRMED *and* UPDATE (never DELETE); the UPDATE call site at c_st_meldung.cpp:9260 is dropped by greps that filter `//` lines.
- [Headless launch needs devtools off](project_headless-launch-devtools-npe.md) — bare `java -cp` of a Local*IfasApplication NPEs on every DB access unless `-Dspring.devtools.restart.enabled=false`; not a code bug.
- [QuickRecalculationTest stale test-classes](project_quick-recalc-stale-test-classes.md) — "must have at least one Melde-CSV" usually means a leftover zip in target/test-classes, not a bad zip; the extra resource pushes the test onto bundleOf(Collection), which never unzips.
- [bundlesOf temp-dir cleaner](project_bundlesof-tempdir-cleaner.md) — `bundlesOf(zip).getFirst()` lets GC delete the unzipped temp files mid-run; use `bundleOf(Resource)` for single-bundle zips.
- [STB is Auslieferformat-only](project_stb-auslieferformat-only.md) — STB lives only in the Auslieferformat schema; the STB entries in CsvIfasStructureValidationRules for OPEN/ERROR/DELETED/FINAL are deliberate, not stale.
- [@CsvSource TestTemplate limits](project_csvsource-testtemplate-provider-limits.md) — the multi-DB extension parses @CsvSource itself: no null columns, no enum conversion.
- [YAML export tags with digits](project_yaml-export-entity-tags-have-digits.md) — `KEST98` is dropped by a `[A-Z_]+` block regex when trimming a fixture export.
- [STM delivery-chain test harness](project_stm-delivery-chain-test-harness.md) — chains need processLieferung; recalc never persists and calculateBundle rejects confirm/delete files.
- [Temporal type storage per DBMS](project_temporal-type-storage-per-dbms.md) — all 3 java.time types agree on the Instant, but offset types store UTC on Sybase/Postgres and Vienna on H2.
- [Sybase testcontainer credentials](project_sybase-testcontainer-credentials.md) — repo-root .env now present; .idea's skip-sybase16-tests silently drops Sybase invocations; jTDS product name is exactly "ASE".
- [Import/Export n:n Lieferanten](project_importexport-nn-lieferanten.md) — nur die HDP/KAG-Seite wird geschrieben; ein HDP-Eintrag ohne `lieferanten` löscht die Join-Zeilen, und Sybase hat dort keine FKs.
