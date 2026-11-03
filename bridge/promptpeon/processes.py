"""Other programs on this machine: whether the game is running, the one-copy lock, and stopping a running copy."""
from __future__ import annotations

import os
import signal
import subprocess
import sys
import time
from pathlib import Path

from . import settings


def running_from(program: Path) -> bool:
    """Retail and Forever are both Wow.exe, so the name can't tell them apart. Windows won't let a running
    program's file be opened for writing, so this can. Opening it changes nothing.
    pa-lean: with no write access to the game folder it can't tell, so it counts as running."""
    try:
        with program.open("r+b"):
            return False
    except OSError:
        return True


def game_running(wow_dir: Path | None = None) -> bool:
    """Whether the game is open, in this client if you name one. If it can't tell which, it counts."""
    try:
        if settings.IS_WINDOWS:
            names = [settings.CLIENTS[wow_dir.name][1]] if wow_dir and wow_dir.name in settings.CLIENTS else [c[1] for c in settings.CLIENTS.values()]
            for name in names:
                listed = subprocess.run(
                    ["tasklist", "/NH", "/FO", "CSV", "/FI", f"IMAGENAME eq {name}"], capture_output=True, text=True,
                    timeout=10, creationflags=subprocess.CREATE_NO_WINDOW,
                ).stdout
                if name.lower() in listed.lower():
                    return wow_dir is None or wow_dir.name not in settings.CLIENTS or running_from(wow_dir / name)
            return False
        # Full commands, because Proton shows the game's path and that says which client it is.
        listed = subprocess.run(["pgrep", "-ifl" if sys.platform == "darwin" else "-ifa", r"wow(classic)?\.exe|world of warcraft( classic)?\.app"],
                                capture_output=True, text=True, timeout=5)
        if listed.returncode != 0:
            return False
        named = [line for line in listed.stdout.splitlines() if any(client in line for client in settings.CLIENTS)]
        return not wow_dir or not named or any(wow_dir.name in line for line in named)
    except (OSError, subprocess.SubprocessError):
        return True  # Rather dial T3 for nothing than miss the game.


def running_client(wow_dirs: list[Path]) -> Path | None:
    """The first of these with its game open."""
    return next((wow_dir for wow_dir in wow_dirs if game_running(wow_dir)), None)


def acquire_lock(path: Path):
    """Only one bridge at a time. Nil if another one holds the lock. The OS frees it if we die."""
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = path.open("a+")
    try:
        if settings.IS_WINDOWS:
            import msvcrt

            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl

            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        return None
    return handle


def stop_running_bridge() -> bool:
    """Stop a running companion app, whichever way it was started. True when none is left."""
    lock = acquire_lock(settings.STATE_DIR / "bridge.lock")
    if lock is not None:
        lock.close()
        return True
    try:
        pid = int((settings.STATE_DIR / "bridge.pid").read_text().strip())
        # Numbers get reused. Only ever stop something that really is us.
        if settings.IS_WINDOWS:
            # Only a whole command line can tell us from another Python. Full paths, so nothing beside the download runs.
            system = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32"
            listed = subprocess.run([str(system / "WindowsPowerShell/v1.0/powershell.exe"), "-NoProfile", "-NonInteractive", "-Command",
                                     f"(Get-CimInstance Win32_Process -Filter 'ProcessId={pid}').CommandLine"], capture_output=True,
                                    text=True, timeout=30, creationflags=subprocess.CREATE_NO_WINDOW).stdout
            if settings.ENTRY_POINT in listed:
                subprocess.run([str(system / "taskkill.exe"), "/PID", str(pid), "/F"], capture_output=True, timeout=10,
                               creationflags=subprocess.CREATE_NO_WINDOW)
        else:
            listed = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True, timeout=10).stdout
            if "promptpeon_bridge" in listed:
                os.kill(pid, signal.SIGTERM)
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    for _ in range(30):
        lock = acquire_lock(settings.STATE_DIR / "bridge.lock")
        if lock is not None:
            lock.close()
            return True
        time.sleep(0.1)
    return False
