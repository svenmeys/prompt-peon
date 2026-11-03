"""Starting the companion app at login: a registry value on Windows, a systemd user service on Linux."""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

from . import safefiles, settings


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
        subprocess.Popen([python, "-I", str(script), "run"], close_fds=True,
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
