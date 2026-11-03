"""Starting the companion app at login: a registry value on Windows, a systemd user service on Linux."""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

from . import processes, safefiles, settings


def background_python() -> str:
    """pythonw has no console window. Fall back to python if this install does not include it."""
    candidate = Path(sys.executable).with_name("pythonw.exe")
    return str(candidate) if candidate.exists() else sys.executable


def enable_windows_autostart(script: Path, start: bool = True) -> str:
    """Start with Windows, for this user only. Needs no admin rights."""
    import winreg

    python = background_python()
    command = f'"{python}" -I "{script}" run'
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, settings.RUN_KEY) as handle:
        winreg.SetValueEx(handle, settings.RUN_VALUE, 0, winreg.REG_SZ, command)
    if start:
        # From its own folder, because Windows won't delete a folder something is standing in, like a download.
        subprocess.Popen([python, "-I", str(script), "run"], close_fds=True, cwd=script.parent,
                         creationflags=subprocess.DETACHED_PROCESS | subprocess.CREATE_NO_WINDOW)
    return command


def write_systemd_unit(script: Path) -> None:
    unit_dir = Path.home() / ".config/systemd/user"
    unit_dir.mkdir(parents=True, exist_ok=True)
    def quoted(value) -> str:
        return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%").replace("$", "$$") + '"'

    safefiles.write_atomic(unit_dir / "prompt-peon.service",
                 "[Unit]\nDescription=Prompt Peon companion app\n\n[Service]\n"
                 f"ExecStart={quoted(sys.executable)} -I {quoted(script)} run\n"
                 "Restart=always\nRestartSec=5\n\n[Install]\nWantedBy=default.target\n")


def start_linux_service(script: Path) -> str:
    """Start the bridge now and at every login. Says what happened, or what to run instead."""
    write_systemd_unit(script)
    by_hand = f'Start the companion app with: "{sys.executable}" -I "{script}" run'
    if not shutil.which("systemctl"):
        return by_hand
    for action in (["daemon-reload"], ["enable", "prompt-peon"], ["restart", "prompt-peon"]):
        try:
            done = subprocess.run(["systemctl", "--user", *action], capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            return by_hand
        if done.returncode != 0:
            return by_hand
    return "The companion app is running, and starts with this machine from now on."


def stop_autostart() -> None:
    """Stop starting at login. On Linux this stops the service too, or systemd would bring it straight back."""
    if settings.IS_WINDOWS:
        import winreg

        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, settings.RUN_KEY, 0, winreg.KEY_SET_VALUE) as handle:
                winreg.DeleteValue(handle, settings.RUN_VALUE)
        except OSError:
            pass
    elif shutil.which("systemctl"):
        subprocess.run(["systemctl", "--user", "disable", "--now", settings.SERVICE], capture_output=True, timeout=30)


def start_stop() -> str:
    """The double-click switch. It flips the installed copy, wherever this one ran from, and off stays off until it's flipped back."""
    script = settings.HOME_DIR / "bridge" / settings.ENTRY_POINT
    if not script.is_file():
        return "Prompt Peon isn't installed yet. Run the installer first."
    lock = processes.acquire_lock(settings.STATE_DIR / "bridge.lock")
    if lock is None:
        stop_autostart()
        if not processes.stop_running_bridge():
            return "The companion app won't start at your next login, but it's still running. Close it by hand."
        return "The companion app is off, and stays off until you run this again. In the game, threads stop updating and replies wait."
    lock.close()
    if settings.IS_WINDOWS:
        enable_windows_autostart(script)
        return "The companion app is on, and starts with Windows again."
    return start_linux_service(script)
