"""Every limit, timing, name and folder the companion app uses, and the version number.

VERSION lives here and nowhere else. The updater reads it out of this file in a release it downloaded,
so it has to stay a plain line: VERSION = "1.2.3".
"""
from __future__ import annotations

import os
from pathlib import Path

VERSION = "0.32.1"
ENTRY_POINT = "promptpeon_bridge.py"  # Installers, autostart, the service and stopping a running copy all know it by this name.
PACKAGE = "promptpeon"  # This folder, which sits next to the entry point.
PROGRAM_DIR = Path(__file__).resolve().parent.parent  # Where the entry point is: bridge/ in a download or an install.
# T3 Connect runs behind Cloudflare, which turns away Python's default signature. So we say who we are.
USER_AGENT = f"PromptPeon/{VERSION}"
# Client folder -> (the Interface number its addons must declare, its game program).
CLIENTS = {
    # The file on disk is WowClassic.exe, the running process is WoWClassic.exe.
    "_classic_era_": ("11509", "WowClassic.exe"),  # Classic Era 1.15.9
    "_retail_": ("120105", "Wow.exe"),  # Retail 12.1.5
    "_forever_": ("16001", "Wow.exe"),  # WoW Forever 1.60.1
}
CLIENT_NAMES = {"_classic_era_": "WoW Classic Era", "_retail_": "WoW Retail", "_forever_": "WoW Forever"}
BUILD_PRODUCTS = {"_classic_era_": "wow_classic_era", "_retail_": "wow", "_forever_": "wowf"}  # Names in .build.info.
SLOT_COUNT = 1000  # Keep equal to ns.SLOT_COUNT in addon/PromptPeon/Core.lua.
OUT_COUNT = 96  # Keep equal to ns.OUT_COUNT in addon/PromptPeon/Core.lua.
INTERNALS = "Prompt Peon internals"  # One collapsible heading in the game's addon list.
ADDON = "PromptPeon"
UPDATE_REPO = "svenmeys/prompt-peon"  # Change this with the repo, or installers keep asking the old address.
UPDATE_API = f"https://api.github.com/repos/{UPDATE_REPO}/releases/latest"
UPDATE_ZIP = f"https://codeload.github.com/{UPDATE_REPO}/zip/refs/tags/v{{version}}"
INSTALL_PYTHON = (3, 14)  # The newest one winget has, with no known CVEs. A test keeps install.cmd and CI equal to this.
UPDATE_SECONDS = 60
UPDATE_CHECK_SECONDS = 30 * 60  # How often the app asks whether a newer release exists, while the game is open.
MAX_UPDATE_BYTES = 30 * 1024 * 1024  # Unpacked. The real thing is under 1 MB.
UPDATE_PARTS = {"addon", "bridge", "install.cmd", "uninstall.cmd", "start-stop.cmd", "install.sh", "uninstall.sh", "start-stop.sh"}  # What the installer uses. An older installer only unpacks what its own list names, so a new file here reaches an install one update later.
MAX_THREADS = 30
THREADS_WITH_MESSAGES = 30
# Keep messages whole. Measured on real threads: the last 30 messages of every open thread
# come to about 110 KB, and Lua loads 2 MB of snapshot in about 6 ms.
MESSAGES_PER_THREAD = 30
MAX_REPLY_BYTES = 4000
MAX_MESSAGE_CHARS = 300_000  # Far past anything real, and the game has to lay out all of it.
MAX_READS_PER_MINUTE = 60
MAX_SENDS_PER_MINUTE = 10
MAX_OUTBOX_CHARS = 256000
KEEP_RESULTS = 200
# Diffs and agent reports only sit in the snapshot for a minute, when you open them.
MAX_LOADED_BYTES = 1_000_000
MAX_PATCH_BYTES = 150_000  # Bigger files come a page at a time, when you open them.
MAX_PAGE_BYTES = 100_000
MAX_DIFF_LINE = 1200  # Characters. Minified files have lines nobody can read in a game window.
LOADED_SECONDS = 60
T3_DIFF_LIMIT = 10_000_000  # T3 cuts a diff off at this size.
MAX_AGENTS = 30
LOADED_FIELDS = ("df", "dn", "fp", "ax", "ob", "om", "oc", "vm", "pd")  # Rows that only stay for a minute.
# What a thread keeps while its words stay out of the game: enough for the list, tracker and party.
WITHHELD_KEEPS = ("id", "p", "t", "s", "u", "pk", "zu", "mo", "pv", "mi", "ef", "rm", "a", "as", "nb", "cu", "tn")
HELPER_CHECK_SECONDS = 30  # Walking every helper isn't free, so not on every refresh.
TYPED_WORDS = ("drafts", "pending")  # In the addon's saved table. Gone once the game has closed.
EFFORT_OPTIONS = ("effort", "reasoningEffort")  # What providers call it in T3's model list.
CATALOG_SECONDS = 600  # How often to ask T3 which models it has. They rarely change.
MAX_MODELS_PER_PROVIDER = 30
CHECK_SECONDS = 180  # What the PR page learned about CI beats T3's own summary for twice this long.
BASE_SCOPES = ["orchestration:read", "orchestration:operate"]
PICTURE_SCOPE = "filesystem:read"  # Lets us read files on the T3 machine. Asked for at install.
DEFAULT_URL = "http://127.0.0.1:3773"
SUPERVISED_MODES = ("approval-required", "auto-accept-edits")  # Anything else can act without asking.
RUNTIME_MODES = (*SUPERVISED_MODES, "auto", "full-access")  # T3's, in its order. Keep equal to ns.RUNTIME_MODES in Core.lua.
COMMAND_MARK = "\x01"  # Starts a command from the addon. No keyboard can type it into a reply.
PREVIEW_FILES = 64  # The game only sees files that exist at a reload, so these are made up front.
PREVIEW_MAX_SIDE = 768
PREVIEWS_PER_THREAD = 3
THREADS_WITH_PREVIEWS = 10
MAX_IMAGE_DOWNLOAD = 40 * 1024 * 1024
PREVIEW_TRIES = 6
MAX_PARKED_ROWS = 30  # Settled threads listed at the bottom of the log, newest first.
MAX_PULL_REQUESTS = 12  # On one thread. Past that, T3 has the rest.
MAX_CHECKS = 40  # On one pull request.
MAX_PR_ENTRIES = 500  # Comments and review threads on one pull request. T3 cuts these off itself too.
MAX_PR_EVENTS = 800  # Rows in one pull request's timeline.
MAX_PR_TEXT = 16_000  # One comment. Bots write up to 30,000 characters.
MAX_SNOOZE_SECONDS = 366 * 24 * 3600
MAX_IMAGE_PIXELS = 8_400_000  # 4K. It's all decoded in Python to make a 768 pixel preview, which is slow.
MAX_T3_BYTES = 64 * 1024 * 1024  # One answer from T3. Far above a real one, far below what could hurt.
T3_READ_SECONDS = 120  # One answer from T3, however slowly it trickles in.
MAX_HISTORY_PAGES = 200
MAX_GAME_FILE_BYTES = 64 * 1024 * 1024  # A file the game wrote, before we read all of it.
LAST_SEND_SECONDS = 120  # After the game closes, how long a last message waits for T3 before it's cleared.
MAX_SNAPSHOT_BYTES = 8_000_000  # Lua loads 2 MB in about 6 ms. Past this, the oldest threads wait for T3.
TOO_LONG_ROW = ["a", "This thread doesn't fit in the game right now. Open it in T3.", "d", 0]
MAX_AUDIT_BYTES = 1_000_000
REFRESH_SECONDS = 5  # Often enough that "Thinking" means thinking.
HEARTBEAT_SECONDS = 30  # Unchanged data is rewritten this often, so the addon knows we are alive.
VERSION_CHECK_SECONDS = 60
GAME_CHECK_SECONDS = 5  # How often to look for the game. tasklist is too slow to run every second.
IS_WINDOWS = os.name == "nt"
if IS_WINDOWS:
    CONFIG_DIR = Path(os.environ.get("APPDATA", Path.home())) / "prompt-peon"
    STATE_DIR = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "prompt-peon"
    HOME_DIR = STATE_DIR
else:
    CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "prompt-peon"
    STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "prompt-peon"
    HOME_DIR = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "prompt-peon"
WOW_GLOBS = [
    ".local/share/Steam/steamapps/compatdata/*/pfx/drive_c/Program Files (x86)/World of Warcraft",
    "Games/*/drive_c/Program Files (x86)/World of Warcraft",
]
WINDOWS_WOW_PATHS = [
    "Program Files (x86)/World of Warcraft",
    "Program Files/World of Warcraft",
    "World of Warcraft",
    "Games/World of Warcraft",
    "Battle.net/World of Warcraft",
]
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
RUN_VALUE = "PromptPeon"
SERVICE = "prompt-peon"
