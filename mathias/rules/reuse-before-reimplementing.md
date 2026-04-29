---
paths:
  - "**/*.java"
---

# Reuse Before Reimplementing

Before adding any new tool, function, method, mapper, helper, validator, DTO, or service, search the codebase for an existing implementation. If something close already exists, propose adopting or extending it (extra parameter, generalized signature, lift to a shared module) instead of writing parallel near-identical code.

## When this rule applies

Every time you would create new Java code in this project — especially for "small" helpers, since duplicates accumulate fastest there.

## How to apply

- Search the relevant modules first: `support-libs/`, `ifas-domain/`, `ifas-services/`, `ifas-persistence-*/`, `ifas-web/`. Look for similar names, similar shapes, and callers of similar logic.
- In your proposal, state explicitly **what was searched** and **what was found**. If something close exists, propose extending or generalizing it as the default.
- Only introduce net-new code after explaining why each existing candidate doesn't fit.
- This is a hard requirement, not a soft preference: do not skip the search step to save time.

## Why

Past code duplication and parallel implementations have drifted apart over time, increasing maintenance cost and bug surface. Reuse keeps the IFAS13 codebase coherent.