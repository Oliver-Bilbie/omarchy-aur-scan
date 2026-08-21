#!/bin/bash
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/obilbie.aur-scan"

if [[ ! -x $PLUGIN_DIR/install-yay-hook.sh || ! -x $PLUGIN_DIR/install-aur-scanner.sh || ! -x $PLUGIN_DIR/install-menu.sh || ! -x $PLUGIN_DIR/threshold.sh ]]; then
  echo "obilbie.aur-scan: missing install scripts in $PLUGIN_DIR" >&2
  exit 1
fi

mkdir -p "$STATE_DIR"
if [[ ! -f $STATE_DIR/severity ]]; then
  printf 'medium\n' > "$STATE_DIR/severity"
fi

if [[ -f $STATE_DIR/setup-complete ]]; then
  "$PLUGIN_DIR/install-yay-hook.sh" --update
  exit 0
fi

rm -f "$STATE_DIR/asked-install"

if pacman -Q aur-scanner &>/dev/null; then
  if ! command -v omarchy-launch-floating-terminal-with-presentation >/dev/null; then
    echo "obilbie.aur-scan: cannot prompt to install the yay hook (launcher missing)" >&2
    omarchy plugin disable obilbie.aur-scan >/dev/null 2>&1 || true
    exit 1
  fi
  omarchy-launch-floating-terminal-with-presentation "$PLUGIN_DIR/install-yay-hook.sh"
  exit 0
fi

if ! command -v omarchy-launch-floating-terminal-with-presentation >/dev/null; then
  echo "obilbie.aur-scan: cannot prompt to install aur-scanner (launcher missing)" >&2
  omarchy plugin disable obilbie.aur-scan >/dev/null 2>&1 || true
  exit 1
fi

omarchy-launch-floating-terminal-with-presentation "$PLUGIN_DIR/install-aur-scanner.sh"
