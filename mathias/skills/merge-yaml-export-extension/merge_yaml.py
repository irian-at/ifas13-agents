#!/usr/bin/env python3
"""
Merge a FondsYamlExportTool extension YAML into a primary YAML, with optional
time-based filtering of STEUER_MELDUNG rows (and their dependents).

See SKILL.md in this directory for the full workflow. Quick reference:

  Analyze an extension YAML (no writes):
    merge_yaml.py --analyze gf2-yaml-extension.yaml.txt

  Merge with filtering:
    merge_yaml.py --merge \
        --original gf1-d20260724-export-AFTER.yaml.txt \
        --extension gf2-yaml-extension.yaml.txt \
        --exclude-stm-ids 649583,649584 \
        --exclude-file-ids 348758 \
        --new-isins LU2276928475,LU0136043394,LU0891777665,LU0012190491,LU0111465547 \
        [--dry-run]

Without --dry-run the original file is OVERWRITTEN in place. Back it up first.
"""
from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Iterable


ENTITY_HEADER_RE = re.compile(r'^- !<(\w+)>\s*$')
COMMENT_HEADER_RE = re.compile(r'^# ={2,} (\w+) ={2,}\s*$')


def parse_blocks(entity_text: str) -> list[dict]:
    """Tokenize an `entities:` section into ordered blocks.

    A block is one of:
        {'type': '<TAG>',    'lines': [...], 'body': str}   # an entity
        {'type': '_COMMENT', 'lines': [...]}                # a "# ====== ..." section header
        {'type': '_BLANK',   'lines': [...]}                # a blank line
        {'type': '_RAW',     'lines': [...]}                # anything else (defensive)
    """
    blocks: list[dict] = []
    lines = entity_text.splitlines(keepends=True)
    n = len(lines)
    i = 0
    while i < n:
        line = lines[i]
        if line.startswith('# '):
            blocks.append({'type': '_COMMENT', 'lines': [line]})
            i += 1
        elif line.startswith('- !<'):
            m = ENTITY_HEADER_RE.match(line.rstrip())
            etype = m.group(1) if m else '?'
            buf = [line]
            i += 1
            # consume indented (2-space) body lines, including embedded blank lines
            while i < n:
                nxt = lines[i]
                if nxt.startswith('  '):
                    buf.append(nxt)
                    i += 1
                    continue
                if nxt == '\n':
                    # look ahead — only consume blank if next non-blank stays indented
                    j = i + 1
                    while j < n and lines[j] == '\n':
                        j += 1
                    if j < n and lines[j].startswith('  '):
                        buf.append(nxt)
                        i += 1
                        continue
                break
            blocks.append({'type': etype, 'lines': buf, 'body': ''.join(buf)})
        elif line.strip() == '':
            blocks.append({'type': '_BLANK', 'lines': [line]})
            i += 1
        else:
            blocks.append({'type': '_RAW', 'lines': [line]})
            i += 1
    return blocks


def extract_entities_section(text: str) -> tuple[str, str]:
    """Split a YAML export into (header_through_entities_keyword, entities_body)."""
    m = re.search(r'^entities:\s*\n', text, re.MULTILINE)
    if not m:
        raise ValueError("could not find `entities:` line in YAML")
    return text[:m.end()], text[m.end():]


def field(body: str, name: str) -> str | None:
    """Read a top-level field from an entity body (`  name: value`). Returns the
    raw value with surrounding quotes stripped, or None if not present."""
    m = re.search(rf'^  {re.escape(name)}: (.*)$', body, re.MULTILINE)
    if not m:
        return None
    return m.group(1).strip().strip('"')


# ----------------------------------------------------------------------------
# Analyze
# ----------------------------------------------------------------------------

