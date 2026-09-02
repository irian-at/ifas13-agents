-- ============================================================================
-- fondspreise-lieferant-isin-analyse.sql
--
-- Voranalysen auf der Altsystem-Sybase (ASE 16) für das Konzept
-- 2026-08-31-fondspreise-neuentwicklung-konzept.md. Rekonstruiert 2026-09-02 —
-- die Q-Nummern folgen den Verweisen im Konzept (Q6–Q8 gab es nie), der
-- V-Block ergänzt die übrigen DB-abfragbaren Punkte der Datenbeschaffung.
--
-- Alle Queries sind read-only. Ausführen gegen die Produktions- bzw.
-- GAST-Sybase (Kataloge kurs, ifas, vwkn).
-- Trennung per Semikolon (IntelliJ/DBeaver); für isql jede Query einzeln
-- ausführen bzw. ';' durch 'go' ersetzen.
--
-- Spaltennamen belegt aus den Legacy-DDLs:
--   Kurs/tabledefs/{lieferanten,KAG_lieferanten,kurs,tmp_i_last,tmp_i_ku,
--   pool_i_k,tax_code,v_preiscode}.cr, Ifas/tabledef/{INV,ASF,preismeldung}.cr,
--   VWKN/tabledefs/WKN_HIST.CR. Die Soll-Selektion (Q2/Q5c) ist 1:1 die von
--   m_plausi4tag_preise.cpp:DoCheck().
-- ============================================================================


-- ============================================================================
-- Block J — Lieferant <-> ISIN-Zuordnung (offener Punkt J, Fehlmeldung)
-- ============================================================================

-- Q0a: Überblick Lieferanten — welche liefer_typ/aktiv-Kombinationen gibt es?
-- ('F' = Fondspreis-Lieferant; die Prüfung war produktiv nie aktiv, -K0)
select liefer_typ     = isnull(liefer_typ, '-'),
       aktiv          = isnull(aktiv, '-'),
       inland_ausland,
       anz            = count(*)
from kurs..lieferanten
group by isnull(liefer_typ, '-'), isnull(aktiv, '-'), inland_ausland
order by 1, 2, 3;

+------------+-------+----------------+-----+
| liefer_typ | aktiv | inland_ausland | anz |
+------------+-------+----------------+-----+
| -          | N     | A              | 1   |
| A          | J     | A              | 21  |
| A          | J     | I              | 34  |
| A          | N     | A              | 215 |
| A          | N     | I              | 17  |
| F          | N     | I              | 29  |
| J          | J     | I              | 1   |
| J          | N     | I              | 2   |
| S          | N     | I              | 1   |
+------------+-------+----------------+-----+

9 Zeile(n) zurückgegeben

-- Q0b: die Fondspreis-Lieferanten im Detail (Adressaten der Fehlmeldung)
select liefer_id, bezeichnung, aktiv, inland_ausland, email_at, re_mail1
from kurs..lieferanten
where liefer_typ = 'F'
order by aktiv desc, liefer_id;

+-----------+----------------------------------------------------------------+-------+----------------+-------------+-------------+
| liefer_id | bezeichnung                                                    | aktiv | inland_ausland | email_at    | re_mail1    |
+-----------+----------------------------------------------------------------+-------+----------------+-------------+-------------+
| fp_3ba    | FPP - 3Banken Generali Invest                                  | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_aia    | FPP - Valartis Management KAG                                  | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_aib    | FPP - Allianz Invest KAG                                       | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_asl    | FPP - Sparkasse OÖ KAG                                         | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_bai    | FPP - BA Real Invest Immobilien                                | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_baw    | FPP - BAWAG P.S.K. Invest GmbH                                 | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_bss    | FPP - BH Schelhammer & Schattera KAG                           | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_c2k    | FPP - C-Quadrat KAAG                                           | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_cap    | FPP - Pioneer Investments Austria                              | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_con    | FPP - Semper Constantia Invest GmbH                            | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_cpi    | FPP - CPB Immobilien KAG                                       | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_csp    | FPP - Carl Spängler KAG                                        | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_dws    | FPP - DWS (Austria) Investment                                 | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_eik    | FPP - ERSTE Immobilien KAG                                     | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_esk    | FPP - ERSTE-Sparinvest KAG                                     | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_gut    | FPP - Gutmann KAG                                              | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_hyp    | FPP - MASTERINVEST KAG                                         | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_inv    | FPP - Macquarie Investment Management Austria Kapitalanlage AG | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_jmi    | FPP - Julius Meinl Investment GmbH.                            | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_kep    | FPP - Kepler-Fonds KAG                                         | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_rai    | FPP - Raiffeisen KAG                                           | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_rik    | FPP - Raiff. Immobilien KAG                                    | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_rin    | FPP - Ringturm KAG                                             | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_sec    | FPP - Security KAAG                                            | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_skw    | FPP - Schoellerbank Invest AG                                  | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_smw    | FPP - Raiffeisen Salzburg Inest KAG                            | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_tir    | FPP - Tirolinvest KAG                                          | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_vbi    | FPP - Immo Kapitalanlage AG                                    | N     | I              | abi@oekb.at | abi@oekb.at |
| fp_vbk    | FPP - Volksbank Invest KAG                                     | N     | I              | abi@oekb.at | abi@oekb.at |
+-----------+----------------------------------------------------------------+-------+----------------+-------------+-------------+

29 Zeile(n) zurückgegeben

-- Q1: je KAG — wie viele aktive F-Lieferanten sind zugeordnet? (Verteilung)
-- Entscheidet mit Q3, ob "je Lieferant" ein eindeutiger Schlüssel ist.
select anz_f_lieferanten = t.anz,
       anz_kags          = count(*)
from ( select kl.KAG, anz = count(*)
       from kurs..KAG_lieferanten kl
       join kurs..lieferanten l on l.liefer_id = kl.liefer_id
       where l.liefer_typ = 'F'
         and isnull(l.aktiv, 'J') = 'J'
       group by kl.KAG ) t
group by t.anz
order by t.anz;

keine Ergebnisse

-- Q2: meldepflichtige Fonds OHNE jeden aktiven F-Lieferanten
-- ("Fehlmeldung ohne Adressat"). Fondsselektion = DoCheck() aus
-- m_plausi4tag_preise.cpp; Stichtag = heute.
-- Hinweis: DoCheck() filtert die wkn_hist-Gültigkeit NICHT — hier ist der
-- Gültigkeitsfilter gesetzt, um umbenannte ISINs nicht doppelt zu zählen.
select i.KAG,
       isin      = h.num_wkn,
       fonds     = d.txt_bez_m,
       num_wfs   = i.WFS_WKN
from ifas..INV i
join vwkn..wkn_hist h on h.num_wfs = i.WFS_WKN
     and h.cod_quelle = 'ISIN'
     and getdate() between h.dat_gueltig_ab and isnull(h.dat_gueltig_bis, '21000101')
join vwkn..wkn_desc d on d.num_wfs = i.WFS_WKN
where i.status = 'A'
  and d.cod_art_f in ('FOND', 'TECH', 'C-PL')
  and getdate() between isnull(i.fonds_beginn, '21000101') and isnull(i.fonds_ende, '21000101')
  and i.KAG < 10000
  and i.preismeldung = 'TGL'
  and not exists ( select 1
                   from kurs..KAG_lieferanten kl
                   join kurs..lieferanten l on l.liefer_id = kl.liefer_id
                   where kl.KAG = i.KAG
                     and l.liefer_typ = 'F'
                     and isnull(l.aktiv, 'J') = 'J' )
order by i.KAG, h.num_wkn;

nur die ersten 100 Zeilen:
    +-----+--------------+-----------------------------------------------+---------+
