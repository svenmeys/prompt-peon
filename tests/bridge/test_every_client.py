"""One install works with every WoW client: it goes into all of them, and the app follows the game you open."""
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from bridge_helpers import Base, FakeRemote, ROOT
from promptpeon import delivery, installer, pairing, processes, prompts, publishing, settings, wowfolder


class FindsEveryClient(Base):
    def setUp(self):
        super().setUp()
        self.root = self.dir / "World of Warcraft"
        self.era, self.retail = self.client("_classic_era_", "WowClassic.exe"), self.client("_retail_", "Wow.exe")

    def client(self, folder, program):
        path = self.dir / "World of Warcraft" / folder
        path.mkdir(parents=True)
        (path / program).write_text("")
        return path

    def test_with_nothing_chosen_it_finds_them_all_without_asking(self):
        with mock.patch("builtins.input", side_effect=AssertionError("it shouldn't ask")):
            self.assertEqual(sorted(wowfolder.find_wow_dirs(None, roots=[self.root])), sorted([self.era, self.retail]))

    def test_you_can_still_name_one(self):
        self.assertEqual(wowfolder.find_wow_dirs(None, "retail", roots=[self.root]), [self.retail])
        self.assertEqual(wowfolder.find_wow_dirs(None, "era", roots=[self.root]), [self.era])
        self.assertEqual(wowfolder.find_wow_dirs(str(self.retail)), [self.retail])

    def test_a_folder_found_twice_counts_once(self):
        self.assertEqual(len(wowfolder.find_wow_dirs(None, roots=[self.root, self.root])), 2)

    def test_nothing_found_says_so(self):
        with self.assertRaises(SystemExit) as caught:
            wowfolder.find_wow_dirs(None, roots=[self.dir / "nope"])
        self.assertIn("Install it first", str(caught.exception))


class TheInstallerGoesIntoAllOfThem(Base):
    def install(self, found):
        cfg, state, home = self.dir / "cfg", self.dir / "state2", self.dir / "home2"
        args = mock.Mock(wow_dir=None, client=None, url=None, link=None, pictures=None, allow_unencrypted=False, full_access=None,
                         no_update=True, no_start=True, addon_source=str(ROOT / "addon/PromptPeon"))
        for owner, name, value in ((settings, "CONFIG_DIR", cfg), (settings, "STATE_DIR", state), (settings, "HOME_DIR", home),
                                   (wowfolder, "find_wow_dirs", mock.Mock(return_value=found)),
                                   (pairing, "connect_to_t3", mock.Mock(return_value="http://t3")),
                                   (prompts, "wants_full_access", mock.Mock(return_value=False)),
                                   (processes, "game_running", mock.Mock(return_value=False)),
                                   (processes, "stop_running_bridge", mock.Mock(return_value=True))):
            patcher = mock.patch.object(owner, name, value)
            self.addCleanup(patcher.stop)
            patcher.start()
        cfg.mkdir(exist_ok=True)
        with mock.patch("sys.stdout", new_callable=io.StringIO) as printed:
            installer.install(args)
        return printed.getvalue(), json.loads((cfg / "config.json").read_text())

    def clients(self):
        made = []
        for folder, version in (("_classic_era_", "11509"), ("_retail_", "120105")):
            path = self.dir / "World of Warcraft" / folder
            (path / "Interface/AddOns").mkdir(parents=True)
            (path / ".build.info").write_text(f"Version!STRING:0\n1.0.0.1|x|{version}\n")
            made.append(path)
        return made

    def test_the_addon_lands_in_each_and_the_config_knows_them_all(self):
        era, retail = self.clients()
        printed, config = self.install([era, retail])
        for client in (era, retail):
            self.assertTrue((client / "Interface/AddOns/PromptPeon/PromptPeon.toc").is_file(), client)
            self.assertTrue((client / "Interface/AddOns/PromptPeonIn001").is_dir(), client)
        self.assertEqual(sorted(config["wow_dirs"]), sorted([str(era), str(retail)]))
        self.assertIn(str(era), printed)
        self.assertIn(str(retail), printed)

    def test_one_question_covers_the_addons_in_every_client(self):
        era, retail = self.clients()
        (era / "Interface/AddOns/OnlyInEra").mkdir()
        (retail / "Interface/AddOns/OnlyInRetail").mkdir()
        with mock.patch.object(sys.stdin, "isatty", lambda: True), mock.patch.object(settings, "CONFIG_DIR", self.dir / "cfg"), \
                mock.patch("sys.stdout", new_callable=io.StringIO) as printed, mock.patch("builtins.input", return_value="y") as asked:
            (self.dir / "cfg").mkdir()
            prompts.ask_about_other_addons(era, retail)
        self.assertEqual(asked.call_count, 1)
        self.assertIn("OnlyInEra", printed.getvalue())
        self.assertIn("OnlyInRetail", printed.getvalue())
        trusted = json.loads((self.dir / "cfg/config.json").read_text())["trusted_addons"]
        self.assertEqual(sorted(trusted), ["OnlyInEra", "OnlyInRetail"])

    def test_naming_one_client_later_clears_thread_text_from_the_others(self):
        era, retail = self.clients()
        self.install([era, retail])
        (retail / "Interface/AddOns/PromptPeon/Snapshot.lua").write_text("PromptPeonSnapshot = 'words from a thread'\n")
        self.install([era])
        self.assertNotIn("words from a thread", (retail / "Interface/AddOns/PromptPeon/Snapshot.lua").read_text())


