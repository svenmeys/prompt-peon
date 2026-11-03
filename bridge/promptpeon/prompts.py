"""The questions the installer asks you."""
from __future__ import annotations

import json
import sys
from pathlib import Path

from . import addonfiles, processes, safefiles, settings, userconfig


def ask_about_other_addons(wow_dir: Path) -> None:
    """The one question that matters most: WoW lets every addon read and send what we do."""
    config = userconfig.read_config()
    trusted = list(config.get("trusted_addons") or [])
    others = addonfiles.other_addons_in(wow_dir, trusted)
    if not others:
        return
    names = ", ".join(others[:6]) + (f" and {len(others) - 6} more" if len(others) > 6 else "")
    if trusted:
        print(f"\nYou have a new addon: {names}." if len(others) == 1 else f"\nYou have new addons: {names}.")
    else:
        print(f"\nYou have other addons installed: {names}.")
    print("WoW gives every addon access to the same things. Any of these could read your threads, and")
    print("send messages to your agents through Prompt Peon, even agents with full access.")
    print("Say yes and everything works. It stays that way when these addons update, and this only asks")
    print("again if a new one appears. Say no and the game shows thread names and status, but no thread text,")
    print("and sending stays off. Either way they can use up the game's refreshes and change what you see,")
    print("so don't install addons you don't trust at all.")
    if sys.stdin.isatty() and ask("Do you trust all of them with that? [y/N]: ").lower().startswith("y"):
        settings.CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        safefiles.write_atomic(settings.CONFIG_DIR / "config.json", json.dumps(dict(config, trusted_addons=trusted + others), indent=2))


def ask(prompt: str) -> str:
    try:
        return input(prompt).strip()
    except EOFError:
        return ""


def wants_full_access(choice: bool | None) -> bool:
    """Whether the game may send to agents that act without asking. Asked once. Off unless you say so."""
    if choice is not None:
        return choice
    saved = userconfig.read_config().get("full_access")
    if saved is True:
        print("\nSending to and starting agents with full access is on. To turn it off, run this again with --no-full-access.")
        return True
    if not sys.stdin.isatty():
        return False
    print("\nSome agents run with full access: they can change anything on the T3 machine without asking.")
    print("Let the game send messages to those, and start new ones? Any addon you trust could then do it too.")
    print("Say no and you can still read them, stop them and turn them in. Agents that ask first are never affected.")
    return ask("Let the game send to and start agents with full access? [y/N]: ").lower().startswith("y")


def wants_pictures(choice: bool | None) -> bool:
    if choice is not None:
        return choice
    if not sys.stdin.isatty():
        return False
    print("\nShow pictures from threads in the game, like screenshots an agent looked at?")
    print("This lets the companion app fetch any picture on the T3 machine that it's asked for, not only")
    print("ones in your projects, and shows them in the game. Anyone who got hold of your token could")
    print("fetch them too. Everything else works without it.")
    return ask("Turn pictures on? [y/N]: ").lower().startswith("y")


def wait_for_game_to_close(wow_dir: Path) -> None:
    """Better to hear this first than after answering everything. A deploy with nobody there carries on."""
    if not sys.stdin.isatty() or not processes.game_running(wow_dir):
        return
    ask("WoW is open. Close it, then press Enter: ")
    if processes.game_running(wow_dir):
        sys.exit("WoW is still open. Close it and run this again.")