| KAG | isin         | fonds                                         | num_wfs |
+-----+--------------+-----------------------------------------------+---------+
| 100 | AT0000497672 | ClassicBond (A)                               | 54990   |
| 100 | AT0000497680 | ClassicBond (T)                               | 54991   |
| 100 | AT0000604368 | SAM17                                         | 50177   |
| 100 | AT0000633607 | SAM15                                         | 45547   |
| 100 | AT0000657838 | S Zukunft Aktien 2                            | 42599   |
| 100 | AT0000657846 | S Zukunft Renten 2                            | 42600   |
| 100 | AT0000675475 | Money&Co Best Of                              | 40617   |
| 100 | AT0000675483 | Money&Co Equity                               | 40618   |
| 100 | AT0000681168 | s EthikAktien (T)                             | 38501   |
| 100 | AT0000681176 | s EthikAktien (A)                             | 38502   |
| 100 | AT0000681184 | s EthikBond (T)                               | 38503   |
| 100 | AT0000681192 | s EthikBond (A)                               | 38504   |
| 100 | AT0000685656 | SAM10                                         | 37961   |
| 100 | AT0000703020 | SAM08                                         | 36540   |
| 100 | AT0000721410 | SAM04                                         | 32936   |
| 100 | AT0000723168 | BusinessBond (T)                              | 32812   |
| 100 | AT0000723176 | BusinessBond (A)                              | 32813   |
| 100 | AT0000723499 | SAM03                                         | 32859   |
| 100 | AT0000729173 | Aktiva s Best-Invest (A)                      | 32355   |
| 100 | AT0000729181 | Aktiva s Best-Invest (T)                      | 32356   |
| 100 | AT0000745153 | s Future Trend                                | 30630   |
| 100 | AT0000745161 | Master s Best-Invest A                        | 30632   |
| 100 | AT0000745179 | Master s Best-Invest B                        | 30633   |
| 100 | AT0000745187 | Master s Best-Invest C                        | 30634   |
| 100 | AT0000765003 | SAM01                                         | 28589   |
| 100 | AT0000801246 | AustroMündelRent (T)                          | 25322   |
| 100 | AT0000801253 | AustroMündelRent (A)                          | 25323   |
| 100 | AT0000801261 | S-PensionsVorsorge-OÖ                         | 25324   |
| 100 | AT0000802400 | EuroPlus 50 (T)                               | 25498   |
| 100 | AT0000802418 | EuroPlus 50 (A)                               | 25497   |
| 100 | AT0000811427 | Equity s Best-Invest                          | 26600   |
| 100 | AT0000811443 | Bond s Best-Invest                            | 26601   |
| 100 | AT0000859806 | AustroRent (T)                                | 269     |
| 100 | AT0000859814 | AustroRent (A)                                | 25723   |
| 100 | AT0000859822 | InterBond (T)                                 | 270     |
| 100 | AT0000859830 | InterBond (A)                                 | 25725   |
| 100 | AT0000859848 | InterStock (T)                                | 271     |
| 100 | AT0000859855 | InterStock (A)                                | 25726   |
| 100 | AT0000952460 | ViennaStock (T)                               | 19935   |
| 100 | AT0000952478 | ViennaStock (A)                               | 25733   |
| 100 | AT0000952486 | BarReserve (T)                                | 19936   |
| 100 | AT0000952494 | BarReserve (A)                                | 25753   |
| 100 | AT0000A06749 | SAM21                                         | 70751   |
| 100 | AT0000A07LH2 | sPM S1                                        | 72787   |
| 100 | AT0000A07LJ8 | sPM S2                                        | 72788   |
| 100 | AT0000A086X3 | SAM22                                         | 74232   |
| 100 | AT0000A0E0X2 | s Reserve (A)                                 | 87889   |
| 100 | AT0000A0E0Y0 | s Reserve (T)                                 | 87888   |
| 100 | AT0000A0G470 | SAM24                                         | 91577   |
| 100 | AT0000A0H0R1 | s-Zukunft Aktien 4                            | 92885   |
| 100 | AT0000A0JGB6 | s Generation                                  | 95625   |
| 100 | AT0000A0K1H5 | s Emerging                                    | 97183   |
| 100 | AT0000A0NUP9 | DP 2                                          | 103219  |
| 100 | AT0000A0XPC6 | s RegionenFonds (A)                           | 119748  |
| 100 | AT0000A0XPE2 | s RegionenFonds (T)                           | 119725  |
| 100 | AT0000A10KD7 | s OÖV1                                        | 123048  |
| 100 | AT0000A17AV5 | SAM26                                         | 129080  |
| 100 | AT0000A189Y3 | s ÄKOÖ1                                       | 130248  |
| 100 | AT0000A189Z0 | s OÖV2                                        | 130247  |
| 100 | AT0000A1L8Z0 | s Top AktienWelt (A)                          | 144729  |
| 100 | AT0000A1L908 | s Top AktienWelt (T)                          | 144730  |
| 100 | AT0000A1X9Z4 | s EthikMix (A)                                | 152621  |
| 100 | AT0000A1XA05 | s EthikMix (T)                                | 152622  |
| 100 | AT0000A208E3 | SAM27                                         | 157619  |
| 100 | AT0000A29469 | BusinessBond (T) DV                           | 168701  |
| 100 | AT0000A294A1 | ClassicBond (T) DV                            | 168710  |
| 100 | AT0000A294B9 | EuroPlus 50 (T) DV                            | 168709  |
| 100 | AT0000A294D5 | InterStock (T) DV                             | 168707  |
| 100 | AT0000A294E3 | s EthikAktien (T) DV                          | 168706  |
| 100 | AT0000A294G8 | s Generation (T) DV                           | 168704  |
| 100 | AT0000A294H6 | s Top AktienWelt (T) DV                       | 168703  |
| 100 | AT0000A294J2 | ViennaStock (T) DV                            | 168702  |
| 100 | AT0000A2D7Y4 | ClassicBond A IT01                            | 173099  |
| 100 | AT0000A2D8J3 | AustroRent A IT01                             | 173133  |
| 100 | AT0000A2D8K1 | AustroMündelRent A IT01                       | 173134  |
| 100 | AT0000A2D8L9 | BusinessBond A IT01                           | 173135  |
| 100 | AT0000A2D8M7 | InterBond A IT01                              | 173136  |
| 100 | AT0000A2D8N5 | s EthikBond A IT01                            | 173143  |
| 100 | AT0000A2D8P0 | InterStock A IT01                             | 173137  |
| 100 | AT0000A2D8Q8 | s Top AktienWelt A IT01                       | 173138  |
| 100 | AT0000A2D8R6 | EuroPlus 50 A IT01                            | 173139  |
| 100 | AT0000A2D8S4 | ViennaStock A IT01                            | 173140  |
| 100 | AT0000A2D8T2 | s EthikAktien A IT01                          | 173141  |
| 100 | AT0000A2D8U0 | s Generation T IT01                           | 173142  |
| 100 | AT0000A2G9V3 | SAM28                                         | 173915  |
| 100 | AT0000A2JSR3 | sPM S1 (A)                                    | 176477  |
| 100 | AT0000A2JSS1 | sPM S2 (A)                                    | 176478  |
| 100 | AT0000A2XMD7 | SAM30                                         | 189743  |
| 100 | AT0000A30434 | SAM31                                         | 191848  |
| 100 | AT0000A30H65 | SAM32                                         | 192348  |
| 100 | AT0000A31KF8 | SAM33                                         | 192852  |
| 100 | AT0000A3FS47 | s Bond Plus (T)                               | 200020  |
| 100 | AT0000A3FS54 | s Bond Plus (A)                               | 200019  |
| 100 | AT0000A3FS62 | s Bond Plus A IT01                            | 200018  |
| 100 | AT0000A3FS70 | s Bond Plus T IT01                            | 200017  |
| 100 | AT0000A3GR70 | SAM34                                         | 200606  |
| 100 | AT0000A3N736 | SAM35                                         | 203797  |
| 100 | AT0A0SCORES7 | s Core Strategy (A)                           | 199259  |
| 100 | AT0T0SCORES6 | s Core Strategy (T)                           | 199262  |
| 100 | ATA01SBOND31 | s Bond 2031 (A)                               | 206766  |
+-----+--------------+-----------------------------------------------+---------+

-- Q3a: KAGs mit MEHR als einem aktiven F-Lieferanten ("wer muss liefern" ist
-- dort nicht eindeutig)
select kl.KAG, anz = count(*)
from kurs..KAG_lieferanten kl
join kurs..lieferanten l on l.liefer_id = kl.liefer_id
where l.liefer_typ = 'F'
  and isnull(l.aktiv, 'J') = 'J'
group by kl.KAG
having count(*) > 1
order by anz desc, kl.KAG;

-- keine ergebnisse

-- Q3b: dieselben KAGs im Detail (welche Lieferanten konkurrieren)
select kl.KAG, kl.liefer_id, l.bezeichnung
from kurs..KAG_lieferanten kl
join kurs..lieferanten l on l.liefer_id = kl.liefer_id
where l.liefer_typ = 'F'
  and isnull(l.aktiv, 'J') = 'J'
  and kl.KAG in ( select kl2.KAG
                  from kurs..KAG_lieferanten kl2
                  join kurs..lieferanten l2 on l2.liefer_id = kl2.liefer_id
                  where l2.liefer_typ = 'F'
                    and isnull(l2.aktiv, 'J') = 'J'
                  group by kl2.KAG
                  having count(*) > 1 )
order by kl.KAG, kl.liefer_id;

-- keine ergebnisse

-- Q4: Ist-Abgleich mit dem heutigen Eingang — Lieferungen in tmp_if_kurs,
-- deren Lieferant der KAG des Fonds NICHT zugeordnet ist (die nie erzwungene
-- ERR_ISIN05-Prüfung). ACHTUNG: Momentaufnahme — tmp_if_kurs wird täglich
-- geleert; nach Lieferschluss und vor dem Tagesjob ausführen, ggf. an
-- mehreren Tagen wiederholen.
select t.liefer_id, i.KAG, anz_zeilen = count(*)
from kurs..tmp_if_kurs t
join vwkn..wkn_hist h on h.cod_quelle = 'ISIN'
     and h.num_wkn = t.num_okb
     and getdate() between h.dat_gueltig_ab and isnull(h.dat_gueltig_bis, '21000101')
join ifas..INV i on i.WFS_WKN = h.num_wfs
where not exists ( select 1
                   from kurs..KAG_lieferanten kl
                   where kl.KAG = i.KAG
                     and kl.liefer_id = t.liefer_id )
group by t.liefer_id, i.KAG
order by anz_zeilen desc;

-- keine ergebnisse
-- todo auf Prod nach Lieferschluss, vor dem Tagesjob wiederholen (auf dem Abzug war
--      tmp_if_kurs fast leer — "keine ergebnisse" ist nicht aussagekräftig)


-- ============================================================================
-- Q5 — Meldeverpflichtung (Voraussetzung für 11., Fehlmeldungs-Job)
-- ============================================================================

-- Q5a: die Referenztabelle — kennt sie 'TGL'? (der Code prüft 'TGL',
-- das eingecheckte Seed ins_preismeldung.cr kennt nur 'U' und 'Y')
select preismeldung, bezeichnung, aktiv
from ifas..preismeldung
order by preismeldung;

+--------------+-----------------------------+-------+
| preismeldung | bezeichnung                 | aktiv |
+--------------+-----------------------------+-------+
| K            | keine Preismeldung          | N     |
| NEIN         | keine Preismeldung          | J     |
| NTGL         | nicht tägliche Preismeldung | J     |
| TGL          | tägliche Preismeldung       | J     |
| U            | tägliche Preismeldung       | N     |
| Y            | nicht tägliche Preismeldung | N     |
+--------------+-----------------------------+-------+

