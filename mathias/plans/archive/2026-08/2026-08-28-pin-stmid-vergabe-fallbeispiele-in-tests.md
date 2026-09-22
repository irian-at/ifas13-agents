# Pin the four Fallbeispiele from `StmIdVergabe.md` in tests

## Context

`docs/Entwicklung/StmIdVergabe.md` transcribes a printed OeKB sheet showing, in four
`Fallbeispiele`, which STM-ID a delivery gets back in the Antwortfile and what display state
results. `docs/Entwicklung/Statusuebergaenge.deck.html` explains the mechanism behind it. Both
are prose — nothing in the build enforces that the system still behaves that way.

We want the sheet pinned by tests: every documented delivery replayed against a real H2
database in **write mode**, asserting both the STATUS record written to the generated return
file (`STM_ID` / `STM_ID_REF`) and the resulting DB state (`status`, `guelt_bis`,
`vorherige_stm_id`, `vorherige_final_stm_id`).

This closes a real coverage gap. `SteuerlicheErmittlungDomainService#processLieferung` — the
class both docs name as the home of the transitions — has **no end-to-end test against a
database**. The recalc harness (`JiraIssueRecalculationTest`, `GrossfileRecalculationTest`)
cannot serve: `RecalculationDomainService#doRecalc` hard-codes `persistResult = false`
(`RecalculationDomainService.java:477`), so nothing survives from one delivery to the next.
`SteuerMeldungPersistenceServiceTest` has a real chain but bypasses the CSV and Antwortfile
layers entirely.

Writing the tests already surfaced two deviations between the docs and the code — see
**Deviations found** below.

## Harness

Entry point: `SteuerlicheErmittlungDomainService#processLieferung(Resource, …)`
(`SteuerlicheErmittlungDomainService.java:41`) with `SteuerlicheErmittlungRecalcOptions.DEFAULT`
(`recalculationMode = false`, `persistResult = true`). One call per delivery.

Not `CalculationDomainService#calculateBundle`: it resolves its input via
`getOptionalSingleResource(STM_MELDUNG_CSV_FILE)` and throws otherwise, while
`SteuerMeldungBundles.determineFileTypeFromFilePath` classifies anything ending in
`_confirm.csv` / `_delete.csv` as `CONFIRM_CSV_FILE` / `DELETE_CSV_FILE`. A confirm or delete
delivery can never reach it. Going one level down avoids depending on that quirk, and
`processLieferung` handles all four input statuses uniformly.

New test class:
`ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/ermittlung/StmIdVergabeTest.java`

```java
@RegisterExtension
static Extension extension = TEST_WITH_H2_ONLY;
```

`MultiDatabaseExtension` truncates **after each test method**, so all deliveries of one chain
run inside one `@TestTemplate` method against one persistent H2 database, and each chain starts
from a clean slate. That also keeps `ERR_JAHRESM_VORH` from firing on the second chain's `NEW`.

**Deterministic IDs.** `StmIdProvider` is a `@FunctionalInterface` passed as a parameter, so the
sheet's literal IDs are available without touching Spring:

```java
AtomicLong nextStmId = new AtomicLong(11114);
StmIdProvider stmIdProvider = stm -> nextStmId.getAndIncrement();
```

`getNextStmId` is only reached from `finishProcessingOpen`, and `finishProcessing` short-circuits
on a failed status before that — so `CONFIRMED`, `DELETE` and every ERROR branch consume no ID,
exactly as the sheet shows.

**Seeding.** `basedataCreator.createBasedata()` plus the fund-specific prologue lifted from
`SteuerMeldungPersistenceServiceTest:674-687` — `KagTestdataCreator`, `HdpTestdataCreator`,
`LieferantTestdataCreator`, `WknHistTestdataCreator#createIsinWknHist(isin, numWfsKu)`,
`InvTestdataCreator#createSimpleInv(...)`, and `GeschaeftsjahrTestdataCreator` (finalize writes
the Geschäftsjahr row).

**Assertions**, two per delivery:

1. *Return file.* Write it with the same call production uses —
   `SteuerMeldungen.writeSteuerMeldungenToCsv(out, ergebnis.returnSteuerMeldungen(), stichtag)`,
   which is what `CalculationOutputs.java:112` invokes — then assert the `STATUS` line verbatim.
   The writer always emits all four columns, so a `NEW` yields `STATUS;OPEN;11114;;` and an
   accepted `UPDATE` yields `STATUS;OPEN;11115;11114;`.
