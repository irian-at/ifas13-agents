# Plan: exclude errored Meldungen from prefilled-Excel generation, and analyze legacy STM coexistence rules

## Context

The `IllegalStateException("More than one match")` at
`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/recalc/RecalculationOutputs.java:483`
fired on the test server for
`ifas-testing/.../gf1-d20260724/gf1-d20260724.csv` rows 573 and 578
(ISIN `DE0008490954`, identical except for the **Selbstnachweis** flag —
row 573 = `JA`, row 578 = default `NEIN`).

A first fix has already been applied to make the prefilled-Excel filename
unique for the Selbstnachweis variant — `_SN` is appended in
`ExcelErmittlungsvorgaben.getPrefilledExcelFilename(...)`
(`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/vorgabe/excel/ExcelErmittlungsvorgaben.java:40-46`).
That alone resolves the assertion failure. But it surfaced a second
problem: the Selbstnachweis row in question is **already flagged as an
ERROR** by validation. The error log
(`ifas-testing/.../gf1-d20260724/error#recalc.log`) shows for row 573:

> `ERROR! Die Meldung erfolgt waehrend der Melde- bzw. Korrekturfrist und
>  kann daher nicht als Selbstnachweis Meldung abgegeben werden.`
>
> Followed by: `Steuerdaten-Meldung wird NICHT VERARBEITET`

Yet a prefilled-Excel file is still produced for it. The validation says
"will not be processed", the recalc pipeline says "here's your prefilled
Excel" — inconsistent.

## Why the errored Meldung still reaches prefill

Three layers conspire — none filter on validation outcome:

1. `SteuerMeldungLieferungService.loadAndValidateSteuerMeldungLieferungFromCsv(...)`
   (`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/SteuerMeldungLieferungService.java:155-159`)
   builds the `DefaultSteuerMeldungLieferung` from the full
   `steuerMeldungen` list. Validation errors are recorded in the parallel
   `validationMsgs` list, not by removing the offending STM from
   `steuerMeldungenByKey()`.

2. `SteuerlicheErmittlungDomainService.internalProcessLieferung(...)`
   (`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/ermittlung/SteuerlicheErmittlungDomainService.java:76-133`)
   does mark failed Meldungen with `StmStatus.ERROR` — but only on the
   wrapper `ProcessedSteuerMeldung`, via `markInputStmWithFailedStatus(...)`
   (line 89, 140). The **input** STM inside
   `lieferung.steuerMeldungenByKey()` (or `…byInstanceKey()` locally) keeps
   its original status (`NEW`). So a downstream consumer reading the
   Lieferung map cannot distinguish accepted from rejected.

3. `BundleRecalculationResults.canPrefillExcelWith(...)`
   (`ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/recalc/BundleRecalculationResults.java:212-220`)
   filters only on `stm.getErmittlungsvorgabe() != null`. The
   Ermittlungsvorgabe is attached during CSV loading, before status
   validation, so every STM the user submitted — including errored ones —
   passes.

## Part 1 — code change

### A. Tighten `canPrefillExcelWith`

`BundleRecalculationResults.canPrefillExcelWith(SteuerMeldung)` is too
permissive. Skip STMs that have at least one ERROR-severity
`ValidationMsg` targeting them. The signal is already present in
`lieferung.errorValidationMsgs()`; each `ValidationMsg` carries a
`SteuerMeldungPosition` referencing its owner STM.

Sketch:

```java
static Stream<SteuerMeldung> getSteuerMeldungenForExcelPrefill(
        SteuerMeldungLieferung lieferung
) {
    Set<SteuerMeldung> errored = lieferung.errorValidationMsgs().stream()
            .map(msg -> msg.getPosition())
            .filter(SteuerMeldungPosition.class::isInstance)
            .map(p -> ((SteuerMeldungPosition) p).steuerMeldung())
            .collect(Collectors.toSet());
    return lieferung.steuerMeldungenByInstanceKey().values().stream()
            .filter(BundleRecalculationResults::canPrefillExcelWith)
            .filter(stm -> !errored.contains(stm));
}
```

