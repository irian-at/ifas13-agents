# Legacy `status_anmerkung` (5th STATUS column) in return files — analysis

**Date:** 2026-07-21
**Scope:** How, when, and what the legacy C++ altsystem writes into `status_anmerkung`,
the 5th column of the `STATUS` record rows in return / EStB files.
**Source:** `~/dev/projects/oekb/ifas/Ifas/cprogs2/preise4/c_st_meldung.cpp` (+ `c_stm_logger.cpp`)
(legacy .cpp is ISO-8859-1 → use `grep -a`).

---

## The write site — `cSt_Meldung::WriteMeldung_STATUS()` (`c_st_meldung.cpp:12187`)

The `STATUS` record is emitted field-by-field. Full layout:

```
STATUS ; <status> ; <stm_id> ; <vorherige_stm_id> ; <anmerkung>
  1        2          3            4                   5
```

Column 5 = member **`strAnmerkung_return`** (declared `c_st_meldung.h:676`,
reset to NULL per meldung at `c_st_meldung.cpp:818`).

### Conditional writing — Return-File branch (`12218–12238`)

```cpp
if ((nStm_id > 0) || (nStm_id_vorherige > 0) || (strAnmerkung_return.Length() > 0))
    fOut << ";";                        // sep before col 3
if (nStm_id > 0) fOut << nStm_id;       // col 3
if (((nStm_id_vorherige > 0) && status != "CONFIRMED" && status != "DELETE")
      || (strAnmerkung_return.Length() > 0)) {
    fOut << ";";                        // sep before col 4
    if (nStm_id_vorherige > 0 && status != "CONFIRMED" && status != "DELETE")
        fOut << nStm_id_vorherige;      // col 4 (suppressed for CONFIRMED/DELETE — OEKBSD-45290)
    if (strAnmerkung_return.Length() > 0)
        fOut << ";" << strAnmerkung_return;   // col 5
}
```

Key consequences:

- **Anmerkung is written only when `strAnmerkung_return` is non-empty.** For accepted
  meldungen it stays NULL → the STATUS row has no 5th field.
- It always lands in **position 5**, even when col 4 (previous ID) is suppressed —
  anmerkung-only produces `STATUS;<status>;;;<text>` (empty ID and empty vorherige-ID fields).
- **EStB-file branch** (`nIsEStBFile==1`, `12198–12217`) writes the anmerkung identically
  into col 5; it differs only in col 4 (uses `nStm_id_vorherigeFINAL`, and suppresses that
  field only for `CONFIRMED`, not `DELETE`).

---

## When & what — the 6 assignment sites

All assignments happen during **input validation**, and every one accompanies a
`*_DECLINED` status. So column 5 is effectively **the reason a meldung was rejected**.
Two functions produce them.

### `CheckVorhandeneMeldung()`

| Line | Condition (when) | Text written (what) |
|------|------|------|
| 7879 | `NEW` Jahresmeldung, but an active annual report already exists → `NEW_DECLINED` | `"Meldung ist bereits vorhanden"` *(hardcoded)* |
| 7946 | Status ≠ NEW (CONFIRMED/UPDATE/DELETE) but no Melde-ID supplied → `*_DECLINED` | `"Melde-ID fehlt im Status Satz"` *(hardcoded)* |
| 9124 | UPDATE of a FINAL, flagged Selbstnachweis, delivered past the SN deadline (`daSNFristDatum > daGj_ende`) → `UPDATE_DECLINED` | `ERR_FRIST_SN`: `"Ende der Frist fuer den Selbstnachweis erreicht, keine Meldung mehr moeglich. "` |
| 9342 | CONFIRMED/UPDATE/DELETE references a Melde-ID, but no active meldung exists (or ID out of `int` range) → `*_DECLINED` | `ERR_MELDID_FEHLT`: `"Die Meldung mit der Melde-ID <%d> ist nicht vorhanden."` — or if `lStm_id > INT_MAX`, `ERR_MELDID_UNG`: `"Die Melde-ID <%ld> ist nicht gueltig [moeglicher Bereich von 1 - %d]."` |

### `CheckLieferfristen()`