6 Zeile(n) zurückgegeben

-- Q5b: Verteilung von INV.preismeldung über ALLE Fonds (inkl. Status)
select preismeldung = isnull(i.preismeldung, '-'),
       status       = isnull(i.status, '-'),
       anz          = count(*)
from ifas..INV i
group by isnull(i.preismeldung, '-'), isnull(i.status, '-')
order by 1, 2;

+--------------+--------+-------+
| preismeldung | status | anz   |
+--------------+--------+-------+
| -            | A      | 62332 |
| -            | B      | 35283 |
| -            | I      | 4     |
| -            | Z      | 8214  |
| NEIN         | A      | 48    |
| NEIN         | B      | 28    |
| NEIN         | I      | 19    |
| NEIN         | L      | 23    |
| NEIN         | V      | 14    |
| NEIN         | Z      | 4     |
| NTGL         | A      | 34    |
| NTGL         | B      | 180   |
| NTGL         | I      | 12    |
| NTGL         | L      | 2     |
| NTGL         | V      | 1     |
| NTGL         | Z      | 6     |
| TGL          | A      | 4571  |
| TGL          | B      | 3340  |
| TGL          | I      | 545   |
| TGL          | L      | 6     |
| TGL          | V      | 187   |
| TGL          | Z      | 1370  |
+--------------+--------+-------+

22 Zeile(n) zurückgegeben

-- Q5c: Verteilung über die Soll-Grundmenge (aktiv, inländisch, lebend,
-- FOND/TECH/C-PL) — die 'TGL'-Zeile ist die Soll-Menge des Fehlmeldungs-Jobs
select preismeldung = isnull(i.preismeldung, '-'),
       anz          = count(*)
from ifas..INV i
join vwkn..wkn_desc d on d.num_wfs = i.WFS_WKN
where i.status = 'A'
  and d.cod_art_f in ('FOND', 'TECH', 'C-PL')
  and getdate() between isnull(i.fonds_beginn, '21000101') and isnull(i.fonds_ende, '21000101')
  and i.KAG < 10000
group by isnull(i.preismeldung, '-')
order by anz desc;

+--------------+------+
| preismeldung | anz  |
+--------------+------+
| TGL          | 4549 |
| NEIN         | 39   |
| NTGL         | 34   |
| -            | 5    |
+--------------+------+

4 Zeile(n) zurückgegeben


-- ============================================================================
-- Block ASF — Statuskollisionen (Q9–Q11), Zirkel (Q12), r_faktor (Q13)
-- ReadAusschuettung filtert weder aussch_status noch waehrung und nimmt die
-- erste Zeile — diese Queries messen, ob das produktiv trifft.
-- ============================================================================

-- Q9: Status-Koexistenz je (Fonds, Tag): welche A/V/D-Kombinationen
-- liegen nebeneinander, und wie oft?
select t.hat_A, t.hat_V, t.hat_D, anz_schluessel = count(*)
from ( select WFS_WKN, ASF_DATUM,
              hat_A = max(case aussch_status when 'A' then 1 else 0 end),
              hat_V = max(case aussch_status when 'V' then 1 else 0 end),
              hat_D = max(case aussch_status when 'D' then 1 else 0 end)
       from ifas..ASF
       group by WFS_WKN, ASF_DATUM ) t
group by t.hat_A, t.hat_V, t.hat_D
order by t.hat_A, t.hat_V, t.hat_D;

+-------+-------+-------+----------------+
| hat_A | hat_V | hat_D | anz_schluessel |
+-------+-------+-------+----------------+
| 0     | 1     | 0     | 95             |
| 1     | 0     | 0     | 84774          |
+-------+-------+-------+----------------+

2 Zeile(n) zurückgegeben

-- Q10: V- und D-Zeilen, die das ReadAusschuettung-Prädikat erfüllen würden
-- (isnull(ausschuettung,-1) >= 0), inländisch, je Jahr — das Reservoir an
-- Zeilen, die fälschlich ins Preisfile geraten könnten
select jahr = datepart(yy, a.ASF_DATUM),
       a.aussch_status,
       anz  = count(*)
from ifas..ASF a
join ifas..INV i on i.WFS_WKN = a.WFS_WKN
where i.KAG < 10000
  and a.aussch_status in ('V', 'D')
  and isnull(a.ausschuettung, -1) >= 0
group by datepart(yy, a.ASF_DATUM), a.aussch_status
order by 1 desc, 2;

+------+---------------+-----+
| jahr | aussch_status | anz |
+------+---------------+-----+
| 2026 | V             | 95  |
+------+---------------+-----+

1 Zeile(n) zurückgegeben

-- Q11: mehrdeutige Treffer — je (Fonds, Tag) mehr als eine qualifizierende
-- Zeile (über Status/Währung hinweg); min<>max heißt: die Wahl der "ersten"
-- Zeile ändert den Wert im File. (Fenster-Überlappungen über verschiedene
-- ASF_DATUM hinweg — preisdatum between ASF_DATUM and aussch_datum — sind
-- hier nicht erfasst; erst prüfen, wenn Q11 überhaupt Treffer hat.)
select a.WFS_WKN,
       a.ASF_DATUM,
       anz_zeilen = count(*),
       min_wert   = min(a.ausschuettung),
       max_wert   = max(a.ausschuettung)
from ifas..ASF a
join ifas..INV i on i.WFS_WKN = a.WFS_WKN
where i.KAG < 10000
  and isnull(a.ausschuettung, -1) >= 0
group by a.WFS_WKN, a.ASF_DATUM
having count(*) > 1
order by a.ASF_DATUM desc;

-- keine ergebnisse

-- Q12a: aktive inländische Ausschüttungen, für die BIS HEUTE kein R-Kurs am
-- ASF_DATUM existiert (grobe Untergrenze des Zirkels — intraday-Timing ist
-- retroaktiv nicht messbar), je Jahr
select jahr = datepart(yy, a.ASF_DATUM), anz = count(*)
from ifas..ASF a
join ifas..INV i on i.WFS_WKN = a.WFS_WKN
where i.KAG < 10000
  and a.aussch_status = 'A'
  and isnull(a.ausschuettung, -1) >= 0
  and not exists ( select 1
                   from vwkn..wkn_hist h, kurs..kurs k
                   where h.num_wfs = a.WFS_WKN
                     and k.num_wfs_ku = h.num_wfs_ku
                     and k.cod_fliesscode = 'R'
                     and k.dat_kurs = a.ASF_DATUM )
group by datepart(yy, a.ASF_DATUM)
order by 1 desc;

-- keine ergebnisse

-- Q12b: der Notausgang 'X' (fiktiver errechneter Wert) — wie oft wurde er
-- überhaupt benutzt, je Jahr? X wird in keinem Ausgabefile ausgeliefert;
-- jede Zeile ist ein Beleg, dass die Aktivierung ohne echten R-Kurs erfolgte.
select jahr = datepart(yy, dat_kurs), anz = count(*)
from kurs..kurs
where cod_fliesscode = 'X'
group by datepart(yy, dat_kurs)
order by 1 desc;

-- abfrage dauert zu lange, oder ich habe die db überlastet
-- -> Ursache: ohne dat_kurs-Eingrenzung wählt ASE den Table-Scan über kurs.
--    kurs_2_index (dat_kurs, cod_fliesscode, waehrung, num_wfs_ku) deckt die
--    Query vollständig ab, sobald dat_kurs eingegrenzt ist. Q12c hat die
--    Kernfrage ohnehin schon beantwortet — Q12b' ist optional.

-- Q12b': X-Kurse je Jahr, index-gedeckt; Untergrenze bei Bedarf verschieben
select jahr = datepart(yy, dat_kurs), anz = count(*)
from kurs..kurs (index kurs_2_index)
where dat_kurs >= '20080101'
  and cod_fliesscode = 'X'
group by datepart(yy, dat_kurs)
order by 1 desc;

+------+-----+
| jahr | anz |
+------+-----+
| 2024 | 1   |
| 2023 | 1   |
| 2022 | 3   |
| 2021 | 1   |
| 2019 | 7   |
| 2018 | 2   |
| 2017 | 32  |
| 2016 | 1   |
| 2014 | 1   |
| 2013 | 12  |
| 2012 | 2   |
| 2011 | 3   |
| 2010 | 2   |
| 2009 | 10  |
| 2008 | 5   |
+------+-----+

15 Zeile(n) zurückgegeben

-- Q12c: X-Kurse an Tagen MIT Ausschüttung — der Zirkel-Ausweg im engeren Sinn
select jahr = datepart(yy, k.dat_kurs), anz = count(*)
from kurs..kurs k
where k.cod_fliesscode = 'X'
  and exists ( select 1
               from vwkn..wkn_hist h, ifas..ASF a
               where h.num_wfs_ku = k.num_wfs_ku
                 and a.WFS_WKN = h.num_wfs
                 and a.ASF_DATUM = k.dat_kurs )
group by datepart(yy, k.dat_kurs)
order by 1 desc;

+------+-----+
| jahr | anz |
+------+-----+
| 2024 | 1   |
| 2023 | 1   |
| 2022 | 3   |
| 2021 | 1   |
| 2019 | 7   |
| 2018 | 2   |
| 2017 | 29  |
| 2016 | 1   |
| 2013 | 2   |
| 2012 | 2   |
| 2011 | 3   |
| 2010 | 2   |
| 2009 | 10  |
| 2008 | 5   |
+------+-----+

14 Zeile(n) zurückgegeben

