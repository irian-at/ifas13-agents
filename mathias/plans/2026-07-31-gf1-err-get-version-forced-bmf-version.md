# gf1 line 7: `ERR_GET_VERSION` missing on the test server

## Context

`gf1-d20260724.csv` line 7 is a deliberate negative test case from the Fachabteilung
(the same line also lives in `docs/Testdaten Fachabteilung/testfaelle_unit_tests_1.csv`):

```
START;LU0064321150;InvF;T;EUR;01.01.1899;31.12.2025;JA;;;2;;LU;NEIN;NEIN;NEIN;;NEIN;JA;2;549300FSVWL0VAR25025
```

Legacy emits **two** errors for it (`gf1-d20260724/error.log`):

```
ERROR! Das Datumsfeld <Geschaeftsjahr-Beginn> im Satz <START> hat den ungueltigen Wert <01.01.1899>.
ERROR! ERROR: Die Version fuer das Gj_Beginn Datum 01.01.1899 kann nicht ermittelt werden.
```

Locally both match. On the test server the second appears as `[-] NUR IM ALTSYSTEM (FEHLER)`.

**Root cause — a run-configuration difference, not a code defect.** The server job ran with
**BMF-Version = 6**, the local test with **AUTO**.

`CsvSteuerMeldungen.getErmittlungsvorgabe()`
(`ifas-domain/ifas-domain-stm/.../meldung/csv/CsvSteuerMeldungen.java:268-308`) resolves in three
tiers, `forcedBmfVersion` first:

```java
if (forcedBmfVersion != null) {
    return ermittlungsvorgabeProvider.getVorgabe(forcedBmfVersion);   // :275-277 — returns here
}
...
LocalDate gjBeginn = getFailsafeLocalDate(gjBeginnStr);                // :289
try {
    return ermittlungsvorgabeProvider.getVorgabe(gjBeginn, stichtag);  // :297  throws for 1899
} catch (Exception e) {
    addCouldNotDetermineVersionError(csvMessage, gjBeginnStr);          // :305  -> ERR_GET_VERSION
    ...
}
```

With a forced version `GJ_Beginn` is never used for version resolution, so `ERR_GET_VERSION`
**cannot** be produced. With AUTO, `DefaultErmittlungsvorgabeProvider.getApplicableBmfVersion()`
(`:69-89`) finds no row in `kurs.steuer_meldung_version` bracketing `gjBeginn = 1899-01-01`
(earliest `gj_beginn_ab` is `2010-01-01`) → `IllegalArgumentException` → caught → `ERR_GET_VERSION`.

`GrossfileRecalculationTest.java:81-86` builds `RecalculationSetting` without `.bmfVersion(...)`
→ `null` → AUTO. The web form (`stm-recalc-form.html:79-85`) defaults to AUTO but offers 4/5/6;
`parseBmfVersion` maps `""`/`AUTO` → `null` (`StmRecalcDetailPageController.java:382-387`).

Legacy has the same escape hatch: `-V` (`nUseVersion4STM > 0`,
`~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/c_st_meldung.cpp:1255-1268`) skips the version lookup
entirely. The bundled `error.log` was recorded **without** `-V`, so a forced-version run of the new
system is not comparable to it for this message class.

For gf1 nothing else changes: with stichtag `2026-07-24` only version 6 is stichtag-eligible, and
every other Meldung has `GJ_Beginn` in 2024/2025, so AUTO resolves 6 for all of them. Line 7 is the
only Meldung where forced-vs-AUTO is observable.

The other legacy error, `ERR_UNG_DATUM`, is independent — plausibility check
`CsvSteuerMeldungValidations.java:150-178` (`MIN_VALID_YEAR = 2000`), which never touches the
Ermittlungsvorgabe. That is why it still matched on the server.

## Action 1 — re-run the server job with BMF-Version = AUTO (no code change)

A job's BMF-Version is shown on the Rekalkulation list (`stm-recalc-list.html:259`) and detail page
(`stm-recalc-detail.html:249-252`) as `AUTO` or a number. Re-submit gf1 with AUTO; the line-7
`NUR IM ALTSYSTEM` entry disappears and the run matches the local baseline.

