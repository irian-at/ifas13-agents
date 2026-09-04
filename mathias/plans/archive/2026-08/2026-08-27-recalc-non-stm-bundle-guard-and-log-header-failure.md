# Recalc: guard non-STM bundles, and fail legibly on an unreadable log header

## Context

A recalc job failed on 10.08.2026 with:

```
java.lang.NullPointerException: processingDate is marked non-null but is null
  at ...meldung.log.LegacyLogFile$LegacyLogFileBuilder.processingDate(LegacyLogFile.java:28)
  at ...meldung.log.LegacyLogParser.parseLog(LegacyLogParser.java:71)
  at ...stm.recalc.RecalculationDomainService.recalculateBundle(RecalculationDomainService.java:267)
```

The input was `20260703_175615_pwc_20260703_2717.isin.zip` — an **ISIN-Anforderungsliste bundle**, not
an STM delivery.

### How it reached the STM recalc

1. **03.07.2026** — bundle uploaded. The routing gate did not exist yet: `60bd98c31` ("fix(domain):
   prevent STM bundle recalculation for ISIN list files") landed 08.07, proper routing to
   `IsinAnforderungDiffJobSubmissionService` in `ca5fb3f4c` on 09.07. Nothing objected, so it became
   an `StmRecalcJob`.
2. **10.08.2026** — that job was repeated. `ParallelbetriebJobSubmissionService.repeatRecalculation`
   (and `repeatRecalculationBatch`) call `createStmRecalcJob(…, existingJob.getInputBundleFile(),
   existingJob.getInputFilename())` **directly**, bypassing `submitStmRecalcJobFromSingleResource`
   and therefore the peek. `resetForRetry` has the same property — it flips a FAILED job back to
   PENDING in place.
3. `recalculateBundle` accepted the bundle. Every entry classifies as a legitimate STM input:

   | entry | classified as |
   |---|---|
   | `pwc_20260703_2717.isin` | `ISIN_ANFORDERUNGSLISTE_FILE` |
   | `pwc_20260703_2717_EStB.csv` | `UNSPECIFIED_CSV_FILE` → content-sniffed as `STM_MELDUNG_CSV_FILE` |
   | `pwc_20260703_2717_EStB_erweitert.csv` | `ESTB_EXTENDED_FILE` |
   | `pwc_20260703_2717_error.log` | `ERROR_LOG_FILE` |
   | `pwc_20260703_2717_info.log` | `INFO_LOG_FILE` |

   The EStB *output report* starts `START;FR001400XCV3;InvF;T;EUR;…` and carries a `STATUS;FINAL;…`
   line, so it sniffs as a Meldefile. A full calculation ran against it.
4. It died at `RecalculationDomainService.java:266-268`, parsing the error log — which is written in
   the **other** legacy dialect.

### The two legacy log dialects

`SteuerMeldungBundles.determineFileTypeFromFilePath:673` maps anything ending in `error.log` to
`ERROR_LOG_FILE`. Two different legacy programs write files matching that:

| | STM logger (`c_stm_logger.cpp:503`) | ISIN/EStB (`m_st_meldung.cpp:989`) |
|---|---|---|
| filename | `error.log`, `info.log` | `<base>_error.log`, `<base>_info.log` |
| source line | `Meldefile           : …` | `- ISIN-Inputdatei         \| …` |
| timestamp | `Verarbeitungsbeginn : …` | `- Zeitpunkt               \| …` |
| provider | `Lieferant           : …` | *(none)* |
| message | `ERROR!` / `ACHTUNG!` | `ERROR \|` / `INFO \|` |

`LegacyLogParser.parseHeader:105-137` seeds `processingDate = null` and only assigns it from a
`Verarbeitungsbeginn` line in the first 10 lines. The ISIN dialect has none, so the value stays null
and the Lombok `@NonNull` check on the builder setter fires.

### What is *not* broken

- **The routing gate works.** `submitStmRecalcJobFromSingleResource:313-320` peeks inside the zip via
  `SteuerMeldungBundles.countNumberOfRecalculationSuitableFiles`, and `:362-370` sends any bundle with
  `isinAnforderungslisteFilesCount > 0` to the ISIN diff — deliberately ahead of the STM branch,
  *"ignore CSV files in same bundle"*. Verified: the peek and `submitSingleZipRecalculation` at
  `93854276b` (the commit at 10.08) are byte-identical to master. The gate was live; repeat re-enters
  behind it.
- **The dialects are correctly served by two parsers.** `IsinAnforderungDiffLegacyLogs` reads the ISIN
  grammar and `IsinAnforderungDiffOutputs.writeLogDeltaReports:215-224` diffs *both* its error and
  info logs into `error#diff.txt` / `info#diff.txt`. It recognises `- Zeitpunkt` at
  `IsinAnforderungDiffLegacyLogs.java:102` purely in order to skip it — the ISIN delta report has no
  metadata block at all.

So the overlap is exactly one thing: a single `BundleFileType` covering two grammars, with the
choice of parser decided by which service picked the bundle up.

---

## Change 1 — reject non-STM bundles in `recalculateBundle`

**Where.** Top of `RecalculationDomainService.recalculateBundle` (`:86-93`), before `importTestdata`.
That is the one point every route passes through: REST upload, `repeatRecalculation`,
`repeatRecalculationBatch`, `resetForRetry`, and the `quick-recalc` folder in
`QuickRecalculationTest`. Guarding the submission paths individually would leave whichever one is
added next uncovered.

**What it keys on.** Positive evidence of the *other* kind:

```
inputBundle.contains(ISIN_ANFORDERUNGSLISTE_FILE) || inputBundle.contains(ESTB_EXTENDED_FILE)
```

`SteuerMeldungBundle.contains(BundleFileType)` already exists (`:116`).

The obvious alternative — *"reject a bundle with no STM-recalc-suitable file"* — **does not catch this
bundle**. `pwc_20260703_2717_EStB.csv` sniffs as `STM_MELDUNG_CSV_FILE`, which
`BundleFileType.isStmRecalculationSuitable()` accepts. By that test the bundle is well-formed. Only
the presence of the ISIN artifacts distinguishes it, which is the same rule the front door already
applies.

**What it raises.** `IllegalArgumentException` per `java-conventions.md` (invalid input), naming the
bundle and the file types found — so the message says *what kind of bundle this is*, not merely that
something was rejected.

---

## Change 2 — `LegacyLogParser` fails with a legible exception instead of leaking an NPE

The parser must never let a raw Lombok null check escape. A header it cannot read is invalid input
and fails the job — deliberately, since a malformed STM log does not occur in practice (they all come
straight from legacy) and tolerating an impossible case is wasted surface.

**There are two triggers, and only one of them involves parsing.** A guard around the parse call
alone would not have prevented the 10.08 stack trace:

| # | Trigger | Today | Fixed by |
|---|---|---|---|
| 1 | `Verarbeitungsbeginn` line **absent** from the first 10 lines | `parseLocalDateTime` is never called; `processingDate` stays null from `parseHeader:107` → **NPE at the builder** | an explicit check *after* the header loop |
| 2 | line present, value **unparsable** | `CsvTypeConversions.parseLocalDateTime:59` throws `IllegalArgumentException: Unsupported date-time format: <value>` — names the value but not the file or the field | wrapping the call at `parseHeader:125` (the `// todo - what if parsing fails?` at `:124`) |

Trigger 1 is the one that actually fired. A line present but **empty** (`Verarbeitungsbeginn :`)
behaves as absent — `HEADER_VERARBEITUNGSBEGINN_PATTERN`'s `(.+)` requires at least one character, so
the line does not match at all — and is covered by the same check.

**`provider` is the twin.** No `Lieferant` line → the identical raw Lombok NPE from `.provider(…)`
one builder call later. It never fires for a genuine STM log, which always carries `Lieferant`, but
the post-loop check covers it at no extra cost and makes "no raw NPE escapes this parser" true rather
than nearly true.

**Both raise `IllegalArgumentException`**, consistent with `java-conventions.md` (invalid input) and
with `LegacyLogParser.java:49` / `:61`, which already throw it for a non-existent and an empty log.
Each message names the file, the field, and — for trigger 2 — the offending raw value, chained to the
original cause. That is the whole point of the change: the difference between *"processingDate is
marked non-null but is null"* and *"no 'Verarbeitungsbeginn' header found in the first 10 lines of
pwc_20260703_2717_error.log"* is the difference between a two-hour and a five-minute diagnosis.

**Explicitly not in scope.**

- *Making `processingDate` nullable.* Reverses to a hard failure by decision; `LegacyLogFile` is
  untouched.
- *Degrading to an `ABWEICHUNG` in the delta report.* `ValidationDeltaReportWriter:69-92` is already
  null-safe on all three legacy metadata fields, so the report layer could have absorbed it — but the
  job now fails before reaching it. `ValidationDeltaCalculator` is untouched.
- *Teaching `LegacyLogParser` the ISIN dialect.* With Change 1 in place the STM parser never sees it,
  and `IsinAnforderungDiffLegacyLogs` already reads it properly.

---

## Files to change

| File | Change |
|---|---|
| `ifas-domain-stm/.../stm/recalc/RecalculationDomainService.java` | Guard at the head of `recalculateBundle` (`:86-93`) rejecting bundles that carry `ISIN_ANFORDERUNGSLISTE_FILE` or `ESTB_EXTENDED_FILE` |
| `ifas-domain-stm/.../stm/meldung/log/LegacyLogParser.java` | `parseHeader` (`:105-137`) — wrap the `parseLocalDateTime` call at `:125`, and add a post-loop check that `processingDate` and `provider` were found; both throw `IllegalArgumentException` naming the file and field. Remove the `// todo` at `:124` |

Deliberately **not** changed: `LegacyLogFile`, `ValidationDeltaCalculator`,
`ValidationDeltaReportWriter`, `IsinAnforderungDiffLegacyLogs`, and the four submission entry points
in `ParallelbetriebJobSubmissionService` — Change 1 covers them all from one place.

## Verification

1. **`LegacyLogParserTest:180-200` changes type.** It currently asserts
   `.isInstanceOf(NullPointerException.class)` with the Lombok message text for a header missing
   `Verarbeitungsbeginn`. It becomes `IllegalArgumentException` with a message naming the file and
   field. Check nothing catches `NullPointerException` from this path on purpose before flipping it.
2. **New parser case** — header present, value unparsable (e.g. `2025.13.45 99:99`):
   `IllegalArgumentException` carrying the raw value, chained to the `CsvTypeConversions` cause.
3. **New parser case** — header present, value empty (`Verarbeitungsbeginn :`): same exception as the
   absent case.
4. **Guard test** — a bundle containing an `.isin` entry through `recalculateBundle` is rejected with
   a message naming the bundle kind. The zip in
   `ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/recalc/issues/quick-recalc/` is a
   ready-made fixture; move it somewhere permanent rather than leaving it in the scratch folder.
5. **Regression baselines unchanged** — `GrossfileRecalculationTest` (8 datasets),
   `JiraIssueRecalculationTest`, `RecalculationDomainServiceTest`. None of their bundles carries an
   `.isin` or `_EStB_erweitert.csv`, and all their logs have a well-formed header, so both changes
   must be inert for them.
6. **Build** — `mvn clean install -Pno-proxy -pl ifas-domain/ifas-domain-stm -am`, then the recalc
   integration tests.

## Open points to settle before coding

1. **Multi-bundle blast radius — unresolved.** `StmRecalcJobExecutionService:129-180` expands one
   input into N bundles and loops *inside* a single `filestore().store(...)`, with
   `executeRecalculation:152` catching and rethrowing. So either failure — the guard on bundle 37 of
   50, or an unreadable log on bundle 37 — discards the 36 that already succeeded. That is today's
   behaviour with a better message, not an improvement on it. Running the guard over all bundles
   *before* the loop rejects cleanly and wastes nothing; skipping per bundle keeps the other 49.
   Applies to both changes.
2. **The 03.07 row is still a dead end.** After the guard it fails cleanly instead of crashing, but
   still yields nothing. Getting a real ISIN diff out of it means re-submitting the stored zip
   through the ISIN path. Unknown how many pre-08.07 rows in `infra.stm_recalc_jobs` are in the same
   state — worth counting, since Ausschüttung and Preis routing landed in the same window and the
   class is "job whose stored input would classify differently today", not just ISIN.
3. **Why the NPE was pinned.** `LegacyLogParserTest:180-200` is the only written-down statement that
   this should be fatal. Worth a look at whether that was a considered decision or characterisation
   of what the code happened to do — it stays fatal either way, but the reason matters for the
   message.

## Note: the guarded field was never load-bearing

`processingDate`'s only production consumer is `ValidationDeltaCalculator.compareMetadata:118-120`,
which compares legacy's processing timestamp against `origination.getVerarbeitungsbeginn()` — when
the *recalc* ran. Those differ by construction, so `dateMatches` is false in every recalc and
`allMatch` with it. The check that kills the job guards a report line that prints `ABWEICHUNG`
unconditionally. The ISIN parser takes the opposite stance on the same value and discards it
outright. This is an argument about *which* exception, not about whether to have one — but it is
worth knowing that nothing downstream depends on the value being present.
