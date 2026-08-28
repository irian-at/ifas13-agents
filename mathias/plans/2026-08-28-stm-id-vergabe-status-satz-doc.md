# Transcribe `PXL_20260828_083018554.jpg` into a Markdown scenario document

## Context

`/home/sma/PXL_20260828_083018554.jpg` is a photo of a printed diagram titled
**"STATUS-Satz - STM-ID Vergabe und Anzeige"** (restricted / *eingeschränkt*). It documents, as four
`Fallbeispiel` (case-example) flows, which STM-ID a delivery gets back and which
*Status-Satz* (`OPEN` / `FINAL` / `ERROR` / `DELETED`) plus `offen`/`beendet` + `open`/`final`
display state results from each `Lieferart` (`NEW`, `CONFIRM`, `UPDATE`, `DELETE`).

The photo is unusable as a reference: it is rotated 90°, and the source is a paper printout — it
cannot be grepped, diffed or reviewed. The user wants the scenarios transcribed into a Markdown
file kept in the project, as plain tables (no diagrams), so the ID-assignment rules become a
checkable spec.

## Approach

### 1. Get a legible read of the image

The photo needs pre-processing before transcription — at the resolution the Read tool downsamples
to, several cell values (`1115` vs `11115`, `offen - open` vs `offen - final`) are borderline.

Working in the session scratchpad
(`/tmp/claude-1000/-home-sma-dev-projects-oekb-ifas13/668adac5-08f4-48c8-a7cd-9bedd3ce6efb/scratchpad`):

1. Rotate upright: `magick /home/sma/PXL_20260828_083018554.jpg -rotate 90 rot.png`
   (verify the direction on the first read; `-rotate -90` if the title ends up at the bottom).
2. Crop one tile per `Fallbeispiel` band and read each tile individually, so every box is read at
   or near native resolution. Use `magick rot.png -crop WxH+X+Y fb1.png` etc.
3. Read each tile with the Read tool and transcribe box by box.

Nothing is written outside the scratchpad in this step; the original photo is never modified.

### 2. Write the Markdown document

Target: **`docs/Entwicklung/StmIdVergabe.md`**

`docs/` is the repo's documentation tree, and `docs/Entwicklung/` is exactly where the analogous
status-scenario note already lives — `docs/Entwicklung/AusschStatus.md` documents the Ausschüttung
`aussch_status` V/A/D transitions as "Processing Scenarios" with the same shape as this diagram's
`Fallbeispiele`. CamelCase filenames are that folder's convention (`AusschStatus.md`,
`AusschuettungNotes.md`).

Structure:

- H1 title + a short intro naming the source (photo filename, date, restricted marking).
- A legend section explaining the notation actually used on the diagram:
  - `<STATUS>;<stm-id>` — the STATUS-Satz of the incoming delivery and the STM-ID it carries.
  - `OPEN;<new-id>;<old-id>` — a new STM-ID is issued and the predecessor is named in
    `_STATUS_MELDUNGS_ID_REF`.
  - `(<id> offen|beendet - open|final)` — two separate dimensions in one cell: `offen`/`beendet` is
    the `guelt_bis` validity (`offen` = `guelt_bis is null` = active row), `open`/`final` is the
    meldung's status as displayed.
- One `## Fallbeispiel N` section each, with the prose caption where the diagram has one
  (Fallbeispiel 4 carries a full sentence describing the update-of-update-then-delete flow).
- Per section a **plain markdown table only**, one row per box, with the branch alternatives
  (`FINAL` vs `ERROR`) as their own rows — matching the chosen format:

  | Step | Input | Result | Status |
  |---|---|---|---|
  | 1 | `NEW` | `OPEN;11114` | 11114 offen - open |
  | 2 | `CONFIRM;11114` | `FINAL;11114` | 11114 offen - open |
  |   |  | `ERROR;11114` | 11114 offen - open |

  Where a step fans out into several *follow-up deliveries* (Fallbeispiele 1 and 2 each branch into
  `DELETE` / `CONFIRM` / `UPDATE` from the same state), split those into sub-sections
  `### Fallbeispiel N.a / N.b / N.c` so each branch stays a linear table rather than an ambiguous
  merged one.
