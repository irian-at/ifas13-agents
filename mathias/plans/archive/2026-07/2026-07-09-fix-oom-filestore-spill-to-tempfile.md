# Fix OOM in STM Recalc: spill filestore ZIP to a temp file (consumer A)

## Context

Production threw `OutOfMemoryError: Java heap space` during an STM recalculation bundle
job. The trace surfaces in `CsvSteuerMeldungen.validateAndTransformCsvMessages:140`
(`validationMsgCollector.addAll(...)`), but that frame is the **victim**, not the cause —
it's an ordinary `ArrayList` grow that failed because free heap was already exhausted by
memory **retained elsewhere in the same job**.

Two unbounded-in-input consumers overlap in time:

- **A (root, chosen fix):** `DatabaseFilestore.store(key, Consumer<OutputStream>, ...)`
  (`DatabaseFilestore.java:49-54`) allocates a single `ByteArrayOutputStream` and hands it
  to the recalc lambda. The lambda loops over **all** bundles
  (`StmRecalcJobExecutionService.java:168`), writing every bundle's ZIP entries into that
  one heap buffer. It grows with the *entire* recalc output and is only drained after the
  loop at `buffer.toByteArray()` (`:52`) — which allocates a **second** full copy
  (peak ≈ 2× total ZIP size). A prior OOM fix (comment at `:156-158`) stopped retaining
  `BundleRecalculationResult` objects but left the ZIP itself fully in heap.
- **B:** the current bundle's input CSV is fully materialized (`CsvFile.messages` +
  `validationMsgCollector`, N rows × K msgs). This is where the allocation happened to fail.

Peak heap = `[ZIP buffer for all bundles so far] + [current bundle's CSV + recalc working set]`.
Removing A's in-heap buffer breaks the collision.

**Persistence constraint:** `FilestoreEntry.content` (`FilestoreEntry.java:27-30`) is a
plain `byte[]` column (`@JdbcTypeCode(Types.BINARY)`), so the DB insert inherently needs the
whole file as one `byte[]`. We cannot stream to the DB without an entity/schema change (out
of scope). But we can move the *generation* buffer off-heap to a temp file, so the full
`byte[]` is only materialized once — after the recalc/CSV working set is GC-eligible.

## Change

The spill *mechanism* is generic and must not live in `DatabaseFilestore` (that class is
about DB storage). What legitimately stays there is the **transaction boundary** (a DB
concern). So: extract the disk-spill into a shared utility in `core-support`, and reduce
`DatabaseFilestore`'s override to a thin `@Transactional` delegation.

### 1. New utility — `support-libs/core-support/.../core/filestore/FilestoreStreams.java`

Generic helper that adapts a streaming producer into any byte-oriented `Filestore` using a
temp file as an off-heap buffer:

```java
@UtilityClass @Slf4j @NullMarked
public final class FilestoreStreams {

    /**
     * Store a streaming producer into a byte-oriented {@link Filestore} without buffering
     * the whole payload on the heap: the producer writes to a temp file, which is then
     * handed to {@code store.store(key, resource)} and deleted afterwards.
     */
    public static URI storeViaTempFile(Filestore store, String key,
            Consumer<OutputStream> outputStreamConsumer, String filename, MimeType contentType) {
        Path tempFile;
        try {
            tempFile = Files.createTempFile("ifas-filestore-spill-", ".tmp");
        } catch (IOException e) {
            throw new IllegalStateException("Cannot create spill temp file for key " + key, e);
        }
        try {
            try (OutputStream out = new BufferedOutputStream(Files.newOutputStream(tempFile))) {
                outputStreamConsumer.accept(out);
            } catch (IOException e) {
                throw new IllegalStateException("Cannot write spill temp file for key " + key, e);
            }
            return store.store(key, NamedContentTypeResource.of(new PathResource(tempFile), contentType, filename));
        } finally {
            try {
                Files.deleteIfExists(tempFile);
            } catch (IOException e) {
                log.warn("Failed to delete spill temp file {} for key {}", tempFile, key, e);
            }
        }
    }
}
```

`store.store(key, resource)` is the byte-oriented overload; for `DatabaseFilestore` it runs
`getContentAsByteArray()` (one materialization) → `storeBytes`.

### 2. `DatabaseFilestore.java` — thin `@Transactional` delegation