def analyze(extension_path: Path) -> None:
    text = extension_path.read_text()
    _, entities_text = extract_entities_section(text)
    blocks = parse_blocks(entities_text)

    # Map ISIN → numWfsKu via WKN_HIST (quelle = ISIN)
    isin_by_wfsku: dict[str, str] = {}
    for b in blocks:
        if b['type'] != 'WKN_HIST':
            continue
        if field(b['body'], 'quelle') == 'ISIN':
            wfsku = field(b['body'], 'numWfsKu')
            isin = field(b['body'], 'numWkn')
            if wfsku and isin:
                isin_by_wfsku[wfsku] = isin

    # Collect STEUER_MELDUNG_FILE
    files: dict[str, dict] = {}
    for b in blocks:
        if b['type'] == 'STEUER_MELDUNG_FILE':
            fid = field(b['body'], 'fileId')
            if fid:
                files[fid] = {
                    'filename': field(b['body'], 'filename') or '',
                    'datum': field(b['body'], 'datum') or '',
                    'startzeit': field(b['body'], 'startzeit') or '',
                    'lieferId': field(b['body'], 'lieferId') or '',
                }

    # Collect STEUER_MELDUNG
    meldungen: list[dict] = []
    for b in blocks:
        if b['type'] != 'STEUER_MELDUNG':
            continue
        meldungen.append({
            'id': field(b['body'], 'id') or '',
            'numWfsKu': field(b['body'], 'numWfsKu') or '',
            'versionsNr': field(b['body'], 'versionsNr') or '',
            'status': field(b['body'], 'status') or '',
            'eintragezeit': field(b['body'], 'eintragezeit') or '',
            'fileId': field(b['body'], 'fileId') or '',
            'confirmFileId': field(b['body'], 'confirmFileId') or '',
            'gjEnde': field(b['body'], 'gjEnde') or '',
        })

    # Summary
    print(f"Extension file: {extension_path}")
    print(f"Total entity blocks: {sum(1 for b in blocks if not b['type'].startswith('_'))}")
    print()

    print("=== ISIN ↔ numWfsKu (from WKN_HIST quelle=ISIN) ===")
    for wfsku, isin in sorted(isin_by_wfsku.items(), key=lambda x: x[1]):
        print(f"  {isin}  ↔  numWfsKu={wfsku}")
    print()

    print("=== STEUER_MELDUNG entries (grouped by fund) ===")
    by_fund: dict[str, list[dict]] = defaultdict(list)
    for m in meldungen:
        by_fund[m['numWfsKu']].append(m)
    for wfsku, ms in sorted(by_fund.items()):
        isin = isin_by_wfsku.get(wfsku, '?')
        print(f"\n  --- numWfsKu={wfsku}  (ISIN {isin}, {len(ms)} meldungen) ---")
        print(f"    {'id':>7s} {'v':>3s} {'status':>6s} {'eintragezeit':<26s} {'fileId':>7s} {'confirm':>7s} {'gjEnde':<12s}  filename")
        for m in ms:
            fid = m['fileId']
            fname = files.get(fid, {}).get('filename', '-')
            print(f"    {m['id']:>7s} {m['versionsNr']:>3s} {m['status']:>6s} {m['eintragezeit']:<26s} {fid:>7s} {m['confirmFileId'] or '-':>7s} {m['gjEnde']:<12s}  {fname}")

    print()
    print("=== STEUER_MELDUNG_FILE entries (sorted by startzeit) ===")
    print(f"  {'fileId':>7s} {'startzeit':<26s} {'lieferId':<10s} filename")
    for fid, f in sorted(files.items(), key=lambda kv: kv[1]['startzeit']):
        print(f"  {fid:>7s} {f['startzeit']:<26s} {f['lieferId']:<10s} {f['filename']}")


# ----------------------------------------------------------------------------
# Merge
# ----------------------------------------------------------------------------

def _should_drop(block: dict, exclude_stm_ids: set[str], exclude_file_ids: set[str]) -> bool:
    t = block['type']
    if t.startswith('_'):
        return False
    body = block.get('body', '')
    if t == 'STEUER_MELDUNG':
        sid = field(body, 'id')
        return sid is not None and sid in exclude_stm_ids
    if t in ('STEUER_FIELDS_DATA', 'STEUER_BEH_DATA'):
        sid = field(body, 'stmId')
        return sid is not None and sid in exclude_stm_ids
    if t == 'STEUER_MELDUNG_FILE':
        fid = field(body, 'fileId')
        return fid is not None and fid in exclude_file_ids
    return False