- Mark any cell that stays genuinely unreadable in the photo as `?` and list it under a short
  **"Unklar / zu prüfen"** section at the end, instead of guessing a value.

German terminology from the diagram is kept verbatim (`Fallbeispiel`, `offen`, `beendet`,
`Lieferart`) — this is the domain vocabulary used throughout the codebase.

### 3. Anchor the document to the code

There is currently **no** markdown documentation of the STM status lifecycle, the STATUS-Satz or
STM-ID assignment anywhere in the repo — only javadoc, DDL and the two PDFs under
`docs/Fileformate/`. So this file fills a real gap and should point at the implementation.

Add a short **"Siehe auch"** section listing:

- `ifas-database/ifas-persistence-stm/.../steuermeldung/StmStatus.java` — the 12 statuses with
  their 3-char X3/DB codes.
- `ifas-domain/ifas-domain-stm/.../ermittlung/SteuerlicheErmittlungDomainService.java` (~line 253) —
  the actual transition switch: `NEW, UPDATE -> OPEN`, `CONFIRMED -> FINAL`, `DELETE -> DELETED`,
  i.e. exactly the happy path the diagram draws.
- `ifas-domain/ifas-domain-stm/.../validation/status/SteuerMeldungStatusValidationService.java` —
  the `guelt_bis`-based *offen/beendet* logic and the `ERR_*` codes behind the diagram's `ERROR`
  boxes.
- `ifas-domain/ifas-domain-stm/.../meldung/csv/RecordType.java` + the
  `STM_LIEFERFORMAT_2022-04-03.csv-schema.yml` `STATUS` section — the STATUS-Satz fields
  (`_STATUS_STATUS`, `_STATUS_MELDUNGS_ID`, `_STATUS_MELDUNGS_ID_REF`, `_STATUS_ANMERKUNG`) that the
  diagram's `LIEFERART;<id>;<ref>` notation is shorthand for.
- `ifas-services/ifas-main-service/.../steuermeldung/SequenceStmIdProvider.java` — where the new
  STM-ID each `UPDATE` mints actually comes from.

Two mismatches between diagram and code to call out explicitly in the doc, so the shorthand is not
mistaken for a literal value:

- The diagram writes **`CONFIRM`**; the enum constant and CSV value is **`CONFIRMED`** (X3 code
  `CON`).
- The diagram only shows `ERROR` as the failure result. The code additionally has
  `NEW_DECLINED` / `UPDATE_DECLINED` / `CONFIRM_DECLINED` / `DELETE_DECLINED` (`NDL`/`UDL`/`CDL`/`DDL`).
  Note this as out of scope of the sheet rather than silently implying `ERROR` is the only failure
  path.

Also note that *offen* / *beendet* are **not** status values — they are the `guelt_bis` semantics
(`offen` = `guelt_bis is null` = the active row), while *open* / *final* in the same parentheses
refer to the meldung's status. The legend must make that split explicit, because the diagram's
`(11114 offen - final)` mixes both dimensions in one cell.

No code is changed.

## Files

- **New:** `docs/Entwicklung/StmIdVergabe.md`
- **Read only:** `/home/sma/PXL_20260828_083018554.jpg`, the STM status enums in
  `ifas-domain/ifas-domain-stm`, `docs/Entwicklung/AusschStatus.md` (style reference)

## Draft transcription (from the downsampled read — to be confirmed against the crops)

Included so the content can be sanity-checked before the file is written. Values marked `(?)` are
the ones the crop pass must settle.

**Fallbeispiel 1** — new → confirm → update, then the three possible follow-ups

