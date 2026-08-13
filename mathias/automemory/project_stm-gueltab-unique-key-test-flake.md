---
name: project_stm-gueltab-unique-key-test-flake
description: Seeding multiple SteuerMeldung rows in a test with a shared now() guelt_ab causes a clock-resolution-dependent unique-constraint flake.
metadata: 
  node_type: memory
  type: project
  originSessionId: 5971a346-d24c-4633-b219-a5358471e515
---

`steuer_meldung` has unique key `AK_STUER_BEH_ALT_KEY_STEUER_M (num_wfs_ku, gj_ende, guelt_ab)`. When a test seeds several `SteuerMeldungEntity` rows that share `numWfsKu` + `gjEnde`, `guelt_ab` is the ONLY discriminator — so setting it from a shared `LocalDateTimes.nowInVienna()` collides whenever two seeds land in the same clock tick (`guelt_ab` is `timestamp(6)`).

**Why:** Manifests as an order-/machine-dependent "constraint exception": passes on bare-metal (fine clock) + cold-JVM IntelliJ single-class runs (ms apart), fails in the hot-JVM full `mvn` build on VMs with coarse/virtualized clocks (µs apart → identical timestamp). It is NOT cross-test pollution — seeding is `em.merge`/save-on-assigned-id (upsert) and truncate runs after each test. `AK_STEUER_BEH_TIMESTA_STEUER_M (guelt, num_wfs_ku, gj_ende, stm_id)` includes `stm_id` so it never collides; only the alt key bites.

**How to apply:** Give each seeded row a deterministic distinct `guelt_ab`, e.g. `GUELT_AB_BASE.plusSeconds(stmId)` — not a shared wall-clock `now()`. Fixed in `VorherigeFinalStmIdResolverTest` (2026-07-24). Prefer distinct fixed timestamps over `now()` in any multi-row STM seeding. Related: [[project_recalc-historical-fidelity]].
