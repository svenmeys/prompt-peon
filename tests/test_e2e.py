"""The whole bridge as a real process, against a fake T3 server and a fake game folder.

Run from the repo root with: python3.14 tests/test_e2e.py
On Windows this is the proof that install, hard links, autostart and the frame reader work
together. It needs no game. Only the real game can prove the addon's side.
"""
import base64
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests/bridge"))
if sys.version_info < (3, 14):
    sys.exit("These tests need Python 3.14 or newer, the same as the installer. Try: python3.14 tests/test_e2e.py")
from bridge_helpers import addons_txt, python_frames  # noqa: E402
from promptpeon import settings  # noqa: E402

THREAD = "1f7743e2-3c60-4348-88a5-7b9f3d6c00b0"
TOKEN = "fake-token-for-the-e2e-test"
LONG = "\n".join(f"Line {n} of a long agent answer." for n in range(1, 400))


class FakeT3(BaseHTTPRequestHandler):
    received: list = []

    def log_message(self, *_):
        pass

    def _json(self, value, status=200):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        if self.headers.get("Authorization") == f"Bearer {TOKEN}":
            return True
        self._json({"error": "no"}, 401)
        return False

    def do_POST(self):
        if self._authorized():
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self._json({"ticket": "ticket"})

    def do_GET(self):
        if self.path.startswith("/ws"):
            self._websocket()
        elif not self._authorized():
            return
        elif self.path.startswith("/api/orchestration/shell"):
            self._json({"projects": [{"id": "p", "title": "Demo"}], "threads": [{
                "id": THREAD, "projectId": "p", "title": "A thread", "status": "running",
                "updatedAt": "2026-11-02T16:00:00.000Z", "lineage": {"parentThreadId": None},
            }]})
        elif self.path.endswith("/bounded"):
            self._json({"projection": {"messages": [{"role": "assistant", "text": LONG, "createdAt": "1"}]}})
        else:
            self._json({}, 404)

    def _websocket(self):
        key = self.headers["Sec-WebSocket-Key"]
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.wfile.write(
            f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n".encode()
        )
        self.wfile.flush()
        read = self.rfile.read
        first, second = read(2)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", read(2))[0]
        mask = read(4)
        data = bytes(byte ^ mask[index % 4] for index, byte in enumerate(read(length)))
        request = json.loads(data)
        # The bridge also asks for things, like the model list. Only commands count here.
        if request.get("tag") == "orchestration.dispatchCommand":
            FakeT3.received.append(request)
        answer = json.dumps({"_tag": "Exit", "requestId": "1", "exit": {"_tag": "Success"}}).encode()
        self.wfile.write(bytes([0x81, len(answer)]) + answer)
        self.wfile.flush()
        self.close_connection = True


