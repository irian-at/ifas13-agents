# CLAUDE.md

<!-- IMPORTANT: Never commit this file to git -->

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

IFAS13 (Investment Fund Administration System) is a Spring Boot-based enterprise application for processing tax reporting data from investment funds. The system processes "Steuermeldungen" (tax reports) submitted as CSV files, validates them against configurable rules ("Ermittlungsvorgaben"), performs calculations, and generates reports. The application supports multiple database backends (PostgreSQL, Sybase, H2).

## Technology Stack

- **Java 21** (LTS)
- **Spring Boot 3.5.6** with Spring Data JPA
- **Maven** multi-module project
- **MapStruct 1.6.3** for object mapping
- **Apache POI 5.4.1** for Excel processing
- **Testcontainers** for integration tests (PostgreSQL, Sybase)
- **Flyway** for database migrations
- **Lombok** for code generation

## Build and Test Commands

### Required Maven Profiles

**IMPORTANT:** Always activate these Maven profiles when running `mvn` commands:
- `no-proxy` - Disables proxy settings
- `platform-arm64` - Required for ARM64/Apple Silicon

```bash
# Example: Always include these profiles
mvn clean install -Pno-proxy -Pplatform-arm64
```

### Building the Project

```bash
# Clean build from root
mvn clean install -Pno-proxy -Pplatform-arm64

# Build without tests
mvn clean install -DskipTests -Pno-proxy -Pplatform-arm64

# Build specific module
cd <module-directory>
mvn clean install -Pno-proxy -Pplatform-arm64
```

### Running Tests

See `.claude/rules/run-tests.md` for full test conventions (AssertJ, naming, commands).

### Running the Application

The application has multiple entry points depending on the database backend. **Never run `IfasMainApplication` directly** - it will throw an exception by design.

#### Using IDE Run Configurations (preferred):

- `SpringBootH2IfasMainApplication` - H2 in-memory database (no prerequisites)
- `SpringBootPostgresContainerIfasMainApplication` - Auto-started Postgres container (requires Docker/Podman)
- `SpringBootPostgresLocalIfasMainApplication` - Existing Postgres on port 7432
- `SpringBootSybaseLocalIfasMainApplication` - Existing Sybase instance
- `SpringBootMultiDbIfasMainApplication` - Multi-database support

#### Using Command Line:

```bash
# From ifas-applications/ifas-main-application directory
cd ifas-applications/ifas-main-application

# Run with H2 (simplest, no dependencies)
mvn spring-boot:run -Dspring-boot.run.mainClass=at.oekb.ifas.app.SpringBootH2IfasMainApplication

# Run with Postgres container
mvn spring-boot:run -Dspring-boot.run.mainClass=at.oekb.ifas.app.SpringBootPostgresContainerIfasMainApplication
```

Application URL: http://localhost:8080/ifas-uat

### Docker Development Environment

```bash
cd container/local-dev-support

# Start Sybase + Java application containers
docker-compose up

# Start with additional services (postgres, sftp, minio)
docker-compose --profile donotstart up <service-name>
```

### Development Tools

Several utility applications are available in `ifas-dev-tools`:

```bash
# Export database data to YAML
mvn exec:java -Dexec.mainClass="at.oekb.ifas.devtools.DatabaseYamlExportTool"

# Import YAML data to database
mvn exec:java -Dexec.mainClass="at.oekb.ifas.devtools.DatabaseYamlImportTool"

# Generate database schema documentation
mvn exec:java -Dexec.mainClass="at.oekb.ifas.devtools.DatabaseSchemaTool"
```

## Architecture

### Module Structure

The project follows a layered architecture organized into Maven modules:

**`support-libs/`** - Technical infrastructure (no business logic)
- `core-support` - General utilities, Spring helpers, transaction support
- `web-support` - Web/REST utilities
- `csv-schema` - CSV parsing and validation framework
- `xls-support` - Excel file processing utilities
- `dsl-support` - Domain-specific language support
- `log-support` - Logging utilities
- `core-test-support` - Test utilities
- `sybase-testcontainer` - Sybase Testcontainer implementation
- `oekb-libs/` - Third-party OEKB libraries
- `oekb-master-pom-dummy/` - Parent POM definition

**`ifas-database/`** - Data persistence layer
- `ifas-database-flyway` - Database migration scripts (Flyway)
- `ifas-persistence-core` - Core persistence entities and repositories
- `ifas-persistence-stamm` - Master data persistence
- `ifas-persistence-stm` - Tax report ("Steuermeldung") persistence
- `ifas-persistence-inv` - Investment data persistence
- `ifas-persistence-wkn` - Security identifier persistence
- `ifas-data-import-export` - Database import/export functionality

**`ifas-domain/`** - Business domain logic (DDD approach)
- `ifas-domain-stamm` - Master data domain (funds, companies, etc.)
- `ifas-domain-fonds` - Fund management domain
- `ifas-domain-stm` - Tax reporting domain (core business logic)
  - Processing of "SteuerMeldung" (tax reports)
  - Validation against "Ermittlungsvorgabe" (calculation rules)
  - Business calculations and transformations
- `ifas-domain-wkn` - Security identifier domain

