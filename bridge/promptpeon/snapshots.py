"""Building the one snapshot the game loads, within what the game can load, and rendering it as Lua."""
from __future__ import annotations

import re
import time
import urllib.parse

from . import gametext, luadata, settings, threadstate


def build_snapshot(shell: dict | None, messages: dict, *, url: str, error: str, error_since: int,
                   ack: int, results: dict, previous: dict | None = None, now: int | None = None, hidden: dict | None = None) -> dict:
    now = now or int(time.time())
    snapshot = {"v": 1, "at": now, "ack": ack, "res": results, "err": error, "errAt": error_since}
    if shell is None:
        # Keep the last threads on screen. The addon shows `err` above them, so an
        # outage reads as an outage and never as "all your agents are idle".
        # Without what you opened: that only ever stays for a minute, outage or not.
        for field in ("threads", "pk"):
            rows = []
            for row in (previous or {}).get(field, []):
                # Something you hid during the outage goes now, not when T3 comes back.
                if threadstate.is_hidden(hidden, row.get("id"), row.get("p")):
                    row = {key: value for key, value in row.items() if key in ("id", "p", "t", "s", "u", "pk", "zu")}
                    row["hd"] = True
                rows.append({key: value for key, value in row.items() if key not in settings.LOADED_FIELDS})
            snapshot[field] = rows
        return snapshot
    projects = {project.get("id"): project.get("title") for project in shell.get("projects", [])}
    snapshot["pj"] = [gametext.readable(title, 60) for title in projects.values() if title and not threadstate.is_hidden(hidden, "", gametext.readable(title, 60))]
    snapshot["pm"] = []
    for project in shell.get("projects", []):
        name = gametext.readable(project.get("title") or "", 60)
        selection = threadstate.new_thread_selection(shell, project) or {}
        if name and selection.get("instanceId") and not threadstate.is_hidden(hidden, "", name):
            effort = next((option.get("value") for option in selection.get("options") or [] if option.get("id") in settings.EFFORT_OPTIONS), "")
            snapshot["pm"].append([name, str(selection["instanceId"]), gametext.readable(selection.get("model") or "", 40), str(effort)])
    snapshot["tc"] = len(threadstate.open_threads(shell))
    threads = []
    for index, thread in enumerate(threadstate.active_threads(shell)):
        row = {
            "id": thread["id"],
            "p": gametext.readable(projects.get(thread.get("projectId")) or "No project", 60),
            "t": gametext.readable(thread.get("title") or "Untitled", 120),
            "s": threadstate.status_of(thread),
            "u": threadstate.to_epoch(thread.get("updatedAt")),
            "b": gametext.readable(thread.get("branch") or "", 60),
            "mo": gametext.readable((thread.get("modelSelection") or {}).get("model") or "", 40),
            "pv": gametext.readable(thread.get("providerInstanceId") or "", 40),
        }
        selection = thread.get("modelSelection") or {}
        if selection.get("instanceId"):
            row["mi"] = str(selection["instanceId"])
        effort = next((option.get("value") for option in selection.get("options") or [] if option.get("id") in settings.EFFORT_OPTIONS), None)
        if effort:
            row["ef"] = str(effort)
        if thread.get("lastError"):
            row["e"] = gametext.readable(thread["lastError"])
        if thread.get("runtimeMode"):
            row["rm"] = gametext.readable(thread["runtimeMode"], 30)
        detail = messages.get(thread["id"]) if index < settings.THREADS_WITH_MESSAGES else None
        if detail:
            row["m"] = detail["rows"]
            if detail.get("queued"):
                row["qc"] = detail["queued"]
            if detail.get("context") is not None:
                row["cu"] = detail["context"]
            if detail.get("changes"):
                row["ch"] = detail["changes"]
            elif detail.get("can_diff"):
                # The recent window has no changed files, but older turns might. T3 can say.
                row["cd"] = True
            if detail.get("more"):
                row["hm"] = True
            if detail.get("turns"):
                row["tn"] = detail["turns"]
            if detail.get("last_change"):
                row["lc"] = detail["last_change"]
            if detail.get("agents"):
                row["ag"] = detail["agents"]
                row["agn"] = detail["agents_total"]
        status = row["s"]
        if status == "running":
            row["a"] = "Waiting on another thread" if thread.get("blockedOnThreadWait") else (detail or {}).get("activity") or "Working"
            started = threadstate.to_epoch(thread.get("activityRunStartedAt") or thread.get("latestRunStartedAt"))
            if started:
                row["as"] = started
        elif status == "needs":
            pending = thread.get("pendingRuntimeRequest") or {}
            row["a"] = "Waiting for your answer" if pending.get("kind") == "user_input" else "Waiting for your approval"
            if pending.get("blocking") is False:
                row["nb"] = True  # A normal reply answers this one.
            elif pending.get("kind") == "user_input":
                row["uq"] = True  # A question, not an approval, so the game can answer it.
        if threadstate.is_hidden(hidden, thread["id"], row["p"]):
            # Hidden means the game never gets the words, so only the bare row stays.
            row = {key: row[key] for key in ("id", "p", "t", "s", "u")}
            row["hd"] = True
        threads.append(row)
    snapshot["threads"] = threads
    # Snoozed and settled ride apart, so the tracker, the party and the counts never see them.
    parked = []
    for kind, thread in threadstate.parked_threads(shell):
        row = {
            "id": thread["id"],
            "p": gametext.readable(projects.get(thread.get("projectId")) or "No project", 60),
            "t": gametext.readable(thread.get("title") or "Untitled", 120),
            "s": threadstate.status_of(thread),
            "u": threadstate.to_epoch(thread.get("updatedAt")),
            "pk": kind,
        }
        if kind == "z":
            row["zu"] = threadstate.to_epoch(thread["snoozedUntil"])
        if threadstate.is_hidden(hidden, thread["id"], row["p"]):
            row["hd"] = True
        else:
            row["b"] = gametext.readable(thread.get("branch") or "", 60)
            row["mo"] = gametext.readable((thread.get("modelSelection") or {}).get("model") or "", 40)
            row["cd"] = True
        parked.append(row)
    snapshot["pk"] = parked
    return snapshot


