#!/bin/bash
set -euo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/obilbie.aur-scan"
FILE="$STATE_DIR/severity"
DEFAULT="medium"

valid() {
  case "${1:-}" in
    critical | high | medium | low | info) return 0 ;;
    *) return 1 ;;
  esac
}

get() {
  local value="$DEFAULT"
  if [[ -f $FILE ]]; then
    value="$(<"$FILE")"
    value="${value//$'\n'/}"
  fi
  if ! valid "$value"; then
    value="$DEFAULT"
  fi
  printf '%s\n' "$value"
}

set_value() {
  if ! valid "${1:-}"; then
    echo "obilbie.aur-scan: invalid severity: ${1:-}" >&2
    echo "valid: critical|high|medium|low|info" >&2
    exit 1
  fi
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$1" > "$FILE"
}

case "${1:-}" in
  get) get ;;
  set) set_value "${2:-}" ;;
  *)
    echo "usage: threshold.sh get|set <critical|high|medium|low|info>" >&2
    exit 1
    ;;
esac
