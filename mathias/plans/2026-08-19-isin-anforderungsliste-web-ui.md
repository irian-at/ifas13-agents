# Web UI for the ISIN Anforderungsliste job

## Context

`IsinAnforderungslisteJob` — the production job that turns one `.isin` request file into the EStB
CSVs plus logs (`_EStB.csv`, `_EStB_erweitert.csv`, `_error.log`, `_info.log`, packed as
`<basename>#estb-result.zip`) — is fully built but **orphaned**: entity, table, paging repository,
`IsinAnforderungslisteJobSubmissionService.submit(...)` and the
`IsinAnforderungslisteJobExecutionService` work-queue handler all exist, and the only caller in the
repository is `IsinAnforderungslisteJobExecutionServiceTest`. There is no way to reach it from the
application.

What exists in the UI today is a *different* job: `IsinAnforderungslisteDiffJob` under
**Testen → STM ISIN Anforderungsliste Diff** (`/ui/isin-anforderungsliste-diff[s]`). That one is a
Parallelbetrieb/testing feature — it takes a ZIP, diffs the new outputs against the legacy CPP
outputs, and carries `diff_settings`, `error_count`, `warning_count`.

This change gives the production job the same operational surface that **STM → Steuermeldungen**
gives `StmCalcJob`: a list page, an upload page, and a detail page — no diff anywhere.

## Decisions

| | |
|---|---|
| Menu | **STM → ISIN Anforderungsliste**, directly below *Steuermeldungen* (no `STM` prefix in the label — the group already says it) |
| Routes | list `/ui/isin-anforderungslisten`, form `/ui/isin-anforderungsliste`, detail `/ui/isin-anforderungslisten/{id}` — mirrors the existing `-diffs`/`-diff` pair |
| Scope | full mirror of *Steuermeldungen*, including the Notizen field → one Flyway migration |
| Upload | multiple `.isin` files, one job per file (as *Neue Steuermeldung* does) |
| Diff | none — `stm-calc` has no diff code at all, so mirroring it is diff-free by construction |

Active-page key: `isin-anforderungslisten`, set by all three controllers (the way all three
`StmCalc*PageController`s set `stm-calculations`).

## The pattern to copy

Three controllers in `ifas-web/ifas-web-ui/src/main/java/at/oekb/ifas/web/stm/`:

- `StmCalcListPageController.java` — `@GetMapping` with `text` / `status` / `keyDate` / `archived` /
  `sort` / `@PageableDefault(size = 15, sort = "createdAt", DESC)`, plus `POST /bulk-archive`,
  `/bulk-unarchive`, `/bulk-delete`
- `StmCalcFormPageController.java` — `@GetMapping` renders the form or the POST-Redirect-GET
  confirmation when `?calculationId=` is set; `POST /upload` binds `MultipartFile[]` plus loose
  `@RequestParam`s (there is no form/DTO class), validates inline, and submits one job per file
  inside a single `tx.doTransactional(...)`
- `StmCalcDetailPageController.java` — `GET /{id}`, `/{id}/input-file`, `/{id}/result-file`,
  `POST /{id}/notes`, `/{id}/archive`, `/{id}/unarchive`

Two conventions to carry over verbatim:

1. **Errors render the view directly, never redirect + flash.** See the Javadoc on
   `StmCalcFormPageController#renderError`: UI controllers are mounted under `/ui`, and a redirect to
   a non-`/ui` path is bounced by `LegacyUiRedirectFilter`; that extra hop drops flash attributes.
   (`IsinAnforderungDiffFormPageController` still uses the older redirect + `/error` landing route —
   do **not** copy that half.)
2. `MultipartFile` → `NamedContentTypeResource.of(inputStream, contentType, originalFilename)`, with
   `IOException` wrapped in `IllegalStateException`.

## Work

### 1. Persistence — add `notes`

`ifas-database/ifas-persistence-infra/.../persistence/infra/isinanforderung/IsinAnforderungslisteJob.java`

Add the field exactly as `StmCalcJob` declares it, plus a `@Nullable String notes` builder
parameter:

```java
@Setter @Nullable
@Column(name = "notes", columnDefinition = "TEXT")
private String notes;
```

`IsinAnforderungslisteJobRepository.java` — add the five `@Modifying`/count methods the list and
detail pages need, copying the bodies from `StmCalcJobRepository` (identical, only the entity name
and the `inputIsinFile` field name differ): `updateNotes`, `updateArchived`, `updateArchivedBatch`,
`countByInputIsinFileExcluding`, `countByResultBundleFileExcluding`.

`IsinAnforderungslisteDiffJobRepository` already carries the same set — use it as the second
reference.