-- Q13: r_faktor-Lücken (Gegenprobe zu offenem Punkt K) — aktive inländische
-- Ausschüttungen ohne bzw. mit unplausiblem r_faktor / r_faktor_ges, je Jahr
select jahr              = datepart(yy, a.ASF_DATUM),
       anz_gesamt        = count(*),
       ohne_r_faktor     = sum(case when a.r_faktor is null or a.r_faktor <= 0 then 1 else 0 end),
       ohne_r_faktor_ges = sum(case when a.r_faktor_ges is null or a.r_faktor_ges <= 0 then 1 else 0 end)
from ifas..ASF a
join ifas..INV i on i.WFS_WKN = a.WFS_WKN
where i.KAG < 10000
  and a.aussch_status = 'A'
  and isnull(a.ausschuettung, -1) >= 0
group by datepart(yy, a.ASF_DATUM)
order by 1 desc;

+------+------------+---------------+-------------------+
| jahr | anz_gesamt | ohne_r_faktor | ohne_r_faktor_ges |
+------+------------+---------------+-------------------+
| 2026 | 2934       | 87            | 87                |
| 2025 | 3929       | 79            | 79                |
| 2024 | 3746       | 34            | 34                |
| 2023 | 3636       | 94            | 94                |
| 2022 | 3665       | 54            | 54                |
| 2021 | 3608       | 29            | 29                |
| 2020 | 3579       | 28            | 28                |
| 2019 | 3555       | 38            | 38                |
| 2018 | 3399       | 26            | 26                |
| 2017 | 3265       | 71            | 69                |
| 2016 | 3380       | 20            | 20                |
| 2015 | 3729       | 40            | 40                |
| 2014 | 4008       | 72            | 72                |
| 2013 | 3954       | 71            | 75                |
| 2012 | 3618       | 51            | 52                |
| 2011 | 2571       | 3             | 3                 |
| 2010 | 2564       | 6             | 6                 |
| 2009 | 2596       | 4             | 4                 |
| 2008 | 2623       | 0             | 0                 |
| 2007 | 2408       | 0             | 0                 |
| 2006 | 2287       | 0             | 0                 |
| 2005 | 2113       | 0             | 0                 |
| 2004 | 1915       | 0             | 0                 |
| 2003 | 1790       | 0             | 0                 |
| 2002 | 1705       | 1             | 0                 |
| 2001 | 1511       | 0             | 0                 |
| 2000 | 1311       | 0             | 0                 |
| 1999 | 1017       | 3             | 0                 |
| 1998 | 700        | 1             | 0                 |
| 1997 | 555        | 0             | 0                 |
| 1996 | 485        | 0             | 0                 |
| 1995 | 416        | 0             | 0                 |
| 1994 | 371        | 0             | 0                 |
| 1993 | 326        | 0             | 0                 |
| 1992 | 302        | 0             | 0                 |
| 1991 | 269        | 0             | 0                 |
| 1990 | 220        | 0             | 0                 |
| 1989 | 145        | 0             | 0                 |
| 1988 | 84         | 0             | 0                 |
| 1987 | 49         | 0             | 0                 |
| 1986 | 25         | 0             | 0                 |
| 1985 | 16         | 0             | 0                 |
| 1984 | 13         | 0             | 0                 |
| 1983 | 11         | 0             | 0                 |
| 1982 | 10         | 0             | 0                 |
| 1981 | 10         | 0             | 0                 |
| 1980 | 10         | 0             | 0                 |
| 1979 | 8          | 0             | 0                 |
| 1978 | 6          | 0             | 0                 |
| 1977 | 6          | 0             | 0                 |
| 1976 | 6          | 0             | 0                 |
| 1975 | 6          | 0             | 0                 |
| 1974 | 6          | 0             | 0                 |
| 1973 | 6          | 0             | 0                 |
| 1972 | 6          | 0             | 0                 |
| 1971 | 6          | 0             | 0                 |
| 1970 | 5          | 0             | 0                 |
| 1969 | 3          | 0             | 0                 |
| 1968 | 2          | 0             | 0                 |
| 1967 | 2          | 0             | 0                 |
| 1966 | 2          | 0             | 0                 |
| 1965 | 1          | 0             | 0                 |
| 1964 | 1          | 0             | 0                 |
| 1963 | 1          | 0             | 0                 |
| 1962 | 1          | 0             | 0                 |
| 1961 | 1          | 0             | 0                 |
| 1960 | 1          | 0             | 0                 |
| 1959 | 1          | 0             | 0                 |
| 1958 | 1          | 0             | 0                 |
| 1957 | 1          | 0             | 0                 |
+------+------------+---------------+-------------------+

70 Zeile(n) zurückgegeben

-- ============================================================================
-- Block V — weitere Voranalysen aus der Datenbeschaffung (neu 2026-09-02)
-- ============================================================================

-- V1a: produktive tax_code-Zeilen — definiert das GESAMTE Ingest-Prüfverhalten
-- (blockiert Schnitt 1). L1/L2/L3 fehlen in allen eingecheckten Seeds;
-- entscheidend sind untergrenze/obergrenze/max_nk/future/isinwaehrung/
-- ignore_null und die Datumsgrenzen.
select *
from kurs..tax_code
order by inland_ausland, sort_order, taxcode;

