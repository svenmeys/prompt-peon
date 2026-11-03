#!/bin/sh
# Prompt Peon setup for Linux and Steam Deck. Run it from a terminal: sh install.sh
HERE=$(cd "$(dirname "$0")" && pwd) || exit 1
# A newer one can sit next to an older python3, which is common on Linux.
PYTHON=$(command -v python3.15 || command -v python3.14 || command -v python3) || {
  echo "Prompt Peon needs Python 3.14 or newer. Install it with your package manager, then run this again."
  exit 1
}
exec "$PYTHON" -I "$HERE/bridge/promptpeon_bridge.py" install "$@"
