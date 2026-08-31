# Preismeldung validation, ported from the legacy C++

## Context

The CSV read path exists and is green: `PREISMELDUNG_LIEFERFORMAT_2026-04.csv-schema.yml` plus
`at.oekb.ifas.domain.fondspreise.csv.{CsvPreismeldungen, CsvPreismeldungMessageProcessor,
CsvPreismeldungValidations, PreismeldungFields}` and `Meldekategorie`/`PreisAktion`. It covers what a
file can be checked for without a database. This plan adds the domain validation the legacy system
actually performs, and its reporting.

**The single most useful discovery: the legacy tree is already on the 2026 10-column layout**, added
by `730bf23 OEKBSD-76527` (2026-03-24). `c_insert.cpp:231-242` is the authoritative field mapping and
it matches the schema I wrote column for column:

```cpp
case 3:   // Neues Format für in- und ausländischen Fonds-Informationen (Code per Record)
    strcextrEx(szZeile, 0, szBerechnungsDatum, cSeperator);   // 1  DATUM
    strcextrEx(szZeile, 1, szWaehrung,         cSeperator);   // 2  WAEHRUNG
    strcextrEx(szZeile, 2, szIsin,             cSeperator);   // 3  ISIN
    strcextrEx(szZeile, 3, szCode,             cSeperator);   // 4  MELDEKATEGORIE
    strcextrEx(szZeile, 4, szValue,            cSeperator);   // 5  WERT
    strcextrEx(szZeile, 5, szAktion,           cSeperator);   // 6  AKTION
    strcextrEx(szZeile, 6, szTxt_bez,          cSeperator);   // 7  FONDSBEZEICHNUNG
    strcextrEx(szZeile, 7, szLieferIntervall,  cSeperator);   // 8  PERIODIZITAET
    strcextrEx(szZeile, 8, szLMTprozentKZ,     cSeperator);   // 9  LMT_PROZENTKENNZEICHEN
    strcextrEx(szZeile, 9, szLMTDatum,         cSeperator);   // 10 LMT_STICHTAG
```

So the schema needs no revision. What follows is the validation on top of it.

## Legacy architecture

Two binaries, two concerns (`preise4/Makefile:4-6`):

| Binary | Units | Role |
|---|---|---|
| `preis_ins.e` | `preis_ins.cpp` (driver) + **`M_INSERT.CPP`** (`cInsertFile`, the engine) + `c_insert.cpp` (`SplitRow`, `cLieferBugs`) + `c_param.cpp` (**the message catalogue**) | Ingest & validate one delivered CSV per supplier → `kurs.dbo.tmp_if_kurs`, findings → `kurs.dbo.liefer_bugs`. |
| `preis_dld.e` | `preis_dld.cpp` + `m_fplausi.cpp` + `m_plausi4tag_preise.cpp` + `M_FP_DLD.CPP` + `m_fp_rec.CPP` | Plausibilise & publish afterwards. Internal OeKB report, **not supplier-facing**. |

`m_fp_rec.CPP` is the outbound file-writer, not a validator (zero `cLieferBugs` calls).

**Actual finding-report call sites: 70 live** (not the 155 a naive grep gives — that counts
doc-comments and argument continuations; 8 more are commented out). Split: 54 `WriteLieferBug`,
11 `WriteInfo`, 1 `WriteInfo2Rows`, 4 `WriteOekbInfo`.

### Reporting contract

Five log files (`M_INSERT.CPP:68-72`) — `data.log`, `error.log`, `statistics.log`, `info.log`,
`oekbinfo.log`. Routing: `WriteLieferBug` → screen + `error.log` + a `liefer_bugs` row;
`WriteInfo` → `info.log` only; `WriteOekbInfo` → `oekbinfo.log` only (OeKB-internal, never mailed as
a bug). Prefixes:

```
### delivery-bug: %6d - from: %s - file: %s - row: %05d
### delivery-info: …
--- oekb-info: %6d - from: %s - file: %s - row: %05d - format: %d
--- input row: %05d   -    <timestamp>          ← echoed for EVERY row, before validation
```

