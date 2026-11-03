"""Pull requests linked to a thread: their rows in the snapshot, their CI, and the page you can open."""
from __future__ import annotations

import re
import time

from . import diffs, gametext, settings, t3errors, threadstate


def summarize_checks(checks: list[dict]) -> dict:
    """CI as one state, how many passed, and what failed. Skipped checks don't count either way."""
    counted = [check for check in checks if check.get("status") not in ("skipped", "neutral")]
    failing = [gametext.readable(check.get("name") or "A check", 60) for check in counted
               if check.get("status") in ("failure", "action-required", "cancelled")]
    passed = sum(check.get("status") == "success" for check in counted)
    state = "failing" if failing else "pending" if passed < len(counted) else "passing"
    return {"st": state, "p": passed, "t": len(counted), "f": failing[:3], "fn": len(failing)}


# Hosts let people write HTML and pictures into comments. The game can draw neither. The lengths are
# bounded because anyone can write a comment, and one full of "<a" shouldn't stall the companion app.
PR_IMAGE_RE = re.compile(r"!\[([^\]\n]{0,200})\]\([^)\n]{0,2000}\)")
PR_IMG_TAG_RE = re.compile(r"<img\b[^>\n]{0,2000}>", re.I)
PR_BREAK_RE = re.compile(r"<br\s{0,8}/?>", re.I)
PR_TAG_RE = re.compile(r"</?(?:a|b|i|u|s|p|em|strong|sub|sup|small|del|ins|hr|h[1-6]|ul|ol|li|table|thead|tbody|tr|td|th|div|span|kbd|code|pre"
                       r"|blockquote|details|summary|picture|source|center|g-emoji|dl|dt|dd)\b[^>\n]{0,2000}>", re.I)


def without_html_comments(text: str) -> str:
    kept, at = [], 0
    while True:
        start = text.find("<!--", at)
        if start < 0:
            return "".join(kept) + text[at:]
        kept.append(text[at:start])
        end = text.find("-->", start + 4)
        if end < 0:  # Never closed, so the rest is a comment too, as it would be on the page.
            return "".join(kept)
        at = end + 3


def pull_request_text(text: str) -> str:
    """A description or comment for the game. Markdown stays, and code stays exactly as written."""
    lines, in_code = [], False
    for line in without_html_comments(str(text or "")).split("\n"):
        if line.lstrip().startswith("```"):
            in_code = not in_code
        elif not in_code:
            line = PR_IMAGE_RE.sub(lambda found: f"[picture: {found.group(1)}]" if found.group(1) else "[picture]", line)
            line = PR_IMG_TAG_RE.sub("[picture]", line)
            line = PR_BREAK_RE.sub("\n", line)
            line = PR_TAG_RE.sub("", line)
        lines.append(line)
    text = re.sub(r"\n{3,}", "\n\n", gametext.message_text("\n".join(lines))).strip()
    if len(text) > settings.MAX_PR_TEXT:
        text = text[:settings.MAX_PR_TEXT].rstrip() + "\n\n(The rest is on the pull request.)"
    return text


def pull_request_person(actor: dict | None) -> tuple[str, bool]:
    actor = actor or {}
    return gametext.readable(actor.get("login") or actor.get("name") or "Someone", 40), bool(actor.get("isBot"))


def review_verdict(comment: dict) -> str:
    """What a review decided. A plain COMMENTED one decides nothing."""
    state = str(comment.get("reviewState") or "").lower().replace("_", "-")
    return state if state in ("approved", "changes-requested", "dismissed") else ""