2. *DB state.* `SteuerMeldungEntityAssertions.assertThat(row)` with
   `.hasStatus(...)`, `.hasGueltBis(...)` / `.hasNoGueltBis()`, `.hasVorherigeStm(...)`,
   `.hasVorherigeFinalStm(...)` — the same vocabulary
   `SteuerMeldungPersistenceServiceTest#givenStmTimeline_...` already uses. `guelt_bis is null`
   is the sheet's *offen*; a set `guelt_bis` is *beendet*.

## Fixture

One checked-in template:
`ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/stm/ermittlung/stmidvergabe/jahresmeldung.csv`

Start from the T01 Meldefile
(`ifas-test-data/.../testdata/stm/T01/T01_V5_AT0000A0LRA1_107-d20250414.csv`, 27 lines, ISIN
`AT0000A0LRA1`, GJ 2023-11-01..2024-10-31, BMF V5) — known-good, its legacy return is
`STATUS;OPEN;636905`. Trim the `D`/country-vector block down to the minimum that still yields
`OPEN`, verifying by running the Fall-1 test; `CsvIfasStructureValidationRules` requires
`START, STATUS, E, END` for `NEW`/`UPDATE`, and `EA` must precede any `D`/`Z`/`ZA`/`AS`.

Stichtag `2025-04-14` for every step: the Meldefrist is `gjEnde + 7M = 2025-05-31`, and the
Korrekturfrist after a confirm is 15 Dec of the Zufluss year (2025-12-15), so no step trips a
Fristenprüfung.

The 27 individual deliveries are derived in-test from that one template. A private nested
helper rewrites the `STATUS` record and, for `CONFIRMED` / `DELETE`, drops the data block —
`CsvIfasStructureValidationRules` allows only `START, STATUS, END` for those:

```java
StmLieferfile.of(TEMPLATE).status(NEW)                     // full payload
StmLieferfile.of(TEMPLATE).status(UPDATE, 11114L)          // full payload
StmLieferfile.of(TEMPLATE).headerOnly(CONFIRMED, 11114L)   // START, STATUS, END
StmLieferfile.of(TEMPLATE).headerOnly(DELETE, 11115L)
```

It returns a `ByteArrayResource` with `getFilename()` overridden (mandatory —
`CsvIfasFilenameValidator` asserts non-null and the filename must match `^[A-Za-z0-9._-]+$`),
encoded with `IfasCharsets.IFAS_CSV_CHARSET`. Same shape as the existing private helper in
`SteuerMeldungLieferungSeverityDowngradeTest:90`. Keep it nested in the test class; extract it
only when a second test needs it.

## Test methods

Ten chains, one `@TestTemplate` each, with the shared prefixes (Fall 1 steps 1-3, Fall 2 steps
1-2) as private helpers reused by their branches. Expected return-STATUS lines and the row
state that must hold afterwards:

**Fall 1** — `givenNewConfirmUpdate_whenDelivered_thenFinalStaysDisplayed`
| # | delivery | return STATUS | rows afterwards |
|---|---|---|---|
| 1 | `NEW` | `STATUS;OPEN;11114;;` | 11114 OPE, offen, no vorherige |
| 2 | `CONFIRMED;11114` | `STATUS;FINAL;11114;;` | 11114 FIN, offen, zufluss = Stichtag |
| 3 | `UPDATE;11114` | `STATUS;OPEN;11115;11114;` | 11115 OPE offen, vorherigeStm/Final = 11114; **11114 FIN still offen** |

**Fall 1.a** — prefix + `DELETE;11115` → `STATUS;DELETED;11115;;`; 11115 DED beendet, 11114 FIN offen.
**Fall 1.b** — prefix + `CONFIRMED;11115` → `STATUS;FINAL;11115;11114;`; 11115 FIN offen, **11114 beendet**.
**Fall 1.c** — prefix + `UPDATE;11115` → `STATUS;OPEN;11116;11115;`; 11116 vorherigeStm 11115 / vorherigeFinal 11114, 11115 beendet, 11114 FIN offen.

**Fall 2** — `givenNewUpdateWithoutConfirm_whenDelivered_thenPredecessorEndsImmediately`
| # | delivery | return STATUS | rows afterwards |
|---|---|---|---|
| 1 | `NEW` | `STATUS;OPEN;11114;;` | 11114 OPE offen |
| 2 | `UPDATE;11114` | `STATUS;OPEN;11115;11114;` | **11114 beendet** (`closeIfOpen` matches), 11115 OPE offen, vorherigeFinal null |