Replace the `ByteArrayOutputStream`-buffering override (`:48-54`) with:

```java
@Override @Transactional
public URI store(String key, Consumer<OutputStream> outputStreamConsumer, String filename, MimeType contentType) {
    return FilestoreStreams.storeViaTempFile(this, key, outputStreamConsumer, filename, contentType);
}
```

Drop the now-unused `import java.io.ByteArrayOutputStream;` (keep `OutputStream` — used by
`write(...)`; keep `Consumer`). The class no longer contains any buffering/temp-file logic —
only the transaction boundary, which is where it belongs.

### 3. `TempDirFilestore.java` — unchanged

It already overrides `store(Consumer)` to stream natively to its own dir, so it never hits
the helper. `Filestore.store(key, Consumer, ...)` stays abstract.

### Why keep a `@Transactional` override rather than remove it entirely

Moving the method out of `DatabaseFilestore` (e.g. an interface `default`) would drop the
`@Transactional`: Spring's proxy wouldn't wrap it the same way, and the self-invoked
byte-oriented `store` would bypass its own `@Transactional`, breaking the atomic
delete+save in `storeBytes`. A thin `@Transactional` override on `DatabaseFilestore` keeps
the tx active while the *mechanism* lives in `FilestoreStreams`. The nested
`store(key, resource)` call runs in that same ambient tx.

### Notes / decisions

- **Why a temp file, not `TempDirFilestore` as a buffer / `AutoCleanupTempFiles`:**
  `TempDirFilestore` allocates a *directory* per instance and never cleans it except
  `deleteOnExit`, so a per-call instance would leak dirs until JVM exit. `AutoCleanupTempFiles`
  binds deletion to the *returned object's* GC (`Cleaner`) + `deleteOnExit`; we return a
  long-lived `URI`, so temp files would linger. A single temp file with `deleteIfExists` in
  `finally` is deterministic and simplest.
- **Reused, not reinvented:** `NamedContentTypeResource.of(Resource, MimeType, filename)` +
  `PathResource` already wrap a file as a resource (same pattern `TempDirFilestore` uses),
  and the byte-oriented `Filestore.store(key, resource)` already exists — the helper just
  composes them.
- **Behaviour preserved:** content fully written, then stored; only the buffer moves from
  heap to disk. Heap during generation holds just the `BufferedOutputStream` window; the
  full `byte[]` is materialized once by `getContentAsByteArray()` *after* the consumer
  returns and the producer's (recalc/CSV) working set is GC-eligible.
- **Callers unchanged:** all `store(Consumer<OutputStream>)` callers
  (`StmRecalcJobExecutionService:163`, `StmCalcJobExecutionService:136`,
  `EstbReportDiffJobExecutionService:129`, `FristenpruefungService:44`,
  `JobAutoNotificationService:60`, `Stm(Re)calcJobSubmissionService`) benefit automatically.
- Conforms to conventions: explicit types (no `var`), `IOException` → `IllegalStateException`
  with context, `@Slf4j`, `@UtilityClass`, plural utility-class name, `@NullMarked`.

### Residual limits (call out, do not fix here)

- A single delivery whose output ZIP alone exceeds `-Xmx` still can't be stored (byte[]
  column floor). True streaming needs an entity/schema change — separate effort.
- `store` is `@Transactional`, so the DB tx stays open for the whole generation
  (pre-existing). Could be shortened by generating outside the tx, but that's a caller-level
  change — out of scope.

## Verification

- **Unit/integration:** `DatabaseFilestoreIntegrationTest` (writes via the `Consumer`
  overload) must still pass and round-trip content. Add/confirm a case with a multi-MB
  payload asserting stored bytes equal written bytes.
  Run: `mvn test -Pno-proxy -pl ifas-services/ifas-main-service -Dtest=DatabaseFilestoreIntegrationTest`
  (add `-Pskip-postgres15-tests -Pskip-sybase16-tests` if Docker is unavailable).
- **Repro:** run a large multi-bundle recalc under a constrained `-Xmx` — OOMs before the
  fix, completes after. Optionally compare heap dumps: the `ByteArrayOutputStream` retained
  set in `DatabaseFilestore` should be gone.
- **Full build:** `mvn clean install -Pno-proxy`.
