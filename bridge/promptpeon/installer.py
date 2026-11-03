"""The install command: copying the program somewhere permanent, then setting up the game folder."""
from __future__ import annotations

import json
import sys
from pathlib import Path

from . import addonfiles, autostart, pairing, processes, prompts, safefiles, settings, updater, userconfig, wowfolder


def settle_in(script: Path, addon_source: Path) -> tuple[Path, Path]:
    """Copy the program and addon somewhere permanent, so the download can be deleted. Read first and
    never written through a link, so a link somebody prepared can't aim this at another file."""
    program_dir = settings.HOME_DIR / "bridge"
    target = program_dir / script.name
    addon = settings.HOME_DIR / "addon" / settings.ADDON
    package = script.parent / settings.PACKAGE
    # Only the source. Compiled files from wherever this ran stay behind, because Python would run them as us.
    program = {Path(settings.PACKAGE) / path.relative_to(package): path.read_bytes() for path in package.rglob("*.py")
               if path.is_file() and not path.is_symlink()}
    program[Path(script.name)] = script.read_bytes()  # Written last, so what starts it is never newer than what it starts.
    # Setup and removal come along too. They aren't there on an install copied over SSH.
    wrappers = {name: (script.parent.parent / name).read_bytes() for name in (("install.cmd", "uninstall.cmd") if settings.IS_WINDOWS else ("install.sh", "uninstall.sh"))
                if (script.parent.parent / name).is_file()}
    files = {path.relative_to(addon_source): path.read_bytes() for path in addon_source.rglob("*")
             if path.is_file() and not path.is_symlink()}
    settings.HOME_DIR.parent.mkdir(parents=True, exist_ok=True)
    for folder in (settings.HOME_DIR, program_dir, addon.parent, addon):
        safefiles.own_folder(folder)
    _make_folder_hold(program_dir, program)
    for name, data in wrappers.items():
        safefiles.write_binary_atomic(settings.HOME_DIR / name, data)
    _make_folder_hold(addon, files)
    return target, addon


def _make_folder_hold(folder: Path, files: dict[Path, bytes]) -> None:
    """Exactly these files. Whatever else is in there would run as us, and it came from somewhere else."""
    _sweep(folder, folder, set(files), {parent for relative in files for parent in relative.parents})
    for relative, data in files.items():
        for parent in reversed(relative.parents):
            if str(parent) != ".":
                safefiles.own_folder(folder / parent)
        safefiles.write_binary_atomic(folder / relative, data)


def _sweep(root: Path, folder: Path, files: set[Path], folders: set[Path]) -> None:
    # From the top down, so a link goes before anything can walk through it. A Windows junction looks like a folder.
    for path in folder.iterdir():
        relative = path.relative_to(root)
        if safefiles.is_link(path) or not ((path.is_file() and relative in files) or (path.is_dir() and relative in folders)):
            safefiles.remove_path(path)
        elif path.is_dir():
            _sweep(root, path, files, folders)


def install(args) -> None:
    """The whole install, from checking for a newer version to starting the companion app."""
    if sys.version_info < settings.INSTALL_PYTHON:
        sys.exit("Prompt Peon needs Python 3.14 or newer, so the app holding your T3 access has current security fixes. "
                 "Get it from https://www.python.org/downloads/ and run this again.")
    if sys.stdin.isatty() and not args.no_update:
        updater.use_the_latest(sys.argv[1:])
    print(f"Prompt Peon {settings.VERSION} setup\n")
    print("Free software with no warranty, so use it at your own risk. It sends real instructions to real")
    print("agents on your T3 machine. It isn't made or endorsed by Blizzard or by T3.\n")
    wow_dir = wowfolder.find_wow_dir(args.wow_dir, args.client)
    print(f"Found {settings.CLIENT_NAMES[wow_dir.name]}: {wow_dir}")
    prompts.wait_for_game_to_close(wow_dir)
    url = pairing.connect_to_t3(args.url, args.link, args.pictures, args.allow_unencrypted)
    prompts.ask_about_other_addons(wow_dir)
    full_access = prompts.wants_full_access(args.full_access)
    if settings.IS_WINDOWS and not processes.stop_running_bridge():
        sys.exit("The companion app is still running, so nothing changed. Close pythonw.exe in Task Manager and run this again.")
    script, addon_source = settle_in(settings.PROGRAM_DIR / settings.ENTRY_POINT, Path(args.addon_source))
    count = addonfiles.place_addon(wow_dir, addon_source)
    known_dirs = list(dict.fromkeys([*(userconfig.read_config().get("wow_dirs") or []), userconfig.read_config().get("wow_dir"), str(wow_dir)]))
    known_dirs = [folder for folder in known_dirs if folder]
    for folder in known_dirs:
        if folder != str(wow_dir):
            addonfiles.clear_game_folder(Path(folder))
    safefiles.write_atomic(settings.CONFIG_DIR / "config.json", json.dumps(dict(userconfig.read_config(), url=url, wow_dir=str(wow_dir), wow_dirs=known_dirs, full_access=full_access), indent=2))
    print(f"Installed the addon and {count} helper entries.")
    if args.no_start:
        pass
    elif settings.IS_WINDOWS:
        autostart.enable_windows_autostart(script)
        print("The companion app is running, and starts with Windows from now on.")
    else:
        print(autostart.start_linux_service(script))
    print("\nDone. Start the game, or restart it if it is open, and type /peon.")
