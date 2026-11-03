"""Your saved settings and your token, in the config folder. The token is never written where the game can read it."""
from __future__ import annotations

import json
import sys

from . import safefiles, settings


def read_config() -> dict:
    try:
        return json.loads((settings.CONFIG_DIR / "config.json").read_text())
    except (OSError, ValueError):
        return {}


def read_token() -> str:
    path = settings.CONFIG_DIR / "token"
    try:
        return path.read_text().strip()
    except OSError:
        sys.exit("Prompt Peon isn't connected to T3 yet. Run the installer again.")


def save_token(token: str) -> None:
    settings.CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    path = settings.CONFIG_DIR / "token"
    safefiles.write_atomic(path, token)  # Owner-only from the first byte, and never through a link.
    path.chmod(0o600)
