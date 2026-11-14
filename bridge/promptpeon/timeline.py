"""Turning what T3 holds inside one thread into the rows the game's log shows."""
from __future__ import annotations

import hashlib
import json
import re
import zlib

from . import gametext, settings, threadstate


# "waiting" is an open question or approval. T3 sends it, not "running", while it waits on you.
RUNNING_STATES = {"running", "in_progress", "inProgress", "pending", "started", "streaming", "waiting"}
FAILED_STATES = {"failed", "error"}
STOPPED_STATES = {"cancelled", "interrupted"}
NOTICE_KINDS = {"notification", "system_notice", "compaction", "handoff", "run_interrupt_request", "run_interrupt_result"}


def state_of(item: dict) -> str:
    """r running, f failed, c stopped, d done."""
    status = item.get("status")
    if status in RUNNING_STATES:
        return "r"
    if status in FAILED_STATES:
        return "f"
    if status in STOPPED_STATES:
        return "c"
    return "d"


def first_line(text, limit: int = 200) -> str:
    for line in str(text or "").splitlines():
        if line.strip():
            return gametext.readable(line.strip(), limit)
    return ""


def short_tool(name) -> str:
    return first_line(str(name or "").split("__")[-1])


def file_name(path) -> str:
    return re.split(r"[\\/]", str(path or ""))[-1]


def step_label(item: dict) -> str:
    """One line for a step, the way T3 shows it collapsed. Tool output stays out of the game."""
    kind, title = item.get("type"), item.get("title")
    if kind == "command_execution":
        command = item.get("input")
        if isinstance(command, dict):
            command = command.get("command") or json.dumps(command)
        return f"Ran {first_line(command)}" if command else first_line(title) or "Ran a command"
    if kind == "dynamic_tool":
        return short_tool(item.get("toolName") or title) or "Used a tool"
    if kind == "file_change":
        return f"Edited {file_name(item.get('fileName'))}" if item.get("fileName") else first_line(title) or "Edited a file"
    if kind == "web_search":
        patterns = item.get("patterns") or []
        return f"Searched the web: {first_line(patterns[0])}" if patterns else first_line(title) or "Searched the web"
    if kind == "subagent":
        return f"Agent: {first_line(title)}" if title else "Started an agent"
    if kind == "notification":
        return first_line(item.get("summary") or title)
    if kind == "system_notice":
        return first_line(item.get("message") or title)
    return first_line(title)


def todo_text(item: dict) -> str:
    marks = {"completed": "[x]", "in_progress": "[>]", "inProgress": "[>]", "running": "[>]"}
    return "\n".join(f"{marks.get(step.get('status'), '[ ]')} {gametext.readable(step.get('text') or '')}"
                     for step in item.get("steps") or [])


def question_text(item: dict) -> str:
    parts = []
    for question in item.get("questions") or []:
        parts.append(gametext.readable(question.get("question") or ""))
        parts += [f"- {gametext.readable(option.get('label') or '')}" for option in question.get("options") or []]
    return "\n".join(part for part in parts if part)


def question_choices(item: dict) -> dict | None:
    """What the game needs to answer an open question itself: T3's request id, and each question
    with its answers in T3's order. None when it has to be answered in T3: a question the game
    can't show whole, or one that a normal reply answers."""
    request, questions = item.get("requestId"), item.get("questions")
    if not isinstance(request, str) or not request or item.get("responseMode") == "message":
        return None
    if not isinstance(questions, list) or not 0 < len(questions) <= settings.MAX_QUESTIONS:
        return None
    shown = []
    for question in questions:
        if not isinstance(question, dict) or not isinstance(question.get("id"), str) or not question["id"]:
            return None
        options = answer_options(question)
        if len(options) > settings.MAX_ANSWER_OPTIONS:
            return None
        shown.append({
            "h": gametext.readable(question.get("header") or "", 40),
            "t": gametext.readable(question.get("question") or "", 400),
            "m": question.get("multiSelect") is True,
            # T3 takes a typed answer unless the question says it doesn't.
            "c": question.get("allowCustomAnswer") is not False,
            "o": [[gametext.readable(option["label"], 80), gametext.readable(option.get("description") or "", 200)] for option in options],
        })
    if not any(entry["o"] or entry["c"] for entry in shown):
        return None
    return {"r": question_mark(item), "q": shown}


