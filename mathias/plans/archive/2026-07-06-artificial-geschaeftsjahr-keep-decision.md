# Decision: keep the artificial Geschäftsjahr in `SteuerMeldungStatusValidationService`

> **Status: DECISION / ANALYSIS — no code change proposed here.**
> Companion to [`frist-nosn-abort-on-prior-error.md`](./frist-nosn-abort-on-prior-error.md)
> (the abort-gate implementation plan) and to
> `docs/Rekalkulation/Fachabteilung-FRIST-NOSN-gf4.md` (the gf4-18 write-up).

## The question

`SteuerMeldungStatusValidationService.findGeschaeftsjahrForMeldung(...)` returns `null` when the
meldung's reported `gjEnde` has no matching Geschäftsjahr in the fund's `GjZeitreihe`. In that
case `createArtificialGeschaeftsjahr(...)` (`:237`, `:427`) fabricates a GJ from the meldung's
own `gjBeginn`/`gjEnde`.

Two challenges were raised:
1. *Why fabricate one at all — shouldn't we skip the Fristen checks when no valid GJ can be
   determined?*
2. *Given that other validators already reject a meldung with a bad GJ, and given we will add an
   abort-on-prior-error gate (companion plan), can the artificial GJ then be dropped?*

## Decision

**Keep the artificial Geschäftsjahr.** It is not the rejection mechanism, and it is **not** made
redundant by the abort gate. The two mechanisms map to **two different legacy code paths**.
Dropping the artificial GJ would remove Frist messages that the legacy *does* emit on the NEW
path, producing a fresh class of `[-] NUR IM ALTSYSTEM` grossfile deviations — the mirror image
of the gf4-18 problem the abort gate fixes.

## What the artificial GJ actually feeds

The Fristen block reads two fields off the (possibly artificial) GJ:

| Field | Consumer | Code |
|---|---|---|
| `snEnde` | `ERR_FRIST_SN` (`errFristSn`) | short-circuits on `null` (`SteuerMeldungFristenValidators.java:82`) |
| `lastChance` | `ERR_SN_INMELDEFRIST` for NEW/CONFIRMED (`errSnInmeldefrist`) | short-circuits on `null` (`:50`) |

`ERR_FRIST_NOSN` and the UPDATE-Korrekturfrist branch do **not** use the GJ object — they derive
their deadline straight from the meldung via `meldefristAsLastChance(steuerMeldung)`
(`SteuerMeldungStatusValidationService.java:287`). So "skip the artificial GJ → pass `null`"
would silently disable `ERR_FRIST_SN` and `ERR_SN_INMELDEFRIST` only.

## Rejection is handled elsewhere — the artificial GJ is for message parity, not rejection

When the real-GJ lookup fails, the meldung is (in the normal case) already rejected by the
**domain** validation pass, which owns the "reported GJ ≠ Stammdaten" checks:

- `ERR_GJE_UNGLEICH` — exact match fails, a nearest GJ exists (`SteuerMeldungDomainValidators.java:663`)
- `ERR_GJE_UNGLEICH_O` — exact match fails, no nearest GJ (`:763`)
- `ERR_GJE_FEHLT` — fund has no `gj_ende` at all (`:541`)

All ERROR severity; all feed the single `validationMsgs` store; acceptance is
`!validationMsgs.hasErrorForEntry(...)` (`SteuerMeldungLieferungService.java:103`) — any ERROR
from any pass rejects. So the artificial GJ is **not** what stops a bad-GJ meldung. Its job is to
keep the Frist checks emitting the same *message set* the legacy emits, since IFAS accumulates
all messages (not fail-fast) and is verified message-for-message against the legacy grossfiles.

## Why it must stay: the NEW path runs `CheckLieferfristen` ungated

Legacy invokes `CheckLieferfristen` (the sole home of `ERR_FRIST_SN` / `ERR_SN_INMELDEFRIST` /
`ERR_FRIST_NOSN`) from two places, gated differently:

| Legacy fn | New-system counterpart | Frist call | Gated on prior error? |
|---|---|---|---|
| `CheckVorhandeneMeldung` (prev-meldung / status) | `SteuerMeldungStatusValidationService` | `ProcessMeldung_CONFIRMED:3011`, UPDATE-on-OPEN `:9260` | **Yes** — `return -1` before the call (gf4-18) |
| `CheckMeldung` / `CheckIsin` (Stammdaten GJE) | `SteuerMeldungDomainValidationService` | end of `CheckMeldung` **`:4171–4179`** | **No** — GJE errors earlier in the same fn do not suppress it |

Verified in `c_st_meldung.cpp:4171–4179`:

```cpp
// bei NEW und CONFIMED sind die Lieferfristen zu prüfen
if ((strStm_status_angeliefert == "NEW") || (strStm_status_angeliefert == "CONFIRMED"))
    nRet = CheckLieferfristen();   // :4175 — reached even after a GJE-Stammdaten mismatch
```

`CheckMeldung` accumulates errors into `nReturn` and falls through to this call. Therefore a
**NEW meldung with an unresolvable / mismatched `gjEnde` still runs the Frist checks** in legacy,
computed from the reported `gjEnde`. Those checks need `snEnde`/`lastChance` — exactly what the
artificial GJ supplies when the real lookup failed. Remove it and the new system emits fewer
Frist messages than legacy for NEW-with-bad-GJ.

## Interaction with the abort-gate plan

The companion plan gates the Fristen trio on a **prior in-service ERROR, for a non-NEW meldung**
(`status != StmStatus.NEW && validationMsgs.stream().anyMatch(ValidationMsg::isError)`). Two
consequences for the artificial GJ:

- The gate is **in-service**, so it sees the prev-meldung/status errors (`ERR_UNGL_VORH`, …) but
  **not** the domain-pass GJE errors — which is faithful, because legacy's NEW Frist call at
  `:4175` is likewise ungated on GJE errors.
- The gate explicitly **exempts NEW**. On the NEW path the Fristen block still runs, and when the
  GJ is unresolvable it still reaches `createArtificialGeschaeftsjahr`. So even *with* the gate in
  place, the artificial GJ remains live on exactly the path where legacy needs it.

⇒ The abort gate and the artificial GJ are **complementary, not substitutes**. One suppresses the
CONFIRMED/UPDATE/DELETE Frist call after a rejecting prev-meldung error; the other feeds the NEW
Frist call. Neither can be replaced by the other.

## Residual caveat (only relevant if removal is ever reconsidered)

`ERR_GJE_UNGLEICH_O` is gated on `invStatus` (`SteuerMeldungDomainValidators.java:783–794`): it
fires for `A/E/L/I` unconditionally, for `B/Z` only when `gjEnde != fondsEnde`, and for any other
/ null status it fires nothing — and `ERR_GJE_UNGLEICH` also cannot fire then (it needs a nearest
GJ). So there is a narrow window (unusual `invStatus` + empty/near-empty `GjZeitreihe` not caught
by `ERR_GJE_FEHLT`) where the GJ is unresolvable yet **no** GJE ERROR is raised. In that window
the artificial-GJ Frist check would be the only thing that could reject a late filing. This is a
further reason not to drop it; it is not currently known to be reachable in the corpus.

## Conclusion / action

- **No change to `createArtificialGeschaeftsjahr` or `findGeschaeftsjahrForMeldung`.** Keep both.
- Proceed with the abort gate per the companion plan; it does not touch the NEW path and so does
  not affect the artificial GJ.
- If removal of the artificial GJ is ever revisited, it would require: (a) lifting the gate to a
  scope that sees GJE-Stammdaten errors, (b) confirming legacy really skips the NEW Frist check in
  that case (it does **not**, per `:4175`), and (c) proving the `ERR_GJE_UNGLEICH_O` invStatus
  window above is unreachable. (a) and (b) already fail, so the artificial GJ stays.