Per-row status line (`WriteDatenRecordsStatus`): `--> Status: …` with `-2` Leerzeile, `-3`
Headerzeile, `-4` Fehler im Inputformat, `-5` Zeile wird ignoriert, `0` keine Daten, `>0` inserted.

Supplier verdict is decided **in the shell, by line count** (`make_einzel.awk:311-319`):
`wc -l error.log > 5` (more than the 5-line header) → `ERROR` / `"URGENT Delivery BUGS"`, else
`INFO` / `"Delivery OK"`. Return mail attaches `error.log` + `info.log`, converted
`unix2dos -c iso` (ISO-8859-1, CRLF). A separate OeKB-only mail carries `oekbinfo.log`.

Per-file receipt row in `kurs.dbo.liefer_zeit` (bugs, infos, rows_delivered).

### The message catalogue — one place, and it is bilingual

`c_param.cpp:280-708`, `cProgParameter::InitMsgs()`, ~107 entries of
`AddMsg(numeric, "KEY", "<German>", "<English>")`, looked up **by string key**. No `check_code`
table, no `.INI` message file (`PREIS_INS.INI` is literally one line, `UseWkn=0`). A second
catalogue `cBugStatMsgs` (19 rows, `c_param.cpp:642-701`) holds the per-file bug-statistics
histogram keys — `BUG_CODE`, `BUG_VALUE`, `BUG_ISIN`, `BUG_DATE_FUTURE`, `BUG_LMT`, … — which
`grep "Bug:" statistics.log` surfaces to the supplier.

Both German and English exist for every code, switched by `-M` / `nUseEnglish`. Worth carrying both
in the Java enum.

## Three corrections to what I already wrote

### 1. ISIN *is* validated by legacy — my decision to skip it was wrong

I read the spec's *"Eine inhaltliche Plausibilisierung der Meldungen wird nicht vorgenommen"* as
covering the ISIN. It does not — it refers to the delivered **values**. Legacy rejects the row hard
for all three of:

| Const | German | Condition |
|---|---|---|
| `ERR_ISIN01` (1121) | `Ungültige Prüfziffer bei ISIN (%s) in Spalte %d: Zeile wird ignoriert.` | `IsIsin()` check digit fails |
| `ERR_ISIN02` (1122) | `Ungültige ISIN (%s) in Spalte %d: Zeile wird ignoriert.` | length ≠ 12, or char 1/2 not a letter |
| `ERR_ISIN06` (1126) | `Unbekannte ISIN (%s). Bitte geben sie OeKB die Basisdaten bekannt. Zeile wird ignoriert.` | not resolvable in `INV`/`wkn_hist` |

The PDF's 9-character LMT examples (`AT0000000`, `AT0000002`) are sloppy illustrations, not a
statement of intent. Consequence: add ISIN validation (`ISINValidator.getInstance(true)`, already
used by `CsvSteuerMeldungValidations`), and my `preismeldung_lmt_examples.csv` fixture — which uses
those ISINs verbatim — must either gain expected `INVALID_ISIN` assertions or be rewritten with real
ISINs.

### 2. The 4 % threshold is production data, not config — my earlier note was wrong

I recorded `CONFIG.INI` keys `PreisGrenze4Log` (4.0) and `GleichePreise4Log` (5) as the live
mechanism. **Those doc-comments (`m_fplausi.h:539-540`, duplicated in two more headers) are stale —
neither key is read anywhere in the tree.** The real mechanism is two DB tables
(`Ifas/tabledef/preise_check.cr`):

```sql
create table preise_check        (WFS_WKN int not null, untergrenze float null, obergrenze float null)
create table preise_check_faktor (WFS_WKN int not null, ab_tage int not null, faktor float not null)
```

with a three-level `WFS_WKN` convention: `-1` = global inland, `0` = global ausland, `>0` = per-fund.
**Neither table is seeded in the repo** — the 4 % lives as production data with no version-controlled
provenance. Formula (`c_checker.cpp:414-428`):

