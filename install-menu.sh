#!/bin/bash
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/extensions/omarchy-menu.jsonc"
FRAGMENT="$PLUGIN_DIR/menu-entries.jsonc"
BEGIN="// BEGIN obilbie.aur-scan"
END="// END obilbie.aur-scan"

if [[ ! -f $FRAGMENT ]]; then
  echo "obilbie.aur-scan: missing $FRAGMENT" >&2
  exit 1
fi

if ! command -v python3 >/dev/null; then
  echo "obilbie.aur-scan: python3 is required to install menu entries" >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
if [[ ! -f $DEST ]]; then
  printf '{\n}\n' > "$DEST"
fi

python3 - "$DEST" "$FRAGMENT" "$BEGIN" "$END" <<'PY'
import sys
from pathlib import Path

dest = Path(sys.argv[1])
fragment = Path(sys.argv[2]).read_text()
begin, end = sys.argv[3], sys.argv[4]
text = dest.read_text()

out = []
skip = False
for line in text.splitlines(keepends=True):
    stripped = line.strip()
    if stripped == begin:
        skip = True
        continue
    if stripped == end:
        skip = False
        continue
    if not skip:
        out.append(line)
text = "".join(out)

idx = text.rfind("}")
if idx < 0:
    sys.exit("obilbie.aur-scan: omarchy-menu.jsonc has no closing brace")

before = text[:idx].rstrip()
code_line = ""
for line in reversed(before.splitlines()):
    stripped = line.strip()
    if not stripped or stripped.startswith("//"):
        continue
    code_line = stripped
    break
if code_line and code_line != "{" and not code_line.endswith(","):
    before += ","

dest.write_text(before + "\n" + fragment.strip("\n") + "\n}\n")
PY
