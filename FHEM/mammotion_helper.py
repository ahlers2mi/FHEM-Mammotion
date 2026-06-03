#!/usr/bin/env python3.13
"""
Mammotion Cloud API Helper fuer FHEM
Aufruf: mammotion_helper.py <account> <password> <action> [params...] [--app-version <ver>] [-v]

Optionen:
  --app-version <ver>   App-Version-Header fuer den Login (Default: leer = pymammotion-Default)
  --legacy-login        Cloud-Login ueber den alten login statt login_v2 (bei
                        "Account or password mismatch" trotz korrekter Daten)
  -v / --verbose        Debug-Logging auf stderr

Aktionen (nur HTTP):
  get_devices

Aktionen (MQTT):
  start_mowing     <device_name> <iot_id>
  stop_mowing      <device_name> <iot_id>
  pause_mowing     <device_name> <iot_id>
  resume_mowing    <device_name> <iot_id>
  return_home      <device_name> <iot_id>
  leave_dock       <device_name> <iot_id>
  along_border     <device_name> <iot_id>
  get_zones        <device_name> <iot_id>
  start_zone       <device_name> <iot_id> <zone_hash>
  get_status       <device_name> <iot_id>
  get_tasks        <device_name> <iot_id>
  start_task       <device_name> <iot_id> <plan_id>
"""

import sys
import os
import json
import asyncio
import logging


# Versionskennung des Helpers (wird zu Beginn ins stderr geloggt, damit im
# FHEM-Log sichtbar ist, welche Helper-Datei tatsaechlich ausgefuehrt wird).
HELPER_VERSION = "1.7.4"


# Optionaler Override fuer den App-Version-Header beim Login. Mammotion kann
# veraltete App-Versionen ablehnen (HTTP 200 ohne Token-JSON -> "Attempt to
# decode JSON with unexpected mimetype"). Standard: leer = keine Aenderung,
# es wird die App-Version der installierten pymammotion-Version verwendet.
# Per FHEM-Attribut "app_version" setzbar, z.B. "Home Assistant,2.3.4.22"
# oder "NOT HA,2.3.4.22".
DEFAULT_APP_VERSION = ""


def _patch_app_version(app_version):
    """Setzt den App-Version-Header auf allen MammotionHTTP-Instanzen.

    Wird nachtraeglich auf der Instanz gesetzt, damit es mit jeder
    pymammotion-Version funktioniert. Der Konstruktor-Parameter "ha_version"
    existiert nur in unveroeffentlichten pymammotion-Versionen und wuerde mit
    der PyPI-Version einen TypeError ("unknown parameter ha_version") ausloesen.
    """
    if not app_version:
        return
    from pymammotion.http.http import MammotionHTTP

    # Wert immer aktualisieren; Patch nur einmal installieren.
    MammotionHTTP._fhem_app_version_value = app_version
    if getattr(MammotionHTTP, "_fhem_app_version_patched", False):
        return

    _orig_init = MammotionHTTP.__init__

    def _patched_init(self, *args, **kwargs):
        kwargs.pop("ha_version", None)  # von aelteren Versionen nicht unterstuetzt
        _orig_init(self, *args, **kwargs)
        try:
            self._headers["App-Version"] = MammotionHTTP._fhem_app_version_value
        except Exception:
            pass

    MammotionHTTP.__init__ = _patched_init
    MammotionHTTP._fhem_app_version_patched = True


def _patch_legacy_login():
    """Erzwingt den alten login (/oauth/token) statt login_v2 (/oauth2/token).

    Manche Accounts werden von login_v2 mit "Account or password mismatch"
    abgelehnt, obwohl exakt dieselben Daten beim alten login funktionieren
    (vgl. PyMammotion#137). Wir leiten login_v2 auf den alten login um und
    laden den fuer den Aliyun-IoT-Login noetigen authorization_code
    anschliessend ueber /authorization/code nach.
    """
    from pymammotion.http.http import MammotionHTTP

    if getattr(MammotionHTTP, "_fhem_legacy_login_patched", False):
        return
    if not hasattr(MammotionHTTP, "login"):
        return
    # Methode, die den authorization_code ueber /authorization/code nachlaedt.
    # Heisst je nach pymammotion-Version unterschiedlich.
    authcode_method = None
    for _m in ("refresh_authorization_code", "fetch_authorization_token"):
        if hasattr(MammotionHTTP, _m):
            authcode_method = _m
            break
    if authcode_method is None:
        return

    _orig_login = MammotionHTTP.login

    async def _login_v2_via_legacy(self, account, password):
        resp = await _orig_login(self, account, password)
        if getattr(self, "login_info", None) is not None:
            try:
                await getattr(self, authcode_method)()
            except Exception:
                pass
        return resp

    MammotionHTTP.login_v2 = _login_v2_via_legacy
    MammotionHTTP._fhem_legacy_login_patched = True


