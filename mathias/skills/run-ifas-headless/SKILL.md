---
name: run-ifas-headless
description: Launch a Local*IfasApplication test launcher from the command line (outside IntelliJ) and drive it with curl — for smoke tests, screenshots and UI checks. Use when asked to run or start the IFAS13 app headlessly or to verify a change against the running app.
---

# Run IFAS13 headless

The runnable launchers are **test-source** classes in `ifas-applications/ifas-main-application`
(`at.oekb.ifas.app.Local*IfasApplication`; `.claude/CLAUDE.md` lists the DB combinations). Outside
IntelliJ they must run on the test classpath, and spring-boot-devtools must be switched off.

## Recipe (H2 only, no prerequisites)

After `mvn install -DskipTests -Pno-proxy` of the repo, from `ifas-applications/ifas-main-application`:

```bash
mvn -Pno-proxy -Pdev-build dependency:build-classpath -Dmdep.outputFile=<scratch>/cp.txt -Dmdep.includeScope=test
mvn -o -Pno-proxy -Pdev-build test-compile
java -Dspring.devtools.restart.enabled=false \
     -cp "target/test-classes:target/classes:$(cat <scratch>/cp.txt)" \
     at.oekb.ifas.app.LocalH2OnlyIfasApplication --server.port=<n>
```

- Ready when the log says `Started LocalH2OnlyIfasApplication in`. H2 comes up with the Stammdaten
  loaded (all 316 Lieferanten) — no import step for read-only checks.
- `--server.port=<n>` avoids colliding with an instance already on 8080. Base URL
  `http://localhost:<n>/ifas-uat`.
- Run it in the background and tail its log; stop the process when done.

## `-Dspring.devtools.restart.enabled=false` is mandatory

Without it the app starts and serves, but **every** database access throws
`NullPointerException: Cannot invoke "DatabaseChildContextRegistry.getBean(...)" because "this.registry" is null`
at `SynchronizingTransactionManager.enrollDatabase`; `/ui/` answers 500 and `WorkQueueExecutor` logs
"Error processing retries" every 5 s. devtools' restart classloader leaves the multidbctx `registry`
unset on the beans the restarted context uses. IntelliJ run configurations never hit this. No frame of
that stack trace is application code — do not chase it.

## POSTing to the UI with curl

CSRF is disabled for `/api/**` only. A `/ui/**` POST needs the token *and* the session cookie that
fetched it: `layout.html` renders `<meta name="_csrf" content="...">`, valid for that session only.

```bash
curl -s -c jar http://localhost:<n>/ifas-uat/ui/<page> | grep -o '_csrf" content="[^"]*' | cut -d'"' -f3 > token
curl -s -b jar -F "_csrf=$(cat token)" -F "file=@<path>" http://localhost:<n>/ifas-uat/ui/<action>
```

## Other launchers

`LocalPostgresOnlyIfasApplication` etc. need the docker-compose services from
`ifas-applications/ifas-main-application` (`docker-compose up postgres` / `sybase16` / `mailhog`).
Same recipe, swap the main class.
