# CLAUDE.md

This file provides guidance to Claude Code when working with the IFAS13 codebase.

## Project Overview

IFAS13 (Investment Fund Administration System) is a Spring Boot-based enterprise application for processing tax reporting data from investment funds. The system processes "Steuermeldungen" (tax reports) submitted as CSV files, validates them against configurable rules ("Ermittlungsvorgaben"), performs calculations, and generates reports. It replaces a legacy C++ application. The application supports multiple database backends (PostgreSQL, Sybase, H2).

## Technology Stack

- Java 21 (LTS), Spring Boot 3.5.8, Spring Data JPA
- Maven multi-module project
- MapStruct 1.6.3 for object mapping
- Apache POI 5.4.1 for Excel processing, Apache Commons CSV 1.12.0
- TestContainers for integration tests (PostgreSQL 15, Sybase 16)
- Flyway for database migrations
- Lombok for code generation, Logback 1.5.16
- AssertJ, JUnit 5, Groovy 3.0.25

## Build & Test Commands

```bash
mvn clean compile          # Build all modules
mvn test                   # Run all tests (H2, PostgreSQL 15, Sybase 16)
mvn package                # Build JARs
mvn clean install          # Full build + local install

# Skip database-specific tests
mvn test -Pskip-postgres15-tests
mvn test -Pskip-sybase16-tests

# Run specific test class
mvn test -Dtest=ClassName
```

Database tests use TestContainers. Setup scripts: `ifas-database/ifas-database-flyway/src/main/resources/db/migration/`.

## Running the Application

Multiple entry points depending on database backend. **Never run `IfasMainApplication` directly** - it throws an exception by design.

**Production**: `SpringBootIfasApplication` — activates all database profiles; configured via environment for deployment.

**Local development** (test launchers in `src/test/java`, run from IDE):

| Test launcher | Databases |
|---------------|-----------|
| `LocalH2OnlyIfasApplication` | H2 only |
| `LocalH2WithMailhogIfasApplication` | H2 + Mailhog |
| `LocalPostgresOnlyIfasApplication` | PostgreSQL only |
| `LocalPostgresAndH2IfasApplication` | PostgreSQL + H2 |
| `LocalPostgresAndSybaseIfasApplication` | PostgreSQL + Sybase |
| `LocalSybaseGastAndH2IfasApplication` | Sybase GAST + H2 |
| `LocalSybaseGastAndPostgresIfasApplication` | Sybase GAST + PostgreSQL |

Application URL: http://localhost:8080/ifas-uat

## Docker Development Environment

```bash
# From ifas-applications/ifas-main-application
docker-compose up postgres      # PostgreSQL (port 7432)
docker-compose up sybase16      # Sybase (port 5001)
docker-compose up mailhog       # Mailhog (web: 8025, SMTP: 10025)
```

## Development Tools

Utility applications in `ifas-dev-tools`:

```bash
mvn exec:java -Dexec.mainClass="at.oekb.ifas.devtools.DatabaseYamlExportTool"
mvn exec:java -Dexec.mainClass="at.oekb.ifas.devtools.DatabaseYamlImportTool"
mvn exec:java -Dexec.mainClass="at.oekb.ifas.devtools.DatabaseSchemaTool"
```

## Architecture

### Module Structure

**`support-libs/`** - Technical infrastructure (no business logic)
- `core-support` - General utilities, Spring helpers, transaction support
- `web-support` - Web/REST utilities
- `csv-schema` - CSV parsing and validation framework
- `xls-support` - Excel file processing utilities
- `dsl-support` - Domain-specific language support
- `log-support` - Logging utilities
- `mail-support` - Email sending utilities
- `multidbctx-support` - Multi-database context routing framework
- `netapp-archive-support` - NetApp archive integration
- `core-test-support` - Test utilities
- `sybase-testcontainer` - Sybase Testcontainer implementation
- `sybase-drivers` - Sybase JDBC drivers
- `oekb-libs/` - Third-party OEKB libraries
- `oekb-master-pom-dummy/` - Parent POM definition

**`ifas-database/`** - Data persistence layer
- `ifas-database-config` - Database configuration classes and Spring profiles
- `ifas-database-flyway` - Database migration scripts (Flyway)
- `ifas-persistence-core` - Core persistence entities and repositories
- `ifas-persistence-stamm` - Master data persistence
- `ifas-persistence-stm` - Tax report ("Steuermeldung") persistence
- `ifas-persistence-inv` - Investment data persistence
- `ifas-persistence-wkn` - Security identifier persistence
- `ifas-persistence-infra` - Infrastructure persistence (work queue, jobs, filestore)
- `ifas-data-import-export` - Database import/export functionality

