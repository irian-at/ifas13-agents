# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Communication Style

- **Be concise**: Keep responses brief and to the point
- **Detailed explanations**: Only provide extensive explanations when explicitly requested
- **Examples**: Avoid multiple examples unless asked
- **Assume competence**: User understands concepts unless they ask for clarification

## Project Overview

IFAS13 is a Java-based Spring Boot application for processing tax reporting (Steuermeldung) data. The system handles CSV imports, Excel processing, and database operations across PostgreSQL and Sybase databases.
It is based on a legacy C++ application which shall be replaced by this new Java application. The original application can be found in ~/dev/projects/oekb/ifas/.

## Build System & Commands

This is a Maven multi-module project using Java 21 and Spring Boot 3.5.6.

**Core Commands:**
- `mvn clean compile` - Build all modules
- `mvn test` - Run unit tests
- `mvn package` - Build JARs for all modules
- `mvn clean install` - Full build including installation to local repository

**Testing:**
- `mvn test` - Run all tests (includes H2, PostgreSQL 15, and Sybase 16 tests)
- `mvn test -Pskip-postgres15-tests` - Skip PostgreSQL tests (uses system property `ignore-test-dbms-postgres15`)
- `mvn test -Pskip-sybase16-tests` - Skip Sybase tests (uses system property `ignore-test-dbms-sybase16`)
- `mvn test -Dtest=ClassName` - Run specific test class

**Database Testing:**
The project uses TestContainers for database integration tests. Tests run against H2 (in-memory), PostgreSQL 15, and Sybase 16. Database setup scripts are in `ifas-database/ifas-database-flyway/src/main/resources/db/migration/`.

**Local Development:**
- `docker-compose -f container/local-dev-support/docker-compose.yml up postgres` - Start PostgreSQL (port 7432)
- `docker-compose -f container/local-dev-support/docker-compose.yml up minio` - Start MinIO for file storage

## Architecture

**Module Structure:**
- `support-libs/` - Shared libraries and utilities (core-support, csv-schema, xls-support, etc.)
- `ifas-database/` - Database migrations (Flyway) and persistence layer (JPA repositories)
- `ifas-domain/` - Domain models and business logic (stamm, fonds, stm, wkn, uat)
- `ifas-services/` - Service layer (main-service, mft-watchdog)
- `ifas-applications/` - Executable applications (main JAR, WAR)
- `ifas-web/` - Web layer (UAT REST API, webapp)
- `ifas-testing/` - Test utilities, test data creators, integration tests
- `ifas-dev-tools/` - Development tools and utilities

**Key Domain Concepts:**
- `SteuerMeldung` - Tax report interface with implementations for CSV/DB/Excel
- `SteuerMeldungLieferung` - Tax report delivery with validation
- `Ermittlungsvorgabe` - Tax calculation specifications
- Multi-database support (H2, PostgreSQL 15, Sybase 16) with Flyway migrations

**Technology Stack:**
- Java 21 (LTS), Spring Boot 3.5.6, JPA/Hibernate
- MapStruct 1.6.3, Apache POI 5.4.1, Apache Commons CSV 1.12.0
- TestContainers, Flyway, Logback 1.5.16
- AssertJ, JUnit 5, Lombok, Groovy 3.0.25

## Code Conventions & Rules

Coding standards are defined in `.claude/rules/` and enforced by the `forbiddenapis` Maven plugin. Key rule files:

| Rule file | Scope | Content |
|-----------|-------|---------|
| `forbidden-apis.md` | All files | Temporal utilities, no console output, no reflection, JUnit 5 only |
| `logging.md` | All files | `@Slf4j` annotation, no manual logger declarations |
| `null-safety.md` | All files | JSpecify `@NullMarked`/`@Nullable` annotations |
| `naming-conventions.md` | All files | Utility plural form, writer pattern, domain terminology |
| `documentation-style.md` | All files | Javadoc guidelines |
| `testing-conventions.md` | `**/test/**` | Given-when-then, AssertJ, `@Inject`, multi-DB |
| `database-conventions.md` | `**/persistence*/**` | JPA, Flyway, converters |
| `apache-commons.md` | All files | `collections4`/`lang3` only |

## Writer Pattern

Use dedicated writer classes for text output. For complete guidance, invoke the `generating-writers` skill.

## Testing

For test generation, the `java-unit-test` and `assertj-assertions` skills provide complete guidance.

## Workflow Preferences

- I'll run the tests myself and copy the log if needed