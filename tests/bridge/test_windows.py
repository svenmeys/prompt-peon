"""Windows paths and hard links, with fakes, and the parts only a real Windows can run."""
import os
import subprocess
import sys
import unittest
from pathlib import Path

from bridge_helpers import Base, FakeRemote, ROOT, thread
from promptpeon import addonfiles, autostart, bridgestate, processes, refreshing, safefiles, settings, wowfolder


class HardLinks(Base):
    """What Windows uses: real hard links and writes in place, tested on any OS."""

    def install(self):
        addonfiles.install_addon(self.wow, ROOT / "addon/PromptPeon", hard_links=True)
        return self.wow / "Interface/AddOns"

    def test_every_slot_sees_each_update(self):
        addons = self.install()
        bridge = bridgestate.Bridge(self.wow, FakeRemote(), state_dir=self.dir / "state", in_place=True)
        refreshing.refresh(bridge)
        first = (addons / "PromptPeonIn001/Data.lua").read_text()
        self.assertIn("A thread", first)
        for name in ("PromptPeonIn150", "PromptPeonIn300"):
            self.assertEqual((addons / name / "Data.lua").read_text(), first)
        self.assertFalse((addons / "PromptPeonIn150/Data.lua").is_symlink())
        bridge.remote._shell = {"threads": [thread(title="Renamed")], "projects": []}
        refreshing.refresh(bridge)
        self.assertIn("Renamed", (addons / "PromptPeonIn300/Data.lua").read_text())

    def test_a_shorter_snapshot_leaves_no_old_tail(self):
        addons = self.install()
        snapshot = addons / "PromptPeon/Snapshot.lua"
        safefiles.write_in_place(snapshot, "x" * 5000)
        safefiles.write_in_place(snapshot, "short")
        self.assertEqual((addons / "PromptPeonIn007/Data.lua").read_text(), "short")

    def test_reinstall_keeps_links_working(self):
        addons = self.install()
        snapshot = addons / "PromptPeon/Snapshot.lua"
        safefiles.write_in_place(snapshot, "PROMPTPEON_SNAPSHOT = {v=1,at=5}\n")
        self.install()
        self.assertNotIn("at=5", (addons / "PromptPeonIn300/Data.lua").read_text(), "a new file, linked again")
        safefiles.write_in_place(snapshot, "changed")
        self.assertEqual((addons / "PromptPeonIn300/Data.lua").read_text(), "changed")


class WindowsPaths(Base):
    def _root(self, *clients):
        root = self.dir / "Program Files (x86)/World of Warcraft"
        for folder, program in clients:
            (root / folder).mkdir(parents=True)
            (root / folder / program).write_text("")
        return root

    def test_finds_client_in_given_roots(self):
        root = self._root(("_classic_era_", "WowClassic.exe"))
        self.assertEqual(wowfolder.find_wow_dirs(None, roots=[self.dir / "nope", root]), [root / "_classic_era_"])

    def test_two_clients_means_both_unless_you_choose(self):
        root = self._root(("_classic_era_", "WowClassic.exe"), ("_forever_", "Wow.exe"))
        self.assertEqual(len(wowfolder.find_wow_dirs(None, roots=[root])), 2)
        self.assertEqual(wowfolder.find_wow_dirs(None, "forever", roots=[root]), [root / "_forever_"])

    def test_registry_path_points_at_the_root(self):
        roots = wowfolder.windows_wow_roots(["D:/Games/WoW/_retail_/", "E:/Other WoW"], drives="C")
        self.assertEqual(roots[:2], [Path("D:/Games/WoW"), Path("E:/Other WoW")])
        self.assertIn(Path("C:/") / "Program Files (x86)/World of Warcraft", roots)

    def test_only_one_bridge_at_a_time(self):
        lock_path = self.dir / "state/bridge.lock"
        first = processes.acquire_lock(lock_path)
        self.assertIsNotNone(first)
        script = (f"import sys; sys.path.insert(0, {str(ROOT / 'bridge')!r}); from pathlib import Path; from promptpeon import processes; "
                  f"sys.exit(0 if processes.acquire_lock(Path({str(lock_path)!r})) is None else 1)")
        self.assertEqual(subprocess.run([sys.executable, "-c", script]).returncode, 0, "a second process must be refused")
        first.close()
        self.assertEqual(subprocess.run([sys.executable, "-c", script]).returncode, 1, "free again once the first is gone")

    def test_reader_works_while_the_file_keeps_changing(self):
        target = self.dir / "AddOns.txt"
        target.write_text("hello")
        self.assertEqual(safefiles.read_shared(target), "hello")


@unittest.skipUnless(os.name == "nt", "Windows only")
class RealWindows(Base):
    def test_autostart_key_is_written_for_this_user(self):
        import winreg

        command = autostart.enable_windows_autostart(ROOT / "bridge/promptpeon_bridge.py", start=False)
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, settings.RUN_KEY) as handle:
                self.assertEqual(winreg.QueryValueEx(handle, settings.RUN_VALUE)[0], command)
            self.assertIn("run", command)
        finally:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, settings.RUN_KEY, 0, winreg.KEY_SET_VALUE) as handle:
                winreg.DeleteValue(handle, settings.RUN_VALUE)

    def test_game_check_uses_tasklist(self):
        self.assertFalse(processes.game_running(Path("C:/x/_classic_era_")), "no game runs on this machine")
        real = settings.CLIENTS["_classic_era_"]
        settings.CLIENTS["_classic_era_"] = (real[0], Path(sys.executable).name)
        try:
            self.assertTrue(processes.game_running(Path("C:/x/_classic_era_")), "finds a program that is running")
        finally:
            settings.CLIENTS["_classic_era_"] = real

    def test_read_does_not_block_replacing_the_file(self):
        target = self.dir / "AddOns.txt"
        target.write_text("one")
        import ctypes
        self.assertTrue(ctypes.windll.kernel32)
        self.assertEqual(safefiles.read_shared(target), "one")
        os.replace(self._make("two"), target)
        self.assertEqual(safefiles.read_shared(target), "two")

    def _make(self, content):
        path = self.dir / "next.txt"
        path.write_text(content)
        return path

    def test_in_place_write_survives_a_reader_holding_the_file(self):
        target = self.dir / "Snapshot.lua"
        target.write_text("old")
        with open(target, "rb") as reader:
            self.assertTrue(safefiles.write_in_place(target, "new"))
            reader.read()
        self.assertEqual(target.read_text(), "new")


if __name__ == "__main__":
    unittest.main(verbosity=1)
