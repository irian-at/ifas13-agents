---
name: project-checklieferfristen-status-reachability
description: "Legacy CheckLieferfristen() (ERR_FRIST_NOSN / ERR_FRIST_SN) is reachable from NEW, CONFIRMED and UPDATE — never DELETE; the UPDATE call site is easy to miss."
metadata: 
  node_type: memory
  type: project
  originSessionId: df12323d-c489-4087-8c5d-749ee1f74ed0
  modified: 2026-08-11T10:52:01.884Z
---

`CheckLieferfristen()` in `c_st_meldung.cpp:9579` is the only emit site for
`ERR_FRIST_NOSN` (line 9706, `selbstnachweis == NEIN` && `daFristDatum > daGj_ende`)
and the main one for `ERR_FRIST_SN` (line 9644, `selbstnachweis == JA` &&
`daSNFristDatum > daGj_ende`). It has **three** call sites:

- `CheckMeldung():4175` — gated `NEW || CONFIRMED` (comment there claims "UPDATE und
  DELETE haben eigene Regelungen", which misleads: see below)
- `ProcessMeldung_CONFIRMED():3011` — CONFIRMED, only when `nConfirm_update == 0`
- `CheckVorhandeneMeldung():9260` — **UPDATE** on an OPEN predecessor with no FINAL in
  the chain (else-branch of `!daDZufluss.IsNull()` at 9232)

So NEW / CONFIRMED / UPDATE can all raise both codes; **DELETE never can** (its branch
at 8961-8982 has no call, and `CheckMeldung_DELETE()` doesn't call it either). The
`DELETE → DELETE_DECLINED` arms at 9668 and 9718 are dead code; the `UPDATE` arms are
live via 9260.

`ERR_FRIST_SN` additionally has a second, direct emit site at
`CheckVorhandeneMeldung():9122` — UPDATE on a **FINAL** predecessor.

Dates: `daFristDatum = Stichtag - 7M` (`STM_Frist_Monate`, c_st_meldung.cpp:513),
`daSNFristDatum = daFristDatum - 12M` (:516). So the conditions are
`Stichtag > gjEnde + 7M` and `Stichtag > gjEnde + 19M` (= new system's
`lastChance` and `snEnde`).

**Why:** the Fachabteilung claimed both codes fire only for UPDATE meldungen — false
for both. And `grep`ing legacy for `CheckLieferfristen` while filtering out lines
containing `//` drops the 9260 call site (it has a trailing-whitespace/comment shape
that trips such filters), which makes UPDATE look unreachable.

**How to apply:** when checking which statuses a legacy Frist validation fires for,
enumerate call sites with a plain `grep -a -n` (no `//` filter — legacy .cpp is
ISO-8859-1, see [[project-kontroll-tolerance-legacy]]) and follow each into its
enclosing status branch. `isShouldCheckFristNosn` in
`SteuerMeldungStatusValidationService` already encodes this matrix correctly
(NEW=always, CONFIRMED=no prior FINAL, UPDATE=OPEN predecessor without FINAL,
DELETE=never); `errFristSn` by contrast has no status gate at all.