```cpp
nDiffTage = pdaPrDatum[0] - pdaPrDatum[1];
if (nDiffTage > 5)                                   // the ONLY hard-coded constant
    dAktZeitFaktor = GetZeitFaktor(lNum_wfs, nDiffTage);   // from preise_check_faktor, default 1.0
dAktKurs_Temp = (pdPreis[0] + dAusschuettung) * dSplitfaktor;
dAbweichung   = (dAktKurs_Temp - pdPreis[1]) / pdPreis[1] * 100.0;
if ((dAbweichung < (-1 * fabs(pdUnterGrenze[i]) * dAktZeitFaktor))
 || (dAbweichung >      fabs(pdOberGrenze[i])  * dAktZeitFaktor))  → out of tolerance
```

A fund with no `preise_check` row is **not checked at all** (`ReadGrenzwerte` returns 0). And
`makeAbweichung` always passes `-1`, so per-fund limits are never actually consulted despite the
3-level design.

The separate E/R/Z correlation tolerance **is** config: `PREIS_DLD.INI` key
`Plausi_Abweichung_ERZ`, default `"20.0"`, clamped to `[0,100]`, applied as
`fabs((E-R)/R)*100 > limit` and `fabs((R-Z)/R)*100 > limit`.

### 3. My cross-field LMT rules are stricter than legacy

Legacy has exactly three LMT checks. Two match mine; four of mine have no legacy counterpart:

| My rule | Legacy | Verdict |
|---|---|---|
| R6 — Stichtag only for L2 | `ERR_LMTRUECKL2` (1157) `LMT Datum der Rueckgabefrist darf nur bei L2 (nicht bei %s) befuellt werden, Spalte %d: Zeile wird ignoriert.` | **matches** |
| R2 — L2 + Stichtag ⇒ Wert 0 | `ERR_LMTRUECKL2_0` (1158) `LMT Datum der Rueckgabefrist darf nur bei L2 und Anzahl Tage 0 (nicht bei %.0lf Tage) befuellt werden, Spalte %d: Zeile wird ignoriert.` | **matches** |
| R3a — Aktion `I` only for L2 | `CheckAktionL2` widens `{N,D}` to `{N,D,I}` for L2 only → `ERR_AKTIONSCODE01` | same effect, but legacy models it as a per-field code check, not a combination |
| R3b — `I` ⇒ Wert 0 | *none* | **stricter than legacy** |
| R3c — `I` ⇒ Stichtag empty | *none* | **stricter than legacy** |
| R4 — L1/L3 must not report 0 | *none.* Driven by `tax_code.untergrenze = 0` + `dValue < untergrenze`, so **0 itself passes** | **stricter than legacy** — but the PDF §4.2 explicitly forbids it |
| R5 — Prozentkennzeichen only for L1/L3 | *none.* Only `J`/`N` syntax is checked (`ERR_LMTPROZENT1`, 1156) | **stricter than legacy** |
| R7 — L2 + Wert 0 + no Stichtag ⇒ Stichtag required | *none.* Col 10 is optional; legacy only rejects it when present-and-inconsistent | **stricter than legacy** |

Note also: legacy's two LMT date/percent rejections are **field-level** — the field is cleared and
the row still inserts. Mine reject nothing (they only report), which is closer to legacy than to a
row rejection.

Two further legacy facts that bear on the schema:

- **Column 8 has been discarded since 2017** (`M_INSERT.CPP:1189-1193`: with
  `daNoEuQust = 2017.01.01`, `szLieferIntervall` is unconditionally blanked), so `ERR_INTERVALL01/02`
  are dead code in practice and `liefer_intervall` is never consulted. My `defaultValue: D` is
  harmless but the value goes nowhere.
- **LMT rows are validated and then dropped** — `SavePreisRecords` skips `gruppe == "LMT"`. The LMT
  persistence layer exists only on branch `origin/OEKBSD-80767` (not an ancestor of master), and that
  branch models **four** dimensions (adding Dual Pricing and Swing Pricing), not three.
