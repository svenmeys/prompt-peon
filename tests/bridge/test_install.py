"""Installing, settling in, and taking it all back out."""
import os
import re
import shutil
import subprocess
import sys
import io
import unittest
from unittest import mock

from bridge_helpers import Base, ROOT
from promptpeon import addonfiles, installer, pairing, processes, prompts, safefiles, settings, uninstaller, wowfolder


class Uninstalling(Base):
    def test_it_takes_everything_of_ours_and_nothing_else(self):
        addonfiles.install_addon(self.wow, ROOT / "addon/PromptPeon")
        addons = self.wow / "Interface/AddOns"
        (addons / "SomeoneElse").mkdir()
        (addons / "PromptPeonEvil").mkdir()
        saved = self.wow / "WTF/Account/A/SavedVariables"
        saved.mkdir(parents=True)
        (saved / "PromptPeon.lua").write_text("x")
        (saved / "PromptPeon.lua.bak").write_text("x")
        (saved / "SomeoneElse.lua").write_text("x")
        cfg, state, home = self.dir / "cfg", self.dir / "state2", self.dir / "home2"
        for folder in (cfg, state, home):
            folder.mkdir()
        (cfg / "token").write_text("t")
        with mock.patch.object(settings, "CONFIG_DIR", cfg), mock.patch.object(settings, "STATE_DIR", state), mock.patch.object(settings, "HOME_DIR", home), \
                mock.patch.object(shutil, "which", lambda _: None), mock.patch.object(settings, "IS_WINDOWS", False), \
                mock.patch.object(processes, "game_running", lambda _: False), mock.patch.object(processes, "stop_running_bridge", lambda: True):
            uninstaller.uninstall(self.wow)
        self.assertEqual(sorted(path.name for path in addons.iterdir()), ["PromptPeonEvil", "SomeoneElse"])
        self.assertEqual([path.name for path in saved.iterdir()], ["SomeoneElse.lua"])
        self.assertFalse(cfg.exists() or state.exists() or home.exists())


class ClientVersion(Base):
    BUILD = ("Branch!STRING:0|Active!DEC:1|Version!STRING:0|Product!STRING:0\n"
             "eu|1|1.60.1.70707|wowf\neu|1|1.15.9.70576|wow_classic_era\neu|1|12.1.5.70688|wow\n")

    def client(self, name, build=BUILD):
        root = self.dir / "World of Warcraft"
        (root / name).mkdir(parents=True, exist_ok=True)
        if build:
            (root / ".build.info").write_text(build)
        return root / name

    def test_reads_the_interface_number_from_the_client(self):
        self.assertEqual(addonfiles.client_interface(self.client("_forever_")), "16001")
        self.assertEqual(addonfiles.client_interface(self.client("_classic_era_")), "11509")
        self.assertEqual(addonfiles.client_interface(self.client("_retail_")), "120105")

    def test_a_patch_gives_a_new_number(self):
        self.assertEqual(addonfiles.client_interface(self.client("_forever_", self.BUILD.replace("1.60.1", "1.62.3"))), "16203")
        self.assertEqual(addonfiles.client_interface(self.client("_retail_", self.BUILD.replace("12.1.5", "12.1.7"))), "120107")

    def test_falls_back_to_what_we_tested(self):
        wow = self.dir / "elsewhere/_forever_"
        wow.mkdir(parents=True)
        self.assertEqual(addonfiles.client_interface(wow), "16001")
        self.assertEqual(addonfiles.client_interface(self.client("_forever_", "nonsense")), "16001")

    def test_addon_follows_a_game_patch(self):
        wow = self.client("_forever_")
        addonfiles.install_addon(wow, ROOT / "addon/PromptPeon")
        addons = wow / "Interface/AddOns"
        addonfiles.keep_addon_current(wow)
        self.assertIn("## Interface: 16001", (addons / "PromptPeonIn300/PromptPeonIn300.toc").read_text())
        (wow.parent / ".build.info").write_text(self.BUILD.replace("1.60.1", "1.61.0"))
        addonfiles.keep_addon_current(wow)
        for name in ("PromptPeon/PromptPeon.toc", "PromptPeonIn300/PromptPeonIn300.toc", "PromptPeonOut96/PromptPeonOut96.toc"):
            text = (addons / name).read_text()
            self.assertIn("## Interface: 16100", text)
            self.assertNotIn("16001", text)


