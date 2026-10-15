---
name: run-tests
description: Run the ifas13 tests affected by the current changes - only the changed modules and their dependents, integration tests narrowed to the ones that reach a change, Postgres and Sybase only for database-relevant changes. Use whenever tests must run in ifas13 (verifying a change or a chunk, one test class or method, a module) instead of composing mvn test commands by hand.
---

# Run ifas13 tests

`affected_tests.py` (next to this file) plans the cheapest test run that still covers the change, and
runs it. Call it from the ifas13 checkout or a worktree of it. Without `--run` it only prints the plan
(about a second, no Maven).

```bash
T=.claude/skills/personal-mathias-run-tests/affected_tests.py
python3 $T                                     # plan: working tree vs HEAD
python3 $T --run --log <scratchpad>/tests.log  # run it, print a summary of the surefire reports
```

| Situation | Arguments |
|---|---|
| Iterate on one class or method | `--test PreisVersionJobTest`, `--test 'PreisVersionJobTest#givenX_whenY_thenZ'` (repeatable) |
| All tests of a module | `--module ifas-domain/ifas-domain-fondspreise` |
| Committed chunk(s), not just the working tree | `--base HEAD~2`, `--base origin/master` |
| Every integration test of the affected modules | `--no-narrow` |
| Force the databases | `--dbs all` / `--dbs h2` |
| Coverage report needed | `--coverage` (keeps the JaCoCo agent) |
| Everything | `--all` |

## What the plan decides

- **Modules**: modules owning a changed file under `src/` or a changed `pom.xml`, plus every module
  depending on them (all scopes). A changed aggregator pom affects its children; a changed root
  `pom.xml` or `.mvn/` runs the whole reactor. Files outside `src/` (docs, notes) are ignored.
- **Tests**: every test class of an affected module, except in `ifas-integration-tests` and
  `ifas-integration-tests-multidbctx` (≈15 min together): there only the test classes that reach a
  changed class through a chain of references (import or same package, plus the name in the source)
  run. All of them run when a change has no reference trail - Spring wiring (`@Configuration`,
  aspects, `*Config*`, `DatabaseContext*`), shared test infrastructure (`integrationtest/`,
  `core-test-support`, `multidbctx-support`), Flyway, a pom, an unreferenced resource - or when more
  than 70 % are reached anyway.
- **Databases**: H2 only, unless a change is database-relevant: `ifas-database/**`, repositories,
  entities, SQL, migrations, DB routing, JPA/JDBC tokens (`@Query`, `@Column`, `nativeQuery`,
  `JdbcTemplate`, ...) in the diff, or a database dependency in a pom. The plan lists the reasons.
- **LibreOffice**: `@Tag("libreoffice-container")` tests only when recalc/workbook code changed.
- **Speed**: `-T 1C`, phase `test` (no packaging), no `clean`, JaCoCo agent off (`-DargLine=`),
  upstream modules compiled but their tests filtered out (`-Dtest=<FQN list>`).

## Rules

- Read the plan before `--run`; it is the record of what was and was not tested. Put its module lines
  (`ifas-testing/ifas-integration-tests: 12/139 - narrowed ...`) into the report.
- A run that includes many integration-test classes or Postgres/Sybase takes minutes: start it with
  `run_in_background` and wait for the notification. Single classes run in the foreground.
- Never two Maven builds in one checkout at the same time: they overwrite each other's `target/`; the
  script refuses (`--force` overrides). Other worktrees are fine for H2-only runs. Postgres and Sybase
  are reusable Testcontainers shared by every checkout and by IntelliJ, and the tests drop and truncate
  tables: never run database tests while another DB test run is active.
- Don't override a database-relevant plan with `--dbs h2` to save time unless Mathias asks.
- No `clean` by default. Clean the module (`mvn -Pno-proxy,dev-build -pl <module> clean`) only for stale
  output: deleted or renamed classes still found at runtime, or leftovers in `target/test-classes`.
- A failing run: the summary lists each failing test with the first line of its message. Details are in
  `<module>/target/surefire-reports/<class>.txt` and `<class>-output.txt`, the build output in the log.
  A summary saying "build failed before or outside the tests" is a compile, enforcer or forbiddenapis
  error: the `[ERROR]` lines are printed.

## Known environment problems

- `Could not find artifact jespa:jespa-jakarta` - the `dev-build` profile is missing.
- `ContainerFetchException ... ifas-libreoffice-recalc-server` (and `StmRecalcJobServicesTest` waiting
  two minutes) - the LibreOffice image was never built, because `-Pno-proxy` switches off
  `platform-amd64`. Build it once:
  `mvn -Pno-proxy,dev-build,platform-amd64 -pl ifas-testing/ifas-libreoffice-recalc-server-container generate-resources`
- Sybase tests fail to connect - `.env` with the Testcontainer credentials is missing at the repo root
  (the plan warns). Podman must be running (the plan checks the socket).

## Manual commands

For cases the script does not cover:

```bash
P=-Pno-proxy,dev-build,platform-amd64      # platform-arm64 on Apple Silicon
H2=,skip-postgres15-tests,skip-sybase16-tests
# one class, H2 only
mvn -B -T 1C $P$H2 -pl <module> -am test -Dtest=<Class> -Dsurefire.failIfNoSpecifiedTests=false -DargLine=
# one method
mvn -B -T 1C $P$H2 -pl <module> -am test -Dtest='<Class>#<method>' -Dsurefire.failIfNoSpecifiedTests=false -DargLine=
# the full reactor, all databases (what a commit should pass)
mvn -B -T 1C $P verify
```

## Reference timings (midgard, 16 threads, 2026-10-15)

| Run | sequential | `-T 1C` |
|---|---|---|
| compile only | 91 s | 49 s |
| full reactor, all DBs | 1305 s | 1114 s |
| full reactor, H2 only | 1031 s | 894 s |
| one integration-test class, H2 | 42 s | 32 s |

`ifas-integration-tests` alone takes ≈1000 s of a full run - narrowing it is where the time goes.