def _update_name_field(text: str, new_isins: list[str]) -> tuple[str, bool]:
    """Append `new_isins` to the comma-separated ISIN list in the YAML `name:` field.

    The YAML name typically looks like:
        name: "Fonds Export from 2026-02-25, ISINs = [AT0000495973, …,\
          \\ US33813J1060]"

    We inject just before the closing `]`. Returns (updated_text, did_update).
    """
    m = re.search(r'(ISINs = \[[^\]]+)\]"', text, re.DOTALL)
    if not m:
        return text, False
    insertion = ',\\\n  \\ ' + ', '.join(new_isins)
    new_text = text[:m.end(1)] + insertion + text[m.end(1):]
    return new_text, True


def _count_entities_by_type(text: str) -> dict[str, int]:
    counts: dict[str, int] = defaultdict(int)
    for m in re.finditer(r'^- !<(\w+)>', text, re.MULTILINE):
        counts[m.group(1)] += 1
    return dict(counts)


def merge(
    original_path: Path,
    extension_path: Path,
    exclude_stm_ids: set[str],
    exclude_file_ids: set[str],
    new_isins: list[str],
    dry_run: bool,
) -> None:
    orig_text = original_path.read_text()
    ext_text = extension_path.read_text()

    _, ext_entities = extract_entities_section(ext_text)
    blocks = parse_blocks(ext_entities)

    # Resolve file_ids of meldungen we keep, so we can drop file rows nobody references
    kept_meldung_file_refs: set[str] = set()
    for b in blocks:
        if b['type'] != 'STEUER_MELDUNG':
            continue
        if _should_drop(b, exclude_stm_ids, exclude_file_ids):
            continue
        body = b.get('body', '')
        for fname in ('fileId', 'confirmFileId'):
            v = field(body, fname)
            if v:
                kept_meldung_file_refs.add(v)

    # Apply filter; for STEUER_MELDUNG_FILE, additionally drop file rows no kept meldung refs
    kept: list[dict] = []
    dropped: dict[str, int] = defaultdict(int)
    for b in blocks:
        if _should_drop(b, exclude_stm_ids, exclude_file_ids):
            dropped[b['type']] += 1
            continue
        # extra check: STEUER_MELDUNG_FILE not referenced by any kept meldung → drop
        if b['type'] == 'STEUER_MELDUNG_FILE':
            fid = field(b.get('body', ''), 'fileId')
            if fid and fid not in kept_meldung_file_refs:
                dropped['STEUER_MELDUNG_FILE'] += 1
                continue
        kept.append(b)

    appended_text = ''.join(''.join(b['lines']) for b in kept)

    # Build the merged file
    if new_isins:
        updated_orig, ok = _update_name_field(orig_text, new_isins)
        if not ok:
            print("WARN: could not find ISIN list in name: field; --new-isins not applied", file=sys.stderr)
            updated_orig = orig_text
    else:
        updated_orig = orig_text

    if not updated_orig.endswith('\n'):
        updated_orig += '\n'

    merged = updated_orig + appended_text

    # Report
    orig_counts = _count_entities_by_type(orig_text)
    merged_counts = _count_entities_by_type(merged)
    print(f"Original:  {original_path}  ({len(orig_text):,} bytes)")
    print(f"Extension: {extension_path} ({len(ext_text):,} bytes)")
    print(f"Excluding STEUER_MELDUNG ids: {sorted(exclude_stm_ids) or '(none)'}")
    print(f"Excluding STEUER_MELDUNG_FILE fileIds: {sorted(exclude_file_ids) or '(none)'}")
    print(f"New ISINs to append to name: {new_isins or '(none)'}")
    print()
    print(f"{'Entity':<26s} {'Original':>10s} {'Merged':>10s} {'Delta':>10s}")
    for t in sorted(set(orig_counts) | set(merged_counts)):
        o = orig_counts.get(t, 0)
        nn = merged_counts.get(t, 0)
        if o != nn:
            print(f"  {t:<24s} {o:>10d} {nn:>10d} {nn - o:>+10d}")
    print()
    print("Dropped (would-be-appended but excluded):")
    for t, c in sorted(dropped.items()):
        print(f"  {t}: {c}")

    if dry_run:
        print("\n--dry-run: not writing.")
        return

    original_path.write_text(merged)
    print(f"\nWrote merged file to {original_path} ({len(merged):,} bytes)")


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------

def _parse_csv(s: str) -> list[str]:
    return [x.strip() for x in s.split(',') if x.strip()]