APPROVAL_KINDS = {"command": "run a command", "file-read": "read a file", "file-change": "change files"}


def fingerprint(*fields) -> str:
    """What the game sends back with an answer or a decision: a fingerprint of everything that
    decided it, each field kept apart from the next. The companion app works it out again from T3
    when the answer arrives. If anything changed, it isn't what was read, and it is refused."""
    return hashlib.sha256(json.dumps(fields, ensure_ascii=True, separators=(",", ":")).encode("ascii")).hexdigest()[:32]


def exactly_showable(text: str) -> bool:
    """Whether the game shows this text exactly as it is: plain printable ASCII and line breaks,
    with nothing the secret filter would hide. Anything else can look different from what it is,
    such as an invisible character, text that runs right to left, or a letter the font lacks."""
    return all(char == "\n" or " " <= char <= "~" for char in text) and gametext.message_text(text) == text


def approval_parts(item: dict) -> dict | None:
    """What the agent is asking to do, in the pieces the game shows: what kind of thing ("k"), the
    request itself ("c"), and the agent's own reason if it gave one ("y"). The game draws the reason
    apart from the request, so nothing inside a request can pass for a reason.

    None when the game can't show every character as it is, and then the game can't approve it:
    nobody should approve something they couldn't read."""
    prompt, reason = item.get("prompt"), item.get("reason")
    if not isinstance(prompt, str) or not prompt.strip():
        return None
    prompt, reason = prompt.strip(), reason.strip() if isinstance(reason, str) else ""
    if len(prompt) + len(reason) > settings.MAX_APPROVAL_CHARS:
        return None
    if not exactly_showable(prompt) or not exactly_showable(reason):
        return None
    return {"k": APPROVAL_KINDS.get(item.get("requestKind"), "do something it needs your approval for"), "c": prompt, "y": reason}


def approval_mark(item: dict) -> str | None:
    """The fingerprint of an approval request: its thread, T3's request id, its kind, the request
    and the reason. None when the game can't approve this one."""
    parts, request = approval_parts(item), item.get("requestId")
    if not parts or not isinstance(request, str) or not request:
        return None
    return fingerprint("approval", item.get("threadId") or "", request, item.get("requestKind") or "", parts["c"], parts["y"])


def question_mark(item: dict) -> str:
    """The fingerprint of an open question: its thread, T3's request id, and every question with its
    answers in order, down to the value T3 would be sent. So an answer picked by its number can
    only ever mean what it meant when it was read."""
    questions = [[question.get("id"), question.get("question"), question.get("header"), question.get("multiSelect") is True,
                  question.get("allowCustomAnswer") is not False,
                  [[option.get("label"), option.get("description"), option.get("value")] for option in answer_options(question)]]
                 for question in item.get("questions") or [] if isinstance(question, dict)]
    return fingerprint("question", item.get("threadId") or "", item.get("requestId") or "", item.get("responseMode") or "", questions)


def answer_options(question: dict) -> list[dict]:
    """A question's answers that can be picked, in T3's order. The game counts them from 1."""
    return [option for option in question.get("options") or [] if isinstance(option, dict) and isinstance(option.get("label"), str) and option["label"].strip()]


