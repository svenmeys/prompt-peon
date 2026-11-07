"""What each command from the game does. A command starts with a byte no keyboard can type into a reply."""
from __future__ import annotations

import time

from . import catalog, diffs, gametext, gates, pullrequests, settings, t3errors, threadstate, timeline


def run_command(bridge, seq: int, thread_id: str, text: str, size: int) -> None:
    verb, _, argument = text[1:].partition("\n")
    if (bridge.state.get("inflight") or {}).get("seq") == seq:
        # We died while running this one. Running it twice could start a second thread.
        bridge.finish(seq, thread_id, size, "unknown: the companion app stopped during this. Check T3.")
        return
    bridge.state["inflight"] = {"seq": seq, "message_id": ""}
    bridge.save_state()
    try:
        bridge.finish(seq, thread_id, size, command_result(bridge, verb, thread_id, argument))
    except t3errors.SendUncertain as error:
        bridge.finish(seq, thread_id, size, f"unknown: {error}. Check T3.")
    except (t3errors.SendRefused, t3errors.T3Changed, OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        bridge.finish(seq, thread_id, size, f"failed: {t3errors.plain_refusal(error)}")


def command_result(bridge, verb: str, thread_id: str, argument: str) -> str:
    if verb in ("new", "newm"):
        mode, _, rest = argument.partition("\n")
        if mode not in settings.RUNTIME_MODES:
            # Also what an addon from before modes looks like, still in memory after an update.
            return "failed: Prompt Peon doesn't know that approval mode. Type /reload, then try again"
        # The same check as sending. A mode you can't send to is a mode you can't start.
        if gates.refused_full_access(bridge, {"runtimeMode": mode}):
            return ("failed: Starting agents that can act without asking is off, the same as sending to them. "
                    "Run the Prompt Peon installer again to turn it on")
        if verb == "new":
            return start_thread(bridge, rest, mode)
        parts = rest.split("\n", 4)
        if len(parts) < 5:
            return "failed: say what the new thread should do"
        project, instance, model, effort, prompt = parts
        return start_thread(bridge, f"{project}\n{prompt}", mode, catalog.model_selection(bridge, instance.strip(), model.strip(), effort.strip()))
    if verb == "hidden":
        return set_hidden(bridge, argument)
    known = bridge.known_threads()
    if thread_id not in known:
        if verb == "unsettle":
            return "failed: T3 no longer lists this thread. Reopen it in T3, then try again."
        return "failed: that thread is not on this T3 server"
    if verb in ("diff", "agents", "file", "older", "view", "pr", "prdiff", "answer") and bridge.hides(known[thread_id]):
        return "failed: this thread is hidden. Show it first."
    if verb == "stop":
        bridge.remote.stop_thread(thread_id)
    elif verb == "settle":
        bridge.remote.settle_thread(thread_id)
    elif verb == "unsettle":
        bridge.remote.unsettle_thread(thread_id)
    elif verb == "snooze":
        wake = int(argument) if argument.strip().isdigit() else 0
        if not time.time() < wake <= time.time() + settings.MAX_SNOOZE_SECONDS:
            return "failed: pick a time in the future to snooze until"
        bridge.remote.snooze_thread(thread_id, time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(wake)))
    elif verb == "unsnooze":
        bridge.remote.unsnooze_thread(thread_id)
    elif verb == "view":
        # Pictures stay out: they are only for threads that ride along in every refresh.
        bridge.keep_loaded(thread_id, vm=bridge.previews.prepare(thread_id, bridge.remote.detail(thread_id)["rows"], False))
        return "sent"
    elif verb in ("steer", "editq", "setmodel", "answer") and gates.refused_full_access(bridge, known[thread_id]):
        return gates.refused_full_access(bridge, known[thread_id])
    elif verb == "answer":
        return answer_question(bridge, thread_id, argument)
    elif verb == "steer":
        active = known[thread_id].get("activeRunId")
        if not active:
            return "failed: it isn't working right now, so there is nothing to steer"
        if not argument.strip():
            raise t3errors.SendRefused("no queued message was named")
        bridge.remote.steer_queued(thread_id, argument.strip(), active)
    elif verb == "setmodel":
        instance, model, effort = (argument.split("\n") + ["", ""])[:3]
        bridge.remote.set_model(thread_id, catalog.model_selection(bridge, instance.strip(), model.strip(), effort.strip(), known[thread_id].get("modelSelection")))
    elif verb == "cancelq":
        if not argument.strip():
            raise t3errors.SendRefused("no queued message was named")
        bridge.remote.cancel_queued(thread_id, argument.strip())
    elif verb == "editq":
        run_id, _, text = argument.partition("\n")
        if not run_id.strip():
            raise t3errors.SendRefused("no queued message was named")
        if not text.strip():
            raise t3errors.SendRefused("the new text is empty")
        if len(text.encode("utf-8")) > settings.MAX_REPLY_BYTES:
            raise t3errors.SendRefused(f"the new text is too long. Keep it under {settings.MAX_REPLY_BYTES} bytes")
        bridge.remote.edit_queued(thread_id, run_id.strip(), text)
    elif verb == "diff":
        diffs.load_diff(bridge, thread_id)
        return "sent"
    elif verb == "agents":
        load_agents(bridge, thread_id)
        return "sent"
    elif verb == "pr":
        return pullrequests.load_pull_request(bridge, known[thread_id], argument)
    elif verb == "prdiff":
        return diffs.load_pull_request_diff(bridge, known[thread_id], argument)
    elif verb == "file":
        return diffs.load_file_page(bridge, known[thread_id], argument)
    elif verb == "older":
        before = int(argument)
        rows, more = bridge.remote.older_rows(thread_id, before)
        bridge.keep_loaded(thread_id, ob=rows, om=more, oc=before)
        return "sent"
    else:
        return f"failed: this companion app doesn't know {verb!r}"
    bridge.seen.pop(thread_id, None)
    return "sent"


