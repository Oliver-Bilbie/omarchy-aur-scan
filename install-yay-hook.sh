#!/bin/bash
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
YAY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/yay"
HOOKS_DIR="$YAY_DIR/hooks"
INIT="$YAY_DIR/init.lua"
BEGIN="-- BEGIN obilbie.aur-scan"
END="-- END obilbie.aur-scan"
MARKER="-- obilbie.aur-scan"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/obilbie.aur-scan"
HOOK_SRC="$PLUGIN_DIR/hooks/obilbie-aur-scan"
HOOK_DEST="$HOOKS_DIR/obilbie-aur-scan"
HOOK_LEGACY_FILE="$HOOKS_DIR/obilbie-aur-scan.lua"
HOOK_LEGACY_ALT="$HOOKS_DIR/aur-scan.lua"

owned_hook() {
  [[ -f $1 ]] && grep -qF -- "$MARKER" "$1"
}

owned_hook_dir() {
  [[ -f $1/init.lua ]] && grep -qF -- "$MARKER" "$1/init.lua"
}

install_hook() {
  mkdir -p "$HOOKS_DIR"
  rm -f "$HOOK_LEGACY_FILE"
  if owned_hook "$HOOK_LEGACY_ALT"; then
    rm -f "$HOOK_LEGACY_ALT"
  fi
  rm -rf "$HOOK_DEST"
  mkdir -p "$HOOK_DEST"
  install -m 644 "$HOOK_SRC/init.lua" "$HOOK_DEST/init.lua"
  install -m 644 "$HOOK_SRC/util.lua" "$HOOK_DEST/util.lua"
  install -m 644 "$HOOK_SRC/agent.lua" "$HOOK_DEST/agent.lua"
  if [[ ! -f $HOOK_DEST/init.lua || ! -f $HOOK_DEST/util.lua || ! -f $HOOK_DEST/agent.lua ]]; then
    echo "obilbie.aur-scan: failed to install yay hook modules" >&2
    exit 1
  fi
}

register_init() {
  mkdir -p "$YAY_DIR"
  touch "$INIT"
  if grep -qF -- "$BEGIN" "$INIT"; then
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
  printf '\n%s\nrequire("hooks.obilbie-aur-scan")\n%s\n' "$BEGIN" "$END" >> "$INIT"
  if ! grep -qF -- "$BEGIN" "$INIT" || ! grep -qF -- 'require("hooks.obilbie-aur-scan")' "$INIT"; then
    echo "obilbie.aur-scan: failed to register hook in $INIT" >&2
    exit 1
  fi
}

if [[ ! -f $HOOK_SRC/init.lua || ! -f $HOOK_SRC/util.lua || ! -f $HOOK_SRC/agent.lua ]]; then
  echo "obilbie.aur-scan: hook source missing under $HOOK_SRC" >&2
  exit 1
fi
if [[ ! -x $PLUGIN_DIR/omarchy-agent-sandbox.sh || ! -f $PLUGIN_DIR/broker.py ]]; then
  echo "obilbie.aur-scan: sandbox/broker missing under $PLUGIN_DIR" >&2
  exit 1
fi

if [[ ${1:-} == --update ]]; then
  if [[ -e $HOOK_DEST && ! -d $HOOK_DEST ]]; then
    if ! owned_hook "$HOOK_DEST"; then
      echo "obilbie.aur-scan: refusing to overwrite $HOOK_DEST (not this plugin's hook)" >&2
      exit 1
    fi
  elif [[ -d $HOOK_DEST ]] && ! owned_hook_dir "$HOOK_DEST"; then
    echo "obilbie.aur-scan: refusing to overwrite $HOOK_DEST (not this plugin's hook)" >&2
    exit 1
  elif [[ -f $HOOK_LEGACY_FILE ]] && ! owned_hook "$HOOK_LEGACY_FILE"; then
    echo "obilbie.aur-scan: refusing to overwrite $HOOK_LEGACY_FILE (not this plugin's hook)" >&2
    exit 1
  fi
  install_hook
  register_init
  "$PLUGIN_DIR/install-menu.sh"
  mkdir -p "$STATE_DIR"
  touch "$STATE_DIR/setup-complete"
  exit 0
fi

if [[ -e $HOOK_DEST && ! -d $HOOK_DEST ]]; then
  if ! owned_hook "$HOOK_DEST"; then
    echo "obilbie.aur-scan: refusing to overwrite $HOOK_DEST (not this plugin's hook)" >&2
    omarchy plugin disable obilbie.aur-scan >/dev/null 2>&1 || true
    exit 1
  fi
elif [[ -d $HOOK_DEST ]] && ! owned_hook_dir "$HOOK_DEST"; then
  echo "obilbie.aur-scan: refusing to overwrite $HOOK_DEST (not this plugin's hook)" >&2
  omarchy plugin disable obilbie.aur-scan >/dev/null 2>&1 || true
  exit 1
elif [[ -f $HOOK_LEGACY_FILE ]] && ! owned_hook "$HOOK_LEGACY_FILE"; then
  echo "obilbie.aur-scan: refusing to overwrite $HOOK_LEGACY_FILE (not this plugin's hook)" >&2
  omarchy plugin disable obilbie.aur-scan >/dev/null 2>&1 || true
  exit 1
fi

if ! command -v gum >/dev/null; then
  echo "obilbie.aur-scan: gum is required to confirm the yay hook" >&2
  omarchy plugin disable obilbie.aur-scan >/dev/null 2>&1 || true
  exit 1
fi
if ! gum confirm $'AUR Scan will create a yay pre-install hook.\nThis writes ~/.config/yay/hooks/obilbie-aur-scan/ and a short block in ~/.config/yay/init.lua.\nContinue?'; then
  omarchy plugin disable obilbie.aur-scan >/dev/null 2>&1 || true
  exit 1
fi

install_hook
register_init
"$PLUGIN_DIR/install-menu.sh"
mkdir -p "$STATE_DIR"
touch "$STATE_DIR/setup-complete"