def pull_request_discussion(activity: dict) -> list[dict]:
    """Comments oldest first, as a page shows them. A review thread is one entry with its replies under
    it, and a review that only wraps its inline comments has nothing to say of its own."""
    comments = [comment for comment in activity.get("comments") or [] if isinstance(comment, dict)]
    by_id = {comment.get("id"): comment for comment in comments}
    in_threads, entries = set(), []
    for review_thread in activity.get("reviewThreads") or []:
        rows = [by_id.get(row.get("id"), row) for row in review_thread.get("comments") or []]
        rows.sort(key=lambda row: threadstate.to_epoch(row.get("createdAt")))
        if not rows:
            continue
        in_threads.update(row.get("id") for row in rows)
        who, _ = pull_request_person(rows[0].get("author"))
        entry = {"w": who, "bt": all(pull_request_person(row.get("author"))[1] for row in rows), "at": int(threadstate.to_epoch(rows[0].get("createdAt"))),
                 "b": pull_request_text(rows[0].get("body")), "pa": gametext.readable(review_thread.get("path") or "", 200)}
        if review_thread.get("line"):
            entry["ln"] = review_thread["line"]
        if review_thread.get("isResolved"):
            entry["rs"] = True
        if review_thread.get("isOutdated"):
            entry["ol"] = True
        if rows[1:]:
            entry["re"] = [[*pull_request_person(row.get("author")), int(threadstate.to_epoch(row.get("createdAt"))), pull_request_text(row.get("body"))] for row in rows[1:]]
        more = (review_thread.get("commentCount") or len(rows)) - len(rows)
        if more > 0:
            entry["mr"] = more
        entries.append(entry)
    for comment in comments:
        if comment.get("id") in in_threads:
            continue
        body, verdict = pull_request_text(comment.get("body")), review_verdict(comment)
        if not body and not verdict:
            continue
        who, bot = pull_request_person(comment.get("author"))
        entry = {"w": who, "bt": bot, "at": int(threadstate.to_epoch(comment.get("createdAt"))), "b": body}
        if verdict:
            entry["st"] = verdict
        entries.append(entry)
    entries.sort(key=lambda entry: entry["at"])
    entries = entries[-settings.MAX_PR_ENTRIES:]
    # The game has to load all of this, so past the budget the oldest give up their words.
    spent = 0
    for entry in reversed(entries):
        spent += len(entry["b"]) + sum(len(reply[3]) for reply in entry.get("re") or [])
        if spent > settings.MAX_LOADED_BYTES:
            entry.update(b="", cut=True)
            entry.pop("re", None)
        entry["g"] = gametext.readable(next((line for line in entry["b"].split("\n") if line.strip()), ""), 100)
    return entries


def pull_request_timeline(detail: dict, activity: dict, discussion: list[dict]) -> list[list]:
    """Everything that happened, newest first. A comment's row points at its entry, so the words only travel once."""
    events = []
    if detail.get("createdAt"):
        events.append(["opened", int(threadstate.to_epoch(detail["createdAt"])), pull_request_person(detail.get("author"))[0]])
    for commit in activity.get("commits") or []:
        events.append(["commit", int(threadstate.to_epoch(commit.get("committedDate"))), gametext.readable(str(commit.get("oid") or "")[:7], 7),
                       gametext.readable(commit.get("messageHeadline") or "", 120), commit.get("additions") or 0, commit.get("deletions") or 0])
    events.extend(["note", entry["at"], index] for index, entry in enumerate(discussion, 1))
    if detail.get("mergedAt"):
        events.append(["merged", int(threadstate.to_epoch(detail["mergedAt"]))])
    elif detail.get("closedAt"):
        events.append(["closed", int(threadstate.to_epoch(detail["closedAt"]))])
    events.sort(key=lambda event: -event[1])
    return events[:settings.MAX_PR_EVENTS]


def pull_request_reviews(activity: dict) -> list[list[str]]:
    """Where each reviewer stands now: only their latest verdict counts, and a dismissed one doesn't."""
    latest: dict[str, tuple[float, str]] = {}
    for comment in activity.get("comments") or []:
        verdict = review_verdict(comment)
        if verdict:
            who, _ = pull_request_person(comment.get("author"))
            when = threadstate.to_epoch(comment.get("createdAt"))
            if who not in latest or latest[who][0] <= when:
                latest[who] = (when, verdict)
    return [[who, verdict] for who, (_, verdict) in latest.items() if verdict != "dismissed"]


def named_checks(checks: list[dict]) -> tuple[list[list[str]], list[list], int]:
    """Real ones run to 70 checks, mostly green. Name what needs a look and count the rest."""
    order = {"failure": 0, "action-required": 0, "cancelled": 0, "pending": 1, "success": 2, "neutral": 3, "skipped": 3}
    checks = sorted(checks, key=lambda check: order.get(check.get("status"), 1))
    tally: dict[str, int] = {}
    for check in checks:
        status = gametext.readable(check.get("status") or "", 16)
        tally[status] = tally.get(status, 0) + 1
    loud = [check for check in checks if check.get("status") not in ("success", "neutral", "skipped")]
    rows = [[gametext.readable(check.get("name") or "A check", 80), gametext.readable(check.get("status") or "", 16)] for check in loud[:settings.MAX_CHECKS]]
    return rows, [[status, count] for status, count in tally.items()], max(0, len(loud) - settings.MAX_CHECKS)