**`ifas-services/`** - Application services
- `ifas-main-service` - Core business services (orchestration layer)
  - `DataImportService` - CSV import processing
  - `DataExportService` - Report generation
  - `UserAcceptanceTestService` - UAT execution
- `ifas-mft-watchdog` - Managed file transfer monitoring

**`ifas-applications/`** - Deployable applications
- `ifas-main-application` - Spring Boot application (JAR deployment)
  - Multiple main classes for different database profiles
  - REST API and simple web UI
- `ifas-main-war` - WAR packaging for Tomcat deployment

**`ifas-web/`** - Web layer
- `ifas-web-restapi` - REST API for user acceptance tests
- `ifas-web-app` - Web UI components

**`ifas-testing/`** - Test infrastructure
- `ifas-test-support` - Test data and utilities
- `ifas-integration-tests` - Integration test suites
- `ifas-libreoffice-recalc-server-container` - LibreOffice calculation service (for Excel recalc)
- `ifas-libreoffice-recalc-client` - Client for LibreOffice service

**`ifas-dev-tools/`** - Developer utilities
- Command-line tools for database operations and testing

### Key Domain Concepts

**SteuerMeldung (Tax Report)**
- Central domain entity representing a tax report submission from a fund
- Loaded from CSV files, database, or Excel
- Contains multiple tax entries with fund holdings and calculations
- Processed through validation and calculation pipelines

**Ermittlungsvorgabe (Calculation Rules)**
- Abstract representation of legal requirements for tax calculations
- Version-controlled Excel templates defining calculation logic
- Applied to SteuerMeldung entities during processing
- Validated through Excel recalculation for verification

**ValidationInfo**
- Represents validation messages (errors, warnings, info)
- Used throughout the validation pipeline
- Note: There's a TODO to rename this to `ValidationMessage`

**CSV Processing**
- Schema-based CSV parsing framework in `csv-schema`
- Supports complex multi-section CSV formats
- Position-aware error reporting
- Bidirectional mapping between CSV and domain objects

### Data Flow

1. **Input**: CSV tax reports uploaded or received via MFT
2. **Import**: CSV parsed using schema definitions (`csv-schema`)
3. **Validation**: Business rules applied (`ifas-domain-stm`)
4. **Calculation**: Tax treatment calculated based on Ermittlungsvorgabe
5. **Verification**: Results verified against Excel template calculations
6. **Storage**: Entities persisted via JPA repositories (`ifas-persistence-*`)
7. **Export**: Reports generated and returned

### Testing Strategy

- **Unit tests**: JUnit 5, focused on business logic
- **Integration tests**: Use Testcontainers for PostgreSQL and Sybase
- **UAT**: Excel-based test cases with expected vs. actual validation
- **Database-agnostic**: Tests can run against H2, PostgreSQL, or Sybase
- Test data located in `ifas-testing/ifas-test-support/src/main/resources/at/oekb/ifas/testdata/`
- Test conventions (AssertJ, method naming): see `.claude/rules/run-tests.md`

## Important Development Notes

### Git Commits and Documentation

See `.claude/rules/git-commits.md` for git commit and documentation rules.

### Time and Date Handling

See `.claude/rules/time-date-handling.md` for time/date handling rules.

### Annotation Processing

The project uses annotation processing (MapStruct, Lombok). Maven is configured with:
```xml
<maven.compiler.proc>full</maven.compiler.proc>
```

When adding new MapStruct mappers, rebuild the affected module to generate implementation classes.

### Database Profiles

Multiple database configurations via Spring profiles:
- `h2` - In-memory H2 (fastest for development)
- `postgres-container` - Testcontainers-managed PostgreSQL
- `postgres-local` - Local PostgreSQL on port 7432
- `sybase-local` - Local Sybase instance
- `multidb` - Multiple datasources

Use the profile-specific main application classes rather than configuring profiles manually.

### Flyway Migrations and H2 Compatibility

See `.claude/rules/flyway-migrations.md` for full migration rules (H2 compatibility, naming, SQL patterns, development mode).

### Package Structure Convention

Domain code follows this pattern:
```
at.oekb.ifas.domain.<domain-name>.<concept>
at.oekb.ifas.persistence.<domain-name>.<concept>
at.oekb.ifas.service.<ServiceName>
at.oekb.ifas.app.<ApplicationName>
at.oekb.ifas.web.<navbar-group>.<PageController>
```

Web controllers should be organized in sub-packages reflecting the UI navigation structure (e.g., `testing`, `datamanagement`, `tools`).

### Code Quality

The build enforces several rules via `forbiddenapis`:
- No deprecated JDK APIs
- No non-portable APIs (e.g., `sun.misc.*`)
- No System.out/System.err (use SLF4J)
- No direct date/time factory methods
- Use `jakarta.*` instead of `javax.*` packages
- Use Apache Commons Collections 4 and Lang3

### Java Variable Declarations

See `.claude/rules/java-variables.md` for variable declaration rules (no `var`).

### Lombok Best Practices

See `.claude/rules/lombok.md` for Lombok usage conventions.

### Asynchronous Processing

