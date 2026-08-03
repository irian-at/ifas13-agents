---
name: validation-discrepancy
description: Analyze a divergence between legacy CPP (`~/dev/projects/oekb/ifas/`) and new Java (`~/dev/projects/oekb/ifas13/`) validation output — typically a `[+] NUR IM NEUSYSTEM` or `[-] NUR IM ALTSYSTEM` entry from a grossfile recalculation diff. Use this skill whenever the user pastes lines from `error#diff.txt` / `error#diff-deviations.txt`, mentions a validation message that fires in one system but not the other, asks "why does the neusystem (not) fire this error", or wants to compare an ERR_* / INFO_* code between the two systems. The skill explains where each system's validation lives, how the CSV input is structured (and how that interacts with status), how to map a German message back to its raiser in both codebases, and the recurring discrepancy patterns observed so far.
---

# Validation Discrepancy Analyzer

Use this when you need to explain (and usually then fix) why a specific German validation message appears in legacy CPP but not in IFAS13, or vice versa. The output of this skill is a focused analysis: legacy raiser location, IFAS13 raiser location, the structural difference between the two, and a fix recommendation (with scope: code change vs spec data vs no-op).

## Inputs you usually have

The user typically pastes a chunk from `ifas-testing/ifas-integration-tests/target/test-output/grossfile-recalc/<dataset>/error#diff*.txt`. A typical entry:

```
--------------------------------------------------------------------------------
Zeile-Nr: 62 | START;LU0133717503;InvF;T;EUR;...;JA;;;2;;LU;NEIN;JA;NEIN;;NEIN;JA;2;4EKHGXD69UZIZADPEK36
--------------------------------------------------------------------------------

    [+] NUR IM NEUSYSTEM (FEHLER)
        ERROR! Das Pflichtfeld <Aufwand_Gesamtbetrag_e> im Satz <E> ist nicht befuellt.
```

Read what's actually there before deciding the cause:

- `Zeile-Nr: N` — the line number of the `START` record in the input CSV. The full meldung spans several lines (START + STATUS + optional E/EA/D/Z/ZA/AS/STB + END).
- `(nur im Neusystem)` after the `|` means the entire meldung output exists only in IFAS13 — legacy emitted nothing for this Zeile at all. Treat this as a strong status-gating hint (legacy almost always means: NEW/UPDATE took a different code path).
- `[-] NUR IM ALTSYSTEM` — legacy fires, IFAS13 doesn't.
- `[+] NUR IM NEUSYSTEM` — IFAS13 fires, legacy doesn't.

Also useful: look at the next lines of the CSV to find the `STATUS;<status>;<stmId>` record. The status (NEW / UPDATE / CONFIRMED / DELETE) drives which checks legacy runs and is the single biggest cause of divergence.

```bash
awk 'NR>=N && NR<=N+5 {print NR": "$0}' \
  ifas-testing/ifas-integration-tests/target/test-output/grossfile-recalc/<dataset>/<dataset>.csv
```

## Where the validation lives

### Legacy CPP — `~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/`

| File | Role |
|------|------|
| `c_stm_logger.cpp` | Defines every `ERR_*` / `INFO_*` template via `cBugMsgs.AddMsg(j++, "CODE", "Template …");`. The template strings are what end up in the diff. Always grep here first to confirm the code exists in legacy. |
| `c_st_meldung.cpp` | Main meldung processing. Status-specific entry points: `ProcessMeldung_NEW`, `ProcessMeldung_UPDATE`, `ProcessMeldung_CONFIRMED`, `ProcessMeldung_DELETE`. Each calls a different `CheckMeldung*` function — this gating is the source of most divergences. |
| `c_stfields.cpp` | Per-field validation. `cStFields::Check()` raises `ERR_PFLICHT_FEHL` etc. `cStFields_col::Check()` iterates all spec fields. |

Key gating in `c_st_meldung.cpp`:

- `CheckMeldung()` (~line 3852) — full payload validation. **Gated on `(status == "NEW") || (status == "UPDATE")`** for the field-level checks (`pcStF->Check()` at ~line 3905). Also runs ERR_KEINE_MELD, ERR_AUSSCHT_FEHL, etc.
- `CheckMeldung_CONFIMED()` (~line 9120) — only checks that forbidden satz types (E, EA, D, Z, ZA) are **absent** in a CONFIRMED.
- `CheckMeldung_DELETE()` (~line 9016) — same pattern, forbidden-satz checks only.
- `CheckVorhandeneMeldung()` (~line 7452) — DB-comparison checks (ISIN match, status transitions, Ausschuettungstag rules). Called from all four `ProcessMeldung_*` paths.

