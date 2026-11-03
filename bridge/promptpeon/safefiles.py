"""Reading and writing files in places other programs can reach. These never write through a link."""
from __future__ import annotations

import os
import shutil
import tempfile
import time
from pathlib import Path

from . import console, settings


def write_binary_atomic(path: Path, data: bytes) -> None:
    """Replace a file in one step, so the game never reads half of it. The temporary name is random
    and made exclusively, and a link at `path` gets replaced, never followed. So a link somebody
    prepared in a shared folder can't aim this at another file."""
    descriptor, temp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
    except BaseException:
        Path(temp).unlink(missing_ok=True)
        raise
    for attempt in range(10):
        try:
            os.replace(temp, path)
            return
        except PermissionError:
            # Windows refuses while another program has the file open. It clears in a moment.
            if attempt == 9:
                Path(temp).unlink(missing_ok=True)
                raise
            time.sleep(0.05)


def write_atomic(path: Path, content: str) -> None:
    write_binary_atomic(path, content.encode("utf-8"))


def is_link(path: Path) -> bool:
    """A symlink, or on Windows any reparse point, which includes junctions on every Python we support."""
    if path.is_symlink():
        return True
    try:
        return bool(getattr(os.lstat(path), "st_file_attributes", 0) & 0x400)
    except OSError:
        return False


def own_folder(path: Path) -> None:
    """A folder that's ours by name. If it's a link, it isn't really ours, so it goes."""
    if is_link(path):
        try:
            path.unlink()
        except OSError:
            os.rmdir(path)  # A Windows junction.
    path.mkdir(exist_ok=True)


def write_in_place(path: Path, content: str) -> bool:
    if is_link(path):
        console.log(f"{path.name} is a link, so it won't be written. Run the installer again.")
        return False
    return _write_in_place(path, content)


def _write_in_place(path: Path, content: str) -> bool:
    """Overwrite a file without replacing it, so every hard link to it sees the new data.

    Not atomic. If the game reads halfway through, Lua rejects it, the addon keeps what it had,
    and that one helper is used up until the next reload.
    """
    try:
        with path.open("r+b") as handle:
            handle.write(content.encode("utf-8"))
            handle.truncate()
        return True
    except PermissionError:
        console.log("snapshot is busy, trying again next time")
        return False


def read_shared(path: Path) -> str:
    """Read a file the game writes, without ever getting in the way of its next write."""
    if path.stat().st_size > settings.MAX_GAME_FILE_BYTES:
        raise OSError(f"{path.name} is too big to be ours")
    if not settings.IS_WINDOWS:
        return path.read_text(encoding="utf-8", errors="replace")
    # A plain open on Windows would stop the game from replacing the file while we read it.
    import ctypes
    import msvcrt
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateFileW.restype = wintypes.HANDLE
    kernel32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
                                     wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    generic_read, share_all, open_existing = 0x80000000, 0x7, 3
    handle = kernel32.CreateFileW(str(path), generic_read, share_all, None, open_existing, 0, None)
    if handle == wintypes.HANDLE(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    with os.fdopen(msvcrt.open_osfhandle(handle, os.O_RDONLY), "rb") as stream:
        return stream.read().decode("utf-8", "replace")


def remove_path(path: Path) -> None:
    if is_link(path) or not path.is_dir():
        path.unlink()
    else:
        shutil.rmtree(path)