async def get_devices(http):
    resp = await http.get_user_device_list()
    if not resp or not resp.data:
        return {"ok": False, "error": "No data returned"}
    devices = []
    for d in resp.data:
        if isinstance(d, dict):
            devices.append({
                "iot_id":      d.get("iot_id", d.get("iotId", "")),
                "device_id":   d.get("device_id", d.get("deviceId", "")),
                "device_name": d.get("device_name", d.get("deviceName", "")),
                "device_type": d.get("device_type", d.get("deviceType", "")),
                "series":      d.get("series", ""),
                "status":      d.get("status", 0),
                "generation":  d.get("generation", 0),
                "active_time": d.get("active_time", d.get("activeTime", "")),
            })
        else:
            devices.append({
                "iot_id":      getattr(d, "iot_id", ""),
                "device_id":   getattr(d, "device_id", ""),
                "device_name": getattr(d, "device_name", ""),
                "device_type": getattr(d, "device_type", ""),
                "series":      getattr(d, "series", ""),
                "status":      getattr(d, "status", 0),
                "generation":  getattr(d, "generation", 0),
                "active_time": getattr(d, "active_time", ""),
            })
    return {"ok": True, "devices": devices}


async def mqtt_action(account, password, device_name, iot_id, action, extra_params=None):
    # pymammotion hat die Geraete-/Cloud-API umgebaut. Wir unterstuetzen beide:
    #   neu (ca. >= 0.7.117): pymammotion.client.MammotionClient
    #   alt (ca. <= 0.7.82) : pymammotion.mammotion.devices.mammotion.Mammotion
    # Einheitliche Helfer (login/get_state/map_sync/plan_sync/send/stop) kapseln
    # die Unterschiede, sodass der Dispatch unten identisch bleibt.
    try:
        from pymammotion.client import MammotionClient
        _new_api = True
    except ImportError:
        _new_api = False

    if _new_api:
        # Neue API: SSL/CA-Bug ist hier behoben, kein Patch noetig.
        from pymammotion.data.model.generate_route_information import GenerateRouteInformation
        client = MammotionClient()
        login     = client.login_and_initiate_cloud
        get_state = client.get_device_by_name
        map_sync  = client.start_map_sync
        plan_sync = client.start_plan_sync
        stop      = client.stop
        send      = client.send_command_with_args
    else:
        # Alte API: get_ssl_context() laedt die CA nicht korrekt
        # (-> CERTIFICATE_VERIFY_FAILED), daher synchron nachladen.
        import ssl as _ssl
        from pymammotion.mqtt import aliyun_mqtt as _aliyun_mod

        async def _fixed_get_ssl_context():
            ctx = _ssl.SSLContext(_ssl.PROTOCOL_TLS_CLIENT)
            ctx.options |= _ssl.OP_IGNORE_UNEXPECTED_EOF
            ctx.load_verify_locations(cadata=_aliyun_mod._ALIYUN_BROKER_CA_DATA)
            return ctx

        _aliyun_mod.AliyunMQTT.get_ssl_context = staticmethod(_fixed_get_ssl_context)

        from pymammotion.data.model import GenerateRouteInformation
        from pymammotion.mammotion.devices.mammotion import Mammotion

        Mammotion._instance = None
        _m = Mammotion()
        login     = _m.login_and_initiate_cloud
        get_state = _m.mower
        map_sync  = _m.start_map_sync
        plan_sync = _m.start_schedule_sync
        stop      = _m.stop

        async def send(name, key, **kwargs):
            if kwargs:
                await _m.send_command_with_args(name, key, **kwargs)
            else:
                await _m.send_command(name, key)

    try:
        try:
            await login(account, password)
        except Exception as e:
            err = " ".join(str(e).split())
            err = err.replace("'", " ").replace('"', " ").replace("\\", " ")
            return {"ok": False, "error": "Login fehlgeschlagen: {}".format(err[:300])}

        # Kurz warten, bis die MQTT-Transport-Verbindung steht.
        await asyncio.sleep(5)

        if get_state(device_name) is None:
            return {"ok": False, "error": "Geraet nicht gefunden: {}".format(device_name)}

        if action == "start_mowing":
            await send(device_name, "start_job")
            return {"ok": True, "action": action}

        elif action == "stop_mowing":
            await send(device_name, "cancel_job")
            return {"ok": True, "action": action}

        elif action == "pause_mowing":
            await send(device_name, "pause_execute_task")
            return {"ok": True, "action": action}

        elif action == "resume_mowing":
            await send(device_name, "resume_execute_task")
            return {"ok": True, "action": action}

        elif action == "return_home":
            await send(device_name, "return_to_dock")
            return {"ok": True, "action": action}

        elif action == "leave_dock":
            await send(device_name, "leave_dock")
            return {"ok": True, "action": action}

        elif action == "along_border":
            await send(device_name, "along_border")
            return {"ok": True, "action": action}

        elif action == "get_zones":
            # Map-Sync NICHT blockierend abwarten: in der neuen API wartet
            # start_map_sync auf die MapFetchSaga, die ueber die Cloud teils
            # nicht/zu langsam durchkommt (-> frueher harter BlockingCall-Kill).
            # Stattdessen Saga als Hintergrund-Task starten und nur den
            # Geraete-State pollen (die Saga fuellt device.map.area inkrementell,
            # waehrend wir schlafen). So bleibt die Laufzeit hart begrenzt.
            sync_task = asyncio.ensure_future(map_sync(device_name))

            wait_max = 90
            wait_step = 3
            waited = 0
            stable_count = 0
            stable_needed = 2
            last_zone_count = -1

            while waited < wait_max:
                await asyncio.sleep(wait_step)
                waited += wait_step
                mower = get_state(device_name)
                area_map = getattr(getattr(mower, "map", None), "area", {}) or {} if mower else {}
                current_count = len(area_map)
                if current_count > 0 and current_count == last_zone_count:
                    stable_count += 1
                    if stable_count >= stable_needed:
                        break
                else:
                    stable_count = 0
                last_zone_count = current_count

            # Hintergrund-Task best effort beenden. CancelledError ist eine
            # BaseException (nicht Exception) -> breit abfangen.
            if not sync_task.done():
                sync_task.cancel()
            try:
                await asyncio.wait_for(sync_task, timeout=1)
            except BaseException:
                pass

            mower = get_state(device_name)
            if mower is None:
                return {"ok": False, "error": "Device state not available"}

            zones = []
            area_map       = mower.map.area      if hasattr(mower.map, "area")      else {}
            area_name_list = mower.map.area_name if hasattr(mower.map, "area_name") else []
            # area_name ist list[AreaHashNameList(name, hash)] — zu dict konvertieren
            name_map = {item.hash: item.name for item in area_name_list}

            for hash_id, area_data in area_map.items():
                zone_name = name_map.get(hash_id, "Zone {}".format(hash_id))
                zones.append({
                    "hash":  hash_id,
                    "name":  zone_name,
                })

            return {"ok": True, "action": "get_zones", "zones": zones}

        elif action == "start_zone":
            if not extra_params:
                return {"ok": False, "error": "zone_hash parameter required"}
            zone_hash = int(extra_params[0])

            route_info = GenerateRouteInformation(
                one_hashs=[zone_hash],
                job_mode=3,
                edge_mode=1,
                blade_height=40,
                speed=1.0,
                ultra_wave=1,
                channel_width=220,
                channel_mode=0,
                toward=0,
                toward_included_angle=0,
                toward_mode=0,
                path_order="",
            )

            await send(
                device_name, "generate_route_information",
                generate_route_information=route_info
            )
            await asyncio.sleep(2)
            await send(device_name, "start_job")
            return {"ok": True, "action": "start_zone", "zone_hash": zone_hash}

        elif action == "get_tasks":
            # Plaene/Tasks via start_plan_sync (nicht start_map_sync), zeitlich
            # begrenzt -> kein harter Kill, falls die Saga haengt.
            try:
                await asyncio.wait_for(plan_sync(device_name), timeout=90)
            except asyncio.TimeoutError:
                pass
            except Exception:
                pass

            # Kurze Stabilisierung (alte API liefert Daten asynchron nach).
            wait_max = 30
            wait_step = 3
            waited = 0

            while waited < wait_max:
                mower = get_state(device_name)
                if mower is not None:
                    plan_map = getattr(getattr(mower, "map", None), "plan", {}) or {}
                    if plan_map:
                        sample = next(iter(plan_map.values()))
                        total = getattr(sample, "total_plan_num", 0)
                        if total > 0 and len(plan_map) >= total:
                            break  # all plans received
                await asyncio.sleep(wait_step)
                waited += wait_step

            mower = get_state(device_name)
            if mower is None:
                return {"ok": False, "error": "Device state not available"}

            plan_map = getattr(getattr(mower, "map", None), "plan", {}) or {}
            tasks = []
            for plan_id, plan in plan_map.items():
                task_name = getattr(plan, "task_name", "") or getattr(plan, "job_name", "") or "Aufgabe {}".format(len(tasks) + 1)
                task_id   = getattr(plan, "task_id", "") or getattr(plan, "job_id", "") or plan_id
                zone_hashs = list(getattr(plan, "zone_hashs", []) or [])
                tasks.append({
                    "id":      task_id,
                    "name":    task_name,
                    "zones":   zone_hashs,
                    "plan_id": plan_id,
                })

            return {"ok": True, "action": "get_tasks", "tasks": tasks}

        elif action == "start_task":
            if not extra_params:
                return {"ok": False, "error": "plan_id parameter required"}
            plan_id = extra_params[0]

            await send(
                device_name, "single_schedule",
                plan_id=plan_id
            )
            return {"ok": True, "action": "start_task", "plan_id": plan_id}

        elif action == "get_status":
            await send(device_name, "get_report_cfg")
            await asyncio.sleep(5)

            mower = get_state(device_name)
            if mower is None:
                return {"ok": False, "error": "Device state not available"}

            if not hasattr(mower, "report_data") or mower.report_data is None:
                return {"ok": False, "error": "Report data not available"}
            dev = mower.report_data.dev
            if dev is None:
                return {"ok": False, "error": "Device data not available"}

            location = mower.location if hasattr(mower, "location") else None

            result = {
                "ok":           True,
                "action":       "get_status",
                "charge_state": dev.charge_state,
                "battery":      dev.battery_val,
                "work_state":   dev.sys_status,
                "mow_zone":     location.work_zone if location is not None else 0,
            }
            return result

        else:
            return {"ok": False, "error": "Unknown action: {}".format(action)}

    except Exception as e:
        err = str(e).replace("'", "").replace('"', '')
        return {"ok": False, "error": "Command failed: {}".format(err)}

    finally:
        try:
            await asyncio.wait_for(stop(), timeout=15)
        except Exception:
            pass


