"""What the companion app remembers while it runs, and what it saves between runs."""
from __future__ import annotations

import json
import os
import secrets
import time
import urllib.error
from pathlib import Path

from . import console, gametext, previews, safefiles, settings, t3errors, t3remote, threadstate


class Bridge:
    """The state of one running companion app. What it does with it lives in the modules that use it."""

    def __init__(self, wow_dir: Path, remote: t3remote.T3Remote, state_dir: Path = settings.STATE_DIR, in_place: bool = settings.IS_WINDOWS,
                 config_path: Path | None = None):
        self.wow_dir = wow_dir
        self.config_path = config_path or settings.CONFIG_DIR / "config.json"
        self.closed_at: float | None = None  # When the game closed, on the monotonic clock.
        self.game_closed = False  # Nothing with words in it goes in the game folder then.
        self.newer_release: str | None = None  # A newer version on GitHub, for the game to mention.
        self.read_times: list[float] = []
        self.addon_copy: Path | None = None  # Our own copy of the addon, to compare the installed one with.
        self.loaded: dict = {}  # Thread id -> a diff or agent reports you opened, for a minute.
        self.patches: dict = {}  # Every patch of the diff opened last, so paging needs no new call.
        self.pr_checks: dict = {}  # (repository, number) -> what CI said, and when we asked.
        self.catalog: list | None = None  # The models you can pick.
        self.catalog_at = 0.0
        self.in_place = in_place  # Windows slots are hard links, which a replaced file would break.
        self.remote = remote
        self.state_dir = state_dir
        self.snapshot_path = wow_dir / "Interface/AddOns" / settings.ADDON / "Snapshot.lua"
        self.state_path = state_dir / "state.json"
        self.audit_path = state_dir / "sent.log"
        self.state = self._load_state()
        self.shell: dict | None = None
        self.messages: dict = {}
        self.seen: dict = {}
        self.error = ""
        self.error_since = 0
        self.snapshot: dict | None = None
        self.last_written = ""
        self.last_write_at = 0.0
        self.outbox_mtimes: dict = {}
        self.cleared_mtimes: dict = {}
        self.helpers_checked_at: float | None = None
        self.helpers_changed: list[str] = []
        self.was_withheld = False
        self.outbox_path_now: Path | None = None
        self.send_times: list[float] = []
        self.session = secrets.token_hex(4)  # With `revision`, tells the addon which snapshot is newer.
        self.revision = 0
        allow_files = self.config().get("pictures") is True  # Only an explicit yes counts.
        self.previews = previews.Previews(wow_dir / "Interface/AddOns" / settings.ADDON / "previews", remote, allow_files=allow_files, state_path=state_dir / "previews.json")

    def _load_state(self) -> dict:
        try:
            state = json.loads(self.state_path.read_text())
        except (OSError, ValueError):
            state = {}
        state.setdefault("ack", 0)
        state.setdefault("results", {})
        state.setdefault("hidden", {"projects": [], "threads": []})
        return state

    def save_state(self) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        safefiles.write_atomic(self.state_path, json.dumps(self.state))

    def audit(self, seq, thread, size, result) -> None:
        """Every reply that leaves the game is recorded. Lengths only, the text stays in T3."""
        self.state_dir.mkdir(parents=True, exist_ok=True)
        line = json.dumps({"at": int(time.time()), "seq": seq, "thread": thread, "bytes": size, "result": result.partition(":")[0]})
        if self.audit_path.exists() and self.audit_path.stat().st_size > settings.MAX_AUDIT_BYTES:
            os.replace(self.audit_path, self.audit_path.with_suffix(".old"))
        with self.audit_path.open("a") as handle:
            handle.write(line + "\n")

    def note_failure(self, error: str) -> None:
        if not self.error:
            self.error_since = int(time.time())
        self.error = error

    def hides(self, thread: dict) -> bool:
        projects = {project.get("id"): project.get("title") for project in (self.shell or {}).get("projects", [])}
        name = gametext.readable(projects.get(thread.get("projectId")) or "No project", 60)
        return threadstate.is_hidden(self.state["hidden"], thread["id"], name)

    def known_threads(self) -> dict:
        shell = self.shell
        if shell is None:
            try:
                shell = t3errors.check_shell(self.remote.shell())
                self.shell = shell
            except (OSError, urllib.error.URLError, ValueError):
                return {}
        return {thread["id"]: thread for thread in shell.get("threads", [])}

    def finish(self, seq: int, thread: str, size: int, result: str) -> None:
        self.state["ack"] = max(self.state["ack"], seq)
        self.state.pop("inflight", None)
        self.state["results"][str(seq)] = result
        # Kept long enough for any batch the addon could send to read its own outcomes.
        for key in sorted(self.state["results"], key=int)[:-settings.KEEP_RESULTS]:
            del self.state["results"][key]
            self.state.get("sums", {}).pop(key, None)
        self.audit(seq, thread, size, result)
        self.save_state()
        console.log(f"seq {seq}: {result}")

    def clients(self) -> list[Path]:
        """Every client Prompt Peon went into, with the one it serves now first, so it stays while that game is open."""
        known = [Path(folder) for folder in self.config().get("wow_dirs") or []]
        others = [folder for folder in known if folder != self.wow_dir and (folder / "Interface/AddOns" / settings.ADDON).is_dir()]
        return [self.wow_dir, *dict.fromkeys(others)]

    def use_client(self, wow_dir: Path) -> None:
        """The game opened in another client, so that one gets the data from now on."""
        addon = wow_dir / "Interface/AddOns" / settings.ADDON
        self.wow_dir = wow_dir
        self.snapshot_path = addon / "Snapshot.lua"
        self.previews.use_folder(addon / "previews")
        self.last_written, self.last_write_at = "", 0.0
        self.helpers_checked_at, self.helpers_changed = None, []
        self.was_withheld = False
        self.outbox_path_now = None

    def config(self) -> dict:
        try:
            return json.loads(self.config_path.read_text())
        except (OSError, ValueError, AttributeError):
            return {}

    def keep_loaded(self, thread_id: str, **values) -> None:
        self.loaded.setdefault(thread_id, {}).update(values, until=time.monotonic() + settings.LOADED_SECONDS)
