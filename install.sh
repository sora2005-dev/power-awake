#!/usr/bin/env bash
set -euo pipefail

REPO_TARBALL_URL="${POWER_AWAKE_TARBALL_URL:-https://github.com/sora2005-dev/power-awake/archive/refs/heads/main.tar.gz}"
ROOT=""
TMP_DIR=""

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [[ ! -x "$ROOT/scripts/build_app.sh" || ! -x "$ROOT/scripts/install_launchd.sh" ]]; then
  TMP_DIR="$(mktemp -d)"
  curl -fsSL "$REPO_TARBALL_URL" -o "$TMP_DIR/source.tar.gz"
  tar -xzf "$TMP_DIR/source.tar.gz" -C "$TMP_DIR"
  ROOT="$(find "$TMP_DIR" -maxdepth 1 -type d -name "power-awake-*" | head -n 1)"
fi

if [[ -z "$ROOT" || ! -x "$ROOT/scripts/build_app.sh" || ! -x "$ROOT/scripts/install_launchd.sh" ]]; then
  echo "Power Awake installer could not locate the project files." >&2
  exit 1
fi

"$ROOT/scripts/build_app.sh"
"$ROOT/scripts/install_launchd.sh"
open "$HOME/Applications/Power Awake.app"

echo "POWER_AWAKE_INSTALLED"
