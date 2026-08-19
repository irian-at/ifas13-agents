# Analyse: Auto-Flush-Problem beim `geschaeftsjahre.write-enabled`-Gate

## Ausgangsfrage

Warum wurde in Commit `072fd85f` (6. Mai 2026) das TODO für Manfred bzgl. Hibernate-Auto-Flush
hinzugefügt? Wo genau ist das Problem aufgetreten, und ist vorher ein Test fehlgeschlagen?

## Kurzantwort

- **Kein Plan-File und keine Memory dokumentieren das Problem.** Weder unter
  `mathias/plans/` (bzw. `.../archive/`) noch unter `~/.claude/plans/` oder in den
  überschriebenen Memories unter `~/.claude/projects/-home-sma-dev-projects-oekb-ifas13/memory/`
  gibt es einen Eintrag dazu. Die einzige GJ-Memory (`gj-calc-rawlastchance-canonical`) betrifft
  `calcRawLastChance` für B-Zeilen, nicht das Auto-Flush-Thema.
- **Es ist kein Test fehlgeschlagen.** Das Problem wurde zur Laufzeit beobachtet — nämlich dass
  das einen Tag zuvor eingeführte `write-enabled`-Gate *nicht* wirkte.

## Wo das Problem aufgetreten ist: das `write-enabled`-Gate vom Vortag

Auslöser war das Feature, das nur einen Tag vorher ausgeliefert wurde:

- **5. Mai** — `443331b51 feat: add Geschaeftsjahre write-enabled configuration and logging logic`
  führte die Property `geschaeftsjahre.write-enabled` ein (in TEST/QAS/PROD auf `false`), damit
  IFAS **keine** fabrizierten/nachbefüllten GJ-Zeilen in die DB schreibt. Das Gate sitzt in
  `GeschaeftsjahreDomainService.saveGeschaeftsjahrEntity`: bei `!isWriteEnabled()` wird
  „Skipping Geschaeftsjahr save“ geloggt und ohne Persistieren zurückgekehrt.
- **6. Mai** — `03c845c3a` setzte den Default auf `false`, danach folgte `072fd85f` (das TODO-Commit).

**Das eigentliche Problem:** Trotz deaktiviertem Gate wurden GJ-Zeilen weiterhin in der DB
verändert. `updateMissingDeadlineDates` mutierte eine **managed (attached) Hibernate-Entität** per
Setter (`gj.setLastChance(...)` usw.). Hibernates Dirty-Checking-Auto-Flush schrieb diese Felder
beim nächsten Flush-Zeitpunkt zurück — **komplett am gegateten `saveGeschaeftsjahrEntity`-Pfad
vorbei**. Der ganze Sinn von `write-enabled=false` wurde für den Deadline-Nachfüll-Fall still
ausgehebelt. Genau das meint das TODO mit „it is saved outside of our persister that uses the
geschaeftsjahre.write-enabled property".

## Warum kein Test das gefangen hat

- Die Teständerung in `072fd85f` war `isSameAs` → `isEqualTo`. Das ist die *umgekehrte* Richtung
  einer „Test hat Bug gefunden"-Geschichte: der Fix (Rückgabe einer `toBuilder()`-**Kopie** statt
  In-Place-Mutation) hat die `isSameAs`-Identitätsassertions *gebrochen*, weshalb sie auf
  `isEqualTo` gelockert werden mussten. Vor der Änderung waren diese Tests grün.
- Die Unit-Tests laufen über `MockGeschaeftsjahreService` mit einem **Identity-In-Memory-Persister**
  — kein EntityManager, kein Dirty-Checking, kein Flush. Auto-Flush ist dort strukturell unsichtbar.
- Das Problem schlägt nur zur Laufzeit gegen einen echten Persistence-Context zu (Integrationstest
  mit `write-enabled=true` oder echte Umgebung, wo man unerwartete GJ-Writes trotz Gate beobachtet).

⇒ Gefunden wurde es durch **Beobachtung, dass das Gate nicht griff** (GJ-Zeilen änderten sich in der
DB, obwohl Writes aus sein sollten), nicht durch einen roten Test. Regressionsabdeckung kam erst
später mit Manfreds Fix.

## Der ursprüngliche Workaround (072fd85f)

- `@Builder(toBuilder = true)` auf `Geschaeftsjahr` ergänzt.
- `updateMissingDeadlineDates` gibt statt der mutierten Entität eine **Kopie** via `gj.toBuilder()`
  zurück (`Optional<Geschaeftsjahr>`), die dann explizit über `geschaeftsjahrPersister` läuft.
- Zusätzlich `else if` → unabhängige `if` geändert (TODO 2): vorher wurde pro Aufruf nur **eines**
  der vier Deadline-Felder (`lastChance`/`mahnungAb`/`snBeginn`/`snEnde`) befüllt.
- Zwei TODOs für Manfred: (1) Kopie ist nur Workaround, Alternative wäre Detach der Entitäten;
  (2) Bitte die `if`-Umstellung verifizieren.

## Auflösung (009ca3637, Manfred, 16. Juli 2026)

Manfred wählte die im TODO vorgeschlagene **andere Option: Entitäten detachen**.

- `GeschaeftsjahreDomainService.java:88`:
  `geschaeftsjahre.forEach(em::detach)` in `getExistingOrderedGeschaeftsjahre`
  — Kommentar: *„Detach from the EntityManager to avoid dirty flushes when persisting is actually
  disabled"*.
- Die Builder-Kopie wurde wieder auf direkte Setter zurückgebaut (die unabhängige `if`-Umstellung
  aus TODO 2 blieb erhalten).
- Regressionsabdeckung ergänzt: Fixture `IE0009GHRM76.yaml.txt` + Änderung an
  `GeschaeftsjahreDomainServiceTest`.

Die TODO-Kommentare existieren im aktuellen Baum nicht mehr.

## Merksatz

Das Mutieren einer *managed* GJ-Entität umgeht das `write-enabled`-Gate über Hibernates
Auto-Flush. Vor dem Mutieren detachen (oder gar nicht mutieren), sonst persistiert das
Dirty-Checking am gegateten Persister vorbei.
