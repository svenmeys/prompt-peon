"""Making text from T3 fit for the game: what its fonts can draw, and secrets caught on the way."""
from __future__ import annotations

import re

from . import settings


GLYPHS = str.maketrans({"→": "->", "←": "<-", "✓": "ok", "✅": "ok", "❌": "x", "•": "-"})


def readable(text: str, limit: int | None = None) -> str:
    """Turn agent markdown into text WoW's fonts can draw. Pipes stay; the addon escapes them.

    Only short labels such as titles pass a limit. Messages are never cut: the addon splits
    long ones into several text blocks when it draws them.
    """
    text = hide_secrets(str(text)).translate(GLYPHS)
    text = re.sub(r"^```.*$", "", text, flags=re.M)
    text = re.sub(r"^#{1,6}\s+", "", text, flags=re.M)
    text = re.sub(r"\*\*(.+?)\*\*", r"\1", text)
    text = re.sub(r"`([^`\n]+)`", r"\1", text)
    text = re.sub(r"\[([^\]\n]+)\]\((?:[^)\n]+)\)", r"\1", text)
    # WoW's fonts have no emoji. Left in, each one draws as an empty box.
    text = "".join(ch for ch in text if ord(ch) <= 0xFFFF and (ch in "\n\t" or ord(ch) >= 0x20))
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    if limit is not None and len(text) > limit:
        text = text[:limit].rstrip() + "..."
    return text


# Files that are usually nothing but secrets. Their diffs stay out of the game altogether.
SECRET_FILE_RE = re.compile(
    r"(^|/)(\.env(?!\.(example|sample|template)$)(\.[^/]*)?|\.envrc|[^/]*\.(pem|p12|pfx|keystore|jks)"
    r"|[^/]*\.key(\.[^/]*)?|id_(rsa|dsa|ecdsa|ed25519)|credentials(\.[^/]*)?|secrets?(\.[^/]*)?"
    r"|[^/]*[-_.]secrets?\.[^/]*|tokens?\.[^/]*|auth\.json|service[-_]?account[^/]*\.json"
    r"|\.netrc|\.npmrc|\.pypirc|\.pgpass|\.git-credentials|\.docker/config\.json)$", re.I)
SECRET_TEXT_RES = [
    re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\Z)", re.S),
    re.compile(r"\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}"
               r"|glpat-[A-Za-z0-9_-]{16,}|npm_[A-Za-z0-9]{20,}"
               r"|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}"
               # Two parts or three: T3's own tokens are the two-part kind.
               r"|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]{5,})?)"),
    re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/-]{8,}=*"),
]
SECRET_URL_RE = re.compile(r"(://[^/\s:@]+:)[^/\s@]+(@)")
SECRET_ASSIGN_RE = re.compile(
    r"(?i)\b([A-Z0-9_.-]*(?:PASSWORD|PASSWD|SECRET|API_?KEY|AUTH_?TOKEN|ACCESS_?TOKEN|PRIVATE_?KEY"
    # Short words only on their own, so "passing" and "authors" aren't labels.
    r"|(?<![A-Z])(?:PASS|PWD|TOKEN|AUTH|CREDENTIALS?)(?![A-Z]))[A-Z0-9_.-]*[\"']?\s*[:=]\s*)"
    # Code stays readable: "password = config.password", "token = get_token()", "secret = None".
    r"(?:\"[^\"\n]{4,}\"|'[^'\n]{4,}'|(?!(?:true|false|null|none|nil|undefined)\b)(?![A-Za-z_]+\.[A-Za-z_])"
    r"[A-Za-z0-9_+/=.~-]{6,}(?![A-Za-z0-9_+/=.~-]*\())")


def hide_secrets(text: str) -> str:
    """A safety net, not a promise: it catches the common shapes of a secret, and says it did."""
    for pattern in SECRET_TEXT_RES:
        text = pattern.sub("[hidden secret]", text)
    text = SECRET_URL_RE.sub(lambda found: found.group(1) + "[hidden secret]" + found.group(2), text)
    return SECRET_ASSIGN_RE.sub(lambda found: found.group(1) + "[hidden secret]", text)


def message_text(text: str) -> str:
    """A whole message for the game: Markdown kept, because the addon draws it. Never cut."""
    text = hide_secrets(str(text)).translate(GLYPHS)
    # WoW's fonts have no emoji. Left in, each one draws as an empty box.
    text = "".join(ch for ch in text if ord(ch) <= 0xFFFF and (ch in "\n\t" or ord(ch) >= 0x20))
    text = text.replace("\t", "    ").strip("\n").rstrip()
    if len(text) > settings.MAX_MESSAGE_CHARS:
        text = text[:settings.MAX_MESSAGE_CHARS] + "\n\n(The rest of this message is in T3.)"
    return text
