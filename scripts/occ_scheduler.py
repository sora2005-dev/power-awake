#!/usr/bin/env python3
"""Keep a Mac awake according to a local power-aware policy.

Default policy:
  - keep awake only on AC power
  - do not block any time window
  - use caffeinate without blocking display sleep by default
  - optionally toggle `pmset disablesleep` when running as root

This script is standalone and does not read network credentials.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import platform
import re
import shlex
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


DAY_ALIASES = {
  "mon": 0,
  "monday": 0,
  "tue": 1,
  "tues": 1,
  "tuesday": 1,
  "wed": 2,
  "wednesday": 2,
  "thu": 3,
  "thur": 3,
  "thurs": 3,
  "thursday": 3,
  "fri": 4,
  "friday": 4,
  "sat": 5,
  "saturday": 5,
  "sun": 6,
  "sunday": 6,
}


def env_bool(name: str, default: bool = False) -> bool:
  value = os.environ.get(name)
  if value is None:
    return default
  return value.strip().lower() in {"1", "true", "yes", "on"}


def env_int(name: str, default: int) -> int:
  value = os.environ.get(name)
  if value is None:
    return default
  try:
    return int(value.strip())
  except ValueError:
    return default


def run(command: list[str], timeout: int = 10) -> tuple[int, str]:
  try:
    completed = subprocess.run(
      command,
      text=True,
      capture_output=True,
      timeout=timeout,
      check=False,
    )
  except (FileNotFoundError, subprocess.TimeoutExpired) as error:
    return 127, str(error)
  return completed.returncode, (completed.stdout + completed.stderr).strip()


def parse_hhmm(value: str) -> dt.time:
  match = re.fullmatch(r"([01]?\d|2[0-3]):([0-5]\d)", value.strip())
  if not match:
    raise argparse.ArgumentTypeError(f"invalid HH:MM time: {value}")
  return dt.time(hour=int(match.group(1)), minute=int(match.group(2)))


def parse_days(value: str) -> set[int]:
  cleaned = value.strip().lower()
  if cleaned in {"none", "never", "off", "no"}:
    return set()
  if cleaned in {"all", "*"}:
    return set(range(7))
  if cleaned in {"weekday", "weekdays"}:
    return {0, 1, 2, 3, 4}
  if cleaned in {"weekend", "weekends"}:
    return {5, 6}

  days: set[int] = set()
  for day_name in re.split(r"[\s,]+", cleaned):
    if not day_name:
      continue
    if day_name not in DAY_ALIASES:
      raise argparse.ArgumentTypeError(f"invalid day name: {day_name}")
    days.add(DAY_ALIASES[day_name])
  if not days:
    raise argparse.ArgumentTypeError("at least one day is required")
  return days


def time_in_range(value: dt.time, start: dt.time, end: dt.time) -> bool:
  if start <= end:
    return start <= value < end
  return value >= start or value < end


def default_state_dir() -> Path:
  if platform.system() == "Darwin" and hasattr(os, "geteuid") and os.geteuid() == 0:
    return Path("/Library/Application Support/occ")
  return Path.home() / ".config" / "occ"


def default_config_file() -> Path:
  return Path("/Library/Application Support/occ/config.json")


def read_json(path: Path) -> dict[str, Any]:
  try:
    return json.loads(path.read_text(encoding="utf-8"))
  except (FileNotFoundError, json.JSONDecodeError, OSError):
    return {}


def write_json(path: Path, payload: dict[str, Any]) -> None:
  path.parent.mkdir(parents=True, exist_ok=True)
  path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def parse_active_until(value: Any) -> dt.datetime | None:
  if not isinstance(value, str) or not value.strip():
    return None
  normalized = value.strip().replace("Z", "+00:00")
  try:
    parsed = dt.datetime.fromisoformat(normalized)
  except ValueError:
    return None
  if parsed.tzinfo is None:
    return parsed.astimezone()
  return parsed.astimezone()


def bool_config(config: dict[str, Any], name: str, default: bool) -> bool:
  value = config.get(name)
  if isinstance(value, bool):
    return value
  if isinstance(value, str):
    return value.strip().lower() in {"1", "true", "yes", "on"}
  return default


def str_config(config: dict[str, Any], name: str, default: str) -> str:
  value = config.get(name)
  if isinstance(value, str) and value.strip():
    return value.strip()
  return default


def pmset_battery() -> dict[str, Any]:
  code, output = run(["/usr/bin/pmset", "-g", "batt"])
  source = "unknown"
  percent: int | None = None
  if code == 0:
    if "AC Power" in output:
      source = "ac"
    elif "Battery Power" in output:
      source = "battery"
    match = re.search(r"(\d+)%", output)
    if match:
      percent = int(match.group(1))
  return {"source": source, "percent": percent, "raw_ok": code == 0}


def read_sleep_disabled() -> dict[str, Any]:
  code, output = run(["/usr/sbin/ioreg", "-r", "-k", "SleepDisabled", "-d", "1"])
  if code != 0:
    return {"raw_ok": False, "enabled": None}
  match = re.search(r'"SleepDisabled"\s*=\s*(Yes|No)', output)
  if not match:
    return {"raw_ok": True, "enabled": None}
  return {"raw_ok": True, "enabled": match.group(1) == "Yes"}


def read_clamshell_state() -> dict[str, Any]:
  code, output = run(["/usr/sbin/ioreg", "-r", "-k", "AppleClamshellState", "-d", "1"])
  if code != 0:
    return {"raw_ok": False, "closed": None}
  match = re.search(r'"AppleClamshellState"\s*=\s*(Yes|No)', output)
  if not match:
    return {"raw_ok": True, "closed": None}
  return {"raw_ok": True, "closed": match.group(1) == "Yes"}


def set_disablesleep(enabled: bool) -> tuple[bool, str]:
  value = "1" if enabled else "0"
  code, output = run(["/usr/bin/pmset", "-a", "disablesleep", value])
  return code == 0, output


def pid_exists(pid: int) -> bool:
  try:
    os.kill(pid, 0)
  except ProcessLookupError:
    return False
  except PermissionError:
    return True
  return True


def caffeinate_running(pid_file: Path) -> dict[str, Any]:
  try:
    pid = int(pid_file.read_text(encoding="utf-8").strip())
  except (FileNotFoundError, ValueError, OSError):
    return {"running": False, "pid": None}

  return {"running": pid_exists(pid), "pid": pid}


def stop_caffeinate(pid_file: Path) -> bool:
  status = caffeinate_running(pid_file)
  pid = status.get("pid")
  if not isinstance(pid, int):
    return False
  if not status["running"]:
    try:
      pid_file.unlink()
    except OSError:
      pass
    return False

  try:
    os.kill(pid, signal.SIGTERM)
  except ProcessLookupError:
    pass
  except PermissionError:
    return False

  try:
    pid_file.unlink()
  except OSError:
    pass
  try:
    pid_file.with_suffix(".json").unlink()
  except OSError:
    pass
  return True


def parse_caffeinate_flags(value: str) -> list[str]:
  flags = shlex.split(value.strip())
  if not flags:
    raise ValueError("caffeinate flags must not be empty")
  if any(not flag.startswith("-") for flag in flags):
    raise ValueError("caffeinate flags must only contain option flags")
  return flags


def start_caffeinate(pid_file: Path, flags: list[str]) -> int:
  existing = caffeinate_running(pid_file)
  metadata_file = pid_file.with_suffix(".json")
  metadata = read_json(metadata_file)
  if existing["running"] and isinstance(existing["pid"], int):
    if metadata.get("flags") == flags:
      return existing["pid"]
    stop_caffeinate(pid_file)

  pid_file.parent.mkdir(parents=True, exist_ok=True)
  process = subprocess.Popen(
    ["/usr/bin/caffeinate", *flags],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    start_new_session=True,
  )
  pid_file.write_text(str(process.pid), encoding="utf-8")
  write_json(metadata_file, {"flags": flags})
  return process.pid


def is_blocked_by_schedule(now: dt.datetime, block_days: set[int], block_start: dt.time, block_end: dt.time) -> bool:
  if not block_days:
    return False
  return now.weekday() in block_days and time_in_range(now.time(), block_start, block_end)


def build_decision(args: argparse.Namespace, state_dir: Path) -> dict[str, Any]:
  now = dt.datetime.now().astimezone()
  config = read_json(args.config_file)
  power = pmset_battery()
  if "blockDays" in config:
    block_days = parse_days(str_config(config, "blockDays", "none"))
  else:
    block_days = args.block_days
  blocked = is_blocked_by_schedule(now, block_days, args.block_start, args.block_end)
  enabled = bool_config(config, "enabled", args.enabled) and platform.system() == "Darwin"
  only_while_plugged_in = bool_config(config, "onlyWhilePluggedIn", True)
  sleep_on_power_disconnect = bool_config(config, "sleepOnPowerDisconnect", True)
  allow_display_sleep = bool_config(config, "allowDisplaySleep", True)
  sleep_display_when_lid_closed = bool_config(config, "sleepDisplayWhenLidClosed", True)
  prevent_lid_sleep = bool_config(config, "preventLidSleep", args.manage_disablesleep)
  active_until = parse_active_until(config.get("activeUntil"))
  expired = active_until is not None and now >= active_until
  power_allowed = power["source"] == "ac" or not only_while_plugged_in
  power_disconnected = only_while_plugged_in and power["source"] != "ac"
  caffeinate_flags = str_config(config, "caffeinateFlags", args.caffeinate_flags)
  if allow_display_sleep and caffeinate_flags == args.caffeinate_flags:
    caffeinate_flags = "-ims"
  elif not allow_display_sleep and caffeinate_flags == args.caffeinate_flags:
    caffeinate_flags = "-dimsu"
  should_keep_awake = enabled and power_allowed and not blocked and not expired

  return {
    "now": now.isoformat(timespec="seconds"),
    "enabled": enabled,
    "should_keep_awake": should_keep_awake,
    "blocked_by_schedule": blocked,
    "expired": expired,
    "power_disconnected": power_disconnected,
    "active_until": active_until.isoformat(timespec="seconds") if active_until else None,
    "power": power,
    "sleep_disabled": read_sleep_disabled(),
    "clamshell": read_clamshell_state(),
    "caffeinate": caffeinate_running(state_dir / "caffeinate.pid"),
    "config_file": str(args.config_file),
    "policy": {
      "block_days": sorted(block_days),
      "block_start": args.block_start.strftime("%H:%M"),
      "block_end": args.block_end.strftime("%H:%M"),
      "manage_disablesleep": prevent_lid_sleep,
      "only_while_plugged_in": only_while_plugged_in,
      "sleep_on_power_disconnect": sleep_on_power_disconnect,
      "allow_display_sleep": allow_display_sleep,
      "sleep_display_when_lid_closed": sleep_display_when_lid_closed,
      "prevent_lid_sleep": prevent_lid_sleep,
      "caffeinate_flags": caffeinate_flags,
      "sleep_when_inactive": args.sleep_when_inactive,
      "interval_seconds": args.interval_seconds,
    },
  }


def log(message: str, quiet: bool) -> None:
  if quiet:
    return
  stamp = dt.datetime.now().astimezone().isoformat(timespec="seconds")
  print(f"{stamp} {message}", flush=True)


def apply_policy(args: argparse.Namespace, state_dir: Path) -> dict[str, Any]:
  state_file = state_dir / "state.json"
  pid_file = state_dir / "caffeinate.pid"
  state = read_json(state_file)
  decision = build_decision(args, state_dir)
  previous_power_source = state.get("last_decision", {}).get("power_source")

  if decision["should_keep_awake"]:
    state["sleep_requested_after_power_disconnect"] = False
    flags = parse_caffeinate_flags(decision["policy"]["caffeinate_flags"])
    pid = start_caffeinate(pid_file, flags)
    decision["caffeinate"] = {"running": True, "pid": pid}
    if decision["policy"]["manage_disablesleep"]:
      sleep_disabled = read_sleep_disabled()
      if sleep_disabled.get("enabled") is False:
        ok, output = set_disablesleep(True)
        if ok:
          state["disablesleep_enabled_by_scheduler"] = True
          log("enabled pmset disablesleep=1", args.quiet)
        else:
          log(f"failed to enable pmset disablesleep=1: {output}", args.quiet)
      elif sleep_disabled.get("enabled") is True and not state.get("disablesleep_enabled_by_scheduler"):
        state["disablesleep_preexisting"] = True
    elif state.get("disablesleep_enabled_by_scheduler"):
      ok, output = set_disablesleep(False)
      if ok:
        state["disablesleep_enabled_by_scheduler"] = False
        log("restored pmset disablesleep=0", args.quiet)
      else:
        log(f"failed to restore pmset disablesleep=0: {output}", args.quiet)
    if (
      decision["policy"]["allow_display_sleep"]
      and decision["policy"]["sleep_display_when_lid_closed"]
      and decision["clamshell"].get("closed") is True
    ):
      if not state.get("display_sleep_requested_while_lid_closed"):
        code, output = run(["/usr/bin/pmset", "displaysleepnow"], timeout=10)
        if code == 0:
          state["display_sleep_requested_while_lid_closed"] = True
          log("requested display sleep while lid is closed", args.quiet)
        else:
          log(f"failed to request display sleep while lid is closed: {output}", args.quiet)
    elif decision["clamshell"].get("closed") is False:
      state["display_sleep_requested_while_lid_closed"] = False
    log(f"awake guard active; caffeinate_pid={pid}", args.quiet)
  else:
    if stop_caffeinate(pid_file):
      log("stopped caffeinate guard", args.quiet)
    if state.get("disablesleep_enabled_by_scheduler"):
      ok, output = set_disablesleep(False)
      if ok:
        state["disablesleep_enabled_by_scheduler"] = False
        log("restored pmset disablesleep=0", args.quiet)
      else:
        log(f"failed to restore pmset disablesleep=0: {output}", args.quiet)
    if (
      decision["enabled"]
      and decision["power_disconnected"]
      and decision["policy"]["sleep_on_power_disconnect"]
      and previous_power_source == "ac"
      and not state.get("sleep_requested_after_power_disconnect")
    ):
      code, output = run(["/usr/bin/pmset", "sleepnow"], timeout=10)
      state["sleep_requested_after_power_disconnect"] = True
      if code == 0:
        log("requested system sleep after external power disconnect", args.quiet)
      else:
        log(f"failed to request sleep after external power disconnect: {output}", args.quiet)
    if args.sleep_when_inactive and decision["blocked_by_schedule"] and decision["power"]["source"] == "ac":
      code, output = run(["/usr/bin/pmset", "sleepnow"], timeout=10)
      if code == 0:
        log("requested system sleep for inactive schedule window", args.quiet)
      else:
        log(f"failed to request system sleep: {output}", args.quiet)

  state["last_decision"] = {
    "at": decision["now"],
    "should_keep_awake": decision["should_keep_awake"],
    "blocked_by_schedule": decision["blocked_by_schedule"],
    "power_source": decision["power"]["source"],
  }
  write_json(state_file, state)
  return build_decision(args, state_dir)


def cleanup(args: argparse.Namespace, state_dir: Path) -> None:
  state = read_json(state_dir / "state.json")
  stop_caffeinate(state_dir / "caffeinate.pid")
  if args.manage_disablesleep and state.get("disablesleep_enabled_by_scheduler"):
    ok, output = set_disablesleep(False)
    if ok:
      state["disablesleep_enabled_by_scheduler"] = False
      write_json(state_dir / "state.json", state)
      log("cleanup restored pmset disablesleep=0", args.quiet)
    else:
      log(f"cleanup failed to restore pmset disablesleep=0: {output}", args.quiet)


def main() -> int:
  parser = argparse.ArgumentParser(description="Schedule Mac sleep prevention from local power and time settings.")
  parser.add_argument("--loop", action="store_true", help="run continuously")
  parser.add_argument("--status", action="store_true", help="print current decision without changing state")
  parser.add_argument("--enabled", action="store_true", default=env_bool("MAC_AWAKE_ENABLED", True))
  parser.add_argument("--disabled", action="store_false", dest="enabled")
  parser.add_argument("--block-days", type=parse_days, default=parse_days(os.environ.get("MAC_AWAKE_BLOCK_DAYS", "none")))
  parser.add_argument("--block-start", type=parse_hhmm, default=parse_hhmm(os.environ.get("MAC_AWAKE_BLOCK_START", "07:00")))
  parser.add_argument("--block-end", type=parse_hhmm, default=parse_hhmm(os.environ.get("MAC_AWAKE_BLOCK_END", "18:00")))
  parser.add_argument("--interval-seconds", type=int, default=env_int("MAC_AWAKE_INTERVAL_SECONDS", 60))
  parser.add_argument("--manage-disablesleep", action="store_true", default=env_bool("MAC_AWAKE_MANAGE_DISABLESLEEP", False))
  parser.add_argument("--no-manage-disablesleep", action="store_false", dest="manage_disablesleep")
  parser.add_argument("--caffeinate-flags", default=os.environ.get("MAC_AWAKE_CAFFEINATE_FLAGS", "-ims"))
  parser.add_argument("--sleep-when-inactive", action="store_true", default=env_bool("MAC_AWAKE_SLEEP_WHEN_INACTIVE", False))
  parser.add_argument("--state-dir", type=Path, default=Path(os.environ.get("MAC_AWAKE_STATE_DIR", default_state_dir())))
  parser.add_argument("--config-file", type=Path, default=Path(os.environ.get("MAC_AWAKE_CONFIG_FILE", default_config_file())))
  parser.add_argument("--quiet", action="store_true")
  args = parser.parse_args()

  if args.interval_seconds < 2:
    parser.error("--interval-seconds must be at least 2")
  try:
    parse_caffeinate_flags(args.caffeinate_flags)
  except ValueError as error:
    parser.error(str(error))

  args.state_dir.mkdir(parents=True, exist_ok=True)

  if args.status:
    print(json.dumps(build_decision(args, args.state_dir), ensure_ascii=False, indent=2))
    return 0

  stopping = False

  def handle_signal(_signum: int, _frame: Any) -> None:
    nonlocal stopping
    stopping = True

  signal.signal(signal.SIGTERM, handle_signal)
  signal.signal(signal.SIGINT, handle_signal)

  try:
    while True:
      decision = apply_policy(args, args.state_dir)
      if not args.loop or stopping:
        break
      log(
        "decision="
        + ("active" if decision["should_keep_awake"] else "inactive")
        + f" power={decision['power']['source']} blocked={decision['blocked_by_schedule']}",
        args.quiet,
      )
      time.sleep(args.interval_seconds)
  finally:
    if stopping:
      cleanup(args, args.state_dir)

  return 0


if __name__ == "__main__":
  sys.exit(main())
