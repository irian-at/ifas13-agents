# Return CSV: Anmerkung + STM-ID-Ref via DeclinedInfo

## Context

The return CSV sent back to suppliers has a `STATUS` record with columns
`_STATUS_MELDUNGS_ID_REF` (col 3, predecessor STM id) and `_STATUS_ANMERKUNG`
(col 4, status remark). The legacy C++ populated these for specific declined
conditions; the new IFAS13 system defines the columns, accessors, and a generic
writer, **but nothing ever fills them** — they are always empty today.

Goal: populate Anmerkung + ref-id so the return file matches legacy behavior.

Legacy reference (verified in `~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/c_st_meldung.cpp`):
three distinct combinations exist —
- **Text only** (no ref-id): `ERR_FRIST_SN` (9124, 9646), `ERR_FRIST_NOSN` (9724),
  `ERR_MELDEID_FEHLT` (7946), `ERR_MELDID_FEHLT`/`_UNG` (9342).
- **Text + ref-id**: `ERR_JAHRESM_VORH` (7878 ref = existing meldung id, 7879 text).
- **Ref-id only** (no text): the success/echo rows — UPDATE (10613),
  CONFIRMED-over-FINAL (8882), OPEN-over-FINAL (9217).

Companion findings doc: `cpp-declined-status-and-result-csv-anmerkung-refid.md`.

## Decisions (confirmed with user)

1. **Declined path** → carry the remark + ref-id on the `ValidationMsg` via a new
   nullable `DeclinedInfo` (both fields independently nullable). Chosen over a
   per-code enum template because the ref-id is dynamic and must ride the msg
   regardless, so the enum route would split the data across two mechanisms.
2. **Success rows** → handled **independently of the validation flow**, in the
   processed-meldung field overrides where `STATUS`/`STM_ID` are already set
   (`getTechnicalReturnFieldValuesToAdd`).

## Reuse (already present — do not reinvent)

- Output fields `STM_ID_REF`, `STATUS_ANMERKUNG` + accessors `getReferencedStmId()`,
  `getStatusAnmerkung()` — `SteuerMeldung.java:49-50,159-167`.
- `ProcessedSteuerMeldung.withOverriddenFields(Map)` — `ProcessedSteuerMeldung.java:61`.
- Generic writer emits any populated field — `CsvSteuerMeldungenWriter` → **no writer change needed**.
- Immutable-wither pattern to mirror — `ValidationMsg.withSeverity(...)` (`ValidationMsg.java:43`).

## Part A — Declined path (Anmerkung + ref-id on the msg)

1. **New record** `DeclinedInfo(@Nullable String anmerkung, @Nullable Long referencedStmId)`
   in `at.oekb.ifas.domain.stm.validation` (`@NullMarked`).
2. **`ValidationMsg`** (`ValidationMsg.java`): add `@Nullable DeclinedInfo` field +
   `withDeclinedInfo(DeclinedInfo)` wither (mirror `withSeverity`; carry it through
   `withSeverity` too). Keep it **out of** `@EqualsAndHashCode` (identity stays
   code+args, matching `ValidationMsgStore.deduplicate()`).
3. **Attach in validators** — only the codes legacy actually annotates:
   - `SteuerMeldungStatusValidators`: `errJahresmVorh` (text *"Meldung ist bereits
     vorhanden"* + resolved existing id — **change signature to pass the `Long`
     instead of today's `boolean`**, source at `SteuerMeldungStatusValidationService`
     ~line 154), `errMeldeIdFehlt` (text only), `errMeldidFehlt` (text only).
   - `SteuerMeldungFristenValidators`: `errFristSn`, `errFristNosn` (text only).
   - **Do NOT** annotate `ERR_ISIN_MID`, `ERR_STATUS_NM`, `ERR_UPD_*`,
     `ERR_CON_UPD_TOLATE`, `ERR_AUSSCHT_AKT_CONF` — legacy declines these with no
     Anmerkung/ref-id; stay faithful.
4. **Select + propagate** in `SteuerlicheErmittlungDomainService`:
   - `calculateDeclinedOrErrorStatus` (line 456) — when declined, pick the **first
     declined `ValidationMsg` carrying a non-null `DeclinedInfo`** (deterministic
     validator order; mirrors CPP short-circuit-on-first-condition). Return status
     **and** the selected `DeclinedInfo` (small holder record, or thread it out of
     `calcErrorStatus`).
   - `markInputStmWithFailedStatus` (line 167) and `markProcessedStmWithErrorStatus`
     (finish path, line 415) — apply `STATUS_ANMERKUNG` + `STM_ID_REF` via
     `withOverriddenFields` when the `DeclinedInfo` is present.

## Part B — Success rows (ref-id only), independent of validation

- Add `@Nullable Long referencedStmId` param to `getTechnicalReturnFieldValuesToAdd`
  (`SteuerlicheErmittlungDomainService:373`); `put(STM_ID_REF, …)` when non-null.
  Thread it from `handleUpdate` (304) / `handleConfirm` (323) / `handleDelete` (343).
- **Open decision — source of the predecessor id** (flagged, coupled to the
  `handleUpdate` stmId-provider TODO at line 310):
  - UPDATE: the supplied Melde-ID `inputStm.getStmId()` — already in scope, no
    validation/DB dependency.
  - CONFIRM / OPEN-over-FINAL: legacy uses the **resolved FINAL predecessor**
    (chain walk), i.e. a repository lookup in the processing flow. Recommend a
    lookup here (independent of validation) OR defer these until the id model is
    finished. Decide before implementing Part B.
- Preserve legacy writer gating: `STM_ID_REF` suppressed for plain `CONFIRMED`/
  `DELETE` output rows, emitted for the `*_DECLINED` statuses (Part A rows).

## Critical files

- `.../stm/validation/DeclinedInfo.java` (new), `ValidationMsg.java`
- `.../stm/validation/status/SteuerMeldungStatusValidators.java`,
  `.../SteuerMeldungStatusValidationService.java`
- `.../stm/validation/fristen/SteuerMeldungFristenValidators.java`
- `.../stm/ermittlung/SteuerlicheErmittlungDomainService.java`
- (no change) `.../meldung/csv/CsvSteuerMeldungenWriter.java`

## Verification

- Unit tests (given-when-then, AssertJ, `@Inject`) per declined code: assert
  `getStatusAnmerkung()` text + `getReferencedStmId()` on the returned
  `ProcessedSteuerMeldung`. Cover text-only, text+ref-id, and (Part B) ref-id-only.
  Watch the `_LIEFERUNG` twins (see `[[project_lieferung-codes-are-clones]]`) and
  assert against literal expected strings, not `formatMessage(sameArgs)`
  (see `[[project_lieferung-tests-tautological]]`).
- Integration test (`@TestTemplate`, MULTI_DB) that writes the return CSV and
  asserts the `STATUS` row col 3 (ref) / col 4 (Anmerkung); compare against a
  legacy-produced expected file where available.
- Confirm no regression: existing return-file tests still pass with the new
  (previously empty) columns now populated only for the intended cases.
