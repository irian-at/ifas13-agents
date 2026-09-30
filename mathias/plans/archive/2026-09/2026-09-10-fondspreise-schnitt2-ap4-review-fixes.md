# Review-Fixes für AP4 (`domain.fondspreise.sync`)

## Context

`/code-review-ifas` über die uncommitteten AP4-Änderungen auf `feat/fondspreis`
ergab vier validierte Befunde ≥ 80 und zwei inhaltlich berechtigte darunter. Alle betreffen nur das
neue `sync`-Package, `FondsStammdaten` und den Test; kein Aufrufer existiert noch, also keine
Live-Auswirkung — aber die Entscheidungstabelle würde AP5 falsch füttern.

## Änderungen

**`ifas-domain-fondspreise/.../sync/PreismeldungSyncDecisions.java`**
1. Währungs-Skip: `skip(NOT_FONDSWAEHRUNG, group.aktion() != PreisAktion.D)` — und `storable` als
   `affectedCodes` mitgeben (neue `skip`-Überladung mit Codes), damit der Ausführende die Projektion
   ohne Rückgriff auf die `PriceGroup` fortschreiben kann.
2. Aktivierung: `stammsatz.isActivatableOn(group.preisdatum()) && group.hasErrechnetenWert()` —
   nur das Flag, Operation bleibt `UPSERT`.
3. `D`-Zweig: `delete(storable, korrektur && deletesErrechnetenWert)` — `marksKorrektur` bedeutet
   damit exakt, was sein Javadoc sagt; `korrektur` wird in beiden Pfaden benutzt.
4. Klammer-Formatierung an `existsAktiveAusschuettung(`.

**`ifas-domain-fondspreise/.../stammdaten/FondsStammdaten.java`**
- `public boolean isActivatableOn(LocalDate preisdatum)` — `isVorlaeufigerFonds()` und
  (`fondsBeginn == null` oder `preisdatum` nicht vor `fondsBeginn`). Javadoc von
  `isVorlaeufigerFonds()` entsprechend kürzen (Regel wandert zur neuen Methode).

**`ifas-domain-fondspreise/.../sync/SyncDecision.java`**
- `skip(reason, advancesLetzterPreis, codes)`-Variante; Klammer-Formatierung in `upsert`.

**`ifas-domain-fondspreise/src/test/.../sync/PreismeldungSyncDecisionsTest.java`**
- `@NullMarked` an die Klasse.
- Neue Tests: `D` in Fremdwährung → `advancesLetzterPreis` false; vorläufiger Fonds mit `R` vor
  `fondsBeginn` → `activatesVorlaeufigenFonds` false, Operation `UPSERT`; `R`-Löschung am Stichtag
  → `marksKorrektur` false; `R`-Löschung eines früheren Tages → true; `NOT_FONDSWAEHRUNG` trägt die
  Codes.
- Bestehenden Test `givenDeletionOfErrechnetemWert_whenNoAusschuettung_thenDeletedAndMarkedAsKorrektur`
  auf ein Preisdatum vor dem Stichtag setzen (er behauptet sonst das Gegenteil des Javadocs).
- Klammer-Formatierung an den fünf gechoppten `Map.of(`/`ofStatic(`/`AusschuettungsTag(`-Aufrufen.

**Tracker** (`mathias/plans/fondspreise/tracker.md`): Schnitt-6-Notiz — Legacy trennt `InsPreise*`
(Speichern) von `Calc*` (Nachrechnen) je Fondskategorie; die Sync-Entscheidung kennt nur Ersteres.

## Verifikation

- `mvn -Pno-proxy -Pdev-build -o test -pl ifas-domain/ifas-domain-fondspreise` — erwartet
  113 + 5 = 118 grün.
- `mvn -q -Pno-proxy -Pdev-build -o install -DskipTests` — Gesamtbuild.
- Danach als eigener Commit auf dem Branch (AP4), Regel `mathias/rules/commit-messages.md`.

## Nicht Teil dieses Fixes

AP5-Folgearbeiten aus dem Review: produktive `AusschuettungProvider`-Implementierung
(`AsfRepository` braucht eine Query auf `(wfsWkn, datum, waehrung, status='A')`),
`PreismeldungSyncOptions` aus `FondspreiseProperties`, Mapping `PreismeldungZeileDaten` →
`PriceGroup` (`String` → `PreisAktion`). Der `@NullMarked`-Rückstand der fünf älteren Testklassen
bleibt unangetastet.
