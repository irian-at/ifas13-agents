# Parallel processing of Steuermeldungen — concurrency analysis

## Context

Lieferanten deliver Meldungen with input status `NEW`, `UPDATE`, `CONFIRMED` or `DELETE`. Each
resolves to a persisted `StmStatus` (`OPEN` / `FINAL` / `DELETED`, or a failure status). The
question: **can parallel execution of two Lieferungen corrupt this state machine, and is there a
concrete scenario where it does?**

**Answer: yes.** The system is structurally exposed. The legacy C++ application was
single-threaded and wrote each Meldung to the DB before reading the next line, so the DB *was*
the state. IFAS13 inverted this — it validates the whole file against a DB snapshot first, then
persists — and runs up to 10 Lieferungen concurrently with no locking of any kind. Every
"does this already exist?" check is an unlocked read-then-write.

This document is analysis only. Remediation options are listed at the end with trade-offs; no
direction is chosen.

---

## 1. The state machine as implemented

`StmStatus` (`ifas-database/ifas-persistence-stm/.../steuermeldung/StmStatus.java:8-21`) has 12
values in two groups — 4 Lieferant input statuses, 8 Meldestelle result statuses. There is no
transition table on the enum; the machine lives in imperative code.

```
Lieferant input          →  Meldestelle result        persistence
─────────────────────────────────────────────────────────────────────────────────────
NEW        ── ok ────────►  OPEN                      INSERT, new stmId from sequence
           └─ declined ──►  NEW_DECLINED (no stmId)
           └─ error ─────►  ERROR

UPDATE     ── ok ────────►  OPEN                      INSERT new row + closeIfOpen(pred)
  (pred OPEN or FINAL)
           └─ declined ──►  UPDATE_DECLINED
           └─ error ─────►  ERROR

CONFIRMED  ── ok ────────►  FINAL                     in-place UPDATE; gueltBis stays NULL
  (pred must be OPEN)                                 + closeIfSelbstnachweisMatches(FIN ancestor)
           └─ !OPEN ─────►  CONFIRM_DECLINED (ERR_STATUS_NM)

DELETE     ── ok ────────►  DELETED                   in-place UPDATE; gueltBis := now
  (pred must be OPEN)
           └─ !OPEN ─────►  DELETE_DECLINED (ERR_STATUS_NM)

any Meldestelle status on input → ERR_STATUS_UNGUE (only message emitted)
```

The happy-path transition function is a four-line switch —
`SteuerlicheErmittlungDomainService.java:252-259`. Failure mapping (`ERROR` if any
non-declining error, else `<inputStatus>_DECLINED`) is at `:673-748`.

**"Active" is keyed on `guelt_bis IS NULL`, not on status.** `FINAL` deliberately leaves
`gueltBis` null (`SteuerMeldungEntity.confirmAsFinalAt`, `:371-383`), so a FINAL row remains the
active predecessor and an `UPDATE` on it is legal. `DELETED` sets `gueltBis`
(`markDeletedAt`, `:390-394`) and is effectively terminal.

## 2. Where transitions are validated

| Guard | Location | Rule |
|---|---|---|
| `errStatusNm` | `SteuerMeldungStatusValidators.java:206-229` | `(CONFIRMED \|\| DELETE) && previousStatus != OPEN` → `ERR_STATUS_NM`, declined |
| `errUpdOldm` | `:296-310` | UPDATE where a non-DELETED successor already exists |
| `errJahresmVorh` | `:402-416` | NEW Jahresmeldung where one already exists for ISIN+gjEnde → ERROR |
| `errAusschmVorh` | `:423-438` | same for Ausschüttungsmeldung → **INFO only** |
| `errMeldidFehlt` / `errMeldidNichtMehrGueltig` | `:82-130` | referenced stmId absent / present but `gueltBis != null` |
| `errStatusUngue` | `SteuerMeldungStatusValidationService.java:99-106` | entry gate; Meldestelle status on input |

