---
name: intellij-git-add
description: Der User staged neue Dateien manuell in IntelliJ — der Git-Index enthält oft schon seine Adds (auch von Claude-erzeugten Dateien).
metadata: 
  node_type: memory
  type: user
  originSessionId: 29d00419-c8e9-488e-8e21-00dd20901780
  modified: 2026-09-02T14:49:26.081Z
---

Der User fügt neue Dateien manuell in IntelliJ zu Git hinzu. Der Index enthält daher häufig
bereits gestagte Einträge, die nicht von Claude stammen — auch Adds von Dateien, die Claude gerade
erst geschrieben hat, und Leichen von umbenannten Dateien (staged-Add + Worktree-Delete, Status
`AD`).

**Why:** Erklärt „mysteriös" vorbefüllte Indizes (2026-09-02 zweimal beobachtet); ohne dieses
Wissen wirkt es wie ein Hook oder Harness-Verhalten.

**How to apply:** Vor einem Commit den Index prüfen statt ihm zu trauen; `AD`-Einträge sind meist
Umbenennungs-Reste und gehören nicht in den Commit. Ein `git reset` verwirft auch seine manuellen
Adds — danach gezielt neu stagen und im Ergebnis-Bericht erwähnen. Die Commit-Regel „If anything
is staged, commit exactly that" gilt nur, wenn das Gestagte zum beauftragten Commit gehört.