async def run(account, password, action, params, app_version=DEFAULT_APP_VERSION, legacy_login=False):
    from pymammotion.http.http import MammotionHTTP

    # App-Version-Header korrigieren, bevor MammotionHTTP verwendet wird
    # (auch fuer die intern vom MQTT-Login erzeugte Instanz).
    try:
        _patch_app_version(app_version)
    except Exception:
        pass

    # Optional: login_v2 -> alten login umleiten (Attribut legacy_login).
    if legacy_login:
        try:
            _patch_legacy_login()
        except Exception:
            pass

    mqtt_actions = {
        "start_mowing", "stop_mowing", "pause_mowing", "resume_mowing",
        "return_home", "leave_dock", "along_border",
        "get_zones", "start_zone", "get_status", "get_tasks", "start_task"
    }

    if action in mqtt_actions:
        if len(params) < 2:
            return {"ok": False, "error": "Benotige device_name und iot_id als Parameter"}
        device_name  = params[0]
        iot_id       = params[1]
        extra_params = params[2:] if len(params) > 2 else []
        return await mqtt_action(account, password, device_name, iot_id, action, extra_params)

    http = MammotionHTTP()
    try:
        try:
            await http.login(account, password)
        except Exception as e:
            # Login-Fehler sauber als Ergebnis zurueckgeben (Exit-Code 0),
            # statt als Exception mit Exit-Code 1 abzubrechen. So landet die
            # Meldung kontrolliert in last_error und das Modul bleibt bedienbar.
            err = " ".join(str(e).split())
            err = err.replace("'", " ").replace('"', " ").replace("\\", " ")
            return {"ok": False, "error": "Login fehlgeschlagen: {}".format(err[:300])}

        if action == "get_devices":
            return await get_devices(http)
        else:
            return {"ok": False, "error": "Unknown action: {}".format(action)}
    finally:
        try:
            await http._session.close()
        except Exception:
            pass


