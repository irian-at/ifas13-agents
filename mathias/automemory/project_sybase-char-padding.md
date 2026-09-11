---
name: project_sybase-char-padding
description: "Sybase pads char(n) columns, so short codes read back with trailing blanks; @Convert cannot fix it on @Id fields"
metadata: 
  node_type: memory
  type: project
  originSessionId: cbe1daac-4228-4eb2-ab07-125e1a82ff3e
  modified: 2026-09-08T09:49:22.794Z
---

Sybase returns `char(n)` columns space-padded: `kurs.cod_fliesscode char(2)` holding the Preiscode
`R` reads back as `"R "`, while Postgres and H2 return `"R"`. Same for `vwkn..wp_art_f.cod_art_f
char(4)` — `"AIF "`, while `FOND`/`TEST`/`C-PL` happen to fill the column exactly.

`ifas..INV.status` is **varchar(5)**, so `"V"`/`"L"` predicates on it are safe — check the legacy
`.cr` DDL before assuming either way.

**Why:** an untrimmed comparison silently fails only on Sybase (or only for the short values of a
column), and the Parallelbetrieb diff then reports a difference on every row.

**How to apply:** trim at the DB boundary. A JPA `@Convert` does **not** work on an `@Id`
attribute — the spec forbids it and Hibernate ignores it without a warning; use a hand-written
trimming getter over the field instead (`Kurs#getCodFliesscode`). For projection queries, trim in
the service that builds the domain record ([[project_stm-delivery-chain-test-harness]] style
boundary). A repository test over all three DBMS catches it; H2+Postgres alone does not.
