"""The fast way out of the game: replies arrive as on/off states of the send addons in AddOns.txt."""
from __future__ import annotations

import queue
import re
import threading
import time
import zlib
from pathlib import Path

from . import console, safefiles, savedvars, settings


CARRIER_RE = re.compile(r"^PromptPeonOut(\d{2}): (enabled|disabled)\s*$", re.M)


def crc8(data: bytes) -> int:
    """Starts from 0xA5, so an all-clear (all zero) frame can never look valid."""
    crc = 0xA5
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def parse_frame(addons_txt: str) -> bytes | None:
    """Read the send addons' on/off states as bytes. Nil when they are not all there or the check fails."""
    found = {int(number): state for number, state in CARRIER_RE.findall(addons_txt)}
    if any(number not in found for number in range(1, settings.OUT_COUNT + 1)):
        return None
    frame = bytearray(settings.OUT_COUNT // 8)
    for number in range(1, settings.OUT_COUNT + 1):
        if found[number] == "disabled":
            frame[(number - 1) // 8] |= 1 << ((number - 1) % 8)
    if crc8(bytes(frame[1:])) != frame[0]:
        return None
    return bytes(frame)


class Reassembler:
    """Join frames back into one reply. A gap throws the reply away; the addon sends it again."""

    def __init__(self):
        self.buffer = bytearray()
        self.expect: int | None = None
        self.last_frame: bytes | None = None

    def _reset(self) -> None:
        self.buffer = bytearray()
        self.expect = None

    def feed(self, frame: bytes) -> dict | None:
        # The file changes more than once per save, so the same frame can be read twice.
        if frame == self.last_frame:
            return None
        self.last_frame = frame
        head, payload = frame[1], frame[2:]
        index = head & 0x7F
        if head & 0x80:
            self.buffer = bytearray(payload)
            self.expect = 1
        elif self.expect is None:
            return None
        elif index != self.expect:
            console.log(f"send frame gap: wanted {self.expect}, got {index}")
            self._reset()
            return None
        else:
            self.buffer += payload
            self.expect = (index + 1) & 0x7F
        return self._complete()

    def _complete(self) -> dict | None:
        data = self.buffer
        if data[0] != 1:
            self._reset()
            return None
        if len(data) < 5 or len(data) < 5 + data[4] + 2:
            return None
        id_end = 5 + data[4]
        size = int.from_bytes(data[id_end:id_end + 2], "big")
        if size > settings.MAX_REPLY_BYTES:
            self._reset()
            return None
        total = id_end + 2 + size + 4
        if len(data) < total:
            return None
        body, check = bytes(data[:total - 4]), int.from_bytes(data[total - 4:total], "big")
        self._reset()
        if zlib.crc32(body) != check:
            console.log("send check failed, waiting for the resend")
            return None
        try:
            thread = body[5:id_end].decode("utf-8")
            text = body[id_end + 2:].decode("utf-8")
        except ValueError:
            return None
        if not savedvars.good_thread_id(thread):
            return None
        return {"seq": int.from_bytes(body[1:4], "big"), "thread": thread, "text": text}


class FrameReader(threading.Thread):
    """Watch AddOns.txt closely. Its own thread, so a slow network call can never miss a frame."""

    def __init__(self, wow_dir: Path, out: "queue.Queue[dict]"):
        super().__init__(daemon=True, name="frame-reader")
        self.wow_dir, self.out = wow_dir, out
        self.running_game = True
        self.assemblers: dict[Path, Reassembler] = {}  # One per file: accounts don't share frames.
        self.ready = threading.Event()  # Set once it has read what was already on disk.

    def paths(self) -> list[Path]:
        accounts = self.wow_dir / "WTF/Account"
        return list(accounts.glob("*/*/*/AddOns.txt")) + list(accounts.glob("*/AddOns.txt"))

    def take(self, path: Path, frame: bytes) -> dict | None:
        return self.assemblers.setdefault(path, Reassembler()).feed(frame)

    def run(self) -> None:
        seen: dict[Path, tuple[int, int]] = {}
        retried: dict[Path, tuple[int, int]] = {}
        known_paths: set[Path] = set()
        files: list[Path] = []
        next_scan = 0.0
        busy_until = 0.0
        first_pass = True
        while True:
            now = time.monotonic()
            if now >= next_scan:
                files = self.paths()
                next_scan = now + 2.0
            for path in files:
                try:
                    stat = path.stat()
                    key = (stat.st_mtime_ns, stat.st_size)
                    if seen.get(path) == key:
                        continue
                    text = safefiles.read_shared(path)
                except OSError:
                    continue
                known, seen[path] = path in seen or path in known_paths, key
                if first_pass or not known:
                    continue  # Whatever was already on disk is old news.
                frame = parse_frame(text)
                if frame is None:
                    # All clear, or read halfway through a write. Look once more to be sure.
                    if retried.get(path) != key:
                        retried[path] = key
                        del seen[path]
                        known_paths.add(path)
                    continue
                busy_until = now + 2.0
                message = self.take(path, frame)
                if message:
                    self.out.put(message)
            first_pass = False
            self.ready.set()
            if now < busy_until:
                time.sleep(0.004)
            else:
                time.sleep(0.02 if self.running_game else 0.5)
