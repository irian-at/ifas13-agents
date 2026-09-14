---
name: preismeldung-rueckmeldung-log-format
description: "Verified byte format of the Preismeldung Rückmeldung logs - LF + ISO-8859-1 (not CRLF), labels from txt_bez_e, and the September 2026 production sample that pins it."
metadata: 
  node_type: memory
  type: project
  originSessionId: 736590b4-e9c7-4ca7-bb81-ff40c9e0907e
  modified: 2026-09-14T14:57:29.804Z
---

The Preismeldungs-Rückmeldung (`statistics.log`, `error.log`, `info.log`, `data.log` in the
delivery ZIP) is **LF-terminated ISO-8859-1**, not CRLF. `make_einzel.awk:296-300` does pipe all
five logs through `unix2dos -c iso`, which would make them **CP437 with CRLF** — but in the
September 2026 production archive that conversion reached exactly one file out of 103 deliveries:
`db_allianz`'s `data.log` (0x81 for `ü`). Everything else, including `db_allianz`'s own
`statistics.log`, is LF + 0xFC. What drives the conversion is not in the repo (the deployed MFT
scripts/INIs are missing).

Every code label in the logs comes from `tax_code.txt_bez_e`, never `txt_bez` — so the
`Rüchnahmepreis` typo and the double-encoded umlauts in `txt_bez` do not reach the Lieferant.

**Why:** the class-level Javadoc asserted "ISO-8859-1 with CRLF (legacy runs unix2dos -c iso
before zipping)" and the writer emitted CRLF accordingly; the real archive says otherwise. The
whole statistics/data layout had been reconstructed from the legacy sources' *intent* rather than
from output, and both were wrong (`%7d  - <label>` vs. an invented `<label>: %5d`; `data.log`
needs `--- input row:` / `--- data-records:` / field blocks, and a rejected line carries the
**last** bug text instead of a status line, because legacy overwrites `szBugInfo`).

**How to apply:** verify a legacy output format against real output bytes before trusting a port
of the writing code — `preise4/M_INSERT.CPP` alone does not tell you what the MFT wrapper does to
the file afterwards. The sample lives in `docs/Fondspreise/beispiele/testdaten_september.zip`
(`Meldung/db_*` = 103 Preismeldungs-Antworten, `Bereitstellung/` = Auslieferungs-ZIPs); two of
them are committed as fixtures under the fondspreise module's
`src/test/resources/.../rueckmeldung/` and compared byte-for-byte by
`PreismeldungRueckmeldungGoldenFileTest`. Related: [[legacy-file-charsets-differ]].
