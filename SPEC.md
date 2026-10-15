# MacParityXL – Feature-Spec (Nachbau von MacPAR deLuxe 5.1.1)

Quelle: Analyse von `/Volumes/MacPAR deLuxe/MacPAR deLuxe.app` (Bundle, Info.plist, Help-HTML,
Localizable.strings, dekodierte NIBs, Obj-C-Klassen/Methoden-Symbole). Ziel ist ein eigener,
moderner Nachbau mit eigenem Code, eigenen Texten und eigenen Icons – keine Assets übernehmen.

## 1. Architektur des Originals

| Teil | Original | Bemerkung |
|---|---|---|
| UI | Cocoa / Obj-C, NSDocument-basiert, x86_64, macOS 10.9+ | Klassen `MyDocument` → `PAR1Document`, `PAR2Document`, `UnrarDocument` |
| PAR2-Engine | `Helpers/par2SL` – Fork von par2cmdline (GPL v2), mit GCD | Wird als Subprozess gestartet, **stdout zeilenweise geparst** |
| PAR1-Engine | `Helpers/par` – parchive par-cmdline (GPL) | ebenso Subprozess |
| Unrar | `Frameworks/libUnrar.dylib` (RARLAB unrar-Quellen) | In-Process über `MPDUnrarLibGlue`, eigene Queue |
| Post-Processing | Regeln (NSCoding, in Defaults) → Finder öffnen / App öffnen / Terminal-Skript per AppleScript | |
| Sonstiges | Crashlytics, Update-Check, Spenden-Reminder | **Nicht nachbauen** |

Datenfluss PAR2-Repair: Dokument öffnen → `par2 r <file.par2>` starten → stdout-Parser
(`Loading "…"`, `Target: "…" - found / damaged / missing / NOT FOUND`, `… found N data blocks`,
`Repair is possible.`, `You need N more recovery blocks to be able to repair.`, `Repairing: …`)
→ `FileStatus` je Datei aktualisieren → Statistik/Statuszeile → Post-Processing (Unrar etc.)
→ optional Auto-Delete der PAR-Dateien → optional Fenster schließen.

## 2. Dokumenttypen

| Typ | Extension | Rolle | Klasse |
|---|---|---|---|
| PAR1-Set | `.par` (auch `.p01…` über Menü) | Editor | PAR1Document |
| PAR2-Set | `.par2` | Editor | PAR2Document |
| RAR-Archiv | `.rar` | Viewer | UnrarDocument |
| Beliebig | `*` | Viewer | MyDocument |

Beim Start ohne Datei: leeres „Untitled“-Dokument vom Default-Typ (PAR2, einstellbar).

## 3. Funktionen

### 3.1 Verify & Repair (PAR2, PAR1)
- Öffnen per Doppelklick / „Open and Repair…“ (⌘O) / Drop auf Dock-Icon → startet **automatisch**.
- Fenster während Lauf nicht schließbar; Abbruch per „Cancel Operation“ (⌘.) / Toolbar.
- Nicht genug Blöcke → Meldung „need N more blocks / bytes“; „Repair Again“ (⌘R) nach
  Nachladen. Bereits geprüfte OK-Dateien werden beim nächsten Lauf übersprungen, solange
  das Fenster offen bleibt.
