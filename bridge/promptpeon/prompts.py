"""The questions the installer asks you."""
from __future__ import annotations

import json
import sys
from pathlib import Path

from . import addonfiles, processes, safefiles, screen, settings, userconfig


def ask_about_other_addons(*wow_dirs: Path) -> None:
    """The one question that matters most: WoW lets every addon read and send what we do."""
    config = userconfig.read_config()
    trusted = list(config.get("trusted_addons") or [])
    others = sorted({name for wow_dir in wow_dirs for name in addonfiles.other_addons_in(wow_dir, trusted)})
    if not others:
        screen.ok("No new addons to ask about.")
        return
    names = ", ".join(others[:6]) + (f" and {len(others) - 6} more" if len(others) > 6 else "")
    if trusted:
        screen.say(f"You have a new addon: {names}." if len(others) == 1 else f"You have new addons: {names}.")
    else:
        screen.say(f"You have other addons installed: {names}.")
    screen.say("\nWoW gives every addon access to the same things. Any of these could read your threads, and send messages to your agents through Prompt Peon, even agents with full access.")
    screen.say("\nSay yes and everything works. It stays that way when these addons update, and this only asks again if a new one appears. Say no and the game shows thread names and status, but no thread text, and sending stays off.")
    screen.say("\nEither way they can use up the game's refreshes and change what you see, so don't install addons you don't trust at all.\n")
    if sys.stdin.isatty() and ask("Do you trust all of them with that? [y/N]: ").lower().startswith("y"):
        settings.CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        safefiles.write_atomic(settings.CONFIG_DIR / "config.json", json.dumps(dict(config, trusted_addons=trusted + others), indent=2))


def ask(prompt: str) -> str:
    try:
        return input(screen.question(prompt)).strip()
    except EOFError:
        return ""


def choose_clients(found: list[Path], saved: list[Path]) -> list[Path]:
    """Which WoW clients get Prompt Peon. You choose when there's more than one. Pressing Enter keeps what you
    have, or takes them all the first time. With nobody there to ask, it does the same."""
    clients = list(dict.fromkeys([*saved, *found]))
    current = [client for client in clients if client in saved] or clients
    if len(clients) < 2 or not sys.stdin.isatty():
        return current
    screen.say("Prompt Peon can go in any of these, and the companion app follows whichever game you open:\n")
    for number, client in enumerate(clients, 1):
        screen.say(f"  {number}. [{'x' if client in current else ' '}] {settings.CLIENT_NAMES.get(client.name, client.name)}: {client}")
    screen.say()
    for _ in range(3):
        answer = ask("Type the numbers you want, like 1 3, or press Enter to keep the ticked ones: ")
        if not answer:
            return current
        picks = answer.replace(",", " ").split()
        if picks and all(pick.isdigit() and 1 <= int(pick) <= len(clients) for pick in picks):
            chosen = {int(pick) for pick in picks}
            return [client for number, client in enumerate(clients, 1) if number in chosen]
        screen.say(f"That didn't work. Use numbers from 1 to {len(clients)}.")
    return current


def wants_full_access(choice: bool | None) -> bool:
    """Whether the game may send to agents that act without asking. Asked once. Off unless you say so."""
    if choice is not None:
        return choice
    saved = userconfig.read_config().get("full_access")
    if saved is True:
        screen.say("Sending to and starting agents with full access is on. To turn it off, run this again with --no-full-access.")
        return True
    if not sys.stdin.isatty():
        return False
    screen.say("\nSome agents run with full access: they can change anything on the T3 machine without asking. Let the game send messages to those, and start new ones? Any addon you trust could then do it too.")
    screen.say("\nSay no and you can still read them, stop them and turn them in. Agents that ask first are never affected.\n")
    return ask("Let the game send to and start agents with full access? [y/N]: ").lower().startswith("y")


def wants_pictures(choice: bool | None) -> bool:
    if choice is not None:
        return choice
    if not sys.stdin.isatty():
        return False
    screen.say("\nShow pictures from threads in the game, like screenshots an agent looked at? This lets the companion app fetch any picture on the T3 machine that it's asked for, not only ones in your projects, and shows them in the game. Anyone who got hold of your token could fetch them too. Everything else works without it.\n")
    return ask("Turn pictures on? [y/N]: ").lower().startswith("y")


def wait_for_game_to_close(wow_dir: Path) -> None:
    """Better to hear this first than after answering everything. A deploy with nobody there carries on."""
    if not sys.stdin.isatty() or not processes.game_running(wow_dir):
        return
    ask("WoW is open. Close it, then press Enter: ")
    if processes.game_running(wow_dir):
        sys.exit("WoW is still open. Close it and run this again.")