**Encoding warning**: the CPP source is ISO-8859-1 with umlauts. Plain `grep` may treat files as binary and stay silent — always use `grep -an` for legacy searches.

### IFAS13 Java — `~/dev/projects/oekb/ifas13/ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/`

| Path | Role |
|------|------|
| `validation/ValidationMsgCode.java` | Enum of every `ERR_*` / `INFO_*` with German message template. The 1:1 counterpart of `c_stm_logger.cpp`. |
| `validation/status/SteuerMeldungStatusValidationService.java` | Status-related: `ERR_MELDEID_FEHLT`, `ERR_MELDID_FEHLT`, `ERR_MELDID_UNG`, `ERR_ISIN_MID`, `ERR_UNGL_*`, `ERR_UPD_*`, `ERR_STATUS_*`, `ERR_VERGANGEN_UPD`, `ERR_AUSSCHT_AKT_CONF`, plus `SteuerMeldungFristenValidators` for `ERR_FRIST_*`, `ERR_SN_INMELDEFRIST`. |
| `validation/status/SteuerMeldungStatusValidators.java` | Individual validator static methods. |
| `validation/status/StmStatusValidationRules.java` | Maps `StmStatus → Set<FieldCategory>` for status-conditional field validation. CONFIRMED/DELETE → `NONE`; NEW → all-except-STB; UPDATE → all. |
| `validation/SteuerMeldungDomainValidationService.java` | Domain checks: `ERR_KEINE_MELD`, `ERR_AUSSCHT_FEHL`, `ERR_AUSSCHT_FEHLT`, `ERR_AUSSCHT_AKT`, `ERR_AUSSCHT_N0`, `ERR_SATZ_FEHLT`, `ERR_SN_AUSSCH`, `ERR_EXTAG_AUSSCHT`, `ERR_EXTAG30_AUSSCHT`, `INFO_WRABATT_*`, `INFO_NO_BOERSETAG`, `ERR_ANZ_ANTEILE`. |
| `validation/SteuerMeldungDomainValidators.java` | Individual domain validators. |
| `validation/fristen/SteuerMeldungFristenValidators.java` | Date/deadline checks. |
| `validation/calculated/CalculatedSteuerMeldungValidators.java` | Kontrollsummen checks (`ERR_KONTROLL_*`). |
| `meldung/validation/SteuerMeldungErmittlungsvorgabeValidationService.java` | Field-spec validation (MAN/OPT/NA per BMF Ermittlungsvorgabe Excel). Raises `ERR_PFLICHT_FEHL`. |
| `meldung/validation/SteuerMeldungErmittlungsvorgabeValidators.java` | The per-field validator. |
| `meldung/log/ValidationMsgCodePattern.java` | **Useful**: regex patterns that match the legacy log strings back to enum codes. When you only have a German error string, this file lets you identify the code without guessing. |

### Orchestration — `SteuerMeldungLieferungService.processLieferung(...)`

For each parsed meldung the service runs, in order:

1. `statusValidationService.validate(...)` — status-related rules
2. `ermittlungsvorgabeValidationService.validate(...)` — field MAN/OPT/NA per spec
3. `domainValidationService.validate(...)` — domain rules

If a discrepancy comes from `ERR_PFLICHT_FEHL`, it's in step 2. Almost everything else is step 1 or 3.

## CSV input structure

A meldung is a *block* of records:

```
START;ISIN;Art;Ertragstyp;Waehrung;Gj_beginn;Gj_ende;Jahresdatenmeldung;Meldezeitraum_beginn;Meldezeitraum_ende;...;LEI
STATUS;NEW|UPDATE|CONFIRMED|DELETE;<stmId>
E;<feldname>;<wert>       (Erträge — Ausschuettung_e, Aufwand_Gesamtbetrag_e, …)
EA;…                      (Ergänzende Angaben — Ausschuettungstag, Ex-Tag, Wiederanlagerabatt-Felder)
D;…                       (Dividenden)
Z;…                       (Zinsen)
ZA;…                      (Zinsen Altemissionen)
AS;…                      (Ausschüttungen Subfonds)
STB;…                     (Steuerliche Behandlung — calculated)
END;ISIN;<timestamp>
```

The **status field on Field-8 of START** (`JA` / `NEIN`) is `Jahresdatenmeldung`. Don't confuse this with the lieferant-supplied STATUS record — they answer different questions.

**Status drives which records are required:**

| Status | What CSV carries | What legacy validates |
|--------|------------------|------------------------|
| NEW | Full payload (START + STATUS + E/EA/D/Z/ZA/AS as applicable + END) | Everything (full `CheckMeldung()` + `CheckVorhandeneMeldung()`) |
| UPDATE | May be partial — only the records being updated | Field check only on records actually present in input; DB merge supplies the rest |
| CONFIRMED | Only START + STATUS + END | Forbidden-satz check + DB comparison; semantics come from the previous meldung |
| DELETE | Only START + STATUS + END | Same as CONFIRMED |

