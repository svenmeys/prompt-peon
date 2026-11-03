"""Shared pieces for the companion app tests: fakes, fixtures and how to make a frame."""
import shutil
import struct
import sys
import tempfile
import unittest
import urllib.error
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(ROOT / "bridge"))
if sys.version_info < (3, 14):
    sys.exit("These tests need Python 3.14 or newer, the same as the installer. Try: python3.14 tests/test_bridge.py")
from promptpeon import bridgestate, diffs, frames, pngtga, settings, timeline  # noqa: E402


THREAD = "1f7743e2-3c60-4348-88a5-7b9f3d6c00b0"
needs_luajit = unittest.skipUnless(shutil.which("luajit"), "luajit is not installed")


def thread(**extra):
    base = {"id": THREAD, "projectId": "p1", "title": "A thread", "status": "completed",
            "updatedAt": "2026-11-02T16:00:00.000Z", "runtimeMode": "approval-required",
            "interactionMode": "default", "lineage": {"parentThreadId": None}, "settledAt": None}
    base.update(extra)
    return base


SHELL = {"threads": [thread()], "projects": [{"id": "p1", "title": "Shop"}]}


def outbox(*entries):
    body = ";".join(f"{seq}:{tid.encode().hex()}:{text.encode().hex()}" for seq, tid, text in entries)
    return f'PromptPeonDB = {{\n["nextSeq"] = 9,\n}}\nPromptPeonOutbox = "{body}"\n'


class Crash(BaseException):
    """The bridge process dying at the worst moment. Nothing inside it can catch this."""


class FakeRemote:
    url = "http://mac:3773"

    def __init__(self, shell=SHELL, send=None):
        self._shell, self.sent, self._send = shell, [], send

    def shell(self):
        if isinstance(self._shell, Exception):
            raise self._shell
        return self._shell

    def detail(self, thread_id):
        if thread_id == "odd":
            raise urllib.error.HTTPError("u", 500, "boom", None, None)
        return timeline.describe_thread({"turnItems": [
            {"type": "user_message", "text": "hi", "status": "completed", "ordinal": 1},
            {"type": "reasoning", "text": "my thoughts", "status": "completed", "ordinal": 2},
            {"type": "command_execution", "input": "ls -la", "status": "completed", "ordinal": 3, "output": "SECRET OUTPUT"},
            {"type": "assistant_message", "text": "**done**", "status": "completed", "ordinal": 4},
        ]})

    def send_reply(self, row, text, message_id=None):
        if self._send:
            raise self._send
        self.sent.append((row["id"], text))
        self.last_message_id = message_id
        if getattr(self, "crash_after_send", False):
            raise Crash()
        return message_id or "m1"

    def has_message(self, thread_id, message_id):
        if getattr(self, "lookup_fails", False):
            raise OSError("no route")
        return message_id in getattr(self, "known_messages", set())


def split_diff(diff):
    return diffs.fit_patches(diffs.parse_diff(diff))


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.dir = Path(self.tmp.name)
        self.wow = self.dir / "_forever_"
        (self.wow / "Interface/AddOns/PromptPeon").mkdir(parents=True)

    def tearDown(self):
        self.tmp.cleanup()

    def bridge(self, remote):
        return bridgestate.Bridge(self.wow, remote, state_dir=self.dir / "state", in_place=False)


def make_png(width, height, colour=6, filter_kind=0, depth=8, palette=None, interlace=0):
    """A real PNG, built by hand, with a known colour at every pixel."""
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colour]
    step = channels * depth // 8
    stride = width * step
    raw, previous = bytearray(), bytearray(stride)
    for y in range(height):
        row = bytearray()
        for x in range(width):
            value = [(x * 10) % 256, (y * 10) % 256, 200, 255][:channels] if colour != 3 else [x % 2]
            for channel in value:
                row.append(channel)
                if depth == 16:
                    row.append(0)
        encoded = bytearray(stride)
        for i in range(stride):
            left = row[i - step] if i >= step else 0
            up = previous[i]
            corner = previous[i - step] if i >= step else 0
            if filter_kind == 1:
                encoded[i] = (row[i] - left) & 255
            elif filter_kind == 2:
                encoded[i] = (row[i] - up) & 255
            elif filter_kind == 3:
                encoded[i] = (row[i] - ((left + up) >> 1)) & 255
            elif filter_kind == 4:
                p = left + up - corner
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - corner)
                encoded[i] = (row[i] - (left if pa <= pb and pa <= pc else up if pb <= pc else corner)) & 255
            else:
                encoded[i] = row[i]
        raw.append(filter_kind)
        raw += encoded
        previous = row

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))

    out = pngtga.PNG_SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, depth, colour, 0, 0, interlace))
    if palette:
        out += chunk(b"PLTE", palette)
    return out + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b"")


class FakeImages:
    def __init__(self, data=None, error=None):
        self.data, self.error, self.calls = data or make_png(8, 8), error, []

    def image_bytes(self, thread_id, reference):
        self.calls.append(reference)
        if self.error:
            raise self.error
        return self.data


def picture_row(path, order=1):
    return ["i", path.rsplit("/", 1)[-1], "d", order, {"p": path}]


class CommandRemote(FakeRemote):
    def __init__(self, shell=None):
        super().__init__(shell=shell or {
            "threads": [thread(modelSelection={"instanceId": "claudeAgent", "model": "m"})],
            "projects": [{"id": "p1", "title": "Shop"}],
        })
        self.calls = []

    def stop_thread(self, thread_id):
        self.calls.append(("stop", thread_id))

    def settle_thread(self, thread_id):
        self.calls.append(("settle", thread_id))

    def cancel_queued(self, thread_id, run_id):
        self.calls.append(("cancelq", thread_id, run_id))

    def edit_queued(self, thread_id, run_id, text):
        self.calls.append(("editq", thread_id, run_id, text))

    def unsettle_thread(self, thread_id):
        self.calls.append(("unsettle", thread_id))

    def start_thread(self, project_id, model, text, runtime_mode):
        self.calls.append(("new", project_id, model["model"], text))
        self.modes = getattr(self, "modes", []) + [runtime_mode]
        return "t2"

    def thread_diff(self, thread_id):
        self.calls.append(("diff", thread_id))
        return "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -0,0 +1 @@\n+new"


def command(seq, target, words):
    return {"seq": seq, "thread": target, "text": "\x01" + words}


def python_frames(seq, thread_id, text):
    raw = text.encode()
    body = bytes([1]) + seq.to_bytes(3, "big") + bytes([len(thread_id)]) + thread_id.encode() + len(raw).to_bytes(2, "big") + raw
    message = body + zlib.crc32(body).to_bytes(4, "big")
    sent_frames = []
    for index, start in enumerate(range(0, len(message), 10)):
        data = bytes([(index & 0x7F) | (0x80 if start == 0 else 0)]) + message[start:start + 10].ljust(10, b"\0")
        sent_frames.append(bytes([frames.crc8(data)]) + data)
    return sent_frames


def addons_txt(frame=None):
    """AddOns.txt as the game writes it, with these bits set as disabled."""
    frame = frame or bytes(settings.OUT_COUNT // 8)
    lines = ["PromptPeon: enabled", "SomeOtherAddon: disabled"]
    for number in range(1, settings.OUT_COUNT + 1):
        on = frame[(number - 1) // 8] & (1 << ((number - 1) % 8))
        lines.append(f"PromptPeonOut{number:02d}: {'disabled' if on else 'enabled'}")
    return "\r\n".join(lines) + "\r\n"
