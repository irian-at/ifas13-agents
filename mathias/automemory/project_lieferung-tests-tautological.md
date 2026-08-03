---
name: project_lieferung-tests-tautological
description: "SteuerMeldungStatusValidatorsTest asserted getFormattedMessage() against formatMessage(<same args>) — self-referential, hid an arg/placeholder mismatch bug."
metadata: 
  node_type: memory
  type: project
  originSessionId: 4ccab271-22c2-466e-8c76-915473853f49
---

`SteuerMeldungStatusValidatorsTest` originally asserted
`msg.getFormattedMessage()).isEqualTo(ValidationMsgCode.<CODE>.formatMessage(<same args as the factory>))`.
That compares the value to itself with identical arguments, so any argument-count vs.
placeholder-count mismatch is mirrored on both sides and cancels out — the assertion passes
even when the rendered message is broken.

This masked a real bug: `ERR_UPD_OLDM_LIEFERUNG`'s text was aligned to the 2-placeholder
`ERR_UPD_OLDM` while its factory still passed 1 arg, so `MessageFormat` rendered a literal
`<{1}>`. The tautological test didn't catch it.

**Why:** `ValidationMsgCode.formatMessage` (MessageFormat) silently drops extra args and
renders missing ones as literal `{n}` — never throws — so only a *literal* expected string
reveals such mismatches.

**How to apply:** For ValidationMsg text assertions, assert against a hardcoded literal
expected string, not `formatMessage(...)` with the same args. Note number rendering uses
pattern `###0` (no grouping) and `null` renders as `leer`. See [[project_lieferung-codes-are-clones]].