**Fall 2.a** — prefix + `UPDATE;11115` → `STATUS;OPEN;11116;11115;`; 11115 beendet.
**Fall 2.b** — prefix + `CONFIRMED;11115` → `STATUS;FINAL;11115;;` (no FINAL ancestor, ref empty).
**Fall 2.c** — prefix + `DELETE;11115` → `STATUS;DELETED;11115;;`; 11115 DED beendet.

**Fall 3** — `NEW` → `STATUS;OPEN;11114;;`; `DELETE;11114` → `STATUS;DELETED;11114;;`, 11114 DED beendet.

**Fall 4** — `givenUpdateAfterDeletedUpdate_whenDelivered_thenChainReattachesToFinal`
| # | delivery | return STATUS | rows afterwards |
|---|---|---|---|
| 1 | `NEW` | `STATUS;OPEN;11114;;` | |
| 2 | `CONFIRMED;11114` | `STATUS;FINAL;11114;;` | 11114 FIN offen |
| 3 | `UPDATE;11114` | `STATUS;OPEN;11115;11114;` | 11114 FIN offen |
| 4 | `UPDATE;11115` | `STATUS;OPEN;11116;11115;` | 11115 beendet; 11116 vorherigeFinal 11114 |
| 5 | `DELETE;11116` | `STATUS;DELETED;11116;;` | 11116 DED beendet; 11114 FIN offen |
| 6 | `UPDATE;11114` | `STATUS;OPEN;11117;11114;` | **needs the fix below**; 11117 vorherigeStm/Final = 11114 |
| 7 | `CONFIRMED;11117` | `STATUS;FINAL;11117;11114;` | 11117 FIN offen, **11114 beendet** |

**Two ERROR branches** — the ones the sheet's own semantics produce, no invented trigger:
- `givenConfirmOnAlreadyFinalMeldung_whenDelivered_thenErrorAndChainUnchanged` — Fall 1 steps 1-2,
  then `CONFIRMED;11114` again → `ERR_STATUS_NM[FINAL, CONFIRMED]` → `STATUS;ERROR;11114;;`, 11114
  unchanged (FIN, offen). `resolveErrorReferencedStmId` leaves the ref empty because the
  referenced row is `FIN`, not `OPE` — matching the sheet's bare `ERROR;11114`.
- `givenDeleteOnFinalMeldung_whenDelivered_thenErrorAndChainUnchanged` — Fall 1 steps 1-2, then
  `DELETE;11114` → `ERR_STATUS_NM[FINAL, DELETE]` → `STATUS;ERROR;11114;;`, chain unchanged.

## Deviations found

**1. Fallbeispiel 4 step 6 fails today — fix the successor scan.**

`SteuerMeldungStatusValidationService#findLatestUndeletedSuccessorStmId` (line 469) filters
successors on `status != DELETED` only. At step 6, 11115 is still status `OPE` with `guelt_bis`
set (closed at step 4). The scan finds it, `ERR_UPD_OLDM` fires as a hard `ERROR`, and the
delivery answers `ERROR;11114` instead of `OPEN;11117;11114` — the very step the sheet calls
"der Kern des Beispiels".

Legacy keys *active* off `guelt_bis is null`, not off status — the same convention
`SteuerMeldungStatusValidationService:110-127` already applies for `inputStmIsValid`. Fix:

```java
return vorherigeId != null
        && vorherigeId.equals(vorherigeStmId)
        && status != StmStatus.DELETED
        && meldung.getGueltBis() == null;   // an ended row is no longer a successor
```

This can move recalc results: `ERR_UPD_OLDM` currently fires on replays where the successor was
already ended, which is why `updOldmDiffsAsWarning` exists. `GrossfileRecalculationTest` and
`JiraIssueRecalculationTest` must be re-run; if their counts move, report the deltas rather than
silently rebaselining.

**2. ~~The deck's `DELETE_DECLINED` claim does not hold.~~ — retracted, the deck is right.**

The first draft of this plan predicted the two ERROR branches would answer `ERROR`, on the
reading that `ERR_STATUS_NM` carries no `DeclinedInfo`. Running the tests showed
`CONFIRM_DECLINED` / `DELETE_DECLINED`: `ERR_STATUS_NM` is declared with the declined flag set
(`ValidationMsgCode.java:36`), so `calculateDeclinedOrErrorStatus` takes the declined branch. The
deck's "ein Delete auf eine bereits veröffentlichte Meldung wird zu `DELETE_DECLINED`" is
accurate and needs no edit; the tests assert the `*_DECLINED` values.

