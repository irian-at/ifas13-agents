## todo - discuss with manfred - why did he change jeAnteil logic to use fieldCategory instead of fieldName??



## todo - Wunsch der FAchabteilung
# Tagesprotokoll auswertung - alle Fehler zusammen (ohne positive Rückmeldungen - zB keine Differenzen..)
# Alle Meldungen zu einem Tag 
# Wenn 2800 STM eintreffen ist das zuviel..

Klasse für von-bis rekalkulationen lesen - anzahl fehler u warnings - 
create service in service layer - read recalc jobs from bis (created_at) timestamp
extractProtocolFromBundleResult - fetch protocol from bundle result



# grossfile test:
# 1) alstsystem grossfile 1 test mit -T parameter (so wird nichts persistiert)
# 2) neusystem grossfile 1 einspielen und mit ergebnissen aus 1 vergleichen
# 3) altsystem grossfile 1 ohne -T parameter
# 4) neusystem grossfile 2 einspielen





# Schreiben wir in Ifas neu schon geschäftsjahre in die tabelle? - wenn ja in welche? sollte in postgres sein..
# wir brauchen eine rest schnittstelle für die berechnung von geschaeftsjahren.. (1 oder mehrere, oder alle) 

# FA ändert manuell geschäftsjahre in der tabelle - ludwig lest von der tabelle für fristenprüfung mit skripts
# deshalb brauchen wir die Schnittstelle - aber wenn die fristenprüfung sowieso eine neuberechnung der geschäftsjahre
# und fristen triggert, können wir und die schnittstelle evtl sparen. (bin nicht sicher)

# brauchen wir überhaupt eine eigene Event-Log Tabelle - oder weiß der Job (zB estb-report 1,2,3) wann der letzte 
# erfolgreiche Job gestartet wurde?

# Parallelbetrieb ab Ende Mai? - was brauchen wir noch unbedingt? 




## todo - rest interface für ESTB report - NUr POST für isin-list
## todo Manfred - DbErmittlungsvorgabe


## done - grossfile test fixen mit zips only
# done Manfred - ausschuettung_e - letzte spalte fehlt je anteil
# done - allow No ermittlungsvorgabe found for version 3 - add setting to UI -
# done - isin ISIN , detail layout same as recalcs - UI
# done - datumsformat - YYYY.MM.DD beim rausschreiben  create jira!
# done - selbstnachweis - default = NEIN wenn nicht befüllt - done  create jira!
# done alle default werte sollen beim einlesen bereits gesetzt werden - done  create jira!
# done e satz hat keinen filler - weg damit - create jira!
# done end satz - fehlt isin und timestamp (fehlen beim einlesen..)




## analyze:
wfs_wkn: 109417
dep_bank=20100
vertreter=depBank 1050

/**
* INFO_KONTROLL_9 - Versions: 4,5,6 (replaces ERR_KONTROLL_9 since 20.11.2019).
* <p>Condition: Ausschuettung_e >= Ertraege_Ausschuettung_keineJahresmeldung_KontrollsummeOeKB</p>
* previously ERR_KONTROLL_9 (deprecated since 20.11.2019, replaced by INFO_KONTROLL_9).
*/
check ob rundung in cpp für vergleich passiert - auf wieviele NK checkt andi

ausschuettungE
273468.0766
ertraegeAusschuettungKeineJahresmeldungKontrollsummeOeKB
273468.0767000000000000000000000000

STM Isin Anforderungsliste

=IF(
Jahresdaten_e="JA",0,
Ergebnis_ordentlich_KV_inklEA_nachAbzugSteuern_nachAufwandundErtrag_nachVerlustverrechnung+   273468.0767000000000000000000000000
ImmoInvF_Jahresgewinn_Para14Abs2Z1uZ2+  0
AIF_Ergebnis_inklEA_nachAufwand-  0
AIF_Summe_Personensteuern_AIF   0
)


=Summe_KV_nach_Aufw_Verl-IF(Saldierte_Substanzgewinne_Verluste_inklEA_Nach_KV_uebrige_Aufw_Aufwuebh_Verl>0,Saldierte_Substanzgewinne_Verluste_inklEA_Nach_KV_uebrige_Aufw_Aufwuebh_Verl,0)
-(SummeDividenden_QuStKESt+SummeZinsen_QuStKESt+SummeZinsenAltemissionen_QuStKESt+SummeAusschuettungenSubfonds_QuStKESt)
+Rueckerstattete_auslQuSt_Vorjahre_e+Rueckerstattete_auslQuSt_Vorjahre_nicht_anrechenbar_dargestellt_e
-IF(FLAG3_alle_KV_Ertragskomponenten_negativ=0,Verlustvortrag_e,0)

## TODO - INFO vs OEKB-INFO - where is definition / spec?

## todo - what if same isin multiple times in same csv?
## ERR_GJ_MELDE_BEGINN - darf nicht nach dem Meldezeitraum-Beginn  <>
## TODO - specify which records are allowed for which status e.g. _DECLINED..

## todo - ask andi
# Meldezyklus - STM Anwendungsfälle im confluence ansehen
https://confluence.oekb.co.at/spaces/IFASIF/pages/151519594/STM+Anwendungsf%C3%A4lle

-> plausibilitätsprüfungen seite im Confluence -> delete/confirm/update...



Ausschüttungen aus dem FINAL file werden für die Kennzahlen Berechnung verwendet.

FMOC - fonds melde online client



// OEKBSD-73393: Neu ab Version 6
// 	INFO_AUSLQST_JA
// 	WENN Abzug_auslQuSt_ausschlgempara48BAO_e = "JA"
//		und SummeDividenden_QuStKESt, SummeZinsen_QuStKESt, SummeZinsenAltemissionen_QuStKESt
//			oder SummeAusschuettungenSubfonds_QuStKESt > 0
// 	DANN Warnung: 'Achtung! Wenn die Ausländische Quellensteuer gemäß § 48 BAO ausschließlich als Aufwand abgezogen wurde,
//		dann müssen SummeDividenden_QuStKESt, SummeZinsen_QuStKESt, SummeZinsenAltemissionen_QuStKESt
//		und SummeAusschuettungenSubfonds_QuStKESt = 0 sein.'
// cBugMsgs.AddMsg(j++, "INFO_AUSLQST_JA",
// "Achtung! Wenn die Auslaendische Quellensteuer gemaesz Par.48 BAO ausschlieszlich als Aufwand abgezogen wurde, dann muss %s <%.4lf> = 0 sein.");


// OEKBSD-73393: INFO_SUBSTANZ_ALTEM
// WENN Substanzgewinn_Altemissionen_inklEA > Substanzgewinn_Summe_inklEA
// DANN Warnung: 'Achtung! Substanzgewinne aus Altemissionen kann nicht größer sein 
//		als die Summe aller Substanzgewinne!'
cBugMsgs.AddMsg(j++, "INFO_SUBSTANZ_ALTEM",
 "Achtung! Substanzgewinne aus Altemissionen <%.4lf> kann nicht groeßer sein als die Summe aller Substanzgewinne <%.4lf>!");