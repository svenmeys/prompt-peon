"""Everything that leaves the game on its way to T3: limits, once-only sending and the saved outbox."""
from __future__ import annotations

import time
import uuid
import zlib
from pathlib import Path

from . import commands, console, gates, publishing, refreshing, safefiles, savedvars, settings, t3errors


def clear_saved_words(bridge, wow_dir: Path | None = None, *, force: bool = False) -> None:
    """Run while the game is closed. Nothing you typed stays in its folder, once any last message has gone.
    T3 being away gets it a fair wait, not forever: then it's cleared, and the next session says it was lost.
    `force` skips the wait, for a client you've moved away from."""
    waited = force or bridge.closed_at is not None and time.monotonic() - bridge.closed_at >= settings.LAST_SEND_SECONDS
    for path in ((wow_dir or bridge.wow_dir) / "WTF/Account").glob(f"*/SavedVariables/{settings.ADDON}.lua*"):
        try:
            mtime = path.stat().st_mtime
            main = path.name == f"{settings.ADDON}.lua"
            if bridge.cleared_mtimes.get(path) == mtime or (main and bridge.outbox_mtimes.get(path) != mtime and not waited):
                continue  # Done already, or poll_outbox hasn't taken what's in it yet.
            lost = unsent_in(bridge, path) if main else 0
            savedvars.clear_typed_words(path)
            mtime = path.stat().st_mtime
            bridge.cleared_mtimes[path] = mtime
            if main:
                bridge.outbox_mtimes[path] = mtime  # Our own write isn't the game reloading.
            if lost:
                bridge.state["cleared"] = {"n": lost, "at": int(time.time())}
                bridge.save_state()
        except OSError as error:
            console.log(f"could not clear {path.name}: {error}")


def unsent_in(bridge, path: Path) -> int:
    """Messages in this file that didn't reach T3, so the next session can say they're gone."""
    entries, _ = savedvars.parse_outbox(safefiles.read_shared(path))
    count = 0
    for entry in entries:
        verb = entry["text"][1:].partition("\n")[0] if entry["text"].startswith(settings.COMMAND_MARK) else None
        result = bridge.state["results"].get(str(entry["seq"]), "")
        if verb in (None, "new", "newm") and (not result or result.startswith("failed")):
            count += 1
    return count


def outbox_files(bridge) -> list[Path]:
    return list((bridge.wow_dir / "WTF/Account").glob(f"*/SavedVariables/{settings.ADDON}.lua"))


def poll_outbox(bridge) -> None:
    # Oldest first, so a newer file's acknowledgement can't skip an older file's reply.
    for path in sorted(outbox_files(bridge), key=lambda entry: entry.stat().st_mtime):
        mtime = path.stat().st_mtime
        if mtime == bridge.outbox_mtimes.get(path) or 0 <= time.time() - mtime < 0.5:
            continue  # Unchanged, or the game may still be writing it.
        # The game writes this file at every reload, and a reload clears its picture cache.
        bridge.previews.new_ui_session(mtime)
        bridge.previews.forget_retryable()
        try:
            saved = safefiles.read_shared(path)
        except OSError as error:
            console.log(f"could not read {path.name} yet: {error}")  # Tried again next time round.
            continue
        bridge.outbox_mtimes[path] = mtime
        bridge.outbox_path_now = path
        dispatch(bridge, saved)


def dispatch(bridge, saved_variables: str) -> None:
    entries, rejected = savedvars.parse_outbox(saved_variables)
    for reason in rejected:
        bridge.audit(None, None, 0, f"rejected: {reason}")
        console.log(f"rejected: {reason}")
    deliver(bridge, entries, from_file=True)


