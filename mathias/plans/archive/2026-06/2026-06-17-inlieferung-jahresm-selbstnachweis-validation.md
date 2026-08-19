# Plan: rethink the `ERR_JAHRESM_VORH` / `InLieferungAcceptedState` validation for Selbstnachweis-JM

## Background

After commit `e1cade6e` ("feat: add Selbstnachweis to LieferungStmKey"),
`LieferungStmKey` carries four fields: `(isin, jahresdatenmeldung, gjEnde,
selbstnachweis)`. Two consequences cascade through the validation chain:

1. `InLieferungAcceptedState.acceptedNewKeys: Set<LieferungStmKey>`
   (`InLieferungAcceptedState.java:43`) now uses the four-field key. A regular
   JM and a Selbstnachweis-JM for the same `(isin, gjEnde, jahresdatenmeldung=true)`
   have **different** entries — neither blocks the other.
2. `SteuerMeldungStatusValidationService.validate(...)` at
   `SteuerMeldungStatusValidationService.java:137-161` reads `acceptedState`
   first and only falls back to the DB lookup
   `findExistingMeldungStmIdByGjEndeAndJahresMeldung(existingMeldungen,
   gjEnde, jahresdatenmeldung)` if no in-Lieferung hit was found.
   That DB lookup ignores `selbstnachweis` as a filter — but it also doesn't
   fire when both Meldungen are in the same fresh Lieferung (nothing in DB
   yet).

Net effect: a CSV that contains a regular-JM **and** a Selbstnachweis-JM for
the same `(ISIN, gjEnde, jahresdatenmeldung=true)` passes status validation
without raising `ERR_JAHRESM_VORH_LIEFERUNG`. Both Meldungen are accepted
and reach calculation/prefill. This is observable in
`gf1-d20260724.csv` lines 573 (Selbstnachweis = JA) vs 578 (Selbstnachweis
defaulted to NEIN), and is the upstream cause behind the
`IllegalStateException("More than one match")` reported on the test server
— see `i-got-this-throw-graceful-starfish.md`. The immediate symptom has
been fixed by adding `_SN` to the prefilled-Excel filename; the domain
policy question is what this plan addresses.

## Legacy C++ behavior (`/home/sma/dev/projects/oekb/ifas`)

Reviewed file:
`/home/sma/dev/projects/oekb/ifas/Kurs/tabledefs/steuer_meldung.cr`.

- Schema columns (`steuer_meldung.cr:89-90`):
  ```
  jahresdatenmeldung   D_JA_NEIN    null,
  selbstnachweis       D_JA_NEIN    null,
  ```
  Both flags exist as independent columns on `steuer_meldung`.

- Unique constraint (`steuer_meldung.cr:125`):
  ```
  constraint AK_STUER_BEH_ALT_KEY_STEUER_M unique (num_wfs_ku, gj_ende, guelt_ab)
  ```
  The uniqueness key is `(ISIN, Geschäftsjahr-Ende, gültig-ab)` —
  it **does not** include `jahresdatenmeldung` or `selbstnachweis`.

- Secondary unique constraint (`steuer_meldung.cr:126`):
  ```
  constraint AK_STEUER_BEH_TIMESTA_STEUER_M unique (guelt, num_wfs_ku, gj_ende, stm_id)
  ```
  Adds `guelt` (full timestamp) + `stm_id`, again with no flag involvement.

**Implication** (with the caveat that this is only the DB-level constraint —
the C++ application code may add stricter checks that I did not locate; the
Explore agent could not find an explicit application-layer
"Jahresmeldung-vorhanden" check with a hardcoded German error message):

If `guelt_ab` differs between a regular-JM and a Selbstnachweis-JM for the
same `(ISIN, gjEnde)`, the legacy DB allows them to coexist. If `guelt_ab`
is the same (e.g. both inserted on the same processing run with default
`getdate()`), the unique constraint rejects the second one — which surfaces
to the user as an SQL error, not a domain-specific error code. So the
legacy is **not unambiguous** evidence either way: it does not encode the
policy "Selbstnachweis-JM and regular-JM are mutually exclusive" at the
schema level, but it also doesn't endorse the new Java behavior of treating
them as fully orthogonal slots.

