#!/bin/bash
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
YAY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/yay"
HOOKS_DIR="$YAY_DIR/hooks"
INIT="$YAY_DIR/init.lua"
BEGIN="-- BEGIN obilbie.aur-scan"
END="-- END obilbie.aur-scan"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/obilbie.aur-scan"

MARKER="-- obilbie.aur-scan"
owned_hook() {
  [[ -f $1 ]] && grep -qF -- "$MARKER" "$1"
}
owned_hook_dir() {
  [[ -f $1/init.lua ]] && grep -qF -- "$MARKER" "$1/init.lua"
}
for hook in "$HOOKS_DIR/obilbie-aur-scan.lua" "$HOOKS_DIR/aur-scan.lua"; do
  if owned_hook "$hook"; then
    rm -f "$hook"
  fi
done
if owned_hook_dir "$HOOKS_DIR/obilbie-aur-scan"; then
  rm -rf "$HOOKS_DIR/obilbie-aur-scan"
fi

MENU="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/extensions/omarchy-menu.jsonc"
MENU_BEGIN="// BEGIN obilbie.aur-scan"
MENU_END="// END obilbie.aur-scan"
if [[ -f $MENU ]] && grep -qF -- "$MENU_BEGIN" "$MENU"; then
  if ! grep -qF -- "$MENU_END" "$MENU"; then
    echo "obilbie.aur-scan: malformed markers in $MENU; not editing" >&2
    exit 1
  fi
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  awk -v b="$MENU_BEGIN" -v e="$MENU_END" 'index($0, b) {skip=1; next} index($0, e) {skip=0; next} !skip {print}' "$MENU" > "$tmp"
  mv "$tmp" "$MENU"
  trap - EXIT
fi

if [[ -f $INIT ]] && grep -qF -- "$BEGIN" "$INIT"; then
  if ! grep -qF -- "$END" "$INIT"; then
    echo "obilbie.aur-scan: malformed markers in $INIT; not editing" >&2
    exit 1
  fi
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  awk -v b="$BEGIN" -v e="$END" '$0 == b {skip=1; next} $0 == e {skip=0; next} !skip {print}' "$INIT" > "$tmp"
  mv "$tmp" "$INIT"
  trap - EXIT
fi

rm -rf "$STATE_DIR"

if pacman -Q aur-scanner &>/dev/null; then
  omarchy-launch-floating-terminal-with-presentation "$PLUGIN_DIR/remove-aur-scanner.sh"
fi
