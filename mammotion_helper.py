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
"""

import sys
import json
import asyncio
import logging

logging.basicConfig(level=logging.WARNING)


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

            # Actively wait until map data arrives (max. 90 seconds)
            wait_max = 90
            wait_step = 3
            waited = 0
            while waited < wait_max:
                await asyncio.sleep(wait_step)
                waited += wait_step
                mower = mammotion.mower(device_name)
                if mower is None:
                    continue
                area_map = mower.map.area if hasattr(mower.map, "area") else {}
                if area_map:
                    break  # Data has arrived, exit the loop

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
            from pymammotion.data.model.enums import JobMode, MowOrder

            route_info = GenerateRouteInformation(
                one_hashs=[zone_hash],
                job_mode=JobMode.NORMAL,
                edge_mode=1,
                blade_height=40,
                speed=1.0,
                ultra_wave=1,
                channel_width=220,
                channel_mode=0,
                toward=0,
                toward_included_angle=0,
                toward_mode=0,
                path_order=MowOrder.LEFT_RIGHT if hasattr(MowOrder, "LEFT_RIGHT") else 0,
            )

            await mammotion.send_command_with_args(
                device_name, "generate_route_information",
                generate_route_information=route_info
            )
            await asyncio.sleep(2)
            await mammotion.send_command(device_name, "start_job")
            return {"ok": True, "action": "start_zone", "zone_hash": zone_hash}

        elif action == "get_status":
            mower = mammotion.mower(device_name)
            if mower is None:
                return {"ok": False, "error": "Device state not available"}

            mower_state = mower.mower_state
            report      = mower.report_data if hasattr(mower, "report_data") else None

            result = {
                "ok":           True,
                "action":       "get_status",
                "charge_state": getattr(mower_state, "charge_state", 0),
                "battery":      getattr(mower_state, "battery_percent", 0),
                "work_state":   getattr(mower_state, "work_state", 0),
                "mow_zone":     getattr(mower_state, "mow_zone", 0),
            }
            if report:
                result["rpt_work_state"] = getattr(report, "work_state", 0)
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
        "get_zones", "start_zone", "get_status"
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
    if len(sys.argv) < 4:
        print(json.dumps({
            "ok":    False,
            "error": "Usage: mammotion_helper.py <account> <password> <action> [params...]"
        }))
        sys.exit(1)

    account  = sys.argv[1]
    password = sys.argv[2]
    action   = sys.argv[3]
    params   = sys.argv[4:] if len(sys.argv) > 4 else []

    try:
        result = asyncio.run(run(account, password, action, params))
        print(json.dumps(result))
        sys.exit(0)
    except Exception as e:
        err = str(e).replace("'", "").replace('"', '')
        print(json.dumps({"ok": False, "error": err}))
        sys.exit(1)