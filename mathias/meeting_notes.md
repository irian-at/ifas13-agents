## todo - user session caching for lieferanten?

## todo - ask fachgruppe - show inactive lieferanten in dropdowns??


## todo - zeitliches ablaufdiagramm das zusammenspiel zwischen
preisfile lieferungen, sammellauf 1 und 2, und ausschuettungsjobs zeigt.
sammellauf 1 muss VOR ausschuettungsjob 3 stattfinden.

tagesjob soll nach sammellauf 1 stattfinden. sollte automatisch laufen.

sammellauf 2 kann dann erst im ausschuettungsjob 1 vom nächsten tag enthalten sein.
die sammellauf berechnungen sind wichtig für die berichtigten preise


## todo - lieferId oekb vs db_oekbtest01 ?? welche validierungen werden für oekb nicht gemacht
"oekb"-lieferant in konstante ziehen und usages checken. 
db_oekbtest01 ist ein echter test lieferant mit isins und journal account, mft account...
soll nicht mit oekb verwechselt werden!
oekb kennzeichnet eigentlich einen internen test run. (keine daten auf mft, kein journal eintrag, aber daten im archiv)
überlegung ob wir das in zukunft über ein flag machen.
oekb soll in prod nicht als lieferant ausgewählt werden können. (fällt weg wenn wir flag einführen)


## feedback:
1) zu job 6 - wozu ein vollständigkeits trigger. job darf in jedem fall starten. die Fehlmeldung darf erst am 
   Ende des Tages, bzw. zu einem definierten Zeitunkt für einen gesamten Tag erstellt werden. Alles was bis zB 17:00
   nicht geliefert wurde gilt als fehlt, und führt zu dem Ergebnis in (b).
2) Es gibt angeblich immer nur genau einen lieferanten der preise für eine isin liefern darf. ob das abgesichert ist
   bin ich nicht sicher.. Wir können die Daten diesbezüglich analysieren wenn du mir die queries für sybase dafür gibst.
3) Dann ist aber das Diagramm irreführend wenn job 4 und 5 je preisfile laufen. warum hängen dan job 2 und 3 dazwischen. 
   Und braucht es für 4 und 5 überhaupt eigene jobs. oder sind das eher workqueue items unter einem job. und der status spiegelt wieder
   was bereits erledigt wurde. 
4) published_lauf passt dann als name nicht mehr. denn die veröffentlichung passiert ja bereits in job 4. der tageslauf erstellt
   ja quasi nur ein protokoll/report.




## fragen zum neuen plan:
1) was ist Job 6? was ist das ergebnis?
2) generelle fragen zu job 4 und 5 - werden die pro preisfile erstellt? sie sollen ja nicht mehr
   gebatched ablaufen. können wir das auch über einen status am job abdecken?
   also preisfile importieren, preise in tmp_if_last schreiben, und nach kurs syncen, 
   dann betroffene kennzahlen neu berechnen




## neuer input von markus: 1.9.2026
1) gut wäre preisfiles sofort zu verarbeiten. ohne batch. manuell getriggerter Tagesjob im Altsystem ist mühsam.
2) Nur die Sammelreports sollen 2 Mal stattfinden. 1. Lauf hält Zwischenstand. 2. Lauf hält nur noch Delta. Was danach kommt am nächsten tag im 1. Lauf.
3) Es soll in den Sammelreports transparent sein was alles geliefert wurde. zB (New, Delete, New...)
4) Es gibt eine Tabelle wo steht welcher Lieferant für welche Isins Preise liefern muss. Sobald er alles geliefert hat könnte man den Report bereits erstellen.
   Wenn am Ende des Tages/ zu einem bestimmten Zeitpunkt noch etwas fehlt, sollte man dafür eine Benachrichtigung bekommen. (entweder FAchabteilung oder Lieferant)
   ZB. Mail an Lieferant: "Preis für Isins XYZ fehlt."
5) Der aktuelle Tagesjob muss manuell von der Fachabteilung gestartet werden, sobald alle Preise geliefert wurden. Das ist sehr mühsam. Er berechnet
   die Kennzahlen und erstellt diverse Stammdaten Files und anderes. Das sollte in Zukunft automatisch passieren. Alles was zu einem bestimmten Zeitpunkt
   vorhanden ist wird verarbeitet, der Rest am nächsten Tag.
6) Derzeit wartet der Tagesjob auf Referenzkurse der EZB die aber erst aum 16:00? geliefert werden. Das sollte in Zukunft anders sein. Evtl die Referenzkurse vom
   Vortag verwenden. (muss noch recherchiert werden was es damit überhaupt auf sich hat.)
7) Es muss weiterhin möglich sein für einen beendeten Fonds einen Preis zu liefern, sofern das Datum für den Preis, vor dem Fondsende liegt.
8) betrifft Ausschuettungen. Wenn eine Ausschuettung für eine Isin ohne vorhandenen Preis gemeldet wird, soll es eine Meldung geben.
9) Es gibt im Tagesjob Log eine Diff für die Kurse zwischen Tagen. Inkl. Plausi. Die Differenz zwischen den Tagen wird im Log angegeben.
   Das ist in Zukunft nicht mehr notwendig, da ohnehin die Aussagekraft sehr beschränkt ist..


## Preisfiles

PREIS_ prefix für alle .csv files.
fondspreis job -> verarbeiten file im job   -> hat status neues preisfile zB -> dann wird antwortfile erzeugt -> nächster status - warten auf batchjob 

1) file kommt an -> legen preismeldung job an -> mit pending und submitted
2) wird verarbeitet -> return files werden erzeugt (data.log, validierung anwerfen) 
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