**`ifas-domain/`** - Business domain logic (DDD approach)
- `ifas-domain-core` - Shared domain model and utilities
- `ifas-domain-stm` - Tax reporting domain (core business logic)
    - Processing of "SteuerMeldung" (tax reports)
    - Validation against "Ermittlungsvorgabe" (calculation rules)
    - Business calculations and transformations
- `ifas-domain-recalc` - Excel recalculation domain logic

**`ifas-services/`** - Application services
- `ifas-main-service` - Core business services (orchestration layer)
    - `DataImportService` - CSV import processing
    - `DataExportService` - Report generation
    - `UserAcceptanceTestService` - UAT execution

**`ifas-applications/`** - Deployable applications
- `ifas-main-application` - Spring Boot application (JAR deployment)
- `ifas-main-war` - WAR packaging for Tomcat deployment

**`ifas-web/`** - Web layer
- `ifas-web-restapi` - REST API for user acceptance tests
- `ifas-web-ui` - Web UI components

**`ifas-testing/`** - Test infrastructure
- `ifas-test-data` - Test data and utilities
- `ifas-integration-tests` - Integration test suites
- `ifas-libreoffice-recalc-server-container` - LibreOffice calculation service (for Excel recalc)
- `ifas-libreoffice-recalc-client` - Client for LibreOffice recalc service
- `ifas-msexcel-recalc-client` - Client for MS Excel recalc service

**`ifas-dev-tools/`** - Developer utilities

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

### Package Structure Convention

```
at.oekb.ifas.domain.<domain-name>.<concept>
at.oekb.ifas.persistence.<domain-name>.<concept>
at.oekb.ifas.service.<ServiceName>
at.oekb.ifas.app.<ApplicationName>
at.oekb.ifas.web.<navbar-group>.<PageController>
```

Web controllers should be organized in sub-packages reflecting the UI navigation structure (e.g., `testing`, `datamanagement`, `tools`).

### Database Profiles

Database configuration classes in `ifas-database/ifas-database-config/` define Spring profiles:

**H2** (in-memory, PostgreSQL compatibility mode):
- `h2-db1`, `h2-db2`, `h2-db3` — application databases
- `h2-infra-db` — infrastructure (work queue, jobs, filestore)

**PostgreSQL 15**:
- `postgres-localhost-7432` — local development (port 7432)
- `postgres-server` — server deployment (environment-configured)
- `postgres-testcontainer` — TestContainers-managed (integration tests only)

**Sybase 16**:
- `sybase-localhost-5001` — local development
- `sybase-gast` — staging environment
- `sybase-ifasneu` — alternative instance

Database routing uses `database-context.*-db-key` properties to map service contexts to database profiles. The test launchers activate the appropriate combination of profiles.

## Code Quality

The build enforces rules via the `forbiddenapis` Maven plugin. See `.claude/rules/forbidden-apis.md` for details.

Annotation processing (MapStruct, Lombok) is configured with `<maven.compiler.proc>full</maven.compiler.proc>`. When adding new MapStruct mappers, rebuild the affected module.

## Coding Conventions

Coding standards are enforced via `.claude/rules/`. Key rules:

| Rule file | Scope | Content |
|-----------|-------|---------|
| `forbidden-apis.md` | `**/*.java` | Temporal utilities, no console output, no reflection, JUnit 5 only |
| `java-conventions.md` | `**/*.java` | No `var`, Lombok, `@Slf4j` logging, exception handling |
| `testing-conventions.md` | `**/test/**` | Given-when-then, AssertJ, `@Inject`, multi-DB, test data |
| `database-conventions.md` | `**/persistence*/**` | JPA, Flyway, multi-DB support |
| `async-processing.md` | `**/service/**` | Executor injection, no `@Async` within same class |
| `ide-refactoring.md` | `**/*.java` | Use IDE/MCP tools for renames/moves |

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

Don't run `IfasMainApplication` directly — use `SpringBootIfasApplication` or one of the test launchers listed above.

### Port Conflicts

Default ports: 8080 (Spring Boot), 7432 (PostgreSQL), 5001 (Sybase docker-compose), 5000 (Sybase internal).