Orchestration: `SteuerMeldungStatusValidationService.validate()` (`:86-349`). It takes **one
unlocked snapshot per Meldung** at `:108`:

```java
Map<Long, DbSteuerMeldung> existingMeldungenByIsin = getExistingMeldungenByIsin(steuerMeldung.getIsin(), stichtag);
```

and then decides everything in Java over that snapshot — `:118-127` for the active-predecessor
determination, `:447-466` for the duplicate lookup, `:472-485` for the successor scan. Plain
`SELECT`s, no lock hints (`SteuerMeldungRepository.findAllStmIdsByIsin`, `:81-89`).

### The in-file guard that exists — and its blind spot

`InLieferungAcceptedState` (`.../validation/status/InLieferungAcceptedState.java`) is an
in-memory overlay that simulates the transitions accepted Meldungen *would* cause, so a second
`CONFIRMED` on the same stmId **within one CSV** trips `ERR_STATUS_NM_LIEFERUNG` rather than
passing. It exists precisely because the new architecture validates before it persists
(`SteuerMeldungLieferungService.java:84-104`).

**It is a per-Lieferung `new InLieferungAcceptedState()` on the stack.** There is no equivalent
across concurrent Lieferungen. The problem was recognised and solved for the sequential case
inside one file; the concurrent case across files is unguarded.

## 3. The concurrency model — evidence

**Parallelism is real and configured.**

- `WorkQueueProperties.workQueueTaskExecutor()` (`:139-153`) — fixed `ThreadPoolTaskExecutor`.
- `application.properties:71` — `workqueue.executor-pool-size=10` in production.
- `WorkQueueExecutor.claimAndExecuteNextItems()` (`:172-204`) — claims up to
  `min(freeSlots, claimSize=10)` items of **any** task type, ordered only by priority +
  `createdAt`. No per-ISIN, per-Lieferant, or per-fund affinity.
- `WorkQueueItemRepository.claimItem` (`:64-79`) — *"Returns 1 if claimed, 0 if already claimed
  by another server"*. Multi-node. The CAS is on `WorkQueueItem.id` only: it guarantees one item
  runs once, and says nothing about two different items touching the same ISIN.
- One `StmCalcJob` per uploaded Meldefile (`StmCalcJobSubmissionService.java:114-146`), so two
  deliveries are two independent work items.
- `StmCalcJob` has **no dedup guard**: the only unique job index is
  `(job_type, key_date, daily_run_number)` and `dailyRunNumber` is never set for STM calc jobs.

**Locking is absent.** Exhaustive grep across main sources:

- `@Version`: exactly one entity in the whole repo, and it is not an STM —
  `AusschuettungTmp.java:36-38`. `SteuerMeldungEntity` has none.
- `@Lock` / `LockModeType` / `FOR UPDATE` / `pg_advisory_*`: **zero occurrences**.
- `synchronized`: only log buffers and handler-registry init. Nothing protects business data.

**Transaction shape.** One transaction spans the entire Lieferung — CSV parse, all validation
reads, all calculation, all writes — opened programmatically in
`WorkQueueExecutor.doExecuteItem` (`:347-365`, comment `// Main Transaction`). Domain services
carry no `@Transactional` by convention (`FristenpruefungDomainService.java:59`).

**Isolation cannot be raised.** `SimpleTransactionTemplate` uses a bare
`DefaultTransactionDefinition` (`:20-29`) → DB default (`READ COMMITTED`). Worse, the multi-DB
`SynchronizingTransactionManager` **discards the isolation level entirely** — it calls
`em.getTransaction().begin()` with no isolation applied (`:139`), and `SynchronizedTransaction`
retains only `readOnly` from the definition. Adding `@Transactional(isolation = SERIALIZABLE)`
today would be a silent no-op.

