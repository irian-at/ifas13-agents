---
name: headless-launch-devtools-npe
description: "Launching a Local*IfasApplication via bare `java -cp` needs -Dspring.devtools.restart.enabled=false, else every DB access NPEs"
metadata: 
  node_type: memory
  type: project
  originSessionId: c0af06a5-1928-49d3-87de-525dee7e7658
  modified: 2026-09-04T10:45:49.928Z
---

Running a `Local*IfasApplication` test launcher outside the IDE (bare `java -cp <test-classes:classes:deps>`)
starts and serves, but **every** database access throws
`NullPointerException: Cannot invoke "DatabaseChildContextRegistry.getBean(...)" because "this.registry" is null`
at `SynchronizingTransactionManager.enrollDatabase` — the `/ui/` index 500s and `WorkQueueExecutor`
floods the log with "Error processing retries" every 5s. Adding
`-Dspring.devtools.restart.enabled=false` fixes it completely (0 NPEs).

**Why:** spring-boot-devtools is on the runtime classpath, and its restart classloader leaves the
multidbctx `registry` unset on the beans the restarted context actually uses. IntelliJ run
configurations don't hit this, so it looks like a code bug when it is purely a launch artifact.

**How to apply:** when starting the app headlessly (agent verification, screenshots, smoke tests),
always pass `-Dspring.devtools.restart.enabled=false`, and add `--server.port=<n>` to avoid
colliding with an instance already on 8080. Don't chase the NPE stack trace — no frames in it
belong to application code. See [[project-recalc-historical-fidelity]] for other launcher notes.

**Full recipe** from `ifas-applications/ifas-main-application` after `mvn install -DskipTests`:

```bash
mvn -Pdev-build dependency:build-classpath -Dmdep.outputFile=<tmp>/cp.txt -Dmdep.includeScope=test
mvn -o -Pdev-build test-compile
java -Dspring.devtools.restart.enabled=false \
     -cp "target/test-classes:target/classes:$(cat <tmp>/cp.txt)" \
     at.oekb.ifas.app.LocalH2OnlyIfasApplication
```

Ready when the log says `Started LocalH2OnlyIfasApplication in`; H2 comes up with the Stammdaten
already loaded (all 316 Lieferanten), so no import step is needed for read-only checks.

**POSTing to the UI with curl** needs the CSRF token *and* the session cookie — the token is in the
`<meta name="_csrf" content="...">` tag `layout.html` renders, and it is only valid for the session
that fetched it: `curl -c jar <page>`, scrape the meta, then `curl -b jar -F "_csrf=$TOKEN" ...`.
CSRF is disabled for `/api/**` only, never for `/ui/**`.