| Step | Input | Result | Status |
|---|---|---|---|
| 1 | `NEW` | `OPEN;11114` | 11114 offen - open |
| 2 | `CONFIRM;11114` | `FINAL;11114` | 11114 offen - open |
|   |  | `ERROR;11114` | 11114 offen - open |
| 3 | `UPDATE;11114` | `OPEN;11115;11114` | 11114 offen - final |
|   |  | `ERROR;11114` | 11114 offen - final |
| 4a | `DELETE;11115` | `DELETED;11115` | 11114 offen - final |
|    |  | `ERROR;11115` | 11114 offen - final |
| 4b | `CONFIRM;11115` | `FINAL;11115` | 11114 beendet |
| 4c | `UPDATE;11115` | `OPEN;11116;11115` | 11114 offen - final / 11115 beendet |
|    |  | `ERROR;11115` | 11115 offen - open |

**Fallbeispiel 2** — new → update (no confirm in between), then the three follow-ups

| Step | Input | Result | Status |
|---|---|---|---|
| 1 | `NEW` | `OPEN;11114` | 11114 offen - open |
| 2 | `UPDATE;11114` | `OPEN;11115;11114` | 11114 beendet |
|   |  | `ERROR;11114` | 11114 offen - open |
| 3a | `UPDATE;11115` | `OPEN;11116;11115` | 11115 beendet |
|    |  | `ERROR;11115` | 11115 offen - open |
| 3b | `CONFIRM;11115` | `FINAL;11115` | 11115 beendet (?) |
|    |  | `ERROR;11115` | 11115 offen - open |
| 3c | `DELETE;11115` | `DELETED;11115` | 11115 beendet |
|    |  | `ERROR;11115` | 11115 offen - open |

**Fallbeispiel 3** — new → delete

| Step | Input | Result | Status |
|---|---|---|---|
| 1 | `NEW` | `OPEN;11114` | 11114 offen - open |
| 2 | `DELETE;11114` | `DELETED;11114` | 11114 beendet |
|   |  | `ERROR;11114` | 11114 offen - open |

**Fallbeispiel 4** — caption on the sheet: *"Einer finalen Jahresmeldung folgt ein Update und diesem
Update ein nochmaliges Update. Das letzte Update wird deleted. Danach erfolgt ein neues Update auf
die finale Jahresmeldung."*

| Step | Input | Result | Status |
|---|---|---|---|
| 1 | `NEW` | `OPEN;11114` | 11114 offen - open |
| 2 | `CONFIRM;11114` | `FINAL;11114` | — |
| 3 | `UPDATE;11114` | `OPEN;11115;11114` | 11114 offen - final |
| 4 | `UPDATE;11115` | `OPEN;11116;11115` | 11114 offen - final |
| 5 | `DELETE;11116` | `DELETED;11116` | 11114 offen - final |
| 6 | `UPDATE;11114` | `OPEN;11117;11114` | 11114 offen - final |
| 7 | `CONFIRM;11117` | `FINAL;11117` | 11114 beendet |

The key rule the sheet encodes: every accepted `UPDATE` mints a **new** STM-ID and names its
predecessor (`OPEN;<new>;<old>`), an `ERROR` response leaves the state untouched, and step 6 shows
an update re-based on the *finale Jahresmeldung* (11114) rather than on the deleted 11116.

## Verification

- `magick identify` on the rotated/cropped tiles to confirm the crops cover the whole sheet with
  no band missed (four `Fallbeispiel` headings must each appear in exactly one tile).
- Re-read the finished `.md` against the full-sheet image one last time: every box on the sheet
  must appear as exactly one table row, and every table row must trace back to a box.
- Confirm the four `Fallbeispiel` sections and the Fallbeispiel 4 caption are present, and that
  the "Unklar" section is either empty (then removed) or lists only cells that really are illegible.
- No file outside the chosen docs path and the scratchpad is touched: `git status` shows exactly
  one new untracked file.