**Hibernate emits full-column UPDATEs.** No `@DynamicUpdate` anywhere in `ifas-database/`. Every
`save()` on a loaded `SteuerMeldungEntity` rewrites *all* columns from the snapshot taken at
`findById` time — including `guelt_bis`. This is what turns the confirm/delete paths from
"benign concurrent writes" into lost updates (scenario R3).

## 4. The TOCTOU window

```
  ┌─────────────── one transaction, READ COMMITTED, no locks ────────────────┐
  │                                                                          │
  │  parse CSV → validate ALL Meldungen against DB snapshot → calculate →     │
  │                        ▲                                                 │
  │                        │ snapshot taken here (T0)                        │
  │                                                       persist ALL (T1)   │
  └──────────────────────────────────────────────────────────────────────────┘
                           └──────── window ────────┘
```

The window is not "a few statements" — it spans **parse + full validation + Excel-driven
calculation of every Meldung in the file**. For a large Lieferung that is seconds to minutes.
Two Lieferungen overlapping anywhere in that window both validate against pre-state and both
write.

## 5. Concrete race scenarios

### R1 — Two identical NEW Meldungen (the scenario as asked)

Two Lieferungen, each one `NEW` Jahresmeldung for ISIN X, gjEnde 2025-12-31.

| | Thread A | Thread B |
|---|---|---|
| T0 | `getExistingMeldungenByIsin(X)` → ∅ | |
| T0' | | `getExistingMeldungenByIsin(X)` → ∅ |
| — | `errJahresmVorh`: `existingStmId == null` → **no error** | same → **no error** |
| T1 | stmId 1000 from sequence, INSERT (`gueltBis` null) | |
| T1' | | stmId 1001 from sequence, INSERT (`gueltBis` null) |
| commit | OPEN | OPEN |

**Result: two simultaneously active Jahresmeldungen for the same ISIN + gjEnde.** Both
Lieferanten receive a successful `OPEN` return file with different Melde-IDs. The invariant the
whole `ERR_JAHRESM_VORH` check exists to enforce is violated, permanently.

The `AK_STUER_BEH_ALT_KEY_STEUER_M unique (num_wfs_ku, gj_ende, guelt_ab)` constraint does
**not** catch this: `guelt_ab` is a `timestamp(6)` derived from each job's own `receivedAt`, so
the two rows differ. There is no partial index `(num_wfs_ku, gj_ende) WHERE guelt_bis IS NULL`
anywhere — grep for `guelt_bis is null` over the Flyway scripts returns nothing. **The schema
permits an unbounded number of active Meldungen per fund + Geschäftsjahr.**

Downstream, everything that resolves "the active Meldung" now picks arbitrarily —
`findExistingMeldungStmIdByGjEndeAndJahresMeldung` uses `.findFirst()` over a map ordered by
gjEnde desc, stmId desc (`SteuerMeldungStatusValidationService.java:458-465`).

### R2 — Two UPDATEs naming the same predecessor P

Both validate P as OPEN and successor-free. Both `builder.vorherigeStm(P)`, both call
`closeIfOpen(P)`. Under READ COMMITTED the second UPDATE blocks on P's row lock, then
re-evaluates — and `closeIfOpen` only touches `guelt`/`guelt_bis`, never `status`, so the
`status_code = 'OPE'` predicate still holds and it fires again. Both successors are inserted.

**Result: a forked chain — two active successors both pointing at P.** Nothing errors:
`findLatestUndeletedSuccessorStmId` already anticipates branching and simply takes `max(id)`.
The `int` return of `closeIfOpen` is discarded at the call site
(`SteuerMeldungPersistenceService.java:93`), so a 0-row close is never noticed.

### R3 — CONFIRMED racing an UPDATE on the same stmId X — lost update

The most damaging, because it silently undoes a committed write.

