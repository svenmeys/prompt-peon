"""Reading and cleaning the addon's SavedVariables file, which the game writes. It is never run as Lua."""
from __future__ import annotations

import re
from pathlib import Path

from . import console, safefiles, settings


OUTBOX_RE = re.compile(r'^PromptPeonOutbox = "([0-9a-zA-Z:;\-]*)"\s*$', re.M)
ENTRY_RE = re.compile(r"^(\d{1,9}):((?:[0-9a-f]{2}){1,200}):((?:[0-9a-f]{2})+)$")


def good_thread_id(thread: str) -> bool:
    """T3 only promises non-empty text, and uses colons in some. Keep equal to ns:Enqueue."""
    return 0 < len(thread.encode("utf-8")) <= 200 and not re.search(r"[\s\x00-\x1f|]", thread)


def parse_outbox(saved_variables: str) -> tuple[list[dict], list[str]]:
    """Pull replies out of a SavedVariables file. Never executes it.

    The addon stores the outbox as one string of seq:hex thread:hex text entries, so this
    is a strict pattern match rather than a Lua parser. Anything else in the file
    is ignored and anything malformed is reported, not guessed at.
    """
    # The last match, because the game writes this global after the DB table, and a
    # draft inside that table could contain a line that looks just like it.
    matches = OUTBOX_RE.findall(saved_variables)
    if not matches or not matches[-1]:
        return [], []
    raw = matches[-1]
    if len(raw) > settings.MAX_OUTBOX_CHARS:
        return [], ["outbox too large, ignored"]
    entries, rejected = [], []
    for part in raw.split(";"):
        if not part:
            continue
        found = ENTRY_RE.match(part)
        if not found:
            rejected.append(f"malformed entry: {part[:32]}")
            continue
        try:
            thread = bytes.fromhex(found.group(2)).decode("utf-8")
            text = bytes.fromhex(found.group(3)).decode("utf-8")
        except ValueError:
            rejected.append(f"seq {found.group(1)}: not valid text")
            continue
        if not good_thread_id(thread):
            rejected.append(f"seq {found.group(1)}: not a thread")
            continue
        entries.append({"seq": int(found.group(1)), "thread": thread, "text": text})
    entries.sort(key=lambda entry: entry["seq"])
    return entries, rejected


LUA_KEY_RE = re.compile(r'\s*\["((?:[^"\\]|\\.)*)"\]\s*=\s*', re.S)
LUA_STRING_RE = re.compile(r'"(?:[^"\\]|\\.)*"', re.S)
LUA_SIMPLE_RE = re.compile(r"[^\s,{}\"]+")
LUA_SPACE_RE = re.compile(r"\s*")
SAVED_OUTBOX_RE = re.compile(r'^PromptPeonOutbox = "(?:[^"\\]|\\.)*"', re.M | re.S)


def lua_value_end(text: str, start: int) -> int | None:
    """Where the value starting here ends, or None if it doesn't. Reads it and never runs it."""
    if text[start:start + 1] == '"':
        found = LUA_STRING_RE.match(text, start)
        return found.end() if found else None
    if text[start:start + 1] != "{":
        found = LUA_SIMPLE_RE.match(text, start)
        return found.end() if found else None
    depth, at = 0, start
    while at < len(text):
        if text[at] == '"':
            found = LUA_STRING_RE.match(text, at)
            if not found:
                return None
            at = found.end()
            continue
        if text.startswith("--", at):
            at = text.find("\n", at)
            if at < 0:
                return None
        elif text[at] == "{":
            depth += 1
        elif text[at] == "}":
            depth -= 1
            if depth == 0:
                return at + 1
        at += 1
    return None


def without_typed_words(saved: str) -> str | None:
    """A SavedVariables file with no drafts or unsent messages, and otherwise byte for byte the same.
    None if it isn't shaped the way the game writes it, so it gets left alone rather than damaged."""
    table = re.search(r"^PromptPeonDB = \{", saved, re.M)
    if not table:
        return SAVED_OUTBOX_RE.sub('PromptPeonOutbox = ""', saved)
    at, keep, kept_from = table.end(), [], table.start()
    while True:
        spaces = LUA_SPACE_RE.match(saved, at).end()
        if saved[spaces:spaces + 1] == "}":
            break
        key = LUA_KEY_RE.match(saved, at)
        end = lua_value_end(saved, key.end()) if key else None
        if end is None:
            return None
        comma = LUA_SPACE_RE.match(saved, end).end()
        after = comma + 1 if saved[comma:comma + 1] == "," else end
        if key.group(1) in settings.TYPED_WORDS:
            keep.append(saved[kept_from:at])
            kept_from = after
        at = after
    table_end = spaces + 1
    keep.append(saved[kept_from:table_end])
    empty = 'PromptPeonOutbox = ""'
    return SAVED_OUTBOX_RE.sub(empty, saved[:table.start()]) + "".join(keep) + SAVED_OUTBOX_RE.sub(empty, saved[table_end:])


def clear_typed_words(path: Path) -> bool:
    """False if the file was left as it was because we couldn't follow it."""
    if path.stat().st_size > settings.MAX_GAME_FILE_BYTES:
        console.log(f"{path.name} is too big to be ours, so it was left alone")
        return False
    # Latin-1 keeps every byte as it was, and every character this looks at is plain ASCII.
    saved = path.read_bytes().decode("latin-1")
    clean = without_typed_words(saved)
    if clean is None:
        console.log(f"{path.name} isn't shaped as expected, so it was left alone")
        return False
    if clean != saved:
        safefiles.write_binary_atomic(path, clean.encode("latin-1"))
    return True