### 2. Flyway — V055

The `infra` tables are PostgreSQL/H2 only; Sybase gets an empty placeholder that keeps version
numbers in sync (see `sybase16/V045__isin_anforderungsliste_jobs.sql`, which is a single comment
line). Follow `V015__stm_recalc_jobs_add_notes.sql`:

- `postgres15/V055__isin_anforderungsliste_jobs_add_notes.sql`
  → `ALTER TABLE isin_anforderungsliste_jobs ADD COLUMN notes text;`
- `sybase16/V055__isin_anforderungsliste_jobs_add_notes.sql`
  → `-- not required in sybase database`

Then regenerate `ifas-dev-tools/src/main/resources/at/oekb/ifas/devtools/postgres-db-schema.sql`:

```bash
mvn exec:java -Dexec.mainClass="at.oekb.ifas.devtools.DatabaseSchemaTool" -Pno-proxy
```

### 3. Service layer

**`IsinAnforderungslisteJobSubmissionService`** (existing, in
`ifas-services/ifas-main-service/.../service/isinanforderung/`) — extend to match
`StmCalcJobSubmissionService`:

- add `@Nullable String notes` to `submit(...)` and set it on the builder
- add a `submitFromWebUi(...)` wrapper that records the audit event in a `finally` block, mirroring
  `submitCalculationFromWebUi`; reuse `StmAuditDetail(lieferant, inputFilename, keyDate, notes)` —
  its shape already fits
- add `updateNotes(id, notes, changedBy)`, `setArchived(id, archived)`,
  `setArchivedBatch(ids, archived)`, `deleteArchivedBatch(ids)`. The delete path copies
  `StmCalcJobSubmissionService#deleteArchivedBatch` step for step: filter to archived, collect
  filestore URIs that no surviving job references, delete work-queue items via
  `workQueueItemRepository.deleteByTaskTypeAndPayloadContaining(IsinAnforderungslisteJob.WQ_TASK_TYPE, jobId)`,
  nullify `repeatedFromJob` FKs, delete the entities, then drop the orphaned filestore entries
- drop the duplicated `.inputFilename(...)` call in the existing builder chain (set twice today)

Keep `dbCtxHelper.requireActiveTransaction()` and the `@Autowired(required = false)` +
null-guard `filestore()` accessor already in the class.

**`IsinAnforderungslisteJobQueryService`** (new) — copy `StmCalcJobQueryService`, substituting
`DefaultJobStatus` for `StmCalcJobStatus`. Two things to preserve:

- every read wrapped in `dbCtxHelper.withJobSystemDbContext(...)`
- the PostgreSQL UUID-LIKE workaround in the text-filter `Specification`:
  `cb.like(cb.concat(root.get("id").as(String.class), cb.literal("")), pattern)`

The text filter matches `id`, `lieferId`, `createdBy`, `inputFilename`, `notes`; paging goes through
`findPage(spec, pageable)` from `JobPagingRepository` (JOINED-inheritance-safe).

**`StmIfasAuditEvents`** (`ifas-domain-stm/.../domain/stm/audit/`) — add two constants alongside the
existing pair: `ISIN_ANFORDERUNGSLISTE_UPLOADED_MANUALLY`, `ISIN_ANFORDERUNGSLISTE_NOTES_CHANGED`.

### 4. File-type check

`support-libs/core-support/.../core/io/FileTypes.java` — add, matching the shape of the neighbours
but extension-only (browsers send `application/octet-stream` for `.isin`, so a content-type arm would
be dead weight and a `text/plain` arm would wrongly accept `.txt`):

```java
public static boolean isIsinFile(@Nullable String fileName) {
    return fileName != null && fileName.toLowerCase(Locale.ROOT).endsWith(".isin");
}
```

`SteuerMeldungBundles.isIsinAnforderungslisteFile(Resource)` already exists and agrees on the `.isin`
extension, but it needs a `Resource` — the controller only has a `MultipartFile`, hence the
`FileTypes` helper.

### 5. Controllers — `ifas-web/ifas-web-ui/.../web/stm/`

The package matches the UI navigation group, per the project convention.

`IsinAnforderungslisteFormPageController` — `@RequestMapping("/isin-anforderungsliste")`

- `GET` → `isin-anforderungsliste-form`; with `?jobId=`, load via the query service and expose
  `submittedJob`, else `errorMsg`
