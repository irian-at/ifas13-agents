# Align "Erstellt" timestamp formatting on STM ISIN Anforderungsliste Diffs list page

## Context

The UI for the "STM ISIN Anforderungsliste Diffs" feature is inconsistent: the list page (`/ui/estb-report-diffs`) renders the "Erstellt" column differently from the detail page (`/ui/estb-report-diffs/{id}`). The cause is twofold — the list page uses Thymeleaf's built-in `#temporals.format` with the `dd.MM.yyyy HH:mm` pattern and no timezone conversion, while the detail page uses the project's `@vienna` formatter bean which converts the `OffsetDateTime` to Europe/Vienna and renders `dd.MM.yyyy HH:mm:ss`. This produces two visible differences in the same job row: missing seconds, and (for offsets that cross the Vienna shift, e.g. UTC values) a different wall-clock time.

The STM Rekalkulationen pages (`/ui/stm-recalculations` and `/ui/stm-recalculations/{id}`) consistently use `@vienna.format(...)` for the same kind of timestamp and are the project's de-facto reference. The fix is to align the ESTB diff list page with that pattern.

## Change

Single template edit. No controller, DTO, or formatter changes are needed — `EstbReportDiffJob.createdAt` is already an `OffsetDateTime` and the `@vienna` bean (`ViennaTimeFormatter`, `@Component("vienna")`) is already in scope for every Thymeleaf template in `ifas-web-ui`.

**File:** `ifas-web/ifas-web-ui/src/main/resources/templates/estb-report-diff-list.html`

Line 209 — replace:

```html
<td th:text="${#temporals.format(job.createdAt, 'dd.MM.yyyy HH:mm')}"></td>
```

with:

```html
<td th:text="${@vienna.format(job.createdAt)}"></td>
```

That is the only change. After it, the "Erstellt" column on the list view will match the detail view and the Rekalkulationen pages: Vienna time, `dd.MM.yyyy HH:mm:ss`, and `-` for null (handled by the formatter).

## Reused utility

- `ViennaTimeFormatter` at `ifas-web/ifas-web-ui/src/main/java/at/oekb/ifas/web/config/ViennaTimeFormatter.java` — `@Component("vienna")`, exposes `format(OffsetDateTime)` (with seconds) and `formatShort(OffsetDateTime)` (no seconds). Both convert via `LocalDateTimes.ofOffsetDateTimeInVienna(...)` and return `"-"` for null. This is the same bean already used by `estb-report-diff-detail.html`, `stm-recalc-list.html`, and `stm-recalc-detail.html`.

## What is intentionally NOT touched

- Line 194 (`keyDate`) keeps `#temporals.format(job.keyDate, 'dd.MM.yyyy')` — `keyDate` is a `LocalDate`, not an `OffsetDateTime`; `@vienna` does not handle `LocalDate` and the existing rendering is correct.
- The detail page is already correct.
- Other columns (`createdBy`, `notes`, error/warning badges) are unrelated to the reported issue.

## Verification

1. Start the app locally with one of the test launchers — `LocalH2OnlyIfasApplication` is fine; H2 is sufficient since the bug is purely in template rendering.
2. Navigate to `http://localhost:8080/ifas-uat/ui/estb-report-diffs`.
3. For at least one job row, confirm the "Erstellt" cell now shows `dd.MM.yyyy HH:mm:ss` (with seconds) in Vienna time.
4. Click into the job's detail page (`/ui/estb-report-diffs/{id}`) and confirm the "Erstellt" value matches the list row exactly — same minute *and* same seconds, no time shift.
5. Cross-check against `/ui/stm-recalculations` to confirm the visual formatting is now identical between the two job-list pages.
6. No automated test changes are required — there is no test asserting the rendered "Erstellt" string for this page, and the change is a one-line template alignment to an already-tested formatter (`ViennaTimeFormatterTest` covers the bean itself).
