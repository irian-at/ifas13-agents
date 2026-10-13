---
name: project_lieferung-codes-are-clones
description: The four *_LIEFERUNG ValidationMsgCodes are exact clones (text + args) of their twins; assert rendered ValidationMsg text against literals, never against formatMessage(<same args>), which hides arg/placeholder mismatches.
metadata:
  type: project
---

The four within-Lieferung codes are deliberate exact clones of their DB-check twins — identical
message text AND argument shape: `ERR_STATUS_NM_LIEFERUNG`≙`ERR_STATUS_NM` (2 args),
`ERR_UPD_OLDM_LIEFERUNG`≙`ERR_UPD_OLDM` (2), `ERR_JAHRESM_VORH_LIEFERUNG`≙`ERR_JAHRESM_VORH` (0),
`ERR_AUSSCHM_VORH_LIEFERUNG`≙`ERR_AUSSCHM_VORH` (0). The Neusystem raises the `_LIEFERUNG` variant for
within-file duplicates, legacy the plain twin; they are separate codes only so the delta comparison's
covered-by rules (`StatusNmCoveredByStatusNmLieferung`, `UpdOldmCoveredByUpdOldmLieferung`) can
bridge them. They never appear in legacy logs and are therefore absent from `ValidationMsgCodePattern`.

**Why:** touching one twin's text or argument list without the other breaks the clone invariant — and
the tests did not catch it: `SteuerMeldungStatusValidatorsTest` asserted `getFormattedMessage()`
against `formatMessage(<same args>)`, which mirrors any arg/placeholder mismatch on both sides.
`MessageFormat` silently drops extra args and renders missing ones as a literal `{n}`, so
`ERR_UPD_OLDM_LIEFERUNG` rendered `<{1}>` for a while unnoticed.

**How to apply:** change an `ERR_*` text or args → change its `_LIEFERUNG` counterpart and its
factory in `SteuerMeldungStatusValidators` identically. Assert ValidationMsg text against a hardcoded
literal (numbers render `###0`, `null` renders `leer`). `errUpdOldmLieferung`'s second "Aktuelle
Melde-ID" arg is `null` (renders "leer") because the in-Lieferung successor stmId is not assigned until
persistence — TODO if the persistence sequence changes.
See [[project_validationsetting-flags-have-two-effects]].
