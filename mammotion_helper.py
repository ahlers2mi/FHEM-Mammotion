#!/usr/bin/env python3.13
"""
Mammotion Cloud API Helper fuer FHEM
Aufruf: mammotion_helper.py <account> <password> <action> [params...]

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
import json
import asyncio
import logging


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
    # Bugfix for pymammotion: get_ssl_context() does not await run_in_executor(),
    # so CA certificates are never loaded -> CERTIFICATE_VERIFY_FAILED.
    # Patch: load CA certificates synchronously.
    import ssl as _ssl
    from pymammotion.mqtt import aliyun_mqtt as _aliyun_mod

    async def _fixed_get_ssl_context():
        context = _ssl.SSLContext(_ssl.PROTOCOL_TLS_CLIENT)
        context.options |= _ssl.OP_IGNORE_UNEXPECTED_EOF
        context.load_verify_locations(cadata=_aliyun_mod._ALIYUN_BROKER_CA_DATA)
        return context

    _aliyun_mod.AliyunMQTT.get_ssl_context = staticmethod(_fixed_get_ssl_context)

    from pymammotion.mammotion.devices.mammotion import Mammotion

    Mammotion._instance = None
    mammotion = Mammotion()
    await mammotion.login_and_initiate_cloud(account, password)
    await asyncio.sleep(5)

    try:
        device = mammotion.get_device_by_name(device_name)
    except (KeyError, Exception) as e:
        return {"ok": False, "error": "Device not found: {}".format(str(e).replace("'", ""))}

    try:
        if action == "start_mowing":
            await mammotion.send_command(device_name, "start_job")
            return {"ok": True, "action": action}

        elif action == "stop_mowing":
            await mammotion.send_command(device_name, "cancel_job")
            return {"ok": True, "action": action}

        elif action == "pause_mowing":
            await mammotion.send_command(device_name, "pause_execute_task")
            return {"ok": True, "action": action}

        elif action == "resume_mowing":
            await mammotion.send_command(device_name, "resume_execute_task")
            return {"ok": True, "action": action}

        elif action == "return_home":
            await mammotion.send_command(device_name, "return_to_dock")
            return {"ok": True, "action": action}

        elif action == "leave_dock":
            await mammotion.send_command(device_name, "leave_dock")
            return {"ok": True, "action": action}

        elif action == "along_border":
            await mammotion.send_command(device_name, "along_border")
            return {"ok": True, "action": action}

        elif action == "get_zones":
            await mammotion.start_map_sync(device_name)

            # Wait until zone count is stable (all MQTT packets received)
            wait_max = 90
            wait_step = 3
            waited = 0
            stable_count = 0
            stable_needed = 3
            last_zone_count = -1

            while waited < wait_max:
                await asyncio.sleep(wait_step)
                waited += wait_step
                mower = mammotion.mower(device_name)
                if mower is None:
                    stable_count = 0
                    last_zone_count = -1
                    continue
                area_map = mower.map.area if hasattr(mower.map, "area") else {}
                current_count = len(area_map)
                if current_count > 0 and current_count == last_zone_count:
                    stable_count += 1
                    if stable_count >= stable_needed:
                        break
                else:
                    stable_count = 0
                last_zone_count = current_count

            mower = mammotion.mower(device_name)
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

            from pymammotion.data.model import GenerateRouteInformation

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

            await mammotion.send_command_with_args(
                device_name, "generate_route_information",
                generate_route_information=route_info
            )
            await asyncio.sleep(2)
            await mammotion.send_command(device_name, "start_job")
            return {"ok": True, "action": "start_zone", "zone_hash": zone_hash}

        elif action == "get_tasks":
            # Plans/Tasks need start_schedule_sync, not start_map_sync
            await mammotion.start_schedule_sync(device_name)

            # Wait until all plans have arrived (plan count == total_plan_num)
            wait_max = 90
            wait_step = 3
            waited = 0

            while waited < wait_max:
                await asyncio.sleep(wait_step)
                waited += wait_step
                mower = mammotion.mower(device_name)
                if mower is None:
                    continue
                plan_map = getattr(getattr(mower, "map", None), "plan", {}) or {}
                if plan_map:
                    sample = next(iter(plan_map.values()))
                    total = getattr(sample, "total_plan_num", 0)
                    if total > 0 and len(plan_map) >= total:
                        break  # all plans received

            mower = mammotion.mower(device_name)
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

            await mammotion.send_command_with_args(
                device_name, "single_schedule",
                plan_id=plan_id
            )
            return {"ok": True, "action": "start_task", "plan_id": plan_id}

        elif action == "get_status":
            await mammotion.send_command(device_name, "get_report_cfg")
            await asyncio.sleep(5)

            mower = mammotion.mower(device_name)
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
            await mammotion.stop()
        except Exception:
            pass


async def run(account, password, action, params):
    from pymammotion.http.http import MammotionHTTP

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
    await http.login(account, password)
    try:
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
    argv = [a for a in argv if a not in ("-v", "--verbose")]

    if verbose:
        logging.basicConfig(level=logging.DEBUG, force=True)
    else:
        logging.basicConfig(level=logging.WARNING)

    if len(argv) < 3:
        print(json.dumps({"ok": False, "error": "Usage: mammotion_helper.py <account> <password> <action> [params...] [-v]"}))
        sys.exit(1)

    account  = argv[0]
    password = argv[1]
    action   = argv[2]
    params   = argv[3:] if len(argv) > 3 else []

    try:
        result = asyncio.run(run(account, password, action, params))
        print(json.dumps(result))
        sys.exit(0)
    except Exception as e:
        err = str(e).replace("'", "").replace('"', '')
        print(json.dumps({"ok": False, "error": err}))
        sys.exit(1)