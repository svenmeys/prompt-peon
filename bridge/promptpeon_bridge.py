#!/usr/bin/env python3
"""Prompt Peon bridge: a T3 Code remote client whose only link to WoW is files.

A WoW addon has no sockets and no file access. So this process sits next to the
game and dials T3 on another machine:

    T3 server  <-- HTTP + WebSocket, scoped token -->  bridge  <-- two files -->  addon

Into the game: Snapshot.lua, a data-only Lua file. Refresh slots read it live.
Out of the game: AddOns.txt. The game rewrites it the moment the addon saves its addon
list, so 96 "send" addons work as 96 bits per write, with no reload and nothing shown.
SavedVariables is the fallback for a reply that could not get out that way.

Stdlib only, because this has to run on a stock SteamOS machine or a Windows PC with nothing
but Python on it. The token lives in the user's config folder and is never written
anywhere the game can read.

This file only starts the program, which is in the promptpeon folder next to it. The installers,
Windows autostart, the Linux service, the updater and stopping a running copy all know it by this
name, so keep the name.
"""
import sys
from pathlib import Path

# Compiled files beside the program would be one more thing that runs as us, and nothing here needs them.
sys.dont_write_bytecode = True
# This runs under python -I, so its folder isn't on the path. At the end, so the standard library always wins.
sys.path.append(str(Path(__file__).resolve().parent))

from promptpeon.cli import main  # noqa: E402

if __name__ == "__main__":
    main()