def answer_question(bridge, thread_id: str, argument: str) -> str:
    """Your answer to the question the agent is waiting on. The game only says which answers you
    picked, counted from 1, or what you typed. What gets sent is T3's own words, read fresh,
    so the game can't answer a question that changed or pick something that isn't offered.

    The argument is the question's mark from the snapshot, then one line per question: "o:2", "o:1,3" or "t:your words".
    """
    request_id, _, lines = argument.partition("\n")
    item = bridge.remote.open_question(thread_id)
    if not item or not isinstance(item.get("requestId"), str) or timeline.request_mark(item["requestId"]) != request_id.strip():
        return "failed: that question isn't open any more. It may have been answered in T3"
    if not timeline.question_choices(item):
        return "failed: answer this one in T3, it doesn't fit in the game"
    questions = item["questions"]
    lines = lines.split("\n")
    if len(lines) != len(questions):
        return "failed: answer every question first"
    answers = {}
    for question, line in zip(questions, lines):
        kind, _, value = line.partition(":")
        if kind == "o":
            options = timeline.answer_options(question)
            try:
                picked = [int(part) for part in value.split(",")]
            except ValueError:
                return "failed: pick one of the answers shown"
            if not picked or len(set(picked)) != len(picked) or not all(1 <= number <= len(options) for number in picked):
                return "failed: pick one of the answers shown"
            if len(picked) > 1 and question.get("multiSelect") is not True:
                return "failed: this question takes one answer"
            # T3's own window sends an answer's value when it has one, and its label when it doesn't.
            words = [options[number - 1].get("value") if isinstance(options[number - 1].get("value"), str) else options[number - 1]["label"]
                     for number in picked]
            answers[question["id"]] = words if question.get("multiSelect") is True else words[0]
        elif kind == "t":
            if question.get("allowCustomAnswer") is False:
                return "failed: this question only takes one of its answers"
            text = value.strip()
            if not text:
                return "failed: type an answer first"
            if len(text.encode("utf-8")) > settings.MAX_REPLY_BYTES:
                return f"failed: the answer is too long. Keep it under {settings.MAX_REPLY_BYTES} bytes"
            answers[question["id"]] = text
        else:
            return "failed: answer every question first"
    bridge.remote.answer_question(thread_id, item["requestId"], answers)
    bridge.seen.pop(thread_id, None)
    return "sent"


def set_hidden(bridge, argument: str) -> str:
    hidden = {"projects": [], "threads": []}
    for line in argument.splitlines():
        kind, _, name = line.partition(":")
        name = name.strip()
        if name and kind in ("p", "t"):
            hidden["projects" if kind == "p" else "threads"].append(name)
    # A picture file doesn't say whose it is, so hiding anything new blanks them all. The rest come back.
    before = bridge.state.get("hidden") or {"projects": [], "threads": []}
    if any(set(hidden[field]) - set(before.get(field, [])) for field in hidden):
        bridge.previews.clear_files(new_session=False)
    # Hiding only takes things away, so anyone may. Showing again brings words back into the game,
    # so an addon you haven't trusted doesn't get to do that.
    refused = gates.refused_by_other_addons(bridge)
    if refused:
        old = bridge.state.get("hidden") or {"projects": [], "threads": []}
        showing = any(set(old.get(field, [])) - set(hidden[field]) for field in hidden)
        for field in hidden:
            hidden[field] = list(dict.fromkeys(list(old.get(field, [])) + hidden[field]))
        bridge.state["hidden"] = hidden
        return refused if showing else "sent"
    bridge.state["hidden"] = hidden
    return "sent"


def start_thread(bridge, argument: str, mode: str, selection: dict | None = None) -> str:
    project_name, _, prompt = argument.partition("\n")
    prompt = prompt.strip()
    if not prompt:
        return "failed: say what the new thread should do"
    shell = bridge.shell or bridge.remote.shell()
    wanted = project_name.strip().lower()
    # The game only knows the shortened name of a long title.
    project = next((p for p in shell.get("projects", []) if wanted in ((p.get("title") or "").lower(), gametext.readable(p.get("title") or "", 60).lower())), None)
    if project is None:
        return f"failed: there is no project called {project_name.strip()}"
    model = selection or threadstate.new_thread_selection(shell, project)
    if not model:
        return "failed: start one thread in T3 first, so we know which model to use"
    bridge.remote.start_thread(project["id"], model, prompt, mode)
    return "sent"


def load_agents(bridge, thread_id: str) -> None:
    words = (bridge.messages.get(thread_id) or {}).get("agent_words") or {}
    kept, spent = {}, 0
    for key, pair in words.items():  # Newest first, so the old ones are what gets left out.
        spent += len(pair[0]) + len(pair[1])
        if spent > settings.MAX_LOADED_BYTES:
            break
        kept[key] = pair
    bridge.keep_loaded(thread_id, ax=kept)