def build_timeline(items: list[dict]) -> list[list]:
    """The thread as T3 shows it, as rows of [kind, text, state, order].

    Kinds: u you, a agent, t thinking, s step, n notice, d todo list, q open question.
    Messages and thinking are never cut. Step labels are one line, and output is left out.
    """
    items = sorted(items, key=lambda item: item.get("ordinal") or 0)
    spots = [index for index, item in enumerate(items)
             if item.get("type") in ("user_message", "assistant_message") and item.get("text")]
    if len(spots) > settings.MESSAGES_PER_THREAD:
        items = items[spots[-settings.MESSAGES_PER_THREAD]:]
    last_todo = max((index for index, item in enumerate(items) if item.get("type") == "todo_list"), default=-1)
    rows: list[list] = []
    for index, item in enumerate(items):
        kind, state, order = item.get("type"), state_of(item), item.get("ordinal") or 0
        text = item.get("text")
        if kind == "user_message":
            if text:
                rows.append(["u", gametext.message_text(text), state, order])
        elif kind == "assistant_message":
            if text:
                rows.append(["a", gametext.message_text(text), state, order])
        elif kind == "reasoning":
            if text:
                rows.append(["t", gametext.message_text(text), state, order])
        elif kind == "todo_list":
            if index == last_todo and item.get("steps"):
                rows.append(["d", todo_text(item), state, order])
        elif kind == "user_input_request":
            question = question_text(item)
            if question and state == "r":
                choices = question_choices(item)
                rows.append(["q", question, state, order, choices] if choices else ["q", question, state, order])
            elif question:
                rows.append(["n", f"Asked: {first_line(question)}", state, order])
        elif kind == "approval_request" and state == "r":
            mark, parts = approval_mark(item), approval_parts(item)
            if mark:
                # The request is the row's words. Its kind and the agent's reason ride beside it, kept apart.
                rows.append(["p", parts["c"], state, order, {"r": mark, "k": parts["k"], **({"y": parts["y"]} if parts["y"] else {})}])
            else:
                rows.append(["n", "Waiting for your approval. Answer it in T3.", state, order])
        elif kind == "checkpoint":
            files = item.get("files") or []
            if files:
                added = sum(entry.get("additions") or 0 for entry in files)
                removed = sum(entry.get("deletions") or 0 for entry in files)
                word = "file" if len(files) == 1 else "files"
                rows.append(["n", f"{len(files)} {word} changed  +{added} -{removed}", state, order])
        elif kind == "subagent":
            result = gametext.message_text(item.get("result")) if item.get("result") else ""
            rows.append(["sa", first_line(item.get("title")) or "Agent", state, order, result])
        elif kind in NOTICE_KINDS:
            label = step_label(item)
            if label:
                rows.append(["n", label, state, order])
        else:
            label = step_label(item)
            if label:
                rows.append(["s", label, state, order])
            if item.get("viewedImagePath"):
                rows.append(["i", file_name(item["viewedImagePath"]), state, order, {"p": item["viewedImagePath"]}])
        for attachment in item.get("attachments") or []:
            if attachment.get("type") == "image" and attachment.get("id"):
                rows.append(["i", gametext.readable(attachment.get("name") or "image", 80), "d", order,
                             {"a": attachment["id"], "n": attachment.get("name") or ""}])
    return rows


def doing_now(items: list[dict]) -> str:
    """The words for what the agent is doing right this moment."""
    for item in sorted(items, key=lambda entry: entry.get("ordinal") or 0, reverse=True):
        if state_of(item) != "r" and not item.get("streaming"):
            continue
        kind = item.get("type")
        if kind == "reasoning":
            return "Thinking"
        if kind == "assistant_message":
            return "Writing a reply"
        if kind == "user_input_request":
            return "Waiting for your answer"
        if kind == "file_search":
            return "Searching files"
        if kind == "web_search":
            return "Searching the web"
        if kind == "file_change":
            name = file_name(item.get("fileName"))
            return f"Editing {name}" if name else "Editing a file"
        if kind == "command_execution":
            return "Running a command"
        label = step_label(item)
        if label:
            return label
    return "Working"


def rows_left_out(items: list[dict], rows: list[list]) -> bool:
    """True if the timeline was cut, so older items exist than the first row it kept."""
    first = next((row[3] for row in rows if row[3]), None)
    return first is not None and any((item.get("ordinal") or 0) < first for item in items)


def fit_older_rows(rows: list[list], items: list[dict], more: bool) -> tuple[list, bool]:
    """Older rows for one snapshot, newest kept first. Pictures become a line: the picture files
    are for what is on screen now, and old threads could use them all up."""
    kept, spent = [], 0
    for row in reversed(rows):
        if row[0] == "i":
            row = ["n", f"Picture: {row[1]}", row[2], row[3]]
        spent += len(str(row[1]).encode("utf-8", "replace"))
        if kept and spent > settings.MAX_LOADED_BYTES:
            return kept[::-1], True
        kept.append(row)
    return kept[::-1], more or rows_left_out(items, rows)


