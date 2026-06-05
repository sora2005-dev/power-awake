# OCC

OCC is a small macOS menu bar utility for power-aware sleep prevention.

It is intended for Macs that should stay awake while connected to external power, including closed-lid setups. When external power is disconnected, OCC can restore normal sleep behavior so the battery is not drained.

## Features

- Menu bar status for external power and sleep-prevention state
- Prevent system sleep only while external power is connected
- Restore sleep behavior when power is disconnected
- Optionally request display sleep when the lid is closed
- Optional duration limits: unlimited, 30 minutes, 1 hour, or 2 hours
- Local-only configuration stored at `/Library/Application Support/occ/config.json`

## Requirements

- macOS 13 or later
- Apple Silicon build target by default
- Administrator approval for installing the LaunchDaemon

## Build

```bash
./scripts/build_app.sh
open ~/Applications/OCC.app
```

## Install Scheduler

```bash
./scripts/install_launchd.sh
```

The scheduler runs as `local.occ.scheduler` and checks the local policy every 5 seconds.

## Configuration

The app edits this JSON file:

```text
/Library/Application Support/occ/config.json
```

Default policy:

```json
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
```

## Notes

OCC is standalone. It does not include task-board, network, VPN, credential, or API integrations.
