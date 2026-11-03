"""One refresh: ask T3 what changed, then publish it."""
from __future__ import annotations

import json
import urllib.error

from . import catalog, console, gametext, publishing, settings, t3errors, threadstate


def refresh(bridge) -> None:
    if bridge.game_closed:
        publishing.publish(bridge)  # A reply flushed as the game exited still gets its result.
        return
    try:
        shell = t3errors.check_shell(bridge.remote.shell())
        threads = threadstate.active_threads(shell)
        titles = {project.get("id"): project.get("title") for project in shell.get("projects", [])}
        for thread in threads[:settings.THREADS_WITH_MESSAGES]:
            # A hidden thread's words have no reason to be on this machine at all.
            if threadstate.is_hidden(bridge.state["hidden"], thread["id"], gametext.readable(titles.get(thread.get("projectId")) or "No project", 60)):
                bridge.messages.pop(thread["id"], None)
                bridge.seen.pop(thread["id"], None)
                continue
            stamp = thread.get("updatedAt")
            if bridge.seen.get(thread["id"]) != stamp:
                try:
                    bridge.messages[thread["id"]] = bridge.remote.detail(thread["id"])
                    bridge.seen[thread["id"]] = stamp  # Only now, so a failure gets another try.
                except urllib.error.HTTPError as error:
                    # One odd thread must not take the whole log down.
                    if error.code in (401, 403):
                        raise
                    console.log(f"no messages for {thread['id']}: HTTP {error.code}")
                except (KeyError, TypeError, AttributeError, ValueError) as error:
                    console.log(f"no messages for {thread['id']}: {type(error).__name__}")
        bridge.shell = shell
        bridge.error, bridge.error_since = "", 0
        catalog.refresh_catalog(bridge)
    except urllib.error.HTTPError as error:
        bridge.shell = None
        if error.code in (401, 403):
            bridge.note_failure("Your link to T3 has expired. Make a new pairing link in T3 and run the installer again.")
        elif error.code in t3errors.T3_CHANGED_CODES:
            bridge.note_failure(t3errors.T3_CHANGED)
        else:
            bridge.note_failure(f"T3 answered with an error ({error.code}).")
    except (t3errors.T3Changed, json.JSONDecodeError, KeyError, TypeError, AttributeError) as error:
        bridge.shell = None
        console.log(f"T3's answer made no sense here: {type(error).__name__}: {str(error)[:120]}")
        bridge.note_failure(t3errors.T3_CHANGED)
    except (OSError, urllib.error.URLError, ValueError) as error:
        bridge.shell = None
        console.log(f"refresh failed: {error}")
        bridge.note_failure(f"Can't reach T3 at {bridge.remote.url}. Is that machine awake, with network access on?")
    try:
        publishing.publish(bridge)
    except (KeyError, TypeError, AttributeError) as error:
        # A field in a new shape. Without its threads this can't fail, and what you had stays up.
        console.log(f"T3's answer made no sense here: {type(error).__name__}: {str(error)[:120]}")
        bridge.shell = None
        bridge.note_failure(t3errors.T3_CHANGED)
        publishing.publish(bridge)
