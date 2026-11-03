"""What the fix review found, kept fixed."""
import io
import json
import os
import shutil
import subprocess
import sys
import time
import unittest
from pathlib import Path
from unittest import mock

from bridge_helpers import Base, THREAD
from promptpeon import luadata, processes, publishing, settings, snapshots, t3errors, t3remote


class WhatTheReviewFound(Base):
    """A broken or hostile T3 can't stop the game loading its data, and a busy machine isn't made busier."""

    def test_a_number_lua_cant_read_becomes_zero(self):
        for bad in (float("inf"), float("-inf"), float("nan")):
            self.assertEqual(luadata.lua_value(bad), "0")
        self.assertEqual(luadata.lua_value({"a": [json.loads("1e999"), json.loads("-Infinity")]}), "{a={0,0}}")
        self.assertEqual(luadata.lua_value(1.5), "1.5")

    @unittest.skipUnless(shutil.which("luajit"), "needs LuaJIT")
    def test_such_a_snapshot_really_loads_in_lua(self):
        shell = json.loads('{"a": Infinity, "b": -Infinity, "c": NaN, "d": 1e999, "e": 2}')
        path = self.dir / "snapshot.lua"
        path.write_text(snapshots.render_snapshot(shell))
        done = subprocess.run(["luajit", "-e", f"dofile({str(path)!r}); assert(PROMPTPEON_SNAPSHOT.a == 0 and PROMPTPEON_SNAPSHOT.e == 2)"],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_lua_string_escapes_exactly_as_the_slow_way_did(self):
        def byte_by_byte(value):
            out = ['"']
            for byte in str(value).encode("utf-8", "replace"):
                if byte in (0x22, 0x5C):
                    out.append("\\" + chr(byte))
                elif 0x20 <= byte < 0x7F:
                    out.append(chr(byte))
                else:
                    out.append(f"\\{byte:03d}")
            out.append('"')
            return "".join(out)

        samples = ["".join(chr(code) for code in range(0x100)), "", '"]]..os.execute("x")--', "\\", "\n\r\t\0", "héllo → ✅ 🐉",
                   "\ud800 lone surrogate", "".join(chr(code) for code in range(0x100, 0x10FFFF, 997) if not 0xD800 <= code < 0xE000), 7]
        for sample in samples:
            self.assertEqual(luadata.lua_string(sample), byte_by_byte(sample))

    def test_a_thread_id_that_could_break_a_chat_link_is_refused(self):
        for bad in ("a|Hevil", "a b", "a\nb", "", "x" * 201):
            with self.assertRaises(t3errors.T3Changed, msg=bad):
                t3errors.check_shell({"threads": [{"id": bad}], "projects": []})
        for good in (THREAD, "thread:with:colons"):
            self.assertTrue(t3errors.check_shell({"threads": [{"id": good}], "projects": []}))

    def test_an_answer_nested_too_deep_reads_as_t3_changed(self):
        class Answer(io.BytesIO):
            headers = {}

            def __enter__(self):
                return self

        deep = b"[" * 2_000_000
        with mock.patch.object(t3remote.NO_REDIRECTS, "open", lambda *_a, **_k: Answer(deep)), self.assertRaises(t3errors.T3Changed):
            t3remote.T3Remote("http://127.0.0.1:1", "token").shell()

    def test_a_quiet_refresh_doesnt_render_the_snapshot(self):
        class Remote:
            url = "http://t3"

        bridge = self.bridge(Remote())
        with mock.patch.object(snapshots, "render_snapshot", wraps=snapshots.render_snapshot) as rendered:
            publishing.publish(bridge)
            self.assertEqual(rendered.call_count, 1, "once, to write it")
            publishing.publish(bridge)
            self.assertEqual(rendered.call_count, 1, "nothing changed, so no work at all")

    def stopping(self, command_line):
        state = self.dir / "state-stop"
        state.mkdir(exist_ok=True)
        (state / "bridge.pid").write_text("4242")
        calls = []

        def run(arguments, **_):
            calls.append(arguments)
            return mock.Mock(stdout=command_line, returncode=0)

        with mock.patch.object(settings, "STATE_DIR", state), mock.patch.object(settings, "IS_WINDOWS", True), \
                mock.patch.object(processes, "acquire_lock", lambda _: None), mock.patch.object(subprocess, "run", run), \
                mock.patch.object(subprocess, "CREATE_NO_WINDOW", 0, create=True), mock.patch.object(time, "sleep", lambda _: None):
            processes.stop_running_bridge()
        return calls

    def test_windows_only_stops_a_process_that_really_is_us(self):
        script = settings.ENTRY_POINT
        self.assertTrue(any("taskkill" in str(call[0]) for call in self.stopping(f'pythonw.exe -I "C:\\x\\{script}" run')))
        self.assertFalse(any("taskkill" in str(call[0]) for call in self.stopping("python.exe C:\\someone\\elses_server.py")))
        self.assertFalse(any("taskkill" in str(call[0]) for call in self.stopping("")), "can't tell, so leave it alone")

    @unittest.skipUnless(os.name == "nt", "real Windows processes")
    def test_on_real_windows_only_our_own_process_gets_stopped(self):
        state = self.dir / "state-real"
        state.mkdir()
        holder = '''import msvcrt, sys, time
handle = open(sys.argv[1], "a+")
handle.seek(0)
msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
print("ready", flush=True)
time.sleep(120)
'''

        def start(name):
            script = self.dir / name
            script.write_text(holder)
            child = subprocess.Popen([sys.executable, str(script), str(state / "bridge.lock")], stdout=subprocess.PIPE, text=True)
            self.addCleanup(child.kill)
            self.addCleanup(child.wait)
            self.assertEqual(child.stdout.readline().strip(), "ready")
            (state / "bridge.pid").write_text(str(child.pid))
            return child

        with mock.patch.object(settings, "STATE_DIR", state):
            somebody = start("someone_elses_server.py")
            self.assertFalse(processes.stop_running_bridge(), "that one isn't us, so it keeps running")
            self.assertIsNone(somebody.poll())
            somebody.kill()
            somebody.wait()
            ours = start(settings.ENTRY_POINT)
            self.assertTrue(processes.stop_running_bridge())
            ours.wait(timeout=10)

    @unittest.skipIf(os.name == "nt", "real Linux processes")
    def test_on_real_linux_only_our_own_process_gets_stopped(self):
        state = self.dir / "state-real"
        state.mkdir()
        holder = '''import fcntl, sys, time
handle = open(sys.argv[1], "a+")
fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
print("ready", flush=True)
time.sleep(120)
'''

        def start(name):
            script = self.dir / name
            script.write_text(holder)
            child = subprocess.Popen([sys.executable, str(script), str(state / "bridge.lock")], stdout=subprocess.PIPE, text=True)
            self.addCleanup(child.stdout.close)
            self.addCleanup(child.wait)
            self.addCleanup(child.kill)
            self.assertEqual(child.stdout.readline().strip(), "ready")
            (state / "bridge.pid").write_text(str(child.pid))
            return child

        with mock.patch.object(settings, "STATE_DIR", state), mock.patch.object(time, "sleep", lambda _: None):
            somebody = start("someone_elses_server.py")
            self.assertFalse(processes.stop_running_bridge(), "that one isn't us, so it keeps running")
            self.assertIsNone(somebody.poll())
            somebody.kill()
            somebody.wait()
        with mock.patch.object(settings, "STATE_DIR", state):
            ours = start(settings.ENTRY_POINT)
            self.assertTrue(processes.stop_running_bridge())
            ours.wait(timeout=10)

    def test_it_asks_windows_by_full_path(self):
        first = self.stopping("")[0]
        self.assertTrue(Path(first[0]).is_absolute() or ":" in first[0], first[0])

    def test_pictures_stop_at_4k(self):
        self.assertGreaterEqual(settings.MAX_IMAGE_PIXELS, 3840 * 2160)
        self.assertLess(settings.MAX_IMAGE_PIXELS, 5120 * 2880)


if __name__ == "__main__":
    unittest.main(verbosity=1)