General rule for Alt/Neu grossfile comparisons: **use AUTO**, since the reference `error.log` files
were produced by legacy without `-V`. A fixed BMF-Version is for reproducing one version's
calculation, not for validation-delta comparisons.

## Action 2 — `ValidationMsgMapper` lines 30-33: fold the special case into the `switch`

File: `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/ValidationMsgMapper.java`

The branch is **not** unreachable — it executes and is what produces `ERR_GET_VERSION`. What is
obsolete is the special-casing. It sits outside the `switch` only for historical reasons:

| commit | state |
|---|---|
| `ed3e6089d` (2026-03-27) | returned `List.of(msg, msg.withSeverity(OEKBINFO))` — genuinely **two** messages, which the single-valued `switch` could not express. Hence the early return and the comment. |
| `8603f4f7c` (2026-07-02) | OEKBINFO removed → `List.of(msg)`. Comment became wrong. |
| `d60ead064` (2026-07-14) | return type collapsed `List<ValidationMsg>` → `ValidationMsg`. Last reason for the early return gone; the block stayed. |

**Change (behaviour-preserving):** delete lines 30-33 (the comment and the `if`) and add the case to
the `switch`, next to the other single-argument mappings:

```java
case COULD_NOT_DETERMINE_VERSION -> ValidationMsg.of(
        position, ERR_GET_VERSION, ValidationMsg.Severity.ERROR, csvValidationMsg.arguments()[0]);
```

Same code, same severity, same raw `arguments()[0]` (no `resolveFieldName`) — identical output.

⚠️ Must be **replaced**, not deleted: the `switch` ends in
`default -> throw new IllegalArgumentException(...)` (`:84-85`), so removing the branch without
adding the case turns every `ERR_GET_VERSION` into a crash.

## Verification

```bash
# existing coverage for the mapper: provider whose getVorgabe(LocalDate, LocalDate) throws,
# asserts ERR_GET_VERSION.formatMessage("20240615")  (CsvToValidationMsgCodeTest.java:327-373)
mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm -Dtest=CsvToValidationMsgCodeTest

# gf1 baseline must stay unchanged: error log (315, 2, 8, 3, 11, 0)
mvn test -Pno-proxy -pl ifas-testing/ifas-integration-tests -Dtest=GrossfileRecalculationTest
```

Deviation files land in `ifas-testing/ifas-integration-tests/target/grossfile-recalc/gf1-d20260724/`
(the comment at `GrossfileRecalculationTest.java:198` names the wrong path).

Server side: re-submit gf1 with AUTO and confirm the line-7 block in `error#diff-deviations.txt`
shows two exact matches and no `NUR IM ALTSYSTEM`.

## Noted while tracing — explicitly out of scope

Not part of this plan; recorded so they are not lost.

1. `DefaultErmittlungsvorgabeProvider.isApplicable()` (`:91-114`) calls
   `stmVersion.stichtagAb().isAfter(...)` unguarded, but `stichtag_ab` / `stichtag_bis` are nullable
   (`SteuerMeldungVersion.java:38-42`) and `SteuerMeldungVersionTestdata.java:12-20` creates such a
   row. The NPE is swallowed by `catch (Exception)` in `CsvSteuerMeldungen:298` and silently becomes
   `ERR_GET_VERSION` for every Meldung. Legacy coalesces null →
   `1900.01.01` / `2100.01.01` (`c_stm_version.cpp:253-268`).
2. Ambiguity: new code throws on >1 matching version (`:75-80`) → `ERR_GET_VERSION`; legacy takes the
   first hit ordered by `versions_nr` (`c_stm_version.cpp:411-428`).
3. Legacy `return -1`s out of `ProcessZeile` after `ERR_GET_VERSION`
   (`c_st_meldung.cpp:1283-1290`), skipping all START field assignment and `CheckStartRow()`. The new
   system falls back to `getFallbackVorgabe(stichtag)` and runs every validator — possibly part of
   gf1's `onlyInNewError = 11`.
4. `.gitignore:19` is `*.zip`, so the working-tree `gf1-d20260724.zip` is untracked and invisible to
   `git status` while the tracked fixture is now `gf1-d20260724.zip.bak`. The untracked one contains
   0 `LAENDER` entities, the committed one 238 (added in `e10deae8d`). Masked locally by
   `basedataCreator.createBasedata()`.
