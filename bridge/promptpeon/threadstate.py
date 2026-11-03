"""Which threads show where, and what one word describes each. All read from T3's thread list."""
from __future__ import annotations

import calendar
import time

from . import settings


def is_child(thread: dict) -> bool:
    return bool((thread.get("lineage") or {}).get("parentThreadId"))


def waiting_on_you(thread: dict) -> bool:
    """T3 calls a request non-blocking when a normal message answers it.

    A background child with one of those has no one reading it, so it stays out of the log.
    """
    pending = thread.get("pendingRuntimeRequest")
    if not pending:
        return False
    if pending.get("blocking") is not False:
        return True
    return not is_child(thread) and not thread.get("settledAt")


def status_of(thread: dict) -> str:
    """One word per thread. A blocked agent outranks everything, because it is waiting on you."""
    if waiting_on_you(thread):
        return "needs"
    if thread.get("activeRunId") and thread.get("activityRunStatus") in (
        "running", "starting", "preparing", "queued", "waiting",
    ):
        return "running"
    status = thread.get("status")
    if status in ("running", "starting", "preparing", "queued"):
        return "running"
    if status == "waiting":
        return "needs"
    if status == "failed" or thread.get("lastError"):
        return "error"
    if status == "completed":
        return "done"
    if status in ("cancelled", "interrupted", "rolled_back"):
        return "stopped"
    return "idle"


RANK = {"needs": 0, "error": 1, "running": 2, "done": 3, "stopped": 4, "idle": 5}


def active_threads(shell: dict) -> list[dict]:
    return open_threads(shell)[:settings.MAX_THREADS]


def is_snoozed(thread: dict) -> bool:
    return bool(thread.get("snoozedUntil")) and to_epoch(thread["snoozedUntil"]) > time.time()


def parked_threads(shell: dict) -> list[tuple[str, dict]]:
    """Snoozed and settled threads, for the bottom of the list. Anything waiting on you stays up top."""
    snoozed, settled = [], []
    for thread in shell.get("threads", []):
        if thread.get("archivedAt") or thread.get("deletedAt") or is_child(thread) or waiting_on_you(thread):
            continue
        if thread.get("settledAt"):
            settled.append(thread)
        elif is_snoozed(thread):
            snoozed.append(thread)
    snoozed.sort(key=lambda thread: to_epoch(thread["snoozedUntil"]))
    settled.sort(key=lambda thread: thread.get("settledAt") or "", reverse=True)
    return [("z", thread) for thread in snoozed] + [("s", thread) for thread in settled[:settings.MAX_PARKED_ROWS]]


def open_threads(shell: dict) -> list[dict]:
    """What the T3 sidebar treats as open: top level, unsettled, not archived. All of them, best first."""
    keep = []
    for thread in shell.get("threads", []):
        if thread.get("archivedAt") or thread.get("deletedAt"):
            continue
        if waiting_on_you(thread):
            keep.append(thread)
            continue
        if is_child(thread) or thread.get("settledAt") or is_snoozed(thread):
            continue
        keep.append(thread)
    keep.sort(key=lambda thread: thread.get("updatedAt") or "", reverse=True)
    keep.sort(key=lambda thread: RANK[status_of(thread)])
    return keep


def to_epoch(stamp) -> int:
    try:
        return calendar.timegm(time.strptime(str(stamp)[:19], "%Y-%m-%dT%H:%M:%S"))
    except (TypeError, ValueError):
        return 0


def is_hidden(hidden: dict | None, thread_id: str, project: str) -> bool:
    """`project` is the readable name the row shows, which is what the player picked."""
    hidden = hidden or {}
    return thread_id in hidden.get("threads", []) or project in hidden.get("projects", [])


def new_thread_selection(shell: dict, project: dict) -> dict | None:
    """The model a new thread in this project gets unless you pick one."""
    if project.get("defaultModelSelection"):
        return project["defaultModelSelection"]
    picked = [thread for thread in shell.get("threads", []) if thread.get("modelSelection")]
    here = [thread for thread in picked if thread.get("projectId") == project.get("id")]
    return max(here or picked, key=lambda thread: thread.get("updatedAt") or "", default={}).get("modelSelection")
