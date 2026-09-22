---
paths:
  - "**/*.java"
---

# English Method Names

Method names are English. The verb is always English — `write`, not `schreibe`; `process`, not
`verarbeite`; `compare`, not `vergleiche`; `isEmptyLine`, not `istLeerzeile`.

German stays for **Fachbegriffe** only, and those live in type, field and record-component names
(`PreismeldungEingangProcessor`, `Meldekategorie`, `lineNumber`, `countByCode`) or as a noun inside an
otherwise English method name (`isHandelswaehrung`, `findReferenzpreis`, `getInboxZeilen`).

## How to apply

- Choose the verb in English every time you write a new method.
- Test method names follow the same rule: `whenProcess`, not `whenVerarbeite`.
- German verbs are acceptable only inside legacy Meldungstexte, which stay verbatim.

## Why

User requirement, set 2026-09-02 after Schnitt 1 Fondspreise. It matches the project CLAUDE.md
convention "Englisch für Technisches, Mischung erlaubt", which states the mixing rule but never
pins down which half the verb belongs to.
