# Fondspreise — Fragen an die Fachabteilung: Fallback (Lauf 1), Währung, gelöschte Preise

Stand 2026-09-11. Entstanden im Designreview zu Schnitt 2
([Plan](2026-09-08-fondspreise-schnitt2-sync-guard-letzte-preise.md), D14) — Klärungen **O** und
**P** im [Tracker](tracker.md). Die Größenordnungen liefern die Abfragen **V6** in
[fondspreise-lieferant-isin-analyse.sql](fondspreise-lieferant-isin-analyse.sql); vor dem Gespräch auf
GAST ausführen und die Zahlen unten eintragen.

---

**Betreff: Preismeldungen in abweichender Währung – Verhalten im Fallback (Lauf 1) klären**

**Sachstand, aus dem Code des Altsystems belegt**

1. Ein Lieferant kann für einen inländischen Fonds einen Preis in einer Währung melden, die nicht der
   Fondswährung laut Stammdaten entspricht. Die Eingangsprüfung lässt das für alle Preis- und
   Solva-Codes durch, also R, E, Z, S, S2 und S3. Die Prüfung „Währung muss Fondswährung sein" ist in
   der tax_code-Konfiguration (Stand GAST) nur für die LMT- und Steuercodes aktiviert.
2. Das tägliche Preisfile veröffentlicht diesen Preis mit der gelieferten Währung. Ein Abgleich mit
   der Fondswährung findet in der Fileerstellung nicht statt.
3. In die Kurstabelle wird der Preis nicht übernommen. Dort stehen ausschließlich Preise in der
   Fondswährung.
4. In die Tabelle der letzten Preise wird er trotzdem geschrieben. Solange der Fonds keinen neueren
   Preis liefert, wird er deshalb bis zu 65 Tage lang im Lauf 1 als Fallback erneut veröffentlicht.

Folge: Es gibt Preise, die veröffentlicht werden, aber nie in der Kurstabelle stehen. Der Fallback
reproduziert genau diese.

**Fragen**

1. Ist die Meldung eines Preises in einer anderen Währung als der Fondswährung ein fachlich
   zulässiger Fall, den IFAS bewusst durchreichen soll? Oder ist es ein Datenqualitätsproblem, das
   nur deshalb im File landet, weil es niemand blockiert?
2. Falls zulässig: Soll ein solcher Preis auch als „letzter bekannter Preis" für den Fallback gelten,
   also erneut veröffentlicht werden, obwohl er in IFAS nicht als Kurs gespeichert ist?
3. Falls nicht zulässig: Soll die Eingangsprüfung ihn künftig zurückweisen, also die
   Fondswährungs-Prüfung auch für R, E, Z und die Solva-Codes aktivieren? Oder soll er weiter
   veröffentlicht, aber nicht mehr als Fallback verwendet werden?

**Zweiter Fall mit derselben Entscheidungsfrage**

Löscht ein Lieferant einen Preis mit Aktion D, wird er aus der Kurstabelle entfernt, bleibt aber in
der Tabelle der letzten Preise stehen. Die dafür vorgesehene Löschroutine im Altsystem wird nie
aufgerufen. Der zurückgezogene Preis wird damit im Lauf 1 als Fallback erneut veröffentlicht. Ist das
gewollt, oder soll ein gelöschter Preis auch aus dem Fallback verschwinden?

**Übergeordnet**

Beide Fragen hängen daran, wozu der Fallback aus Sicht der Bezieher dient: Soll er einen verpassten
Preis nachliefern, oder erwartet ein Abnehmersystem täglich eine Zeile je Fonds? Die Antwort
entscheidet, ob der Fallback künftig aus der Kurstabelle abgeleitet werden kann oder eine eigene
Tabelle der letzten Preise wie im Altsystem geführt werden muss.

Dazu die Frage an KUPL/KMS: Lesen diese Anwendungen die Tabelle der letzten Preise (`tmp_if_last`)
direkt? Wenn ja, welche Spalten?

---

## Belege (für Rückfragen)

| Aussage | Fundstelle |
|---|---|
| Eingang: Fondswährungs-Prüfung nur bei `isinwaehrung = J` (`ERR_CURRENCY04`) | `tax_code`, GAST-Abzug in `standard_TAX_CODE_data.yaml`: `R`/`E`/`Z`/`S`/`S2`/`S3` = false, `L1`–`L3` und Steuercodes = true |
| Preis ≠ Fondswährung → kein `kurs`-Write, `WriteLastKurse` läuft trotzdem | `Ifas/cprogs2/calc/preisekennzahl.cpp:2843-2850` |
| Fileerstellung prüft die Fondswährung nicht; Währung im `I2`-Satz ist die gelieferte | `Ifas/cprogs2/preise4/m_fp_rec.CPP`, `StartTmpKursSchleife` / `ReadTmpKurse` |
| Fallback-Selektion: Fonds ohne neuere Lieferung, 65-Tage-Fenster | `m_fp_rec.CPP:2536ff` (`nQuellTab = 1`), `M_FP_DLD.CPP:127` |
| `DeleteLastKurse` wird nirgends aufgerufen; SQL nennt Spalten, die `tmp_if_last` nicht hat | `preisekennzahl.cpp:1849` (Definition), `:1939` (SQL: `waehrung`, `cod_fliesscode`), Header `preisekennzahl.h:719`; `Kurs/tabledefs/tmp_i_last.cr` |

## Zahlen aus V6 (GAST)

_noch nicht ausgeführt — Ergebnis von V6d hier eintragen (Fall 2 = Währung, Fall 3 = gelöscht o. ä.)_