+---------+-------+----------------+-------------------------------------------------------------------------------------------------------------------------------+-----------------------------------------------------------------------------------------+-----------+--------+-------------+------------+------------+-----------+----------------+------------+--------+--------+----------------------+---------------+----------------+-----------------------+-----------------------+-----------------------+-----------+---------------------+--------------+-------------+--------+
| taxcode | alias | inland_ausland | txt_bez                                                                                                                       | txt_bez_e                                                                               | mandatory | gruppe | untergrenze | obergrenze | sort_order | intervall | check_taeglich | check_jahr | sperre | future | intervall_irregulaer | maxanteil_nav | selbstnachweis | lieferung_ab          | lieferung_bis         | datum_max             | datum_min | datum_bug_or_ignore | isinwaehrung | ignore_null | max_nk |
+---------+-------+----------------+-------------------------------------------------------------------------------------------------------------------------------+-----------------------------------------------------------------------------------------+-----------+--------+-------------+------------+------------+-----------+----------------+------------+--------+--------+----------------------+---------------+----------------+-----------------------+-----------------------+-----------------------+-----------+---------------------+--------------+-------------+--------+
| AK      | NULL  | A              | Laufender KESt Betrag                                                                                                         | KESt laufend                                                                            | O         | KEST   | 0.0         | NULL       | NULL       | D         | NULL           | NULL       | NULL   | NULL   | NULL                 | 20.0          | NULL           | NULL                  | 2012-06-30 00:00:00.0 | 2012-03-31 00:00:00.0 | NULL      | NULL                | N            | J           | NULL   |
| AS      | NULL  | A              | Splitfaktor (alt/neu)                                                                                                         | Faktor of split (=old number/new number of shares)                                      | O         | SPLIT  | NULL        | NULL       | NULL       | I         | NULL           | NULL       | NULL   | NULL   | J                    | NULL          | NULL           | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | N            | NULL        | NULL   |
| Q2      | QAGE  | A              | EU-QuSt des Ausschüttungsgleichen Ertrages                                                                                    | EU-QuSt AG Ertrag                                                                       | M         | QUST   | NULL        | NULL       | 5          | A         | NULL           | Q          | Q      | N      | NULL                 | NULL          | NULL           | NULL                  | 2016-12-31 00:00:00.0 | NULL                  | NULL      | NULL                | N            | NULL        | NULL   |
| AQS     | NULL  | A              | Anrechenbare auslÃ¤ndische Quellensteuer                                                                                      | Anr.bare ausl. QuSt                                                                     | O         | AGE    | 0.0         | NULL       | 7          | A         | NULL           | NULL       | NULL   | N      | NULL                 | NULL          | J              | 2015-01-01 00:00:00.0 | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| AASIF   | NULL  | A              | Anrechenbare ausländische Steuern bei ausländischen Immobilienfonds                                                           | Anr.bare ausl. Steuern bei ausl. Imm.Fonds                                              | O         | AGE    | 0.0         | NULL       | 15         | A         | NULL           | NULL       | NULL   | N      | NULL                 | NULL          | J              | 2013-08-01 00:00:00.0 | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| TD      | NULL  | A              | KESt auf Zinsen gem. Para. 98 Abs. 1 Z 5 lit. b EStG 1988 auf AusschÃ¼ttungen                                                 | KESt Zinsen § 98 Ausschüttungen                                                         | O         | AUSSCH | 0.0         | NULL       | 32         | A         | NULL           | NULL       | NULL   | J      | NULL                 | NULL          | NULL           | 2015-01-01 00:00:00.0 | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| AE      | NULL  | A              | Ausschüttungsgleicher Ertrag                                                                                                  | AG Ertrag                                                                               | O         | AGE    | 0.0         | NULL       | 34         | A         | NULL           | NULL       | NULL   | NULL   | NULL                 | NULL          | NULL           | NULL                  | 2012-03-31 00:00:00.0 | NULL                  | NULL      | J                   | N            | J           | NULL   |
| AF      | NULL  | A              | Realisierter Substanzgewinn private Anleger                                                                                   | Real. Substanzgewinn priv. Anleger                                                      | O         | AGE    | 0.0         | NULL       | 35         | A         | NULL           | NULL       | NULL   | NULL   | NULL                 | NULL          | NULL           | NULL                  | 2012-03-31 00:00:00.0 | NULL                  | NULL      | J                   | N            | J           | NULL   |
| AG      | NULL  | A              | Realisierter Substanzgewinn betriebliche Anleger                                                                              | Real. Substanzgewinn betr. Anleger                                                      | O         | AGE    | 0.0         | NULL       | 36         | A         | NULL           | NULL       | NULL   | NULL   | NULL                 | NULL          | NULL           | NULL                  | 2012-03-31 00:00:00.0 | NULL                  | NULL      | J                   | N            | J           | NULL   |
| AH      | NULL  | A              | KESt Betrag Ausschüttungsgleicher Ertrag - private Anleger                                                                    | KESt AG Ertrag priv. Anleger                                                            | O         | AGE    | 0.0         | NULL       | 37         | A         | NULL           | AK         | AK     | NULL   | NULL                 | 20.0          | NULL           | NULL                  | 2012-03-31 00:00:00.0 | NULL                  | NULL      | J                   | N            | J           | NULL   |
| AI      | NULL  | A              | KESt Betrag Ausschüttungsgleicher Ertrag - betriebliche Anleger                                                               | KESt AG Ertrag betr. Anleger                                                            | O         | AGE    | 0.0         | NULL       | 38         | A         | NULL           | AK         | AK     | NULL   | NULL                 | 20.0          | NULL           | NULL                  | 2012-03-31 00:00:00.0 | NULL                  | NULL      | J                   | N            | J           | NULL   |
| AD      | NULL  | A              | Ausschüttung                                                                                                                  | Ausschüttung                                                                            | O         | AUSSCH | 0.0         | NULL       | 39         | A         | AK             | NULL       | AK     | J      | NULL                 | NULL          | NULL           | NULL                  | 2012-06-30 00:00:00.0 | 2012-03-31 00:00:00.0 | NULL      | NULL                | N            | J           | NULL   |
| AT      | NULL  | A              | KESt Betrag der Ausschüttung                                                                                                  | KESt Ausschüttung                                                                       | O         | AUSSCH | 0.0         | NULL       | 40         | A         | NULL           | NULL       | AK     | J      | NULL                 | NULL          | NULL           | NULL                  | 2012-06-30 00:00:00.0 | 2012-03-31 00:00:00.0 | NULL      | NULL                | N            | J           | NULL   |
| C       | NULL  | I              | KESt-Pflicht                                                                                                                  | KESt-Pflicht laufend                                                                    | O         | KEST   | 0.0         | NULL       | NULL       | D         | NULL           | NULL       | NULL   | N      | NULL                 | NULL          | NULL           | NULL                  | 2012-12-31 00:00:00.0 | 2012-03-31 00:00:00.0 | NULL      | NULL                | N            | NULL        | NULL   |
| F       | NULL  | I              | KESt-Gesamt                                                                                                                   | KESt laufend                                                                            | O         | KEST   | 0.0         | NULL       | NULL       | D         | NULL           | NULL       | NULL   | N      | NULL                 | NULL          | NULL           | NULL                  | 2012-12-31 00:00:00.0 | 2012-03-31 00:00:00.0 | NULL      | NULL                | N            | NULL        | NULL   |
| L1      | NULL  | I              | LMT - RuecknahmebeschrÃ¤nkung                                                                                                 | LMT-Ruecknahmebeschraenkung                                                             | O         | LMT    | 0.0         | NULL       | NULL       | NULL      | NULL           | NULL       | NULL   | N      | NULL                 | NULL          | NULL           | 2026-03-01 00:00:00.0 | NULL                  | NULL                  | NULL      | NULL                | J            | NULL        | 8      |
| L2      | NULL  | I              | LMT - Verlaengerung der Rueckgabefrist                                                                                        | LMT-Verlaengerung der Rueckgabefrist                                                    | O         | LMT    | 0.0         | NULL       | NULL       | NULL      | NULL           | NULL       | NULL   | N      | NULL                 | NULL          | NULL           | 2026-03-01 00:00:00.0 | NULL                  | NULL                  | NULL      | NULL                | J            | NULL        | 8      |
| L3      | NULL  | I              | LMT - Rueckgabegebuehr                                                                                                        | LMT-Rueckgabegebuehr                                                                    | O         | LMT    | 0.0         | NULL       | NULL       | NULL      | NULL           | NULL       | NULL   | N      | NULL                 | NULL          | NULL           | 2026-03-01 00:00:00.0 | NULL                  | NULL                  | NULL      | NULL                | J            | NULL        | 8      |
| S       | NULL  | I              | Solvabilität                                                                                                                  | Solvabilität                                                                            | O         | SOLVA  | -100.0      | 150.0      | NULL       | D         | NULL           | NULL       | NULL   | NULL   | NULL                 | NULL          | NULL           | NULL                  | NULL                  | NULL                  | NULL      | NULL                | N            | NULL        | NULL   |
| S2      | NULL  | I              | Solvabilität 2 (Standard Ansatz)                                                                                              | Solvabilität 2 (Standard)                                                               | O         | SOLVA  | -100.0      | 1250.0     | NULL       | D         | NULL           | NULL       | NULL   | NULL   | NULL                 | NULL          | NULL           | NULL                  | NULL                  | NULL                  | NULL      | NULL                | N            | NULL        | NULL   |
| S3      | NULL  | I              | Solvabilität 2.1 (IRB-Ansatz)                                                                                                 | Solvabilität 2.1 (IRB)                                                                  | O         | SOLVA  | -100.0      | 1250.0     | NULL       | D         | NULL           | NULL       | NULL   | NULL   | NULL                 | NULL          | NULL           | NULL                  | NULL                  | NULL                  | NULL      | NULL                | N            | NULL        | NULL   |
| KESTP   | NULL  | I              | KESt-Betrag der Ausschüttung Pflicht (ohne Optionserklärung)  - nur AT-Fonds                                                  | KESt-Betrag Pflicht (ohne Optionserklärung)                                             | M         | AUSSCH | 0.0         | NULL       | 24         | A         | NULL           | NULL       | AK     | J      | NULL                 | NULL          | NULL           | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| KESTS   | NULL  | I              | KESt Substanzgewinn der Ausschüttung - nur AT-Fonds                                                                           | KESt Substanzgewinn                                                                     | M         | AUSSCH | 0.0         | NULL       | 25         | A         | NULL           | NULL       | AK     | J      | NULL                 | NULL          | NULL           | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| E       | NULL  | IA             | Ausgabepreis                                                                                                                  | Ausgabepreis                                                                            | O         | PREIS  | 1.0E-8      | NULL       | NULL       | D         | NULL           | NULL       | NULL   | N      | NULL                 | NULL          | NULL           | NULL                  | NULL                  | NULL                  | NULL      | NULL                | N            | NULL        | NULL   |
| Q       | NULL  | IA             | Tägliche EU-QuSt pro Fondsanteil                                                                                              | EU-QuSt laufend                                                                         | M         | QUST   | 0.0         | NULL       | NULL       | D         | Q              | NULL       | Q      | N      | NULL                 | NULL          | NULL           | NULL                  | 2016-12-31 00:00:00.0 | NULL                  | NULL      | NULL                | N            | NULL        | NULL   |
| R       | NULL  | IA             | Errechneter Wert                                                                                                              | Errechneter Wert                                                                        | M         | PREIS  | 1.0E-8      | NULL       | NULL       | D         | NULL           | NULL       | NULL   | N      | NULL                 | NULL          | NULL           | NULL                  | NULL                  | NULL                  | NULL      | NULL                | N            | NULL        | NULL   |
| T       | NULL  | IA             | Täglicher TIS pro Fondsanteil                                                                                                 | TIS laufend                                                                             | M         | QUST   | 0.0         | NULL       | NULL       | D         | NULL           | NULL       | Q      | N      | NULL                 | 15.0          | NULL           | NULL                  | 2016-12-31 00:00:00.0 | NULL                  | NULL      | NULL                | N            | NULL        | NULL   |
| TA      | NULL  | IA             | Laufende KESt auf Zinsen gem. Para. 98 Abs. 1 Z 5 lit. b EStG 1988                                                            | KESt Zinsen § 98 laufend                                                                | O         | KEST   | 0.0         | NULL       | NULL       | D         | 98             | NULL       | 98     | N      | NULL                 | NULL          | NULL           | 2015-01-01 00:00:00.0 | 2016-12-31 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| Z       | NULL  | IA             | Rüchnahmepreis                                                                                                                | Rücknahmepreis                                                                          | O         | PREIS  | 1.0E-8      | NULL       | NULL       | D         | NULL           | NULL       | NULL   | N      | NULL                 | NULL          | NULL           | NULL                  | NULL                  | NULL                  | NULL      | NULL                | N            | NULL        | NULL   |
| ALOE    | NULL  | IA             | Als ausgeschüttet zu behandelnde laufende ordentliche Erträge je Anteil                                                       | AG ordentliche Erträge                                                                  | M         | AGE    | NULL        | NULL       | 1          | A         | NULL           | AK         | AK     | N      | NULL                 | 50.0          | J              | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| KEST    | NULL  | IA             | KESt Betrag des Ausschüttungsgleichen Ertrages                                                                                | KESt AG Ertrag                                                                          | M         | AGE    | NULL        | NULL       | 2          | A         | NULL           | AK         | AK     | N      | NULL                 | 20.0          | J              | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| SSGPV   | NULL  | IA             | Im Privatvermögen steuerpflichtige Substanzgewinne je Anteil                                                                  | Steuerpfl. Substanzgew. Privatverm.                                                     | M         | AGE    | 0.0         | NULL       | 3          | A         | NULL           | AK         | AK     | N      | NULL                 | NULL          | J              | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| SSGBV   | NULL  | IA             | Im Betriebsvermögen steuerpflichtige Substanzgewinne je Anteil                                                                | Steuerpfl. Substanzgew. Betriebsverm.                                                   | M         | AGE    | 0.0         | NULL       | 4          | A         | NULL           | AK         | AK     | N      | NULL                 | NULL          | J              | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| AKE     | NULL  | IA             | KESt auf Zinsen gem. Para. 98 Abs. 1 Z 5 lit. b EStG 1988                                                                     | KESt Zinsen § 98                                                                        | M         | AGE98  | 0.0         | NULL       | 6          | A         | NULL           | 98         | 98     | N      | NULL                 | NULL          | J              | 2015-01-01 00:00:00.0 | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| KBAP    | NULL  | IA             | Korrekturbetrag Anschaffungskosten (AG Erträge) für Privatanleger (für KESt Zwecke relevant)                                  | KB Ansch.kosten (AG Erträge) Privatanl.                                                 | M         | AGE    | 0.0         | NULL       | 8          | A         | NULL           | AK         | AK     | N      | NULL                 | NULL          | J              | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| KBAPE   | NULL  | IA             | Vorzeichenverkehrt anzuwendender Korrekturbetrag Anschaffungskosten (AG Erträge) für Privatanleger (für KESt Zwecke relevant) | Vorzeichenverkehrt anzuw. KB Anschaffungskosten (AG Erträge) Privatanl.                 | O         | AGE    | 0.0         | NULL       | 9          | A         | NULL           | NULL       | NULL   | N      | NULL                 | NULL          | J              | 2013-08-01 00:00:00.0 | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| KBABN   | NULL  | IA             | Korrekturbetrag Anschaffungskosten (AG Erträge) für betriebliche Anleger (natürliche Person)                                  | KB Ansch.kosten (AG Erträge) betr. Anleger (nat. Person)                                | O         | AGE    | 0.0         | NULL       | 10         | A         | NULL           | NULL       | AK     | N      | NULL                 | NULL          | J              | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| KBABJ   | NULL  | IA             | Korrekturbetrag Anschaffungskosten (AG Erträge) für betriebliche Anleger (juristische Person)                                 | KB Ansch.kosten (AG Erträge) betr. Anleger (jur. Person)                                | O         | AGE    | 0.0         | NULL       | 11         | A         | NULL           | NULL       | AK     | N      | NULL                 | NULL          | J              | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| KBAPS   | NULL  | IA             | Korrekturbetrag Anschaffungskosten (AG Erträge) für Privatstiftungen                                                          | KB Ansch. (AG Erträge) Privatstiftung                                                   | O         | AGE    | 0.0         | NULL       | 12         | A         | NULL           | NULL       | AK     | N      | NULL                 | NULL          | J              | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| OVVA1   | NULL  | IA             | Gemäß Fonds-Melde-VO § 5 Abs.2 Z 1 auszuweisende Differenz der alten Substanzverluste je Anteil                               | Gemäß FMVO § 5 Abs.2 Z 1 auszuw. Differenz alte Substanzverluste                        | O         | AGE    | NULL        | NULL       | 13         | A         | NULL           | NULL       | NULL   | N      | NULL                 | NULL          | NULL           | 2013-08-01 00:00:00.0 | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| OVVA2   | NULL  | IA             | Gemäß Fonds-Melde-VO § 5 Abs.2 Z 2 auszuweisender Gesamtbetrag der alten Substanzverluste je Anteil im Betriebsvermögen       | Gemäß FMVO § 5 Abs.2 Z 2 auszuw. Gesamtbetrag alte Substanzverluste im Betriebsvermögen | O         | AGE    | NULL        | NULL       | 14         | A         | NULL           | NULL       | NULL   | N      | NULL                 | NULL          | NULL           | 2013-08-01 00:00:00.0 | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| VKAGE   | NULL  | IA             | Verrechenbare KESt AG Ertrag                                                                                                  | Verrechenb. KESt AG Ertrag                                                              | O         | AGE    | 0.0         | NULL       | 16         | A         | NULL           | NULL       | AK     | N      | NULL                 | NULL          | J              | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| ELUF    | NULL  | IA             | Einkünfte aus Land- und Forstwirtschaft (§ 21 EStG 1988)                                                                      | Einkünfte Land-/Forstwirtschaft                                                         | O         | AGE    | 0.0         | NULL       | 17         | A         | NULL           | NULL       | AK     | N      | NULL                 | NULL          | J              | 2014-09-01 00:00:00.0 | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| EGB     | NULL  | IA             | Einkünfte aus Gewerbebetrieb (§ 23 EStG 1988)                                                                                 | Einkünfte Gewerbebetrieb                                                                | O         | AGE    | 0.0         | NULL       | 18         | A         | NULL           | NULL       | AK     | N      | NULL                 | NULL          | J              | 2014-09-01 00:00:00.0 | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| EVV     | NULL  | IA             | Einkünfte aus Vermietung und Verpachtung von Sachinbegriffen (§ 28 EStG 1988)                                                 | Einkünfte Vermietung/Verpachtung                                                        | O         | AGE    | 0.0         | NULL       | 19         | A         | NULL           | NULL       | AK     | N      | NULL                 | NULL          | J              | 2014-09-01 00:00:00.0 | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| SEL     | NULL  | IA             | Einkünfte aus Leistungen (§ 29 Z 3 EStG 1988)                                                                                 | Einkünfte § 29 Z 3 EStG                                                                 | O         | AGE    | 0.0         | NULL       | 20         | A         | NULL           | NULL       | AK     | N      | NULL                 | NULL          | J              | 2014-09-01 00:00:00.0 | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| SPK     | NULL  | IA             | Einkünfte aus Spekulationsgeschäften (§ 31 EStG 1988)                                                                         | Einkünfte § 31 EStG                                                                     | O         | AGE    | 0.0         | NULL       | 21         | A         | NULL           | NULL       | AK     | N      | NULL                 | NULL          | J              | 2014-09-01 00:00:00.0 | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| DIVI    | NULL  | IA             | Ausschüttung pro Fondsanteil                                                                                                  | Ausschüttung                                                                            | M         | AUSSCH | 0.0         | NULL       | 22         | A         | NULL           | NULL       | AK     | J      | NULL                 | 50.0          | NULL           | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| KESTD   | NULL  | IA             | KESt-Betrag der Ausschüttung                                                                                                  | KESt-Betrag                                                                             | M         | AUSSCH | 0.0         | NULL       | 23         | A         | NULL           | NULL       | AK     | J      | NULL                 | 20.0          | NULL           | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| KBP     | NULL  | IA             | Korrekturbetrag Anschaffungskosten (Ausschüttung) für Privatanleger (für KESt Zwecke relevant)                                | KB Ansch.kosten (Ausschüttung) Privatanl.                                               | M         | AUSSCH | 0.0         | NULL       | 26         | A         | NULL           | NULL       | AK     | J      | NULL                 | NULL          | NULL           | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| KBBN    | NULL  | IA             | Korrekturbetrag Anschaffungskosten (Ausschüttung) für betriebliche Anleger (natürliche Person)                                | KB Ansch.kosten (Ausschüttung) betr. Anleger (nat. Person)                              | O         | AUSSCH | 0.0         | NULL       | 27         | A         | NULL           | NULL       | AK     | J      | NULL                 | NULL          | NULL           | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| KBBJ    | NULL  | IA             | Korrekturbetrag Anschaffungskosten (Ausschüttung) für betriebliche Anleger (juristische Person)                               | KB Ansch.kosten (Ausschüttung) betr. Anleger (jur. Person)                              | O         | AUSSCH | 0.0         | NULL       | 28         | A         | NULL           | NULL       | AK     | J      | NULL                 | NULL          | NULL           | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| KBPS    | NULL  | IA             | Korrekturbetrag Anschaffungskosten (Ausschüttung) für Privatstiftungen                                                        | KB Ansch.kosten (Ausschüttung) Privatstiftung                                           | O         | AUSSCH | 0.0         | NULL       | 29         | A         | NULL           | NULL       | AK     | J      | NULL                 | NULL          | NULL           | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| Q1      | QDIV  | IA             | EU-QuSt der Ausschüttung                                                                                                      | EU-QuSt Ausschüttung                                                                    | M         | QUST   | 0.0         | NULL       | 30         | A         | NULL           | NULL       | Q      | J      | NULL                 | 15.0          | NULL           | NULL                  | 2016-12-31 00:00:00.0 | NULL                  | NULL      | NULL                | N            | NULL        | NULL   |
| T1      | TDIV  | IA             | TIS der Ausschüttung -> steuerpflichtiger Betrag der Ausschüttung                                                             | TIS Ausschüttung                                                                        | O         | QUST   | 0.0         | NULL       | 31         | A         | NULL           | NULL       | Q      | J      | NULL                 | NULL          | NULL           | NULL                  | 2016-12-31 00:00:00.0 | NULL                  | NULL      | NULL                | N            | NULL        | NULL   |
| VKDIV   | NULL  | IA             | Verrechenbare KESt Ausschüttung                                                                                               | Verrechenb. KESt Ausschüttung                                                           | M         | AUSSCH | 0.0         | NULL       | 33         | A         | NULL           | NULL       | AK     | J      | NULL                 | NULL          | NULL           | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
| KESTA   | NULL  | IA             | KESt ausl. Dividenden der Ausschüttung                                                                                        | KESt ausl. Dividenden                                                                   | O         | AGE    | 0.0         | NULL       | 41         | A         | NULL           | NULL       | AK     | J      | NULL                 | NULL          | J              | NULL                  | 2016-03-25 00:00:00.0 | NULL                  | NULL      | NULL                | J            | NULL        | 4      |
+---------+-------+----------------+-------------------------------------------------------------------------------------------------------------------------------+-----------------------------------------------------------------------------------------+-----------+--------+-------------+------------+------------+-----------+----------------+------------+--------+--------+----------------------+---------------+----------------+-----------------------+-----------------------+-----------------------+-----------+---------------------+--------------+-------------+--------+

