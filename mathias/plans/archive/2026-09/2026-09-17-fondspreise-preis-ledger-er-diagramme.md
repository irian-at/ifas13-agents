# Fondspreise — Entity-Diagramme: Altsystem und Neusystem mit Ledger-Varianten

Stand 2026-09-17. Begleitblatt zu
[Preis-Ledger — die Formen](2026-09-17-fondspreise-preis-ledger-formen.md); Begriffe dort in
Abschnitt 0. Diagramme als mermaid (IntelliJ-Vorschau, GitHub); als Deck gerendert in
`2026-09-17-fondspreise-preis-ledger-er-diagramme.deck.html` (braucht `_deck/mermaid.min.js` daneben).

**Lesart:** durchgezogene Linie = echter Schlüsselbezug (Fremdschlüssel oder Join), gestrichelte
Linie = Datenfluss oder Ableitung durch ein Programm bzw. eine Stufe. Kardinalitäten an gestrichelten
Linien sind Größenordnungen („viele Zeilen ergeben höchstens eine"), keine Constraints. Spaltenlisten
sind auf das Wesentliche gekürzt; Ledger-Namen und -Schlüssel sind **provisorisch**.

---

## 1. Altsystem — `kurs`-DB (Sybase), Stammdaten aus `ifas` und `vwkn`

```mermaid
erDiagram
    inv {
        int WFS_WKN PK "Fonds bzw. Tranche (ifas..INV)"
        char(3) WAEHRUNG "Fondswaehrung = Tranchenwaehrung, genau eine je ISIN"
        varchar(5) status "V vorlaeufig, L Liquidation"
        varchar(5) veroeffentlichung "A K N V, X nur im Code"
    }
    wkn_hist {
        char(12) num_wkn PK "ISIN (cod_quelle = ISIN)"
        int num_wfs FK "zu INV.WFS_WKN"
        int num_wfs_ku "Kurs-Nummer, Schluessel von kurs"
        datetime dat_gueltig_bis "null = aktiv; Basis der 35-Tage-Loeschregel"
    }
    tmp_if_kurs {
        varchar(12) num_okb PK "ISIN wie geliefert"
        datetime dat_kurs PK "Preisdatum"
        char(3) cod_waehrung PK "Waehrung wie geliefert, ungeprueft"
        char(2) cod_preiscode PK "R E Z S S2 S3"
        char(2) cod_ex PK "Aktion N oder D, Teil des PK: N und D koexistieren"
        float num_kurs
        char(100) txt_bez
        varchar(30) liefer_id
        datetime eintragezeit "Ankunft im Eingang; Fenster fuer Stufe 4"
        varchar(3) intervall
    }
    tmp_if_last {
        varchar(12) num_okb PK "ISIN"
        datetime dat_kurs PK "im Ersetzungsschluessel NICHT enthalten"
        char(3) cod_waehrung PK
        char(2) cod_preiscode PK
        char(2) cod_ex PK "immer N, D wird nie geschrieben"
        float num_kurs "gelieferter Wert, nicht der aus kurs"
        char(100) txt_bez
        varchar(30) liefer_id
        datetime eintragezeit
    }
    kurs {
        int num_wfs_ku PK "Kurs-Nummer, nicht die ISIN"
        datetime dat_kurs PK "Preisdatum"
        char(2) cod_fliesscode PK "= Preiscode"
        char(3) waehrung PK "nur Fondswaehrung kommt an"
        float num_kurs "gelieferter Wert"
        float num_bericht_kurs "berichtigter Kurs aus der Nachrechnung"
        char(2) cod_ex "vorhanden, ungenutzt"
        datetime guelt "Insert-Zeit; kein Ende, kein Grund"
    }

    inv ||--o{ wkn_hist : "num_wfs"
    wkn_hist ||..o{ tmp_if_kurs : "ISIN-Aufloesung erst in Stufe 4"
    wkn_hist ||--o{ kurs : "num_wfs_ku"
    tmp_if_kurs }o..o| kurs : "Stufe 4: delete-then-insert je Code, nur Fondswaehrung; D loescht physisch"
    tmp_if_kurs }o..o| tmp_if_last : "Stufe 4 WriteLastKurse: ein Platz je ISIN, Whg, Code; cod_ex hart N; auch Fremdwaehrung"
    tmp_if_last }o..o{ tmp_if_kurs : "Stufe 3 Fallback: Anti-Join nur auf ISIN, 65-Tage-Fenster"
```

Was das Diagramm zeigt:

| Punkt | Befund |
|---|---|
| **Zwei Identitäten** | Eingang und Projektion kennen die ISIN (`num_okb`), `kurs` kennt nur `num_wfs_ku`. Die Auflösung passiert in Stufe 4 über `wkn_hist`. |
| **Aktion im Schlüssel** | `cod_ex` ist in `tmp_if_kurs` Teil des PK. Ein `N` und ein `D` zum selben Preis stehen nebeneinander; wer gewinnt, entscheidet der Eingang (`Check4DeleteInTmp`) und die Verarbeitungsreihenfolge. |
| **Ein Platz je Schlüssel** | `tmp_if_last` hat den 5-spaltigen PK, aber `WriteLastKurse` löscht vor dem Insert über (ISIN, Whg, Code) **ohne** Datum. Der eine Platz ist Code, nicht Schema. |
| **Keine Zeit, kein Ende** | `kurs.guelt` ist die Insert-Zeit. Löschungen sind physisch, es bleibt nichts zurück. `eintragezeit` steuert nur das Verarbeitungsfenster. |
| **Währung** | `tmp_if_kurs` und `tmp_if_last` tragen die gelieferte Währung, `kurs` nur die Fondswährung. Genau dort laufen die drei Tabellen auseinander. |
| **Wert** | überall `float`. |

---

## 2. Neusystem — Inbox, Ledger (Variante A), abgeleitete Sybase-Tabellen

Postgres: `jobs` und `preismeldung_zeilen` (Job-System), das Ledger (Kontext
`business-new-introduced`). Sybase, Neusystem-Instanz, schema-gesperrt: `kurs`, `tmp_if_last`
(letztere nur, solange Klärung **O** offen ist).

```mermaid
erDiagram
    jobs {
        uuid id PK
        text job_type
        timestamp created_at "Ankunft der Lieferung = Ordnungszeit (angekommen_am)"
    }
    preismeldung_zeilen {
        uuid job_id PK, FK "Inbox: rohe Zeilen je Lieferung"
        int zeilen_nr PK
        varchar(12) isin
        date preisdatum
        varchar(3) waehrung "wie geliefert"
        varchar(2) meldekategorie "R E Z S S2 S3 L1 L2 L3"
        varchar(1) aktion "N D I"
        varchar(30) wert "exakt, als Text"
        varchar(100) fondsbezeichnung
    }
    preis_version {
        varchar(12) isin PK "wie geliefert"
        date preisdatum PK
        varchar(3) waehrung PK "= Fondswaehrung, sonst kommt die Zeile nicht hierher (1a)"
        varchar(2) meldekategorie PK
        timestamptz gueltig_ab PK "Zeitpunkt der Sync-Entscheidung, Ordnung nach angekommen_am"
        timestamptz gueltig_bis "null = aktuell; gesetzt = abgeloest oder geloescht"
        varchar ende_grund "KORREKTUR, D; Veto entfaellt (1a)"
        int num_wfs_ku "zur Sync-Zeit aufgeloest, fuer kurs"
        numeric wert "exakt"
        uuid job_id FK "schreibender Job"
        uuid beendet_durch_job_id FK "Job, der die Version geschlossen hat"
    }
    kurs {
        int num_wfs_ku PK
        date dat_kurs PK
        varchar(2) cod_fliesscode PK
        varchar(3) waehrung PK
        float num_kurs "aus der offenen Version"
        float num_bericht_kurs "Nachrechnung"
        timestamp guelt
    }
    tmp_if_last {
        varchar(12) num_okb PK
        date dat_kurs PK
        varchar(3) cod_waehrung PK
        varchar(2) cod_preiscode PK
        varchar(2) cod_ex PK "N"
        float num_kurs
    }

    jobs ||--o{ preismeldung_zeilen : "job_id"
    jobs ||--o{ preis_version : "job_id, beendet_durch_job_id"
    preismeldung_zeilen }o..o{ preis_version : "Sync-Entscheidung mit Stammdaten; die offene Version ist der Guard"
    preis_version }o..o| kurs : "Ableitung: offene Versionen nach Sybase, inline oder terminiert"
    preis_version }o..o| tmp_if_last : "Ableitung: juengste offene Version je ISIN, Whg, Code im 65-Tage-Fenster"
```

Die heutigen Stufe-2-Tabellen `preis_herkunft` (Guard je `kurs`-Zeile) und `letzte_preise` (Guard
und Spiegel der Projektion) kommen im Diagramm nicht mehr vor: die offene `preis_version` übernimmt
den ersten Guard, die Abfrage der Projektion den zweiten (Formen-Dokument, 5a).

### Die Ledger-Varianten im Vergleich — nur die Ledger-Entität(en)

**A — Gültigkeitsintervalle** (oben): eine Zeile je Version, `gueltig_ab`/`gueltig_bis`, Grund an
der geschlossenen Zeile.

**B — Ereignis-Ledger**: eine Zeile je Operation, nie ein Update.

```mermaid
erDiagram
    preis_ereignis {
        bigint id PK "monotone Einfuegesequenz = Wasserstandsmarke fuer den Sync"
        varchar(12) isin
        date preisdatum
        varchar(3) waehrung
        varchar(2) meldekategorie
        varchar(4) op "NEU DEL SKIP"
        numeric wert "bei DEL leer"
        varchar grund "bei SKIP oder DEL"
        int num_wfs_ku
        timestamptz angekommen_am "Ordnung beim LESEN: Faltung je Schluessel"
        uuid job_id FK
        int zeilen_nr "mit job_id eindeutig: Wiederholungsschutz"
    }
    jobs ||--o{ preis_ereignis : "job_id"
    preis_ereignis }o..o| kurs : "nur entkoppelt ohne Guard: ein Sync faltet den committeten Stand"
```

**C — Ist-Tabelle plus Historie**: zwei Tabellen, konsistent zu halten.

```mermaid
erDiagram
    preis_aktuell {
        varchar(12) isin PK
        date preisdatum PK
        varchar(3) waehrung PK
        varchar(2) meldekategorie PK
        numeric wert
        timestamptz seit
        uuid job_id FK "die Ist-Zeile ist der Guard"
    }
    preis_historie {
        bigint id PK
        varchar(12) isin
        date preisdatum
        varchar(3) waehrung
        varchar(2) meldekategorie
        numeric wert
        timestamptz von
        timestamptz bis "null = ist die aktuelle"
        varchar grund
        uuid job_id FK
    }
    preis_aktuell ||--o{ preis_historie : "jede Version, auch geloeschte"
    preis_aktuell }o..o| kurs : "Ableitung 1:1"
```

---

## 3. Alt gegen Neu — die Unterschiede auf einen Blick

| | Altsystem | Neusystem mit Ledger (A) |
|---|---|---|
| **Rohinput** | `tmp_if_kurs`, wird nach Stufe 4 nach `tmp_if_cop` kopiert und geleert | `preismeldung_zeilen`, bleibt; keine Kopie, kein Leeren |
| **Identität** | ISIN im Eingang, `num_wfs_ku` in `kurs`; Auflösung spät und still | beide Spalten am Ledger, Auflösung zur Sync-Zeit festgehalten |
| **Aktion** | `cod_ex` im PK von `tmp_if_kurs`; `D` löscht in `kurs` physisch | `D` schließt eine Version mit `ende_grund = D`; nichts verschwindet |
| **Korrektur** | delete-then-insert, alter Wert weg | alte Version geschlossen (`KORREKTUR`), neue geöffnet |
| **Zeit** | `eintragezeit` (Ankunft), `guelt` (Insert-Zeit); kein Ende | `gueltig_ab`/`gueltig_bis` je Version; Stand zu jedem Zeitpunkt rekonstruierbar |
| **Reihenfolge** | Verarbeitungsreihenfolge des Tagesjobs | Ankunft (`angekommen_am`), festgehalten an der Version; offene Version = Guard |
| **Währung** | gelieferte Währung in tmp-Tabellen und File, Fondswährung in `kurs` | nur Fondswährung; abweichende Zeile scheitert am Eingang oder wird nicht geführt (1a) |
| **Letzter Preis** | eigene Tabelle `tmp_if_last`, ein Platz je Schlüssel, „zuletzt verarbeitet gewinnt" | Abfrage über offene Versionen: jüngstes Preisdatum, dann späteste Ankunft |
| **Gelöschte Preise** | unsichtbar (kein Protokoll, `del_protokoll` ohne Leser) | geschlossene Version mit Zeitpunkt, Grund und Job |
| **Wert** | `float` | exakt (`numeric`); `float` erst in der Ableitung nach `kurs` |
| **`kurs`** | Ziel und Quelle zugleich | abgeleitet aus dem Ledger; bleibt für Parallelbetrieb und Fremdleser, wird 2027 zur Sicht |

## Quellen

`Kurs/tabledefs/tmp_i_ku.cr`, `tmp_i_last.cr`, `kurs.cr`, `I_kurs.cr`; `Ifas/tabledef/INV.cr`;
`VWKN/tabledefs/WKN_HIST.CR`; Flyway `V009__stm_recalc_jobs.sql` (`jobs`), `V061__preismeldung_zeilen.sql`,
`V067__preismeldung_zeilen__job_fk.sql`; Branch `feat/fondspreise-sync`: `V067__fondspreise_sync.sql`
(`preis_herkunft`, `letzte_preise`, `kurs`-Provisionierung). Verhalten: Formen-Dokument, Abschnitte 1, 1a, 5a.