class SettlingIn(Base):
    def test_the_download_can_be_deleted_afterwards(self):
        download = self.dir / "Downloads/prompt-peon"
        (download / "bridge").mkdir(parents=True)
        (download / "bridge/promptpeon").mkdir()
        (download / "bridge/promptpeon_bridge.py").write_text("# bridge")
        (download / "bridge/promptpeon/settings.py").write_text("# settings")
        shutil.copytree(ROOT / "addon/PromptPeon", download / "addon/PromptPeon")
        with mock.patch.object(settings, "HOME_DIR", self.dir / "home"):
            script, addon = installer.settle_in(download / "bridge/promptpeon_bridge.py", download / "addon/PromptPeon")
            shutil.rmtree(download)
            self.assertEqual(script.read_text(), "# bridge")
            self.assertEqual((script.parent / "promptpeon/settings.py").read_text(), "# settings")
            self.assertTrue((addon / "Core.lua").exists())
            again = installer.settle_in(script, addon)
        self.assertEqual(again, (script, addon), "running it again from there changes nothing")

    def settle(self, home):
        with mock.patch.object(settings, "HOME_DIR", home):
            return installer.settle_in(ROOT / "bridge/promptpeon_bridge.py", ROOT / "addon/PromptPeon")

    def test_the_whole_program_comes_along_and_runs_from_there(self):
        target, _ = self.settle(self.dir / "home")
        wanted = {path.name for path in (ROOT / "bridge/promptpeon").glob("*.py")}
        self.assertEqual({path.name for path in (target.parent / "promptpeon").iterdir()}, wanted)
        for name in wanted:
            self.assertEqual((target.parent / "promptpeon" / name).read_bytes(), (ROOT / "bridge/promptpeon" / name).read_bytes())
        done = subprocess.run([sys.executable, "-I", str(target), "--help"], capture_output=True, text=True, timeout=60,
                              env=dict(os.environ, HOME=str(self.dir), USERPROFILE=str(self.dir)))
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual([path.name for path in target.parent.rglob("__pycache__")], [], "it leaves nothing compiled behind")

    def test_a_stale_module_gets_removed(self):
        # Whatever else sits in the program folder would run as us: an old module, or a compiled file Python prefers.
        home = self.dir / "home"
        package = home / "bridge/promptpeon"
        (package / "__pycache__").mkdir(parents=True)
        (package / "leftover").mkdir()
        (package / "old_module.py").write_text("raise SystemExit('stale')")
        (package / "__pycache__/settings.cpython-314.pyc").write_bytes(b"stale")
        (package / "leftover/inner.py").write_text("stale")
        (home / "bridge/stray.py").write_text("stale")
        if hasattr(os, "mkfifo"):
            os.mkfifo(package / "a_pipe")
        target, _ = self.settle(home)
        self.assertEqual({path.name for path in package.iterdir()}, {path.name for path in (ROOT / "bridge/promptpeon").glob("*.py")})
        self.assertEqual({path.name for path in target.parent.iterdir()}, {"promptpeon", "promptpeon_bridge.py"})

    def test_compiled_files_in_the_download_stay_behind(self):
        download = self.dir / "Downloads/prompt-peon"
        (download / "bridge/promptpeon/__pycache__").mkdir(parents=True)
        (download / "bridge/promptpeon_bridge.py").write_text("# bridge")
        (download / "bridge/promptpeon/settings.py").write_text("# settings")
        (download / "bridge/promptpeon/__pycache__/settings.cpython-314.pyc").write_bytes(b"compiled")
        shutil.copytree(ROOT / "addon/PromptPeon", download / "addon/PromptPeon")
        with mock.patch.object(settings, "HOME_DIR", self.dir / "home"):
            script, _ = installer.settle_in(download / "bridge/promptpeon_bridge.py", download / "addon/PromptPeon")
        self.assertEqual([path.name for path in (script.parent / "promptpeon").iterdir()], ["settings.py"])

    def test_a_link_in_the_program_folder_is_replaced_and_not_followed(self):
        home = self.dir / "home"
        package = home / "bridge/promptpeon"
        package.mkdir(parents=True)
        victim = self.dir / "my-document.txt"
        victim.write_text("precious")
        elsewhere = self.dir / "elsewhere"
        elsewhere.mkdir()
        (elsewhere / "keep.txt").write_text("precious")
        (package / "settings.py").symlink_to(victim)  # One we write to.
        (package / "not_ours.py").symlink_to(victim)  # One we remove.
        (package / "a_folder").symlink_to(elsewhere, target_is_directory=True)  # One a walk could go through.
        self.settle(home)
        self.assertEqual(victim.read_text(), "precious")
        self.assertEqual((elsewhere / "keep.txt").read_text(), "precious")
        self.assertFalse((package / "settings.py").is_symlink())
        self.assertEqual((package / "settings.py").read_bytes(), (ROOT / "bridge/promptpeon/settings.py").read_bytes())
        self.assertFalse((package / "not_ours.py").exists() or (package / "not_ours.py").is_symlink())
        self.assertFalse((package / "a_folder").exists() or (package / "a_folder").is_symlink())

    def test_the_package_folder_being_a_link_is_not_followed(self):
        home = self.dir / "home"
        (home / "bridge").mkdir(parents=True)
        elsewhere = self.dir / "elsewhere"
        elsewhere.mkdir()
        (elsewhere / "keep.txt").write_text("precious")
        (home / "bridge/promptpeon").symlink_to(elsewhere, target_is_directory=True)
        self.settle(home)
        self.assertEqual([path.name for path in elsewhere.iterdir()], ["keep.txt"])
        self.assertFalse((home / "bridge/promptpeon").is_symlink())
        self.assertTrue((home / "bridge/promptpeon/settings.py").is_file())