A follow-up before deciding: locate the C++ application-layer check
(`c_st_meldung.cpp` / `CheckVorhandeneMeldung` is referenced from
`SteuerMeldungStatusValidationService.java:105` as the legacy source for a
neighboring lookup — that file is the most likely place for the
Jahresmeldung-vorhanden rule). If it exists and its predicate ignores
`selbstnachweis`, then the new Java behavior is a regression; if it uses
`selbstnachweis`, then the new Java behavior matches legacy and only the
filename collision (already fixed) was broken.

## The domain-policy question

Pick one:

**Option A — Mutually exclusive (legacy-equivalent if legacy ignored selbstnachweis):**
A regular JM blocks a Selbstnachweis-JM for the same `(ISIN, gjEnde,
jahresdatenmeldung=true)` and vice-versa, *both* within a Lieferung and
against the DB. Restores the pre-`e1cade6e` semantic, just with the new
key.

**Option B — Orthogonal dimension:**
A regular JM and a Selbstnachweis-JM for the same `(ISIN, gjEnde,
jahresdatenmeldung=true)` are two valid slots and may both be accepted.
The current Java code accidentally implements this — make it the official
rule.

**Option C — Asymmetric:**
A Selbstnachweis-JM is a *substitute* for a missing regular JM. Define
preconditions (e.g. only allowed when no regular JM exists yet for the
`(ISIN, gjEnde)` slot, or only allowed past a certain Frist). Requires
domain input from OEKB.

## Recommended next steps (no code change yet)

1. **Confirm the C++ rule.** Read
   `/home/sma/dev/projects/oekb/ifas/Ifas/cprogs2/.../c_st_meldung.cpp`
   (referenced from `SteuerMeldungStatusValidationService.java:105`). Look
   for the predicate that drives the "Jahresmeldung schon vorhanden" check.
   Determine whether it filters by `selbstnachweis` or not. This decides
   between Option A and Option B/C.
2. **Cross-check with stakeholders** if the legacy is ambiguous. The
   `LieferungStmKey` Javadoc claims the coexistence is by design — confirm
   with whoever wrote `e1cade6e` whether that's the intended OEKB rule or
   only a key-design choice without semantic backing.
3. **Implement.** Depending on the outcome:
   - **Option A**: change
     `InLieferungAcceptedState.hasAcceptedNew(LieferungStmKey)` to compare
     ignoring `selbstnachweis` (or carry a separate `Set` keyed by
     `(isin, jahresdatenmeldung, gjEnde)`). Mirror in the DB-side
     `findExistingMeldungStmIdByGjEndeAndJahresMeldung` — already ignores
     `selbstnachweis` by virtue of not querying it, but verify.
   - **Option B**: keep current code; update the `LieferungStmKey` Javadoc
     and add a unit test pinning the behavior so it doesn't regress.
   - **Option C**: design a new validator that encodes the asymmetric rule;
     this is the largest change and should be sized separately.
4. **Test data.** `gf1-d20260724.csv` rows 573/578 are the canonical pair
   — either keep them as positive coverage (Option B), turn them into a
   negative test expecting an `ERR_JAHRESM_VORH_LIEFERUNG` (Option A), or
   adjust per the C++-confirmed rule.

## Files in scope when the policy is decided

- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/status/InLieferungAcceptedState.java`
  — primary change locus for Options A and B.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/status/SteuerMeldungStatusValidationService.java`
  (lines 137-161, lines 146-150) — DB-side lookup may need the
  `selbstnachweis` flag added or explicitly documented as ignored.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/validation/status/SteuerMeldungStatusValidators.java`
  (`errJahresmVorh`, `errJahresmVorhLieferung`, lines 354-418) — currently
  policy-free predicate; may need Selbstnachweis branch.
- `ifas-domain/ifas-domain-stm/src/main/java/at/oekb/ifas/domain/stm/meldung/LieferungStmKey.java`
  — Javadoc to update once the rule is final.
- `ifas-domain/ifas-domain-stm/src/test/java/at/oekb/ifas/domain/stm/validation/status/InLieferungAcceptedStateTest.java`
  — pin the chosen behavior.