- **Future dates: `daCheckdatum > daAktdatum`** (`M_INSERT.CPP:2792`) — strictly later than today,
  so **today is allowed**. That settles the `isAfter` vs `!isBefore` question I had left open. Global
  switch `nAllowFutureValues = 0`; per-code opt-out `tax_code.future`, which is `'N'` for L1/L2/L3.

## The rule inventory, tiered by what IFAS13 can do today

Most per-value validation is **data-driven from `kurs.dbo.tax_code`** — `untergrenze`, `obergrenze`,
`max_nk`, `future`, `isinwaehrung`, `intervall_irregulaer`, `lieferung_ab`, `lieferung_bis`,
`datum_max`, `datum_min`, `datum_bug_or_ignore`, `ignore_null`, `gruppe`. **IFAS13 has no `tax_code`
table, entity or migration** (verified: zero hits in the flyway tree and no Java type). That, plus
the absence of price history, is what tiers the work.

### Tier 1 — implementable now, no new tables

| Rule | Legacy const + German | IFAS13 means |
|---|---|---|
| invalid date | `ERR_DATE02` (1132) `Ungültiges Datum (%s) in Spalte %d: Zeile wird ignoriert.` | `CsvIfasDateFormat` + parse |
| date in the future | `ERR_DATE03` (1133) `Datum (%s) in Spalte %d ist in der Zukunft: Zeile wird ignoriert.` | a `stichtag` parameter (not `LocalDates.now()`, so tests stay deterministic) |
| ISIN checksum / shape / unknown | `ERR_ISIN01` / `ERR_ISIN02` / `ERR_ISIN06` | `ISINValidator`; `InvRepository.getInvByIsin` |
| Code missing | `ERR_CODE03` (1001) `Mandatory Feld Code in Spalte %d wurde nicht angegeben: Zeile wird ignoriert.` | schema `required` (done) |
| Wert not numeric / empty | `ERR_VALUE08` (1009), `ERR_VALUE04` (1005) | schema `AMOUNT_NK8` (done) |
| Aktion invalid | `ERR_AKTIONSCODE01` (1145) `Ungültiger Aktions-Code (%s), Spalte %d: Zeile wird ignoriert.` | `PREIS_AKTION` type (done) |
| LMT-Prozentkennzeichen invalid | `ERR_LMTPROZENT1` (1156) | `J_N` type (done) |
| LMT cross-field | `ERR_LMTRUECKL2`, `ERR_LMTRUECKL2_0` | `CsvPreismeldungValidations` (done) |
| currency unknown / not in HWA | `ERR_CURRENCY01` (1111) `Ungültiger ISO Währungscode (%s) - Spalte %d: Zeile wird ignoriert.`; `INFO_CURRENCY02` (1112) `Info: Gültiger ISO Währungscode (%s) - wurde in Tabelle HWA noch nicht angelegt` | **`HwaRepository` + `WaehrungRepository` both exist.** Note the hard-coded legacy-currency exclusion list (`ATS BEF DEM ESP FRF GRD ITL LUF NLG PTE XEU`, `c_waehr.cpp:138`) |
| currency ≠ tranche currency | `ERR_CURRENCY03` / `ERR_CURRENCY04` (both 1113) | `Inv.getWaehrung()` |
| foreign/domestic scope | `ERR_ISIN03` (1123) / `ERR_ISIN04` (1124) | `Inv` KAG, `< 10000` = inland |
| Lieferant not authorized | `ERR_ISIN05` (1125) `User %s ist nicht berechtigt für ISIN (%s) zu liefern. Zeile wird ignoriert.` | `KAG_lieferanten` exists (`V011__lieferanten.sql`). **Off by default in legacy** (`nCheckKag = 0`, needs `-K1`) |
| delivery after Fonds-Ende | `ERR_DATE04` (1134) | `Inv.fondsEnde` |
| delivery before Fonds-Beginn | `INFO_DATE02` (1136) — **OeKB-info only, row proceeds** | `Inv.fondsBeginn` |
| not an Austrian Börsetag | `INFO_DATE01` (1135) `Info: Datum %s (%s, Spalte: %d) ist kein gültiger Börsetag in AT.` — info only | **`AustrianBankingDays` already in `ifas-domain-core`** |
| Z ≤ R, E ≥ R (within file) | `ERR_VALUE06` (1007) / `ERR_VALUE05` (1006) | cross-row over the `CsvFile`'s messages; legacy windows this to ±16 rows (`lRange4Preis`) purely for speed |
| DELETE followed by a new row | `INFO_DEL_NEW` (2011) `Info: Dem DELETE Record folgt ein neuer Datensatz in Zeile %d. Delete-Zeile wird ignoriert.` — **the only `2Rows` variant**, logs both lines | cross-row, forward scan |
| blank / all-zero rows | status `-2`, no bug | exact matches on `""`, `";;;;;;;;;;;;;"`, `"0;0;0;0;0.0000;0;;0"`, and `strlen < 10` |
| Aktion `D` short-circuit | `M_INSERT.CPP:3157-3163` — after the code-exists check, before numeric/empty/`max_nk`/bounds/currency | |
| file-level: encoding, xls/xlsx magic, no data | `ERR_FORMAT03` (1903) UTF-16LE/BE, `ERR_FORMAT04` (1904) xls/xlsx, `ERR_FORMAT02` (1902), `ERR_NODATA01/02` | byte-prefix sniffing before parse |

