"""What the later reviews found, kept fixed."""
import json
import os
import re
import shutil
import subprocess
import sys
import time
import unittest
from unittest import mock

from bridge_helpers import Base, CommandRemote, FakeImages, ROOT, THREAD, command, picture_row, thread
from promptpeon import addonfiles, bridgestate, delivery, gametext, installer, pairing, pngtga, previews, processes, prompts, refreshing, safefiles, settings, snapshots, t3remote, uninstaller, websocket


class ThirdLook(Base):
    """Findings from the code review of the fixes, turned into checks that stay."""

    def make(self, remote=None):
        remote = remote or CommandRemote()
        return bridgestate.Bridge(self.wow, remote, state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json"), remote

    def test_no_saved_answer_means_no(self):
        shell = {"threads": [thread(runtimeMode="full-access")], "projects": [{"id": "p1", "title": "Shop"}]}
        bridge, remote = self.make(CommandRemote(shell=shell))
        self.assertFalse(bridge.previews.allow_files)
        delivery.deliver(bridge, [{"seq": 1, "thread": THREAD, "text": "hello"}])
        self.assertEqual(remote.sent, [])
        self.assertIn("full access", bridge.state["results"]["1"])

    def test_a_config_we_cant_read_means_no(self):
        (self.dir / "config.json").write_text("{not json")
        shell = {"threads": [thread(runtimeMode="full-access")], "projects": [{"id": "p1", "title": "Shop"}]}
        bridge, remote = self.make(CommandRemote(shell=shell))
        self.assertFalse(bridge.previews.allow_files)
        delivery.deliver(bridge, [{"seq": 1, "thread": THREAD, "text": "hello"}])
        self.assertEqual(remote.sent, [])

    def test_the_program_copy_never_goes_through_a_link(self):
        home = self.dir / "home3"
        (home / "bridge").mkdir(parents=True)
        victim = self.dir / "my-document.txt"
        victim.write_text("precious")
        (home / "bridge/promptpeon_bridge.py").symlink_to(victim)
        (home / "addon").mkdir()
        elsewhere = self.dir / "elsewhere2"
        elsewhere.mkdir()
        (home / "addon/PromptPeon").symlink_to(elsewhere)
        with mock.patch.object(settings, "HOME_DIR", home):
            target, addon = installer.settle_in(ROOT / "bridge/promptpeon_bridge.py", ROOT / "addon/PromptPeon")
        self.assertEqual(victim.read_text(), "precious")
        self.assertEqual(list(elsewhere.iterdir()), [])
        self.assertFalse(target.is_symlink())
        self.assertEqual(target.read_bytes(), (ROOT / "bridge/promptpeon_bridge.py").read_bytes())
        self.assertFalse(addon.is_symlink())
        self.assertTrue((addon / "Core.lua").is_file())

    def test_settling_in_from_where_it_already_is_changes_nothing(self):
        home = self.dir / "home4"
        with mock.patch.object(settings, "HOME_DIR", home):
            target, addon = installer.settle_in(ROOT / "bridge/promptpeon_bridge.py", ROOT / "addon/PromptPeon")
            again_target, again_addon = installer.settle_in(target, addon)
        self.assertEqual(again_target.read_bytes(), (ROOT / "bridge/promptpeon_bridge.py").read_bytes())
        self.assertEqual((again_addon / "Core.lua").read_bytes(), (ROOT / "addon/PromptPeon/Core.lua").read_bytes())

    def test_a_snapshot_hard_linked_to_something_else_gets_replaced(self):
        addons = self.wow / "Interface/AddOns/PromptPeon"
        addonfiles.install_addon(self.wow, ROOT / "addon/PromptPeon")
        victim = self.dir / "my-document.txt"
        victim.write_text("precious")
        (addons / "Snapshot.lua").unlink()
        os.link(victim, addons / "Snapshot.lua")
        addonfiles.install_addon(self.wow, ROOT / "addon/PromptPeon", hard_links=True)
        self.assertTrue(safefiles.write_in_place(addons / "Snapshot.lua", "new words"))
        self.assertEqual(victim.read_text(), "precious")
        self.assertEqual((self.wow / "Interface/AddOns/PromptPeonIn001/Data.lua").read_text(), "new words", "and the helpers still see it")

    def test_a_picture_on_its_way_when_the_game_closes_stays_out(self):
        folder = self.dir / "pics"
        folder.mkdir()
        picture_files = previews.Previews(folder, FakeImages())
        picture_files.prepare("t", [picture_row("/a/queued.png")], True)
        picture_files.clear_files()
        self.assertFalse(picture_files.process_one(), "what was queued is gone")
        self.assertEqual(list(folder.iterdir()), [])

        slow = FakeImages()
        original = slow.image_bytes

        def closes_during_the_download(*args):
            previews2.clear_files()
            return original(*args)

        slow.image_bytes = closes_during_the_download
        previews2 = previews.Previews(folder, slow)
        previews2.prepare("t", [picture_row("/a/slow.png")], True)
        previews2.process_one()
        self.assertEqual([path for path in folder.iterdir() if path.stat().st_size != len(pngtga.blank_tga())], [])
        self.assertEqual(previews2.ready, {})

    def test_a_new_session_can_show_pictures_again(self):
        folder = self.dir / "pics2"
        folder.mkdir()
        picture_files = previews.Previews(folder, FakeImages())
        picture_files.clear_files()
        picture_files.prepare("t", [picture_row("/a/one.png")], True)
        picture_files.process_one()
        self.assertEqual(picture_files.prepare("t", [picture_row("/a/one.png")], True)[0][7], "")

    def fake_socket(self, answer):
        class Socket:
            def __init__(self, _url):
                pass

            def send_text(self, _text):
                pass

            def recv_text(self):
                return answer

            def close(self):
                pass

        return Socket

    def test_a_nonsense_answer_after_sending_says_we_dont_know(self):
        shell = {"threads": [thread()], "projects": [{"id": "p1", "title": "Shop"}]}
        remote = t3remote.T3Remote("http://127.0.0.1:1", "t")
        remote.shell = lambda: shell
        remote.detail = lambda _id: {"rows": []}
        real_request = remote._request
        remote._request = lambda path, **_: {"ticket": "x"} if "ticket" in path else real_request(path)
        bridge = bridgestate.Bridge(self.wow, remote, state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json")
        for seq, answer in enumerate(("[]", '{"_tag": "Exit", "requestId": "1", "exit": []}', "null"), start=1):
            with self.subTest(answer), mock.patch.object(websocket, "WebSocket", self.fake_socket(answer)):
                delivery.deliver(bridge, [{"seq": seq, "thread": THREAD, "text": "hello"}])
                self.assertTrue(bridge.state["results"][str(seq)].startswith("unknown:"), bridge.state["results"][str(seq)])
                self.assertNotIn("inflight", bridge.state)

    def test_a_failed_uninstall_can_be_run_again(self):
        cfg, state, home = self.dir / "cfg", self.dir / "state2", self.dir / "home2"
        for folder in (cfg, state, home):
            folder.mkdir()
        (cfg / "token").write_text("secret")
        (cfg / "config.json").write_text(json.dumps({"wow_dir": str(self.wow), "wow_dirs": [str(self.wow)]}))
        addon = self.wow / "Interface/AddOns/PromptPeon"
        addon.mkdir(parents=True, exist_ok=True)
        real_remove = safefiles.remove_path

        def locked(path):
            if path == addon:
                raise PermissionError("in use")
            real_remove(path)

        folders = dict(CONFIG_DIR=cfg, STATE_DIR=state, HOME_DIR=home, IS_WINDOWS=False)
        with mock.patch.multiple(settings, **folders), mock.patch.multiple(processes, game_running=lambda _: False, stop_running_bridge=lambda: True), \
                mock.patch.object(shutil, "which", lambda _: None):
            with mock.patch.object(safefiles, "remove_path", locked), self.assertRaises(SystemExit) as stopped:
                uninstaller.uninstall(self.wow)
            self.assertIn("run this again", str(stopped.exception))
            self.assertFalse((cfg / "token").exists(), "the token goes whatever else happens")
            self.assertEqual(uninstaller.game_folders_with_us(None), [self.wow], "it still knows where to look")
            uninstaller.uninstall(None)
        self.assertFalse(addon.exists())
        self.assertFalse(cfg.exists())

    def test_uninstall_notices_any_client_running(self):
        era = self.dir / "game/_classic_era_"
        forever = self.dir / "game/_forever_"
        for client in (era, forever):
            (client / "Interface/AddOns/PromptPeon").mkdir(parents=True)
        running = {str(era)}
        with mock.patch.object(settings, "CONFIG_DIR", self.dir / "cfg-none"), mock.patch.object(processes, "game_running", lambda folder: str(folder) in running), self.assertRaises(SystemExit):
            uninstaller.uninstall(forever)
        self.assertTrue((forever / "Interface/AddOns/PromptPeon").exists(), "nothing was touched")

    def test_a_hidden_threads_words_are_never_fetched(self):
        asked = []
        bridge, remote = self.make()
        remote.detail = lambda thread_id: asked.append(thread_id) or {"rows": [["a", "my thoughts", "d", 1]]}
        bridge.state["hidden"] = {"projects": [], "threads": [THREAD]}
        refreshing.refresh(bridge)
        self.assertEqual(asked, [])
        bridge.state["hidden"] = {"projects": [], "threads": []}
        refreshing.refresh(bridge)
        self.assertEqual(asked, [THREAD], "showing it again fetches it")


class SecondLook(Base):
    """Findings from the free-roam review at 3bbb0b0, turned into checks that stay."""

    def make(self, remote=None):
        remote = remote or CommandRemote()
        return bridgestate.Bridge(self.wow, remote, state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json"), remote

    def test_more_secret_shapes_are_caught(self):
        for text in ("password = correcthorsebattery", 'DB_PASS="correct"', "export DB_PASS=correcthorse", "token = abcdefgh1234",
                     "Authorization: Bearer abcdefghijklmnop", "postgres://app:s3cr3tvalue@db.internal:5432/prod",
                     "npm_abcdefghijklmnopqrstuvwxyz", "glpat-abcdefghijklmnopqrst",
                     "eyJhbGciOiJIUzI1NiJ9abc.abcdefghijklmnopqrstuv"):
            with self.subTest(text):
                hidden = gametext.hide_secrets(text)
                self.assertIn("[hidden secret]", hidden)
                for leaked in ("correcthorse", "s3cr3tvalue", "abcdefghijklmnop", "abcdefgh1234", '"correct"'):
                    self.assertNotIn(leaked, hidden)

    def test_ordinary_code_stays_readable(self):
        for text in ("password = config.password", "token = get_token()", "secret = None", "passing = everything", "authors: someone else",
                     "tokens = list_of_things", "auth = true", "https://example.com:8443/path", "see http://localhost:3000/"):
            with self.subTest(text):
                self.assertEqual(gametext.hide_secrets(text), text)

    def test_more_secret_files_stay_out_of_diffs(self):
        for path in (".envrc", "tokens.json", "auth.json", "app-secrets.yaml", "service-account.json", "private.key.txt", "deep/down/.git-credentials", ".pgpass"):
            with self.subTest(path):
                self.assertTrue(gametext.SECRET_FILE_RE.search(path))
        for path in ("src/tokenizer.py", "secretary.md", "authors.json", ".env.example", "docs/keys.md"):
            with self.subTest(path):
                self.assertFalse(gametext.SECRET_FILE_RE.search(path))

    def test_a_giant_message_gets_an_honest_end(self):
        text = gametext.message_text("x" * (settings.MAX_MESSAGE_CHARS + 5))
        self.assertTrue(text.endswith("(The rest of this message is in T3.)"))
        self.assertLess(len(text), settings.MAX_MESSAGE_CHARS + 100)
        self.assertEqual(gametext.message_text("x" * 1000), "x" * 1000)

    def test_a_hidden_project_isnt_offered_and_the_address_stays_out(self):
        shell = {"threads": [thread()], "projects": [{"id": "p1", "title": "Secret Project"}, {"id": "p2", "title": "Shop"}]}
        snapshot = snapshots.build_snapshot(shell, {}, url="http://100.64.1.2:3773", error="", error_since=0, ack=0, results={}, hidden={"projects": ["Secret Project"], "threads": []})
        self.assertEqual(snapshot["pj"], ["Shop"])
        self.assertNotIn("100.64.1.2", snapshots.render_snapshot(snapshot))

    def test_reading_has_a_limit_too(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(seq, THREAD, "diff") for seq in range(1, settings.MAX_READS_PER_MINUTE + 5)])
        self.assertEqual(sum(1 for call in remote.calls if call[0] == "diff"), settings.MAX_READS_PER_MINUTE)
        self.assertIn("too many", bridge.state["results"][str(settings.MAX_READS_PER_MINUTE + 1)])

    def test_a_removed_addon_stays_removed(self):
        bridge, _ = self.make()
        shutil.rmtree(self.wow / "Interface/AddOns/PromptPeon")
        refreshing.refresh(bridge)
        self.assertFalse((self.wow / "Interface/AddOns/PromptPeon").exists())

    def test_a_game_patch_doesnt_keep_lookalikes_alive(self):
        addonfiles.install_addon(self.wow, ROOT / "addon/PromptPeon")
        addons = self.wow / "Interface/AddOns"
        lookalike = addons / "PromptPeonEvil"
        lookalike.mkdir()
        (lookalike / "PromptPeonEvil.toc").write_text("## Interface: 99998\n")
        ours = addons / "PromptPeon/PromptPeon.toc"
        ours.write_text(re.sub(r"^## Interface: .*$", "## Interface: 1", ours.read_text(), flags=re.M))
        addonfiles.keep_addon_current(self.wow)
        self.assertNotIn("## Interface: 1\n", ours.read_text())
        self.assertEqual((lookalike / "PromptPeonEvil.toc").read_text(), "## Interface: 99998\n")

    def full_access(self, allowed, mode="full-access"):
        (self.dir / "config.json").write_text(json.dumps({"full_access": allowed}))
        shell = {"threads": [thread(runtimeMode=mode, activeRunId="run-now")], "projects": [{"id": "p1", "title": "Shop"}]}
        return self.make(CommandRemote(shell=shell))

    def test_full_access_is_something_you_turn_on(self):
        bridge, remote = self.full_access(False)
        remote.steer_queued = lambda *args: remote.calls.append(("steer",) + args)
        remote.set_model = lambda *args: remote.calls.append(("setmodel",) + args)
        delivery.deliver(bridge, [{"seq": 1, "thread": THREAD, "text": "delete everything"}, command(2, THREAD, "steer\nrun"), command(3, THREAD, "editq\nrun\nnew words")])
        self.assertEqual(remote.sent, [])
        self.assertEqual(remote.calls, [])
        for seq in "123":
            self.assertIn("full access", bridge.state["results"][seq])
            self.assertTrue(bridge.state["results"][seq].startswith("failed:"), "so your words come back")

    def test_you_can_always_stop_and_settle_a_full_access_agent(self):
        bridge, remote = self.full_access(False)
        delivery.deliver(bridge, [command(1, THREAD, "stop"), command(2, THREAD, "settle")])
        self.assertEqual(remote.calls, [("stop", THREAD), ("settle", THREAD)])

    def test_turned_on_it_works(self):
        bridge, remote = self.full_access(True)
        delivery.deliver(bridge, [{"seq": 1, "thread": THREAD, "text": "carry on"}])
        self.assertEqual(remote.sent, [(THREAD, "carry on")])

    def test_agents_that_ask_first_are_never_affected(self):
        bridge, remote = self.full_access(False, mode="approval-required")
        delivery.deliver(bridge, [{"seq": 1, "thread": THREAD, "text": "carry on"}])
        self.assertEqual(remote.sent, [(THREAD, "carry on")])

    def test_a_mode_we_dont_know_counts_as_full_access(self):
        bridge, remote = self.full_access(False, mode="some-new-mode")
        delivery.deliver(bridge, [{"seq": 1, "thread": THREAD, "text": "carry on"}])
        self.assertEqual(remote.sent, [])

    def test_the_question_defaults_to_no_and_remembers_yes(self):
        cfg = self.dir / "cfg"
        cfg.mkdir()
        with mock.patch.object(settings, "CONFIG_DIR", cfg):
            with mock.patch.object(sys.stdin, "isatty", lambda: False):
                self.assertFalse(prompts.wants_full_access(None), "nobody there to say yes")
            with mock.patch.object(sys.stdin, "isatty", lambda: True), mock.patch("builtins.input", return_value=""):
                self.assertFalse(prompts.wants_full_access(None))
            with mock.patch.object(sys.stdin, "isatty", lambda: True), mock.patch("builtins.input", return_value="yes"):
                self.assertTrue(prompts.wants_full_access(None))
            (cfg / "config.json").write_text(json.dumps({"full_access": True}))
            self.assertTrue(prompts.wants_full_access(None))
            self.assertFalse(prompts.wants_full_access(False), "the flag can turn it off")

    def test_a_pasted_link_names_where_it_goes_and_asks(self):
        with mock.patch.object(settings, "CONFIG_DIR", self.dir / "cfg"), mock.patch.object(pairing, "t3_program", lambda: None), \
                mock.patch.object(sys.stdin, "isatty", lambda: True), mock.patch("builtins.input", side_effect=["", "https://stranger.example/pair#token=abc", "no"]), \
                mock.patch.object(pairing, "exchange_pair_code") as exchange, self.assertRaises(SystemExit):
            pairing.connect_to_t3(None, None, False)
        exchange.assert_not_called()

    def test_stopping_only_ever_stops_us(self):
        state = self.dir / "state3"
        state.mkdir()
        (state / "bridge.pid").write_text("4242")
        held = iter([None] * 40)
        killed = []
        with mock.patch.object(settings, "STATE_DIR", state), mock.patch.object(settings, "IS_WINDOWS", False), mock.patch.object(processes, "acquire_lock", lambda _: next(held)), \
                mock.patch.object(os, "kill", lambda *args: killed.append(args)), mock.patch.object(time, "sleep", lambda _: None), \
                mock.patch.object(subprocess, "run", lambda *_a, **_k: mock.Mock(stdout="/usr/bin/someone-elses-program")):
            self.assertFalse(processes.stop_running_bridge())
        self.assertEqual(killed, [], "a reused number is somebody else's")

    def test_uninstall_wont_claim_success_with_one_still_running(self):
        (self.wow / "Interface/AddOns/PromptPeon").mkdir(parents=True, exist_ok=True)
        with mock.patch.object(processes, "game_running", lambda _: False), mock.patch.object(shutil, "which", lambda _: None), mock.patch.object(settings, "IS_WINDOWS", False), \
                mock.patch.object(processes, "stop_running_bridge", lambda: False), self.assertRaises(SystemExit) as stopped:
            uninstaller.uninstall(self.wow)
        self.assertIn("still running", str(stopped.exception))
        self.assertTrue((self.wow / "Interface/AddOns/PromptPeon").exists())


if __name__ == "__main__":
    unittest.main(verbosity=1)
