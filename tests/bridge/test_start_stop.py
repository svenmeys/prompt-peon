"""The double-click switch that turns the companion app off and on."""
import subprocess
import unittest
from pathlib import Path
from unittest import mock

from bridge_helpers import Base, ROOT
from promptpeon import autostart, cli, processes, settings


class TheSwitch(Base):
    def setUp(self):
        super().setUp()
        self.home, self.state = self.dir / "home", self.dir / "state"
        self.state.mkdir()
        (self.home / "bridge").mkdir(parents=True)
        self.script = self.home / "bridge" / settings.ENTRY_POINT
        self.script.write_text("")
        self.stop_autostart = self.patched(autostart, "stop_autostart")
        self.stop_running = self.patched(processes, "stop_running_bridge", return_value=True)
        self.start_windows = self.patched(autostart, "enable_windows_autostart")
        self.start_linux = self.patched(autostart, "start_linux_service", return_value="The companion app is running.")
        self.patched(settings, "HOME_DIR", self.home)
        self.patched(settings, "STATE_DIR", self.state)

    def patched(self, owner, name, *value, **options):
        patcher = mock.patch.object(owner, name, *value, **options)
        self.addCleanup(patcher.stop)
        return patcher.start()

    def test_when_it_is_running_it_goes_off_and_stays_off(self):
        lock = processes.acquire_lock(self.state / "bridge.lock")
        self.addCleanup(lock.close)
        said = autostart.start_stop()
        self.stop_autostart.assert_called_once()
        self.stop_running.assert_called_once()
        self.start_linux.assert_not_called()
        self.start_windows.assert_not_called()
        self.assertIn("is off", said)

    def test_autostart_goes_first_or_systemd_would_bring_it_straight_back(self):
        lock = processes.acquire_lock(self.state / "bridge.lock")
        self.addCleanup(lock.close)
        order = mock.Mock()
        order.attach_mock(self.stop_autostart, "autostart")
        order.attach_mock(self.stop_running, "running")
        autostart.start_stop()
        self.assertEqual([call[0] for call in order.mock_calls], ["autostart", "running"])

    def test_when_it_wont_stop_it_says_so(self):
        lock = processes.acquire_lock(self.state / "bridge.lock")
        self.addCleanup(lock.close)
        self.stop_running.return_value = False
        said = autostart.start_stop()
        self.assertNotIn("is off", said)
        self.assertIn("still running", said)

    def test_when_it_is_stopped_the_installed_copy_starts_on_linux(self):
        self.patched(settings, "IS_WINDOWS", False)
        self.assertEqual(autostart.start_stop(), "The companion app is running.")
        self.start_linux.assert_called_once_with(self.script)
        self.stop_autostart.assert_not_called()

    def test_when_it_is_stopped_the_installed_copy_starts_on_windows(self):
        self.patched(settings, "IS_WINDOWS", True)
        self.patched(processes, "acquire_lock", return_value=mock.Mock())
        self.assertIn("is on", autostart.start_stop())
        self.start_windows.assert_called_once_with(self.script)

    def test_before_an_install_it_changes_nothing(self):
        self.script.unlink()
        self.assertIn("Run the installer first", autostart.start_stop())
        for fake in (self.stop_autostart, self.stop_running, self.start_linux, self.start_windows):
            fake.assert_not_called()

    def test_the_command_works_before_there_is_any_config(self):
        self.patched(autostart, "start_stop", return_value="flipped")
        with mock.patch("sys.argv", ["bridge", "start-stop"]), mock.patch("builtins.print") as printed:
            cli.main()
        printed.assert_called_once_with("flipped")


class TheFilesAreThere(unittest.TestCase):
    def test_the_installer_and_the_updater_bring_the_switch_along(self):
        self.assertTrue({"start-stop.cmd", "start-stop.sh"} <= settings.UPDATE_PARTS)
        code = (ROOT / "bridge/promptpeon/installer.py").read_text()
        self.assertIn("start-stop.cmd", code)
        self.assertIn("start-stop.sh", code)

    def test_the_windows_switch_keeps_windows_line_endings(self):
        data = (ROOT / "start-stop.cmd").read_bytes()
        self.assertEqual(data.count(b"\n"), data.count(b"\r\n"))


class WindowsStartsItFromItsOwnFolder(Base):
    def test_a_running_copy_doesnt_stand_in_the_download_folder(self):
        # Windows won't delete a folder something is standing in, and people delete their downloads.
        script = Path("C:/home/bridge") / settings.ENTRY_POINT
        fake_registry = mock.MagicMock()
        with mock.patch.dict("sys.modules", {"winreg": fake_registry}), \
                mock.patch.object(subprocess, "Popen") as popen, \
                mock.patch.object(subprocess, "DETACHED_PROCESS", 8, create=True), \
                mock.patch.object(subprocess, "CREATE_NO_WINDOW", 0x08000000, create=True):
            autostart.enable_windows_autostart(script)
        self.assertEqual(popen.call_args.kwargs["cwd"], script.parent)


if __name__ == "__main__":
    unittest.main(verbosity=1)
