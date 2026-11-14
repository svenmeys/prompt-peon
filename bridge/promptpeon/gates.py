"""The checks on other addons and on full access. Any addon can write what ours writes, so these are the real checks."""
from __future__ import annotations

import re
import sys
import time
from pathlib import Path

from . import addonfiles, console, gametext, settings


def other_addons(bridge) -> list[str]:
    """Addons you have not said you trust. WoW gives us no way to tell who is sending."""
    return addonfiles.other_addons_in(bridge.wow_dir, bridge.config().get("trusted_addons") or [])


def trust_command(name: str) -> str | None:
    """The exact command that trusts one addon, so an agent that built it can run it. Only for a name
    that is safe to paste: whoever made the addon chose its folder name, and this goes into a terminal."""
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}", name):
        return None
    return cli_command(f"trust {name}")


def cli_command(words: str) -> str:
    """The exact command line for one of the companion app's own commands, for a notice to name.
    `words` is ours or already checked: it goes into a terminal as it is."""
    python = Path(sys.executable)
    if python.name.lower() == "pythonw.exe" and python.with_name("python.exe").exists():
        python = python.with_name("python.exe")  # pythonw would print nothing.
    # pa-lean: quoted for sh, bash and cmd. PowerShell wants "& " in front; add it if agents there trip on it.
    return f'"{without_your_name(python)}" -I "{without_your_name(settings.PROGRAM_DIR / settings.ENTRY_POINT)}" {words}'


def without_your_name(path: Path) -> str:
    """A path for the game to show. Your home folder has your account's name in it, and the game's
    chat ends up in screenshots and streams. So the home folder is named the way a shell names it,
    which still runs when pasted: inside double quotes sh expands $HOME and cmd expands %USERPROFILE%."""
    try:
        inside = path.relative_to(Path.home())
    except ValueError:
        return str(path)
    return f"%USERPROFILE%\\{inside}" if settings.IS_WINDOWS else f"$HOME/{inside.as_posix()}"


def refused_full_access(bridge, thread: dict) -> str | None:
    """An agent with full access can do anything on the T3 machine without asking, and any addon
    you trust can send through this. So reaching those from the game is something you turn on."""
    # Only an explicit yes counts. An older install, or a config we can't read, hasn't said yes.
    if thread.get("runtimeMode") in settings.SUPERVISED_MODES or bridge.config().get("full_access") is True:
        return None
    return ("failed: This agent has full access, and sending to those from the game is off. "
            "Run the Prompt Peon installer again to turn it on")


def withheld_because(bridge) -> str:
    """Thread text only enters the game once you've said you trust every addon that could read
    it. This says why it's staying out, and it's empty when it isn't."""
    stays_out = "so thread text stays out of the game."
    try:
        others = other_addons(bridge)
        now = time.monotonic()
        if bridge.helpers_checked_at is None or now - bridge.helpers_checked_at >= settings.HELPER_CHECK_SECONDS:
            bridge.helpers_changed = addonfiles.tampered_addons(bridge.wow_dir, bridge.addon_copy)
            bridge.helpers_checked_at = now
    except OSError as error:
        console.log(f"could not list addons: {error}")
        return f"Couldn't check which addons are installed, {stays_out}"
    if bridge.helpers_changed:
        return f"{bridge.helpers_changed[0]} has been changed, {stays_out} Close WoW and run the Prompt Peon installer again to repair it."
    if not others:
        return ""
    name = gametext.readable(others[0], 40)
    who = f"{name} isn't trusted yet" if len(others) == 1 else f"{name} and {len(others) - 1} more aren't trusted yet"
    command = trust_command(others[0]) if len(others) == 1 else None
    if command:
        return f"{who}, {stays_out} To trust it, run: {command}"
    return f"{who}, {stays_out} Close WoW, run the Prompt Peon installer again and say whether you trust {'it' if len(others) == 1 else 'them'}."


def refused_by_other_addons(bridge) -> str | None:
    try:
        others = other_addons(bridge)
        changed = addonfiles.tampered_addons(bridge.wow_dir, bridge.addon_copy)
    except OSError as error:
        console.log(f"could not list addons: {error}")
        return "failed: could not check which addons are installed, so nothing was sent"
    if changed:
        return (f"failed: {changed[0]} has been changed, so it could be something else now. "
                "Run the Prompt Peon installer again to repair it")
    if not others:
        return None
    command = trust_command(others[0]) if len(others) == 1 else None
    if command:
        return f"failed: {others[0]} is installed, and any addon could send through Prompt Peon. To trust it, run: {command}"
    return (f"failed: {others[0]} is installed, and any addon could send through Prompt Peon. "
            "Run the Prompt Peon installer again to say whether you trust it")
