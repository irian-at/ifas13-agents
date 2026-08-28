
todo - write offSetDateTime, localDateTime, zonedDateTime to sybase
read values - should be same instant for all 3


## Preisfiles

PREIS_ prefix für alle .csv files.

fondspreis job -> verarbeiten file im job   -> hat status neues preisfile zB -> dann wird antwortfile erzeugt -> nächster status - warten auf batchjob 
1) legen preismeldung job an -> mit pending und submitted
2) wird verarbeitet -> return return files werden erzeugt (data.log, validierung anwerfen) 
   -> gespeichert im job und committed -> job geht auf status ready_for_batch
3) 14:00 job holt sich alle im ready_for_batch (werden neuerlich validiert, im speicher gesammelt,  und fplausib, und fondspreisfiles erzeugt)
4) -> wenn alle jobs verarbeit -> tmp_if_last aktualisieren (entw. löschen oder updaten..)

5) - ensure stammdaten validation does not impact result - what if it runs in batch again later - will we have same result?


entities: fondspreis job, statistics pro lieferung, letzter_kurs (tmp_if_last), kurs (kurs) 

(eventuell neue detail table fondpreisJobKurse für die einzelnen preise eines jobs, aber das nur wenn wir es wirklich brauchen)


lösch sätze löschen derzeit nur aus der tmp_if_kurs table

data.log -> result file für import (wird das gebraucht? -> fa fragen)
was passiert wenn 1 zeile ungültig -> wird rest importiert? -> alles ohne fehler wird importiert!

fondspreise tabelle neu. -> linkt auf job, muss timestamp haben

alle preisdaten werden in tmp_if_kurs gesammelt

->fplausib.txt wird geschrieben für die fachabteilung (sammlung aller)

-> letzter aktueller preis ist in tmp_if_last

-> wird dann in kurs gesynced

- zukünftiger 2. lauf soll alles nochmal durchgehen.



# error zusammensetzung kontrollieren
# REST schnittstelle dass wir die isin listen auch behandeln 

steuermeldungen:
-> alle anderen .csv files - könnte ja erste zeile falsch sein, aber der rest korrekt...

## todo - rest interface für ESTB report - NUr POST für isin-list
## todo Manfred - DbErmittlungsvorgabe

# grossfile test:

# a) export isins
# 1) alstsystem grossfile 1 test mit -T parameter (so wird nichts persistiert)
# 2) neusystem grossfile 1 einspielen und mit ergebnissen aus 1 vergleichen
# b) export isins
# 3) altsystem grossfile 1 ohne -T parameter
# 4) neusystem grossfile 2 einspielen



Ausschüttungen aus dem FINAL file werden für die Kennzahlen Berechnung verwendet.
FMOC - fonds melde online client

