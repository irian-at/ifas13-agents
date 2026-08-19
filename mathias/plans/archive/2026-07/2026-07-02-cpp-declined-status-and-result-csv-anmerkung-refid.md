# Legacy CPP: Declined status + result.csv Anmerkung / STM-Ref-ID

Findings document (not an implementation plan). Records how the legacy C++ IFAS
application (`~/dev/projects/oekb/ifas`, mainly `Ifas/cprogs2/preise4/`) decides
declined status and populates the result/return CSV. Captured for comparison
against the new IFAS13 Java implementation.

---

## 1. How CPP sets a Steuermeldung to DECLINED

**It is not a set-based any/all test over an error list** (the new Java models the
same outcome with a set-based `allMatch(isDeclined)` — see alignment note below).
CPP keeps a single running "next status" field
(`cStmStatus_modul::cNewStatus`) and each validation check writes to it inline.
Final status = last writer wins, governed by two setters with different precedence.

`c_stm_status.cpp`:

- `SetNewStatus("ERROR")` / `SetNewStatus("X_DECLINED")` — **unconditional** overwrite.
- `SetNewStatusIfNotError("X_DECLINED")` — guarded (the common case):

  ```cpp
  int cStmStatus_modul::SetNewStatusIfNotError(char szPStatus[]) {
      ...
      if (strcmp(cNewStatus.szStatus, "ERROR") == 0)
          return -1;   // ERROR already set -> refuse to set declined
      return SetNewStatus(szPStatus);
  }
  ```

**Effective rule: ERROR wins over DECLINED.**
- Guarded declined-setter refuses to downgrade an already-set ERROR.
- Plain `SetNewStatus("ERROR")` overwrites a previously-set declined.
- => Meldung ends DECLINED only when a declining condition fired **and no plain
  ERROR was recorded** — closest to "only declined errors exist", NOT "at least
  one declined error".

Two wrinkles in `c_st_meldung.cpp`:
- Most declining checks `return -1` right after setting status (e.g. ISIN
  mismatch 8144–8185), so they **short-circuit** further validation — first
  terminal declining condition usually wins.
- A few use unconditional `SetNewStatus("X_DECLINED")` (e.g. `ERR_MELDEID_FEHLT`
  at 7932–7939) which overrides even ERROR — but also `return -1` immediately.

### Alignment with new IFAS13 Java (ALIGNED)

`SteuerlicheErmittlungDomainService.calculateDeclinedOrErrorStatus()` (lines 456–474):

```java
boolean anyDeclinedError = validationMsgsForThisStm.stream()
        .filter(ValidationMsg::isError)                              // ERROR-severity only
        .allMatch(valMsg -> valMsg.getValidationMsgCode().isDeclined());
if (anyDeclinedError) { ... return X_DECLINED; }
return StmStatus.ERROR;
```

NOTE the operator is **`allMatch`**, not `anyMatch` (the variable name
`anyDeclinedError` is a misnomer). So: declined only if **every** error-severity
message is a declined-flagged code; any plain (non-declined) error => ERROR.

This **aligns** with CPP's effective ERROR-wins rule ("declined only when no plain
ERROR present"). The explicit `declined` boolean on `ValidationMsgCode` is a
faithful, cleaner re-modeling of CPP's emergent per-check
`SetNewStatus` / `SetNewStatusIfNotError` precedence — collapsed into one uniform
declarative rule. Supporting details:
- `.filter(isError)` drops INFO/warnings so they don't force ERROR — matches CPP,
  where INFO writes don't touch the ERROR/declined status.
- CPP declining checks short-circuit (`return -1`), so a declined meldung never
  also accumulates independent plain errors; CPP's occasional *unconditional*
  `SetNewStatus("X_DECLINED")` and the guarded variants therefore don't produce
  outcomes different from the new uniform `allMatch`.

(Earlier draft of this doc claimed `anyMatch` / declined-wins / a divergence —
that was a subagent misread of `allMatch`. No divergence.)

---

## 2. result.csv: when Anmerkung and STM-Ref-ID are written

