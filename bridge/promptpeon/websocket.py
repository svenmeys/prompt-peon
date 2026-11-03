"""A minimal WebSocket client, just enough RFC 6455 for one request and its answer."""
from __future__ import annotations

import base64
import hashlib
import secrets
import socket
import ssl
import struct
import time
import urllib.parse

from . import settings


class WebSocketClosed(Exception):
    pass


class WebSocket:
    """Just enough RFC 6455 for one request and its answer."""

    def __init__(self, url: str, timeout: float = 15.0):
        self.deadline = time.monotonic() + settings.T3_READ_SECONDS
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in ("ws", "wss"):
            raise ValueError("not a WebSocket address")
        secure = parsed.scheme == "wss"
        self.sock = socket.create_connection((parsed.hostname, parsed.port or (443 if secure else 80)), timeout=timeout)
        if secure:
            self.sock = ssl.create_default_context().wrap_socket(self.sock, server_hostname=parsed.hostname)
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        target = parsed.path + (f"?{parsed.query}" if parsed.query else "")
        request = (
            f"GET {target} HTTP/1.1\r\nHost: {parsed.netloc}\r\nUser-Agent: {settings.USER_AGENT}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(request.encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise WebSocketClosed("closed during handshake")
            head += chunk
            if len(head) > 65536 or time.monotonic() > self.deadline:
                raise WebSocketClosed("the handshake never ended")
        status = head.split(b"\r\n", 1)[0].decode(errors="replace")
        if " 101 " not in status + " ":
            raise WebSocketClosed(f"handshake refused: {status}")
        wanted = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        if wanted.lower() not in head.lower():
            raise WebSocketClosed("the handshake answer was wrong")
        self.buffer = head.split(b"\r\n\r\n", 1)[1]

    def _read(self, count: int) -> bytes:
        if count > settings.MAX_T3_BYTES:
            raise WebSocketClosed("a message too big to be real")
        while len(self.buffer) < count:
            if time.monotonic() > self.deadline:
                raise WebSocketClosed("the answer took too long")
            chunk = self.sock.recv(65536)
            if not chunk:
                raise WebSocketClosed("connection closed")
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        mask = secrets.token_bytes(4)
        length = len(payload)
        if length < 126:
            header = struct.pack("!BB", 0x80 | opcode, 0x80 | length)
        elif length < 65536:
            header = struct.pack("!BBH", 0x80 | opcode, 0x80 | 126, length)
        else:
            header = struct.pack("!BBQ", 0x80 | opcode, 0x80 | 127, length)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def send_text(self, text: str) -> None:
        self._send_frame(0x1, text.encode("utf-8"))

    def recv_text(self) -> str:
        parts: list[bytes] = []
        total = 0
        while True:
            first, second = self._read(2)
            opcode, length = first & 0x0F, second & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._read(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._read(8))[0]
            payload = self._read(length)
            if opcode == 0x8:
                raise WebSocketClosed("server closed the socket")
            if opcode == 0x9:
                self._send_frame(0xA, payload)
            elif opcode in (0x0, 0x1):
                parts.append(payload)
                total += len(payload)
                if total > settings.MAX_T3_BYTES:
                    raise WebSocketClosed("a message too big to be real")
                if first & 0x80:
                    return b"".join(parts).decode("utf-8", "replace")

    def close(self) -> None:
        try:
            self._send_frame(0x8, b"")
        except OSError:
            pass
        self.sock.close()