Notes:
- Use identity (`Set<SteuerMeldung>` with reference-equality semantics) or
  match by `LieferungStmInstanceKey` / `stmId`, depending on whether
  `SteuerMeldung` overrides equals/hashCode. Easiest reliable form: build
  a `Set<LieferungStmInstanceKey>` (local) / `Set<LieferungStmKey>` (pushed)
  from the errored STMs, then exclude.
- `canPrefillExcelWith(stm)` still checks
  `ermittlungsvorgabe != null` as before.
- Don't fold the error-skip into `canPrefillExcelWith` itself — that
  function only knows the STM, not the Lieferung's `validationMsgs`. Do
  the cross-reference in `getSteuerMeldungenForExcelPrefill(...)`.

### B. Keep the `_SN` filename suffix

Already applied at `ExcelErmittlungsvorgaben.java:40-46`. Keep it.
Belt-and-suspenders: even after the validation refactor blocks
illegitimate Selbstnachweis-coexistence cases, the filename should still
be unambiguous for a regular-JM + Selbstnachweis-JM pair that legitimately
passes validation.

### C. Verification

- `mvn -Pno-proxy -pl ifas-domain/ifas-domain-stm test`
- Run the integration test that consumes `gf1-d20260724.csv` end-to-end.
  Expected:
  - No `IllegalStateException("More than one match")`.
  - The recalc bundle for ISIN `DE0008490954` produces **one** prefilled
    Excel — for row 578 (the regular JM, no error). Row 573 (Selbstnachweis
    with ERR_FRIST_SN) gets none.
  - All other prefilled Excels in the bundle are unchanged (byte-identical
    filenames for any STM where Selbstnachweis was false / unset).

## Part 2 — follow-up CPP analysis (this is the bigger question)

The Part-1 filter unblocks the test server, but the underlying domain rule
is unresolved: **which combinations of `(Jahresmeldung, Ausschüttungsmeldung,
Selbstnachweis J/N)` are legitimate for the same `(ISIN, Geschäftsjahr-Ende)`
within one Lieferung, and how are they validated?**

