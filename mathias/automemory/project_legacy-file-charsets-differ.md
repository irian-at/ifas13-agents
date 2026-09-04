---
name: legacy-file-charsets-differ
description: Legacy EStB CSVs are windows-1252 while return/delete/confirm CSVs and logs are IBM437 - the encoding follows the data's origin, not the producing program.
metadata:
  type: project
---

Legacy return/delete/confirm CSVs and the error/info logs are **IBM437** (byte 0x81 = u-umlaut),
but the legacy `*_EStB.csv` / `*_EStB_erweitert.csv` are **windows-1252** (0xFC = u-umlaut,
0xD6 = O-umlaut). Both come out of the same C++ class (`cSt_Meldung`, written to a plain
`ostream`), and the legacy tree contains no transcoding call at all.

**Why:** the encoding follows where the strings came from, not which program wrote them.
The return file echoes the Lieferant's uploaded CSV back (`c_st_meldung.cpp:2186`
`ExtractColumnEx(strZeile, ...)`), so it carries the supplier's DOS-era CP437 bytes. The EStB
report for the Datenbezieher is rendered from the Sybase DB (`cSt_Meldung::Initialisieren`
sets `nIsEStBFile = 1` at `c_st_meldung.cpp:778`; `m_stm_files.cpp` is its own main program),
so it carries the DB's windows-1252.

**How to apply:** declare the charset per `BundleFileType` from the file's origin, never by
"it's a legacy file, so IBM437". Reading an EStB CSV as IBM437 silently turns every umlaut
into U+207F, which then encodes to `?` in a report - it does not throw, it just manufactures
field diffs. Verify with a byte histogram (`tr -dc '\200-\377' < file | od -An -tx1`) before
trusting a declaration. See [[gf1-fielddiff-null-vs-zero]] for the other class of phantom
field diffs.
