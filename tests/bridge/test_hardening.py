"""The security findings from the first reviews, kept fixed."""
import os
import queue
import shutil
import socket
import sys
import threading
import time
import unittest
import zlib
from pathlib import Path
from unittest import mock

from bridge_helpers import Base, CommandRemote, ROOT, THREAD, command, python_frames
from promptpeon import addonfiles, autostart, bridgestate, delivery, frames, loop, processes, publishing, refreshing, safefiles, settings, snapshots, t3errors, t3remote, uninstaller, userconfig, websocket


class Hardening(Base):
    """Each of these is a finding from the pen test at 3bbb0b0, turned into a check that stays."""

    def make(self, remote=None):
        remote = remote or CommandRemote()
        return bridgestate.Bridge(self.wow, remote, state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json"), remote

    def installed(self):
        addonfiles.install_addon(self.wow, ROOT / "addon/PromptPeon")
        return self.wow / "Interface/AddOns"

    def test_helper_names_have_to_be_exactly_ours(self):
        addons = self.wow / "Interface/AddOns"
        for name in ("PromptPeonIn9999", "PromptPeonOut00", "PromptPeonOut97", "PromptPeonIn0001", "PromptPeonIn1", "PromptPeonEvil"):
            (addons / name).mkdir(parents=True)
        self.assertEqual(addonfiles.other_addons_in(self.wow, []), sorted(["PromptPeonIn9999", "PromptPeonOut00", "PromptPeonOut97", "PromptPeonIn0001", "PromptPeonIn1", "PromptPeonEvil"]))
        self.assertIn("PromptPeonIn1000", addonfiles.OUR_ADDONS)
        self.assertIn("PromptPeonOut96", addonfiles.OUR_ADDONS)

    def test_a_folder_that_looks_like_ours_cant_send(self):
        (self.wow / "Interface/AddOns/PromptPeonIn9999").mkdir(parents=True)
        bridge, remote = self.make()
        delivery.deliver(bridge, [{"seq": 1, "thread": THREAD, "text": "do something awful"}])
        self.assertEqual(remote.sent, [])
        self.assertIn("PromptPeonIn9999", bridge.state["results"]["1"])

    def test_something_slipped_into_a_helper_stops_sending_until_repaired(self):
        cases = {
            "an extra file": lambda addons: (addons / "PromptPeonIn001/evil.lua").write_text("x"),
            "a client-specific toc": lambda addons: (addons / "PromptPeonIn001/PromptPeonIn001_Vanilla.toc").write_text("evil.lua"),
            "a toc that runs something else": lambda addons: (addons / "PromptPeonIn002/PromptPeonIn002.toc").write_text("Data.lua\nevil.lua\n"),
            "a send helper that runs code": lambda addons: (addons / "PromptPeonOut01/Data.lua").write_text("x"),
            "real code instead of the snapshot": lambda addons: ((addons / "PromptPeonIn003/Data.lua").unlink(), (addons / "PromptPeonIn003/Data.lua").write_text("x")),
            "another toc on the main addon": lambda addons: (addons / "PromptPeon/PromptPeon_Vanilla.toc").write_text("evil.lua"),
            "the main toc running something else": lambda addons: (addons / "PromptPeon/PromptPeon.toc").write_text("evil.lua\n"),
        }
        for name, tamper in cases.items():
            with self.subTest(name):
                addons = self.installed()
                tamper(addons)
                self.assertTrue(addonfiles.tampered_addons(self.wow), name)
                bridge, remote = self.make()
                bridge.state["ack"] = 0
                bridge.state["results"] = {}
                delivery.deliver(bridge, [{"seq": 1, "thread": THREAD, "text": "hello"}])
                self.assertEqual(remote.sent, [])
                self.assertIn("has been changed", bridge.state["results"]["1"])
                self.assertEqual(addonfiles.tampered_addons(self.wow) and self.installed() and addonfiles.tampered_addons(self.wow), [], "the installer repairs it")

    def test_a_clean_install_isnt_tampered(self):
        self.installed()
        self.assertEqual(addonfiles.tampered_addons(self.wow, ROOT / "addon/PromptPeon"), [])

    def test_changed_addon_code_is_noticed(self):
        addons = self.installed()
        (addons / "PromptPeon/Core.lua").write_text("-- not ours")
        self.assertEqual(addonfiles.tampered_addons(self.wow, ROOT / "addon/PromptPeon"), ["PromptPeon"])

    def test_an_install_never_writes_through_a_link(self):
        addons = self.installed()
        victim = self.dir / "my-document.txt"
        victim.write_text("precious")
        core = addons / "PromptPeon/Core.lua"
        core.unlink()
        core.symlink_to(victim)
        picture = addons / "PromptPeon/previews/p01.tga"
        picture.unlink()
        picture.symlink_to(self.dir / "not-there-yet.tga")
        self.installed()
        self.assertEqual(victim.read_text(), "precious")
        self.assertFalse(core.is_symlink())
        self.assertFalse(picture.is_symlink())
        self.assertFalse((self.dir / "not-there-yet.tga").exists())

    def test_a_linked_addon_folder_gets_replaced_not_followed(self):
        elsewhere = self.dir / "elsewhere"
        elsewhere.mkdir()
        shutil.rmtree(self.wow / "Interface/AddOns/PromptPeon", ignore_errors=True)
        (self.wow / "Interface/AddOns").mkdir(parents=True, exist_ok=True)
        (self.wow / "Interface/AddOns/PromptPeon").symlink_to(elsewhere)
        self.installed()
        self.assertEqual(list(elsewhere.iterdir()), [])
        self.assertFalse((self.wow / "Interface/AddOns/PromptPeon").is_symlink())

    def test_writing_a_file_cant_be_aimed_with_a_prepared_temp_name(self):
        victim = self.dir / "my-document.txt"
        victim.write_text("precious")
        target = self.dir / "Snapshot.lua"
        (self.dir / f".Snapshot.lua.{os.getpid()}.tmp").symlink_to(victim)
        safefiles.write_atomic(target, "new")
        self.assertEqual(victim.read_text(), "precious")
        self.assertEqual(target.read_text(), "new")
        self.assertFalse(target.is_symlink())

    def test_a_link_at_the_file_itself_gets_replaced(self):
        victim = self.dir / "my-document.txt"
        victim.write_text("precious")
        target = self.dir / "Snapshot.lua"
        target.symlink_to(victim)
        safefiles.write_atomic(target, "new")
        self.assertEqual(victim.read_text(), "precious")
        self.assertFalse(target.is_symlink())

    def test_the_token_never_goes_through_a_link(self):
        cfg = self.dir / "cfg"
        cfg.mkdir()
        victim = self.dir / "my-document.txt"
        victim.write_text("precious")
        (cfg / "token").symlink_to(victim)
        with mock.patch.object(settings, "CONFIG_DIR", cfg):
            userconfig.save_token("secret")
        self.assertEqual(victim.read_text(), "precious")
        self.assertEqual((cfg / "token").read_text(), "secret")
        if os.name != "nt":
            self.assertEqual((cfg / "token").stat().st_mode & 0o777, 0o600)

    def test_in_place_refuses_a_link(self):
        victim = self.dir / "my-document.txt"
        victim.write_text("precious")
        target = self.dir / "Snapshot.lua"
        target.symlink_to(victim)
        self.assertFalse(safefiles.write_in_place(target, "new"))
        self.assertEqual(victim.read_text(), "precious")

    def test_an_untrusted_addon_cant_unhide_but_anyone_can_hide_more(self):
        (self.wow / "Interface/AddOns/OrdinaryAddon").mkdir(parents=True)
        bridge, _ = self.make()
        bridge.state["hidden"] = {"projects": [], "threads": [THREAD]}
        delivery.deliver(bridge, [command(1, "settings", "hidden\n")])
        self.assertEqual(bridge.state["hidden"]["threads"], [THREAD], "showing it again needs trust")
        self.assertIn("OrdinaryAddon", bridge.state["results"]["1"])
        delivery.deliver(bridge, [command(2, "settings", "hidden\nt:" + THREAD + "\nt:another")])
        self.assertEqual(bridge.state["hidden"]["threads"], [THREAD, "another"])
        self.assertEqual(bridge.state["results"]["2"], "sent")

    def test_hiding_during_an_outage_takes_the_words_away_now(self):
        class Goes(CommandRemote):
            down = False

            def shell(self):
                if self.down:
                    raise OSError("gone")
                return super().shell()

            def detail(self, _thread_id):
                return {"rows": [["a", "my thoughts", "d", 1]]}

        bridge, remote = self.make(Goes())
        refreshing.refresh(bridge)
        self.assertIn("my thoughts", snapshots.render_snapshot(bridge.snapshot))
        remote.down = True
        refreshing.refresh(bridge)
        self.assertIn("my thoughts", snapshots.render_snapshot(bridge.snapshot), "an outage alone keeps what's on screen")
        delivery.deliver(bridge, [command(1, "settings", "hidden\nt:" + THREAD)])
        self.assertNotIn("my thoughts", snapshots.render_snapshot(bridge.snapshot))

    def test_a_reply_flushed_after_the_game_closed_brings_no_words_back(self):
        class Wordy(CommandRemote):
            def detail(self, _thread_id):
                return {"rows": [["a", "my thoughts", "d", 1]]}

        bridge, remote = self.make(Wordy())
        refreshing.refresh(bridge)
        snapshot_file = self.wow / "Interface/AddOns/PromptPeon/Snapshot.lua"
        self.assertIn("my thoughts", snapshot_file.read_text())
        publishing.go_quiet(bridge)
        self.assertNotIn("my thoughts", snapshot_file.read_text())
        delivery.deliver(bridge, [{"seq": 1, "thread": THREAD, "text": "one last thing"}])
        self.assertEqual(remote.sent, [(THREAD, "one last thing")], "the reply still goes")
        self.assertEqual(bridge.state["results"]["1"], "sent")
        self.assertNotIn("my thoughts", snapshot_file.read_text())
        self.assertIn("ack=1", snapshot_file.read_text(), "and the game can read its result next time")

    def test_a_game_that_reopens_gets_words_again(self):
        bridge, _ = self.make()
        publishing.go_quiet(bridge)
        bridge.game_closed = False
        refreshing.refresh(bridge)
        self.assertEqual(len(bridge.snapshot["threads"]), 1)

    def test_each_result_says_which_message_it_belongs_to(self):
        bridge, _ = self.make()
        delivery.deliver(bridge, [{"seq": 1, "thread": THREAD, "text": "hello"}])
        publishing.publish(bridge)
        self.assertEqual(bridge.snapshot["rc"]["1"], zlib.crc32(f"{THREAD}\0hello".encode()))

    def test_accounts_dont_share_a_half_read_message(self):
        reader = frames.FrameReader(self.wow, queue.Queue())
        first = python_frames(1, THREAD, "from account one, long enough to take several frames")
        second = python_frames(1, THREAD, "from account two, long enough to take several frames")
        self.assertGreater(len(first), 2)
        done = []
        for one, two in zip(first, second):
            for path, frame in ((Path("a"), one), (Path("b"), two)):
                message = reader.take(path, frame)
                if message:
                    done.append(message["text"])
        self.assertEqual(sorted(done), sorted(["from account one, long enough to take several frames", "from account two, long enough to take several frames"]))

    def test_a_gzip_bomb_stops_at_the_limit(self):
        bomb = zlib.compressobj(wbits=31)
        raw = bomb.compress(b"x" * 2_000_000) + bomb.flush()
        with mock.patch.object(settings, "MAX_T3_BYTES", 1_000_000):
            with self.assertRaises(t3errors.T3Changed):
                t3remote.gunzip_bounded(raw)
        self.assertEqual(len(t3remote.gunzip_bounded(raw)), 2_000_000)

    def test_an_endless_answer_stops_at_the_limit(self):
        class Endless:
            def read1(self, _size):
                return b"x" * 65536

        with mock.patch.object(settings, "MAX_T3_BYTES", 1_000_000):
            with self.assertRaises(t3errors.T3Changed):
                t3remote.read_bounded(Endless())

    def test_a_slow_trickle_stops_at_the_deadline(self):
        class Trickle:
            def read1(self, _size):
                return b"x"

        with mock.patch.object(settings, "T3_READ_SECONDS", -1):
            with self.assertRaises(t3errors.T3Changed):
                t3remote.read_bounded(Trickle())

    def test_websocket_refuses_a_giant_frame_and_a_wrong_handshake(self):
        socket_ = websocket.WebSocket.__new__(websocket.WebSocket)
        socket_.buffer, socket_.deadline = b"", time.monotonic() + 60
        with self.assertRaises(websocket.WebSocketClosed):
            socket_._read(settings.MAX_T3_BYTES + 1)
        server = socket.create_server(("127.0.0.1", 0))
        self.addCleanup(server.close)

        def answer():
            connection, _ = server.accept()
            connection.recv(4096)
            connection.sendall(b"HTTP/1.1 101 Switching\r\nSec-WebSocket-Accept: wrong\r\n\r\n")
            connection.close()

        threading.Thread(target=answer, daemon=True).start()
        with self.assertRaises(websocket.WebSocketClosed):
            websocket.WebSocket(f"ws://127.0.0.1:{server.getsockname()[1]}/ws")

    def test_history_that_never_ends_is_refused(self):
        remote = t3remote.T3Remote("http://127.0.0.1:1", "t")
        answers = {"bounded": {"projection": {"turnItems": []}, "hasMoreHistory": True, "historyCursor": "same"}}
        remote._request = lambda path: answers["bounded"] if path.endswith("/bounded") else {"items": [], "hasMoreHistory": True, "nextCursor": "same"}
        with self.assertRaises(t3errors.T3Changed):
            remote.older_rows(THREAD, 5)

    def test_a_giant_thread_cant_make_the_snapshot_giant(self):
        snapshot = {"threads": [{"id": "new", "m": [["a", "x" * 5_000_000, "d", 1]]}, {"id": "old", "m": [["a", "y" * 5_000_000, "d", 1]], "hm": True}]}
        snapshots.fit_snapshot(snapshot)
        self.assertEqual(snapshot["threads"][1]["m"], [settings.TOO_LONG_ROW], "the one updated longest ago goes first")
        self.assertEqual(snapshot["threads"][0]["m"][0][1][:1], "x")
        self.assertNotIn("hm", snapshot["threads"][1])

    def test_the_main_loop_survives_anything(self):
        bridge, _ = self.make()
        poll = mock.Mock(side_effect=[TypeError("a new shape"), KeyboardInterrupt()])
        with mock.patch.object(delivery, "poll_outbox", poll), mock.patch.object(addonfiles, "keep_addon_current"), self.assertRaises(KeyboardInterrupt):
            loop.run(bridge, always=True)
        self.assertEqual(poll.call_count, 2)

    def uninstall_setup(self):
        cfg, state, home = self.dir / "cfg", self.dir / "state2", self.dir / "home2"
        for folder in (cfg, state, home):
            folder.mkdir()
        return cfg, state, home

    def test_uninstall_cleans_every_client_it_went_into(self):
        era = self.dir / "game/_classic_era_"
        forever = self.dir / "game/_forever_"
        for client in (era, forever):
            (client / "Interface/AddOns/PromptPeon").mkdir(parents=True)
            (client / "Interface/AddOns/PromptPeon/Snapshot.lua").write_text("private")
            saved = client / "WTF/Account/A/SavedVariables"
            saved.mkdir(parents=True)
            (saved / "PromptPeon.lua").write_text("drafts")
        cfg, state, home = self.uninstall_setup()
        with mock.patch.object(settings, "CONFIG_DIR", cfg), mock.patch.object(settings, "STATE_DIR", state), mock.patch.object(settings, "HOME_DIR", home), \
                mock.patch.object(shutil, "which", lambda _: None), mock.patch.object(settings, "IS_WINDOWS", False), mock.patch.object(processes, "game_running", lambda _: False), \
                mock.patch.object(processes, "stop_running_bridge", lambda: True):
            uninstaller.uninstall(forever)
        for client in (era, forever):
            self.assertFalse((client / "Interface/AddOns/PromptPeon").exists())
            self.assertFalse((client / "WTF/Account/A/SavedVariables/PromptPeon.lua").exists())

    def test_uninstall_waits_for_the_game_to_close(self):
        with mock.patch.object(processes, "game_running", lambda _: True), self.assertRaises(SystemExit) as stopped:
            uninstaller.uninstall(self.wow)
        self.assertIn("Close WoW", str(stopped.exception))

    def test_switching_clients_clears_the_old_one(self):
        addons = self.installed()
        (addons / "PromptPeon/Snapshot.lua").write_text("private words")
        addonfiles.clear_game_folder(self.wow)
        self.assertNotIn("private words", (addons / "PromptPeon/Snapshot.lua").read_text())

    @unittest.skipIf(os.name == "nt", "a Linux service file, with Linux paths")
    def test_the_service_quotes_its_paths_and_runs_isolated(self):
        with mock.patch.object(Path, "home", lambda: self.dir), mock.patch.object(sys, "executable", "/py thon/python3"):
            autostart.write_systemd_unit(Path("/a b/100%/promptpeon_bridge.py"))
        unit = (self.dir / ".config/systemd/user/prompt-peon.service").read_text()
        self.assertIn('ExecStart="/py thon/python3" -I "/a b/100%%/promptpeon_bridge.py" run', unit)


if __name__ == "__main__":
    unittest.main(verbosity=1)
