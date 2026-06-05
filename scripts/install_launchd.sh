#!/usr/bin/env bash
set -euo pipefail

LABEL="local.occ.scheduler"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$OCC_ROOT/scripts/occ_launchd.plist.template"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
STATE_DIR="/Library/Application Support/occ"
CONFIG_FILE="$STATE_DIR/config.json"
INSTALL_WAKE_SCHEDULE=0

usage() {
  cat <<USAGE
Usage: $0 [--install-wake-schedule]

Installs the OCC scheduler as a root LaunchDaemon.

Default policy:
  - active only on AC power
  - active at any time while on AC power
  - toggles pmset disablesleep only while active

Options:
  --install-wake-schedule
      Also run: pmset repeat wakeorpoweron MTWRF 18:00:00
      This may replace an existing repeating pmset power schedule.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-wake-schedule)
      INSTALL_WAKE_SCHEDULE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer is macOS-only." >&2
  exit 1
fi

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Missing plist template: $TEMPLATE" >&2
  exit 1
fi

TMP="$(mktemp)"
sed -e "s#__OCC_ROOT__#$OCC_ROOT#g" "$TEMPLATE" > "$TMP"
plutil -lint "$TMP" >/dev/null

sudo install -o root -g wheel -m 644 "$TMP" "$PLIST"
rm -f "$TMP"

CONSOLE_USER="$(stat -f %Su /dev/console 2>/dev/null || true)"
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" ]]; then
  CONSOLE_USER="${SUDO_USER:-$USER}"
fi

sudo mkdir -p "$STATE_DIR" "/Library/Logs"
sudo chown "$CONSOLE_USER:staff" "$STATE_DIR"
sudo chmod 775 "$STATE_DIR"
if [[ ! -f "$CONFIG_FILE" ]]; then
  sudo tee "$CONFIG_FILE" >/dev/null <<'JSON'
{
  "enabled": true,
  "onlyWhilePluggedIn": true,
  "sleepOnPowerDisconnect": true,
  "allowDisplaySleep": true,
  "sleepDisplayWhenLidClosed": true,
  "preventLidSleep": true,
  "activeUntil": null,
  "blockDays": "none"
}
JSON
fi
sudo chown "$CONSOLE_USER:staff" "$CONFIG_FILE"
sudo chmod 664 "$CONFIG_FILE"

if sudo launchctl print "system/$LABEL" >/dev/null 2>&1; then
  sudo launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
fi

sudo launchctl bootstrap system "$PLIST"
sudo launchctl kickstart -k "system/$LABEL"

if [[ "$INSTALL_WAKE_SCHEDULE" == "1" ]]; then
  sudo pmset repeat wakeorpoweron MTWRF 18:00:00
  echo "wake schedule: wakeorpoweron MTWRF 18:00:00"
else
  echo "wake schedule: unchanged"
  echo "  Optional: rerun with --install-wake-schedule to wake weekdays at 18:00."
fi

echo "launchd:"
sudo launchctl print "system/$LABEL" >/dev/null
echo "  loaded: $LABEL"

echo "status:"
python3 "$OCC_ROOT/scripts/occ_scheduler.py" --status --manage-disablesleep --config-file "$CONFIG_FILE"

echo "OCC_LAUNCHD_INSTALLED"
