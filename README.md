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
- Python **3.13** mit der [pymammotion](https://github.com/mikey0000/PyMammotion) Bibliothek (empfohlen: **≥ 0.7.117**, siehe Hinweis unten)
- Mammotion Cloud-Account (E-Mail + Passwort)

### Python-Abhängigkeiten installieren

```
pip3 install pymammotion
```

### Hinweis zur pymammotion-Version

Mammotion und pymammotion ändern ihre Cloud-/Geräte-API regelmäßig. Das Modul
unterstützt sowohl die **alte** API (`pymammotion.mammotion.devices.mammotion`,
bis ca. 0.7.82) als auch die **neue** API (`pymammotion.client.MammotionClient`,
ab ca. 0.7.117) und erkennt automatisch, welche installiert ist.

Für das **zonengenaue Starten** (`start_zone`) wird die neue API empfohlen, da
nur sie die `MowPathSaga` (Routenberechnung + Bestätigung der Mähbahn) enthält.
Mit der alten API funktioniert `start_zone` nur eingeschränkt.

Installierte Version prüfen bzw. aktualisieren:

```
pip3 show pymammotion | grep -i version
pip3 install --upgrade pymammotion
# oder eine bestimmte Version:
pip3 install pymammotion==0.7.133
```

> **Wichtig:** pip3 für **das gleiche** Python verwenden, das auch FHEM nutzt
> (Attribut `python_bin`, Standard `/usr/bin/python3.13`). In FHEM lässt sich die
> aktiv genutzte Version mit `{qx(pip3 show pymammotion | grep -i version)}`
> prüfen.

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
| `disable` | Modul deaktivieren (1 = deaktiviert, 0 = aktiv). Stoppt alle Timer und blockiert `set`/`get`-Befehle. | `0` |
| `interval` | Polling-Intervall in Sekunden | `300` |
| `python_bin` | Pfad zum Python-Interpreter | `/usr/bin/python3.13` |
| `helper_script` | Pfad zum Python-Hilfsskript | `/opt/fhem/FHEM/mammotion_helper.py` |
| `app_version` | Optionaler App-Version-Header für den Mammotion-Login. Siehe Fehlerbehebung. | _(leer)_ |
| `legacy_login` | `1` = älteren Login-Weg (`/oauth/token`) statt `login_v2` nutzen. Siehe Fehlerbehebung. | `0` |

### Login-Attribute `app_version` und `legacy_login`

Diese beiden Attribute sind nur nötig, wenn der Login scheitert – im Normalfall
bleiben sie leer.

- **`app_version`** – Mammotion lehnt veraltete App-Versionen ab; der Login
  scheitert dann mit `Attempt to decode JSON with unexpected mimetype`. In dem
  Fall hier eine aktuelle App-Version setzen, z.B.:

  ```
  attr Yuka app_version 2.3.4.22
  ```

  (Je nach pymammotion-Version werden auch Formate wie `Home Assistant,2.3.4.22`
  oder `NOT HA,2.3.4.22` akzeptiert.)

- **`legacy_login`** – Steuert den Cloud-Login für Befehle/Status. Bei `1` wird
  statt `login_v2` (`/oauth2/token`) der ältere `login` (`/oauth/token`)
  verwendet und der `authorization_code` separat nachgeladen. Hilft, wenn der
  Login mit `Account or password mismatch` scheitert, obwohl die Zugangsdaten
  korrekt sind (die Geräteliste mit `get devices` also funktioniert). Das betrifft
  vor allem **geteilte / Zweit-Accounts**.

  ```
  attr Yuka legacy_login 1
  ```

### Modul deaktivieren und wieder aktivieren

```
# Modul deaktivieren (stoppt Polling, blockiert set/get)
attr Yuka disable 1

# Modul wieder aktivieren (startet Polling nach 30 Sekunden)
attr Yuka disable 0
```

Wenn `disable 1` gesetzt ist:
- Alle laufenden `InternalTimer` werden entfernt.
- Laufende BlockingCall-Prozesse werden sauber beendet und das `RUNNING`-Flag zurückgesetzt.
- `set`- und `get`-Befehle werden mit einer Fehlermeldung blockiert.
- Das Reading `state` wird auf `disabled` gesetzt.

Wird `disable` auf `0` zurückgesetzt oder das Attribut gelöscht, startet das Polling automatisch nach 30 Sekunden neu.

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

## Fehlerbehebung

Die Fehlermeldung steht jeweils im Reading `last_error`. Mit `attr Yuka verbose 5`
landen zusätzlich die Python-Meldungen (inkl. `mammotion_helper version …`) im
FHEM-Log – hilfreich, um zu sehen, welche Helper-Version tatsächlich läuft.

### Login scheitert mit „unexpected mimetype"

```
Login fehlgeschlagen: ... Attempt to decode JSON with unexpected mimetype
```

Mammotion lehnt die (veraltete) App-Version ab. Lösung: Attribut `app_version`
setzen, z.B. `attr Yuka app_version 2.3.4.22`.

### „Account or password mismatch", obwohl `get devices` funktioniert

Tritt typischerweise bei **geteilten / Zweit-Accounts** auf: Die Geräteliste lässt
sich abrufen, aber Befehle/Status scheitern, weil `login_v2` solche Konten
ablehnt. Lösung: `attr Yuka legacy_login 1`.

### „unknown parameter ha_version"

Eine ältere/abweichende pymammotion-Version kennt den `ha_version`-Parameter
nicht. Das Modul fängt das ab und setzt den App-Version-Header direkt – sollte die
Meldung dennoch auftreten, Helper aktualisieren (`update all`) und pymammotion auf
eine aktuelle Version bringen.

### „No module named pymammotion.client"

Es ist die **alte** pymammotion-API installiert. Das Modul funktioniert damit,
für `start_zone` wird aber die neue API empfohlen – pymammotion aktualisieren
(siehe [Hinweis zur pymammotion-Version](#hinweis-zur-pymammotion-version)).

### Befehl wird quittiert, aber der Mäher reagiert nicht / fährt nicht los

Mehrere mögliche Ursachen, die in aktuellen Versionen bereits behoben sind:

- **Kommando wurde nie zugestellt** (behoben in 1.7.10): Der Helper hat den
  MQTT-Publish abgesetzt und den Prozess sofort hart beendet, bevor die Nachricht
  über die Leitung ging. Seitdem wartet der Helper nach jedem Kommando kurz, damit
  der Publish den Broker erreicht.
- **`start_zone` plant, fährt aber nicht** (behoben in 1.7.9 / 1.7.11): Damit der
  Mäher wirklich losfährt, muss erst die Mähbahn berechnet **und bestätigt**
  werden (`MowPathSaga`), bevor `start_job` gesendet wird. Bei geteilten Konten
  kann die Saga mit `identityId is blank (29003)` abbrechen; das Modul wiederholt
  sie dann automatisch auf der neu aufgebauten Cloud-Session.

Wenn `start_zone` trotzdem nicht losfährt, mit `verbose 5` prüfen, ob
`start_zone: MowPathSaga erfolgreich` im Log steht. Erscheint stattdessen
mehrfach `… Versuch N fehlgeschlagen`, ist die neue pymammotion-API vermutlich
nicht installiert oder das Konto darf das Gerät nicht steuern.

### Zeitüberschreitung bei `get zones`

Das Abrufen der Zonen kann dauern, wenn der Mäher gerade lädt oder schläft. Am
besten abrufen, während der Mäher aktiv/erreichbar ist. Das Modul liefert die
Zonen-Namen aus, sobald sie stabil vorliegen, und beendet hängende Prozesse über
einen Watchdog selbstständig.

## Versionshistorie

| Version | Datum | Änderung |
|---|---|---|
| 1.7.11 | 2026-06-04 | `start_zone`: `MowPathSaga` wird bei Cloud-Session-Fehler (`29003 identityId is blank`) automatisch wiederholt; `start_job` nur nach erfolgreicher Saga |
| 1.7.10 | 2026-06-03 | Kommandos (`leave_dock`, `start_zone` u.a.) werden vor dem Prozess-Exit zugestellt (MQTT-Publish wird geflusht) |
| 1.7.9 | 2026-06-03 | `start_zone` nutzt die korrekte App-Sequenz (MowPathSaga + `start_job`) |
| 1.7.x | 2026-06-03 | Robustes `get_zones` (Watchdog-Thread, Auslieferung der Zonen-Namen); fire-and-forget-Tasks sauber abgeräumt |
| 1.6.x | 2026-06-03 | Automatische Erkennung alte/neue pymammotion-API; Attribut `legacy_login` für geteilte Konten |
| 1.5.x | 2026-06-03 | Attribut `app_version`; Login-Fehler werden kontrolliert in `last_error` gemeldet (kein Absturz mehr) |
| 1.4.0 | 2026-04-12 | Neues Attribut `disable` zum Deaktivieren des Moduls (stoppt Timer, blockiert set/get, setzt state auf `disabled`) |
| 1.3.0 | 2026-04-10 | Watchdog-Timer für hängende Prozesse; Aufgaben (Tasks/Pläne) via `get_tasks` und `start_task` |
| 1.2.0 | 2026-04-10 | Dynamische Dropdowns für Zonen und Aufgaben im FHEM-Frontend |
| 1.1.0 | 2026-04-10 | `get_status` automatisch nach Geräte-Update; Arbeitsstatus-Texte |
| 1.0.0 | 2026-04-10 | Initiale Version mit Zonen-Unterstützung |

## Lizenz

Dieses Modul ist ein Community-Beitrag und steht unter der [GNU General Public License v2](https://www.gnu.org/licenses/gpl-2.0.html), entsprechend der FHEM-Lizenz.