# As T3's own threadLinks.ts has it: <t3-thread://v2/ENVIRONMENT/ID>, [label](t3-thread://...) or v1 with
# no environment. The ID can be percent-escaped. Links in code get collected too: only harmless extra rows.
THREAD_LINK_RE = re.compile(r"t3-thread://(?:v2/[^/\s]+|v1)/([^\s<>)]+)")


def add_linked_threads(snapshot: dict, shell: dict | None, loaded: dict, hidden: dict | None = None) -> None:
    """Most links point at delegated threads, which the list leaves out. A link has to open them, so
    they ride along in `pk` as "l": a title and a status, with their words loaded when you open one."""
    if shell is None:
        return  # What the last snapshot had stays until T3 is back.
    by_id = {thread["id"]: thread for thread in shell.get("threads", []) if not thread.get("archivedAt") and not thread.get("deletedAt")}
    projects = {project.get("id"): project.get("title") for project in shell.get("projects", [])}
    have = {row["id"] for field in ("threads", "pk") for row in snapshot[field]}
    bodies = [row.get("m") for row in snapshot["threads"] + snapshot["pk"]]
    bodies += [extra.get(field) for extra in loaded.values() for field in ("vm", "ob")]
    added = 0
    for rows in bodies:
        for message in rows or []:
            if len(message) < 2 or not isinstance(message[1], str) or "t3-thread://" not in message[1]:
                continue
            for written in THREAD_LINK_RE.findall(message[1]):
                thread = by_id.get(written) or by_id.get(urllib.parse.unquote(written))
                if not thread or thread["id"] in have or added >= settings.MAX_LINKED_THREADS:
                    continue
                row = {
                    "id": thread["id"],
                    "p": gametext.readable(projects.get(thread.get("projectId")) or "No project", 60),
                    "t": gametext.readable(thread.get("title") or "Untitled", 120),
                    "s": threadstate.status_of(thread),
                    "u": threadstate.to_epoch(thread.get("updatedAt")),
                    "pk": "l",
                }
                if threadstate.is_hidden(hidden, thread["id"], row["p"]):
                    row["hd"] = True
                else:
                    row["b"] = gametext.readable(thread.get("branch") or "", 60)
                    row["mo"] = gametext.readable((thread.get("modelSelection") or {}).get("model") or "", 40)
                    row["cd"] = True
                snapshot["pk"].append(row)
                have.add(thread["id"])
                added += 1


def withhold_words(snapshot: dict, reason: str) -> None:
    """Names and status stay, so the tracker, party and counts keep working. Nothing anyone wrote does."""
    for field in ("threads", "pk"):
        rows = []
        for row in snapshot.get(field) or []:
            kept = {key: row[key] for key in settings.WITHHELD_KEEPS if key in row}
            if row.get("s") == "running":
                kept["a"] = "Working"  # Otherwise this can name a file or a command.
            rows.append(dict(kept, hd=True))
        snapshot[field] = rows
    snapshot["lk"] = reason


def fit_snapshot(snapshot: dict) -> None:
    """Messages are never cut, but the game has to load all of this. So past the budget, starting with
    the threads updated longest ago, rows give up their words and the row says where to read them.
    Then whatever else they carry goes, what you opened last of all, so the budget always holds."""
    total = len(luadata.lua_value(snapshot))
    rows = [*reversed(snapshot["threads"]), *reversed(snapshot.get("pk") or [])]
    for row in rows:
        if total <= settings.MAX_SNAPSHOT_BYTES:
            return
        if row.get("m"):
            total -= len(luadata.lua_value(row["m"]))
            row["m"] = [settings.TOO_LONG_ROW]
            row.pop("hm", None)
    for field in ("prs", "ag", "ch", *settings.LOADED_FIELDS):
        for row in rows:
            if total <= settings.MAX_SNAPSHOT_BYTES:
                return
            if field in row:
                total -= len(luadata.lua_value(row.pop(field)))


def render_snapshot(snapshot: dict) -> str:
    return "-- Written by the Prompt Peon bridge. Data only.\nPROMPTPEON_SNAPSHOT = " + luadata.lua_value(snapshot) + "\n"
