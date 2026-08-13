# Count new messages reused as the match for several legacy messages

## Context

The delta report cannot see a multiplicity difference: `legacy 231 / new 6` and `legacy 231 / new 231` give
byte-identical counters. That is why the `ERR_UNG_LAND` 26→3 collapse and the `ERR_KENNUNG_DBA` 231-vs-6 gap
were invisible to all eight grossfile baselines and were found by reading a log by eye.

The mechanism is in the pairing. `ValidationDeltaCalculator.compareValidationMsgs:315` iterates **legacy**
messages; `findBestMatch:427-451` scans the whole `newErrors` list and never excludes an already-matched
entry; and `ValidationMsgMatcher.hasCompatibleLineScope:78-85` requires only that the legacy line fall
*somewhere inside the Meldung's span*, equal lines being a mere preference. So one new message can be the
match partner for arbitrarily many legacy messages, and nothing records that it happened.

This step adds that record — the number of matches that reused a new message already claimed by an earlier
legacy message. It is pure instrumentation: no counter, baseline or report figure may change. The number then
decides whether to tighten `hasCompatibleLineScope` to require equal lines, or to surface the gap additively.

## The constraint that makes or breaks this

`ValidationMsg` is `@EqualsAndHashCode(onlyExplicitlyIncluded = true)` over **`validationMsgCode` and
`arguments` only** — position and severity are excluded (`ValidationMsg.java:17-26`). Two messages with the
same code and args at different lines are therefore `equals`.

⇒ The reuse count **must** be tracked by object identity. A `HashSet<ValidationMsg>` or
`.map(...).distinct().count()` would collapse the 231 correct per-row `ERR_KENNUNG_DBA` messages into one and
report 230 reuses for output that is exactly right.

Use `Collections.newSetFromMap(new IdentityHashMap<>())`, whose `add` returns `false` only for the same
instance.

## Change

`ifas-domain-stm/.../validation/delta/ValidationDeltaCalculator.java` — in `compareValidationMsgs`, alongside
the existing `matchedLegacyErrors` / `matchedNewErrors`:

```java
// Identity, not equals: ValidationMsg.equals covers only (code, arguments), so value-based tracking
// would treat the same message reported on different rows as one and invent reuses.
Set<ValidationMsg> newErrorsUsedAsMatch = Collections.newSetFromMap(new IdentityHashMap<>());
int reusedMatchCount = 0;
```

Increment where a match with a new message is recorded — the four `matchedNewErrors.add(...)` sites (exact
`:326`, within-tolerance `:342`, allowed-divergent-args `:355`, same-severity covered-by `:373`):

```java
if (!newErrorsUsedAsMatch.add(bestExactMatch)) {
    reusedMatchCount++;
}
```

**Not** the cross-severity covered-by site (`:390`) — it deliberately does not add to `matchedNewErrors`
because that new message lives in another severity's diff.

Best extracted into a small private helper so the four sites do not each carry the idiom.

`ifas-domain-stm/.../validation/delta/ValidationMsgsComparison.java` — add a plain
`int reusedMatchCount` field via the existing `@Builder`, set from `compareValidationMsgs`. Additive; the
existing `matches` / `onlyInLegacy` / `onlyInNew` and all derived counts stay as they are.

Surface it for reading, without touching `Summary`: a `@Slf4j` info line per comparison when the count is
non-zero, naming the Meldung and the count. `Summary` must not gain a field yet — `SummaryExpectation` is a
six-field record and every `GrossfileBaseline` literal at `GrossfileRecalculationTest:199-246` would have to
change in the same commit.

## Verification

```bash
mvn -Pno-proxy -o install -DskipTests -pl ifas-domain/ifas-domain-stm -am
mvn -Pno-proxy -o test -pl ifas-domain/ifas-domain-stm
mvn -Pno-proxy -o install -DskipTests -pl ifas-testing/ifas-integration-tests -am
mvn -Pno-proxy -o test -pl ifas-testing/ifas-integration-tests -Dtest=GrossfileRecalculationTest
```

All eight baselines and all six counters **unchanged** — this is instrumentation. Any movement means an
increment site altered control flow.

Unit test in `ifas-domain-stm/src/test/.../validation/delta/`:
- three legacy messages, one new message they all match → `reusedMatchCount == 2`
- three legacy messages, three distinct new instances carrying the **same code and args** at different lines
  → `reusedMatchCount == 0`. This is the test that fails if identity tracking is replaced by `equals`, so it
  is the one that matters.

Then read the numbers. Report per dataset (quick-recalc and gf1–gf8): total matches, and of those how many
reused a new message. Expected shape from what is already measured: quick-recalc near zero now that
`ERR_UNG_LAND` and `ERR_KENNUNG_DBA` are per-row (every legacy message has an exact same-line counterpart);
gf1 is where reuse is expected.

To prove the counter detects the real regression rather than merely compiling: temporarily revert
`errKennungDba` to its single-message form, rerun quick-recalc, and confirm the count jumps to ~225. Restore
afterwards.

## Deliberately not in this step

- **`matchedNewErrors` is a value-based `HashSet` (`:312`).** Because `equals` ignores position, matching any
  one message marks every same-code-and-args sibling as matched, so `!matchedNewErrors.contains(newError)`
  keeps them all out of `onlyInNew`. That is the mirror blind spot: **over**-reporting is invisible too — had
  the per-row change overshot to 300 messages against legacy's 231, no counter would have moved. Switching it
  to identity is a genuine fix but a behaviour change that will move baselines, so it belongs in its own
  commit, informed by this count.
- Tightening `hasCompatibleLineScope` to require equal lines.
- Any `Summary` field or baseline update.

## Prior plans in this thread

1. `2026-08-04-err-ung-land-collapse-legacy-fidelity.md` — original diagnosis of the 26→3 collapse
2. `2026-08-04-err-ung-land-per-row-validation-redesign.md` — per-row validation redesign (implemented)
3. `2026-08-04-recordkeypath-truthful-positions-uniform-dedup.md` — `RecordKeyPath`, truthful positions,
   removal of `POSITION_SIGNIFICANT` (implemented)
4. `2026-08-04-err-kennung-dba-per-row-and-missing-tests.md` — `ERR_KENNUNG_DBA` per row, missing unit tests
   (implemented)
5. this one — not started