Writer: `cSt_Meldung::WriteMeldung_STATUS()` (`c_st_meldung.cpp:12187`).

Row layout (positional; empty ref-id still emits its separator):
```
STATUS;<statusCode>;<stm_id>;<ref_stm_id>;<anmerkung>
```

Both extra columns are **data-driven, not error-code-driven**: they are emitted
based on whether the member variables were populated during processing, plus a
status-code gate on the ref-id.

### Anmerkung (`strAnmerkung_return`) — written whenever non-empty (no status gate)

Set only for these conditions:

| Condition / error | Text |
|---|---|
| Jahresmeldung already exists (`ERR_JAHRESM_VORH`) -> `NEW_DECLINED` | "Meldung ist bereits vorhanden" |
| Melde-ID missing in STATUS record, status != NEW (`ERR_MELDEID_FEHLT`) | "Melde-ID fehlt im Status Satz" |
| Selbstnachweis deadline reached (`ERR_FRIST_SN`) — UPDATE path & `CheckLieferfristen()` | "Ende der Frist fuer den Selbstnachweis erreicht, keine Meldung mehr moeglich." |
| Referenced meldung not found / invalid id (`ERR_MELDID_FEHLT` / `ERR_MELDID_UNG`) | "Die Meldung mit der Melde-ID <%d> ist nicht vorhanden." / "Die Melde-ID <%ld> ist nicht gueltig …" |
| Reported after deadline, not flagged Selbstnachweis (`ERR_FRIST_NOSN`) | "Die Meldung erfolgt nach der Meldefrist und ist nicht als Selbstnachweis gekennzeichnet." |

Generic `SetNewStatus("ERROR")` field-mismatch checks do **not** set an Anmerkung.

### Reference STM id — written when set AND status allows it

Variable chosen by file type:
- **EStB file** (`nIsEStBFile == 1`): writes `nStm_id_vorherigeFINAL`, gated by
  `status != "CONFIRMED"`.
- **Return file** (else): writes `nStm_id_vorherige`, gated by
  `status != "CONFIRMED" && status != "DELETE"` (DELETE exclusion per `OEKBSD-45290`).

Set at:

| Condition | Variable <- value |
|---|---|
| Jahresmeldung already exists -> NEW_DECLINED | `nStm_id_vorherige <- nAId` |
| Prior FINAL found while checking a CONFIRMED | `nStm_id_vorherige` & `nStm_id_vorherigeFINAL <- nBstm_id` |
| OPEN meldung with prior FINAL found in CHECK phase | both <- `nDstm_id` |
| Processing an UPDATE — id of the meldung being updated | `nStm_id_vorherige <- nStm_id` |

### Net

- **Anmerkung**: only the deadline / duplicate / missing-invalid-melde-id
  conditions above (mostly `*_DECLINED` + `ERR_FRIST_*`, `ERR_MELDID_*`,
  `ERR_JAHRESM_VORH`), independent of the final status code.
- **Ref-id**: whenever a predecessor meldung was resolved (declined-duplicate,
  confirm/open-over-final, update), but **suppressed for `CONFIRMED`** (and for
  `DELETE` in return files).
- Neither column is tied to "any error occurred" — a plain `ERROR` from field
  mismatches carries no Anmerkung and no ref-id unless one of the above fired.

---

## Key source locations

- `c_stm_status.cpp` — `SetNewStatus` (915), `SetNewStatusIfNotError` (941), `SetNewError` (986), `IsNewError` (997)
- `c_st_meldung.cpp` — declined-setting sites 7882/7933–7939/8158–8173/8770–8967; `WriteMeldung_STATUS` (12187–12241)
- `c_stm_logger.cpp` — message texts: `ERR_FRIST_NOSN` (248), `ERR_FRIST_SN` (250), `ERR_MELDEID_FEHLT` (310), `ERR_MELDID_FEHLT` (331), `ERR_MELDID_UNG` (333), `ERR_JAHRESM_VORH` (397)
- New Java: `SteuerlicheErmittlungDomainService.calculateDeclinedOrErrorStatus()` (~456), `ValidationMsgCode.java` (`declined` flag)
