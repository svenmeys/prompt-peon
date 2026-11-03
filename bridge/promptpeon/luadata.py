"""Writing plain data as Lua. Everything that came from a thread goes through this, so text stays data."""
from __future__ import annotations

import math
import re


LUA_UNSAFE = re.compile(rb'[^\x20-\x7e]|["\\]')  # A regex, because snapshots run to megabytes.
LUA_ESCAPES = {bytes([byte]): (f"\\{chr(byte)}" if byte in (0x22, 0x5C) else f"\\{byte:03d}").encode() for byte in range(256)}


def lua_string(value: str) -> str:
    """A Lua string literal. Everything that came from a thread goes through this.

    Bytes outside printable ASCII become decimal escapes, so no thread text can
    close the string or start a new statement, whatever it contains.
    """
    escaped = LUA_UNSAFE.sub(lambda found: LUA_ESCAPES[found.group()], str(value).encode("utf-8", "replace"))
    return '"' + escaped.decode("ascii") + '"'


def lua_value(value) -> str:
    """Serialize plain data. Keys are ours, and must be plain Lua names."""
    if value is None:
        return "nil"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, float) and not math.isfinite(value):
        return "0"  # JSON from T3 can say Infinity or NaN. Written as they are, the game can't load the file.
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return lua_string(value)
    if isinstance(value, (list, tuple)):
        return "{" + ",".join(lua_value(item) for item in value) + "}"
    if isinstance(value, dict):
        parts = []
        for key, item in value.items():
            if isinstance(key, int):
                parts.append(f"[{key}]={lua_value(item)}")
            elif re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
                parts.append(f"{key}={lua_value(item)}")
            elif re.fullmatch(r"\d{1,9}", key):  # Reply results, keyed by sequence number.
                parts.append(f"[{lua_string(key)}]={lua_value(item)}")
            else:
                raise ValueError(f"unsafe Lua key: {key!r}")
        return "{" + ",".join(parts) + "}"
    raise TypeError(f"cannot serialize {type(value).__name__}")