def pull_request_rows(thread: dict, known_checks: dict) -> list[dict]:
    """Every pull request linked to a thread, open ones first and then the newest. T3 keeps these up to
    date itself, so this costs nothing to ask. `known_checks` adds what we learned about CI directly."""
    rows = []
    for link in thread.get("pullRequests") or []:
        snapshot = link.get("snapshot") or {}
        number = link.get("number")
        if not isinstance(number, int):
            continue
        row = {"n": number, "ti": gametext.readable(snapshot.get("title") or "Untitled", 200),
               "st": gametext.readable(snapshot.get("state") or "", 12), "ck": gametext.readable(snapshot.get("checksState") or "", 12),
               "rv": gametext.readable(snapshot.get("reviewDecision") or "", 20), "mg": gametext.readable(snapshot.get("mergeability") or "", 16),
               "a": snapshot.get("additions") or 0, "d": snapshot.get("deletions") or 0, "f": snapshot.get("changedFiles") or 0,
               "hb": gametext.readable(snapshot.get("headBranch") or "", 80), "bb": gametext.readable(snapshot.get("baseBranch") or "", 80),
               "au": gametext.readable((snapshot.get("author") or {}).get("login") or "", 40), "r": gametext.readable(link.get("repository") or "", 80),
               "at": threadstate.to_epoch(snapshot.get("updatedAt"))}
        if snapshot.get("isDraft"):
            row["dr"] = True
        url = str(link.get("url") or "")
        if url.startswith("https://"):
            row["u"] = gametext.readable(url, 300)
        known = known_checks.get((link.get("repository"), number)) or {}
        # T3 keeps its own state current, so what we asked long ago doesn't get to outvote it.
        if known.get("st") and time.monotonic() - known.get("asked", 0) < settings.CHECK_SECONDS * 2:
            row.update(ck=known["st"], cp=known.get("p", 0), ct=known.get("t", 0))
        rows.append(row)
    rows.sort(key=lambda row: (row["st"] != "open", -row["at"]))
    return rows[:settings.MAX_PULL_REQUESTS]


def load_pull_request(bridge, thread: dict, argument: str) -> str:
    """Only for a pull request this thread really links, so the game can't ask about anything else."""
    link = diffs.linked_pull_request(thread, argument)
    if link is None:
        return "failed: that pull request isn't linked to this thread"
    number = link["number"]
    project = thread.get("projectId")
    problems = []

    def ask(call) -> dict | None:
        try:
            return call(project, link) or {}
        except (t3errors.SendRefused, t3errors.SendUncertain, t3errors.T3Changed, OSError, ValueError, KeyError, AttributeError) as error:
            problems.append(str(error))
            return None

    detail, activity = ask(bridge.remote.pr_detail), ask(bridge.remote.pr_activity)
    page: dict = {}
    if detail is not None:
        checks = detail.get("checks") or []
        # Only an open one's checks can still move, and asking makes T3 go and look.
        if (link.get("snapshot") or {}).get("state") == "open":
            checks = (ask(bridge.remote.pr_checks) or {}).get("checks") or checks
        bridge.pr_checks[(link.get("repository"), number)] = dict(summarize_checks(checks), asked=time.monotonic())
        rows, tally, left_out = named_checks(checks)
        page.update(b=pull_request_text(detail.get("body")), oa=int(threadstate.to_epoch(detail.get("createdAt"))), cs=rows, ct=tally, cm=left_out,
                    lb=[gametext.readable(label.get("name") or "", 40) for label in detail.get("labels") or [] if isinstance(label, dict)][:12])
        if detail.get("behindBy"):
            page["bh"] = detail["behindBy"]
    if activity is not None:
        discussion = pull_request_discussion(activity)
        page.update(ds=discussion, tl=pull_request_timeline(detail or {}, activity, discussion), rv=pull_request_reviews(activity), dn=activity.get("commentCount") or 0)
        if activity.get("commentsTruncated") or activity.get("reviewThreadsTruncated"):
            page["tr"] = True
    if problems:
        page["er"] = gametext.readable(problems[0], 200)
    bridge.keep_loaded(thread["id"], pd=[number, page])
    return f"failed: {gametext.readable(problems[0], 200)}" if detail is None and activity is None else "sent"
