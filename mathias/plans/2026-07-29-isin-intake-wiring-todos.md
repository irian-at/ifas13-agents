# Add intake-wiring TODOs for IsinAnforderungslisteJob

## Context

The ISIN Anforderungsliste pipeline is now: **intake (missing) → `submit(...)` (exists) → execute (done) → result ZIP (done)**.

`IsinAnforderungslisteJobSubmissionService.submit(...)` has **no production caller** — nothing turns an
arriving `.isin` file into an `IsinAnforderungslisteJob`. The user wants both intake channels supported
eventually — **MFT delivery** and a **REST endpoint** — but for now only wants TODO markers placed at the
relevant point(s), not the actual wiring.

Findings that shape placement:
- **No inbound MFT mechanism exists anywhere in the codebase.** MFT is currently outbound-only
  (`StmCalcJobResultSender` POSTs results to `oekb.mft.stm-result-endpoint`). There is no MFT receiver /
  poller class to annotate.
- **No ISIN REST controller exists.** The REST intake analog is `SteuerMeldungRestController`
  (`ifas-web-restapi`, `@PostMapping(consumes=multipart/form-data)` → `stmCalcJobSubmissionService`). An ISIN
  endpoint would be a new sibling controller.
- Therefore both intakes are greenfield; the single guaranteed-relevant, feature-local anchor for both is the
  submission service itself. Scattering an ISIN TODO into the STM-specific controller would edit unrelated
  code for no functional benefit.

## Approach

Add a single structured Javadoc TODO block to **`IsinAnforderungslisteJobSubmissionService`**
(`ifas-services/ifas-main-service/src/main/java/at/oekb/ifas/service/isinanforderung/IsinAnforderungslisteJobSubmissionService.java`),
at class level, documenting that `submit(...)` currently has no production trigger and enumerating the two
intake paths to be wired later — each of which will call `submit(lieferId, inputIsinResource, stichtag, createdBy)`:

```java
/**
 * ...existing summary...
 *
 * <p>TODO(intake): {@link #submit} has no production trigger yet. Two intake channels are to be wired,
 * both ending in a {@code submit(...)} call:
 * <ul>
 *   <li><b>REST endpoint</b> — add an ISIN Anforderungsliste upload controller in {@code ifas-web-restapi},
 *       analogous to {@link at.oekb.ifas.rest.stm.SteuerMeldungRestController} (multipart {@code FILE} +
 *       supplier/Stichtag), delegating to {@code submit(...)}.</li>
 *   <li><b>MFT delivery</b> — ingest {@code .isin} files delivered via MFT and call {@code submit(...)}.
 *       No inbound MFT mechanism exists yet (MFT is currently outbound-only, see
 *       {@code StmCalcJobResultSender} / {@code oekb.mft.*}); a receiver/poller must be introduced.</li>
 * </ul>
 */
```

Rationale for one location: it is the shared entry point a developer wiring *either* channel will land on,
it keeps the change inside the ISIN feature, and it accurately records that the MFT-inbound side needs a new
mechanism rather than pointing at a file that does not exist.

## Files

- **Edit (comment only):** `ifas-services/ifas-main-service/.../isinanforderung/IsinAnforderungslisteJobSubmissionService.java`
  — add the class-level Javadoc TODO block. No code/behavior change.

## Verification

- `mvn compile -Pno-proxy -pl ifas-services/ifas-main-service` — confirms the Javadoc still compiles (comment-only change; low risk).
- Grep check: `grep -n "TODO(intake)" ...IsinAnforderungslisteJobSubmissionService.java` shows the marker is present.