The new Java behavior after `e1cade6e` ("feat: add Selbstnachweis to
LieferungStmKey") treats `(isin, jahresdatenmeldung, gjEnde, selbstnachweis)`
as the in-Lieferung uniqueness key, which means a regular JM and a
Selbstnachweis-JM occupy *separate* slots. The `LieferungStmKey` Javadoc
claims this is by design ("a Selbstnachweis-Jahresmeldung coexists with a
regular Jahresmeldung for the same ISIN and Geschäftsjahr in the same
Lieferung"). The legacy C++ behavior needs to be confirmed before deciding
whether this is correct.

### Concrete questions to answer from `/home/sma/dev/projects/oekb/ifas`

For one Lieferung (CSV file) containing multiple Meldungen for the same
ISIN + Geschäftsjahr-Ende:

1. **JM + AM for same (ISIN, GJ_Ende)** — are they allowed to coexist?
   The Java code currently distinguishes them via the
   `jahresdatenmeldung` flag in the key. Confirm the same is true in CPP.
2. **JM + Selbstnachweis-JM for same (ISIN, GJ_Ende)** — allowed? The Java
   code currently allows it. What does CPP do?
3. **JM + Selbstnachweis-NEIN + Selbstnachweis-JA + AM** — what's the
   maximum legitimate set of Meldungen for one (ISIN, GJ_Ende) slot in one
   Lieferung?
4. **Where is the application-layer "Jahresmeldung-vorhanden" check?** A
   previous Explore agent reported only the DB unique constraint
   `(num_wfs_ku, gj_ende, guelt_ab)` in
   `/home/sma/dev/projects/oekb/ifas/Kurs/tabledefs/steuer_meldung.cr:125`.
   That doesn't include `selbstnachweis` or `jahresdatenmeldung`, so it
   doesn't decide the policy alone. The application-level check is likely
   in `Ifas/cprogs2/.../c_st_meldung.cpp`, referenced from
   `SteuerMeldungStatusValidationService.java:105` as
   `CheckVorhandeneMeldung`. Locate it and read its predicate.
5. **Frist rules around Selbstnachweis.** The error in the test data is
   `ERR_FRIST_SN` / `ERR_SN_INMELDEFRIST` ("Die Meldung erfolgt waehrend
   der Melde- bzw. Korrekturfrist und kann daher nicht als Selbstnachweis
   Meldung abgegeben werden"). Confirm the legacy implements the same
   Frist gate, and that the Frist windows match (Java refers to these
   in `SteuerMeldungFristenValidators.java`).

### Where to look in the CPP

- `Ifas/cprogs2/...` — main application sources. Greps for
  `Jahresdaten`, `Selbstnachweis`, `JM_VORH`, `vorhanden`, `mehrfach`,
  `Frist`, `Melde[\-_ ]?frist`, `Korrekturfrist` are starting points.
- `Ifas/tabledef/insert_update/ins_del.cr` and
  `Kurs/tabledefs/insert_tax_selbst.cr` — touched by earlier grep for
  "Selbstnachweis", may show insert/update side rules.
- `Kurs/tabledefs/steuer_meldung.cr:89-90, 125-126` — schema columns and
  unique constraints (already reviewed; both flags are stored but neither
  is in a uniqueness key).
- `Ifas/scripts/templates/template_*_jahr_kest*.txt` — message templates,
  may surface the exact German phrasings to grep for.

### Output of Part 2

A short follow-up note (or this file appended) capturing:

- The matrix of allowed/disallowed (JM, AM, SN-JA, SN-NEIN) combinations
  per (ISIN, GJ_Ende) within one Lieferung as the legacy CPP enforces it.
- The CPP source(s) that encode each rule (file:line).
- Whether the new Java key choice `(isin, jahresdatenmeldung, gjEnde,
  selbstnachweis)` matches the legacy policy, or where it diverges.
- A recommendation for any follow-up adjustment to
  `InLieferungAcceptedState.acceptedNewKeys`,
  `SteuerMeldungStatusValidationService.findExistingMeldungStmIdByGjEndeAndJahresMeldung(...)`,
  or both.

This Part-2 work does not block Part 1 from going in.

---

## Part 2 — CPP findings

All CPP file:line references below are absolute paths under
`/home/sma/dev/projects/oekb/ifas`.

### The "vorhandene Meldung" predicate

The Java method
`SteuerMeldungStatusValidationService.findExistingMeldungStmIdByGjEndeAndJahresMeldung(...)`
is named for legacy `cSt_Meldung::CheckVorhandeneMeldung(DBCmd*)` in
`Ifas/cprogs2/preise4/c_st_meldung.cpp`. The function is huge (~7806–9150)
and dispatches on `strStm_status_angeliefert` (NEW / CONFIRMED / UPDATE /
DELETE). The branch that decides "is this NEW Meldung a duplicate of an
existing active one?" is at lines 7826–7919.

The actual SQL predicate it builds (`c_st_meldung.cpp:7836–7854`):

```cpp
select stm_id
  from kurs..steuer_meldung m, vwkn.dbo.wkn_hist h
 where num_wkn = '<isin>'
   and gj_ende = '<gj_ende>'
   and jahresdatenmeldung = '<JA|NEIN>'
   /* line 7841–7844 — the key Selbstnachweis branch: */
   and (strSelbstnachweis == "JA"
        ? selbstnachweis = 'JA'
        : isnull(selbstnachweis, 'NEIN') <> 'JA')
   /* For Ausschüttungsmeldung only, also constrain Meldezeitraum: */
   and (strJahresmeldung != "JA" ?
            meldungszeitraum_beginn = '...'
        and meldungszeitraum_ende  = '...' : true)
   and m.num_wfs_ku = h.num_wfs_ku and cod_quelle = 'ISIN'
   and guelt_bis is null
```

So **the CPP existence check partitions on four fields**:
`(ISIN, gj_ende, jahresdatenmeldung, selbstnachweis-bucket)` — where the
selbstnachweis bucket is binary: `'JA'` vs. `not 'JA'` (i.e. NEIN or
NULL). For an Ausschüttungsmeldung the Meldezeitraum is added.

If at least one row matches, the action depends on
`jahresdatenmeldung` (`c_st_meldung.cpp:7876–7913`):

- **`jahresdatenmeldung = 'JA'`** → `cStm_Logger::WriteStmBug("ERR_JAHRESM_VORH", …)`,
  status set to `NEW_DECLINED`, return `-1` (error). The error message
  reads "Es liegt bereits eine Jahresmeldung … vor."
- **`jahresdatenmeldung = 'NEIN'`** → `cStm_Logger::WriteStmInfo("ERR_AUSSCHM_VORH", …)`
  and `cProStatus.nCheckVorhandeneMeldung = 3 /* INFO */`. Despite the
  `ERR_` prefix this is logged as **info, not error** — the line
  `cStm_Logger::WriteStmBug(...)` above it is commented out
  (`c_st_meldung.cpp:7900–7904`), and `c_stm_logger.cpp:399` annotates
  `ERR_AUSSCHM_VORH` with `// Wird derzeit als Info verwendet`.

The error texts are registered in
`Ifas/cprogs2/preise4/c_stm_logger.cpp:397–399`.

### Coexistence matrix within one Lieferung

Inside a single Lieferung (the CSV being imported), CPP processes rows
one at a time and applies `CheckVorhandeneMeldung` against the
**already-persisted** dataset (after each row's commit). Two rows in the
same Lieferung therefore collide via the same predicate as a row vs.
historical state. From the predicate above:

| Combination, same `(ISIN, gj_ende)`                | Coexist? | CPP source |
|-----------------------------------------------------|----------|------------|
| JM-`NEIN` + AM-`NEIN`                               | Yes      | predicate splits by `jahresdatenmeldung` (`c_st_meldung.cpp:7840`) |
| JM-`NEIN` + JM-`JA` (Selbstnachweis variant)        | Yes      | predicate splits by SN-bucket (`c_st_meldung.cpp:7841–7844`) |
| AM-`NEIN` + AM-`JA` (Selbstnachweis variant)        | Yes¹     | same SN-bucket logic + Meldezeitraum partition |
| Two JMs, same SN bucket                             | **No**   | `ERR_JAHRESM_VORH` (`c_st_meldung.cpp:7885`) → `NEW_DECLINED` |
| Two AMs, same SN bucket, same Meldezeitraum         | **No**²  | matched by predicate; logged as info, the second is still rejected for duplicate Meldezeitraum |
| JM + AM + SN-`JA` JM + SN-`JA` AM (the full quartet) | Yes¹     | each row distinct on the 4-tuple `(ISIN, gj_ende, JM-flag, SN-bucket)` |

¹ Subject to Frist gates (`ERR_FRIST_SN` / `ERR_SN_INMELDEFRIST`, see
below) — those reject *individual* rows, they do not change the
uniqueness key.

² AM+AM with different Meldezeitraum is allowed (e.g. two distribution
events in the same Geschäftsjahr); the Meldezeitraum filter at
`c_st_meldung.cpp:7848–7851` ensures only the exact-same window
collides.

### ERR_SN_INMELDEFRIST and ERR_FRIST_SN

Frist messages are defined at
`Ifas/cprogs2/preise4/c_stm_logger.cpp:245–251`:

- `ERR_SN_INMELDEFRIST` — "Die Meldung erfolgt waehrend der Melde- bzw.
  Korrekturfrist und kann daher nicht als Selbstnachweis Meldung
  abgegeben werden."
- `ERR_FRIST_SN` — "Ende der Frist fuer den Selbstnachweis erreicht,
  keine Meldung mehr moeglich."

The two Frist dates are computed in
`c_st_meldung.cpp:512–516`:

```cpp
// daDatum = run-day "Stichtag"
daFristDatum  .Add(daDatum,    -nSTM_Frist_Monate, "M", 0); // default 7 months
daSNFristDatum.Add(daFristDatum, -12,               "M", 0);
```

So the test is in terms of `daGj_ende` vs. these dates:

- **Inside regular Frist** ⇔ `daFristDatum  <= daGj_ende` (the GJ-Ende
  is no older than 7 months from Stichtag).
- **Outside SN Frist** ⇔ `daSNFristDatum > daGj_ende` (older than
  7 months + 12 months from Stichtag).

`CheckLieferfristen` at `c_st_meldung.cpp:9579–9695` (for NEW) and
`CheckVorhandeneMeldung` UPDATE-on-FINAL branch at
`c_st_meldung.cpp:9060–9153` apply the same logic in two flavors:

| Incoming flag | Date situation                                | CPP action |
|---------------|------------------------------------------------|------------|
| SN=`JA`       | within regular Frist AND vorherige ≠ SN-`JA`   | `ERR_SN_INMELDEFRIST` (line 9617 / 9099), set SN→`NEIN`, status→NEW_DECLINED (line 9620) |
| SN=`JA`       | SN window already missed (`daSNFristDatum > daGj_ende`) | `ERR_FRIST_SN` (line 9644 / 9122), status→NEW_DECLINED (line 9663) |
| SN=`JA`       | inside SN window, outside regular Frist        | accepted as Selbstnachweis |
| SN=`NEIN`     | outside regular Frist                          | `ERR_FRIST_NOSN` (line 9706, separate error) |
| SN=`NEIN`     | within regular Frist                           | accepted as regular Meldung |

The carve-out `strSelbstnachweis_vorherige != "JA"` at
`c_st_meldung.cpp:9603` / `:9086` lets a Selbstnachweis *update* a prior
Selbstnachweis even within the regular Frist — continuity rule.

The Java `SteuerMeldungFristenValidators.java` (lines 35–58 for
`ERR_SN_INMELDEFRIST`, 69–92 for `ERR_FRIST_SN`) encodes the same two
gates with the inequalities re-expressed forward from `gjEnde`:
`lastChance = gjEnde + 7M` and `snEnde = lastChance + 12M`. The two
formulations are equivalent. The continuation carve-out via
`previousSteuerMeldung.getSelbstnachweis() == TRUE` is the analog of
`strSelbstnachweis_vorherige`. Frist behavior matches.

### Verdict on the Java in-Lieferung key

`LieferungStmKey` was made
`(isin, jahresdatenmeldung, gjEnde, selbstnachweis)` in commit
`e1cade6e`. The CPP existence predicate at `c_st_meldung.cpp:7840–7844`
also partitions on exactly those four fields (the SN dimension as a
two-bucket fold, treating NULL as NEIN). **The Java in-Lieferung key
matches the legacy CPP rule. No change needed on the key itself.**

The boundary case worth confirming: CPP folds `selbstnachweis IS NULL`
into the same bucket as `'NEIN'`. The Java key uses `boolean
selbstnachweis` (Javadoc states "When the source Meldung has no
Selbstnachweis flag, `false` is used"), so null and false map to the
same bucket — consistent with CPP.

### Divergence — Java existence check is missing one dimension

`SteuerMeldungStatusValidationService.findExistingMeldungStmIdByGjEndeAndJahresMeldung(...)`
at `:358–377` filters by `(gjEnde, jahresdatenmeldung)` only — it does
**not** filter by `selbstnachweis`. CPP does
(`c_st_meldung.cpp:7841–7844`). Consequence: when the user submits a
new SN-`JA` Jahresmeldung for `(ISIN, GJ_Ende)` where the DB already
holds a SN-`NEIN` Jahresmeldung (or vice versa), Java raises
`ERR_JAHRESM_VORH` but CPP would not — that is a legitimate
Selbstnachweis arriving alongside the regular Jahresmeldung the user
filed earlier.

The same Java method also feeds the Ausschüttungsmeldung path at line
156 (`ERR_AUSSCHM_VORH`), where CPP's analogue additionally partitions
by Meldezeitraum (`c_st_meldung.cpp:7848–7851`). Java omits that as
well. Lower stakes there since `ERR_AUSSCHM_VORH` is logged as info in
CPP anyway (see above).

### Recommendation

For the immediate test-server failure: Part 1 (filter errored STMs out
of prefill in `BundleRecalculationResults` + keep the `_SN` filename
suffix) is sufficient. The Java `LieferungStmKey` is already correct.

Follow-up cleanup, separate change:

1. **`findExistingMeldungStmIdByGjEndeAndJahresMeldung`** —
   `ifas-domain-stm/.../SteuerMeldungStatusValidationService.java:358`.
   Add a third filter matching the CPP SN bucket:

   ```java
   .filter(meldung -> {
       Boolean existingSn = meldung.getSelbstnachweis();
       boolean existingIsJa = Boolean.TRUE.equals(existingSn);
       boolean incomingIsJa = Boolean.TRUE.equals(incomingSelbstnachweis);
       return existingIsJa == incomingIsJa;
   })
   ```

   The method signature has to take the incoming `selbstnachweis`
   value; both call sites (`:146` for JM, the AM site referenced at
   `:156`) already have the `SteuerMeldung` in hand and can pass it
   through. Rename the method to
   `findExistingMeldungStmIdByGjEndeJahresMeldungAndSelbstnachweis` —
   or, since the new predicate is just "all four fields of the legacy
   coexistence key", consider folding it into a lookup keyed by
   `LieferungStmKey`-equivalent that already exists in the persistence
   layer.

2. **Optional, lower priority** — extend the Ausschüttungsmeldung
   branch (`:156`) to also partition by `meldungszeitraum_beginn` /
   `meldungszeitraum_ende`, matching `c_st_meldung.cpp:7848–7851`.
   Without this, two AMs for the same `(ISIN, gj_ende, SN)` but
   different Meldezeiträume can incorrectly trigger
   `ERR_AUSSCHM_VORH` (though as info-level it's mostly noise).

3. **`InLieferungAcceptedState.acceptedNewKeys`** — no change needed.
   The current `LieferungStmKey` already encodes the right uniqueness
   for in-Lieferung deduplication.

Neither change is required for the test server unblock; both are
correctness follow-ups that should be filed as separate tickets once
Part 1 ships.

### Coexistence matrix

Row notation: `JM` = Jahresmeldung (`jahresdatenmeldung='JA'`), `AM` =
Ausschüttungsmeldung (`jahresdatenmeldung='NEIN'`), `(N)` = `selbstnachweis='NEIN'`
or `NULL`, `(J)` = `selbstnachweis='JA'`. All pairs are evaluated for the
**same `(ISIN, gj_ende)`**. Where it matters, AM Meldezeitraum is called
out separately. "File" = two rows inside one Lieferung CSV; "DB" = new
row vs. an already-persisted active row (`guelt_bis is null`). For CPP
these two columns are identical because each row is committed before the
next is checked; for Java the in-file check is `LieferungStmKey` and the
DB check is `findExistingMeldungStmIdByGjEndeAndJahresMeldung`.

| # | Row A | Row B | CPP — coexist? | Java file (`LieferungStmKey`) | Java DB (`findExisting…`) | CPP outcome on collision | CPP citation |
|---|-------|-------|----------------|-------------------------------|---------------------------|---------------------------|--------------|
| 1 | JM(N) | JM(N) | **No** | No (collide) | No (collide) | `ERR_JAHRESM_VORH` → `NEW_DECLINED` | `c_st_meldung.cpp:7840, 7885` |
| 2 | JM(N) | JM(J) | **Yes** — distinct SN bucket | Yes (4-tuple key differs) | **No (false collision)** — Java ignores SN | second row would be wrongly declined as `ERR_JAHRESM_VORH` in Java DB path | CPP `:7841–7844`; Java divergence `SteuerMeldungStatusValidationService.java:369–376` |
| 3 | JM(J) | JM(J) | **No** | No (collide) | No (collide) | `ERR_JAHRESM_VORH` → `NEW_DECLINED` | `c_st_meldung.cpp:7840, 7885` |
| 4 | JM(N) | AM(N) | **Yes** | Yes | Yes | n/a (different `jahresdatenmeldung`) | `c_st_meldung.cpp:7840` |
| 5 | JM(N) | AM(J) | **Yes** | Yes | Yes | n/a | `c_st_meldung.cpp:7840` |
| 6 | JM(J) | AM(N) | **Yes** | Yes | Yes | n/a | `c_st_meldung.cpp:7840` |
| 7 | JM(J) | AM(J) | **Yes** | Yes | Yes | n/a | `c_st_meldung.cpp:7840` |
| 8 | AM(N) | AM(N), same Meldezeitraum | **No** | No (collide) | No (collide) | `ERR_AUSSCHM_VORH` logged as **info only** (no decline) | `c_st_meldung.cpp:7848–7851, 7900–7913` |
| 9 | AM(N) | AM(N), different Meldezeitraum | **Yes** | n/a — Java key has no Meldezeitraum | **No (false collision)** — Java ignores Meldezeitraum | second row would log spurious `ERR_AUSSCHM_VORH` info | CPP `:7848–7851`; Java divergence at `:369–376` and at the AM call site |
| 10 | AM(N) | AM(J), same Meldezeitraum | **Yes** — distinct SN bucket | Yes | **No (false collision)** — Java ignores SN | second row logs spurious `ERR_AUSSCHM_VORH` info | CPP `:7841–7844`; Java divergence at `:369–376` |
| 11 | AM(N) | AM(J), different Meldezeitraum | **Yes** | Yes | **No (false collision)** | as #10 | as #10 |
| 12 | AM(J) | AM(J), same Meldezeitraum | **No** | No (collide) | No (collide) | `ERR_AUSSCHM_VORH` info | `c_st_meldung.cpp:7848–7851, 7900–7913` |
| 13 | AM(J) | AM(J), different Meldezeitraum | **Yes** | n/a (no Meldezeitraum) | **No (false collision)** | as #9 | as #9 |

**Reading the matrix:**

- The "CPP — coexist?" column is the ground truth from
  `c_st_meldung.cpp:7836–7854`. Rows 2, 5–7, 9–11, 13 are scenarios the
  legacy app accepts; the Java DB path is stricter than CPP in 5 of
  those rows (2, 9, 10, 11, 13).
- The Java in-file column is correct everywhere except rows 9 and 13,
  which Java cannot represent because `LieferungStmKey` lacks the
  Meldezeitraum dimension — but those collisions only produce info-level
  noise in CPP, so the practical impact is small.
- The Java DB column shows the divergence already noted in
  Recommendation 1 above: ignoring the SN bucket converts several
  CPP-legal scenarios into spurious `ERR_JAHRESM_VORH` / `ERR_AUSSCHM_VORH`
  signals. Row 2 is the one that actually causes a wrong decline (JM
  is hard-error, AM is info-only).

### Per-row Frist criteria

Coexistence determines whether a row passes the duplicate check. A row
also has to pass the Frist gate, which is per-row and independent of
sibling rows. Notation: `daFristDatum = Stichtag − 7 months` (default,
configurable), `daSNFristDatum = daFristDatum − 12 months`. `vorher.SN`
is the `selbstnachweis` flag of the previous Meldung in the same chain
(via `vorherige_stm_id`) — used for continuation.

| Row | Date situation | Outcome | CPP citation |
|-----|----------------|---------|--------------|
| `JM(N)` or `AM(N)` | `daFristDatum <= daGj_ende` (still inside regular Frist) | **OK** — accepted as regular Meldung | `c_st_meldung.cpp:9697–9700` |
| `JM(N)` or `AM(N)` | `daFristDatum > daGj_ende` (regular Frist missed) | `ERR_FRIST_NOSN` → `NEW_DECLINED` | `c_st_meldung.cpp:9700–9722` |
| `JM(J)` or `AM(J)` | `daFristDatum <= daGj_ende` AND `vorher.SN ≠ JA` | `ERR_SN_INMELDEFRIST` (NEW) → `NEW_DECLINED`; also fired in UPDATE-on-FINAL when `Stichtag <= 15-Dec-of-Zufluss-year` AND `vorher.SN ≠ JA` | `c_st_meldung.cpp:9598–9633` (NEW), `:9060–9110` (UPDATE-FINAL) |
| `JM(J)` or `AM(J)` | regular Frist missed AND `daSNFristDatum > daGj_ende` (SN window also missed) | `ERR_FRIST_SN` → `NEW_DECLINED` | `c_st_meldung.cpp:9636–9680` (NEW), `:9111–9152` (UPDATE-FINAL) |
| `JM(J)` or `AM(J)` | regular Frist missed AND `daSNFristDatum <= daGj_ende` (inside SN window) | **OK** — accepted as Selbstnachweis | `c_st_meldung.cpp:9681–9694` |
| `JM(J)` or `AM(J)` | `daFristDatum <= daGj_ende` AND `vorher.SN = JA` | **OK** — continuation of an earlier Selbstnachweis chain | `c_st_meldung.cpp:9603` carve-out |

Java equivalents in `SteuerMeldungFristenValidators.java`: lines 35–58
(`ERR_SN_INMELDEFRIST`), 69–92 (`ERR_FRIST_SN`). The Java
reformulation `lastChance = gjEnde + 7M` and `snEnde = lastChance + 12M`
is mathematically equivalent to CPP's `daFristDatum = Stichtag − 7M`
and `daSNFristDatum = daFristDatum − 12M` once Stichtag is fixed.

## Files in scope

### Part 1 (immediate)
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/recalc/BundleRecalculationResults.java`
  — tighten `getSteuerMeldungenForExcelPrefill` to exclude errored STMs.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/vorgabe/excel/ExcelErmittlungsvorgaben.java`
  — `_SN` suffix already applied; no further change.
- `ifas-testing/ifas-integration-tests/.../gf1-d20260724` — verify behavior
  on the actual triggering CSV.

### Part 2 (follow-up analysis, no code change yet)
- Legacy CPP under `/home/sma/dev/projects/oekb/ifas`.
- After the analysis, expected loci of change are
  `InLieferungAcceptedState.java`,
  `SteuerMeldungStatusValidationService.java`, and the related validator
  in `SteuerMeldungStatusValidators.java`. Concrete edits depend on the
  outcome of the analysis.

## Cross-references

- Earlier plan documenting the filename collision and `_SN` fix:
  `/home/sma/.claude/plans/i-got-this-throw-graceful-starfish.md`
- Earlier plan documenting the `InLieferungAcceptedState` policy options:
  `/home/sma/.claude/plans/inlieferung-jahresm-selbstnachweis-validation.md`