- B (`finalizeSteuerMeldung`) loads X via `findById` at T1; `gueltBis` is NULL in that snapshot.
- A (`persistSteuerMeldung`, UPDATE) runs `closeIfOpen(X)` at T2 → `gueltBis := t_A`. Commits T3.
- B mutates via `confirmAsFinalAt` and calls `save(existing)` at T4. With no `@DynamicUpdate`,
  Hibernate issues `UPDATE steuer_meldung SET …, guelt_bis = NULL, status = 'FIN', … WHERE stm_id = X`.

**Result: A's close of the predecessor is silently reverted.** X is FINAL *and* active
(`gueltBis` null), while A's successor Y is OPEN *and* active pointing at X. Two active rows,
broken chain.

The reverse ordering is no better: if B commits first, A's `closeIfOpen` matches 0 rows
(status is now `'FIN'`, not `'OPE'`), the return value is ignored, and you land in the same
two-active-rows state — except A's validation had already been allowed to pass under the
assumption X was OPEN, so `ERR_STATUS_NM` never fires for either side.

### R4 — CONFIRMED racing a DELETE on the same stmId X

Both validate X as OPEN. A sets `status = FIN` (leaves `gueltBis` null); B sets
`status = DED`, `gueltBis = t_B`. Full-column UPDATEs, last writer takes the whole row.

**Result: the return file lies to one Lieferant.** If A's write lands last, X is FINAL — but B's
Lieferant already received a `DELETED` (`DED`) confirmation in their response ZIP. The delivery
was acknowledged as applied and was not. This is the worst class of outcome: divergence between
what the supplier was told and what the DB holds.

### R5 — Double CONFIRMED on the same stmId

Both write `FIN`; mostly convergent. But `existing.addConfirmFile(file)` is a single FK column,
so one Lieferung's `confirm_file_id` is lost, and
`gjAbsichtFinalizeService.updateOnFinalize` runs twice —
`gj.markStmFinalized(stmId, …)` plus `absichtRepository.closeOpenForStmFinalize(...)` against the
Geschäftsjahr/Absicht rows in a *second* DB context.

### R6 — `steuer_meldung_file.nr` collision — the only race that fails loudly

`SequenceSteuerMeldungFileIdProvider.nextFileNumber` (`:32-35`):

```java
return fileRepository.findMaxNrByDatumAndLieferId(datum, lieferId).orElse(0) + 1;
```

An unlocked `max(nr)+1` against `AK_STEUER_MELDUNG_FIL_STEUER_M unique (datum, liefer_id, nr)`
(`V004__steuermeldung.sql:122`). `datum` is the **Stichtag**, not the calendar day
(`SteuerlicheErmittlungDomainService.java:188`), so two Lieferungen from the same Lieferant for
the same Stichtag — the common case — both read the same max and both insert `nr = max+1`.

The loser dies with a constraint violation at flush, rolling back the *entire* Lieferung. And it
is **not retried**: `AbstractJobWorkQueueHandler.getMaxAttempts()` returns `1`
(`:90-93`), which outranks the global `workqueue.default-max-attempts=3`. The job fails outright.

`stm_id` and `file_id` themselves are safe — `PkSequenceProvider.next` uses `nextval`
(`:33-41`), correctly noted as *"concurrency-safe, unlike the legacy max(id)+1"*. Only `nr` was
left behind, with a TODO acknowledging it.

Note the perverse interaction: R6 is the accidental partial protection against R1 — when both
deliveries share Lieferant *and* Stichtag, one dies before it can create the duplicate. Change
either field and the protection disappears.

### R7 — Parallelbetrieb with the Altsystem

`errMeldidNichtMehrGueltig` exists specifically because *"the stm has guelt_bis already set to
non-null by the altsystem in Parallelbetrieb"* (`SteuerMeldungStatusValidators.java:104-107`).
The legacy C++ writes to the same tables concurrently, outside any of IFAS13's transactions.
Every scenario above also applies with legacy as the second writer.

Aggravating factor: with two writable DBs the commit is *best-effort 1PC*, not 2PC —
`SynchronizingTransactionManager.doCommit` (`:153-179`) commits enrolled databases in sequence
and throws `PartialCommitException` if a later one fails, leaving the earlier ones committed.