def latest_diff_turn(projection: dict) -> int:
    """The newest turn T3 can diff: a ready checkpoint from a run that finished."""
    finished = {run.get("id") for run in projection.get("runs") or [] if run.get("status") == "completed"}
    return max((row.get("appRunOrdinal") or 0 for row in projection.get("checkpoints") or []
                if row.get("status") == "ready" and row.get("runId") in finished), default=0)


def describe_agents(subagents: list[dict]) -> tuple[list, dict]:
    """T3's subagents, newest first: a light row for every refresh, and their words for when you open them."""
    ordered = sorted(subagents, key=lambda row: str(row.get("startedAt") or row.get("updatedAt") or ""), reverse=True)
    rows, words = [], {}
    for agent in ordered[:settings.MAX_AGENTS]:
        key = f"k{zlib.crc32(str(agent.get('id')).encode()):08x}"
        rows.append([key, first_line(agent.get("title")) or "Agent", state_of(agent),
                     gametext.readable(agent.get("model") or agent.get("driver") or "", 40), threadstate.to_epoch(agent.get("startedAt"))])
        words[key] = [gametext.message_text(agent.get("prompt") or ""), gametext.message_text(agent.get("result") or "")]
    return rows, words


def describe_thread(projection: dict) -> dict:
    items = list(projection.get("turnItems") or [])
    messages = projection.get("messages") or []
    if not items:
        ordered = sorted(messages, key=lambda message: message.get("createdAt") or "")
        items = [{"type": "user_message" if message.get("role") == "user" else "assistant_message",
                  "text": message.get("text") if message.get("role") in ("user", "assistant") else None,
                  "status": "completed", "ordinal": index} for index, message in enumerate(ordered)]
    rows = build_timeline(items)
    # A queued message has no timeline item until its turn starts, so T3 lists it separately.
    queued_runs = {run.get("id") for run in projection.get("runs") or [] if run.get("status") == "queued"}
    placed = {item.get("messageId") for item in items if item.get("messageId")}
    queued = [message for message in messages if message.get("runId") in queued_runs
              and message.get("role") == "user" and message.get("id") not in placed and message.get("text")]
    for message in queued:
        rows.append(["u", gametext.message_text(message["text"]), "q", 0, message["runId"]])
    context = None
    for provider_thread in reversed(projection.get("providerThreads") or []):
        usage = provider_thread.get("contextUsage") or {}
        if usage.get("maxTokens"):
            context = round(usage.get("usedTokens", 0) * 100 / usage["maxTokens"])
            break
    # Every file this window of the thread touched, newest numbers winning, as T3 lists them.
    changes: dict[str, list] = {}
    for item in sorted(items, key=lambda entry: entry.get("ordinal") or 0):
        if item.get("type") == "checkpoint":
            for entry in item.get("files") or []:
                if entry.get("path"):
                    changes[entry["path"]] = [gametext.readable(entry["path"], 160), entry.get("kind") or "modified",
                                              entry.get("additions") or 0, entry.get("deletions") or 0]
    subagents = projection.get("subagents") or []
    agents, agent_words = describe_agents(subagents)
    turns = max((run.get("ordinal") or 0 for run in projection.get("runs") or [] if run.get("status") == "completed"), default=0)
    last_change = None
    for item in sorted(items, key=lambda entry: entry.get("ordinal") or 0):
        if item.get("type") == "checkpoint" and item.get("files"):
            last_change = [len(item["files"]), sum(entry.get("additions") or 0 for entry in item["files"]),
                           sum(entry.get("deletions") or 0 for entry in item["files"]), item.get("ordinal") or 0]
    return {"turns": turns, "last_change": last_change, "rows": rows, "activity": doing_now(items), "queued": len(queued_runs), "context": context,
            "changes": list(changes.values()), "can_diff": latest_diff_turn(projection) > 0,
            "agents": agents, "agents_total": len(subagents), "agent_words": agent_words}
