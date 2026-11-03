"""Getting a working link to T3, with as few questions as we can."""
from __future__ import annotations

import json
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from . import prompts, safefiles, screen, settings, t3remote, threadstate, userconfig


def open_threads(count: int) -> str:
    return "1 open thread" if count == 1 else f"{count} open threads"


def parse_pair_link(text: str) -> tuple[str, str] | None:
    """The T3 address and one-time code in a pairing link, including T3's t3code:// form."""
    found = re.search(r"""(https?://[^\s#?]+?)/pair/?#(?:[^\s#]*&)?token=([^\s&"']+)""", urllib.parse.unquote(text))
    return (found.group(1), found.group(2)) if found else None


def exchange_pair_code(url: str, code: str, scopes: list[str]) -> str:
    """Trade a one-time code for a token holding only what we asked for. T3 makes it last 30 days."""
    form = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token": code,
        "subject_token_type": "urn:t3:params:oauth:token-type:environment-bootstrap",
        "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "scope": " ".join(scopes),
        "client_label": f"Prompt Peon on {socket.gethostname()} {time.strftime('%Y-%m-%d')}"[:80],
        "client_device_type": "desktop",
    }).encode()
    request = urllib.request.Request(f"{url}/oauth/token", form, {"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with t3remote.NO_REDIRECTS.open(request, timeout=15) as response:
            answer = json.loads(t3remote.read_bounded(response))
        token = answer["access_token"]
    except urllib.error.HTTPError as error:
        sys.exit(f"T3 said no to that link ({error.code}). It may be used up or expired, since they only work once. "
                 "Make a new one and run this again.")
    except (OSError, ValueError, KeyError) as error:
        sys.exit(f"Can't reach T3 at {url}: {error}\n"
                 "If T3 runs on another machine, it has to be reachable from here. On that machine, the easiest way with\n"
                 "Tailscale is: t3 pair --tailscale  Without it: t3 up --lan, which restarts T3 and stops running agents.\n"
                 "Then make a new link and run this again.")
    # T3 quietly gives a limited link only what it allows, so check what we really got.
    granted = str(answer.get("scope") or "").split()
    if not all(scope in granted for scope in settings.BASE_SCOPES):
        sys.exit("That link doesn't allow reading and sending messages. Make a new one with those two left on.")
    if any(scope not in scopes for scope in granted):
        sys.exit("T3 gave this link more access than we asked for, so it wasn't used. Make a new one with only the access Prompt Peon needs.")
    if settings.PICTURE_SCOPE in scopes and settings.PICTURE_SCOPE not in granted:
        screen.say("That link doesn't allow reading files, so pictures from files stay off. Everything else works.")
    return token


def t3_program() -> str | None:
    """The t3 command, when T3 is on this machine."""
    home = Path.home() / ".t3/bin"
    candidates = [home / "t3", home / "t3.exe", home / "t3.cmd"]
    found = shutil.which("t3") or next((str(path) for path in candidates if path.exists()), None)
    return found


HOW_TO_GET_A_LINK = ("On the machine your threads are on, in a copy of this folder, run this, or ask an agent in a thread there to:\n"
                     "  python3 bridge/promptpeon_bridge.py link\n"
                     "That works with T3 Connect. With Tailscale, run t3 pair --tailscale --ttl 15m there instead.")


def connect_address() -> str | None:
    """T3 Connect's public address, read the way T3 reads it: from its tunnel's local status page.
    pa-lean: it finds that page with lsof, so not on a Windows T3 machine. Tailscale still works there."""
    try:
        listening = subprocess.run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-c", "cloudflared"], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for port in re.findall(r"127\.0\.0\.1:(\d+)", listening):
        try:
            with t3remote.NO_REDIRECTS.open(f"http://127.0.0.1:{port}/config", timeout=3) as response:
                config = json.loads(t3remote.read_bounded(response))
        except (OSError, ValueError):
            continue
        for rule in (config.get("config") or {}).get("ingress") or []:
            if rule.get("hostname"):
                return "https://" + rule["hostname"]
    return None


def make_link() -> int:
    """Run this on the T3 machine: a one-time link for a game somewhere else, over T3 Connect.
    It allows pictures, because the installer asks about those and only requests what you said yes to."""
    program = t3_program()
    if not program:
        screen.say("T3 isn't on this machine. Run this on the machine your threads are on.")
        return 1
    address = connect_address()
    if not address:
        screen.say("Couldn't find T3 Connect running here. Run this on the machine your threads are on, not the one you play on.")
        screen.say("If this is that machine, turn T3 Connect on in T3's settings. It can't be found on a Windows machine yet,")
        screen.say("so there, use Tailscale: t3 pair --tailscale --ttl 15m")
        return 1
    command = [program, "auth", "pairing", "create", "--base-url", address, "--ttl", "15m", "--label", "Prompt Peon", "--json"]
    for scope in settings.BASE_SCOPES + [settings.PICTURE_SCOPE]:
        command += ["--scope", scope]
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=60)
        link = json.loads(done.stdout)["pairUrl"]
    except (OSError, subprocess.SubprocessError, ValueError, KeyError):
        screen.say("T3 didn't make a link. Is it running?")
        return 1
    screen.say(f"Copy this link:\n\n  {link}\n")
    screen.say("On the game machine, double-click install.cmd and paste it when it asks. (On Linux or SteamOS: sh install.sh)")
    screen.say("It works once, for 15 minutes. Whoever has it can read your threads and send to them, so keep it to yourself.")
    return 0


def issue_local_token(scopes: list[str]) -> str | None:
    """With T3 on this machine there is nothing to paste, as long as it is running."""
    program = t3_program()
    if not program or not t3_answers(settings.DEFAULT_URL):
        return None
    screen.say("This access lasts a year. You can revoke it in T3 under Settings, Sharing & access.")
    label = f"Prompt Peon {time.strftime('%Y-%m-%d')}"  # So the list in T3 can tell one from another.
    command = [program, "auth", "session", "issue", "--ttl", "365d", "--label", label, "--token-only"]
    for scope in scopes:
        command += ["--scope", scope]
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    return done.stdout.strip() if done.returncode == 0 and done.stdout.strip() else None


def t3_answers(url: str) -> bool:
    try:
        t3remote.NO_REDIRECTS.open(url, timeout=3).close()
    except urllib.error.HTTPError:
        pass  # It answered, and that is what we wanted to know.
    except OSError:
        return False
    return True


def is_plain_over_network(url: str) -> bool:
    parsed = urllib.parse.urlsplit(url)
    return parsed.scheme != "https" and parsed.hostname not in ("127.0.0.1", "localhost", "::1")


def accept_plain_network(url: str, allowed: bool) -> None:
    """On a plain http address, anyone on that network can read your messages and take your access."""
    if allowed or not is_plain_over_network(url):
        return
    screen.say(f"\n{url} isn't encrypted. Anyone on that network could read your threads and take your T3 access.")
    screen.say("Only say yes on a network you trust completely, and never on public or shared wifi.")
    if not sys.stdin.isatty():
        sys.exit("Stopping, because nobody is here to say yes. To allow it, add --allow-unencrypted.")
    if not prompts.ask("Use it anyway? [y/N]: ").lower().startswith("y"):
        sys.exit("Nothing changed. An SSH tunnel or Tailscale address avoids this: see the README.")


def keep_or_paste() -> str | None:
    """Running this again is how you move to another T3, so that takes a paste and no flags."""
    if not sys.stdin.isatty():
        return None
    return prompts.ask("Press Enter to keep it, or paste a link to connect to another machine: ") or None


def paste_a_link() -> str:
    """A pair link or a token. A bad paste gets another go, because getting a new link is the slow part."""
    text = prompts.ask("Paste the link here: ")
    for _ in range(2):
        if not sys.stdin.isatty() or parse_pair_link(text) or (text and "://" not in text):
            break
        screen.say("That isn't a link from T3. It looks like https://.../pair#token=...")
        text = prompts.ask("Paste the link here: ")
    return text


def connect_to_t3(url: str | None, link: str | None, pictures: bool | None, allow_unencrypted: bool = False) -> str:
    """Get a working link to T3 with as few questions as we can. Returns T3's address."""
    saved_url = userconfig.read_config().get("url")
    # A saved token only ever goes back to the address that gave it to us.
    same_place = saved_url and (not url or url.rstrip("/") == saved_url.rstrip("/"))
    if same_place and not link and pictures is None and (settings.CONFIG_DIR / "token").exists():
        try:
            count = len(threadstate.active_threads(t3remote.T3Remote(saved_url, userconfig.read_token()).shell()))
            screen.ok(f"Already connected to T3 at {saved_url}. {open_threads(count)}.")
            if saved_url.rstrip("/") == settings.DEFAULT_URL.rstrip("/"):
                screen.say(f"Those are this machine's threads. For another machine's, you need a link from there.\n{HOW_TO_GET_A_LINK}")
            if is_plain_over_network(saved_url):
                screen.say("That address isn't encrypted, so only use it on a network you trust completely.")
            link = keep_or_paste()
            if not link:
                shows = "on" if userconfig.read_config().get("pictures") is True else "off"
                screen.say(f"Pictures are {shows}. To change that, run this again with --pictures or --no-pictures. It may ask for a new link.")
                return saved_url
        except urllib.error.HTTPError as error:
            if error.code not in (401, 403):
                return saved_url
            screen.say("Your link to T3 has expired, so we need a new one.")
        except (OSError, ValueError):
            screen.say(f"Can't reach T3 at {saved_url} right now.")
            link = keep_or_paste()
            if not link:
                screen.say("Keeping your settings.")
                return saved_url

    # T3 here only shows threads that live here, so someone with T3 in both places gets to choose.
    t3_here = not link and not url and t3_program() and t3_answers(settings.DEFAULT_URL)
    if t3_here and sys.stdin.isatty():
        screen.say("\nFound T3 on this machine. It shows the threads on this machine only.")
        screen.say(f"If your threads are on another machine, even one this T3 app can reach, you need a link from there.\n{HOW_TO_GET_A_LINK}")
        link = prompts.ask("Press Enter to use this machine, or paste the link: ") or None
    allow_files = None
    token = None
    if t3_here and not link:
        allow_files = prompts.wants_pictures(pictures)
        token = issue_local_token(settings.BASE_SCOPES + ([settings.PICTURE_SCOPE] if allow_files else []))
    if token:
        screen.say("Found T3 on this machine.")
        target = settings.DEFAULT_URL
    else:
        if not link:
            screen.say(f"\nNow connect to T3.\n{HOW_TO_GET_A_LINK}")
        text = link or paste_a_link()
        pair = parse_pair_link(text)
        if pair:
            target, code = pair
            screen.say(f"\nThis link connects Prompt Peon to {target}.")
            screen.say("Whoever runs that machine can read what you send and put words in your game.\n")
            if sys.stdin.isatty() and not prompts.ask("Is it your own machine, or one you trust? [y/N]: ").lower().startswith("y"):
                sys.exit("Nothing changed.")
            accept_plain_network(target, allow_unencrypted)
            allow_files = prompts.wants_pictures(pictures) if allow_files is None else allow_files
            token = exchange_pair_code(target, code, settings.BASE_SCOPES + ([settings.PICTURE_SCOPE] if allow_files else []))
        elif text and "://" not in text:
            target, token = url or settings.DEFAULT_URL, text  # A token made by hand works too.
            accept_plain_network(target, allow_unencrypted)
            screen.say("A token made by hand keeps whatever access it was made with, whatever you answer about pictures.")
            allow_files = prompts.wants_pictures(pictures) if allow_files is None else allow_files
        else:
            sys.exit("That isn't a pairing link, so nothing changed. Run this again when you have one.")
    # Tried before saving, so a bad link can't replace one that works.
    try:
        count = len(threadstate.active_threads(t3remote.T3Remote(target, token).shell()))
    except urllib.error.HTTPError as error:
        sys.exit(f"T3 answered {error.code} when we tried to connect, so nothing changed. Make a new link and run this again.")
    except (OSError, ValueError) as error:
        sys.exit(f"Can't reach T3 at {target}, so nothing changed: {error}")
    userconfig.save_token(token)
    settings.CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    safefiles.write_atomic(settings.CONFIG_DIR / "config.json", json.dumps(dict(userconfig.read_config(), url=target, pictures=allow_files), indent=2))
    screen.ok(f"Connected to T3 at {target}. {open_threads(count)}.")
    return target