57 Zeile(n) zurückgegeben

-- V1b: die Preiscode-Sicht dazu (kennt S2, S3, X)
select *
from kurs..v_preiscode
order by cod_preiscode;

+---------------+--------------------------------------+
| cod_preiscode | txt_bez                              |
+---------------+--------------------------------------+
| E             | Ausgabepreis                         |
| R             | Errechneter Wert                     |
| S             | Solvabilität                         |
| S2            | Solvabilität 2 (Standard-Ansatz)     |
| S3            | Solvabilität 2.1 (IRB-Ansatz)        |
| X             | Fiktiver idikativer errechneter Wert |
| Z             | Rücknahmepreis                       |
+---------------+--------------------------------------+

7 Zeile(n) zurückgegeben

-- V2a: pool_if_kurs — Bestand und Alter. Der PK enthält cod_ex, also können
-- 'N'- und 'D'-Zeilen zum selben fachlichen Schlüssel koexistieren.
select anz       = count(*),
       min_dat   = min(dat_kurs),
       max_dat   = max(dat_kurs),
       min_eintr = min(eintragezeit),
       max_eintr = max(eintragezeit)
from kurs..pool_if_kurs;

+------+-----------------------+-----------------------+-----------------------+-------------------------+
| anz  | min_dat               | max_dat               | min_eintr             | max_eintr               |
+------+-----------------------+-----------------------+-----------------------+-------------------------+
| 4767 | 2005-07-01 00:00:00.0 | 2012-03-30 00:00:00.0 | 2005-07-01 12:30:05.0 | 2012-03-30 14:37:23.873 |
+------+-----------------------+-----------------------+-----------------------+-------------------------+

