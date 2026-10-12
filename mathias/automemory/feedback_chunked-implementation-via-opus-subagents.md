---
name: chunked-implementation-via-opus-subagents
description: "Feature implementation runs as small, independently committable chunks (schema + entities first, live wiring last), each delegated to an Opus 5.5 subagent while Fable orchestrates and reviews."
metadata:
  node_type: memory
  type: feedback
  originSessionId: 387e3d2c-8336-466c-adf5-16dc3c0c3429
  modified: 2026-10-01T08:18:13.271Z
---

For feature work (set 2026-10-01 at the start of the Fondspreise `preis_historie` implementation):

- Split into **small chunks that each build, test and can be committed on their own**, in dependency
  order with the *persistence* first (migration + entities + repositories), pure domain next, the
  behaviour change to existing code after that, and the "plug it into the live chain" commit last.
  Nothing in an earlier chunk may change what the running system does.
- **Delegate the implementation to an Opus 5.5 subagent** (`model: "opus"`) with a self-contained
  brief: plan sections, rule files, exact scope, verification commands, and what to report. Fable
  gathers context, writes the brief, reviews the result and reports.
- Do not commit on the user's behalf; leave the verified chunk in the working tree. He stages and
  commits himself (see [[user-intellij-git-add]]) or asks for `/commit`.
- Open with a short numbered overview of the remaining steps before starting the first one.

**Why:** reviewable units, cheaper model for the mechanical part, and no half-wired state on master.

**How to apply:** at the start of any multi-chunk feature, print the step list, then dispatch one
chunk at a time; independent chunks (e.g. pure domain vs. persistence) may be offered to run in
parallel. Related: [[only-change-what-was-asked]], [[flyway-one-file-per-feature]],
[[fondspreise-stufe-split]].
