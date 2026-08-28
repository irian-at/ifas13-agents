---
name: project_stm-delivery-chain-test-harness
description: Multi-delivery STM chain tests must call processLieferung directly; the recalc harness never persists and calculateBundle rejects confirm/delete files.
metadata:
  type: project
---

To test a *sequence* of Steuermeldung deliveries against a real DB (NEW -> CONFIRM -> UPDATE …),
call `SteuerlicheErmittlungDomainService#processLieferung(Resource, …)` with
`SteuerlicheErmittlungRecalcOptions.DEFAULT`. Neither alternative works:

- `RecalculationDomainService#doRecalc` hard-codes `persistResult = false`, so no state survives
  from one delivery to the next — the whole recalc harness (`JiraIssueRecalculationTest`,
  `GrossfileRecalculationTest`) is unusable for chains.
- `CalculationDomainService#calculateBundle` resolves its input as `STM_MELDUNG_CSV_FILE`, and
  `SteuerMeldungBundles.determineFileTypeFromFilePath` classifies `*_confirm.csv` / `*_delete.csv`
  as `CONFIRM_CSV_FILE` / `DELETE_CSV_FILE` — a confirm or delete delivery can never reach it.

**Why:** the two obvious entry points both look right and both fail, one silently (nothing
persisted, every step starts from an empty chain).

**How to apply:** `StmIdVergabeTest` is the worked example. `MultiDatabaseExtension` truncates
*after each test method*, so one chain = one `@TestTemplate`. `StmIdProvider` is a parameter, not a
bean, so a counting lambda gives deterministic STM-IDs. See [[project_gueltbis-active-meldung-discriminator]].
