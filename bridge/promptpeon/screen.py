"""What the installer looks like. Someone at a terminal gets colors and wrapped lines. Logs and pipes get plain text."""
from __future__ import annotations

import os
import shutil
import sys
import textwrap

INDENT = "  "
MAX_WIDTH = 80
GOLD, GREEN, BOLD, DIM, RESET = "\033[33m", "\033[32m", "\033[1m", "\033[2m", "\033[0m"
_windows_colors_on = False


def _enable_windows_colors() -> None:
    """Windows consoles need asking before they understand colors. If this fails, the codes would show, so it says so."""
    global _windows_colors_on
    if os.name != "nt" or _windows_colors_on:
        _windows_colors_on = True
        return
    import ctypes

    kernel = ctypes.windll.kernel32
    handle = kernel.GetStdHandle(-11)  # Standard output.
    mode = ctypes.c_ulong()
    if kernel.GetConsoleMode(handle, ctypes.byref(mode)) and kernel.SetConsoleMode(handle, mode.value | 4):  # Virtual terminal.
        _windows_colors_on = True


def _at_terminal() -> bool:
    return sys.stdout is not None and sys.stdout.isatty()


def _color(text: str, *styles: str) -> str:
    if not _at_terminal() or "NO_COLOR" in os.environ:
        return text
    _enable_windows_colors()
    if os.name == "nt" and not _windows_colors_on:
        return text
    return "".join(styles) + text + RESET


def _wrapped(line: str, hanging: int = 0) -> str:
    """One line, wrapped to the window and lined up. Addresses and commands never get broken in the middle.
    Color goes on afterwards, because its codes take up no room on screen."""
    if not line.strip():
        return ""
    lead = INDENT + line[:len(line) - len(line.lstrip())]
    width = min(shutil.get_terminal_size().columns, MAX_WIDTH) - 1
    return textwrap.fill(line.strip(), width=width, initial_indent=lead, subsequent_indent=lead + " " * hanging,
                         break_long_words=False, break_on_hyphens=False)


def say(text: str = "") -> None:
    """Words for the reader. Line breaks in the text stay where they are."""
    if sys.stdout is None:
        return
    if not _at_terminal():
        print(text)
        return
    for line in text.split("\n"):
        print(_wrapped(line))


def title(text: str) -> None:
    if sys.stdout is None:
        return
    if not _at_terminal():
        print(f"{text}\n{'=' * len(text)}\n\"Something need doing?\"\n")
        return
    print(f"\n{INDENT}{_color(text, BOLD, GOLD)}\n{INDENT}{_color('=' * len(text), GOLD)}\n{INDENT}{_color('\"Something need doing?\"', DIM)}\n")


def step(number: int, total: int, text: str) -> None:
    if sys.stdout is not None:
        print(f"\n{_color(f'[{number}/{total}] {text}', BOLD, GOLD)}")


def ok(text: str) -> None:
    """Good news, marked the way the tracker in the game marks a finished thread."""
    if sys.stdout is None:
        return
    if not _at_terminal():
        print(f"[ok] {text}")
        return
    print(_wrapped(f"[ok] {text}", hanging=5).replace("[ok]", _color("[ok]", GREEN), 1))


def done(text: str) -> None:
    if sys.stdout is None:
        return
    if not _at_terminal():
        print(f"\n{text}")
        return
    print("\n" + "\n".join(INDENT + _color(line.strip(), BOLD, GREEN) for line in _wrapped(text).split("\n")))


def question(text: str) -> str:
    return INDENT + _color(text, BOLD) if _at_terminal() else text