- `POST /upload` with `MultipartFile[] files`, `lieferant`, `stichtag`
  (`@DateTimeFormat(iso = DATE)`), `notes`. Validate: non-empty array, non-blank `lieferant`, no
  empty file, `FileTypes.isIsinFile(...)` per file — German error texts via `renderError`. Then
  `stichtag != null ? stichtag : LocalDates.nowInVienna()`,
  `AuthUsers.getCurrentWebUiUser(request)`, one `submitFromWebUi` call per file inside one
  `tx.doTransactional(...)`. One job → `redirect:/ui/isin-anforderungsliste?jobId=<uuid>`;
  several → `redirect:/ui/isin-anforderungslisten`

`IsinAnforderungslisteListPageController` — `@RequestMapping("/isin-anforderungslisten")`, plus the
three bulk `@PostMapping`s using `redirectAttributes.addFlashAttribute("successMsg"/"errorMsg")`.
Model attributes as in `StmCalcListPageController`: `page`, `jobs`, `inputFilenames`, `textFilter`,
`statusFilter`, `keyDateFilter`, `archivedFilter`, `currentSort`.

`IsinAnforderungslisteDetailPageController` — `@RequestMapping("/isin-anforderungslisten")` with
`GET /{id}`, `/{id}/input-file`, `/{id}/result-file`, `POST /{id}/notes`, `/{id}/archive`,
`/{id}/unarchive`. Resolve file metadata through `filestore.getMetainfo(...)` and link the work-queue
item the way the STM detail page does — reading the constant off the entity, not a string literal:

```java
workQueueService.findItemByTaskTypeAndPayloadContaining(
        IsinAnforderungslisteJob.WQ_TASK_TYPE, job.getId().toString()
).ifPresent(wqItem -> model.addAttribute("workQueueItemId", wqItem.getId()));
```

Commit `719085cea` fixed two silently-dead links caused by hardcoding those constants — don't
reintroduce that.

### 6. Templates — `ifas-web/ifas-web-ui/src/main/resources/templates/`

There are no message bundles in this project; all labels are hardcoded German in the templates, so
nothing to touch under `resources/*.properties` (and therefore no ISO-8859-1 re-encoding hazard).
Each page opens with `th:replace="~{layout :: layout( ~{::title/text()}, ~{::section} )}"` and a
`<title>` that doubles as the page heading.

- `isin-anforderungsliste-form.html` from `stm-calc-form.html` — title `IFAS - Neue ISIN
  Anforderungsliste`; fields Lieferant (default `oekb`), Stichtag (defaults to today), Notizen,
  `<input type="file" name="files" accept=".isin" multiple required>`; the tooltip should state
  `.isin` and the `${@global.maxFileSize}` cap. Submit button "Hochladen und verarbeiten".
- `isin-anforderungsliste-list.html` from `stm-calc-list.html` — title `IFAS - ISIN
  Anforderungslisten`; "Neue ISIN Anforderungsliste" button linking to `/ui/isin-anforderungsliste`;
  filter form, sortable headers, clickable rows, bulk-action bar and the inline JS all carry over
  with the route strings swapped. **The status dropdown must list `DefaultJobStatus`'s five values**
  (PENDING, PROCESSING, COMPLETED, FAILED, CANCELLED) — no `WAITING_FOR_START_OF_DAY`, which is
  `StmCalcJobStatus`-only and also appears in the row-checkbox guard, so that condition simplifies.
  Reuse `fragments/pagination` with its 11-argument positional signature.
- `isin-anforderungsliste-detail.html` from `stm-calc-detail.html` — title `IFAS - ISIN
  Anforderungsliste Details`; metadata card (ID, Status, Status-Nachricht, Stichtag, Liefer-ID,
  Hochgeladen/Gestartet/Beendet, Erstellt von, Notizen with inline edit, Work-Queue link), Input-Datei
  card, Ergebnis-Datei card, archive/unarchive buttons. Same simplification of the
  `WAITING_FOR_START_OF_DAY` guard on the archive button.

### 7. Auth + menu

`ifas-web/ifas-web-core/.../auth/IfasRight.java` — new constant under the *Menu: "Steuermeldungen"*
comment block, same authorities as `STEUERMELDUNGEN`. Each surface needs the bare path **and**
`/**`, because Spring Security 6.5's `PathPatternRequestMatcher` does not treat `/foo/**` as matching
bare `/foo`:

```java
ISIN_ANFORDERUNGSLISTEN(List.of(IFAS_INTRA_USER, IFAS_INTRA_SYSTEMSUPPORT),
        "/ui/isin-anforderungslisten", "/ui/isin-anforderungslisten/**",
        "/ui/isin-anforderungsliste", "/ui/isin-anforderungsliste/**"),
```

`IfasSecurityConfig` loops the enum, so no separate security wiring is needed.

`WebUiAuthorization.java` — add the leaf and OR it into the group:

```java
public boolean canAccessStm() {
    return canAccessSteuermeldungen() || canAccessIsinAnforderungslisten();
}
public boolean canAccessIsinAnforderungslisten() { return has(IfasRight.ISIN_ANFORDERUNGSLISTEN); }
```

`templates/layout.html` — inside the STM `<ul class="dropdown-menu">` (after line 34):

```html
<li th:if="${@webUiAuth.canAccessIsinAnforderungslisten()}"><a class="dropdown-item" th:href="@{/ui/isin-anforderungslisten}">ISIN Anforderungsliste</a></li>
```

and extend the STM group's `th:classappend` (line 29) with
`or @navigationState.activePage == 'isin-anforderungslisten'`, the way the Testen group ORs its keys.

Note `WebUiAuthorization`'s Javadoc constraint: `@webUiAuth` calls are legal in `th:if` but **not**
in `th:href`/`th:action`/`th:replace` — the markup above respects that.

### 8. Cross-links for the new job type

- `web/system/WorkQueuePageController.java#addPayloadLinks` — new branch on
  `IsinAnforderungslisteJob.WQ_TASK_TYPE` setting `isinAnforderungslisteJobId`
- `templates/work-queue-detail.html` — matching `<dt>/<dd>` row linking to
  `/ui/isin-anforderungslisten/{id}` (model the block on the existing `isinAnforderungDiffJobId` rows
  at lines 137–140, and keep the two labels distinguishable: the diff row reads
  "ISIN-Anforderungsliste:" today, so relabel it "ISIN-Anforderungsliste Diff:")
- `templates/job-detail.html` — add `'IsinAnforderungsliste'` to the `jobType` guard at line 194 and
  a deep link next to the existing ones. Careful: the guard compares whole strings, so
  `'IsinAnforderungsliste'` and `'IsinAnforderungslisteDiff'` don't collide — but the two `th:if`
  arms must test equality, not `startsWith`.
- `docs/Technische Konzepte/jobs-and-workqueue.md` — add `ISIN_ANFORDERUNGSLISTE` to the Jobs table
  (it currently lists only the Diff job)

## Out of scope

The two TODOs inside `IsinAnforderungslisteJobExecutionService` stay as they are — NetApp archiving
(`ArchiveType.ISIN_ANFORDERUNG` is configured but unreferenced), the result mail, and the MFT
push-back to the Lieferant's `receive` directory. Likewise untouched: the `@Deprecated`
`IsinAnforderungslistenBatchJob` whose scheduled handler is still an empty `log.warn`, and the
unqueried `lieferanten.isin_sonderauswertung` flag. This change makes the job reachable by hand; it
does not build the batch automation.

## Verification

```bash
mvn clean install -Pno-proxy -Pdev-build
```

Auth guard tests parameterise over `IfasRight`, so the new right is picked up automatically —
confirm `IfasRightTest`, `IfasSecurityConfigAuthorizationTest` and `SecurityCsrfTest` stay green.
`IsinAnforderungslisteJobExecutionServiceTest` must still pass after the `submit(...)` signature
change (it calls the 4-argument form).

Then run the app from the IDE via `LocalH2OnlyIfasApplication` and walk it end to end at
http://localhost:8080/ifas-uat:

1. **STM → ISIN Anforderungsliste** appears below *Steuermeldungen*; the STM group highlights as
   active on the new page.
2. "Neue ISIN Anforderungsliste" → upload a `.isin` file. No sample exists in the repo, so create
   one: semicolon-delimited, no header, windows-1252, columns `ISIN;DatumAB;DatumBIS` with dates as
   `yyyy.MM.dd` — e.g. `US0378331005` and `DE0005557508` on separate lines, as
   `IsinAnforderungslisteJobExecutionServiceTest` does. Name it `*.isin`.
3. Single upload lands on the confirmation view; a multi-file upload lands on the list.
4. Reject paths: no file, blank Lieferant, and a `.csv` file each render the form with a German
   error and no job created.
5. The job runs through the work queue to COMPLETED; the detail page offers the input file and the
   `#estb-result.zip`, whose four entries are `_EStB.csv`, `_EStB_erweitert.csv`, `_error.log`,
   `_info.log`. Against an empty H2 the ISINs are unknown — the report still completes and the error
   log notes them, which is the expected outcome.
6. Notizen inline edit persists; archive → the row leaves the default list and appears under
   *Archiviert*; bulk unarchive and bulk delete behave as on Steuermeldungen.
7. **System → Work Queue** → the item's detail page links back to the Anforderungsliste page, and
   **System → Aufgaben** → the job's generic detail page shows the deep link.
