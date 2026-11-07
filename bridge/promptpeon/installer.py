"""The install command: copying the program somewhere permanent, then setting up the game folder."""
from __future__ import annotations

import json
import sys
from pathlib import Path

from . import addonfiles, autostart, pairing, processes, prompts, safefiles, screen, settings, updater, userconfig, wowfolder


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
    wrappers = {name: (script.parent.parent / name).read_bytes() for name in (("install.cmd", "uninstall.cmd", "start-stop.cmd") if settings.IS_WINDOWS else ("install.sh", "uninstall.sh", "start-stop.sh"))
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


def clients_to_use(args) -> tuple[list[Path], list[Path]]:
    """Which clients get Prompt Peon, and which had it and no longer do. Naming one adds it to what you have."""
    config = userconfig.read_config()
    saved = [Path(folder) for folder in dict.fromkeys([*(config.get("wow_dirs") or []), config.get("wow_dir")]) if folder and Path(folder).is_dir()]
    found = wowfolder.find_wow_dirs(args.wow_dir, args.client)
    chosen = list(dict.fromkeys([*found, *saved])) if args.wow_dir or args.client else prompts.choose_clients(found, saved)
    return chosen, [folder for folder in saved if folder not in chosen]


def install(args) -> None:
    """The whole install, from checking for a newer version to starting the companion app."""
    if sys.version_info < settings.INSTALL_PYTHON:
        sys.exit("Prompt Peon needs Python 3.14 or newer, so the app holding your T3 access has current security fixes. "
                 "Get it from https://www.python.org/downloads/ and run this again.")
    if sys.stdin.isatty() and not args.no_update:
        updater.use_the_latest(sys.argv[1:])
    screen.title(f"Prompt Peon {settings.VERSION} setup")
    screen.say("Free software with no warranty, so use it at your own risk. It sends real instructions to real agents on your T3 machine. It isn't made or endorsed by Blizzard or by T3.")
    screen.step(1, 4, "Looking for WoW")
    wow_dirs, dropped = clients_to_use(args)
    for wow_dir in wow_dirs:
        screen.ok(f"Using {settings.CLIENT_NAMES[wow_dir.name]}: {wow_dir}")
    for wow_dir in [*wow_dirs, *dropped]:
        prompts.wait_for_game_to_close(wow_dir)
    screen.step(2, 4, "Connecting to T3")
    url = pairing.connect_to_t3(args.url, args.link, args.pictures, args.allow_unencrypted)
    pairing.offer_this_machine(url, getattr(args, "also_local", None))
    screen.step(3, 4, "Your addons and agents")
    prompts.ask_about_other_addons(*wow_dirs)
    full_access = prompts.wants_full_access(args.full_access)
    screen.step(4, 4, "Installing")
    if settings.IS_WINDOWS and not processes.stop_running_bridge():
        sys.exit("The companion app is still running, so nothing changed. Close pythonw.exe in Task Manager and run this again.")
    script, addon_source = settle_in(settings.PROGRAM_DIR / settings.ENTRY_POINT, Path(args.addon_source))
    counts = [addonfiles.place_addon(wow_dir, addon_source) for wow_dir in wow_dirs]
    for folder in dropped:
        _taken, stuck = addonfiles.remove_from_client(folder)
        (screen.say if stuck else screen.ok)(f"Couldn't remove all of Prompt Peon from {folder}: {', '.join(stuck[:3])}" if stuck else
                                             f"Removed Prompt Peon from {settings.CLIENT_NAMES.get(folder.name, folder.name)}.")
    chosen = [str(wow_dir) for wow_dir in wow_dirs]
    saved = userconfig.read_config()
    # The app starts here and follows whichever game opens, so this is only where it begins.
    wow_dir = saved.get("wow_dir") if saved.get("wow_dir") in chosen else chosen[0]
    safefiles.write_atomic(settings.CONFIG_DIR / "config.json", json.dumps(dict(userconfig.read_config(), url=url, wow_dir=wow_dir, wow_dirs=chosen, full_access=full_access), indent=2))
    screen.ok(f"Installed the addon and {counts[0]} helper entries" + (f" in {len(counts)} clients." if len(counts) > 1 else "."))
    if args.no_start:
        pass
    elif settings.IS_WINDOWS:
        autostart.enable_windows_autostart(script)
        screen.ok("The companion app is running, and starts with Windows from now on.")
    else:
        started = autostart.start_linux_service(script)
        (screen.ok if started.startswith("The companion app is running") else screen.say)(started)
    screen.done("Done. Start the game, or restart it if it is open, and type /peon.")