- Vor Start: Schreibrecht im Ordner prüfen; Warnung, wenn Ordner viele unbeteiligte Dateien
  enthält (Proceed / Proceed and don't ask again / Cancel).
- PAR2: Erkennung falsch kodierter Dateinamen (Encoding-Auswahl-Dialog, `EncodingSelection.nib`).
- PAR1: Dateien, die nicht zur Parität beitragen („non-recoverable“) werden unterstützt.

### 3.2 PAR-Set erzeugen
- Neues PAR1-Set (⌘N, Variante) / PAR2-Set (⌘N); Dateien per Drag&Drop oder „Add Files…“ (⇧⌘F);
  „Remove“.
- Alle Dateien müssen im selben Ordner liegen; Limits: PAR1 ≤ 255, PAR2 ≤ 32768 Dateien.
- „Create PAR Set…“ (⇧⌘S): Save-Panel mit Zusatzfeld *Anzahl Pnn* (PAR1, 0–99) bzw.
  *Redundanz %* (PAR2, 1–100); Dateiname-Vorschlag aus gemeinsamem Basisnamen.
- Abgebrochene Erzeugung kann ohne Neuanlage neu gestartet werden; verwaiste Pnn-Dateien werden entfernt.

### 3.3 Unrar
- „Unrar Archive…“ (⌘U), Drop von `.rar` aufs App-Icon, oder automatisch nach PAR-Check.
- Formate: `.rar` + `.r00…`, `.partNN.rar`, `.exe`/`.partNN.exe` (SFX), `.001…`; RAR 2.x–5.
- Mehrere Top-Level-Items → Zielordner mit Archivname; ein Item → kein Wrapper-Ordner.
- Ziel existiert: Dialog Overwrite / Keep Both (bestehendes umbenennen) / Cancel.
- Passwortgeschützt: ein Passwort pro Archiv (Dialog).
- Fortschrittsfenster (aktuelle Datei, Fortschrittsbalken, Cancel).
- Ergebnis als User-Notification (Erfolg/Fehler); Klick → im Finder zeigen.
- Danach Segmente: liegen lassen / in Papierkorb (Default) / endgültig löschen (mit Warnung).

### 3.4 Post-Processing-Regeln
- Liste von Regeln, oben nach unten ausgewertet, erste passende gewinnt, einmal pro Set.
- Regel: Beschreibung; Bedingung „Dateiname *ends with* / *contains* X“ (Ignore case);
  Aktion: *Open in Finder* | *Open with App…* | *Command line* (läuft im Terminal).
- Makros für Command line: `«F»` voller Pfad, `«E»` voller Pfad ohne Ext., `«L»` Dateiname,
  `«K»` Dateiname ohne Ext., `«A»` Dateiname ohne passenden Teil, `«D»` Verzeichnis.
- Letzte Regel fix: „Built-in Unrar“. Buttons: New, Modify, Delete, ↑, ↓, Standard.
- Standardregeln: `.rar` → Built-in Unrar; `.zip` → Archive Utility; (`.sit*` → StuffIt – heute obsolet).
- Manuell auslösbar: Menü Process → „Apply Rule“.

### 3.5 Warteschlange
- Mehrere geöffnete Dokumente: *one by one* (Default, exklusive Queue) oder *simultaneously*.
- Status „Waiting to start PAR check…“ / „Waiting to start Unrar…“.

## 4. Hauptfenster (PAR-Dokument)
- Titel = Dateiname (Typ PAR1/PAR2 erkennbar), 600×500, min 600×422.
- Toolbar (anpassbar): New, Open+Repair, Add, Remove, Create par1/par2, Repair again, Cancel,
  Preferences, Help.
- Tabelle: Spalten **• (Status-Icon)**, **File**, **Status**; Finder-Sortierung (natural sort);
  Alternating rows; Mehrfachauswahl; Copy (Dateinamen), „Select All Non-OK“ (⌥⌘A).
- Statistik unten:
  - PAR1: Good files / Corrupt files / Missing files / Pnn files.
  - PAR2: Total / Good · Need N blocks = M bytes.
- Statuszeile (grün bei Erfolg, rot bei Fehler).
- Ausklappbarer Bereich (früher Drawer) mit Roh-Output von `par` („Show "par" Output“).

### Datei-Status (`FileStatus`)
OK · Invalid checksum · OK after renaming file 'X' · Missing · Missing, but can be recovered ·
Missing and cannot be recovered · Invalid checksum, but can be recovered · Invalid checksum and
cannot be recovered · Recovered successfully · Not in PAR file yet.
Icons: OK, recoverable, possible error, error, not in volume set.

### Pnn/Recovery-Datei-Status
Valid Pnn file · Contains no recovery blocks · Contains duplicate recovery blocks ·
Contains N recovery block(s) · Contains N block(s) from file 'X'.

### Dokument-Status
Verifying… · Restoring… · Canceled · Cannot restore; need N more files/blocks · All files checked out
fine (; renamed) · Files restored successfully (; renamed) · PAR file not valid · Generating… ·
PAR files generated successfully · Only non-recoverable files missing · Internal error · Waiting….

## 5. Einstellungen
- **Basic:** Auto delete par files · Close window after auto post-processing · Default document type
  (par1/par2) · Run unattended (keine Dialoge; sichere Defaults: Keep both, leeres Passwort; Fehler als Notification).
- **Par1:** Anzahl Pnn: „One for every N files“ oder fest N.
- **Par2:** Redundanz % (Default 10) · Limit par2 file size to match largest data file · Block size
  Automatic oder N KB.
- **Unrar:** Keep broken files · Ziel: neben Archiv / immer fragen / fester Ordner ·
  Ziel existiert: Ask / Overwrite / Keep both / Cancel · Nach Erfolg: Leave / Trash / Delete.
- **Post-processing:** Auto post-process + Regel-Editor (3.4).
- **Other:** Multiple files: one by one / simultaneously · (CPU-Kern-Limit für par2).

## 6. Menüs
(Modifier bei ⌥⌘N / ⌥⌘A nicht aus NIB lesbar, nur Taste – vermutet.)
- **App:** About, Preferences… (⌘,), Services, Hide/Hide Others/Show All, Quit (während Lauf deaktiviert).
- **File:** New PAR 2 Set (⌘N), New PAR 1 Set (⌥⌘N), Open and Repair… (⌘O), Close (⌘W),
  Close All (⌥⌘W), Create PAR Set… (⇧⌘S).
- **Edit:** Cut/Copy/Paste/Clear/Select All, Select All Non-OK, Add Files… (⇧⌘F), Remove,
  Repair Again (⌘R), Cancel Operation (⌘.).
- **Process:** Unrar Archive… (⌘U), Apply Rule, Show/Hide "par" Output.
- **Window:** Minimize (⌘M), Hide/Customize Toolbar.
- **Help:** Hilfe (⌘?).

## 7. Bewusst weglassen / modernisieren
- Crashlytics/Fabric, Spenden-Reminder, eigener Update-Check (ggf. Sparkle), E-Mail-Support-Button.
- Resource-Fork-Prüfung (irrelevant), StuffIt-Regeln.
- Drawer → Inspector/Split-View; Carbon-APIs weg; Universal Binary (arm64 + x86_64).

## 8. Entscheidungen (2026-10-15)
1. **PAR2-Engine:** par2cmdline-turbo 1.5.0, gebündelt als separates Executable (Subprozess, stdout-Parser).
   Als getrenntes Programm ist es nur „aggregiert“; die App selbst muss nicht GPL sein, die par2-Quellen müssen aber mitgeliefert/verlinkt werden.
2. **UI:** SwiftUI, AppKit wo nötig (Toolbar, Save-Panel-Accessory, NSDocument-Details).
3. **Umfang v1:** vollständig inkl. PAR1 (Engine: par-cmdline, GPL).
4. **RAR-Backend:** RARLAB UnRAR 7.3.1 als statische Bibliothek (Lizenz: nur Entpacken; nicht GPL-kompatibel,
   deshalb darf die App selbst nicht unter GPL stehen, wenn sie libunrar linkt).
5. **PAR1:** eigene Swift-Implementierung in ParityKit (`Par1/`: GF(2^8), Polynom 0x11D, Header/Kontroll-Hash,
   Verify/Repair/Create). par-cmdline 1.1 dient nur als Test-Orakel (Kompatibilität in beide Richtungen geprüft),
   wird nicht ausgeliefert.
