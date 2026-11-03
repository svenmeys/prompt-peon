"""What can go wrong talking to T3, and the plain words a player sees when it does."""
from __future__ import annotations

import json
import re
import urllib.error

from . import console, gametext, savedvars


# T3's remote API isn't public, so an update can change any of it. These are what the player sees then.
T3_CHANGED = ("T3 answered in a way this version of Prompt Peon doesn't understand. "
              "If T3 just updated, get the newest Prompt Peon and run the installer again.")
T3_DIDNT_UNDERSTAND = ("T3 didn't understand that. If T3 just updated, get the newest Prompt Peon "
                       "and run the installer again.")
T3_CHANGED_CODES = (400, 404, 406, 410, 426)  # Protocol 2 gone, or a route gone. Protocol 3 answers 400 today.


class T3Changed(Exception):
    """T3 answered, but not in a shape we know."""


class SendRefused(Exception):
    """T3 definitely did not take the message. Safe to report as failed."""


class SendUncertain(Exception):
    """The message may have gone through. Never retry this one."""


def describe_failure(outcome: dict) -> str:
    """Pull the human message out of an Effect RPC failure without dumping the whole thing."""
    text = json.dumps(outcome)
    # "Fail" is T3 saying no. "Die" is T3 not understanding: a call it doesn't have, or a shape it doesn't take.
    causes = outcome.get("cause") if isinstance(outcome, dict) else None
    if isinstance(causes, list) and any(isinstance(cause, dict) and cause.get("_tag") == "Die" for cause in causes):
        console.log(f"T3 didn't understand a call: {gametext.hide_secrets(text)[:200]}")
        return T3_DIDNT_UNDERSTAND
    found = re.search(r'"message":\s*"([^"]{1,200})"', text)
    if found:
        return found.group(1)
    console.log(f"T3 refused without saying why: {gametext.hide_secrets(text)[:200]}")
    return "T3 refused that."


def check_shell(shell) -> dict:
    """The one answer everything else stands on. A new shape must read as that, not as a crash."""
    if not isinstance(shell, dict) or not isinstance(shell.get("threads"), list) or not isinstance(shell.get("projects", []), list):
        raise T3Changed("no thread list")
    for thread in shell["threads"]:
        if not isinstance(thread, dict) or not isinstance(thread.get("id"), str):
            raise T3Changed("a thread with no id")
        # An id goes inside a chat link in the game, so one with a | in it could fake what chat says.
        if not savedvars.good_thread_id(thread["id"]):
            raise T3Changed("a thread with a strange id")
    return shell


def plain_refusal(error: Exception) -> str:
    """T3's refusals can name its own run ids, which mean nothing to the person playing."""
    if isinstance(error, (T3Changed, KeyError, TypeError, AttributeError, json.JSONDecodeError)):
        return T3_CHANGED
    if isinstance(error, urllib.error.HTTPError) and error.code in T3_CHANGED_CODES:
        return T3_CHANGED
    words = str(error)
    if "is not queued" in words:
        return "that message already started, so it can't be changed"
    if "pending approval" in words and "cannot be snoozed" in words:
        return "it's waiting on you, so it can't be snoozed"
    if "cannot be snoozed" in words:
        return "it has a queued message, so it can't be snoozed"
    return words
