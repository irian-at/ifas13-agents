---
paths:
  - "**/db/migration/**"
---

# Flyway Versions When Merging

A feature branch adds its migration scripts under
`ifas-database/ifas-database-flyway/src/main/resources/db/migration/{postgres15,sybase16}` with the
next free version at branch time. By the time it is merged, `master` — or a sibling branch that
merged first — may already own those numbers. Flyway refuses duplicate versions, and with
`outOfOrder` off (the default here) a new script whose version lies below an already applied one
fails validation. Check before every merge, in either direction.

## Before the merge

1. `git fetch origin`, then compare against the **shared** branches, never only the local `master`:
   highest version per tree on `origin/master`, `origin/stable`, `origin/production` against the
   branch.
2. List the scripts only the branch has:
   `git diff --name-status origin/master...<branch> -- <migration dir>`.
3. Look at sibling feature branches too — whoever merges into `master` second renumbers:
   loop over `git for-each-ref --format='%(refname:short)' refs/remotes/origin` and print the highest
   file per tree with `git ls-tree --name-only <ref> -- <tree dir> | sort -V | tail -1`.

## Renumbering, when branch-only scripts collide or lie below the target's highest version

- Renumber only scripts that exist on the branch alone. A script that is on `master`, `stable` or
  `production` is applied somewhere and is never renamed.
- Continue after the target's highest version, keep the branch's relative order, and give the same
  feature the **same number in both trees**, placeholders ("not required in sybase") included.
- Update every reference to the old names: plan and tracker under `mathias/plans/`, `docs/`,
  comments in other scripts or Java. Grep the old `V0nn__` names across the repo and the plans.
- Reinstall the Flyway module, otherwise tests run against the stale jar:
  `mvn -Pno-proxy install -DskipTests -pl ifas-database/ifas-database-flyway`.
- Local databases that already applied the old numbers (docker Postgres 7432, a GAST clone) keep
  them in `flyway_schema_history`; the renamed scripts show up as new versions and fail on the
  existing tables. Reset the docker volume, or delete the old history rows and the objects they
  created, before starting the application. H2 is in-memory and unaffected.
- Verify with a Flyway-backed test on Postgres: one `@TestTemplate` class of the feature without
  `-Pskip-postgres15-tests`.

## Record it

Note the check in the feature plan's risk list with the date, the target's highest version and the
outcome — also when nothing had to change.
