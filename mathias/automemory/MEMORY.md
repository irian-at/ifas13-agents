# Memory Index

## Feedback
- [Check active fixture first](feedback_check-active-fixture-before-synthesizing-repro.md) — mid-ticket, inspect `quick-recalc.zip` before building a synthetic repro

## Project
- [Job counters vs protocol](project_job-counters-vs-protocol.md) — job tables keep listable counters only; per-item detail goes to the protocol file
- [DB-context blind spot in tests](project_db-context-blind-spot-in-tests.md) — ifas-integration-tests routes every context to one H2; routing proofs go to `-multidbctx`
- [TEST-stage Sybase layout](project_test-stage-sybase-layout.md) — sybase-gast = ALT (readonly), sybase-ifasneu = NEU (`ifas1,kurs1,vwkn1`), same server
- [Sybase schema freeze](project_sybase-schema-freeze.md) — no new Sybase tables/columns; business tables go to Postgres, never to `infra`
- [Meldefile routing: first line only](project_meldefile-routing-first-line-only.md) — 100-line scan (IFAS13-244) reverted; broken line 1 → bad-input job, never the STM pipeline; ERR_ZEILE1_SATZ attempt discarded
- [Recalc historical fidelity](project_recalc-historical-fidelity.md) — old-version recalcs must match legacy *at that time*; version gates are intentional
- [gueltBis = active discriminator](project_gueltbis-active-meldung-discriminator.md) — legacy keys "active" off `guelt_bis is null`, not status
- [_LIEFERUNG codes are clones](project_lieferung-codes-are-clones.md) — keep the twins in lockstep; assert message text against literals
- [KONTROLL tolerance (legacy)](project_kontroll-tolerance-legacy.md) — absolute dToleranz 10.0 (≥ 2017-02-01) on KONTROLL 1/2/3/4/5/7/10, none on 9
- [gf1 field-diff null-vs-zero](project_gf1-fielddiff-null-vs-zero.md) — lockdown counts calculatedVsOldReturn + STATUS_* only; the ~11151 round-trip diffs are benign
- [Legacy return col 4](project_legacy-return-col4-vorherige.md) — OPEN → immediate predecessor, FINAL/ERROR → nearest FINAL; FINAL rows carry a ref
- [STM guelt_ab unique-key flake](project_stm-gueltab-unique-key-test-flake.md) — seed multi-row STMs with distinct fixed `guelt_ab`, not `now()`
- [ValidationSetting flags have two effects](project_validationsetting-flags-have-two-effects.md) — report severity AND result status; wire both halves
- [CheckLieferfristen reachability](project_checklieferfristen-status-reachability.md) — ERR_FRIST_NOSN/SN fire for NEW, CONFIRMED and UPDATE, never DELETE
- [Korrekturfrist needs a FINAL predecessor](project_korrekturfrist-requires-final-predecessor.md) — ERR_UPD_TOLATE only with a FINAL in the chain; else plain Meldefrist
- [zufluss is the FINAL Stichtag](project_zufluss-is-the-final-stichtag.md) — select "became FINAL for D" via `zufluss = D`, never a time window
- [STB is Auslieferformat-only](project_stb-auslieferformat-only.md) — the STB entries in CsvIfasStructureValidationRules are deliberate
- [STM delivery-chain harness](project_stm-delivery-chain-test-harness.md) — chains need processLieferung; recalc never persists
- [@CsvSource TestTemplate limits](project_csvsource-testtemplate-provider-limits.md) — no empty columns, no enum conversion
- [QuickRecalculationTest stale target](project_quick-recalc-stale-test-classes.md) — "must have at least one Melde-CSV" = leftover zip in target/test-classes
- [bundlesOf temp-dir cleaner](project_bundlesof-tempdir-cleaner.md) — `bundlesOf(zip).getFirst()` lets GC delete the unzip; use `bundleOf(Resource)`
- [Temporal storage per DBMS](project_temporal-type-storage-per-dbms.md) — offset types store UTC on Sybase/Postgres, Vienna on H2
- [Sybase testcontainer credentials](project_sybase-testcontainer-credentials.md) — repo-root `.env`; `.idea` skips Sybase silently; product name is exactly "ASE"
- [jTDS shared-Calendar race](project_jtds-shared-calendar-race.md) — Calendar AIOOBE under jTDS is Hibernate's static UTC_CALENDAR, never bad data
- [Sybase char padding](project_sybase-char-padding.md) — `char(n)` reads back padded; `@Convert` is ignored on `@Id`, trim in a getter
- [Import/Export n:n Lieferanten](project_importexport-nn-lieferanten.md) — only KAG/HDP owning; `lieferanten` absent = keep links, `[]` = drop them
- [Native datalist limits](project_native-datalist-limits.md) — the popup is browser UI: no page CSS, no placement; Chrome's arrow needs `!important`
- [web-ui frontend constraints](project_web-ui-frontend-constraints.md) — no npm/CDN; the layout pulls only `~{::section}`; scope `@ControllerAdvice`
- [Fondspreise Stufe split](project_fondspreise-stufe-split.md) — Stufe 1 on master; feat/fondspreise-sync is a quarry, never merged; status in tracker.md
- [Preismeldung Rückmeldung log format](project_preismeldung-rueckmeldung-log-format.md) — LF + ISO-8859-1, labels from `txt_bez_e`; a golden-file test pins it
- [Legacy file charsets differ](project_legacy-file-charsets-differ.md) — EStB CSVs windows-1252; return/confirm/delete + logs IBM437
- [TEST deploys nightly](project_test-stage-nightly-deploy.md) — a migration pushed today has reached no DB; editable until the nightly deploy, then frozen

## Reference
- [MCP rename on Lombok fields](reference_mcp-rename-lombok-fields.md) — "Access from EDT" error, misses strings/setters/builders; grep after every rename