class WhichGameIsOpen(Base):
    def pgrep(self, *lines):
        done = mock.Mock(returncode=0 if lines else 1, stdout="\n".join(lines))
        return mock.patch.object(subprocess, "run", return_value=done)

    def linux(self):
        return mock.patch.object(settings, "IS_WINDOWS", False)

    def test_linux_tells_clients_apart_by_the_folder_in_the_command(self):
        retail, era = Path("/w/_retail_"), Path("/w/_classic_era_")
        with self.linux(), self.pgrep(r"123 C:\Program Files\World of Warcraft\_classic_era_\WoWClassic.exe -launcherlogin"):
            self.assertTrue(processes.game_running(era))
            self.assertFalse(processes.game_running(retail))

    def test_linux_with_a_command_that_names_no_folder_cant_tell_so_it_counts(self):
        with self.linux(), self.pgrep("123 ./Wow.exe"):
            self.assertTrue(processes.game_running(Path("/w/_retail_")))

    def test_linux_with_no_game_says_no(self):
        with self.linux(), self.pgrep():
            self.assertFalse(processes.game_running(Path("/w/_retail_")))

    def test_any_game_still_works_without_a_folder(self):
        with self.linux(), self.pgrep("123 ./Wow.exe"):
            self.assertTrue(processes.game_running())

    def test_the_first_open_one_wins_and_none_is_none(self):
        one, two = Path("/a"), Path("/b")
        with mock.patch.object(processes, "game_running", lambda client: client == two):
            self.assertEqual(processes.running_client([one, two]), two)
        with mock.patch.object(processes, "game_running", lambda client: True):
            self.assertEqual(processes.running_client([two, one]), two, "the one it already serves stays first")
        with mock.patch.object(processes, "game_running", lambda client: False):
            self.assertIsNone(processes.running_client([one, two]))

    def test_a_program_file_that_opens_for_writing_isnt_running(self):
        program = self.dir / "Wow.exe"
        program.write_text("")
        self.assertFalse(processes.running_from(program))

    def test_when_it_cant_tell_it_counts_as_running(self):
        self.assertTrue(processes.running_from(self.dir / "not-there.exe"))


@unittest.skipUnless(os.name == "nt", "Only Windows locks a running program's file")
class RealWindowsTellsThemApart(Base):
    def test_retail_and_forever_share_a_name_but_not_a_running_file(self):
        root = Path(tempfile.mkdtemp(dir=self.dir)) / "World of Warcraft"
        system = Path(os.environ["SystemRoot"]) / "System32"
        for client in ("_retail_", "_forever_"):
            (root / client).mkdir(parents=True)
            shutil.copy(system / "PING.EXE", root / client / "Wow.exe")
        game = subprocess.Popen([str(root / "_forever_/Wow.exe"), "-n", "60", "127.0.0.1"], stdout=subprocess.DEVNULL)
        try:
            time.sleep(1)
            self.assertTrue(processes.game_running(root / "_forever_"))
            self.assertFalse(processes.game_running(root / "_retail_"))
            self.assertEqual(processes.running_client([root / "_retail_", root / "_forever_"]), root / "_forever_")
        finally:
            game.kill()
            game.wait()
        time.sleep(0.5)
        self.assertFalse(processes.game_running(root / "_forever_"))


