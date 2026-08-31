# Make the Sybase invocations run in IntelliJ

## Context

`TemporalTypeRoundtripTest` uses `TEST_WITH_ALL_DATABASE_SYSTEMS`, which should produce 12
invocations (4 methods × H2 / PostgreSQL / Sybase). From the CLI it does — verified green, 12/12,
including the ASE wall-clock output. In IntelliJ only **8 appear and the run is green**: the Sybase
invocations are absent, not failing.

Absent-and-green has exactly one cause in this harness. `MultiDatabaseExtension` filters profiles
out of the map *before* any invocation exists:

```java
testSpringProfiles.stream().filter(profile -> !isIgnored(profile))
// isIgnored: System.getProperty("ignore-test-dbms-" + mainDbProfile, "false")
```

A failing context produces errors; only this filter produces silent absence. So
`ignore-test-dbms-sybase-testcontainer` is being set in the IDE's test JVM.

**What I could not determine:** where it comes from. Confirmed *not* the source:

- `.idea/misc.xml` — `skip-sybase16-tests` is correctly in `disabledProfiles` now, and
  `MavenImportPreferences.explicitlyEnabledProfiles` is down to `no-proxy,platform-amd64`
- no `VM_PARAMETERS` anywhere in `.idea/`, no JUnit template overriding them
- no `ignore-test-dbms` string in `.idea/` or in `~/.config/JetBrains/*/options/`
- no `activeProfiles` in `~/.m2/settings.xml`; `MAVEN_OPTS` is only `-Xmx16g -XX:+TieredCompilation`
- no `.mvn/maven.config`, no `junit-platform.properties`
- all four profiles in `ifas-testing/ifas-integration-tests/pom.xml` that set the property are
  `activeByDefault=false`

The run configuration is `type="JUnit"` (IntelliJ's own runner, not delegated Maven). The likely
remaining mechanism is that IntelliJ applies the surefire `systemPropertyVariables` from its
**imported** Maven model to JUnit run configurations, and that model is stale — it still carries
`skip-sybase16-tests` from before the profile was disabled. I have not proven this, so the plan
leads with the cheap fix for it and then applies an override that works regardless of the mechanism.

Scope per your choice: **IDE-only, no repo change.** Both files involved are gitignored
(`.idea/.gitignore:3` for `workspace.xml`, `.gitignore:113` for `misc.xml`), so nothing reaches the
repo. `SybaseTestcontainer` is left alone.

## Steps

### 1. Re-enable `dev-build` (unrelated regression, fix first)

Disabling `skip-sybase16-tests` also moved **`dev-build`** into `disabledProfiles`. Per CLAUDE.md
that profile excludes the transitive `jespa:jespa-jakarta`, which cannot resolve from Maven Central,
so IDE Maven import will start failing on `oekb-auth-support` and everything downstream of it.

In `.idea/misc.xml`, move `dev-build` back from `disabledProfiles` to `enabledProfiles` (or tick it
in the Maven profiles panel). Leave `skip-sybase16-tests` disabled.

### 2. Reload the Maven project

**Maven tool window → Reload All Maven Projects.** If the stale-imported-model theory is right, this
alone restores the Sybase invocations, because the re-resolved effective POM no longer contains the
surefire `ignore-test-dbms-sybase-testcontainer` entry.

Rerun the test. If 12 invocations appear, stop here — steps 3 and 4 are unnecessary.

### 3. If still 8: override the property explicitly

`isIgnored` treats only the literal string `false` as "do not ignore":

```java
boolean ignore = !System.getProperty(name, "false").equalsIgnoreCase("false");
```

So setting it explicitly to `false` defeats the filter no matter who else sets it. Add to the
**VM options** of the `TemporalTypeRoundtripTest` run configuration, and to
**Run/Debug Configurations → Edit configuration templates → JUnit** so new configurations inherit it:

```
-Dignore-test-dbms-sybase-testcontainer=false -Dignore-test-dbms-postgres-testcontainer=false
```

This is the guaranteed fix and does not depend on diagnosing IntelliJ's import behaviour.

### 4. Pin the working directory so `.env` resolves

Once Sybase actually starts, it needs the four `SYBASE_TESTCONTAINER_*` keys.
`ifas-testing/ifas-integration-tests/src/test/resources/application.properties:61` sets
`springdotenv.directory=../..`, resolved by `dotenv-java` **relative to the process working
directory**, and a missing file is silently ignored (`ignoreIfMissing`) — so a wrong CWD yields null
credentials and a misleading `Container is started, but cannot be accessed` plus an NPE, with no
warning about the `.env`.

The run configuration currently specifies **no** `WORKING_DIRECTORY`. Set it explicitly on the
configuration and on the JUnit template:

```
$MODULE_WORKING_DIR$
```

For this Maven module that is `ifas-testing/ifas-integration-tests`, so `../..` lands on the repo
root where `.env` now lives. Verified: `/home/sma/dev/projects/.env` does **not** exist, which is
what a project-root CWD would look for.

### Editing mechanics

Run configurations and the JUnit template live in `.idea/workspace.xml`, which IntelliJ holds in
memory and rewrites on save/exit — external edits made while it is running get clobbered. So either
do steps 3 and 4 through the IDE UI, or **close IntelliJ first** and I will edit `workspace.xml`
directly. Step 1 (`misc.xml`) is safe for me to edit either way, though a reload is still needed for
it to take effect.

## Verification

In the IntelliJ test tree, expect **12** invocations, with the third context per method labelled:

```
Context 'sybase-testcontainer'
```

and this line in the console, which only the Sybase run can produce:

```
stored wall clocks on ASE: ts_offset=2024-07-15 12:34:56 ts_local=2024-07-15 14:34:56 ts_zoned=2024-07-15 12:34:56
```

Note `ts_offset` is UTC while `ts_local` is Vienna — that asymmetry is the expected Sybase result,
not a failure.

First IDE run costs ~2 min for the ASE container unless it is still up from the CLI runs
(`withReuse(true)` keeps it alive; check with `podman ps`). If the tree shows 12 but the Sybase ones
are **red** with an NPE, step 4 was the missing piece.

CLI cross-check that must stay green throughout:

```bash
mvn -o -Pno-proxy -Pdev-build -pl ifas-testing/ifas-integration-tests test -Dtest=TemporalTypeRoundtripTest
```
