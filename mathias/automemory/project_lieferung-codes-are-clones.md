---
name: project_lieferung-codes-are-clones
description: The four *_LIEFERUNG ValidationMsgCodes are intended to be exact clones (text + args) of their non-LIEFERUNG twins; only the delta covered-by rules distinguish them.
metadata: 
  node_type: memory
  type: project
  originSessionId: 4ccab271-22c2-466e-8c76-915473853f49
---

The four within-Lieferung ValidationMsgCode entries are deliberate exact clones of
their DB-check twins — identical message text AND identical argument shape:
`ERR_STATUS_NM_LIEFERUNG`≙`ERR_STATUS_NM` (2 args), `ERR_UPD_OLDM_LIEFERUNG`≙`ERR_UPD_OLDM`
(2 args), `ERR_JAHRESM_VORH_LIEFERUNG`≙`ERR_JAHRESM_VORH` (0), `ERR_AUSSCHM_VORH_LIEFERUNG`≙`ERR_AUSSCHM_VORH` (0).

The neusystem raises the _LIEFERUNG variant for within-file duplicates; legacy raises the
plain twin. They're kept as separate *codes* only so the delta comparison's covered-by rules
(`StatusNmCoveredByStatusNmLieferung`, `UpdOldmCoveredByUpdOldmLieferung`) can bridge them.
The _LIEFERUNG codes are neusystem-only and never appear in legacy logs, so they were removed
from `ValidationMsgCodePattern` (only legacy-log parsing / equivalence grouping uses that enum).

**Why:** When you touch one twin's text or argument list, the other must stay in lockstep or
the clone invariant breaks.

**How to apply:** If you change an `ERR_*` text/args, update its `_LIEFERUNG` counterpart (and
its factory in `SteuerMeldungStatusValidators`) identically. Caveat: `errUpdOldmLieferung`'s
2nd "Aktuelle Melde-ID" arg is passed as `null` (renders "leer") because the in-Lieferung
successor stmId isn't assigned until persistence runs — there's a TODO to revisit if the
persistence sequence changes. See [[project_lieferung-tests-tautological]].