if __name__ == "__main__":
    argv = sys.argv[1:]
    verbose = "-v" in argv or "--verbose" in argv

    # Flags herausloesen (--app-version <wert>/=<wert>, --legacy-login),
    # damit die positionalen Argumente unveraendert bleiben.
    app_version = DEFAULT_APP_VERSION
    legacy_login = False
    cleaned = []
    skip_next = False
    for i, a in enumerate(argv):
        if skip_next:
            skip_next = False
            continue
        if a in ("-v", "--verbose"):
            continue
        if a == "--legacy-login":
            legacy_login = True
            continue
        if a == "--app-version":
            if i + 1 < len(argv):
                app_version = argv[i + 1]
                skip_next = True
            continue
        if a.startswith("--app-version="):
            app_version = a.split("=", 1)[1]
            continue
        cleaned.append(a)
    argv = cleaned

    if verbose:
        logging.basicConfig(level=logging.DEBUG, force=True)
    else:
        logging.basicConfig(level=logging.WARNING)

    # Versionskennung ins stderr (im FHEM-Log unter "Python stderr" sichtbar).
    sys.stderr.write("mammotion_helper version {}\n".format(HELPER_VERSION))
    sys.stderr.flush()

    if len(argv) < 3:
        print(json.dumps({"ok": False, "error": "Usage: mammotion_helper.py <account> <password> <action> [params...] [--app-version <ver>] [--legacy-login] [-v]"}))
        sys.exit(1)

    account  = argv[0]
    password = argv[1]
    action   = argv[2]
    params   = argv[3:] if len(argv) > 3 else []

    # Gesamt-Zeitbudget je Aktion (jeweils unter dem FHEM-BlockingCall-Timeout).
    # wf = asyncio-Timeout (sauberer Abbruch, falls Cancellation greift),
    # wd = harte Watchdog-Frist (Prozess-Exit, falls der Loop trotzdem haengt).
    _budget = {
        "get_zones":  (180, 200),
        "start_zone": (140, 160),
        "get_tasks":  (140, 160),
        "start_task": (140, 160),
        "get_status": (70, 80),
    }
    wf, wd = _budget.get(action, (50, 55))

    # Watchdog-Thread: garantiert den Prozess-Exit nach wd Sekunden, UNABHAENGIG
    # vom Event-Loop. Noetig, weil pymammotion-Hintergrund-Tasks (MQTT/Transport)
    # die Cancellation verschlucken koennen -> loop.run_until_complete kehrt sonst
    # nie zurueck und os._exit unten wird nie erreicht (-> harter FHEM-Kill).
    import threading
    import time as _time

    def _watchdog():
        _time.sleep(wd)
        try:
            sys.stdout.write(json.dumps({"ok": False, "error": "Zeitueberschreitung bei Aktion {} (Watchdog)".format(action)}) + "\n")
            sys.stdout.flush()
        except Exception:
            pass
        os._exit(0)

    threading.Thread(target=_watchdog, daemon=True).start()

    # Eigene Event-Loop statt asyncio.run(): nach dem Ergebnis hart beenden
    # (os._exit), damit das Loop-Shutdown nicht an haengenden pymammotion-
    # Hintergrund-Tasks (MQTT-Loops/Transport-Reconnect nach dem Map-Sync)
    # blockiert.
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        result = loop.run_until_complete(
            asyncio.wait_for(
                run(account, password, action, params, app_version, legacy_login),
                timeout=wf,
            )
        )
    except asyncio.TimeoutError:
        result = {"ok": False, "error": "Zeitueberschreitung bei Aktion {} (Cloud nicht rechtzeitig erreichbar)".format(action)}
    except Exception as e:
        err = " ".join(str(e).split()).replace("'", " ").replace('"', " ").replace("\\", " ")
        result = {"ok": False, "error": err[:300] or "Unbekannter Fehler"}

    try:
        sys.stdout.write(json.dumps(result) + "\n")
        sys.stdout.flush()
        sys.stderr.flush()
    except Exception:
        pass
    # Harter Sofort-Exit ohne Loop-/Task-Cleanup (verhindert Shutdown-Hang).
    os._exit(0)
