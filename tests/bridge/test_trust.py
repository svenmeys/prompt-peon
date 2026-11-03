"""Thread text only enters the game with your trust, and nothing typed stays behind."""
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import time
import unittest
from unittest import mock

from bridge_helpers import Base, FakeRemote, ROOT, THREAD, outbox, thread
from promptpeon import addonfiles, bridgestate, delivery, prompts, publishing, refreshing, savedvars, settings, t3errors


class ThreadTextNeedsTrust(Base):
    WORDS = ("my thoughts", "ls -la", "secret-branch", "secret error")

    def make(self, remote=None):
        shell = {"projects": [{"id": "p1", "title": "Shop"}],
                 "threads": [thread(branch="secret-branch", lastError="secret error", runtimeMode="full-access")]}
        remote = remote or FakeRemote(shell)
        return bridgestate.Bridge(self.wow, remote, state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json"), remote

    def text(self, bridge):
        refreshing.refresh(bridge)
        return bridge.snapshot_path.read_text(encoding="utf-8")

    def install_other(self, *names):
        for name in names:
            (self.wow / "Interface/AddOns" / name).mkdir(parents=True)

    def test_with_no_other_addons_everything_is_there(self):
        bridge, _ = self.make()
        text = self.text(bridge)
        self.assertIn("my thoughts", text)
        self.assertNotIn("lk", bridge.snapshot)

    def test_an_untrusted_addon_gets_names_and_status_but_no_words(self):
        self.install_other("SomeoneElse")
        bridge, _ = self.make()
        text = self.text(bridge)
        for words in self.WORDS:
            self.assertNotIn(words, text)
        row = bridge.snapshot["threads"][0]
        self.assertEqual((row["t"], row["p"], row["hd"]), ("A thread", "Shop", True))
        self.assertIn("s", row)
        self.assertIn("rm", row, "the log still has to know this agent has full access")
        self.assertIn("SomeoneElse isn't trusted yet", bridge.snapshot["lk"])
        self.assertIn("whether you trust it", bridge.snapshot["lk"])

    def test_saying_yes_brings_the_words_back_with_no_restart(self):
        self.install_other("SomeoneElse")
        bridge, _ = self.make()
        self.assertNotIn("my thoughts", self.text(bridge))
        (self.dir / "config.json").write_text(json.dumps({"trusted_addons": ["SomeoneElse"]}))
        self.assertIn("my thoughts", self.text(bridge))
        self.assertNotIn("lk", bridge.snapshot)

    def test_a_hundred_addons_are_still_one_short_line(self):
        self.install_other(*(f"Addon{number:03d}" for number in range(100)))
        bridge, _ = self.make()
        self.text(bridge)
        self.assertIn("Addon000 and 99 more aren't trusted yet", bridge.snapshot["lk"])
        self.assertLess(len(bridge.snapshot["lk"]), 200)

    def test_an_odd_addon_name_cant_dress_up_the_notice(self):
        # Not a real folder, because Windows doesn't allow a pipe in a name. Linux does.
        odd = "Evil|cffff0000Name" + "x" * 80
        bridge, _ = self.make()
        with mock.patch.object(addonfiles, "other_addons_in", return_value=[odd]):
            self.text(bridge)
        self.assertLess(len(bridge.snapshot["lk"]), 200)

    def test_words_already_there_go_when_a_new_addon_appears(self):
        bridge, _ = self.make()
        self.assertIn("my thoughts", self.text(bridge))
        bridge.loaded[THREAD] = {"df": [["secret-file.py"]], "until": time.monotonic() + 60}
        self.install_other("SomeoneElse")
        text = self.text(bridge)
        self.assertNotIn("my thoughts", text)
        self.assertNotIn("secret-file.py", text)
        self.assertEqual(bridge.loaded, {})

    def test_an_outage_keeps_no_words_either(self):
        bridge, remote = self.make()
        self.assertIn("my thoughts", self.text(bridge))
        self.install_other("SomeoneElse")
        remote._shell = OSError("no route")
        text = self.text(bridge)
        self.assertNotIn("my thoughts", text)
        self.assertIn("A thread", text, "the threads you had stay on screen")

    def test_a_changed_helper_keeps_the_words_out(self):
        addonfiles.install_addon(self.wow, ROOT / "addon/PromptPeon")
        (self.wow / "Interface/AddOns/PromptPeonIn001/Extra.lua").write_text("-- not ours")
        bridge, _ = self.make()
        self.assertNotIn("my thoughts", self.text(bridge))
        self.assertIn("PromptPeonIn001 has been changed", bridge.snapshot["lk"])

    def test_not_being_able_to_look_keeps_the_words_out(self):
        bridge, _ = self.make()
        with mock.patch.object(addonfiles, "other_addons_in", side_effect=OSError("denied")):
            self.assertNotIn("my thoughts", self.text(bridge))
        self.assertIn("Couldn't check", bridge.snapshot["lk"])

    def test_no_picture_is_fetched_or_left_behind(self):
        addonfiles.install_addon(self.wow, ROOT / "addon/PromptPeon")
        self.install_other("SomeoneElse")
        bridge, _ = self.make()
        with mock.patch.object(bridge.previews, "prepare", wraps=bridge.previews.prepare) as prepare, \
                mock.patch.object(bridge.previews, "clear_files", wraps=bridge.previews.clear_files) as clear:
            self.text(bridge)
            self.text(bridge)
        prepare.assert_not_called()
        self.assertEqual(clear.call_count, 1, "once when the words go, not on every refresh")

    def test_the_helpers_arent_walked_on_every_refresh(self):
        bridge, _ = self.make()
        with mock.patch.object(addonfiles, "tampered_addons", return_value=[]) as walked:
            self.text(bridge)
            self.text(bridge)
        self.assertEqual(walked.call_count, 1)

    def test_the_installer_asks_once_however_many_addons_there_are(self):
        self.install_other(*(f"Addon{number:03d}" for number in range(100)))
        printed = io.StringIO()
        with mock.patch.object(settings, "CONFIG_DIR", self.dir), mock.patch.object(sys.stdin, "isatty", return_value=True), \
                mock.patch.object(prompts, "ask", return_value="y") as asked, contextlib.redirect_stdout(printed):
            prompts.ask_about_other_addons(self.wow)
            prompts.ask_about_other_addons(self.wow)
        self.assertEqual(asked.call_count, 1, "yes is remembered")
        self.assertIn("Addon000, Addon001", printed.getvalue())
        self.assertIn("and 94 more", printed.getvalue())
        self.assertIn("no thread text", printed.getvalue())
        self.assertEqual(len(json.loads((self.dir / "config.json").read_text())["trusted_addons"]), 100)

    def test_the_installer_says_new_when_some_are_already_trusted(self):
        self.install_other("Old", "New")
        (self.dir / "config.json").write_text(json.dumps({"trusted_addons": ["Old"]}))
        printed = io.StringIO()
        with mock.patch.object(settings, "CONFIG_DIR", self.dir), mock.patch.object(sys.stdin, "isatty", return_value=True), \
                mock.patch.object(prompts, "ask", return_value="n"), contextlib.redirect_stdout(printed):
            prompts.ask_about_other_addons(self.wow)
        self.assertIn("You have a new addon: New.", printed.getvalue())


class NothingTypedStaysBehind(Base):
    SAVED = ('PromptPeonDB = {\r\n["opacity"] = 0.7,\r\n["drafts"] = {\r\n'
             '["t1"] = "a draft with [\\"pending\\"] = { and } and -- in it",\r\n},\r\n'
             '["hiddenThreads"] = {\r\n["t2"] = true,\r\n},\r\n["pending"] = {\r\n{\r\n["seq"] = 3,\r\n'
             '["text"] = "words\\nmore } words",\r\n}, -- [1]\r\n},\r\n["numberHigh"] = 39,\r\n}\r\n')

    def make(self, remote=None):
        remote = remote or FakeRemote()
        return bridgestate.Bridge(self.wow, remote, state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json"), remote

    def saved_file(self, text, name="PromptPeon.lua"):
        folder = self.wow / "WTF/Account/ACCOUNT/SavedVariables"
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / name
        path.write_bytes(text.encode("utf-8") if isinstance(text, str) else text)
        os.utime(path, (time.time() - 10, time.time() - 10))
        return path

    def test_only_the_typed_words_go_and_the_rest_stays_byte_for_byte(self):
        clean = savedvars.without_typed_words(self.SAVED + 'PromptPeonOutbox = "3:abcd:6869"\r\n')
        self.assertEqual(clean, 'PromptPeonDB = {\r\n["opacity"] = 0.7,\r\n["hiddenThreads"] = {\r\n["t2"] = true,\r\n},\r\n'
                                '["numberHigh"] = 39,\r\n}\r\nPromptPeonOutbox = ""\r\n')

    def test_the_result_is_still_a_file_lua_can_load(self):
        if not shutil.which("luajit"):
            self.skipTest("luajit is not installed")
        path = self.dir / "clean.lua"
        path.write_text(savedvars.without_typed_words(self.SAVED), newline="")
        code = f'dofile([[{path}]]); assert(PromptPeonDB.opacity == 0.7 and PromptPeonDB.hiddenThreads.t2 and not PromptPeonDB.drafts and not PromptPeonDB.pending)'
        done = subprocess.run(["luajit", "-e", code], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_nothing_to_clear_changes_nothing(self):
        text = 'PromptPeonDB = {\r\n["opacity"] = 0.7,\r\n}\r\nPromptPeonOutbox = ""\r\n'
        self.assertEqual(savedvars.without_typed_words(text), text)

    def test_a_file_it_cant_follow_is_left_alone(self):
        for broken in ('PromptPeonDB = {\r\n["drafts"] = {\r\n', 'PromptPeonDB = {\r\nnonsense\r\n}\r\n', 'PromptPeonDB = {\r\n["a"] = "never closed\r\n'):
            self.assertIsNone(savedvars.without_typed_words(broken), broken)
            path = self.saved_file(broken)
            self.assertFalse(savedvars.clear_typed_words(path))
            self.assertEqual(path.read_bytes(), broken.encode())

    def test_bytes_that_arent_utf8_survive(self):
        path = self.saved_file(self.SAVED.encode() + b'PromptPeonOdd = "caf\xe9"\r\n')
        self.assertTrue(savedvars.clear_typed_words(path))
        self.assertIn(b'caf\xe9', path.read_bytes())

    def test_closing_sends_the_last_message_then_clears_the_file_and_its_backup(self):
        bridge, remote = self.make()
        path = self.saved_file(self.SAVED + outbox((3, THREAD, "last words")))
        backup = self.saved_file(self.SAVED, "PromptPeon.lua.bak")
        delivery.clear_saved_words(bridge)
        self.assertIn(b"pending", path.read_bytes(), "not before the last message has been read")
        delivery.poll_outbox(bridge)
        self.assertEqual(remote.sent, [(THREAD, "last words")])
        delivery.clear_saved_words(bridge)
        for saved in (path, backup):
            self.assertNotIn(b"a draft", saved.read_bytes())
            self.assertNotIn(b"words", saved.read_bytes())
            self.assertIn(b"numberHigh", saved.read_bytes())
        self.assertNotIn("cleared", bridge.state, "that message went, so there's nothing to tell")

    def test_it_doesnt_read_the_file_again_or_treat_its_own_write_as_a_reload(self):
        bridge, _ = self.make()
        path = self.saved_file(self.SAVED + outbox((3, THREAD, "last words")))
        delivery.poll_outbox(bridge)
        delivery.clear_saved_words(bridge)
        with mock.patch.object(savedvars, "clear_typed_words") as again, mock.patch.object(bridge.previews, "new_ui_session") as reload_seen:
            delivery.clear_saved_words(bridge)
            delivery.poll_outbox(bridge)
        again.assert_not_called()
        reload_seen.assert_not_called()
        self.assertEqual(bridge.outbox_mtimes[path], path.stat().st_mtime)

    def test_a_message_that_couldnt_go_is_counted_for_next_time(self):
        bridge, _ = self.make(FakeRemote(send=t3errors.SendRefused("T3 said no")))
        self.saved_file(self.SAVED + outbox((3, THREAD, "last words"), (4, THREAD, "more words")))
        delivery.poll_outbox(bridge)
        delivery.clear_saved_words(bridge)
        self.assertEqual(bridge.state["cleared"]["n"], 2)
        at = bridge.state["cleared"]["at"]
        bridge.game_closed = False
        refreshing.refresh(bridge)
        self.assertEqual(bridge.snapshot["clr"], {"n": 2, "at": at})

    def test_a_client_you_moved_away_from_is_cleared_too(self):
        path = self.saved_file(self.SAVED)
        addonfiles.clear_game_folder(self.wow)
        self.assertNotIn(b"a draft", path.read_bytes())


    def test_t3_being_away_cant_keep_your_words_on_disk(self):
        bridge, _ = self.make()
        path = self.saved_file(self.SAVED + outbox((3, THREAD, "last words")))
        publishing.go_quiet(bridge)
        with mock.patch.object(bridge, "known_threads", return_value={}):
            delivery.poll_outbox(bridge)
        delivery.clear_saved_words(bridge)
        self.assertIn(b"pending", path.read_bytes(), "it gets a fair chance to go first")
        self.assertNotIn("cleared", bridge.state)
        bridge.closed_at -= settings.LAST_SEND_SECONDS + 1
        delivery.clear_saved_words(bridge)
        self.assertNotIn(b"a draft", path.read_bytes())
        self.assertNotIn(b"pending", path.read_bytes())
        self.assertEqual(bridge.state["cleared"]["n"], 1, "and the next session says it was lost")


if __name__ == "__main__":
    unittest.main(verbosity=1)
