"""Pictures from threads, written to the fixed set of files the game can show without a reload."""
from __future__ import annotations

import json
import queue
import struct
import threading
import zlib
from pathlib import Path

from . import console, pngtga, safefiles, settings, t3errors


class Previews:
    """Turns images in threads into picture files the game can show without a reload.

    The game reads a picture file the first time it is shown and caches it until the next
    reload. So a file must never be written twice in one UI session, or the log would show the
    wrong image. Files are used in a ring, and writing stops when one session has used them all.
    """

    def __init__(self, folder: Path, remote, state_path: Path | None = None, allow_files: bool = True):
        self.folder, self.remote, self.state_path = folder, remote, state_path
        self.allow_files = allow_files  # Your answer at install, whatever the token could do.
        self.ready: dict[str, dict] = {}  # image key -> {file, w, h}, or {error}.
        self.next_file = 1
        self.used_this_session = 0
        self.session_mark: float | None = None
        self.waiting: "queue.Queue[tuple[str, str, dict]]" = queue.Queue()
        self.queued: set[str] = set()
        self.tries: dict[str, int] = {}
        self.lock = threading.Lock()
        self.files_lock = threading.Lock()  # Writing a picture and clearing them all never overlap.
        self.generation = 0  # Moves on when the game closes, so work already under way gets dropped.
        self._load()

    def _load(self) -> None:
        """A bridge restart must not forget which files this game session has already used."""
        if not self.state_path:
            return
        try:
            saved = json.loads(self.state_path.read_text())
            self.ready = {key: entry for key, entry in saved["ready"].items() if "file" in entry}
            self.next_file = int(saved["next_file"])
            self.used_this_session = int(saved["used"])
            self.session_mark = saved["mark"]
        except (OSError, ValueError, KeyError, TypeError):
            pass

    def _save(self) -> None:
        if not self.state_path:
            return
        with self.lock:
            self.state_path.parent.mkdir(parents=True, exist_ok=True)
            safefiles.write_atomic(self.state_path, json.dumps({
                "ready": {key: entry for key, entry in self.ready.items() if "file" in entry},
                "next_file": self.next_file, "used": self.used_this_session, "mark": self.session_mark,
            }))

    @staticmethod
    def key(reference: dict) -> str:
        return reference.get("p") or f"attachment:{reference.get('a')}"

    def new_ui_session(self, mark: float) -> None:
        """Called with the time of the game's last SavedVariables write, which every reload moves."""
        if mark == self.session_mark:
            return
        self.session_mark = mark
        self.used_this_session = 0
        self._save()

    def prepare(self, thread_id: str, rows: list, wanted: bool) -> list:
        """Rows for the game: the newest images resolved, older ones gone, no server paths."""
        images = [row for row in rows if row[0] == "i"]
        keep = {id(row) for row in images[-settings.PREVIEWS_PER_THREAD:]} if wanted else set()
        out = []
        for row in rows:
            if row[0] != "i":
                out.append(row)
            elif id(row) in keep:
                out.append(self._resolve(thread_id, row))
        return out

    def _resolve(self, thread_id: str, row: list) -> list:
        kind, label, state, order, reference = row
        key = self.key(reference)
        found = self.ready.get(key)
        if found is None:
            name = reference.get("p") or reference.get("n") or ""
            if "a" not in reference and not self.allow_files:
                found = self.ready[key] = {"error": "This picture needs file access, which is off. Run the installer again to turn it on."}
            elif name and not name.lower().endswith(".png"):
                found = self.ready[key] = {"error": "Only PNG pictures can be previewed for now."}
            elif key not in self.queued:
                self.queued.add(key)
                self.waiting.put((thread_id, key, reference))
        if found is None:
            return [kind, label, state, order, 0, 0, 0, "Loading preview..."]
        if "error" in found:
            return [kind, label, state, order, 0, 0, 0, found["error"]]
        return [kind, label, state, order, found["file"], found["w"], found["h"], ""]

    def process_one(self, block: bool = False) -> bool:
        """Fetch and convert one waiting image. False when there was nothing to do."""
        generation = self.generation
        try:
            thread_id, key, reference = self.waiting.get(block=block, timeout=1 if block else None)
        except queue.Empty:
            return False
        self.queued.discard(key)
        if self.used_this_session >= settings.PREVIEW_FILES:
            # Not an error about the image, so it stays eligible after the next reload.
            self.ready[key] = {"error": "Reload the UI to free up more previews.", "retry": True}
            return True
        try:
            tga, width, height = pngtga.png_to_tga(self.remote.image_bytes(thread_id, reference))
            with self.files_lock:
                if generation != self.generation:
                    return True  # The game closed while this was on its way, so it stays out.
                number = self.next_file
                safefiles.write_binary_atomic(self.folder / f"p{number:02d}.tga", tga)
                self.next_file = number % settings.PREVIEW_FILES + 1
                self.used_this_session += 1
                # That file now holds this image, so anything it held before is gone.
                for other, entry in list(self.ready.items()):
                    if entry.get("file") == number:
                        del self.ready[other]
                self.ready[key] = {"file": number, "w": width, "h": height}
                self._save()
        except pngtga.ImageError as error:
            self.ready[key] = {"error": f"This picture is {error}."}
        except (struct.error, zlib.error, IndexError, MemoryError) as error:
            console.log(f"damaged picture {key[-40:]}: {error}")
            self.ready[key] = {"error": "This picture is damaged."}
        except (OSError, ValueError, KeyError, t3errors.SendRefused, t3errors.SendUncertain) as error:
            console.log(f"no preview for {key[-40:]}: {error}")
            if "missing required scope" in str(error):
                self.ready[key] = {"error": "This picture needs file access, which is off. Run the installer again to turn it on."}
            else:
                # T3 can answer "not found" as an agent reads a picture, then serve it a moment later.
                # So leave it to be asked for again, and only give up after a few tries.
                self.tries[key] = self.tries.get(key, 0) + 1
                if self.tries[key] >= settings.PREVIEW_TRIES:
                    self.ready[key] = {"error": "T3 could not send this picture."}
        return True

    def use_folder(self, folder: Path) -> None:
        """Another client from now on, whose game is starting a session of its own."""
        with self.files_lock:
            self.folder = folder
        self.clear_files()

    def clear_files(self, new_session: bool = True) -> None:
        """Blank every picture and drop work under way. While the game is still open, new_session=False
        keeps moving through the files, because it has cached the old ones until the next reload."""
        blank = pngtga.blank_tga()
        with self.files_lock:
            self.generation += 1
            while True:
                try:
                    self.waiting.get_nowait()
                except queue.Empty:
                    break
            self.queued.clear()
            for number in range(1, settings.PREVIEW_FILES + 1):
                picture = self.folder / f"p{number:02d}.tga"
                try:
                    # By content: a real 8x8 picture is exactly as long as a blank one.
                    if picture.exists() and picture.read_bytes() != blank:
                        safefiles.write_binary_atomic(picture, blank)
                except OSError as error:
                    console.log(f"could not clear a picture: {error}")
            self.ready = {}
            if new_session:
                self.next_file, self.used_this_session = 1, 0
            self._save()

    def forget_retryable(self) -> None:
        for key, entry in list(self.ready.items()):
            if entry.get("retry"):
                del self.ready[key]
