---
name: project_legacy-return-col4-vorherige
description: "Legacy return-file STATUS col 4 is nStm_id_vorherige on every status except literal CONFIRMED/DELETE: accepted UPDATE→OPEN = immediate predecessor, CONFIRMED→FINAL and ERROR = nearest FINAL ancestor; FINAL rows DO carry a ref."
metadata:
  type: project
---

Legacy `WriteMeldung_STATUS` (`c_st_meldung.cpp:12187`) writes col 4 = `nStm_id_vorherige` on every
return status except the literal `CONFIRMED`/`DELETE` (those only go to the separate confirm/delete
files, `WriteConfirmMeldung:11965`). A confirmation's return status is `FINAL` (`GetNewStatus`, callers
11887/11937), so **FINAL rows do carry a ref**.

The value is operation-dependent:

- accepted UPDATE → OPEN: the **immediate** `vorherige_stm` (`:7878` / `:10613`)
- CONFIRMED → FINAL and ERROR: the **nearest FINAL ancestor** — the validation walk `:8825-8886` /
  `:9157-9218` sets `nStm_id_vorherige = nStm_id_vorherigeFINAL` (header `h:639` vs `h:643`; DB
  `vorherige_final_stm_id` maintained at `:10995`)
- empty only when that predecessor does not exist

**Why:** the 8 grossfiles contain only first-time confirmations (no prior FINAL → nearest-final
trivially null → empty col 4), which once produced the wrong conclusion "legacy never writes a ref on
FINAL". A real re-confirmation return file shows the ref.

**How to apply:** the Neusystem CONFIRMED path keeps `vorherigeFinalStmId` in col 4 (a `null` change
was reverted 2026-07-23); the ERROR path (`resolveErrorReferencedStmId` → nearest FINAL) is correct;
OPEN rows reference the immediate predecessor. Related: [[project_gf1-fielddiff-null-vs-zero]],
[[project_korrekturfrist-requires-final-predecessor]].
