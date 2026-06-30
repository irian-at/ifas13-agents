---
name: find-missing-isins-for-yaml-extension
description: Identify which ISINs a grossfile run (`gfN-d<yyyymmdd>`) needs that aren't yet represented in the merged YAML fixture sitting next to it. Produces the ISIN list the user feeds into `FondsYamlExportTool` to create the next `*-yaml-extension.yaml.txt` for the [[merge-yaml-export-extension]] step. Use this when the user says "prepare a yaml extension for gfN", "what ISINs are missing from the gfN yaml", or before merging a new extension.
---

# Find ISINs Missing From YAML Extension

This is the **first** step of preparing a YAML extension for a grossfile fixture. The `merge-yaml-export-extension` skill is the second step. They are designed to be used together.

## When to use this skill

- User says "I need to prepare a yaml extension for gfN" / "which ISINs are missing from the gfN yaml".
- Before re-exporting the DB for missing ISINs: you need the ISIN list to pass to `FondsYamlExportTool`.

## When NOT to use this skill

- You already have the extension YAML and just want to merge it → [[merge-yaml-export-extension]].
- The user wants to *change* the gfN CSV inputs, not extend the YAML test setup.

## Inputs

Everything is in `ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/recalc/grossfiles/gfN-d<yyyymmdd>/`:

- `gfN-d<yyyymmdd>.csv`, `_confirm.csv`, `_delete.csv` — the grossfile CSV inputs (lines `START;<ISIN>;…` and `END;<ISIN>;…`).
- The merged YAML file that lives alongside, named after the **previous** grossfile (e.g. inside `gf3-d20260805/` the YAML is `gf2-d20260731-export-AFTER.yaml.txt`). This is the cumulative test fixture that gfN runs against.

If the directory only contains a `.zip`, unzip it first (or use `unzip -l` to inspect the YAML's name).

## Procedure

```bash
cd ifas-testing/ifas-integration-tests/src/test/resources/at/oekb/ifas/domain/recalc/grossfiles/gfN-d<yyyymmdd>/

# 1. ISINs the grossfile references — START rows are authoritative; _confirm/_delete usually overlap but include them for safety.
grep -hE '^START;[A-Z]{2}[A-Z0-9]{9}[0-9];' gfN-d<yyyymmdd>.csv gfN-d<yyyymmdd>_confirm.csv gfN-d<yyyymmdd>_delete.csv \
  | cut -d';' -f2 | sort -u > /tmp/gfN.csv.isins

# 2. ISINs claimed by the YAML — two independent signals; they should agree.
#    (a) the multi-line `name:` header
awk '/^name:/{flag=1} flag{print; if(/]/){exit}}' *-export-AFTER.yaml.txt \
  | grep -oE '[A-Z]{2}[A-Z0-9]{9}[0-9]' | sort -u > /tmp/gfN.yaml.name.isins

#    (b) `WKN_HIST` entries — the authoritative structural check (`numWkn: "<ISIN>"`)
grep -oE 'numWkn: "[A-Z]{2}[A-Z0-9]{9}[0-9]"' *-export-AFTER.yaml.txt \
  | grep -oE '[A-Z]{2}[A-Z0-9]{9}[0-9]' | sort -u > /tmp/gfN.yaml.wkn.isins

# 3. Diff — these should produce the same list. If they differ, prefer the WKN_HIST list (truth) and flag the name-header drift to the user.
comm -23 /tmp/gfN.csv.isins /tmp/gfN.yaml.name.isins   # missing (per name header)
comm -23 /tmp/gfN.csv.isins /tmp/gfN.yaml.wkn.isins    # missing (per WKN_HIST — authoritative)
```

## Sanity checks

- Both `comm` outputs should match. If `name` says present but `WKN_HIST` says missing, the name header is stale (a previous merge forgot to extend it) — trust the `WKN_HIST` result.
- Counts: gfN CSV typically lists 20-40 ISINs; the cumulative YAML typically holds 50-80. A missing-set of 5-15 ISINs is normal for a new grossfile.
- The ISIN regex `[A-Z]{2}[A-Z0-9]{9}[0-9]` matches the 12-char ISIN format used in the fixtures (including ones with embedded letters like `IE00B03HCZ61`). Do not relax it to `[A-Z0-9]{12}` — that would match unrelated tokens.

## Handoff

Give the user:

1. The missing-ISIN list as a comma-separated string (the form `FondsYamlExportTool` expects).
2. A note on which YAML and grossfile they apply to.

Example handoff line:
> "12 ISINs are missing from `gf3-d20260805/gf2-d20260731-export-AFTER.yaml.txt`. Re-export the DB with: `AT0000495973,DE0008478116,IE0007472115,…`. Save the result as `gf3-yaml-extension.yaml.txt` and then run the [[merge-yaml-export-extension]] skill."

## Notes / gotchas

- **Cutoff time T for the merge step**: the extension you produce after this step is a *current* DB snapshot. If gfN+1 has already run when you export, you must time-filter the extension (drop post-T meldungen) — that's the merge skill's job, not this one's. Just note T for the user: read it from `gfN-d<yyyymmdd>_return.csv`'s `END;<ISIN>;<timestamp>` lines (latest one wins) or use the grossfile's nominal date `<yyyymmdd>`.
- **The YAML in the gfN fixture is named after gfN-1** by convention. Don't be confused — the test setup for gfN is the cumulative state *after* gfN-1.
- **Per-ISIN export loops in the YAML** mean the same ISIN's `WKN_HIST` row can appear multiple times. `sort -u` handles that.
- **Don't expand the regex to match non-ISIN identifiers** like `numWfsKu` (security id, numeric) — those are fund-internal IDs, not what `FondsYamlExportTool` takes.
