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
- [Recalc fixture data recovery](project_recalc-fixture-data-recovery.md) — Missing meldung/ISIN in a grossfile fixture? Recover from a LATER grossfile's export-AFTER snapshot, undoing that grossfile's mutations (exclude what it created; re-source pre-T any OPE predecessor it ended — FIN ones stay null).
- [gueltBis = active-meldung discriminator](project_gueltbis-active-meldung-discriminator.md) — Legacy keys "active" off `guelt_bis is null`, not status; check gueltBis before treating an ERR_MELDID_FEHLT deviation as missing data — present-but-ended = validation bug, not a data problem.
- [_LIEFERUNG codes are clones](project_lieferung-codes-are-clones.md) — The four *_LIEFERUNG ValidationMsgCodes must stay exact clones (text + args) of their twins; change one twin, change the other + its factory.
- [_LIEFERUNG tests were tautological](project_lieferung-tests-tautological.md) — Assert ValidationMsg text against literal strings, not formatMessage(<same args>); MessageFormat silently renders missing args as literal `{n}`.
