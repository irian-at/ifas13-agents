# Fix MapStruct build error in `SteuerMeldungMapper`

## Context

`mvn` fails in `ifas-web-restapi`:

```
Unmapped source properties: "successStmCount, failedStmCount".
```

Commit `19b18903d` ("feat: track STM success and failure counts in calculation jobs") added
`successStmCount` / `failedStmCount` to `StmCalcJob`, and `9c5563d2d` surfaced them in the
Thymeleaf views — but neither commit touched the REST layer. `SteuerMeldungMapper` maps
`StmCalcJob` → `SteuerMeldungDocument.Data.Attributes` under
`unmappedSourcePolicy = ReportingPolicy.ERROR` with an explicit
`ignoreUnmappedSourceProperties` allow-list, so the two new entity getters have no target and
annotation processing aborts.

Outcome: the two counts become optional attributes of the `steuermeldungen` JSON:API resource,
consistent with how the sibling `recalculations` resource already exposes its
`fieldDiffErrors` / `logDiffErrors` / `fieldDiffWarnings` / `logDiffWarnings` counts.

## Change

**`ifas-web/ifas-web-restapi/src/main/java/at/oekb/ifas/rest/stm/SteuerMeldungDocument.java`**

Add two components to the `Data.Attributes` record, placed after `createdBy` and before
`notes` — matching the field order in
`recalc/RecalculationDocument.java:74-88`:

```java
@Schema(description = "Number of Steuermeldungen in the result bundle with a successful return status", requiredMode = Schema.RequiredMode.NOT_REQUIRED)
@Nullable
Integer successStmCount,
@Schema(description = "Number of Steuermeldungen in the result bundle that were rejected", requiredMode = Schema.RequiredMode.NOT_REQUIRED)
@Nullable
Integer failedStmCount,
```

No mapper change is needed: MapStruct resolves both by name from
`StmCalcJob.getSuccessStmCount()` / `getFailedStmCount()`, which clears the unmapped-source
error. `Attributes` already carries `@JsonInclude(JsonInclude.Include.NON_NULL)`, so both keys
are simply absent from the 202 upload response, where the counts are still null.

`SteuerMeldungDocument.Data.Attributes` has no constructor call outside the generated
`SteuerMeldungMapperImpl` (verified by grep across the repo), so widening the record breaks
nothing.

## Verification

```bash
mvn clean install -Pno-proxy -pl ifas-web/ifas-web-restapi -am -DskipTests
```

Then confirm the generated
`ifas-web/ifas-web-restapi/target/generated-sources/annotations/at/oekb/ifas/rest/stm/SteuerMeldungMapperImpl.java`
assigns both counts in `toJsonApiAttributes`, and run the full build:

```bash
mvn clean install -Pno-proxy -Pdev-build
```
