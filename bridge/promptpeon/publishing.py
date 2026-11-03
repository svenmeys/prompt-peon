"""Putting what we know in the game folder, and taking it out again when the game closes."""
from __future__ import annotations

import json
import time

from . import console, gates, pullrequests, safefiles, settings, snapshots, threadstate


def publish(bridge) -> None:
    if bridge.game_closed:
        go_quiet(bridge)
        return
    withheld = gates.withheld_because(bridge)
    details = {}
    if bridge.shell is not None:
        for index, thread in enumerate(threadstate.active_threads(bridge.shell)):
            detail = bridge.messages.get(thread["id"])
            if detail and withheld:
                # Numbers only, for the party. No rows, so no pictures get fetched either.
                details[thread["id"]] = {"rows": [], "context": detail.get("context"), "turns": detail.get("turns")}
            elif detail and not bridge.hides(thread):
                wanted = index < settings.THREADS_WITH_PREVIEWS and bridge.previews.folder.is_dir()
                details[thread["id"]] = dict(detail, rows=bridge.previews.prepare(thread["id"], detail["rows"], wanted))
    snapshot = snapshots.build_snapshot(
        bridge.shell, details, url=bridge.remote.url, error=bridge.error, error_since=bridge.error_since,
        ack=bridge.state["ack"], results=bridge.state["results"], previous=bridge.snapshot,
        hidden=bridge.state["hidden"],
    )
    for thread_id, extra in list(bridge.loaded.items()):
        if time.monotonic() >= extra["until"]:
            del bridge.loaded[thread_id]
    if bridge.catalog:
        snapshot["md"] = bridge.catalog
    if bridge.config().get("full_access") is True:
        snapshot["fa"] = True  # Only so the game can grey out what would be refused. The check is in commands.command_result.
    snapshot["rc"] = bridge.state.get("sums") or {}
    if bridge.state.get("cleared"):
        snapshot["clr"] = bridge.state["cleared"]
    by_id = {thread["id"]: thread for thread in (bridge.shell or {}).get("threads", [])}
    for row in snapshot["threads"]:
        if row.get("hd"):
            continue
        extra = bridge.loaded.get(row["id"])
        if extra:
            row.update({key: value for key, value in extra.items() if key != "until"})
        linked = pullrequests.pull_request_rows(by_id[row["id"]], bridge.pr_checks) if row["id"] in by_id else None
        if linked:
            row["prs"] = linked
    for row in snapshot["pk"]:
        if row.get("hd"):
            continue
        extra = bridge.loaded.get(row["id"])
        if extra:
            row.update({key: value for key, value in extra.items() if key != "until"})
        linked = pullrequests.pull_request_rows(by_id[row["id"]], bridge.pr_checks) if row["id"] in by_id else None
        if linked:
            row["prs"] = linked
    if withheld:
        snapshots.withhold_words(snapshot, withheld)
        bridge.loaded.clear()
        bridge.patches = {}
        if not bridge.was_withheld:
            bridge.previews.clear_files(new_session=False)
    bridge.was_withheld = bool(withheld)
    snapshots.fit_snapshot(snapshot)
    bridge.snapshot = snapshot
    # Agents are often quiet, and a snapshot can be hundreds of KB. Only write real changes,
    # plus a heartbeat, because the time in the file is how the addon knows we are alive.
    body = json.dumps(dict(snapshot, at=0))  # About 30 times cheaper than rendering it to compare.
    now = time.monotonic()
    if body == bridge.last_written and now - bridge.last_write_at < settings.HEARTBEAT_SECONDS:
        return
    bridge.revision += 1
    snapshot.update(sid=bridge.session, rv=bridge.revision)
    if not bridge.snapshot_path.parent.is_dir():
        console.log("the addon folder is gone, so nothing was written. Run the installer again to bring it back.")
        return
    if bridge.in_place and bridge.snapshot_path.exists():
        if not safefiles.write_in_place(bridge.snapshot_path, snapshots.render_snapshot(snapshot)):
            return  # Not written, so the next refresh tries again.
    else:
        safefiles.write_atomic(bridge.snapshot_path, snapshots.render_snapshot(snapshot))
    bridge.last_written, bridge.last_write_at = body, now


def go_quiet(bridge) -> None:
    """The game closed. Thread text and pictures shouldn't sit in its folder until it opens again."""
    if not bridge.game_closed:
        bridge.closed_at = time.monotonic()
    bridge.game_closed = True
    bridge.loaded.clear()
    bridge.patches = {}
    bridge.snapshot = None
    snapshot = snapshots.build_snapshot(None, {}, url=bridge.remote.url, error="", error_since=0, ack=bridge.state["ack"],
                              results=bridge.state["results"])
    bridge.revision += 1
    snapshot.update(quiet=True, sid=bridge.session, rv=bridge.revision, rc=bridge.state.get("sums") or {})
    bridge.last_written = ""
    if bridge.snapshot_path.parent.is_dir():
        if bridge.in_place and bridge.snapshot_path.exists():
            safefiles.write_in_place(bridge.snapshot_path, snapshots.render_snapshot(snapshot))
        else:
            safefiles.write_atomic(bridge.snapshot_path, snapshots.render_snapshot(snapshot))
    if bridge.previews.folder.is_dir():
        bridge.previews.clear_files()
