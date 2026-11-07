"""The command line: install, uninstall, start-stop, run, once, status and link."""
from __future__ import annotations

import argparse
import os
import sys
import urllib.error
from pathlib import Path

from . import (
    autostart, bridgestate, delivery, installer, loop, pairing, processes, prompts, refreshing, servers, settings, threadstate,
    uninstaller, userconfig,
)


def main() -> None:
    if sys.version_info < (3, 10):
        sys.exit("Prompt Peon needs Python 3.10 or newer. Get it from https://www.python.org/downloads/ and run this again.")
    # A Windows console can't print every character in a thread title. Don't crash on one.
    if sys.stdout is not None and hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(errors="replace")
    parser = argparse.ArgumentParser(description="Prompt Peon bridge: a T3 Code remote client whose only link to WoW is files.")
    sub = parser.add_subparsers(dest="command", required=True)
    install = sub.add_parser("install", help="install the addon and save where T3 lives")
    install.add_argument("--wow-dir")
    install.add_argument("--client", choices=["era", "retail", "forever"], help="needed when more than one is installed")
    install.add_argument("--link", help="a pairing link from T3. Asked for if needed")
    install.add_argument("--url", help="T3's address, when you use a token instead of a link")
    install.add_argument("--pictures", dest="pictures", action="store_true", default=None,
                         help="let the companion app read files on the T3 machine, to show pictures. Asked for if needed")
    install.add_argument("--no-pictures", dest="pictures", action="store_false", help="leave file reading off")
    install.add_argument("--full-access", dest="full_access", action="store_true", default=None,
                         help="let the game send to, and start, agents that act without asking")
    install.add_argument("--no-full-access", dest="full_access", action="store_false", help="don't. This is the default")
    install.add_argument("--also-local", dest="also_local", action="store_true", default=None,
                         help="with your main T3 on another machine, show the threads of the T3 on this machine too")
    install.add_argument("--no-also-local", dest="also_local", action="store_false", help="show only the main T3's threads")
    install.add_argument("--no-start", action="store_true", help="don't start the companion app or set it to start with this machine")
    install.add_argument("--allow-unencrypted", action="store_true", help="use a plain http address on a network without asking")
    install.add_argument("--no-update", action="store_true", help="use this copy, without asking GitHub for a newer one")
    remove = sub.add_parser("uninstall", help="remove the addon, the companion app, your token and all saved data")
    remove.add_argument("--yes", action="store_true", help="don't ask first")
    install.add_argument("--addon-source", default=str(settings.PROGRAM_DIR.parent / "addon" / settings.ADDON))
    sub.add_parser("start-stop", help="turn the companion app off if it's running, and on if it isn't")
    run_parser = sub.add_parser("run", help="run the companion app")
    run_parser.add_argument("--always", action="store_true", help="dial T3 even when the game is closed")
    once = sub.add_parser("once", help="refresh once, deliver any outbox, print what happened")
    once.add_argument("--quiet", action="store_true")
    sub.add_parser("status", help="check the connection to T3")
    sub.add_parser("link", help="on the T3 machine: make a one-time link for a game somewhere else, over T3 Connect")
    args = parser.parse_args()

    if args.command == "link":
        sys.exit(pairing.make_link())
    if args.command == "install":
        installer.install(args)
        return
    if args.command == "start-stop":
        print(autostart.start_stop())
        return

    if args.command == "uninstall":
        saved_wow = userconfig.read_config().get("wow_dir")
        if not args.yes and not prompts.ask("Remove Prompt Peon, your token and all its saved data? [y/N]: ").lower().startswith("y"):
            sys.exit("Nothing changed.")
        uninstaller.uninstall(Path(saved_wow) if saved_wow else None)
        return

    config = userconfig.read_config()
    if not config.get("url"):
        sys.exit("Not set up yet. Run the installer first.")
    remote = servers.from_config(config)
    bridge = bridgestate.Bridge(Path(config["wow_dir"]), remote)
    bridge.addon_copy = settings.HOME_DIR / "addon" / settings.ADDON
    if args.command == "run":
        lock = processes.acquire_lock(settings.STATE_DIR / "bridge.lock")
        if lock is None:
            sys.exit("The companion app is already running.")
        (settings.STATE_DIR / "bridge.pid").write_text(str(os.getpid()))
        loop.run(bridge, always=args.always)
    elif args.command == "once":
        lock = processes.acquire_lock(settings.STATE_DIR / "bridge.lock")
        if lock is None:
            sys.exit("The companion app is already running. Use status to check the connection.")
        delivery.poll_outbox(bridge)
        refreshing.refresh(bridge)
        threads = (bridge.snapshot or {}).get("threads", [])
        print(f"threads: {len(threads)}  error: {bridge.error or 'none'}  ack: {bridge.state['ack']}")
        if not args.quiet:
            for row in threads:
                print(f"  [{row['s']:7}] {row['p']}: {row['t']}")
    elif args.command == "status":
        try:
            threads = threadstate.active_threads(remote.shell())
            print(f"Connected to {remote.url}. {len(threads)} open threads.")
            for name, server in getattr(remote, "servers", [])[1:]:
                print(f"Also {name} at {server.url}: {remote.down.get(name) or 'answering'}")
        except urllib.error.HTTPError as error:
            sys.exit(f"T3 answered {error.code}. Your link may have expired: run the installer again.")
        except (OSError, urllib.error.URLError) as error:
            sys.exit(f"Can't reach {remote.url}: {error}")
