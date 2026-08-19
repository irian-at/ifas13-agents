# Fix: Work-Queue link missing on the ISIN-Anforderungsliste job detail page

## Context

On the **STM ISIN Anforderungsliste** detail page (`/ui/estb-report-diffs/{id}`, nav entry
"STM ISIN Anforderungsliste") the "Work Queue:" row that links to the work-queue item which
executed the job never appears. The STM Rekalkulation detail page (`/ui/stm-recalculations/{id}`)
shows the same row correctly.

The markup is *not* the problem — both templates already carry an identical row:

```html
<tr th:if="${workQueueItemId != null}">
    <th>Work Queue:</th>
    <td><a th:href="@{/ui/work-queue/{id}(id=${workQueueItemId})}"><code th:text="${workQueueItemId}"></code></a></td>
</tr>
```
`estb-report-diff-detail.html:206-213` vs. `stm-recalc-detail.html:228-235`.

The model attribute `workQueueItemId` is simply never populated, because the controller looks the
work-queue item up under a **stale task type**:

- `IsinAnforderungDiffDetailPageController.java:97-99` passes the string literal `"ESTB_REPORT_DIFF"`.
- The task type was renamed to `ISIN_ANFORDERUNGSLISTE_DIFF`
  (`IsinAnforderungslisteDiffJob.java:27`), and migration
  `postgres15/V046__job_type_migration.sql` rewrote every existing `work_queue_items.task_type`
  row from `ESTB_REPORT_DIFF` to the new value.
- Therefore `WorkQueueService.findItemByTaskTypeAndPayloadContaining(...)` never matches and the
  `ifPresent(...)` branch never runs.

`StmRecalcDetailPageController.java:116-118` does the same lookup but references the constant
`StmRecalcJob.WQ_TASK_TYPE` instead of a literal, which is why it kept working across the rename.
`StmCalcDetailPageController.java:80-82` also uses the constant. The literal in the ISIN
controller is the only remaining occurrence of `ESTB_REPORT_DIFF` in Java code.

Intended outcome: the Anforderungsliste detail page shows the Work-Queue link exactly like the
recalc page, and the stale literal can no longer drift again.

## Change

**File:** `ifas-web/ifas-web-ui/src/main/java/at/oekb/ifas/web/testing/IsinAnforderungDiffDetailPageController.java`

Replace the hard-coded task type with the entity constant (the class already imports
`IsinAnforderungslisteDiffJob`, line 9):

```java
// work queue item link
workQueueService.findItemByTaskTypeAndPayloadContaining(
        IsinAnforderungslisteDiffJob.WQ_TASK_TYPE, estbReportDiffJob.getId().toString()
).ifPresent(wqItem -> model.addAttribute("workQueueItemId", wqItem.getId()));
```

No template change, no service change, no migration. `JobService.submitToWorkQueue`
(`JobService.java:46-66`) stores a `JobPayload(job.getId())`, so the payload-substring match on
the job UUID already resolves once the task type is right — this is the same mechanism the recalc
page relies on.

## Out of scope (noted, not changed)

`WorkQueuePageController.addPayloadLinks` (`WorkQueuePageController.java:232-244`) only
special-cases `STM_RECALCULATION` and `STM_CALCULATION`; an ISIN-Anforderungsliste-Diff item falls
into the generic `else` branch and its reverse link points at `/ui/jobs/{id}` rather than
`/ui/estb-report-diffs/{id}`. That reverse direction still works, so it is left alone unless you
want it included.

## Verification

1. Build the module: `mvn -Pno-proxy -Pdev-build clean install -pl ifas-web/ifas-web-ui -am -DskipTests`
2. Start `LocalH2OnlyIfasApplication` (test launcher, from the IDE) and open
   http://localhost:8080/ifas-uat
3. Navigate *STM ISIN Anforderungsliste* → submit a diff job (or open an existing one).
4. On the detail page confirm the **Work Queue:** row renders with the item UUID, and that the
   link opens `/ui/work-queue/{id}` showing a work-queue item with task type
   `ISIN_ANFORDERUNGSLISTE_DIFF` whose payload `jobId` equals the job id from the detail page.
5. Cross-check a recalc detail page still behaves identically (no regression, unchanged code).

There are currently no automated tests for these page controllers, so verification is manual.