This asymmetry is the single most important fact for understanding most divergences.

## Result file layout

`ifas-testing/ifas-integration-tests/target/test-output/grossfile-recalc/<dataset>/`:

| File | Content |
|------|---------|
| `<dataset>.csv` | The input CSV extracted from the test zip. Use `awk 'NR==N' …` to peek at a Zeile. |
| `error#diff.txt` | Full per-Zeile error diff between legacy and IFAS13. |
| `error#diff-deviations.txt` | Same, restricted to entries where the two systems disagree. **This is usually what the user pastes.** |
| `error.log`, `error#recalc.log` | IFAS13 raw logs from the run. |
| `<dataset>_confirm.csv`, `_delete.csv`, `_return.csv` | Generated outputs (less useful for validation diff). |

The test that produces these is `ifas-testing/ifas-integration-tests/.../GrossfileRecalculationTest.java#givenGrossfileZip_whenRecalculate_thenWriteResultsToFilesystem`. It's `@Disabled` by default; it discovers `gf<n>-d<yyyyMMdd>.zip` files in `at/oekb/ifas/domain/recalc/grossfiles/`, parses the stichtag from the filename, and writes one output directory per dataset.

## Recurring discrepancy patterns

These have shown up in practice. When you see a new diff, match it against this list before assuming a brand-new pattern.

### 1. Status-gating divergence (most common)

IFAS13 runs a validator unconditionally; legacy only runs the equivalent check for some statuses. Tell-tale sign: `[+] NUR IM NEUSYSTEM` on a CONFIRMED or DELETE meldung where IFAS13 complains about missing CSV fields.

**Examples observed:**
- `ERR_KEINE_MELD` firing for CONFIRMED meldungen — legacy's `CheckMeldung()` (which raises this) only runs for NEW/UPDATE.
- All of `validateErgaenzendeAngaben` (`ERR_KEINE_MELD`, `ERR_AUSSCHT_FEHL`, `ERR_AUSSCHT_FEHLT`, `ERR_SATZ_FEHLT`, …) firing for CONFIRMED/DELETE.

**Fix shape:** add an early-return at the top of the affected service/method when `status ∉ {NEW, UPDATE}`. Cite the legacy split (`CheckMeldung()` vs `CheckMeldung_CONFIMED()` / `CheckMeldung_DELETE()` in `c_st_meldung.cpp`) in the comment.

### 2. Partial-update semantics

UPDATE meldung carries only the records being updated; missing records' fields should be treated as "unchanged from DB", not "missing MAN". IFAS13's Ermittlungsvorgabe validator iterates the full spec → fires `ERR_PFLICHT_FEHL` for E-satz fields on a header-only UPDATE.

**Example:** `ERR_PFLICHT_FEHL` on `Aufwand_Gesamtbetrag_e` / `Aufwand_Gesamtbetrag_KV_e` for an UPDATE with no E records.

**Fix shape:** in `SteuerMeldungErmittlungsvorgabeValidators.validateInputField`, gate the MANDATORY check on `status == UPDATE && inputHasRecordType(steuerMeldung, recordType)`. Use `CsvSteuerMeldung#getCsvMessage().hasRecordType(name)` for the presence check; return true for non-CSV sources.

### 3. Wrong field source (current vs previous)

