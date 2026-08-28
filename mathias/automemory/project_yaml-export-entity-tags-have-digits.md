---
name: project_yaml-export-entity-tags-have-digits
description: Fonds/testdata YAML export tags can contain digits (KEST98) — a `[A-Z_]+` regex silently drops them.
metadata:
  type: project
---

Entity tags in the `DatabaseYamlExportTool` format are `- !<TYPE>` at column 0, and at least one
type carries a digit: `KEST98` (the fund's §98-KESt Stammdaten, keyed by `numWfsKu`). A block-splitting
regex of `^- !<([A-Z_]+)>` skips those lines, so they get folded into the neighbouring block and
disappear from any filtered rewrite.

**Why:** the loss is silent — the import just reports fewer entities, and the symptom shows up much
later as an unexplained extra validation message (`… KESt auf Zinsen gem. Para. 98 EStG 1988 <NEIN>
weicht von dem bei den Stammdaten … angegebenen Wert <leer> ab`).

**How to apply:** use `^- !<([A-Z0-9_]+)>` when scripting a fixture trim, and verify afterwards that
every entity type the filter does not target has an unchanged count and that each kept block still
occurs verbatim in the original. Related: [[project_recalc-fixture-data-recovery]].
