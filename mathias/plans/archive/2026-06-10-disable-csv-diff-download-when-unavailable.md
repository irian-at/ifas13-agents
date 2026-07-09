# Plan: Disable "CSV-Diff Herunterladen" button when no CSV diff is available

## Context

On the **STM ISIN Anforderungsliste Diff Detail** page
(`/ui/estb-report-diffs/{id}` — template `estb-report-diff-detail.html`),
the "CSV-Diff Herunterladen" button is currently rendered unconditionally
inside the "Ergebnis-Bundle-Datei" card. When the backend has no CSV diff
to return, clicking the button hits `GET /{id}/csv-diff-file` and yields
an HTTP 404 (see `EstbReportDiffDetailPageController.downloadCsvDiff`,
line 133–148, which returns `SC_NOT_FOUND` if
`queryService.getCsvDiffProtocol(id) == null`).

The original suspicion was that the absence of CSV-Diff is governed by
the `performStmFieldDiff` setting, but exploring `EstbReportDiffService`
shows otherwise:

- `buildDiffResult()` (line 152–176) returns `null` only when
  `legacyById.isEmpty()` — i.e., when the input bundle contains **no
  legacy `EStB_erweitert#alt.csv`** file. The `performStmFieldDiff` flag
  only swaps the output entry name (`EStB#field-diff.txt` vs.
  `EStB#csv-abgleich.txt`) and whether field-level diffs are computed,
  not whether the CSV diff file is produced.
- The fallback case (`performStmFieldDiff=false` with legacy CSV present)
  still produces a useful `csv-abgleich.txt` — STM-level reconciliation
  (matched count, only-in-legacy, only-in-recalc). Disabling the button
  based on the flag would hide an output the user can legitimately
  consume.

So the correct disable condition is "no CSV diff file is available",
which mirrors the existing inline-protocol card visibility at template
line 291 (`th:if="${csvDiffProtocol != null}"`).

## Goal

When `csvDiffProtocol == null`, render the "CSV-Diff Herunterladen"
anchor as a Bootstrap disabled link with a `title` tooltip explaining
why; otherwise render it unchanged.

## Change

### File to modify

- `ifas-web/ifas-web-ui/src/main/resources/templates/estb-report-diff-detail.html`
  (lines 280–286, the `<a>` tag for `csv-diff-file`)

### Pattern

Add the disabled-style + tooltip via Thymeleaf attribute conditionals on
the existing `<a>`. No second branch / no duplicated markup, no
JavaScript needed — Bootstrap recognizes `.disabled` + `aria-disabled`
on anchors and the browser shows the native `title` tooltip.

```html
<a th:href="${csvDiffProtocol != null}
            ? @{/ui/estb-report-diffs/{id}/csv-diff-file(id=${job.id})}
            : '#'"
   class="btn btn-success btn-sm"
   th:classappend="${csvDiffProtocol == null} ? 'disabled' : ''"
   th:attr="aria-disabled=${csvDiffProtocol == null} ? 'true' : null,
            tabindex=${csvDiffProtocol == null} ? '-1' : null,
            title=${csvDiffProtocol == null}
                  ? 'CSV-Diff nicht verfügbar (kein legacy EStB_erweitert#alt.csv im Input-Bundle).'
                  : null">
    <!-- existing SVG + label unchanged -->
    CSV-Diff Herunterladen
</a>
```

Notes:
- `csvDiffProtocol` is already supplied by
  `EstbReportDiffDetailPageController.showDetail` (line 103–104) for
  completed jobs. No controller change required.
- The card wrapper is already gated by `th:if="${resultBundleFile != null}"`
  (line 252), so for PENDING/PROCESSING jobs the whole card is hidden
  and this change has no effect on them.
- Keep button labels and German wording consistent with the rest of the
  template (the existing inline protocol card uses the same null-check
  semantics).

### What stays the same

- Controller endpoint `GET /{id}/csv-diff-file` — unchanged; it remains
  defensive and continues to return 404 if called directly with an
  unavailable diff.
- `EstbReportDiffService`, `EstbReportDiffOutputs`,
  `EstbReportDiffJobQueryService` — unchanged.
- The "Ergebnis-Bundle Herunterladen" button next to it (line 273) —
  unchanged; the full result bundle is independent of CSV diff
  availability.