The sheet drawing those boxes as plain `ERROR` is the abstraction `StmIdVergabe.md` already
records under *Abweichungen Diagramm ↔ Implementierung*, so the sheet needs no edit either. What
the sheet does pin holds in both readings: the delivered Melde-ID comes back and the chain is
untouched.

A third, smaller one needs no action: the sheet writes `FINAL;11115` for Fall 1.b without a ref,
but the code fills the ref with the nearest FINAL ancestor (11114). The sheet's shorthand simply
omits it; the test asserts the ref and carries a comment saying so.

## Files

| Action | Path |
|---|---|
| new | `ifas-testing/ifas-integration-tests/src/test/java/at/oekb/ifas/domain/stm/ermittlung/StmIdVergabeTest.java` |
| new | `.../resources/at/oekb/ifas/domain/stm/ermittlung/stmidvergabe/jahresmeldung.csv` |
| new | `.../resources/at/oekb/ifas/domain/stm/ermittlung/stmidvergabe/fondsstammdaten.yaml` |
| edit | `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/status/SteuerMeldungStatusValidationService.java` — `guelt_bis` filter in `findLatestUndeletedSuccessorStmId` |
| edit | `docs/Entwicklung/StmIdVergabe.md` — add `StmIdVergabeTest` to *Siehe auch* |
| ~~edit~~ | ~~`docs/Entwicklung/Statusuebergaenge.deck.html`~~ — not needed, see Deviation 2 |
| maybe | `GrossfileRecalculationTest` / `JiraIssueRecalculationTest` baselines, only if the fix moves them |

**Fixtures as built.** Seeding turned out cleaner as YAML than as `*TestdataCreator` calls: the
fund needs KAG / WKN_DESC / WKN_HIST / two GESCHAEFTSJAHRE / INV / KEST98 / LIEFERANT wired to
each other, which the creators cannot express as one coherent fund. `fondsstammdaten.yaml` (92
lines, derived from `SteuerMeldungDomainValidatorTest_base.yaml`) is imported on top of
`BasedataCreator`, which already supplies the reference tables and the STM metadata.

The Meldefile template trimmed down to five lines — `ERR_PFLICHT_FEHL` names
`Aufwand_Gesamtbetrag_e` and `Aufwand_Gesamtbetrag_KV_e` as the only mandatory `E` fields, and
the `EA` record turns out not to be required either:

```
START;AT0000A0LRA1;InvF;V;EUR;2023.11.01;2024.10.31;JA;;;5350000;;AT;NEIN;JA;JA;;JA;JA;6420000
STATUS;NEW
E;Aufwand_Gesamtbetrag_e;4280000,0000
E;Aufwand_Gesamtbetrag_KV_e;4280000,0000
END;AT0000A0LRA1;2025.03.10 09:12:28
```

Reuse, no new code: `SteuerMeldungEntityAssertions`, `BasedataCreator`, the `*TestdataCreator`
beans, `SteuerMeldungen#writeSteuerMeldungenToCsv`, `StmIdProvider`,
`SteuerlicheErmittlungRecalcOptions.DEFAULT`, `SimpleTransactionTemplate`.

Conventions: `@TestTemplate` (not `@Test` — plain `@Test` gets no Spring context in these
classes), given-when-then names, AssertJ only, `@Inject`, no `var`, `@NullMarked`.

## Verification

```bash
mvn -Pno-proxy -pl ifas-testing/ifas-integration-tests -am \
    test -Dtest=StmIdVergabeTest
```

Then, because the validation fix touches shared code:

```bash
mvn -Pno-proxy -pl ifas-testing/ifas-integration-tests test \
    -Dtest='JiraIssueRecalculationTest,GrossfileRecalculationTest,SteuerMeldungPersistenceServiceTest,VorherigeFinalStmIdResolverTest'
mvn -Pno-proxy -pl ifas-domain/ifas-domain-stm test -Dtest=SteuerMeldungStatusValidatorsTest
```

Full build before handing over: `mvn clean install -Pno-proxy -Pdev-build`.

Each of the 12 test methods must pass with the sheet's literal IDs — 11114 … 11117 — appearing
in the asserted return-file STATUS lines, so a failure diff reads directly against
`StmIdVergabe.md`.