class EndToEnd(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        self.dir = Path(self.tmp.name)
        FakeT3.received = []
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), FakeT3)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.wow = self.dir / "World of Warcraft/_classic_era_"
        self.wow.mkdir(parents=True)
        (self.wow / "WowClassic.exe").write_text("")
        self.env = dict(os.environ, APPDATA=str(self.dir / "cfg"), LOCALAPPDATA=str(self.dir / "state"),
                        XDG_CONFIG_HOME=str(self.dir / "cfg"), XDG_STATE_HOME=str(self.dir / "state"),
                        XDG_DATA_HOME=str(self.dir / "data"),
                        HOME=str(self.dir / "home"), USERPROFILE=str(self.dir / "home"))
        (self.dir / "home").mkdir()
        self.process = None

    def tearDown(self):
        if self.process:
            self.process.kill()
            self.process.wait()
        if os.name == "nt":
            import winreg
            try:
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, settings.RUN_KEY, 0, winreg.KEY_SET_VALUE) as handle:
                    winreg.DeleteValue(handle, settings.RUN_VALUE)
            except OSError:
                pass
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def cli(self, *args, stdin=""):
        return subprocess.run([sys.executable, str(ROOT / "bridge/promptpeon_bridge.py"), *args], env=self.env, input=stdin,
                              capture_output=True, text=True, timeout=60)

    def wait_for(self, check, seconds=15):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            value = check()
            if value:
                return value
            time.sleep(0.05)
        self.fail(f"timed out waiting for {check.__name__}")

    def test_the_double_click_installer_reaches_the_real_install(self):
        script = ["cmd", "/c", str(ROOT / "install.cmd")] if os.name == "nt" else ["sh", str(ROOT / "install.sh")]
        done = subprocess.run([*script, "--wow-dir", str(self.wow), "--url", self.url, "--no-start"], env=self.env,
                              input=TOKEN + "\n\n", capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("helper entries", done.stdout)
        self.assertIn("Done.", done.stdout)
        self.assertTrue((self.dir / "data/prompt-peon/bridge/promptpeon_bridge.py").exists() or os.name == "nt")
        self.assertTrue((self.wow / "Interface/AddOns/PromptPeon/PromptPeon.toc").exists())

    def test_the_installed_copy_works_once_the_download_is_gone(self):
        def wrapper(folder, name):
            return ["cmd", "/c", str(folder / f"{name}.cmd")] if os.name == "nt" else ["sh", str(folder / f"{name}.sh")]

        def run(command, *args, **options):
            return subprocess.run([*command, *args], env=self.env, capture_output=True, text=True, timeout=120, **options)

        done = run(wrapper(ROOT, "install"), "--wow-dir", str(self.wow), "--url", self.url, "--no-start", input=TOKEN + "\n\n")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        home = self.dir / ("state" if os.name == "nt" else "data") / "prompt-peon"
        again = run(wrapper(home, "install"), "--wow-dir", str(self.wow), "--no-start", input="\n\n")
        self.assertIn("Done.", again.stdout, again.stdout + again.stderr)
        # From inside that folder, like a double-click. Windows won't delete a folder something is standing in.
        gone = run(wrapper(home, "uninstall"), "--yes", cwd=home, input="")
        self.assertFalse(home.exists(), gone.stdout + gone.stderr)
        self.assertFalse((self.wow / "Interface/AddOns/PromptPeon").exists(), gone.stdout + gone.stderr)

    def test_the_app_follows_the_game_you_open(self):
        era, retail = self.wow, self.wow.parent / "_retail_"
        retail.mkdir()
        (retail / "Wow.exe").write_text("")
        for client in (era, retail):
            done = self.cli("install", "--wow-dir", str(client), "--url", self.url, "--no-start", stdin=TOKEN + "\n")
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        config = self.dir / "cfg/prompt-peon/config.json"
        # So this test never asks GitHub, and everything else in it is local.
        config.write_text(json.dumps(dict(json.loads(config.read_text()), update_check=False)))

        def open_game(client, program):
            if os.name == "nt":  # A real program under that name, because Windows looks at running programs.
                shutil.copy(Path(os.environ["SystemRoot"]) / "System32/PING.EXE", client / program)
                game = subprocess.Popen([str(client / program), "-n", "120", "127.0.0.1"], stdout=subprocess.DEVNULL)
            else:
                game = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)", str(client / program)])
            self.addCleanup(game.wait)
            self.addCleanup(game.kill)
            return game

        def has_threads(client):
            path = client / "Interface/AddOns/PromptPeon/Snapshot.lua"
            return path.exists() and "A thread" in path.read_text(errors="replace")

        self.process = subprocess.Popen([sys.executable, str(ROOT / "bridge/promptpeon_bridge.py"), "run"],
                                        env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        game = open_game(retail, "Wow.exe")
        self.wait_for(lambda: has_threads(retail))
        self.assertFalse(has_threads(era), "only the open game gets thread text")
        game.kill()
        game.wait()
        self.wait_for(lambda: not has_threads(retail))
        open_game(era, "WowClassic.exe")
        self.wait_for(lambda: has_threads(era))
        self.assertFalse(has_threads(retail), "and the one you left stays clear")

    @unittest.skipUnless(os.name == "nt", "On Linux the switch would touch this machine's real service")
    def test_the_switch_turns_the_real_app_off_and_on(self):
        import msvcrt
        import winreg

        home = self.dir / "state/prompt-peon"
        switch = ["cmd", "/c", str(home / "start-stop.cmd")]

        def flip():
            return subprocess.run(switch, env=self.env, input="", capture_output=True, text=True, timeout=120)

        def starts_at_login():
            try:
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, settings.RUN_KEY) as handle:
                    return bool(winreg.QueryValueEx(handle, settings.RUN_VALUE)[0])
            except OSError:
                return False

        def running():
            handle = (home / "bridge.lock").open("a+")
            try:
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
                return False
            except OSError:
                return True
            finally:
                handle.close()

        done = subprocess.run(["cmd", "/c", str(ROOT / "install.cmd"), "--wow-dir", str(self.wow), "--url", self.url], env=self.env,
                              input=TOKEN + "\n\n", capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.wait_for(running)
        self.assertTrue(starts_at_login())
        off = flip()
        self.assertIn("is off", off.stdout, off.stdout + off.stderr)
        self.assertFalse(running())
        self.assertFalse(starts_at_login())
        on = flip()
        self.assertIn("is on", on.stdout, on.stdout + on.stderr)
        self.wait_for(running)
        self.assertTrue(starts_at_login())
        self.assertIn("is off", flip().stdout, "and off again, so nothing keeps running after this test")

    def test_install_refresh_and_reply(self):
        # Install, asking for the token on stdin as a first-time user would be asked.
        start = [] if os.name == "nt" else ["--no-start"]  # Never touch this machine's real services.
        done = self.cli("install", "--wow-dir", str(self.wow), "--url", self.url, "--full-access", *start, stdin=TOKEN + "\n")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("helper entries", done.stdout)
        addons = self.wow / "Interface/AddOns"
        self.assertIn("## Interface: 11509", (addons / "PromptPeon/PromptPeon.toc").read_text())

        if os.name == "nt":
            # Install started the bridge in the background. Give it the game check it needs below.
            import winreg
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, settings.RUN_KEY) as handle:
                self.assertIn("promptpeon_bridge.py", winreg.QueryValueEx(handle, settings.RUN_VALUE)[0])
            self.assertFalse((addons / "PromptPeonIn300/Data.lua").is_symlink(), "Windows uses hard links")
            state = self.dir / "state/prompt-peon"

            def pid_written():
                return (state / "bridge.pid").exists()

            self.wait_for(pid_written)
            time.sleep(1)
            subprocess.run(["taskkill", "/PID", (state / "bridge.pid").read_text().strip(), "/F"], capture_output=True)
            time.sleep(1)

        # The real bridge process, told to dial T3 without waiting for a game.
        self.process = subprocess.Popen([sys.executable, str(ROOT / "bridge/promptpeon_bridge.py"), "run", "--always"],
                                        env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        slot = addons / "PromptPeonIn300/Data.lua"

        def snapshot_arrived():
            return slot.exists() and "A thread" in slot.read_text()

        self.wait_for(snapshot_arrived)
        text = slot.read_text()
        self.assertIn("Line 399 of a long agent answer.", text, "long messages arrive whole")
        self.assertNotIn(TOKEN, text)

        # The game writes frames into AddOns.txt, as the addon does.
        folder = self.wow / "WTF/Account/ME/Realm/Char"
        folder.mkdir(parents=True)
        target = folder / "AddOns.txt"
        target.write_text(addons_txt())
        time.sleep(2.5)  # The reader looks for new files every two seconds.
        for frame in python_frames(1, THREAD, "hello from the game, héllo"):
            target.write_text(addons_txt(frame))
            time.sleep(0.05)
        target.write_text(addons_txt())

        def reply_arrived():
            return FakeT3.received

        self.wait_for(reply_arrived)
        payload = FakeT3.received[0]["payload"]
        self.assertEqual(payload["type"], "message.dispatch")
        self.assertEqual(payload["threadId"], THREAD)
        self.assertEqual(payload["text"], "hello from the game, héllo")
        self.assertEqual(payload["dispatchMode"], {"type": "queue_after_active"})

        def ack_reached_the_game():
            return "ack=1" in slot.read_text() and 'res={["1"]="sent"}' in slot.read_text()

        self.wait_for(ack_reached_the_game)

        # A second bridge refuses to start.
        second = self.cli("run", "--always")
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("already running", second.stderr)


    def test_with_the_game_closed_the_last_message_goes_and_the_words_dont_stay(self):
        done = self.cli("install", "--wow-dir", str(self.wow), "--url", self.url, "--no-start", "--full-access", stdin=TOKEN + "\n\n")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        saved = self.wow / "WTF/Account/ACCOUNT/SavedVariables/PromptPeon.lua"
        saved.parent.mkdir(parents=True)
        words = f"1:{THREAD.encode().hex()}:{'last words'.encode().hex()}"
        saved.write_text(f'PromptPeonDB = {{\r\n["opacity"] = 0.7,\r\n["drafts"] = {{\r\n["t"] = "half a thought",\r\n}},\r\n}}\r\nPromptPeonOutbox = "{words}"\r\n', newline="")
        # No --always: as far as it can see, the game isn't running.
        self.process = subprocess.Popen([sys.executable, str(ROOT / "bridge/promptpeon_bridge.py"), "run"],
                                        env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

        def message_went():
            return any("last words" in str(row) for row in FakeT3.received)

        def words_gone():
            return "half a thought" not in saved.read_text()

        self.wait_for(message_went)
        self.wait_for(words_gone, seconds=20)
        self.assertIn('["opacity"] = 0.7', saved.read_text())
        self.assertIn('PromptPeonOutbox = ""', saved.read_text())

    def test_cancelling_a_queued_message_reaches_t3(self):
        if os.name == "nt":
            self.skipTest("the install path above covers Windows")
        done = self.cli("install", "--wow-dir", str(self.wow), "--url", self.url, "--full-access", "--no-start", stdin=TOKEN + "\n")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.process = subprocess.Popen([sys.executable, str(ROOT / "bridge/promptpeon_bridge.py"), "run", "--always"],
                                        env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        slot = self.wow / "Interface/AddOns/PromptPeonIn300/Data.lua"
        self.wait_for(lambda: slot.exists() and "A thread" in slot.read_text())
        folder = self.wow / "WTF/Account/ME/Realm/Char"
        folder.mkdir(parents=True)
        target = folder / "AddOns.txt"
        target.write_text(addons_txt())
        time.sleep(2.5)  # The reader looks for new files every two seconds.
        for frame in python_frames(1, THREAD, settings.COMMAND_MARK + "cancelq\nrun-7"):
            target.write_text(addons_txt(frame))
            time.sleep(0.05)
        target.write_text(addons_txt())
        self.wait_for(lambda: FakeT3.received)
        payload = FakeT3.received[0]["payload"]
        self.assertEqual((payload["type"], payload["threadId"], payload["runId"]), ("queued-run.cancel", THREAD, "run-7"))
        self.wait_for(lambda: 'res={["1"]="sent"}' in slot.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=1)