### Tier 2 — DEFERRED (would need a `tax_code` equivalent)

`untergrenze` / `obergrenze` (`ERR_VALUE01` 1002, `ERR_VALUE02` 1003), `max_nk` (`ERR_VALUE09`
1010), `future`, `isinwaehrung`, `gruppe` (PREIS/SOLVA/LMT — needed for the group-based format rules
and the LMT-drop decision), `lieferung_ab`/`lieferung_bis`/`datum_max`/`datum_min` (`ERR_CODE02`
1000), `ignore_null`, `intervall_irregulaer` (`ERR_INTERVALL02` 1142 — dead in practice), and the
code/alias list itself (`ERR_CODE01` 999). The L1/L2/L3 seed rows are known verbatim from the
deleted `insert_tax_code_lmt.cr`: all `gruppe=LMT`, `mandatory=O`, `inland_ausland=I`,
`untergrenze=0`, `future=N`, `isinwaehrung=J`, `max_nk=8`, `lieferung_ab=2026-03-01`,
`obergrenze` NULL.

### Tier 3 — needs price history (new tables) 

`Check4DeleteInTmp` idempotency reconciliation (`INFO_DEL_TMP_N` 2013, `INFO_IGNORE_DEL` 2014,
`INFO_DEL_TMP` 2012), and all of Stage B: previous-day deviation, E/R/Z correlation,
missing-delivery detection (`cCheck4TaeglichePreise`: `nMinTage4Meldung=3`, `nMaxTage4Meldung=11`,
walked in `KTA` exchange trading days, triggered by `INV.preismeldung = 'TGL'` — **not** by
`liefer_intervall`, which is never enforced anywhere).

## Legacy defects — document, do not replicate

1. **`c_insert.cpp:928` — misplaced `return 9;`.** Inside `if (nAllowTxtExt4PreisFile == 0)` but
   outside the extension test, so with the documented default of `0` *every* file, `.csv` included,
   is rejected as unprocessable. Production must run with `AllowTxtExt4PreisFile=1`.
2. **`M_INSERT.CPP:2906` — `datum_min` comparison inverted** (`daCheckdatum > daDatumMin` where `<`
   is meant; the three sibling date checks all use the correct direction). Latent only because no
   code currently sets `datum_min` together with `datum_bug_or_ignore='J'`.
3. **`m_plausi4tag_preise.cpp:463` — assigns `nMinTage4Meldung` where `nMaxTage4Meldung` is meant**,
   so an out-of-range `Preis_MaxTage4Meldung` clobbers the wrong field.
4. `ERR_GJAHR02` (1202) is defined but its emission is commented out.
5. Duplicate numeric codes (`1113` for `ERR_CURRENCY03` *and* `ERR_CURRENCY04`; `2102`; `3011`) —
   harmless only because lookup is by string key.
