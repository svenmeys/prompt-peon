"""The connection to T3: its HTTP routes, and its commands over a WebSocket. Only ever the one address you gave."""
from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zlib

from . import pngtga, settings, t3errors, timeline, websocket


def read_bounded(response) -> bytes:
    """All of an answer, but not without limit, in size or in time."""
    read = getattr(response, "read1", None) or response.read
    deadline = time.monotonic() + settings.T3_READ_SECONDS
    parts, total = [], 0
    while True:
        chunk = read(65536)
        if not chunk:
            return b"".join(parts)
        total += len(chunk)
        if total > settings.MAX_T3_BYTES:
            raise t3errors.T3Changed("an answer too big to be real")
        if time.monotonic() > deadline:
            raise t3errors.T3Changed("an answer that took too long")
        parts.append(chunk)


def gunzip_bounded(raw: bytes) -> bytes:
    """Unpacking can be most of the size: 2 KB can become 2 MB. So stop at the limit, not after it."""
    try:
        unpacker = zlib.decompressobj(wbits=31)
        data = unpacker.decompress(raw, settings.MAX_T3_BYTES + 1)
    except zlib.error as error:
        raise t3errors.T3Changed("a broken compressed answer") from error
    if len(data) > settings.MAX_T3_BYTES:
        raise t3errors.T3Changed("an answer too big to be real")
    return data


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    """A redirect would hand our token to whatever address it names. T3 has no need for one."""

    def redirect_request(self, *_args, **_kwargs):
        return None


# No proxies either: Python would otherwise pick them up from the environment or the Windows settings,
# and hand them the token.
NO_REDIRECTS = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirects)
NO_REDIRECTS.addheaders = [("User-Agent", settings.USER_AGENT)]


