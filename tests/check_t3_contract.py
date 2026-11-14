#!/usr/bin/env python3
"""Does this T3 still speak what the bridge expects? Run it after every T3 update, against a throwaway server.

    t3 serve --base-dir <empty folder> --port 3999 --host 127.0.0.1
    python3 tests/check_t3_contract.py http://127.0.0.1:3999 <file holding a token>

Safe by design. It only reads, and every command it sends names a thread that doesn't exist, so T3
refuses it. A refusal means T3 understood the command. Not understanding it is what fails this check.
Tokens are never printed.
"""
import json
import sys
import urllib.parse
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "bridge"))
from promptpeon import catalog, settings, t3errors, t3remote  # noqa: E402

NOBODY = "00000000-0000-4000-8000-000000000000"
SHELL_KEYS = ("threads", "projects")
# What the bridge reads from each thread in the shell. A rename of any of these would fail quietly.
THREAD_KEYS = ("id", "title", "projectId", "updatedAt", "settledAt", "snoozedUntil", "archivedAt", "lineage",
               "modelSelection", "providerInstanceId", "runtimeMode", "activeRunId", "pendingRuntimeRequest", "pullRequests")
PROJECTION_KEYS = ("turnItems", "messages", "runs", "checkpoints", "subagents", "providerThreads", "thread")
COMMANDS = {
    "thread.stop": {},
    "thread.settle": {},
    "thread.unsettle": {"reason": "user"},
    "thread.snooze": {"snoozedUntil": "2099-01-01T00:00:00.000Z"},
    "thread.unsnooze": {"reason": "user"},
    "thread.model-selection.set": {"modelSelection": {"instanceId": "claudeAgent", "model": "claude-haiku-5-5", "options": []}},
    "queued-run.cancel": {"runId": "run:nobody"},
    "queued-run.edit": {"runId": "run:nobody", "text": "x"},
    "queued-message.promote-to-steer": {"queuedRunId": "run:nobody", "targetRunId": "run:nobody"},
    "runtime-request.respond": {"requestId": "request:nobody", "answers": {"question:nobody": "x"}},
}
failures = 0


def report(ok: bool, name: str, detail: str = "") -> None:
    global failures
    failures += not ok
    print(f"{'ok  ' if ok else 'FAIL'} {name}" + (f"  {detail}" if detail else ""))


def understood(tag: str, name: str, payload: dict) -> None:
    """T3 saying no is fine here. T3 not understanding is not."""
    try:
        remote._rpc(tag, payload)
        report(True, name, "accepted")
    except t3errors.SendRefused as error:
        report(str(error) != t3errors.T3_DIDNT_UNDERSTAND, name, str(error)[:70])
    except t3errors.SendUncertain as error:
        report(False, name, str(error)[:70])


url, token_file = sys.argv[1], sys.argv[2]
remote = t3remote.T3Remote(url, Path(token_file).read_text().strip())

shell = remote.shell()
report(t3errors.check_shell(shell) is shell, "the shell has a thread list")
for key in SHELL_KEYS:
    report(key in shell, f"shell has {key}")
print(f"     shell schemaVersion {shell.get('schemaVersion')}, {len(shell['threads'])} threads")
if shell["threads"]:
    newest = shell["threads"][0]
    for key in THREAD_KEYS:
        report(key in newest, f"a thread has {key}")
    bounded = remote._request(f"/api/orchestration/threads/{newest['id']}/bounded")
    report("projection" in bounded and "hasMoreHistory" in bounded, "bounded has projection and hasMoreHistory", ", ".join(sorted(bounded)))
    for key in PROJECTION_KEYS:
        report(key in bounded.get("projection", {}), f"a projection has {key}")
    cursor = bounded.get("historyCursor")
    if cursor:
        history = remote._request(f"/api/orchestration/threads/{newest['id']}/history?cursor={urllib.parse.quote(str(cursor))}")
        report("items" in history and "hasMoreHistory" in history, "history has items and hasMoreHistory", ", ".join(sorted(history)))
    else:
        print("     no older history on the newest thread, so that route wasn't checked")
else:
    report(False, "no threads on this server to check a projection with")

config = remote.server_config()
report(isinstance(config.get("providers"), list), "server.getConfig lists providers")
report(isinstance(catalog.model_catalog(config), list), "the model list still parses")

for kind, extra in COMMANDS.items():
    understood("orchestration.dispatchCommand", kind, {"type": kind, "commandId": str(uuid.uuid4()), "threadId": NOBODY, **extra})
# Yolo mode's Approve and Decline: the same command as an answer, with a decision in place of answers.
for decision in ("accept", "decline"):
    understood("orchestration.dispatchCommand", f"runtime-request.respond {decision}", {
        "type": "runtime-request.respond", "commandId": str(uuid.uuid4()), "threadId": NOBODY, "requestId": "request:nobody", "decision": decision})
understood("orchestration.dispatchCommand", "message.dispatch", {
    "type": "message.dispatch", "commandId": str(uuid.uuid4()), "threadId": NOBODY, "messageId": str(uuid.uuid4()),
    "text": "x", "attachments": [], "dispatchMode": {"type": "queue_after_active"}, "createdBy": "user", "creationSource": "web"})
for mode in settings.RUNTIME_MODES:
    understood("orchestration.launchThread", f"launchThread {mode}", {
        "commandId": str(uuid.uuid4()), "creationSource": "web", "threadId": str(uuid.uuid4()), "projectId": NOBODY, "title": "x",
        "modelSelection": {"instanceId": "claudeAgent", "model": "claude-haiku-5-5", "options": []},
        "runtimeMode": mode, "interactionMode": "default", "workspaceStrategy": {"type": "root"},
        "initialMessage": {"messageId": str(uuid.uuid4()), "text": "x", "attachments": []}})
understood("orchestration.getFullThreadDiff", "getFullThreadDiff", {"threadId": NOBODY, "toTurnCount": 1})
understood("assets.createUrl", "assets.createUrl", {"resource": {"_tag": "media-file", "threadId": NOBODY, "path": "/nobody.png"}})
understood("pullRequests.checks", "pullRequests.checks", {"projectId": NOBODY, "host": "github.com", "repository": "nobody/nobody", "number": 1})
understood("pullRequests.detail", "pullRequests.detail", {"projectId": NOBODY, "host": "github.com", "repository": "nobody/nobody", "number": 1})
understood("pullRequests.activity", "pullRequests.activity", {"projectId": NOBODY, "host": "github.com", "repository": "nobody/nobody", "number": 1})

# And the check itself has to be able to fail, or it proves nothing.
try:
    remote._rpc("no.such.call", {})
    report(False, "a made-up call gets refused")
except t3errors.SendRefused as error:
    report(str(error) == t3errors.T3_DIDNT_UNDERSTAND, "a made-up call reads as not understood", str(error)[:50])

print(json.dumps({"failures": failures}))
sys.exit(1 if failures else 0)