| Line | Condition (when) | Text written (what) |
|------|------|------|
| 9646 | Meldung flagged Selbstnachweis, delivered past the SN deadline → `*_DECLINED` | `ERR_FRIST_SN` (same text as above) |
| 9724 | Regular (non-SN) meldung delivered after the reporting deadline (`daFristDatum > daGj_ende`) → `*_DECLINED` | `ERR_FRIST_NOSN`: `"Die Meldung erfolgt nach der Meldefrist und ist nicht als Selbstnachweis gekennzeichnet. "` |

Message texts come from the `cBugMsgs` table (`c_stm_logger.cpp:248–334`).
The **trailing space** in `ERR_FRIST_SN` / `ERR_FRIST_NOSN` is part of the literal and
appears in the file.

---

## Important subtleties (for the Java reimplementation)

- **Two of the six texts are hardcoded German strings** (7879, 7946), *not* from the
  message catalog — so anmerkungen cannot all be sourced from the `BugMsgs` table.
- The col-5 string `"Melde-ID fehlt im Status Satz"` (7946) is a **different** string from
  the bug-log message `ERR_MELDEID_FEHLT` = `"Das Pflichtfeld Melde-ID im Satz <STATUS> mit
  Status <%s> ist nicht befuellt."` written to the error log at 7925–7927 for the same case.
- The shared buffer `cABasisParameter::szBuf` is reused for later log lines after the
  assignment, but `cAString::operator=` **copies** the value, so the captured anmerkung is
  correct (no aliasing bug).
- `strAnmerkung_return` is only ever *set*, never cleared after these points; initialized to
  NULL per meldung (818). At most one reason ends up in the file — the first-triggered
  `*_DECLINED` check that returns wins.
- Only these two check functions ever assign `strAnmerkung_return` — no other file in
  `preise4/` touches it.

---

## Summary of all possible column-5 values

1. `Meldung ist bereits vorhanden`
2. `Melde-ID fehlt im Status Satz`
3. `Ende der Frist fuer den Selbstnachweis erreicht, keine Meldung mehr moeglich. `  (ERR_FRIST_SN)
4. `Die Meldung erfolgt nach der Meldefrist und ist nicht als Selbstnachweis gekennzeichnet. `  (ERR_FRIST_NOSN)
5. `Die Meldung mit der Melde-ID <NNN> ist nicht vorhanden.`  (ERR_MELDID_FEHLT, `%d` = supplied ID)
6. `Die Melde-ID <NNN> ist nicht gueltig [moeglicher Bereich von 1 - NNN].`  (ERR_MELDID_UNG, ID > INT_MAX)

(empty / no 5th field ⇒ meldung accepted)

---

## Open follow-ups (not yet done)

- Confirm the STATUS-record **read/parse** side (`c_st_meldung.cpp:1760`) uses the same
  5-column layout.
- ~~Compare against current Java output~~ → done, see next section.

---

# Comparison against the current Java implementation

## Java pipeline (anmerkung → 5th STATUS column)

1. **Validators attach `DeclinedInfo`** to the specific error `ValidationMsg` via
   `msg.withDeclinedInfo(DeclinedInfo)`.
   `DeclinedInfo(@Nullable String anmerkung, @Nullable Long referencedStmId)`
   (`validation/DeclinedInfo.java`) carries exactly the two legacy return-file values:
   col-5 `anmerkung` (`strAnmerkung_return`) and col-4 `referencedStmId`
   (`nStm_id_vorherige`).
2. **`SteuerlicheErmittlungDomainService.calculateDeclinedOrErrorStatus()`** (`:629`)
   iterates the STM's error messages, takes the **first** declined one's `DeclinedInfo`,
   and maps input status → `*_DECLINED`, packing anmerkung + ref-id into
   `StmStatusWithAdditionalInfo(status, stmId, referencedStmId, statusAnmerkung)` (`:661-667`).
   A plain (non-declined) ERROR short-circuits to `StmStatus.ERROR` with **no** anmerkung
   (`:646-651`, `// todo - status anmerkung?`).
3. **`ProcessedSteuerMeldung.withStatusInfo()`** (`:50`) copies `statusAnmerkung` into the
   override field `SteuerMeldung.FieldName.STATUS_ANMERKUNG`.
4. **CSV writer** serializes the STATUS record from the `STM_AUSLIEFERFORMAT` schema:
   `STATUS ; _STATUS_STATUS ; _STATUS_MELDUNGS_ID ; _STATUS_MELDUNGS_ID_REF ; _STATUS_ANMERKUNG`
   → **col 5 = `_STATUS_ANMERKUNG`**. Layout matches legacy exactly.

