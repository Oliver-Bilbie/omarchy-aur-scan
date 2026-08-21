#!/bin/bash
set -euo pipefail

if ! pacman -Q aur-scanner &>/dev/null; then
  echo "aur-scanner is not installed"
  exit 0
fi

if gum confirm --default=false "Remove aur-scanner?"; then
  yay -Rns --noconfirm aur-scanner
fi