1 Zeile(n) zurückgegeben

-- V2b: pool_if_kurs — fachliche Schlüssel mit mehreren Zeilen (N neben D):
-- beantwortet, ob der monotone Guard auch für den Pool gebraucht wird
select num_okb, dat_kurs, cod_waehrung, cod_preiscode, anz = count(*)
from kurs..pool_if_kurs
group by num_okb, dat_kurs, cod_waehrung, cod_preiscode
having count(*) > 1
order by dat_kurs desc;

-- keine ergebnisse

-- V3a: tmp_if_last — Altersprofil gegen das 65-Tage-Lesefenster
-- (Grundlage für den Seed von letzte_preise und den B3-Diff)
select im_65_tage_fenster = case when dat_kurs > dateadd(dd, -65, getdate()) then 'J' else 'N' end,
       anz                = count(*)
from kurs..tmp_if_last
group by case when dat_kurs > dateadd(dd, -65, getdate()) then 'J' else 'N' end;

+--------------------+-------+
| im_65_tage_fenster | anz   |
+--------------------+-------+
| N                  | 16064 |
| J                  | 14604 |
+--------------------+-------+

2 Zeile(n) zurückgegeben

-- V3b: tmp_if_last — Zeilen mit heute nicht auflösbarer ISIN (genau die
-- Werte, die kurs nie gesehen hat; Beleg, dass die Projektion nicht aus kurs
-- ableitbar ist)
select anz = count(*)
from kurs..tmp_if_last t
where not exists ( select 1
                   from vwkn..wkn_hist h
                   where h.cod_quelle = 'ISIN'
                     and h.num_wkn = t.num_okb );

+-----+
| anz |
+-----+
| 906 |
+-----+

1 Zeile(n) zurückgegeben

-- V3c: tmp_if_last — cod_ex-Verteilung (Konzept: WriteLastKurse setzt hart
-- 'N'; alles andere wäre ein Befund)
select cod_ex, anz = count(*)
from kurs..tmp_if_last
group by cod_ex;

+--------+-------+
| cod_ex | anz   |
+--------+-------+
| N      | 30668 |
+--------+-------+

1 Zeile(n) zurückgegeben

-- V4: heutiger Eingang je Lieferant (Momentaufnahme tmp_if_kurs; Kontext für
-- Q4 und für die Volumsannahmen ~4200 Preise/Tag)
select liefer_id,
       anz       = count(*),
       min_eintr = min(eintragezeit),
       max_eintr = max(eintragezeit)
from kurs..tmp_if_kurs
group by liefer_id
order by anz desc;

+-----------+-----+------------------------+-------------------------+
| liefer_id | anz | min_eintr              | max_eintr               |
+-----------+-----+------------------------+-------------------------+
| db_spard  | 81  | 2026-08-28 15:36:18.63 | 2026-08-28 16:36:10.967 |
+-----------+-----+------------------------+-------------------------+

1 Zeile(n) zurückgegeben

-- todo auf Prod nach Lieferschluss wiederholen (Momentaufnahme nach dem Tagesjob —
--      nur der Nachzügler db_spard war noch da, Volumen nicht repräsentativ)

-- V5: kurs.guelt — ist das Feld überhaupt gepflegt? (C3 sieht guelt als
-- Reparatursignal vor; viele NULLs entwerten den Pfad)
select anz_gesamt = count(*),
       anz_guelt_null = sum(case when guelt is null then 1 else 0 end),
       max_guelt = max(guelt)
from kurs..kurs;

-- abfrage dauert zu lange
-- -> Ursache: Aggregat über die ganze Tabelle = Table-Scan. Die eigentliche
--    Frage ist nur "wird guelt AKTUELL gepflegt?" — dafür reichen drei billige
--    Zugriffe über kurs_guelt_index (guelt, num_wfs_ku, dat_kurs):

-- V5'a: jüngster guelt-Wert (Index-Zugriff)
select max_guelt = max(guelt)
from kurs..kurs;

+------------------------+
| max_guelt              |
+------------------------+
| 2026-08-28 16:01:19.91 |
+------------------------+

1 Zeile(n) zurückgegeben

-- V5'b: gibt es NULL-guelt-Zeilen, und wie viele? (Seek auf die NULL-Gruppe)
select anz_guelt_null = count(*)
from kurs..kurs (index kurs_guelt_index)
where guelt is null;

+----------------+
| anz_guelt_null |
+----------------+
| 29502340       |
+----------------+

1 Zeile(n) zurückgegeben

-- V5'c: wie viele kurs-Zeilen wurden in den letzten 7 Tagen berührt?
select anz_letzte_7_tage = count(*)
from kurs..kurs (index kurs_guelt_index)
where guelt >= dateadd(dd, -7, getdate());

-- achtung - abzug ist nicht tagesaktuell (ca 4 tage alt)

+-------------------+
| anz_letzte_7_tage |
+-------------------+
| 46105             |
+-------------------+

1 Zeile(n) zurückgegeben


-- ============================================================================
-- Block F — Nachfass-Queries aus den Ergebnissen vom 2026-09-02 (TEST-Abzug)
--
-- Kernbefund Block J: es gibt KEINEN aktiven liefer_typ='F'-Lieferanten
-- (Q0a/Q0b: alle 29 fp_*-Konten aktiv='N', Rückmeldeadressen intern
-- abi@oekb.at); die reale Lieferung in V4 kam über 'db_spard'. Die
-- F-Typisierung ist tot — diese Queries klären, worüber die Zuordnung heute
-- tatsächlich läuft. Q4/V4 auf dem Abzug sind nicht aussagekräftig
-- (tmp_if_kurs nach dem Tagesjob fast leer) — auf Prod nach Lieferschluss,
-- vor dem Tagesjob wiederholen.
-- ============================================================================

-- F1: KAG_lieferanten nach liefer_typ/aktiv — wer steht überhaupt in der
-- Zuordnungstabelle, und wie viele KAGs deckt das ab?
select liefer_typ      = isnull(l.liefer_typ, '-'),
       aktiv           = isnull(l.aktiv, '-'),
       anz_zuordnungen = count(*),
       anz_kags        = count(distinct kl.KAG)
from kurs..KAG_lieferanten kl
join kurs..lieferanten l on l.liefer_id = kl.liefer_id
group by isnull(l.liefer_typ, '-'), isnull(l.aktiv, '-')
order by 1, 2;

+------------+-------+-----------------+----------+
| liefer_typ | aktiv | anz_zuordnungen | anz_kags |
+------------+-------+-----------------+----------+
| A          | J     | 1126            | 1010     |
| A          | N     | 176             | 154      |
| F          | N     | 10              | 9        |
| J          | J     | 8               | 8        |
+------------+-------+-----------------+----------+

4 Zeile(n) zurückgegeben

-- F2: Q1 ohne F-Filter — aktive Lieferanten (beliebiger Typ) je KAG
select anz_lieferanten = t.anz,
       anz_kags        = count(*)
from ( select kl.KAG, anz = count(*)
       from kurs..KAG_lieferanten kl
       join kurs..lieferanten l on l.liefer_id = kl.liefer_id
       where isnull(l.aktiv, 'J') = 'J'
       group by kl.KAG ) t
group by t.anz
order by t.anz;

+-----------------+----------+
| anz_lieferanten | anz_kags |
+-----------------+----------+
| 1               | 926      |
| 2               | 57       |
| 3               | 24       |
| 4               | 3        |
| 5               | 2        |
+-----------------+----------+

5 Zeile(n) zurückgegeben

-- F3: meldepflichtige Fonds ohne jeden AKTIVEN Lieferanten (beliebiger Typ) —
-- die echte "Fehlmeldung ohne Adressat"-Menge
select anz = count(*)
from ifas..INV i
join vwkn..wkn_desc d on d.num_wfs = i.WFS_WKN
where i.status = 'A'
  and d.cod_art_f in ('FOND', 'TECH', 'C-PL')
  and getdate() between isnull(i.fonds_beginn, '21000101') and isnull(i.fonds_ende, '21000101')
  and i.KAG < 10000
  and i.preismeldung = 'TGL'
  and not exists ( select 1
                   from kurs..KAG_lieferanten kl
                   join kurs..lieferanten l on l.liefer_id = kl.liefer_id
                   where kl.KAG = i.KAG
                     and isnull(l.aktiv, 'J') = 'J' );

+-----+
| anz |
+-----+
| 0   |
+-----+

1 Zeile(n) zurückgegeben

