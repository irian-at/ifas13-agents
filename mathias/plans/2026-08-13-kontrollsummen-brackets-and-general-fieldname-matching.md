# Kontrollsummen messages: `<>` alignment + general field-name matching

## Context

Two things came out of checking the uncommitted Kontrollsummen change against the Altsystem:

1. The bracket change in the working tree is **correct** — legacy does not wrap field names in
   `<>`, only values.
2. The one remaining field-name divergence should not be fixed with a hand-written alias. The
   Ermittlungsvorgabe already carries every legacy label; `FieldNameResolver` withholds them
   because its rendering guards also govern matching. Splitting those two concerns makes field
   names match generally, with no per-field alias maintenance.

## Part 1 — the brackets are right, keep the change

Legacy catalog, `~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/c_stm_logger.cpp:390-395`:

```c
cBugMsgs.AddMsg(j++, "ERR_KONTROLL_N<0",
    "Das Ergebnis im Feld %s <%.4lf> darf nicht kleiner 0 sein");
cBugMsgs.AddMsg(j++, "ERR_KONTROLL_SN<0",
    "Die Summe der Inhalte der Meldefelder %s <%.4lf> darf nicht kleiner 0 sein");
cBugMsgs.AddMsg(j++, "ERR_KONTROLL_LSN<0",
    "Die Summe der Inhalte der Meldefelder %s <%.4lf> fuer Land %s darf nicht kleiner 0 sein");
```

`%s` is unbracketed. Confirmed three ways: all 9 `N<0` and 6 `LSN<0` call sites in
`c_st_meldung.cpp` pass bare literals; the in-repo legacy fixture
`ifas-domain/ifas-domain-stm/src/test/resources/at/oekb/ifas/domain/stm/meldung/log/error.log:21`;
and the real gf1 run `~/dev/projects/oekb/ifas13-tests/IFAS13-196/error.log`.

`ERR_KONTROLL_LSN_LT_0` was already fixed in `3c5079d00`; this brings its siblings in line.
`ERR_KONTROLL_SN_LT_0` is dead in both systems (legacy defines but never emits it — the existing
`@Deprecated` is right). `ERR_KONTROLL_1`–`_10`, `INFO_KONTROLL_1`, `INFO_KONTROLL_9` name their
fields as literal template text and already match legacy verbatim. **No further bracket changes.**

Side effect: the old bracketed pattern could never match a real legacy log line, so
`LegacyLogPatternMatcher` failed to classify legacy `Das Ergebnis im Feld ...` messages at all.
They match now. No shadowing — `ERR_REAL_VERLUSTE` (`ValidationMsgCodePattern:183`) anchors on a
different prefix and `Matcher.matches()` is a full match.

**Action:** keep both enum edits; revert the three stray blank lines in
`.../validation/calculated/CalculatedSteuerMeldungValidationService.java` (no behaviour change).

## Part 2 — general field-name matching, no alias per field

### The finding

Legacy labels `Substanzverluste_inklEA` as
`"Realisierte Verluste aus Substanz (ohne Altemissionen) inkl. Ertragsausgleich"`
(`c_st_meldung.cpp:7607`). That string is **not** legacy-specific — it is the display name in the
BMF Ermittlungsvorgabe. Verified in `docs/Testdaten Fachabteilung/BMF_ErmittlungsvorgabenV6_20251113_OFFEN.xlsx`,
whose shared strings contain the defined name, that exact label, and the legacy rule text itself:

```
'Substanzverluste_inklEA'
'Realisierte Verluste aus Substanz (ohne Altemissionen) inkl. Ertragsausgleich'
':\r\nWENN Substanzverluste_inklEA < 0\r\nDANN '
" 'Realisierte Verluste aus Substanz (ohne Altemissionen) inkl. Ertragsausgleich darf nicht kleiner 0 sein\r\n"
```

So `FieldSpec.displayName()` already holds what legacy prints, for this field and every other
Ermittlungsvorgabe field. `FieldNameResolver.resolveDisplayName` (`FieldNameResolver.java:38-53`)
just refuses to hand it over — two guards block it:

- `spec.fieldCategory() == FieldCategory.STAMMDATEN_UND_ERGAENZENDE_ANGABEN`
  (`Substanzverluste_inklEA` is `ERTRAEGE`, set at `ErtraegeFieldSpecs.java:140-141`)
- `spec.displayName().length() <= MAX_DISPLAY_NAME_LENGTH` (35; this label is 76)

Both guards are about **what we render**. Neither should constrain **what we accept as equal**.

### The change

Split rendering from matching on `FieldName`:

- `FieldName.toString()` keeps returning the restricted display name — **emitted message text
  stays exactly as it is today**, no return-file or log churn.
- Add `FieldName.matchableNames()` returning every known form: defined name, the *unrestricted*
  Ermittlungsvorgabe display name, the `FALLBACK_DISPLAY_NAMES` entry, and `FieldNameAliases`
  entries. `FieldNameResolver` supplies these alongside the existing `toDisplayName` operator
  (extend `FieldName.resolving(...)`, which today takes only a `UnaryOperator<String>`).
- `ValidationMsgMatcher.compareFieldNameArgument` (`ValidationMsgMatcher.java:420-436`) compares
  the legacy string against `matchableNames()` instead of the current fixed three-step
  display → defined → alias chain.

Net effect: any validator that passes a resolved `FieldName` gets legacy-label matching for
**every** Ermittlungsvorgabe field for free. `FieldNameAliases` stops growing — it stays only for
names that are genuinely not derivable, i.e. the structural START-record fields
(`Record-Date`, `Ausschuettungstag`, `Geschaeftsjahr-Beginn`, `Selbstnachweis`, `Anzahl Anteile`,
`Meldedatum`, …), which I confirmed are absent from the field metadata.

