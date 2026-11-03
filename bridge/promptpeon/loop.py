"""The companion app's main loop: dial T3 only while the game is open, and keep going whatever happens."""
from __future__ import annotations

import queue
import threading
import time

from . import addonfiles, console, delivery, frames, processes, publishing, refreshing, settings, updater


def run(bridge, *, always: bool = False) -> None:
    """Dial T3 only while the game is open, so the T3 machine pays nothing the rest of the time."""
    console.log(f"bridge {settings.VERSION}: {bridge.remote.url} -> {bridge.wow_dir}")
    replies: "queue.Queue[dict]" = queue.Queue()
    reader = frames.FrameReader(bridge.wow_dir, replies)
    reader.start()

    def convert_images() -> None:
        while True:
            try:
                bridge.previews.process_one(block=True)
            except Exception as error:  # One bad picture must not end pictures for good.
                console.log(f"picture failed: {error}")

    # Its own thread: a big PNG takes seconds to convert, and must not hold up replies.
    threading.Thread(target=convert_images, daemon=True, name="previews").start()
    addonfiles.keep_addon_current(bridge.wow_dir)
    if not always and not processes.game_running(bridge.wow_dir):
        publishing.go_quiet(bridge)  # We may have died with thread text still in the game folder.
    next_refresh = 0.0
    next_game_check = 0.0
    next_clear = 0.0
    next_version_check = time.monotonic() + settings.VERSION_CHECK_SECONDS
    was_running = False
    running = False
    if not always:  # That's for testing by hand, and asks for T3 only.
        threading.Thread(target=updater.watch_for_releases, args=(bridge, lambda: running), daemon=True, name="releases").start()
    while True:
        now = time.monotonic()
        if now >= next_game_check:
            running = always or processes.game_running(bridge.wow_dir)
            reader.running_game = running
            next_game_check = now + settings.GAME_CHECK_SECONDS
            if running != was_running:
                console.log("game started, dialing T3" if running else "game closed, going quiet")
                was_running = running
                next_refresh = 0.0
                bridge.game_closed = False
                if not running:
                    publishing.go_quiet(bridge)
        if not running and now >= next_version_check:
            addonfiles.keep_addon_current(bridge.wow_dir)  # The launcher patches while the game is closed.
            next_version_check = now + settings.VERSION_CHECK_SECONDS
        try:
            while not replies.empty():
                delivery.deliver(bridge, [replies.get_nowait()])
            # Also while closed: a reply can be flushed as the game exits.
            delivery.poll_outbox(bridge)
            if not running and now >= next_clear:
                delivery.clear_saved_words(bridge)
                next_clear = now + settings.GAME_CHECK_SECONDS
            if running and time.monotonic() >= next_refresh:
                refreshing.refresh(bridge)
                next_refresh = time.monotonic() + settings.REFRESH_SECONDS
        except Exception as error:  # On Windows nothing restarts this, so it must not stop.
            console.log(f"loop error, carrying on: {type(error).__name__}: {str(error)[:200]}")
        try:
            # A reply wakes this straight away.
            replies.put(replies.get(timeout=0.25))
        except queue.Empty:
            pass