-- F4: die aktiven Lieferanten mit KAG-Zuordnung im Detail (die realen
-- Kandidaten für die Fehlmeldungs-Adressierung)
select l.liefer_id, l.liefer_typ, l.aktiv, l.inland_ausland, l.bezeichnung,
       anz_kags = count(distinct kl.KAG)
from kurs..lieferanten l
join kurs..KAG_lieferanten kl on kl.liefer_id = l.liefer_id
where isnull(l.aktiv, 'J') = 'J'
group by l.liefer_id, l.liefer_typ, l.aktiv, l.inland_ausland, l.bezeichnung
order by anz_kags desc;

+-------------------+------------+-------+----------------+-----------------------------------------------------------------------------+----------+
| liefer_id         | liefer_typ | aktiv | inland_ausland | bezeichnung                                                                 | anz_kags |
+-------------------+------------+-------+----------------+-----------------------------------------------------------------------------+----------+
| af_pwc            | A          | J     | A              | non-AT F.: PwC PricewaterhouseCoopers Wirtschaftsprüfung und Steuerb. GmbH  | 246      |
| af_deloitte       | A          | J     | A              | non-AT Fonds: Deloitte Tax Wirtschaftsprüfungs GmbH                         | 191      |
| af_ernstyoung     | A          | J     | A              | non-AT Fonds: Ernst & Young Steuerberatungsgesellschaft m.b.H.              | 182      |
| af_erstebank      | A          | J     | A              | non-AT Fonds: Erste Group im Namen der Erste Bank der österr. Sparkassen    | 179      |
| af_kpmg           | A          | J     | A              | non-AT Fonds: KPMG Alpen-Treuhand GmbH                                      | 165      |
| af_leitnerleitner | A          | J     | A              | non-AT Fonds: LeitnerLeitner GmbH Wirtschaftsprüfer und Steuerberater       | 45       |
| af_tpah           | A          | J     | A              | non-AT Fonds: TPA Steuerberatung GmbH                                       | 16       |
| af_moritz         | A          | J     | A              | non-AT Fonds: Dr. Helmut Moritz                                             | 14       |
| af_bdo            | A          | J     | A              | non-AT Fonds: BDO Austria GmbH                                              | 13       |
| db_kpmg           | J          | J     | I              | AT-Fonds: KPMG Alpen-Treuhand GmbH                                          | 8        |
| db_spard          | A          | J     | I              | AT-Fonds Preise: Erste Group Bank AG                                        | 7        |
| db_aigner         | A          | J     | I              | AT-Fonds: Dr. Gernot Aigner                                                 | 6        |
| db_rrz            | A          | J     | I              | Raiffeisen Bank International AG                                            | 6        |
| db_copri          | A          | J     | I              | Liechtensteinische Landesbank (Österreich) AG                               | 5        |
| af_oevag          | A          | J     | A              | non-AT Fonds: Volksbank Wien AG                                             | 4        |
| af_kpmglu         | A          | J     | A              | non AT-Fonds: KPMG Tax and Advisory S.à r.l.                                | 4        |
| db_bdo            | A          | J     | I              | AT-Fonds: BDO Austria GmbH                                                  | 4        |
| db_semper         | A          | J     | I              | LLB Invest Kapitalanlagegesellschaft m.b.H.                                 | 4        |
| db_deloitte       | A          | J     | I              | AT-Fonds: Deloitte Wirtschaftsprüfungs GmbH                                 | 3        |
| db_pwc            | A          | J     | I              | AT-Fonds: PwC PricewaterhouseCoopers Wirtschaftsprüfung und Steuerb. GmbH   | 3        |
| af_hypovbg        | A          | J     | A              | non-AT Fonds: Hypo Vorarlberg Bank AG                                       | 2        |
| af_rsm            | A          | J     | A              | non AT-Fonds: RSM Austria Steuerberatung GmbH                               | 2        |
| db_pioneer        | A          | J     | I              | UniCredit Business Partner GmbH                                             | 2        |
| db_ernstyoung     | A          | J     | I              | AT-Fonds: Ernst & Young Steuerberatungsgesellschaft m.b.H.                  | 2        |
| af_gtaustria      | A          | J     | A              | non AT-Fonds: Grant Thornton Austria GmbH                                   | 1        |
| af_lohr           | A          | J     | A              | non-AT Fonds: Lohr + Company GmbH Wirtschaftsprüf.- und Steuerberatungsges. | 1        |
| db_iqam           | A          | J     | I              | IQAM Invest GmbH                                                            | 1        |
| db_kepler         | A          | J     | I              | Kepler-Fonds KAG                                                            | 1        |
| db_amp            | A          | J     | I              | Ampega Investment GmbH                                                      | 1        |
| db_argon          | A          | J     | I              | Argon Steuerberatung GmbH                                                   | 1        |
| db_schoeller      | A          | J     | I              | Schoellerbank Invest AG                                                     | 1        |
| db_gut            | A          | J     | I              | Bank Gutmann Aktiengesellschaft                                             | 1        |
| db_hypovbg        | A          | J     | I              | AT-Fonds: Hypo Vorarlberg Bank AG                                           | 1        |
| db_kpmgnoe        | A          | J     | I              | AT-Fonds: KPMG Niederösterreich GmbH                                        | 1        |
| db_masterinvest   | A          | J     | I              | MASTERINVEST Kapitalanlage GmbH                                             | 1        |
| db_sec            | A          | J     | I              | Security Kapitalanlage Aktiengesellschaft                                   | 1        |
| db_rai            | A          | J     | I              | Raiffeisen Kapitalanlage-Gesellschaft m.b.H.                                | 1        |
| db_allianz        | A          | J     | I              | Allianz Invest Kapitalanlagegesellschaft mbH                                | 1        |
| db_sparinvest     | A          | J     | I              | AT-Fonds STM: Erste Asset Management GmbH                                   | 1        |
| db_ersteimmo      | A          | J     | I              | ERSTE Immobilien Kapitalanlagegesellschaft m.b.H.                           | 1        |
| db_rloo           | A          | J     | I              | Raiffeisenlandesbank Oberösterreich Aktiengesellschaft                      | 1        |
| db_bareal         | A          | J     | I              | Bank Austria Real Invest Immobilien-Kapitalanlage GmbH                      | 1        |
| db_obli           | A          | J     | I              | Oberbank AG, Zahlungsverkehrssysteme und zentrale Produktion                | 1        |
| db_sparooe        | A          | J     | I              | Sparkasse Oberösterreich Kapitalanlagegesellschaft m.b.H.                   | 1        |
| db_macquarie      | A          | J     | I              | Macquarie Investment Management Austria Kapitalanlage AG                    | 1        |
+-------------------+------------+-------+----------------+-----------------------------------------------------------------------------+----------+

45 Zeile(n) zurückgegeben

-- F5: der tatsächliche Preislieferant aus V4 im Detail
select liefer_id, liefer_typ, aktiv, inland_ausland, bezeichnung, email_at, re_mail1
from kurs..lieferanten
where liefer_id = 'db_spard';

+-----------+------------+-------+----------------+--------------------------------------+-------------+-------------+
| liefer_id | liefer_typ | aktiv | inland_ausland | bezeichnung                          | email_at    | re_mail1    |
+-----------+------------+-------+----------------+--------------------------------------+-------------+-------------+
| db_spard  | A          | J     | I              | AT-Fonds Preise: Erste Group Bank AG | abi@oekb.at | abi@oekb.at |
+-----------+------------+-------+----------------+--------------------------------------+-------------+-------------+

1 Zeile(n) zurückgegeben

-- F6: die 95 V-Zeilen aus Q9/Q10 — liegen ihre ASF_DATUM in der Zukunft
-- (harmlos, warten auf Aktivierung) oder in der Vergangenheit (könnten in
-- das ReadAusschuettung-Fenster fallen)?
select lage = case when a.ASF_DATUM > getdate() then 'Zukunft' else 'Vergangenheit' end,
       anz  = count(*),
       min_datum = min(a.ASF_DATUM),
       max_datum = max(a.ASF_DATUM)
from ifas..ASF a
join ifas..INV i on i.WFS_WKN = a.WFS_WKN
where i.KAG < 10000
  and a.aussch_status = 'V'
  and isnull(a.ausschuettung, -1) >= 0
group by case when a.ASF_DATUM > getdate() then 'Zukunft' else 'Vergangenheit' end;

+---------------+-----+-----------------------+-----------------------+
| lage          | anz | min_datum             | max_datum             |
+---------------+-----+-----------------------+-----------------------+
| Vergangenheit | 93  | 2026-08-31 00:00:00.0 | 2026-09-02 00:00:00.0 |
| Zukunft       | 2   | 2026-09-15 00:00:00.0 | 2026-09-30 00:00:00.0 |
+---------------+-----+-----------------------+-----------------------+

2 Zeile(n) zurückgegeben

-- F7: Q13-Nachfassung — wie viele r_faktor-Lücken betreffen ausschuettung = 0
-- (dort wäre r_faktor rechnerisch 1.0, die Lücke also harmlos) gegen > 0?
select typ = case when a.ausschuettung = 0 then 'aussch = 0' else 'aussch > 0' end,
       anz = count(*)
from ifas..ASF a
join ifas..INV i on i.WFS_WKN = a.WFS_WKN
where i.KAG < 10000
  and a.aussch_status = 'A'
  and isnull(a.ausschuettung, -1) >= 0
  and (a.r_faktor is null or a.r_faktor <= 0)
group by case when a.ausschuettung = 0 then 'aussch = 0' else 'aussch > 0' end;

+------------+-----+
| typ        | anz |
+------------+-----+
| aussch > 0 | 706 |
| aussch = 0 | 106 |
+------------+-----+

2 Zeile(n) zurückgegeben