def deliver(bridge, entries: list[dict], *, from_file: bool = False) -> None:
    """Send replies on to T3, whichever way they left the game. Each seq is only sent once."""
    changed = False
    for entry in entries:
        seq, thread_id, text = entry["seq"], entry["thread"], entry["text"]
        if seq <= bridge.state["ack"]:
            continue
        changed = True
        size = len(text.encode("utf-8"))
        # So a second account on this install can tell this number's result isn't for its message.
        bridge.state.setdefault("sums", {})[str(seq)] = zlib.crc32(f"{thread_id}\0{text}".encode("utf-8"))
        command_verb = text[1:].partition("\n")[0] if text.startswith(settings.COMMAND_MARK) else None
        # Hiding only takes things away from the game, so another addon gains nothing from it.
        refused = None if command_verb == "hidden" else gates.refused_by_other_addons(bridge)
        if refused:
            bridge.finish(seq, thread_id, size, refused)
            continue
        if text.startswith(settings.COMMAND_MARK):
            verb = text[1:].partition("\n")[0]
            # Reading more doesn't change anything, but these do, so they count like replies.
            if verb in ("stop", "settle", "new", "newm", "setmodel", "steer", "cancelq", "editq", "unsettle", "snooze", "unsnooze"):
                now = time.time()
                bridge.send_times = [stamp for stamp in bridge.send_times if now - stamp < 60]
                if len(bridge.send_times) >= settings.MAX_SENDS_PER_MINUTE:
                    bridge.finish(seq, thread_id, size, "failed: too many in one minute")
                    continue
                bridge.send_times.append(now)
            elif verb != "hidden":
                # Reading changes nothing, but each one makes T3 work, so it has a limit too.
                now = time.time()
                bridge.read_times = [stamp for stamp in bridge.read_times if now - stamp < 60]
                if len(bridge.read_times) >= settings.MAX_READS_PER_MINUTE:
                    bridge.finish(seq, thread_id, size, "failed: too many in one minute")
                    continue
                bridge.read_times.append(now)
            commands.run_command(bridge, seq, thread_id, text, size)
            continue
        try:
            known = bridge.known_threads()
        except t3errors.T3Changed as error:
            bridge.finish(seq, thread_id, size, f"failed: {t3errors.plain_refusal(error)}")
            continue
        if not known:
            console.log("T3 unreachable, holding the reply")
            if from_file and bridge.outbox_path_now:
                bridge.outbox_mtimes.pop(bridge.outbox_path_now, None)  # Look at this file again next time.
            return
        if size == 0 or size > settings.MAX_REPLY_BYTES:
            bridge.finish(seq, thread_id, size, f"failed: reply must be 1 to {settings.MAX_REPLY_BYTES} bytes")
            continue
        thread = known.get(thread_id)
        full_access = gates.refused_full_access(bridge, thread) if thread else None
        if full_access:
            bridge.finish(seq, thread_id, size, full_access)
            continue
        if thread is None:
            bridge.finish(seq, thread_id, size, "failed: that thread is not on this T3 server")
            continue
        # We died mid-send last time. T3 knows whether it got this one, so ask instead of guessing.
        inflight = bridge.state.get("inflight") or {}
        message_id = None
        if inflight.get("seq") == seq:
            try:
                if bridge.remote.has_message(thread_id, inflight["message_id"]):
                    bridge.finish(seq, thread_id, size, "sent")
                    continue
            except (OSError, ValueError, KeyError) as error:
                console.log(f"seq {seq}: could not check after a crash: {error}")
                bridge.finish(seq, thread_id, size, "unknown: the companion app stopped while sending. Check the thread in T3 before resending.")
                continue
            message_id = inflight["message_id"]
        now = time.time()
        bridge.send_times = [stamp for stamp in bridge.send_times if now - stamp < 60]
        if len(bridge.send_times) >= settings.MAX_SENDS_PER_MINUTE:
            bridge.finish(seq, thread_id, size, "failed: too many replies in one minute")
            continue
        bridge.send_times.append(now)
        # Written down before sending, so a crash in the next line can be sorted out afterwards.
        message_id = message_id or str(uuid.uuid4())
        bridge.state["inflight"] = {"seq": seq, "message_id": message_id}
        bridge.save_state()
        try:
            bridge.remote.send_reply(thread, text, message_id)
            bridge.finish(seq, thread_id, size, "sent")
        except t3errors.SendRefused as error:
            bridge.finish(seq, thread_id, size, f"failed: {error}")
        except t3errors.SendUncertain as error:
            # Marked as handled on purpose. A duplicate instruction to an agent is worse than
            # asking you to look at the thread.
            bridge.finish(seq, thread_id, size, f"unknown: {error}. Check the thread in T3 before resending.")
    if changed:
        # The outcome goes out right away, because a refresh can take seconds and the addon is
        # waiting for it. The refresh then brings the new message itself.
        publishing.publish(bridge)
        for entry in entries:
            bridge.seen.pop(entry["thread"], None)
        refreshing.refresh(bridge)