class Install(Base):
    def test_slots_point_at_one_snapshot(self):
        count = addonfiles.install_addon(self.wow, ROOT / "addon/PromptPeon")
        self.assertEqual(count, settings.SLOT_COUNT + settings.OUT_COUNT)
        addons = self.wow / "Interface/AddOns"
        snapshot = addons / "PromptPeon/Snapshot.lua"
        # Writes through a symlink or a hard link alike, so this test holds on every OS.
        safefiles.write_in_place(snapshot, "PROMPTPEON_SNAPSHOT = {v=1}\n")
        data = addons / "PromptPeonIn007/Data.lua"
        self.assertEqual(data.read_text(), "PROMPTPEON_SNAPSHOT = {v=1}\n")
        toc = (addons / "PromptPeonIn007/PromptPeonIn007.toc").read_text()
        self.assertIn("## LoadOnDemand: 1", toc)
        self.assertIn("## Group: PromptPeonIn001", toc)
        parent = (addons / "PromptPeonIn001/PromptPeonIn001.toc").read_text()
        self.assertIn(f"## Category: {settings.INTERNALS}", parent)
        self.assertNotIn("Category", toc)
        send = (addons / "PromptPeonOut96/PromptPeonOut96.toc").read_text()
        self.assertIn("## LoadOnDemand: 1", send)
        self.assertIn("## Group: PromptPeonIn001", send)
        self.assertNotIn("Data.lua", send)
        self.assertTrue((addons / "PromptPeon/Bindings.xml").exists())
        self.assertIn("## Interface: 16001", toc)
        self.assertTrue((addons / f"PromptPeonIn{settings.SLOT_COUNT:03d}").is_dir())

    def test_the_font_and_its_license_are_installed_intact(self):
        addonfiles.install_addon(self.wow, ROOT / "addon/PromptPeon")
        target = self.wow / "Interface/AddOns/PromptPeon"
        self.assertEqual((target / "IBMPlexMono-Regular.ttf").read_bytes(), (ROOT / "addon/PromptPeon/IBMPlexMono-Regular.ttf").read_bytes())
        self.assertIn("SIL Open Font License", (target / "IBMPlexMono-LICENSE.txt").read_text())

    def test_classic_era_gets_its_own_interface_number(self):
        era = self.dir / "_classic_era_"
        era.mkdir()
        addonfiles.install_addon(era, ROOT / "addon/PromptPeon")
        addons = era / "Interface/AddOns"
        self.assertIn("## Interface: 11509", (addons / "PromptPeon/PromptPeon.toc").read_text())
        self.assertIn("## Interface: 11509", (addons / "PromptPeonIn300/PromptPeonIn300.toc").read_text())

    def test_retail_gets_its_own_interface_number(self):
        retail = self.dir / "_retail_"
        retail.mkdir()
        addonfiles.install_addon(retail, ROOT / "addon/PromptPeon")
        addons = retail / "Interface/AddOns"
        self.assertIn("## Interface: 120105", (addons / "PromptPeon/PromptPeon.toc").read_text())
        self.assertIn("## Interface: 120105", (addons / "PromptPeonIn300/PromptPeonIn300.toc").read_text())

    def _client(self, folder, program):
        path = self.dir / "home/Games/x/drive_c/Program Files (x86)/World of Warcraft" / folder
        path.mkdir(parents=True)
        (path / program).write_text("")
        return path

    @unittest.skipIf(os.name == "nt", "Windows looks elsewhere: see WindowsPaths")
    def test_finds_the_only_client(self):
        era = self._client("_classic_era_", "WowClassic.exe")
        self.assertEqual(wowfolder.find_wow_dirs(None, home=self.dir / "home"), [era])

    @unittest.skipIf(os.name == "nt", "Windows looks elsewhere: see WindowsPaths")
    def test_two_clients_means_both_unless_you_choose(self):
        era = self._client("_classic_era_", "WowClassic.exe")
        forever = self._client("_forever_", "Wow.exe")
        self.assertEqual(sorted(wowfolder.find_wow_dirs(None, home=self.dir / "home")), sorted([era, forever]))
        self.assertEqual(wowfolder.find_wow_dirs(None, "era", home=self.dir / "home"), [era])
        self.assertEqual(wowfolder.find_wow_dirs(None, "forever", home=self.dir / "home"), [forever])

    def test_retail_is_found_and_can_be_chosen(self):
        retail = self._client("_retail_", "Wow.exe")
        roots = [retail.parent]  # A Windows machine looks on its drives, not in a home folder.
        self.assertEqual(wowfolder.find_wow_dirs(None, roots=roots), [retail], "the only one installed")
        self._client("_classic_era_", "WowClassic.exe")
        self.assertEqual(len(wowfolder.find_wow_dirs(None, roots=roots)), 2)
        self.assertEqual(wowfolder.find_wow_dirs(None, "retail", roots=roots), [retail])
        self.assertEqual(wowfolder.find_wow_dirs(str(retail)), [retail], "and by its folder")

    def test_the_installer_takes_retail(self):
        done = subprocess.run([sys.executable, "-I", str(ROOT / "bridge/promptpeon_bridge.py"), "install", "--client", "retail"],
                              env=dict(os.environ, HOME=str(self.dir), USERPROFILE=str(self.dir)), capture_output=True, text=True,
                              stdin=subprocess.DEVNULL)
        self.assertNotIn("invalid choice", done.stderr)

    def test_missing_client_is_named(self):
        self._client("_forever_", "Wow.exe")
        with self.assertRaises(SystemExit) as caught:
            wowfolder.find_wow_dirs(None, "era", home=self.dir / "home")
        self.assertIn("Install it first", str(caught.exception))

    def test_reinstall_starts_a_new_snapshot(self):
        # An old file could be hard linked to anything. The companion app fills the new one in.
        addonfiles.install_addon(self.wow, ROOT / "addon/PromptPeon")
        snapshot = self.wow / "Interface/AddOns/PromptPeon/Snapshot.lua"
        safefiles.write_atomic(snapshot, "PROMPTPEON_SNAPSHOT = {v=1,at=5}\n")
        addonfiles.install_addon(self.wow, ROOT / "addon/PromptPeon")
        self.assertNotIn("at=5", snapshot.read_text())

    def test_modes_match_the_addon(self):
        core = (ROOT / "addon/PromptPeon/Core.lua").read_text()
        self.assertEqual(tuple(re.findall(r'\{ id = "([a-z-]+)", label', core)), settings.RUNTIME_MODES)

    def test_slot_count_matches_the_addon(self):
        core = (ROOT / "addon/PromptPeon/Core.lua").read_text()
        self.assertIn(f"ns.SLOT_COUNT = {settings.SLOT_COUNT}", core)
        self.assertIn(f"ns.OUT_COUNT = {settings.OUT_COUNT}", core)


class StoppingTheOldCopy(Base):
    def test_windows_setup_stops_if_the_old_copy_cant_be_stopped(self):
        args = mock.Mock(wow_dir=str(self.wow), client=None, url=None, link=None, pictures=None, allow_unencrypted=False, full_access=None)
        with mock.patch.object(settings, "IS_WINDOWS", True), mock.patch.object(wowfolder, "find_wow_dirs", return_value=[self.wow]), \
                mock.patch.object(prompts, "wait_for_game_to_close"), mock.patch.object(pairing, "connect_to_t3", return_value="http://t3"), \
                mock.patch.object(prompts, "ask_about_other_addons"), mock.patch.object(prompts, "wants_full_access", return_value=False), \
                mock.patch.object(processes, "stop_running_bridge", return_value=False), mock.patch.object(installer, "settle_in") as settled, \
                mock.patch("sys.stdout", new_callable=io.StringIO), self.assertRaises(SystemExit) as caught:
            installer.install(args)
        settled.assert_not_called()
        self.assertIn("still running", str(caught.exception))


if __name__ == "__main__":
    unittest.main(verbosity=1)
