#!/bin/sh
# Removes Prompt Peon, your token and all its saved data. Run it from a terminal: sh uninstall.sh
HERE=$(cd "$(dirname "$0")" && pwd) || exit 1
exec python3 -I "$HERE/bridge/promptpeon_bridge.py" uninstall "$@"