Success paths (`finishProcessingOpen/Final/Deleted`) build the status info with
`statusAnmerkung = null` → empty col 5 for accepted meldungen. Matches legacy (NULL init).

## Case-by-case coverage of the 6 legacy anmerkungen

| Legacy (file:line) | Java validator | Anmerkung source | Match |
|---|---|---|---|
| `Meldung ist bereits vorhanden` + ref-id (7879) | `StatusValidators.errJahresmVorh` `:387` | `DeclinedInfo.of("Meldung ist bereits vorhanden", existingStmId)` | ✅ incl. ref-id |
| `Melde-ID fehlt im Status Satz` (7946) | `StatusValidators.errMeldeIdFehlt` `:37` | `DeclinedInfo.ofAnmerkung("Melde-ID fehlt im Status Satz")` | ✅ hardcoded |
| `ERR_FRIST_SN` (9124 & 9646) | `FristenValidators.errFristSn` `:94` | `ofAnmerkung(msg.getFormattedMessage())` | ✅ (verify text) |
| `ERR_FRIST_NOSN` (9724) | `FristenValidators.errFristNosn` `:131` | `ofAnmerkung(msg.getFormattedMessage())` | ⚠️ intentional deviation, see below |
| `ERR_MELDID_FEHLT` (9342) | `StatusValidators.errMeldidFehlt` `:101` | `ofAnmerkung(msg.getFormattedMessage())` | ✅ (verify text) |
| `ERR_MELDID_UNG` (9342, id>INT_MAX) | `StatusValidators.errMeldeIdUng` `:69` | `ofAnmerkung(msg.getFormattedMessage())` | ✅ (verify text) |

**All 6 legacy anmerkung strings are reproduced.** Two are hardcoded German literals
(matching legacy 7879/7946 which were also hardcoded, *not* from the message table); the
other four render from the `ValidationMsgCode` message text via `getFormattedMessage()`.

Java also adds within-file (`_LIEFERUNG`) twins that legacy has no separate path for:
`errJahresmVorhLieferung` `:434` (anmerkung only, ref-id is a TODO — earlier dup's stmId not
yet assigned).

## Ref-id (col-4) — the other `DeclinedInfo` field

- `errJahresmVorh` → `existingStmId` (= legacy `nAId`). ✅
- `checkKorrekturfrist` → `DeclinedInfo.of(null, referencedStmId)` for `ERR_UPD_TOLATE` /
  `ERR_CON_UPD_TOLATE` (`FristenValidators:257`) — the "ref-id only, no anmerkung"
  combination. Mirrors legacy 9217 (UPDATE of OPEN with prior FINAL → ref = that FINAL).

## Deviations & risks to verify

1. **`ERR_FRIST_NOSN` skips Ausschüttungsmeldungen** (`errFristNosn:117`,
   `FALSE.equals(getJahresdatenmeldung())`) — intentional, "confirmed with Caroline Gitterle
   7.7.2026, no Fristencheck for Ausschüttungsmeldungen". Legacy applied it regardless. So a
   late non-SN Ausschüttungsmeldung gets **no** anmerkung / no decline in the new system.
2. **"First declined wins" ordering.** Legacy sets `strAnmerkung_return` in whichever Check
   returns `-1` first (strict sequential order). Java takes the first `isDeclined()` message
   in the collected list (`:636`). If the message collection order differs from the legacy
   check order, a meldung tripping several declined conditions can emit a *different*
   anmerkung than legacy. Verify list order matches legacy check sequence.
3. **Message-text fidelity.** The 4 non-hardcoded anmerkungen equal `getFormattedMessage()`,
   so byte-identical return files require the `ValidationMsgCode` texts to match the legacy
   `cBugMsgs` literals exactly — including the **trailing space** in `ERR_FRIST_SN` /
   `ERR_FRIST_NOSN` and the `%d`/`%ld` substitutions. Confirm the message properties carry
   the trailing space (cf. memory: MessageFormat can silently render/omit).
4. **Plain-ERROR path writes no anmerkung** (`:650 todo`). Consistent with legacy (only
   `*_DECLINED` set anmerkung), but the TODO signals it's not yet deliberately decided.
5. **col-4 ref-id semantics still open** (`getVorherigeStmId :682 todo`): legacy writes
   `nStm_id_vorherige`, but Caro indicated the *vorherige FINAL*. Affects col 4, not col 5.
