"""Newer releases. The installer fetches one when you run it. The companion app only asks whether one exists, so the game can
say so: it never updates itself, and nothing in the game can ask it to."""
from __future__ import annotations

import io
import json
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

from . import console, screen, settings, t3remote

VERSION_LINE = re.compile(r'^VERSION = "(\d+\.\d+\.\d+)"$', re.M)


def latest_release() -> str:
    """The version of the newest release on GitHub. Nothing of yours goes with the request, and a redirect is refused."""
    with t3remote.NO_REDIRECTS.open(settings.UPDATE_API, timeout=settings.UPDATE_SECONDS) as response:
        tag = json.loads(t3remote.read_bounded(response)).get("tag_name")
    # This goes into an address, so only the exact shape gets through.
    if not isinstance(tag, str) or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ValueError(f"the newest release has a strange name: {tag}")
    return tag[1:]


def is_newer(version: str, than: str | None = None) -> bool:
    numbers = lambda text: tuple(int(part) for part in text.split("."))
    return numbers(version) > numbers(than or settings.VERSION)


def update_notice(version: str) -> str:
    """Fixed words around a number that latest_release checked, so nothing from GitHub reaches the game but that."""
    if settings.IS_WINDOWS:
        return f"Prompt Peon {version} is out. Close WoW, then double-click install.cmd in %LOCALAPPDATA%\\prompt-peon."
    return f"Prompt Peon {version} is out. Close WoW, then run: sh ~/.local/share/prompt-peon/install.sh"


def check_for_newer(bridge) -> None:
    """Note a newer release for the game to mention. It only asks: nothing gets downloaded or run."""
    try:
        latest = latest_release()
        bridge.newer_release = latest if is_newer(latest) else None
    except Exception as error:  # GitHub being away is nobody's problem.
        console.log(f"couldn't ask GitHub about new versions: {type(error).__name__}: {str(error)[:200]}")


def watch_for_releases(bridge, game_open) -> None:
    """Runs in its own thread, because GitHub can take a minute to not answer, and that mustn't hold up replies."""
    next_check = 0.0
    while True:
        time.sleep(settings.GAME_CHECK_SECONDS)
        if game_open() and time.monotonic() >= next_check:
            next_check = time.monotonic() + settings.UPDATE_CHECK_SECONDS
            check_for_newer(bridge)


def download_release(version: str) -> bytes:
    with t3remote.NO_REDIRECTS.open(settings.UPDATE_ZIP.format(version=version), timeout=settings.UPDATE_SECONDS) as response:
        return t3remote.read_bounded(response)


def unpack_latest(data: bytes, target: Path) -> str:
    """Unpack only what the installer uses, and only inside target. Returns its version."""
    total = 0
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        if len({entry.filename.split("/")[0] for entry in archive.infolist()}) != 1:
            raise ValueError("the download has more than one top folder")
        for entry in archive.infolist():
            top, *parts = entry.filename.split("/")
            if not top or "\\" in entry.filename or ":" in entry.filename or ".." in parts:
                raise ValueError(f"the download has a strange path in it: {entry.filename}")
            if stat.S_ISLNK(entry.external_attr >> 16):
                raise ValueError(f"the download has a link in it: {entry.filename}")
            if entry.is_dir() or not parts or parts[0] not in settings.UPDATE_PARTS:
                continue
            total += entry.file_size
            if total > settings.MAX_UPDATE_BYTES:
                raise ValueError("the download is too big to be real")
            path = target.joinpath(*parts)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(archive.read(entry))
    script = target / "bridge" / settings.ENTRY_POINT
    version_home = target / "bridge" / settings.PACKAGE / "settings.py"
    if not script.is_file() or not version_home.is_file() or not (target / "addon" / settings.ADDON / f"{settings.ADDON}.toc").is_file():
        raise ValueError("the download doesn't have the program in it")
    found = VERSION_LINE.search(version_home.read_text(errors="replace"))
    if not found:
        raise ValueError("the download doesn't say which version it is")
    return found.group(1)


def installed_version() -> str | None:
    """What's in the program folder, which may not be the copy running this. None if it can't be run."""
    program = settings.HOME_DIR / "bridge"
    try:
        found = VERSION_LINE.search((program / settings.PACKAGE / "settings.py").read_text(errors="replace"))
    except OSError:
        return None
    return found.group(1) if found and (program / settings.ENTRY_POINT).is_file() else None


def hand_over(script: Path, arguments: list[str]) -> None:
    done = subprocess.run([sys.executable, "-I", str(script), *arguments, "--no-update"])
    sys.exit(done.returncode)


def use_the_latest(arguments: list[str]) -> None:
    """Hand over to the newest copy there is: a newer release from GitHub, or a newer install than this download. Only the
    installer does this, and only when you run it yourself: the companion app never updates itself, and nothing in the
    game folder can ask it to."""
    screen.say("Checking GitHub for a newer version...")
    installed = installed_version()
    newest_here = installed if installed and is_newer(installed) else settings.VERSION
    folder = None
    try:
        try:
            latest = latest_release()
            if is_newer(latest, newest_here):
                folder = Path(tempfile.mkdtemp(prefix="promptpeon-update-"))
                if unpack_latest(download_release(latest), folder) != latest:
                    raise ValueError(f"release {latest} says it's a different version")
                screen.ok(f"Using {latest} from GitHub, because this copy is {settings.VERSION}.")
                hand_over(folder / "bridge" / settings.ENTRY_POINT, arguments)
            if newest_here == settings.VERSION:
                screen.ok("You have the newest version.")
        except Exception as error:  # A failed check must never stop an install.
            screen.say(f"Couldn't get the newest version, so this uses the one you have ({newest_here}): {error}")
        if newest_here != settings.VERSION:
            screen.ok(f"This copy is {settings.VERSION}, but {newest_here} is already installed, so this uses that.")
            hand_over(settings.HOME_DIR / "bridge" / settings.ENTRY_POINT, arguments)
    finally:
        if folder:
            shutil.rmtree(folder, ignore_errors=True)
