"""Sound files that tell the game there is news, so it doesn't have to look on a timer to find out.

An addon can't read a file, but it can play a sound and ask whether it is really playing. An empty
file doesn't play. So one of eight "bells" is a real, silent sound and the rest are empty, and
which one is real says how many times the bell has rung. The game knows the count of the snapshot
it has. If that count's bell has gone quiet, a newer snapshot is waiting, and it loads it at once.

Measured on WoW Forever on 2026-11-13: the game reads a sound file from disk again on every play
when it is this big, so a change shows within one listen, with no reload. The idea is Ryan
Hughes's, from t3code-wow.
"""
from __future__ import annotations

import json
import struct
from pathlib import Path

from . import console, safefiles, settings


def silence() -> bytes:
    """Ten seconds of silence as a WAV. Big on purpose: the game keeps small sounds in memory and
    would never look at the file again."""
    data = b"\x00\x00" * (settings.BELL_SECONDS * settings.BELL_RATE)
    header = struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", 36 + len(data), b"WAVE", b"fmt ", 16, 1, 1,
                         settings.BELL_RATE, settings.BELL_RATE * 2, 2, 16, b"data", len(data))
    return header + data


def bell(folder: Path, count: int) -> Path:
    return folder / f"b{count % settings.BELL_COUNT + 1}.wav"


def is_ours(path: Path) -> bool:
    """A plain file with one name. A link, or a file that is also something else's (a hard link),
    isn't a bell we made, and gets replaced before anything is written."""
    try:
        return not safefiles.is_link(path) and path.is_file() and path.stat().st_nlink == 1
    except OSError:
        return False


def make(folder: Path) -> bool:
    """The files the game listens to: one that always plays, so the game can tell its sound is on,
    and the bells. Made by the installer, and again by the companion app if they are missing.
    A bell that is already there is left as it is, so the count survives."""
    try:
        if not folder.parent.is_dir():
            return False
        safefiles.own_folder(folder)
        always = folder / "on.wav"
        if not is_ours(always) or always.stat().st_size == 0:
            safefiles.write_binary_atomic(always, silence())
        for count in range(settings.BELL_COUNT):
            path = bell(folder, count)
            if not is_ours(path):
                safefiles.write_binary_atomic(path, b"")
        return True
    except OSError as error:
        console.log(f"couldn't set up the update bells, so the game looks on its timer: {error}")
        return False


def rung(folder: Path) -> int:
    """Which bell is real right now, so a companion app that restarts carries on from there."""
    for count in range(settings.BELL_COUNT):
        try:
            path = bell(folder, count)
            if is_ours(path) and path.stat().st_size > 0:
                return count
        except OSError:
            continue
    return 0


def ring(folder: Path, count: int) -> bool:
    """Make `count`'s bell the real one and the others empty. The new one first, so there is never
    a moment with none, which the game would read as news it then can't find.

    Every write makes a new file and swaps it in. Nothing already there is ever opened to be
    written into, so a link or a hard link put in a bell's place can't aim this at another file."""
    try:
        if not make(folder):
            return False
        safefiles.write_binary_atomic(bell(folder, count), silence())
        for other in range(settings.BELL_COUNT):
            path = bell(folder, other)
            if other != count % settings.BELL_COUNT and path.stat().st_size > 0:
                safefiles.write_binary_atomic(path, b"")
        return True
    except OSError as error:
        console.log(f"couldn't ring the update bell: {error}")
        return False


def shape(snapshot: dict) -> tuple[str, frozenset]:
    """What is worth telling the game about at once, in two parts. The first is every thread's
    state, in an order that doesn't depend on who wrote last: two agents taking turns being newest
    is not news. The second is what you asked for that is here now, such as a diff."""
    def of(row: dict) -> list:
        return [str(row.get("id")), row.get("s"), row.get("pk"), bool(row.get("uq")), bool(row.get("hd"))]
    rows = (snapshot.get("threads") or []) + (snapshot.get("pk") or [])
    state = json.dumps([sorted((of(row) for row in rows), key=json.dumps),
                        bool(snapshot.get("err")), bool(snapshot.get("lk")), bool(snapshot.get("yo")), bool(snapshot.get("quiet"))])
    asked = frozenset((str(row.get("id")), field) for row in rows for field in settings.LOADED_FIELDS if field in row)
    return state, asked


def is_news(before: tuple[str, frozenset] | None, now: tuple[str, frozenset]) -> bool:
    """Whether to ring. A thread changed state, or something you asked for arrived. Something you
    asked for going away again a minute later isn't news: the game already has it."""
    return before is None or before[0] != now[0] or bool(now[1] - before[1])
