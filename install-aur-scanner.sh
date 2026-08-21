#!/bin/bash
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/obilbie.aur-scan"

if ! pacman -Q aur-scanner &>/dev/null; then
  if ! gum confirm "Install aur-scanner from the AUR?"; then
    omarchy plugin disable obilbie.aur-scan >/dev/null 2>&1 || true
    exit 1
  fi
  yay -S --noconfirm --needed aur-scanner
fi

if pacman -Q aur-scanner &>/dev/null; then
  "$PLUGIN_DIR/install-yay-hook.sh"
  mkdir -p "$STATE_DIR"
  touch "$STATE_DIR/setup-complete"
fi