## 6. What is *not* at risk

- `stm_id`, `file_id`, `archivierung_id` — DB sequences, safe.
- Work item double-execution — `claimItem` CAS is correct.
- Duplicates *within* one CSV — `InLieferungAcceptedState` handles this correctly.
- Two Lieferungen touching **disjoint** ISINs — no shared state, no interference.
- `closeIfOpen` / `closeIfSelbstnachweisMatches` as statements — atomic conditional UPDATEs.
  Their weakness is that callers discard the `int` result, not the SQL.

## 7. How likely is this in practice?

There is no code preventing it; the protection today is purely statistical. Overlap needs two
deliveries in flight simultaneously, which requires them to arrive within roughly the processing
time of one Lieferung (`polling-interval-ms=5000` plus calculation time). Realistic triggers:

- A Lieferant uploading a corrected file immediately after the first.
- Two Lieferanten reporting the same fund (co-managed / Vertreter constellations).
- A batch drop of several files at once — 10 workers will pick up 10 at a time.
- Any retry or re-submission of a file that is still being processed.
- Parallelbetrieb, where the second writer is the Altsystem and the timing is entirely outside
  IFAS13's control.

## 8. Remediation options (trade-offs, not a recommendation)

**A. Serialize per business key.** Take `pg_advisory_xact_lock(hashtext(isin))` at the top of
`SteuerlicheErmittlungDomainService.internalProcessLieferung`, or add a serialization key to
`WorkQueueItem` so the claim query skips items whose key is already `RUNNING`.
*Closes every scenario at once. Costs throughput on hot funds; advisory locks are
Postgres-only, so Sybase/Parallelbetrieb needs a different mechanism (a lock table).
The `requiredServer` field is the nearest existing precedent for a routing key.*

**B. DB-level guards.** Partial unique index `(num_wfs_ku, gj_ende) WHERE guelt_bis IS NULL`;
`@Version` on `SteuerMeldungEntity`; replace `max(nr)+1` with a sequence or a retry loop.
*Turns silent corruption into loud failures — the index catches R1, `@Version` catches R3/R4/R5,
the sequence removes R6. Does not prevent anything, it converts races into rolled-back jobs
(which, with `getMaxAttempts() == 1`, are not retried). Sybase ASE has no filtered indexes,
which is plausibly why the partial index was never added.*

**C. Narrow the window.** Re-validate the conflict-relevant predicates immediately before each
persist, inside the write path, instead of trusting the T0 snapshot.
*Shrinks but does not close the window — still a read-then-write without a lock.*

**D. Make `@DynamicUpdate` the default on `SteuerMeldungEntity`.** Removes the specific
lost-update in R3/R4 (columns a transaction never touched are no longer rewritten).
*Cheap and narrow. Does not address R1, R2 or R6, and leaves genuinely-conflicting column
writes racing.*

Worth noting for whichever direction is chosen: **raising the isolation level is not on the
table** until `SynchronizingTransactionManager` stops discarding it (`:139`).

## 9. How to demonstrate any of this

No repro test exists today. A concurrent integration test would need:

- Two threads, each running `SteuerlicheErmittlungDomainService.processLieferung` against
  `postgres-testcontainer` with the same ISIN fixture.
- A latch between the validation snapshot and the persist call to force the interleaving
  deterministically (the natural seam is `SteuerlicheErmittlungDomainService.java:150`, between
  `persistFile` and the `finishProcessing` stream).
- Assert on `SELECT count(*) … WHERE num_wfs_ku = ? AND gj_ende = ? AND guelt_bis IS NULL` for
  R1, and on `guelt_bis` of the predecessor for R3.

Note H2 will not reproduce the Postgres row-lock re-evaluation behaviour in R2 faithfully; use
`postgres-testcontainer` for anything ordering-sensitive.
