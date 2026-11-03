"""Taking everything back out."""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

from . import addonfiles, processes, safefiles, settings, userconfig


def game_folders_with_us(wow_dir: Path | None) -> list[Path]:
    """Every client Prompt Peon went into, and its known neighbours in case that was lost."""
    known = [Path(folder) for folder in userconfig.read_config().get("wow_dirs") or []] + ([wow_dir] if wow_dir else [])
    found: dict[str, Path] = {}
    for folder in known:
        for candidate in (folder, *(folder.parent / client for client in settings.CLIENTS)):
            if (candidate / "Interface/AddOns" / settings.ADDON).exists() or (candidate / "WTF/Account").is_dir() and candidate == folder:
                found[str(candidate)] = candidate
    return list(found.values())


def uninstall(wow_dir: Path | None) -> None:
    """Take everything back out, and say plainly what only T3 can do."""
    folders = game_folders_with_us(wow_dir)
    # Every client it went into. On Windows each one is its own program.
    if any(processes.game_running(folder) for folder in folders or ([wow_dir] if wow_dir else [])):
        sys.exit("Close WoW first. It saves its data again when it closes, and that would bring it back.")
    if settings.IS_WINDOWS:
        import winreg

        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, settings.RUN_KEY, 0, winreg.KEY_SET_VALUE) as handle:
                winreg.DeleteValue(handle, settings.RUN_VALUE)
        except OSError:
            pass
    elif shutil.which("systemctl"):
        subprocess.run(["systemctl", "--user", "disable", "--now", settings.SERVICE], capture_output=True, timeout=30)
        (Path.home() / f".config/systemd/user/{settings.SERVICE}.service").unlink(missing_ok=True)
        subprocess.run(["systemctl", "--user", "daemon-reload"], capture_output=True, timeout=30)
    # It could have been started by hand. Left running, it would put everything back.
    if not processes.stop_running_bridge():
        sys.exit("The companion app is still running, so nothing was removed. Close it and run this again.")
    removed = 0
    left: list[str] = []

    def take_out(path: Path) -> None:
        try:
            safefiles.remove_path(path)
        except OSError:
            left.append(str(path))

    for folder in folders:
        addons = folder / "Interface/AddOns"
        for path in list(addons.glob(f"{settings.ADDON}*")):
            if path.name in addonfiles.OUR_ADDONS:
                take_out(path)
                removed += 1
        # What the game saved for us: drafts and unsent messages, including its backups.
        for saved in (folder / "WTF/Account").glob(f"*/SavedVariables/{settings.ADDON}.lua*"):
            take_out(saved)
    token = settings.CONFIG_DIR / "token"
    if token.exists() or token.is_symlink():
        take_out(token)  # This goes whatever else happens.
    for folder in {settings.STATE_DIR, settings.HOME_DIR}:
        if folder.exists():
            take_out(folder)
    if left:
        # Keep only where to look, or running this again couldn't find what's left.
        known = [str(folder) for folder in folders]
        safefiles.write_atomic(settings.CONFIG_DIR / "config.json", json.dumps({"wow_dir": known[0] if known else "", "wow_dirs": known}, indent=2))
        print(f"Removed {removed} addon folders and your token, but these are still there: {', '.join(left)}")
        sys.exit("Close anything using them and run this again.")
    if settings.CONFIG_DIR.exists():
        take_out(settings.CONFIG_DIR)
    print(f"Removed the addon ({removed} folders), your token and all saved data from this machine.")
    print("\nOne thing only T3 can do: in T3 go to Settings, Sharing & access, and revoke Prompt Peon.")
    print("Screenshots, chat logs and backups you already made are not touched.")
