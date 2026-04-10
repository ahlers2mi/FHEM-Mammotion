# FHEM-Mammotion

FHEM-Modul zur Anbindung von Mammotion Rasenmähern (Luba, Yuka u.a.) über die Mammotion Cloud API. Ermöglicht das Steuern des Mähers, Abfragen von Zonen und Aufgaben sowie die Statusüberwachung – direkt aus FHEM heraus.

## Features

- 🌿 Mähvorgang starten, stoppen, pausieren und fortsetzen
- 🏠 Zur Ladestation zurückfahren oder Ladestation verlassen
- 🗺️ Zonen und Aufgaben (Tasks) aus der Mammotion Cloud laden
- 📍 Bestimmte Zone oder Aufgabe per Name oder Hash/ID starten
- 🔄 Automatisches Polling (konfigurierbares Intervall)
- 🔋 Akkustand, Arbeits- und Ladestatus als FHEM-Readings
- 🛡️ Watchdog: hängende Python-Prozesse werden automatisch beendet

## Voraussetzungen

- FHEM-Installation (Perl-basiert)
- Python **3.13** mit der [pymammotion](https://github.com/mikey0000/PyMammotion) Bibliothek
- Mammotion Cloud-Account (E-Mail + Passwort)

### Python-Abhängigkeiten installieren

```
pip3 install pymammotion
```

## Installation

### Erstmalig laden

```
update all https://raw.githubusercontent.com/ahlers2mi/FHEM-Mammotion/main/controls_Mammotion.txt
shutdown restart
```

### Für automatische Updates (zusammen mit `update all`)

```
update add https://raw.githubusercontent.com/ahlers2mi/FHEM-Mammotion/main/controls_Mammotion.txt
```

Danach wird das Modul bei jedem `update all` automatisch mitaktualisiert.

### Manuelle Installation

Die Dateien `98_Mammotion.pm` und `mammotion_helper.py` in das FHEM-Verzeichnis `/opt/fhem/FHEM/` kopieren.

## Einrichtung

### 1. Gerät definieren

```
define Yuka Mammotion meinEmail@beispiel.de MeinPasswort Yuka-ABC123
```

Das dritte Argument ist der Gerätename aus der Mammotion App (optional). Wird er weggelassen, wird das erste gefundene Gerät verwendet.

### 2. Optional: Polling-Intervall anpassen

```
attr Yuka interval 300
```

Standard ist 300 Sekunden (5 Minuten).

### 3. Optional: Python-Pfad anpassen

```
attr Yuka python_bin /usr/bin/python3.13
attr Yuka helper_script /opt/fhem/FHEM/mammotion_helper.py
```

## Verwendung

### Gerät aktualisieren

```
set Yuka update
```

### Mähvorgang steuern

```
set Yuka start
set Yuka stop
set Yuka pause
set Yuka resume
set Yuka return_home
set Yuka leave_dock
set Yuka along_border
```

### Zonen abfragen und starten

```
get Yuka zones
set Yuka start_zone Vorgarten
set Yuka start_zone 12345678
```

Zonen werden per Name oder Hash-ID angesprochen. Nach `get zones` erscheinen sie als Dropdown im FHEM-Frontend.

### Aufgaben abfragen und starten

```
get Yuka tasks
set Yuka start_task MeineAufgabe
```

### Gerät wechseln (bei mehreren Geräten)

```
get Yuka devices
set Yuka selectDevice Luba-XYZ789
```

### Status anzeigen

```
get Yuka status
```

Zeigt Gerätename, Typ, IoT-ID, Akkustand, Arbeits- und Ladestatus sowie verfügbare Zonen und Aufgaben.

## Attribute

| Attribut | Beschreibung | Standard |
|---|---|---|
| `interval` | Polling-Intervall in Sekunden | `300` |
| `python_bin` | Pfad zum Python-Interpreter | `/usr/bin/python3.13` |
| `helper_script` | Pfad zum Python-Hilfsskript | `/opt/fhem/FHEM/mammotion_helper.py` |

## Readings

| Reading | Beschreibung |
|---|---|
| `state` | Aktueller Status (`initialized`, `updating`, `online`, `offline`, `mowing`, `paused`, `returning`, `error`, `timeout`) |
| `battery` | Akkustand in Prozent |
| `work_state` | Arbeitsstatus als Text (z.B. `mäht`, `lädt`, `bereit`) |
| `charge_state` | Ladestatus (`nicht laden`, `laden`, `voll`) |
| `device_name` | Name des aktiven Geräts |
| `device_type` | Gerätetyp |
| `iot_id` | IoT-ID des aktiven Geräts |
| `device_count` | Anzahl gefundener Geräte |
| `zones_count` | Anzahl verfügbarer Zonen |
| `zones_json` | Zonen als JSON (intern genutzt) |
| `tasks_count` | Anzahl verfügbarer Aufgaben |
| `tasks_json` | Aufgaben als JSON (intern genutzt) |
| `last_update` | Zeitstempel des letzten Updates |
| `last_command` | Zuletzt ausgeführter Befehl |
| `last_error` | Letzter Fehler |

## Typischer Workflow

```
# 1. Gerät definieren und einmal aktualisieren
define Yuka Mammotion mein@email.de MeinPasswort Yuka-ABC123
set Yuka update

# 2. Zonen laden und anzeigen
get Yuka zones
get Yuka status

# 3. Zone starten
set Yuka start_zone Vorgarten

# 4. Zur Ladestation zurückschicken
set Yuka return_home
```

## Versionshistorie

| Version | Datum | Änderung |
|---|---|---|
| 1.3.0 | 2026-04-10 | Watchdog-Timer für hängende Prozesse; Aufgaben (Tasks/Pläne) via `get_tasks` und `start_task` |
| 1.2.0 | 2026-04-10 | Dynamische Dropdowns für Zonen und Aufgaben im FHEM-Frontend |
| 1.1.0 | 2026-04-10 | `get_status` automatisch nach Geräte-Update; Arbeitsstatus-Texte |
| 1.0.0 | 2026-04-10 | Initiale Version mit Zonen-Unterstützung |

## Lizenz

Dieses Modul ist ein Community-Beitrag und steht unter der [GNU General Public License v2](https://www.gnu.org/licenses/gpl-2.0.html), entsprechend der FHEM-Lizenz.