**Use direct `Executor` injection for asynchronous operations, not `@Async` within the same class.**

#### Problem: @Async Doesn't Work Within Same Class

Spring's `@Async` annotation uses AOP proxies. When you call an `@Async` method from within the same class, the proxy is bypassed and the method executes synchronously:

```java
// DON'T - This won't work asynchronously!
@Service
public class MyService {

    public String startTask() {
        processAsync();  // ❌ Runs synchronously, proxy bypassed!
        return taskId;
    }

    @Async
    public void processAsync() {
        // Heavy processing
    }
}
```

#### Solution: Inject Executor Directly

Instead, inject the `Executor` bean and use it explicitly:

```java
// DO - This works asynchronously!
@Service
public class MyService {
    private final Executor taskExecutor;

    @Autowired
    public MyService(Executor taskExecutor) {
        this.taskExecutor = taskExecutor;
    }

    public String startTask() {
        taskExecutor.execute(() -> processTask());  // ✅ Truly async!
        return taskId;
    }

    private void processTask() {
        // Heavy processing runs on thread pool
    }
}
```

#### Configuration

Enable async support with a configuration class:

```java
@Configuration
@EnableAsync
public class AsyncConfig {

    @Bean(name = "taskExecutor")
    public Executor taskExecutor() {
        ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
        executor.setCorePoolSize(2);
        executor.setMaxPoolSize(5);
        executor.setQueueCapacity(100);
        executor.setThreadNamePrefix("async-");
        executor.initialize();
        return executor;
    }
}
```

#### Pattern: Task Tracking with Status Polling

For long-running operations in web controllers:

1. **Service layer**: Store task state in `ConcurrentHashMap` with unique task IDs
2. **Controller**: Return task ID immediately, provide REST endpoint for status polling
3. **Frontend**: JavaScript polls status endpoint every 1-2 seconds
4. **UI feedback**: Show progress indicator, auto-display results when complete

Example: `AsyncStmRecalcService` with `StmRecalcPageController`

Benefits:
- Non-blocking user experience
- Real-time progress feedback
- Works with standard HTTP (no WebSocket complexity)
- Thread pool manages resource usage efficiently

### Test Data

Test CSV files and resources are organized by test case ID in:
- `ifas-testing/ifas-test-support/src/main/resources/at/oekb/ifas/testdata/stm/`

Use `StmTestResources` utility class to load test data by test ID.

### Refactoring and File Operations

**CRITICAL: Always use IntelliJ/IDE refactoring tools for code changes, never bash commands.**

#### Why IDE Refactoring is Required:
1. **Git tracking**: IDE refactorings are properly tracked as renames/moves (not delete + add)
2. **Reference updates**: All imports, references, and usages are automatically updated
3. **Compile-time safety**: IDE validates changes before applying them
4. **Atomic operations**: Changes are committed together with proper tracking

#### Available MCP Tools for Refactoring:
- `mcp__jetbrains__rename_refactoring` - Rename classes, methods, variables
- `mcp__jetbrains__create_new_file` - Create new files/classes
- Manual moves via IntelliJ UI when MCP tools don't support the operation

#### What NOT to do:
```bash
# DON'T use bash commands for code operations
mv Controller.java NewController.java  # ❌ Breaks git tracking
cp file1.java file2.java               # ❌ Doesn't update references
sed -i 's/old/new/' file.java          # ❌ Bypasses IDE validation
```

#### Correct approach:
```
1. Use mcp__jetbrains__rename_refactoring for renaming
2. Use IntelliJ's "Refactor → Move" UI for moving to new packages
3. Let IntelliJ handle git staging/commits automatically
4. Verify git shows renames (R) not deletions (D) + additions (A)
```

#### Example refactoring sequence:
1. Rename class: `mcp__jetbrains__rename_refactoring`
2. Move to package: User performs "Refactor → Move" in IDE
3. Update implementation: Edit tool for code changes
4. Git handles automatically: IntelliJ stages and commits with proper rename tracking

This ensures code integrity and proper version control history.

## Common Issues

### Annotation Processing Not Working

If MapStruct implementations aren't generated:
```bash
mvn clean compile -pl <affected-module>
```

### Testcontainers Failing

Ensure Docker/Podman is running, or skip container-based tests:
```bash
mvn test -Pskip-postgres15-tests -Pskip-sybase16-tests
```

### Application Won't Start

Don't run `IfasMainApplication` directly - it throws `IllegalStateException` by design. Use one of the profile-specific main classes.

### Port Conflicts

Default ports:
- 8080: Spring Boot application
- 7432: PostgreSQL container
- 7433: Sybase container (via docker-compose)
- 5000: Sybase internal port

Check for conflicts before starting services.

## Additional Resources

- Architecture diagrams: `docs/Architektur/`
- Application configurations: `docs/Applications and Configurations.md`
- Test data documentation: `docs/Testdaten Fachabteilung/`
- **Local architecture documentation**: `.local/docs/ARCHITECTURE.md` (detailed architecture reference with diagrams)
- **Implementation documentation**: Always place implementation docs in `.local/docs/` (not in `docs/`)
- Web page controller classes should have the PageController suffix
- Always git stage newly added files