#!/bin/bash
# Adds OpenUsage to the app menu (~/.local/share/applications) and opens it.
# Usage: widget-linux/install.sh [--no-open]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if ! python3 -c 'import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk' >/dev/null 2>&1; then
  echo "Python GTK 3 bindings not found. Install them first:" >&2
  echo "  Debian/Ubuntu/Mint/Zorin: sudo apt install python3-gi python3-gi-cairo gir1.2-gtk-3.0" >&2
  echo "  Fedora:                   sudo dnf install python3-gobject gtk3" >&2
  echo "  Arch:                     sudo pacman -S python-gobject gtk3" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "warning: node not found on PATH; install Node.js >= 22.6" >&2
elif ! node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&b>=6)?0:1)'; then
  echo "warning: Node.js $(node -v) is too old; OpenUsage needs >= 22.6" >&2
fi

python3 "$ROOT/widget-linux/openusage.py" --install

if ! python3 -c 'import gi
for n in ("AyatanaAppIndicator3", "AppIndicator3"):
    try:
        gi.require_version(n, "0.1"); raise SystemExit(0)
    except ValueError:
        pass
raise SystemExit(1)' >/dev/null 2>&1; then
  echo "tip: for a tray icon on GNOME, install gir1.2-ayatanaappindicator3-0.1 (and the AppIndicator extension)."
fi

if [ "${1:-}" != "--no-open" ]; then
  # A running copy just shows itself; start detached so this terminal can close.
  nohup python3 "$ROOT/widget-linux/openusage.py" >/dev/null 2>&1 &
fi