6. SQL built by `dbfcmd(…'%s'…)` with only `"`→`'` substitution — supplier-controlled
   `szTxt_bez` (200 bytes) reaches `liefer_bugs` that way.

## The extraction

`ifas-domain-core` is the target: a flat 8-file module in `at.oekb.ifas.domain.core` already holding
`IfasCharsets`, `IfasCsvMeldeFileType(s)` and `AustrianBankingDays`. `ifas-domain-core → core-support`
and `csv-schema → core-support` only, so **adding `csv-schema` to `ifas-domain-core`'s pom creates no
cycle**; `ifas-domain-stm` already depends on both.

### `at.oekb.ifas.domain.core.csv` — move as-is (small blast radius)

`CsvIfasDateFormat` (5 referencing files), `CsvTypeConversions` (10), `CsvIfasFilenameValidator` (5).
All three are IFAS-generic with no STM import.

### `CsvIfasValueTypeValidator` — move whole, do **not** split

An earlier draft of this plan split it per domain. That was over-engineering: 4 of the 7 value types
Preismeldung uses (`DATE`, `TEXT`, `AMOUNT_NK8`, `J_N`) are shared with STM/Ausschuettung anyway, so
a split produces a shared pattern holder *plus* two or three thin validators to express what one flat
map says today. The class name already says `Ifas`, not `Stm`; the objection was to its **package**,
not to one file owning the whole IFAS CSV vocabulary.

So move the file as-is to `at.oekb.ifas.domain.core.csv`, keeping every pattern together — STM's,
Ausschuettung's `J_N`, and the three `PREIS_*`. One obvious place to add a value type, and the
typo-becomes-a-runtime-throw trap is already covered by
`PreismeldungCsvSchemaTest#givenEveryDeclaredValueType_whenValidate_thenPatternIsRegistered`.

The one obstacle is `STM_STATUS`, the only pattern generated from an enum
(`StmStatus.values()`, in `ifas-persistence-stm`). `ifas-domain-core` must not depend on a
persistence module — that inverts the layering. Write it as a literal alternation like its five
siblings (`ART`, `ERTRAGSTYP`, `W_RABATT_ART`, `KAPITAL_RUECKZAHLUNG` already duplicate their enum
constants by hand), and add a guard test in `ifas-domain-stm` asserting the literal still matches
`StmStatus.values()` — the generated-ness becomes a verified invariant rather than a compile-time
dependency, and the entry stops being the map's lone exception. `StmStatus` is a stable 12-constant
enum, so the guard is cheap.

### `at.oekb.ifas.domain.core.validation` — new, small

The genuinely duplicated logic is argument formatting: `ValidationMsgCode.formatMessage` and
`IsinAnforderungValidationMsgCode.formatMessage` implement the same dispatch independently. Extract:

- `ValidationCode` — `String name()`, `String formatMessage(Object... args)`
- `ValidationSeverity` — `{ERROR, INFO}`; both existing families already use exactly these two, and
  it is an exact match for legacy `T_BUG_INFO in ('B','I')`
- `ValidationMsgArguments` — the shared dispatch (`BigDecimal`→4 NK via `roundWithPreScale`,
  `Double`/`Float`→`###0.0000`, `Number`→`###0`, `LocalDate`→`yyyy.MM.dd`, `Boolean`→`JA`/`NEIN`,
  `null`→`"leer"`, German locale with an ASCII dot separator)

`ValidationMsgCode implements ValidationCode` and delegates its formatting — additive, no signature
change, no touch to its 141 constants, the twin `ValidationMsgCodePattern`, or the 28-class delta
package. `IsinAnforderungValidationMsgCode` adopts it in the same pass, which is what proves the
extraction earns its keep.

**Not moved: `FieldName`** (64 referencing files). Preismeldung's field names are the fixed constants
in `PreismeldungFields` with no `Ermittlungsvorgabe` numeric codes to resolve — the only thing
`FieldNameResolver` exists for.