### Then route the Kontrollsummen validator through it

`CalculatedSteuerMeldungValidators.errKontrollNLt0` (`:364`) passes a raw `String`, so the
argument never reaches the field-name path at all. Pass a resolved `FieldName`, as
`SteuerMeldungDomainValidators.java:284` and `:1054` already do:

```java
ValidationMsg.of(
        SteuerMeldungPositions.positionOf(steuerMeldung),
        ValidationMsgCode.ERR_KONTROLL_N_LT_0,
        ValidationMsg.Severity.ERROR,
        new FieldNameResolver(steuerMeldung.getErmittlungsvorgabe()).of(fieldName),
        value
)
```

With Part 2 in place this needs **no `FieldNameAliases` entry** — `Substanzverluste_inklEA`
matches via its Ermittlungsvorgabe display name. The match lands as `MatchQuality.EXACT`
(an alias/name hit returns `ArgumentMatchResult.MATCH`), not `DIVERGENT_ARGS`;
`DivergentArgsCodes` is the weaker per-index allowlist and is not the right tool here.

Leave `errKontrollLsnLt0` alone — its argument is a joined expression
(`buildFieldNamesDescription`, `:498-500`), and legacy passes byte-identical joined strings that
already match as plain strings. `INFO_AUSLQST_JA` (`:455-468`) also needs nothing: legacy passes
the same four technical names (`c_st_meldung.cpp:7647,7671,7695,7719`).

### Optional follow-up: ASCII normalization

Legacy message text is pure ASCII (`gemaess`, `ue`, `sz`). Folding umlauts/ß and collapsing
hyphens vs spaces inside the comparison would mechanically retire roughly a third of the current
alias entries (`Ausschüttungstag`, `Geschäftsjahr Beginn`, `Record Date`/`RecordDate`,
`Öffentliches Angebot`). Worth doing as a separate step once the matching split is in.

## Files to touch

| File | Change |
|---|---|
| `.../stm/validation/FieldName.java` | add `matchableNames()`; widen `resolving(...)` |
| `.../stm/validation/FieldNameResolver.java` | supply unrestricted display name + fallback + aliases as match candidates; leave `resolveDisplayName` rendering rules untouched |
| `.../stm/validation/delta/ValidationMsgMatcher.java` | `compareFieldNameArgument` iterates `matchableNames()` |
| `.../stm/validation/calculated/CalculatedSteuerMeldungValidators.java` | `errKontrollNLt0` passes a resolved `FieldName` |
| `.../validation/calculated/CalculatedSteuerMeldungValidationService.java` | revert stray blank lines |
| `.../validation/calculated/CalculatedSteuerMeldungValidatorsTest.java` | `:1286-1289` asserts a raw `String`; use `FieldName.of(...)` (`@EqualsAndHashCode(of = "definedName")`, so a plain `of(...)` compares equal). `formatMessage` assertions at `:1290`, `:1310-1316` keep passing |

Investigated and **not** needed: `STEUER_FIELDS.txtBez` (`SteuerField.java:52`) carries the same
labels, but reaching it would mean extending `SteuerFieldInfo` (no `getTxtBez()` today) and
pulling persistence into the matcher. The Ermittlungsvorgabe already has the data.

## Verification

```bash
mvn test -Pno-proxy -pl ifas-domain/ifas-domain-stm \
  -Dtest='LegacyLogParserTest+LegacyLogPatternMatcherTest+CalculatedSteuerMeldungValidatorsTest+ValidationMsgMatcherTest+FieldNameResolverTest'
```

- `LegacyLogParserTest:288` already gates the pattern against the real legacy fixture
  (`.contains("Das Ergebnis im Feld Realisierte Verluste aus Substanz")`).
- Add a `ValidationMsgMatcherTest` case: a legacy `Das Ergebnis im Feld Realisierte Verluste aus
  Substanz (ohne Altemissionen) inkl. Ertragsausgleich <-3.0000> ...` line matches a new
  `ERR_KONTROLL_N_LT_0` on `Substanzverluste_inklEA` as `EXACT`, with **no** alias entry present.
- Assert emitted text is unchanged: `getFormattedMessage()` still renders
  `Das Ergebnis im Feld Substanzverluste_inklEA <-3.0000> darf nicht kleiner 0 sein`.

Tooling note: this box has no `unzip`; inspect the Ermittlungsvorgabe workbooks with
`python3 -c "import zipfile; ..."`.

## Out of scope — recorded, not fixed

- **Two legacy fields never checked.** `ImmoInvF_Gewinnvortrag_ImmoInvF_Bewirtschaftungsgewinne_inklEA`
  (`c_st_meldung.cpp:6968`, version 3/4) and `ImmoInvF_Gewinnvortrag_ImmoInvF_WPundLiquiditaetsgewinne_inklEA`
  (`:7503`) appear nowhere in the Java codebase. Adding them is a behaviour change needing its own
  version-gate analysis.
- **gf1 deviations remain.** The 7 `[+] NUR IM NEUSYSTEM` `N_LT_0` entries in
  `IFAS13-196/error#diff.txt` are not resolved here — legacy's gf1 `error.log` contains zero
  `Das Ergebnis im Feld` lines, so the new system raises errors legacy never did.
- **Tests are tautological.** `CalculatedSteuerMeldungValidatorsTest:1291,1611` assert
  `getFormattedMessage()` against `ValidationMsgCode.<CODE>.formatMessage(<same args>)`, so they
  pass under either bracket form. Nothing enforces name/arity parity between `ValidationMsgCode`
  and `ValidationMsgCodePattern`.
