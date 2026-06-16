
preis files:

PREIS_ prefix für alle .csv files.

steuermeldungen:
-> alle anderen .csv files - könnte ja erste zeile falsch sein, aber der rest korrekt...


ZUSAMMENFASSUNG - gf1
================================================================================
Gesamt Validierungen im Altsystem: 328
Gesamt Validierungen im Neusystem: 344
Exakte Treffer      : 315
Abweichende Treffer : 2
Abgedeckte Treffer  : 8
Nur im Altsystem    : 3
Nur im Neusystem (Fehler)  : 19
Nur im Neusystem (Warnung) : 0
================================================================================


ZUSAMMENFASSUNG - gf2
================================================================================
Gesamt Validierungen im Altsystem: 98
Gesamt Validierungen im Neusystem: 99
Exakte Treffer      : 93
Abweichende Treffer : 0
Abgedeckte Treffer  : 0
Nur im Altsystem    : 5
Nur im Neusystem (Fehler)  : 6
Nur im Neusystem (Warnung) : 0
================================================================================


# Schreiben wir in Ifas neu schon geschäftsjahre in die tabelle? - wenn ja in welche? sollte in postgres sein..
# wir brauchen eine rest schnittstelle für die berechnung von geschaeftsjahren.. (1 oder mehrere, oder alle) 

# FA ändert manuell geschäftsjahre in der tabelle - ludwig lest von der tabelle für fristenprüfung mit skripts
# deshalb brauchen wir die Schnittstelle - aber wenn die fristenprüfung sowieso eine neuberechnung der geschäftsjahre
# und fristen triggert, können wir und die schnittstelle evtl sparen. (bin nicht sicher)

# brauchen wir überhaupt eine eigene Event-Log Tabelle - oder weiß der Job (zB estb-report 1,2,3) wann der letzte 
# erfolgreiche Job gestartet wurde?


## todo - rest interface für ESTB report - NUr POST für isin-list
## todo Manfred - DbErmittlungsvorgabe


## todo - ask andi
# Meldezyklus - STM Anwendungsfälle im confluence ansehen
https://confluence.oekb.co.at/spaces/IFASIF/pages/151519594/STM+Anwendungsf%C3%A4lle

-> plausibilitätsprüfungen seite im Confluence -> delete/confirm/update...


# grossfile test:
# 1) alstsystem grossfile 1 test mit -T parameter (so wird nichts persistiert)
# 2) neusystem grossfile 1 einspielen und mit ergebnissen aus 1 vergleichen
# 3) altsystem grossfile 1 ohne -T parameter
# 4) neusystem grossfile 2 einspielen




Ausschüttungen aus dem FINAL file werden für die Kennzahlen Berechnung verwendet.

FMOC - fonds melde online client

