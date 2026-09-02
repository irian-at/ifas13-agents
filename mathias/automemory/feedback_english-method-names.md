---
name: english-method-names
description: "Methodennamen englisch (write/process/compare), deutsch nur für Fachbegriffe in Typ-/Feldnamen."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 29d00419-c8e9-488e-8e21-00dd20901780
  modified: 2026-09-02T14:31:14.967Z
---

Methodennamen sind englisch — `write` statt `schreibe`, `process` statt `verarbeite`, `compare`
statt `vergleiche`, `isEmptyLine` statt `istLeerzeile`. Deutsch bleiben nur **Fachbegriffe**, und
die stehen in Typ-, Feld- und Record-Komponenten-Namen (`PreismeldungEingang`, `Meldekategorie`,
`zeilenNr`, `anzahlJeCode`) oder als Substantiv im englischen Methodennamen
(`isHandelswaehrung`, `findReferenzpreis`, `getInboxZeilen`).

**Why:** User-Vorgabe 2026-09-02 nach Schnitt 1 Fondspreise; deckt sich mit der
CLAUDE.md-Konvention „Englisch für Technisches, Mischung erlaubt".

**How to apply:** Beim Schreiben neuer Methoden das Verb immer englisch wählen; deutsche Verben
nur in Legacy-Meldungstexten (die bleiben wortgetreu). Betrifft auch Test-Methodennamen
(`whenProcess`, nicht `whenVerarbeite`).
