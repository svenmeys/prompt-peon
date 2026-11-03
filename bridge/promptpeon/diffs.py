"""A thread's changes: splitting T3's diff by file, and fitting it into snapshots a page at a time."""
from __future__ import annotations

import re

from . import gametext, settings


def shorten_long_lines(patch: str) -> str:
    lines = patch.split("\n")
    for index, line in enumerate(lines):
        if len(line) > settings.MAX_DIFF_LINE:
            lines[index] = f"{line[:settings.MAX_DIFF_LINE]} ... ({len(line) - settings.MAX_DIFF_LINE:,} more characters on this line)"
    return "\n".join(lines)


def parse_diff(diff: str) -> list[list]:
    """One row per changed file: path, lines added, lines removed, its patch."""
    files = []
    for part in re.split(r"(?m)^(?=diff --git )", diff):
        if not part.strip():
            continue
        head, marker, rest = part.partition("\n@@")
        patch = "@@" + rest if marker else ""
        path = ""
        for line in head.splitlines():
            name = line[4:].strip()
            if line.startswith("+++ ") and name != "/dev/null":
                path = name
            elif line.startswith("--- ") and name != "/dev/null" and not path:
                path = name
        if path[:2] in ("a/", "b/"):
            path = path[2:]
        if not path:
            named = re.match(r"diff --git a/(.*) b/(.*)", head)
            path = named.group(2) if named else "A file"
        lines = patch.splitlines()
        files.append([gametext.readable(path, 160), sum(line.startswith("+") for line in lines),
                      sum(line.startswith("-") for line in lines),
                      None if gametext.SECRET_FILE_RE.search(path) else shorten_long_lines(patch).rstrip("\n")])
    return files


def fit_patches(files: list[list]) -> list[list]:
    """What goes in one snapshot. A file that doesn't fit is listed, and comes in pages when opened."""
    fitted, spent = [], 0
    for path, added, removed, patch in files:
        if patch is None:
            fitted.append([path, added, removed, "", True, True])  # The last field: kept out on purpose.
            continue
        size = len(patch.encode("utf-8", "replace"))
        fits = size <= settings.MAX_PATCH_BYTES and spent + size <= settings.MAX_LOADED_BYTES
        if fits:
            spent += size
        fitted.append([path, added, removed, gametext.message_text(patch) if fits else "", fits])
    return fitted


def patch_pages(patch: str) -> list[list]:
    """A big patch in pages small enough to draw: each is its first old line, first new line, text."""
    pages, current, size = [], [], 0
    old_line = new_line = first_old = first_new = 0
    for line in patch.split("\n"):
        cost = len(line.encode("utf-8", "replace")) + 1
        if current and size + cost > settings.MAX_PAGE_BYTES:
            pages.append([first_old, first_new, "\n".join(current)])
            current, size = [], 0
            first_old, first_new = old_line, new_line
        hunk = re.match(r"@@ -(\d+)(?:,\d+)? \+(\d+)", line)
        if hunk:
            old_line, new_line = int(hunk.group(1)), int(hunk.group(2))
            if not current:
                first_old, first_new = old_line, new_line
        elif line.startswith("+"):
            new_line += 1
        elif line.startswith("-"):
            old_line += 1
        elif not line.startswith("\\"):
            old_line += 1
            new_line += 1
        current.append(line)
        size += cost
    if current:
        pages.append([first_old, first_new, "\n".join(current)])
    return pages


def linked_pull_request(thread: dict, argument: str) -> dict | None:
    """Only one this thread really links, so the game can't ask about anything else."""
    number = int(argument) if argument.strip().isdigit() else None
    return next((link for link in thread.get("pullRequests") or [] if link.get("number") == number), None)


def load_diff(bridge, thread_id: str) -> None:
    diff = bridge.remote.thread_diff(thread_id)
    note = ""
    if not diff:
        note = "T3 has no changes to show for this thread."
    elif len(diff) >= settings.T3_DIFF_LIMIT:
        note = "T3 cuts diffs off at 10 MB, so some files may be missing here."
    files = parse_diff(diff)
    bridge.patches = {"thread": thread_id, "pr": 0, "files": {row[0]: row[3] for row in files}}
    bridge.keep_loaded(thread_id, df=fit_patches(files), dn=note, dp=0)


def load_pull_request_diff(bridge, thread: dict, argument: str) -> str:
    """One pull request's own files, for going into it. Sent the same way as the thread's changes."""
    link = linked_pull_request(thread, argument)
    if link is None:
        return "failed: that pull request isn't linked to this thread"
    patch, cut = bridge.remote.pr_diff(thread.get("projectId"), link)
    note = ""
    if not patch:
        note = "T3 has no changes to show for this pull request."
    elif cut:
        note = "This diff got cut off, so some files may be missing here. GitHub has all of it."
    files = parse_diff(patch)
    number = link["number"]
    bridge.patches = {"thread": thread["id"], "pr": number, "files": {row[0]: row[3] for row in files}}
    bridge.keep_loaded(thread["id"], df=fit_patches(files), dn=note, dp=number)
    return "sent"


def load_file_page(bridge, thread: dict, argument: str) -> str:
    """A page of a big file, from the thread's changes, or from a pull request's when it names one."""
    thread_id = thread["id"]
    path, _, rest = argument.partition("\n")
    wanted, _, pull_request = rest.partition("\n")
    number = int(pull_request) if pull_request.strip().isdigit() else 0
    if bridge.patches.get("thread") != thread_id or bridge.patches.get("pr", 0) != number:
        if number:
            answer = load_pull_request_diff(bridge, thread, pull_request)
            if answer != "sent":
                return answer
        else:
            files = parse_diff(bridge.remote.thread_diff(thread_id))
            bridge.patches = {"thread": thread_id, "pr": 0, "files": {row[0]: row[3] for row in files}}
    patch = bridge.patches["files"].get(path)
    if patch is None:
        return "failed: that file can't be shown here"
    pages = patch_pages(patch)
    number = max(1, min(int(wanted or 1), len(pages)))
    first_old, first_new, text = pages[number - 1]
    bridge.keep_loaded(thread_id, fp=[path, number, len(pages), first_old, first_new, gametext.message_text(text)])
    return "sent"
