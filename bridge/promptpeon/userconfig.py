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


def extra_token_path(name: str):
    # The name comes from the installer, but a config edited by hand mustn't reach outside the folder.
    if not name or not all(char.isascii() and (char.isalnum() or char == "-") for char in name):
        raise ValueError(f"a T3 name can only have letters, digits and dashes: {name!r}")
    return settings.CONFIG_DIR / f"token-{name}"


def read_extra_token(name: str) -> str:
    try:
        return extra_token_path(name).read_text().strip()
    except OSError:
        sys.exit(f"Prompt Peon has no token for the T3 called {name}. Run the installer again.")


def save_extra_token(name: str, token: str) -> None:
    settings.CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    path = extra_token_path(name)
    safefiles.write_atomic(path, token)
    path.chmod(0o600)