def extract(
    source_path: Path,
    output_path: Path,
    include_stm_ids: set[str],
    include_isins: set[str],
    dry_run: bool,
) -> None:
    """Carve a minimal extension YAML out of a primary YAML.

    Two selection axes (combine freely):

    * ``include_stm_ids`` — keep the listed STEUER_MELDUNG ids only (plus their
      FIELDS_DATA / BEH_DATA dependents and the STEUER_MELDUNG_FILE rows the kept
      meldungen reference). Use this when sybase-gast lost specific stmIds you need.

    * ``include_isins`` — keep ALL fund-specific data for the listed ISINs:
      WKN_HIST, WKN_DESC, INV, INV_H, KEST98, LIEFER_STATUS_GESAMT, GESCHAEFTSJAHR,
      plus every STEUER_MELDUNG for those funds and their dependents and file rows.
      Use this when an ISIN is missing entirely from the merge target (no WKN_HIST →
      "ISIN nicht fuer eine Steuerdatenmeldung registriert" in validation).

    Reference data (LIEFERANT, KAG, HDP, ABSICHT, BOERSE, WAEHRUNG, …) is never
    extracted — the merge target is expected to already have it. If it doesn't,
    importer dedup will accept whatever's already there and the missing rows surface
    as FK errors at test time.
    """
    if not include_stm_ids and not include_isins:
        raise ValueError("extract: provide --include-stm-ids and/or --include-isins")

    # Small lookup tables that STEUER_MELDUNG / INV / WKN_HIST etc. reference by code.
    # All rows are included from the source; the merge importer dedupes by primary key, so
    # carrying them forward is cheap insurance against the target not having a specific code
    # (e.g. STM_KAPITALRUECKZAHLUNG="N" used only by funds outside the target's original ISIN set).
    SMALL_REFERENCE_TYPES = {
        'ABSICHT', 'BOERSE', 'GJ_TYP', 'HDP', 'HWA', 'KAG', 'KURSBLATT', 'LEI_STATUS',
        'LIEFERANT', 'QUELLE', 'STATUS_FMV', 'STEUER_MELDUNG_STATUS',
        'STEUER_MELDUNG_VERSION', 'STM_ERTRAGSTYP', 'STM_KAPITALRUECKZAHLUNG',
        'STM_W_RABATT_ART', 'WAEHRUNG', 'WP_ART_F', 'WP_ART_G',
    }

    text = source_path.read_text()
    header, entities = extract_entities_section(text)
    blocks = parse_blocks(entities)

    # Pass 1: resolve ISINs → numWfsKu + wknDesc sets via WKN_HIST.
    #   WKN_HIST.numWkn == ISIN (when quelle="ISIN"); WKN_HIST.numWfsKu == fund security id;
    #   WKN_HIST.wknDesc == WKN_DESC.wfsWkn == INV.wfsWkn == INV_H.wfsWkn.
    isin_num_wfs_ku: set[str] = set()
    isin_wkn_desc: set[str] = set()
    if include_isins:
        for b in blocks:
            if b['type'] != 'WKN_HIST':
                continue
            body = b.get('body', '')
            if field(body, 'numWkn') not in include_isins:
                continue
            wfs = field(body, 'numWfsKu')
            wd = field(body, 'wknDesc')
            if wfs:
                isin_num_wfs_ku.add(wfs)
            if wd:
                isin_wkn_desc.add(wd)

    # Pass 2: expand include_stm_ids with all STEUER_MELDUNG ids of the resolved funds.
    full_stm_ids: set[str] = set(include_stm_ids)
    referenced_file_ids: set[str] = set()
    for b in blocks:
        if b['type'] != 'STEUER_MELDUNG':
            continue
        body = b.get('body', '')
        mid = field(body, 'id')
        if mid is None:
            continue
        if mid in include_stm_ids or field(body, 'numWfsKu') in isin_num_wfs_ku:
            full_stm_ids.add(mid)
            for fname in ('fileId', 'confirmFileId'):
                v = field(body, fname)
                if v:
                    referenced_file_ids.add(v)

    # Pass 3: walk blocks, decide based on the resolved sets.
    kept: list[dict] = []
    kept_counts: dict[str, int] = defaultdict(int)
    for b in blocks:
        t = b['type']
        if t.startswith('_'):
            continue  # skip raw comments / blanks — extension stays compact
        body = b.get('body', '')
        keep = False
        if t == 'STEUER_MELDUNG':
            keep = field(body, 'id') in full_stm_ids
        elif t in ('STEUER_FIELDS_DATA', 'STEUER_BEH_DATA'):
            keep = field(body, 'stmId') in full_stm_ids
        elif t == 'STEUER_MELDUNG_FILE':
            keep = field(body, 'fileId') in referenced_file_ids
        elif t == 'WKN_HIST':
            # Keep all WKN_HIST rows for the kept funds — same fund has multiple rows
            # (one per quelle: ISIN, OEKB, etc.), all needed for FK integrity.
            keep = (field(body, 'numWkn') in include_isins
                    or field(body, 'numWfsKu') in isin_num_wfs_ku)
        elif t == 'WKN_DESC':
            # WKN_DESC's primary key is `numWfs` (matches WKN_HIST.wknDesc / INV.wfsWkn).
            keep = field(body, 'numWfs') in isin_wkn_desc
        elif t in ('INV', 'INV_H', 'GESCHAEFTSJAHR'):
            # All three keyed by `wfsWkn`, which holds the wknDesc value (not the numWfsKu).
            keep = field(body, 'wfsWkn') in isin_wkn_desc
        elif t in ('KEST98', 'LIEFER_STATUS_GESAMT'):
            keep = field(body, 'numWfsKu') in isin_num_wfs_ku
        elif t in SMALL_REFERENCE_TYPES:
            # Small lookup tables — always include all rows. Cheap insurance against the
            # merge target missing a specific code (importer dedupes the duplicates).
            keep = True
        # STEUER_FIELD / STEUER_BEH_FIELD (large; ~3k rows shared across all funds) are
        # left out — assume the merge target's reference data already covers them.
        if keep:
            kept.append(b)
            kept_counts[t] += 1

    # Build the extension YAML. The name field is rewritten to reflect what's in here.
    selectors: list[str] = []
    if include_stm_ids:
        selectors.append(f'STEUER_MELDUNG[{",".join(sorted(include_stm_ids))}]')
    if include_isins:
        selectors.append(f'ISINs[{",".join(sorted(include_isins))}]')
    name_line = f'name: "Extracted from {source_path.name}: {" + ".join(selectors)}"\n'
    out_text = '--- !<Data>\n' + name_line + 'entities:\n' + ''.join(
        ''.join(b['lines']) for b in kept
    )

    print(f"Source:  {source_path}")
    if include_stm_ids:
        print(f"Include STEUER_MELDUNG ids: {sorted(include_stm_ids)}")
    if include_isins:
        print(f"Include ISINs: {sorted(include_isins)}")
        print(f"  → resolved numWfsKu: {sorted(isin_num_wfs_ku) or '(none)'}")
        print(f"  → resolved wknDesc: {sorted(isin_wkn_desc) or '(none)'}")
    print(f"Referenced fileIds carried forward: {sorted(referenced_file_ids) or '(none)'}")
    print()
    print(f"{'Entity':<26s} {'Kept':>10s}")
    for t, c in sorted(kept_counts.items()):
        print(f"  {t:<24s} {c:>10d}")
    if include_stm_ids:
        missing = include_stm_ids - {field(b['body'], 'id') for b in blocks if b['type'] == 'STEUER_MELDUNG'}
        if missing:
            print(f"\nWARN: these requested stmIds were NOT found in the source: {sorted(missing)}")
    if include_isins:
        missing_isins = include_isins - {field(b['body'], 'numWkn') for b in blocks if b['type'] == 'WKN_HIST'}
        if missing_isins:
            print(f"\nWARN: these requested ISINs were NOT found in the source: {sorted(missing_isins)}")
    print(f"\nOutput size: {len(out_text):,} bytes")

    if dry_run:
        print("--dry-run: not writing.")
        return

    output_path.write_text(out_text)
    print(f"Wrote extracted extension to {output_path}")