**Do not extend `ValidationMsgCode`.** It has a twin enum `ValidationMsgCodePattern` (136 constants)
mirroring it by `name()` with regexes instead of templates; that pair is the legacy-log-parity
contract, joined by name in `…/stm/validation/delta/`. Adding Preismeldung texts would break the 1:1
correspondence.

### Undo the STM/Preismeldung mixing I introduced

| File | Undo |
|---|---|
| `…/stm/meldung/csv/CsvIfasValueType.java` | remove the three `PREIS_*` constants |
| `…/stm/meldung/csv/CsvTypeCoercions.java` | remove the `VALUE_TYPE_TO_CLASS` entries and the `coerce` arm |
| `…/stm/meldung/csv/CsvValueFormatters.java` | remove the `formatValue` arm entries |
| `…/stm/validation/ValidationMsgMapper.java` | remove the three names from the `ERR_UNG_CODE` group |

The first three are the *write* side and Preismeldung has no write path, so those constants were
speculative. The regexes move to the Preismeldung-owned validator.

## What Preismeldung owns

In `at.oekb.ifas.domain.fondspreise`, following the STM convention and `isinanforderung` (both by
Manfred Geiler / Mathias Scharl — note `ausschuettung` is **not** a template: it is
`fabian663`-originated and carries the two defects already documented plus validation that duplicates
the schema with drifted regexes):

- `PreismeldungValidationMsgCode implements ValidationCode` — the transcribed German (and English)
  texts, `ERR_`/`INFO_` prefixes, keeping the legacy numeric code as a field for traceability
- `PreismeldungValidationMsg` — severity from the name prefix, plus the **optional second line/row
  pair** that legacy's `WriteInfo2Rows` needs (`CsvMessagePosition` and
  `IsinAnforderungValidationMsg` can each express only one position)
- `PreismeldungValueTypeValidator` — the three `PREIS_*` patterns
- `PreismeldungDomainValidationService` — `@Service`, repositories by constructor, resolving every
  lookup up front and passing plain values into `@UtilityClass` static
  `errXxx(List<ValidationMsg> msgs, …)` rules, exactly as `SteuerMeldungDomainValidationService`
  does with `HwaRepository`/`WaehrungRepository`/`InvRepository`/`WknDescRepository`
- `PreismeldungLogWriter` / `PreismeldungLogs` — `error.log` / `info.log` / `oekbinfo.log` in the
  legacy format, over `TextWriterHelper` + `IFAS_LOG_CHARSET`

No `liefer_bugs` table (your call) — findings stay in memory and go to the logs. Recorded as the
deferred option needed only if a Stage-B Plausibilität must read findings back.

## Decisions

- **The four PDF-only LMT rules stay** (`I`⇒Wert 0, `I`⇒Stichtag empty, L1/L3 must not report 0,
  Prozentkennzeichen only for L1/L3). The PDF §4.2 forbids them, so the new system is right and
  legacy is lenient. They need a **known-divergence marker** so the diff classifies them instead of
  flagging regressions — see below.
- **Tier 2 is deferred entirely.** No `tax_code` equivalent, no new Flyway migration. The bounds,
  `max_nk`, `future`-per-code, `isinwaehrung` and delivery-date-window rules are simply not
  implemented, and that is documented rather than stubbed.
- **The extraction lands as its own preparatory commit**, no behaviour change.

### Expressing the known divergence

STM already has this exact concept: five `ValidationMsgCode` constants
(`ERR_*_VORH_LIEFERUNG`, `ERR_STATUS_NM_LIEFERUNG`, `ERR_UPD_OLDM_LIEFERUNG`,
`ERR_MELDID_NICHT_MEHR_GUELTIG`) are deliberately **absent** from the twin
`ValidationMsgCodePattern`, because legacy can never emit them; the delta layer then treats them via
`CoveredByRule` implementations rather than as unmatched findings.