The validator pulls a value from the input (`steuerMeldung.getX()`) where legacy uses the DB row (`previousSteuerMeldung.getX()` ← legacy's `daMelde*` variables). Often masquerades as "Jahresmeldung over-firing" because `aussch_datum` is null in DB for Jahresmeldungen but the IFAS13 input field is populated (e.g. from an EA satz aggregation).

**Examples:**
- `ERR_AUSSCHT_AKT_CONF`: legacy uses `daMeldeAussch_datum` (previous's DB column). IFAS13 was reading `steuerMeldung.getAusschuettungstag()` (current). Fix: switch to `previousSteuerMeldung.getAusschuettungstag()`.
- `ERR_VERGANGEN_UPD`: had a `getJahresdatenmeldung() == TRUE` skip guard that legacy doesn't have. Legacy gates on `selbstnachweis != "JA"`. Fix: swap the guard.

**Fix shape:** match the legacy field source verbatim. The message template often hints at the source — *"… der zugrunde liegenden Meldung"* means "previous", not "current".

### 4. Lookup pre-filtered by ISIN (cross-ISIN blind spot)

IFAS13's status validator looks up the previous meldung from a map pre-filtered to the current meldung's ISIN. That makes the cross-ISIN comparison impossible: `errIsinMid` never fires because `previousSteuerMeldung.getIsin()` is always the supplied ISIN by construction, and `errMeldidFehlt` mis-classifies a stmId that exists under a different ISIN as "not found".

**Fix shape:** "hybrid lookup". Keep the same-ISIN map for in-chain checks (`errUnglVorh`, `errUpdSelbst`, …). For `errIsinMid` and `errMeldidFehlt`, add a fallback via `stmRepository.getIsinByStmId(stmId, stichtag)` and pass a `@Nullable String previousIsinAnyMatch` to those validators. Suppress downstream same-ISIN checks when only the cross-ISIN previous exists.

### 5. Spec data mismatch (no code change needed)

The BMF Ermittlungsvorgabe Excel marks a field MAN for a version where legacy treats it OPT, or vice versa. Tell-tale: `ERR_PFLICHT_FEHL` for a field whose name doesn't appear (except commented-out) in legacy source.

**Where to look:** `ifas-domain/ifas-domain-stm/src/main/resources/at/oekb/ifas/domain/stm/vorgabe/excel/BMF_Ermittlungsvorgaben_V*.xlsx`.

**Fix shape:** adjust the Excel; or, if the spec is correct and legacy is wrong, leave it.

### 6. Classification gap (different category)

Both systems agree something is wrong but disagree on the diagnosis — legacy says `ERR_AUSSCHT_AKT_CONF` (we have an Ausschüttungsmeldung), IFAS13 says `ERR_KEINE_MELD` (this isn't even an Ausschüttungsmeldung). Means IFAS13's CSV import / EA-satz parsing isn't recognising the record. This is parsing, not validation — look in `meldung/csv/CsvIfasMessageProcessor.java` and the related CSV schema.

## Workflow for a new discrepancy

1. **Read the diff entry carefully.** Note Zeile-Nr, supplied status, error codes on each side.
2. **Pull the CSV block** for that Zeile (`awk` snippet above) so you see the full STATUS line and any E/EA records.
3. **Find the legacy raiser**:
   ```bash
   grep -an "ERR_THE_CODE" ~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/*.cpp
   ```
   Then walk *upward* from the raise site: which function are we in, and which `ProcessMeldung_*` calls it? That answers "for which statuses does legacy raise this?".
4. **Find the IFAS13 raiser**:
   ```bash
   grep -rn "ValidationMsgCode.ERR_THE_CODE" /home/sma/dev/projects/oekb/ifas13/ifas-domain --include="*.java"
   ```
   Then walk upward: which service calls the validator, what gates it?
5. **Compare the gating and the field source.** Almost every divergence I've fixed has been one of the six patterns above. Try to match.
6. **Don't fix yet — confirm the analysis with the user.** Often the cleanest fix is broader than the visible symptom (e.g. "skip the whole `validateErgaenzendeAngaben` for CONFIRMED/DELETE" vs "skip just `errKeineMeld`"). Surface both scopes and let the user pick.
7. **When fixing, leave a legacy reference in the comment** — file + line number, ideally the function name. Example:
   > Mirrors legacy `c_st_meldung.cpp:3905` (`CheckMeldung()` gated on `NEW || UPDATE`).

## Mapping a German message to a code

If the diff only shows the German text and you need the code:

```bash
grep -n "<distinctive substring>" \
  /home/sma/dev/projects/oekb/ifas13/ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/ValidationMsgCode.java
```

Or use the regex patterns:

```bash
grep -n "<distinctive substring>" \
  /home/sma/dev/projects/oekb/ifas13/ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/log/ValidationMsgCodePattern.java
```

Both files use the same templates so either works.

## Anti-patterns to avoid

- **Don't add an ad-hoc `getJahresdatenmeldung() == TRUE` skip.** It looks reasonable ("Jahresmeldungen don't have an Ausschuettungstag") but legacy doesn't gate that way and Jahresmeldungen *can* have per-EA Ausschüttungstage. Fix the field source instead.
- **Don't generalise from a single Zeile.** A fix that suppresses the visible symptom may flip other tests from `[-] NUR IM ALTSYSTEM` to `[+] NUR IM NEUSYSTEM`. Always re-run the grossfile recalc test to confirm net diff reduction.
- **Don't trust IDE indexing for legacy files.** They're ISO-8859-1 and IDE search may miss. Use `grep -an` on the filesystem.
- **Don't conflate "Zeile-Nr only in Neusystem" with parsing bugs.** It usually means the meldung *was* processed by legacy but produced no error/info, so the diff tool has nothing to align against. That's typically a status-gating divergence (legacy skipped a validator), not a parsing issue.