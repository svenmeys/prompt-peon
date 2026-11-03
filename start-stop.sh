#!/bin/sh
# Turns the Prompt Peon companion app off if it's running, and on if it isn't. Run it from a terminal: sh start-stop.sh
HERE=$(cd "$(dirname "$0")" && pwd) || exit 1
# The same choice as the installer, because turning it on writes this Python into the service.
PYTHON=$(command -v python3.15 || command -v python3.14 || command -v python3) || {
  echo "Prompt Peon needs Python 3.14 or newer. Install it with your package manager, then run this again."
  exit 1
}
exec "$PYTHON" -I "$HERE/bridge/promptpeon_bridge.py" start-stop "$@"