def prune(
    path: Path,
    exclude_stm_ids: set[str],
    cascade: bool,
    dry_run: bool,
) -> None:
    """Drop the given STEUER_MELDUNG ids (and their dependents) from a primary YAML in place.

    With ``cascade=True`` (default), also drops any meldung whose ``vorherigeStmId`` or
    ``vorherigeFinalStmId`` points to a dropped meldung — chained until stable. Without cascade,
    leaves orphan successors in place and prints a warning (the resulting YAML will have FK
    violations on import).

    STEUER_MELDUNG_FILE rows that no surviving meldung references are dropped automatically.
    STEUER_FIELDS_DATA / STEUER_BEH_DATA rows pointing to dropped meldungen are dropped.

    With ``dry_run=True``, prints what would change and does not write.
    """
    text = path.read_text()
    header, entities = extract_entities_section(text)
    blocks = parse_blocks(entities)

    # Index meldung ids that exist in the file and build predecessor pointers
    all_meldung_ids: set[str] = set()
    successor_of: dict[str, list[str]] = defaultdict(list)
    for b in blocks:
        if b['type'] != 'STEUER_MELDUNG':
            continue
        body = b.get('body', '')
        mid = field(body, 'id')
        if not mid:
            continue
        all_meldung_ids.add(mid)
        for fname in ('vorherigeStmId', 'vorherigeFinalStmId'):
            pred = field(body, fname)
            if pred:
                successor_of[pred].append(mid)

    # Cascade: expand the drop set with successors of dropped meldungen, until stable.
    drop_set = set(exclude_stm_ids)
    cascade_added: list[tuple[str, str]] = []  # (added_id, reason_predecessor)
    if cascade:
        frontier = list(drop_set)
        while frontier:
            new_frontier = []
            for pred in frontier:
                for succ in successor_of.get(pred, []):
                    if succ not in drop_set:
                        drop_set.add(succ)
                        cascade_added.append((succ, pred))
                        new_frontier.append(succ)
            frontier = new_frontier

    # Check for orphan successors when cascade is off
    if not cascade:
        orphans = []
        for pred in drop_set:
            for succ in successor_of.get(pred, []):
                if succ not in drop_set:
                    orphans.append((succ, pred))
        if orphans:
            print("WARN: orphan successors will remain (FK violations on import):", file=sys.stderr)
            for s, p in orphans:
                print(f"  meldung {s} -> dropped predecessor {p}", file=sys.stderr)

    # Resolve still-referenced file ids from kept meldungen
    kept_meldung_file_refs: set[str] = set()
    for b in blocks:
        if b['type'] != 'STEUER_MELDUNG':
            continue
        body = b.get('body', '')
        mid = field(body, 'id')
        if mid in drop_set:
            continue
        for fname in ('fileId', 'confirmFileId'):
            v = field(body, fname)
            if v:
                kept_meldung_file_refs.add(v)

    # Filter blocks
    kept: list[dict] = []
    dropped: dict[str, int] = defaultdict(int)
    for b in blocks:
        t = b['type']
        if t.startswith('_'):
            kept.append(b)
            continue
        body = b.get('body', '')
        if t == 'STEUER_MELDUNG':
            if field(body, 'id') in drop_set:
                dropped[t] += 1
                continue
        elif t in ('STEUER_FIELDS_DATA', 'STEUER_BEH_DATA'):
            if field(body, 'stmId') in drop_set:
                dropped[t] += 1
                continue
        elif t == 'STEUER_MELDUNG_FILE':
            fid = field(body, 'fileId')
            if fid and fid not in kept_meldung_file_refs:
                dropped[t] += 1
                continue
        kept.append(b)

    new_entities = ''.join(''.join(b['lines']) for b in kept)
    new_text = header + new_entities

    before = _count_entities_by_type(text)
    after = _count_entities_by_type(new_text)
    print(f"Pruning {path}")
    print(f"  Explicitly excluded: {sorted(exclude_stm_ids) or '(none)'}")
    if cascade_added:
        print(f"  Cascade-dropped successors ({len(cascade_added)}):")
        for s, p in cascade_added:
            print(f"    {s}  (predecessor {p})")
    print()
    print(f"{'Entity':<26s} {'Before':>10s} {'After':>10s} {'Delta':>10s}")
    for t in sorted(set(before) | set(after)):
        b_, a_ = before.get(t, 0), after.get(t, 0)
        if b_ != a_:
            print(f"  {t:<24s} {b_:>10d} {a_:>10d} {a_ - b_:>+10d}")
    print()
    print("Dropped by type:")
    for t, c in sorted(dropped.items()):
        print(f"  {t}: {c}")

    if dry_run:
        print("\n--dry-run: not writing.")
        return

    path.write_text(new_text)
    print(f"\nWrote pruned file to {path} ({len(new_text):,} bytes)")


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog='merge_yaml.py',
        description='Analyze or merge FondsYamlExportTool YAML files. See SKILL.md.',
    )
    sub = p.add_subparsers(dest='mode', required=False)

    # --analyze is a convenience flag, not a subcommand
    p.add_argument('--analyze', metavar='EXT_YAML',
                   help='Analyze an extension YAML; print meldungen and file tables. No writes.')

    p.add_argument('--merge', action='store_true',
                   help='Perform the merge (requires --original and --extension).')
    p.add_argument('--prune', action='store_true',
                   help='Prune STEUER_MELDUNG ids from a primary YAML in place '
                        '(requires --original and --exclude-stm-ids). Cascades to successor meldungen.')
    p.add_argument('--extract', action='store_true',
                   help='Extract a minimal extension YAML from a source YAML. '
                        'Requires --source, --output, and at least one of '
                        '--include-stm-ids / --include-isins.')
    p.add_argument('--source', metavar='SOURCE_YAML',
                   help='With --extract: path to the source YAML to extract from.')
    p.add_argument('--output', metavar='OUTPUT_YAML',
                   help='With --extract: path to write the extracted extension YAML to.')
    p.add_argument('--include-stm-ids', default='',
                   help='With --extract: comma-separated STEUER_MELDUNG ids to keep.')
    p.add_argument('--include-isins', default='',
                   help='With --extract: comma-separated ISINs whose fund-specific data '
                        '(WKN_HIST, INV, INV_H, KEST98, LIEFER_STATUS_GESAMT, '
                        'GESCHAEFTSJAHR, all STEUER_MELDUNG for the fund, ...) should be kept.')
    p.add_argument('--original', metavar='PRIMARY_YAML',
                   help='Path to the primary YAML that will be extended/pruned (will be OVERWRITTEN unless --dry-run).')
    p.add_argument('--extension', metavar='EXT_YAML',
                   help='Path to the extension YAML.')
    p.add_argument('--exclude-stm-ids', default='',
                   help='Comma-separated STEUER_MELDUNG ids to drop (drops their FIELDS_DATA/BEH_DATA too).')
    p.add_argument('--exclude-file-ids', default='',
                   help='Comma-separated STEUER_MELDUNG_FILE fileIds to drop explicitly.')
    p.add_argument('--no-cascade', action='store_true',
                   help='With --prune: do NOT cascade-drop successor meldungen whose '
                        'vorherigeStmId/vorherigeFinalStmId points to a dropped meldung. '
                        'Default is to cascade. Without cascade the YAML may have FK violations on import.')
    p.add_argument('--new-isins', default='',
                   help='Comma-separated ISINs to append to the name: field of the primary YAML.')
    p.add_argument('--dry-run', action='store_true',
                   help='Print counts but do not write.')

    args = p.parse_args(argv)

    if args.analyze:
        analyze(Path(args.analyze))
        return 0

    if args.merge:
        if not args.original or not args.extension:
            p.error('--merge requires --original and --extension')
        merge(
            original_path=Path(args.original),
            extension_path=Path(args.extension),
            exclude_stm_ids=set(_parse_csv(args.exclude_stm_ids)),
            exclude_file_ids=set(_parse_csv(args.exclude_file_ids)),
            new_isins=_parse_csv(args.new_isins),
            dry_run=args.dry_run,
        )
        return 0

    if args.prune:
        if not args.original or not args.exclude_stm_ids:
            p.error('--prune requires --original and --exclude-stm-ids')
        prune(
            path=Path(args.original),
            exclude_stm_ids=set(_parse_csv(args.exclude_stm_ids)),
            cascade=not args.no_cascade,
            dry_run=args.dry_run,
        )
        return 0

    if args.extract:
        if not args.source or not args.output:
            p.error('--extract requires --source and --output')
        if not args.include_stm_ids and not args.include_isins:
            p.error('--extract requires at least one of --include-stm-ids / --include-isins')
        extract(
            source_path=Path(args.source),
            output_path=Path(args.output),
            include_stm_ids=set(_parse_csv(args.include_stm_ids)),
            include_isins=set(_parse_csv(args.include_isins)),
            dry_run=args.dry_run,
        )
        return 0

    p.print_help()
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