class SwitchingClients(Base):
    def setUp(self):
        super().setUp()
        self.other = self.dir / "_retail_"
        (self.other / "Interface/AddOns/PromptPeon/previews").mkdir(parents=True)
        (self.wow / "Interface/AddOns/PromptPeon/previews").mkdir(parents=True)
        self.config = self.dir / "config.json"
        self.config.write_text(json.dumps({"wow_dirs": [str(self.wow), str(self.other), str(self.dir / "_uninstalled_")]}))

    def bridge(self, remote=None):
        from promptpeon import bridgestate
        return bridgestate.Bridge(self.wow, remote or FakeRemote(), state_dir=self.dir / "state", in_place=False, config_path=self.config)

    def test_it_knows_the_clients_it_went_into_with_its_own_first(self):
        self.assertEqual(self.bridge().clients(), [self.wow, self.other])

    def test_a_client_that_lost_the_addon_doesnt_count(self):
        shutil.rmtree(self.other / "Interface")
        self.assertEqual(self.bridge().clients(), [self.wow])

    def test_switching_moves_the_snapshot_and_pictures_and_starts_clean(self):
        bridge = self.bridge()
        bridge.last_written, bridge.last_write_at, bridge.helpers_changed = "old", 5.0, ["x"]
        leftover = self.other / "Interface/AddOns/PromptPeon/previews/p01.tga"
        leftover.write_bytes(b"a picture from before")
        bridge.use_client(self.other)
        self.assertEqual(bridge.wow_dir, self.other)
        self.assertEqual(bridge.snapshot_path, self.other / "Interface/AddOns/PromptPeon/Snapshot.lua")
        self.assertEqual(bridge.previews.folder, self.other / "Interface/AddOns/PromptPeon/previews")
        self.assertEqual((bridge.last_written, bridge.last_write_at, bridge.helpers_changed), ("", 0.0, []))
        self.assertNotEqual(leftover.read_bytes(), b"a picture from before", "pictures from another session don't show")

    def test_what_you_publish_afterwards_lands_in_the_new_client(self):
        bridge = self.bridge()
        bridge.use_client(self.other)
        bridge.shell = {"threads": [], "projects": []}
        publishing.publish(bridge)
        self.assertTrue((self.other / "Interface/AddOns/PromptPeon/Snapshot.lua").is_file())
        self.assertFalse((self.wow / "Interface/AddOns/PromptPeon/Snapshot.lua").exists())

    def test_words_left_in_a_client_you_left_get_cleared(self):
        saved = self.other / "WTF/Account/ME/SavedVariables"
        saved.mkdir(parents=True)
        path = saved / f"{settings.ADDON}.lua"
        path.write_text('PromptPeonDB = {\n["drafts"] = {\n["t1"] = "a secret draft",\n},\n}\n')
        delivery.clear_saved_words(self.bridge(), self.other, force=True)
        self.assertNotIn("a secret draft", path.read_text())

    def test_without_force_it_still_waits_for_a_last_message(self):
        saved = self.wow / "WTF/Account/ME/SavedVariables"
        saved.mkdir(parents=True)
        path = saved / f"{settings.ADDON}.lua"
        path.write_text('PromptPeonDB = {\n["drafts"] = {\n["t1"] = "a secret draft",\n},\n}\n')
        delivery.clear_saved_words(self.bridge())
        self.assertIn("a secret draft", path.read_text())


class TheUpdateCheckCanBeTurnedOff(Base):
    def test_it_starts_unless_you_said_no(self):
        code = (ROOT / "bridge/promptpeon/loop.py").read_text()
        self.assertIn('bridge.config().get("update_check") is not False', code)


if __name__ == "__main__":
    unittest.main(verbosity=1)
