"""The log line. To the console when there is one, to a file in the state folder when there isn't."""
from __future__ import annotations

import sys
import time

from . import settings


def log(message: str) -> None:
    line = f"{time.strftime('%H:%M:%S')} {message}"
    if sys.stdout is not None:
        print(line, flush=True)
        return
    # Started in the background on Windows, where there is no console to print to.
    try:
        settings.STATE_DIR.mkdir(parents=True, exist_ok=True)
        path = settings.STATE_DIR / "bridge.log"
        if path.exists() and path.stat().st_size > 1_000_000:
            path.unlink()
        with path.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    except OSError:
        pass