class T3Remote:
    def __init__(self, url: str, token: str):
        self.url = url.rstrip("/")
        self.token = token

    def _request(self, path: str, *, method: str = "GET", body: bytes | None = None, protocol: bool = True):
        headers = {"Authorization": f"Bearer {self.token}", "Accept-Encoding": "gzip"}
        if protocol:
            headers["x-t3-orchestration-protocol"] = "2"
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.url + path, data=body, headers=headers, method=method)
        with NO_REDIRECTS.open(request, timeout=20) as response:
            raw = read_bounded(response)
            if response.headers.get("Content-Encoding") == "gzip":
                raw = gunzip_bounded(raw)
        try:
            return json.loads(raw)
        except RecursionError:
            raise t3errors.T3Changed("an answer nested too deep") from None

    def shell(self) -> dict:
        # The flags want "1", not "true". With them this is 44 threads instead of 1285.
        return self._request("/api/orchestration/shell?omitIdleSubagents=1&omitOlderSettled=1")

    def detail(self, thread_id: str) -> dict:
        """Everything T3 shows inside a thread: messages, thinking, steps, what it is doing now.

        The bounded route first, because the full transcript refuses long threads
        (thread_transcript_too_large). Some threads only answer on the transcript route.
        """
        base = f"/api/orchestration/threads/{urllib.parse.quote(thread_id)}"
        more = False
        try:
            response = self._request(f"{base}/bounded")
            projection, more = response["projection"], bool(response.get("hasMoreHistory"))
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                raise
            rows = self._request(f"{base}/transcript").get("items", [])
            projection = {"turnItems": [row.get("item") or {} for row in rows]}
        detail = timeline.describe_thread(projection)
        detail["more"] = more or timeline.rows_left_out(projection.get("turnItems") or [], detail["rows"])
        return detail

    def older_rows(self, thread_id: str, before: int) -> tuple[list, bool]:
        """The next rows older than `before`, and whether there are more. Starts from the newest
        each time, so nothing is remembered here and a bridge restart can't leave a gap."""
        base = f"/api/orchestration/threads/{urllib.parse.quote(thread_id)}"
        first = self._request(f"{base}/bounded")
        items = first["projection"].get("turnItems") or []
        cursor = first.get("historyCursor") if first.get("hasMoreHistory") else None
        seen: set[str] = set()
        while True:
            older = [item for item in items if (item.get("ordinal") or 0) < before]
            rows = timeline.build_timeline(older)
            if rows or not cursor:
                return timeline.fit_older_rows(rows, older, bool(cursor))
            if cursor in seen or len(seen) >= settings.MAX_HISTORY_PAGES:
                raise t3errors.T3Changed("history that never ends")
            seen.add(cursor)
            page = self._request(f"{base}/history?cursor={urllib.parse.quote(cursor)}")
            items = [row.get("item") or {} for row in page.get("items") or []]
            cursor = page.get("nextCursor") if page.get("hasMoreHistory") else None

    def has_message(self, thread_id: str, message_id: str) -> bool:
        """Did T3 already take this message? Used after a crash, instead of guessing."""
        base = f"/api/orchestration/threads/{urllib.parse.quote(thread_id)}"
        projection = self._request(f"{base}/bounded")["projection"]
        if any(message.get("id") == message_id for message in projection.get("messages") or []):
            return True
        return any(item.get("messageId") == message_id for item in projection.get("turnItems") or [])

    def _rpc(self, tag: str, payload: dict):
        """One request over T3's WebSocket, and its answer."""
        try:
            ticket = self._request("/api/auth/websocket-ticket", method="POST", body=b"{}", protocol=False)["ticket"]
            base = urllib.parse.urlsplit(self.url)
            query = urllib.parse.urlencode({
                "wsTicket": ticket,
                "orchestrationProtocol": "2",
                "clientSurface": "desktop",
                "clientAppVersion": f"prompt-peon/{settings.VERSION}",
            })
            scheme = "wss" if base.scheme == "https" else "ws"  # Never downgrade an encrypted address.
            socket_ = websocket.WebSocket(f"{scheme}://{base.netloc}/ws?{query}")
        except (OSError, urllib.error.URLError, KeyError, ValueError, TypeError, t3errors.T3Changed, websocket.WebSocketClosed) as error:
            raise t3errors.SendRefused(f"could not connect to T3: {error}") from error
        try:
            socket_.send_text(json.dumps({"_tag": "Request", "id": "1", "tag": tag, "payload": payload, "headers": []}))
            while True:
                answer = json.loads(socket_.recv_text())
                # It may already have acted on this, so "we don't know" is the honest answer.
                if not isinstance(answer, dict):
                    raise t3errors.SendUncertain("T3 answered in a shape we don't know")
                if answer.get("_tag") == "Exit" and str(answer.get("requestId")) == "1":
                    outcome = answer.get("exit")
                    if not isinstance(outcome, dict) or outcome.get("_tag") not in ("Success", "Failure"):
                        raise t3errors.SendUncertain("T3 answered in a shape we don't know")
                    if outcome.get("_tag") == "Success":
                        return outcome.get("value")
                    raise t3errors.SendRefused(t3errors.describe_failure(outcome))
                if answer.get("_tag") == "Defect":
                    raise t3errors.SendUncertain("T3 reported an internal error")
        except (OSError, websocket.WebSocketClosed, ValueError, RecursionError) as error:
            raise t3errors.SendUncertain(f"lost the connection mid-send: {error}") from error
        finally:
            socket_.close()

    def send_reply(self, thread: dict, text: str, message_id: str | None = None) -> str:
        """Start or queue a turn on an existing thread."""
        message_id = message_id or str(uuid.uuid4())
        self._rpc("orchestration.dispatchCommand", {
            "type": "message.dispatch",
            # Derived from the message, so sending the same one again is the same command.
            "commandId": str(uuid.uuid5(uuid.NAMESPACE_URL, f"prompt-peon:{message_id}")),
            "threadId": thread["id"],
            "messageId": message_id,
            "text": text,
            "attachments": [],
            # Same as `t3 thread send`: a busy agent gets this as its next turn, never mid-turn.
            # The thread keeps its own model and permission mode.
            "dispatchMode": {"type": "queue_after_active"},
            "createdBy": "user",
            "creationSource": "web",
        })
        return message_id

    def open_question(self, thread_id: str) -> dict | None:
        """The question this thread is waiting on right now, read fresh from T3, or None."""
        base = f"/api/orchestration/threads/{urllib.parse.quote(thread_id)}"
        items = self._request(f"{base}/bounded")["projection"].get("turnItems") or []
        for item in sorted(items, key=lambda entry: entry.get("ordinal") or 0, reverse=True):
            if item.get("type") == "user_input_request" and timeline.state_of(item) == "r":
                return item
        return None

    def answer_question(self, thread_id: str, request_id: str, answers: dict) -> None:
        """The same command T3's own window sends: each question's id, and the answer picked or typed."""
        self._rpc("orchestration.dispatchCommand", {"type": "runtime-request.respond", "commandId": str(uuid.uuid4()),
                                                    "threadId": thread_id, "requestId": request_id, "answers": answers})

    def stop_thread(self, thread_id: str) -> None:
        self._rpc("orchestration.dispatchCommand", {"type": "thread.stop", "commandId": str(uuid.uuid4()), "threadId": thread_id})

    def settle_thread(self, thread_id: str) -> None:
        self._rpc("orchestration.dispatchCommand", {"type": "thread.settle", "commandId": str(uuid.uuid4()), "threadId": thread_id})

    def snooze_thread(self, thread_id: str, until: str) -> None:
        self._rpc("orchestration.dispatchCommand", {"type": "thread.snooze", "commandId": str(uuid.uuid4()),
                                                    "threadId": thread_id, "snoozedUntil": until})

    def unsnooze_thread(self, thread_id: str) -> None:
        self._rpc("orchestration.dispatchCommand", {"type": "thread.unsnooze", "commandId": str(uuid.uuid4()),
                                                    "threadId": thread_id, "reason": "user"})

    def unsettle_thread(self, thread_id: str) -> None:
        self._rpc("orchestration.dispatchCommand", {"type": "thread.unsettle", "commandId": str(uuid.uuid4()), "threadId": thread_id, "reason": "user"})

    def cancel_queued(self, thread_id: str, run_id: str) -> None:
        self._rpc("orchestration.dispatchCommand", {"type": "queued-run.cancel", "commandId": str(uuid.uuid4()), "threadId": thread_id, "runId": run_id})

    def edit_queued(self, thread_id: str, run_id: str, text: str) -> None:
        self._rpc("orchestration.dispatchCommand", {"type": "queued-run.edit", "commandId": str(uuid.uuid4()), "threadId": thread_id,
                                                    "runId": run_id, "text": text})

    def start_thread(self, project_id: str, model_selection: dict, text: str, runtime_mode: str) -> str:
        """A new thread in the mode you picked. commands.command_result checks that mode first."""
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        title = (lines[0] if lines else "New thread")[:80]
        answer = self._rpc("orchestration.launchThread", {
            "commandId": str(uuid.uuid4()),
            "creationSource": "web",
            # T3's own id for an unnamed launch has characters a reply from the game refuses.
            "threadId": str(uuid.uuid4()),
            "projectId": project_id,
            "title": title,
            "modelSelection": model_selection,
            "runtimeMode": runtime_mode,
            "interactionMode": "default",
            "workspaceStrategy": {"type": "root"},
            "initialMessage": {"messageId": str(uuid.uuid4()), "text": text, "attachments": []},
        })
        return answer["threadId"]

    def thread_diff(self, thread_id: str) -> str:
        """The whole thread's changes as a unified diff, as T3's diff panel gets them."""
        base = f"/api/orchestration/threads/{urllib.parse.quote(thread_id)}"
        projection = self._request(f"{base}/bounded")["projection"]
        answer = self._rpc("orchestration.getFullThreadDiff", {"threadId": thread_id, "toTurnCount": timeline.latest_diff_turn(projection)})
        return answer.get("diff") or ""

    def steer_queued(self, thread_id: str, run_id: str, active_run: str) -> None:
        self._rpc("orchestration.dispatchCommand", {"type": "queued-message.promote-to-steer", "commandId": str(uuid.uuid4()),
                                                    "threadId": thread_id, "queuedRunId": run_id, "targetRunId": active_run})

    def server_config(self) -> dict:
        return self._rpc("server.getConfig", {}) or {}

    def set_model(self, thread_id: str, selection: dict) -> None:
        self._rpc("orchestration.dispatchCommand", {"type": "thread.model-selection.set", "commandId": str(uuid.uuid4()),
                                                    "threadId": thread_id, "modelSelection": selection})

    def pr_diff(self, project_id: str, link: dict) -> tuple[str, bool]:
        """One pull request's changes as a unified diff, and whether some got left out. T3 sends big ones in slices."""
        parts: list[str] = []
        size, cut, cursor = 0, False, None
        while True:
            payload = {"projectId": project_id, "host": link.get("host"), "repository": link.get("repository"), "number": link.get("number")}
            if cursor:
                payload["cursor"] = cursor
            answer = self._request("/api/pull-requests/diff", method="POST", body=json.dumps(payload).encode())
            patch = answer.get("patch") or ""
            parts.append(patch)
            size += len(patch)
            cut = cut or bool(answer.get("truncated"))
            cursor = answer.get("nextCursor")
            if not cursor:
                return "".join(parts), cut
            if size >= settings.T3_DIFF_LIMIT:
                return "".join(parts), True

    def pr_checks(self, project_id: str, link: dict) -> dict | None:
        return self._rpc("pullRequests.checks", {"projectId": project_id, "host": link.get("host"),
                                                 "repository": link.get("repository"), "number": link.get("number")})

    def pr_detail(self, project_id: str, link: dict) -> dict | None:
        return self._rpc("pullRequests.detail", {"projectId": project_id, "host": link.get("host"),
                                                 "repository": link.get("repository"), "number": link.get("number")})

    def pr_activity(self, project_id: str, link: dict) -> dict | None:
        return self._rpc("pullRequests.activity", {"projectId": project_id, "host": link.get("host"),
                                                   "repository": link.get("repository"), "number": link.get("number")})

    def image_bytes(self, thread_id: str, reference: dict) -> bytes:
        """An image from a thread. A signed link, using only the read permission."""
        if "a" in reference:
            resource = {"_tag": "attachment", "attachmentId": reference["a"], "disposition": "inline"}
        else:
            resource = {"_tag": "media-file", "threadId": thread_id, "path": reference["p"]}
        link = self._rpc("assets.createUrl", {"resource": resource})["relativeUrl"]
        request = urllib.request.Request(self.url + link, headers={"Authorization": f"Bearer {self.token}"})
        with NO_REDIRECTS.open(request, timeout=30) as response:
            data = response.read(settings.MAX_IMAGE_DOWNLOAD + 1)
        if len(data) > settings.MAX_IMAGE_DOWNLOAD:
            raise pngtga.ImageError("too big to preview")
        return data
