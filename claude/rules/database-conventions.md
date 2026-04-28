---
paths:
  - "**/persistence*/**/*.java"
  - "**/flyway/**"
  - "**/database*/**/*.java"
  - "**/repository/**/*.java"
---

# Database Conventions

## JPA Entities

- Use `@Entity` with `@Table(catalog = "...", name = "...")` — catalogs are `ifas`, `kurs`, and `vwkn`
- Explicit `@Column(name = "...")` mappings on all fields
- Lombok: `@Getter`, `@NoArgsConstructor`, `@EqualsAndHashCode(onlyExplicitlyIncluded = true)`, `@ToString(onlyExplicitlyIncluded = true)` — no class-level `@Setter`, only selective per-field
- JSpecify: `@NullMarked` at class level, selective `@Nullable` on individual fields
- Custom JPA converters for legacy data mappings:
  - `DJaNeinToBooleanConverter` — "JA"/"NEIN" to Boolean
  - `TJaNeinToBooleanConverter` — "J"/"N" to Boolean
  - `UriConverter` — URI to String (`autoApply = true`)

## JPA Repositories

- Extend `JpaRepository<Entity, ID>` and `JpaSpecificationExecutor<Entity>`
- Use `@Query` with named parameters (`@Param`) for complex operations
- Use `@Modifying` on UPDATE/DELETE query methods

## Flyway Migrations

- Scripts location: `ifas-database/ifas-database-flyway/src/main/resources/db/migration/`
- Database-specific directories: `postgres15/` and `sybase16/`
- H2 reuses PostgreSQL migrations directly (`DbConfigs.FLYWAY_MIGRATION_LOCATION_H2 = FLYWAY_MIGRATION_LOCATION_POSTGRES`) — H2 runs in `MODE=PostgreSQL` compatibility mode, so no H2-specific SQL is needed

## Multi-Database Support

The project supports H2 (in-memory), PostgreSQL 15, and Sybase 16. TestContainers is used for database integration tests.

Database configuration classes are in `ifas-database/ifas-database-config/`. Each defines a Spring profile:

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

Database routing uses `database-context.*-db-key` properties in `application-*.properties` files to map service contexts to database profiles.