Mirror that with a single field rather than a second enum: give
`PreismeldungValidationMsgCode` the legacy numeric code where one exists
(`ERR_LMTRUECKL2` → 1157, `ERR_LMTRUECKL2_0` → 1158, `ERR_ISIN01` → 1121, …) and leave it **absent
for the four PDF-only rules**. "No legacy code" then *is* the divergence marker — self-documenting,
impossible to forget when adding a constant, and directly usable by the future diff to classify a
finding as expected-only-in-new. It also carries the legacy traceability for free.

## Staging

**Commit 1 — extraction, no behaviour change.**
Move `CsvIfasDateFormat`, `CsvTypeConversions`, `CsvIfasFilenameValidator` and
`CsvIfasValueTypeValidator` (whole, `STM_STATUS` literalised + guard test) to
`at.oekb.ifas.domain.core.csv` (add `csv-schema` to `ifas-domain-core`'s pom); add
`at.oekb.ifas.domain.core.validation` (`ValidationCode`, `ValidationSeverity`,
`ValidationMsgArguments`) and have `ValidationMsgCode` plus
`IsinAnforderungValidationMsgCode` delegate their formatting to it; undo the four `PREIS_*`
insertions into STM classes. Regression net: the existing 1395 `ifas-domain-stm` tests, unchanged.
Use IDE/MCP move-refactorings, not `mv` — git rename tracking and reference updates.

**Commit 2 — the Preismeldung message layer.**
`PreismeldungValidationMsgCode` (German + English texts, `ERR_`/`INFO_` prefixes, optional legacy
numeric code), `PreismeldungValidationMsg` (severity from the name prefix, optional second
line/row pair for the `WriteInfo2Rows` case), `PreismeldungValueTypeValidator` with the three
`PREIS_*` patterns, `PreismeldungLogWriter`/`PreismeldungLogs` writing `error.log` / `info.log` /
`oekbinfo.log` in the legacy format, and a mapper from the existing `CsvValidationMsg`s.

**Commit 3 — Tier 1 domain rules.**
`PreismeldungDomainValidationService` with the reference-data checks (ISIN checksum/shape/unknown,
currency via `Hwa`+`Waehrung`, tranche-currency mismatch, Lieferant/KAG, `fonds_beginn`/`fonds_ende`,
Börsetag info via `AustrianBankingDays`), the future-date check against a passed-in `stichtag`, and
the cross-row checks (`Z ≤ R`, `E ≥ R`, DELETE-followed-by-new) over the `CsvFile`'s messages. Plus
the ISIN correction and its fixture consequence: keep one fixture carrying the PDF's 9-character
ISINs verbatim and assert the `INVALID_ISIN` findings on it, and give
`preismeldung_lmt_examples.csv` real 12-character ISINs so it keeps testing what it was written for
(the trailing-delimiter regression).

**Deferred** — Tier 2 (`tax_code` reference data) and Tier 3 (price history: the
`Check4DeleteInTmp` reconciliation and all of Stage B).

## Verification

```bash
mvn -Pno-proxy -o -pl support-libs/csv-schema,ifas-domain/ifas-domain-core,ifas-domain/ifas-domain-stm -am clean install -DskipTests
mvn -Pno-proxy -o -pl ifas-domain/ifas-domain-stm test -Dtest='Preismeldung*,CsvPreismeldung*'
mvn -Pno-proxy -o -pl ifas-domain/ifas-domain-stm test          # 1395 tests, the extraction's net
mvn -Pno-proxy -Pdev-build -Pskip-postgres15-tests -Pskip-sybase16-tests -o clean install
```

Tier-1 DB rules need integration tests: follow `SteuerMeldungDomainValidationServiceTest`'s
base + overlay fixture layout (`*_base.yaml` shared master data, `*_{scenario}.yaml` overlays merged
via `em.merge()`, `*_{scenario}.csv` inputs) with `@TestTemplate` + `TEST_WITH_H2_ONLY`.
`HwaTestdata`/`HwaTestdataCreator`, `WaehrungTestdata` and `LieferantTestdataCreator` already exist.

When you supply sample Preisfiles plus their legacy output, add a golden-file parity test in the
shape of `ValidationDeltaCalculatorIntegrationTest` — keep the fixture loader separate from the
inline-CSV tests so it can be dropped in without restructuring.
