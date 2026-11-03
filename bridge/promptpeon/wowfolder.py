"""Finding which WoW client to install into."""
from __future__ import annotations

import sys
from pathlib import Path

from . import prompts, settings


def windows_wow_roots(registry_paths: list[str] | None = None, drives: str = "CDEFGHIJ") -> list[Path]:
    """Where WoW lives on Windows: what Blizzard wrote in the registry, then the usual folders."""
    found = list(registry_paths if registry_paths is not None else _registry_wow_paths())
    roots = []
    for value in found:
        path = Path(value)
        roots.append(path.parent if path.name.startswith("_") else path)
    for letter in drives:
        roots += [Path(f"{letter}:/") / folder for folder in settings.WINDOWS_WOW_PATHS]
    return list(dict.fromkeys(roots))


def _registry_wow_paths() -> list[str]:
    import winreg

    paths = []
    for key in (r"SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
                r"SOFTWARE\Blizzard Entertainment\World of Warcraft"):
        for name in ("InstallPath", "GamePath"):
            try:
                with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key) as handle:
                    paths.append(winreg.QueryValueEx(handle, name)[0])
            except OSError:
                pass
    return paths


def find_wow_dir(explicit: str | None, client: str | None = None, home: Path | None = None,
                 roots: list[Path] | None = None) -> Path:
    """The client to install into. With two installed, ask rather than pick the wrong one."""
    if explicit:
        path = Path(explicit).expanduser()
        if path.name not in settings.CLIENTS or not (path / settings.CLIENTS[path.name][1]).exists():
            sys.exit(f"No supported WoW client in {path}. Expected a folder named one of: {', '.join(settings.CLIENTS)}.")
        return path
    wanted = ["_classic_era_"] if client == "era" else [f"_{client}_"] if client else list(settings.CLIENTS)
    if roots is None:
        if settings.IS_WINDOWS:
            roots = windows_wow_roots()
        else:
            roots = [root for pattern in settings.WOW_GLOBS for root in (home or Path.home()).glob(pattern)]
    found = [root / name for root in roots for name in wanted if (root / name / settings.CLIENTS[name][1]).exists()]
    if len(found) == 1:
        return found[0]
    if found and sys.stdin.isatty():
        print("You have more than one WoW client. Which one should T3 live in?")
        for number, path in enumerate(found, 1):
            print(f"  {number}. {settings.CLIENT_NAMES[path.name]}")
        answer = prompts.ask("Type its number: ")
        if answer.isdigit() and 1 <= int(answer) <= len(found):
            return found[int(answer) - 1]
    if found:
        sys.exit("More than one WoW client is installed. Choose one with --client era, --client retail or --client forever.")
    sys.exit("Could not find that WoW client. Install it first, or pass --wow-dir with the path to its client folder.")
