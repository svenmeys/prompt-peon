"""The installer's one update check."""
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import zipfile
from pathlib import Path
from unittest import mock

from bridge_helpers import Base, ROOT
from promptpeon import cli, settings, t3remote, updater


class TheGameGetsTold(Base):
    """While the game is open the app asks whether a newer release exists. It only ever asks."""

    def bridge_with_release(self, tag_or_error):
        bridge = mock.Mock(newer_release=None)
        side = {"side_effect": tag_or_error} if isinstance(tag_or_error, Exception) else {"return_value": tag_or_error}
        patcher = mock.patch.object(updater, "latest_release", **side)
        self.addCleanup(patcher.stop)
        patcher.start()
        return bridge

    def test_a_newer_release_is_noted(self):
        bridge = self.bridge_with_release("99.0.0")
        updater.check_for_newer(bridge)
        self.assertEqual(bridge.newer_release, "99.0.0")

    def test_numbers_compare_as_numbers(self):
        with mock.patch.object(settings, "VERSION", "0.9.0"):
            self.assertTrue(updater.is_newer("0.10.0"))
            self.assertFalse(updater.is_newer("0.9.0"))
            self.assertFalse(updater.is_newer("0.8.9"))

    def test_the_same_or_an_older_one_is_not(self):
        for version in (settings.VERSION, "0.0.1"):
            bridge = self.bridge_with_release(version)
            updater.check_for_newer(bridge)
            self.assertIsNone(bridge.newer_release, version)

    def test_github_being_away_bothers_nobody_and_keeps_what_it_knew(self):
        bridge = self.bridge_with_release(urllib.error.URLError("away"))
        bridge.newer_release = "99.0.0"
        updater.check_for_newer(bridge)
        self.assertEqual(bridge.newer_release, "99.0.0")

    def test_it_never_downloads_or_runs_anything(self):
        bridge = self.bridge_with_release("99.0.0")
        with mock.patch.object(updater, "download_release") as download, mock.patch.object(subprocess, "run") as run:
            updater.check_for_newer(bridge)
        download.assert_not_called()
        run.assert_not_called()

    def test_the_notice_says_what_to_run(self):
        with mock.patch.object(settings, "IS_WINDOWS", True):
            self.assertEqual(updater.update_notice("9.9.9"), "Prompt Peon 9.9.9 is out. Close WoW, then double-click install.cmd in %LOCALAPPDATA%\\prompt-peon.")
        with mock.patch.object(settings, "IS_WINDOWS", False):
            self.assertEqual(updater.update_notice("9.9.9"), "Prompt Peon 9.9.9 is out. Close WoW, then run: sh ~/.local/share/prompt-peon/install.sh")

    def watch(self, game_open, clock):
        """Runs the watcher for one wake-up per clock reading, and says how often it asked GitHub."""
        class Done(Exception):
            pass
        readings = iter(clock)
        now = [0]

        def sleep(_seconds):
            try:
                now[0] = next(readings)
            except StopIteration:
                raise Done from None

        # Only this module's clock, because the real one is shared with every other thread.
        fake_time = mock.Mock(sleep=sleep, monotonic=lambda: now[0])
        with mock.patch.object(updater, "time", fake_time), mock.patch.object(updater, "latest_release", return_value="99.0.0") as asked:
            with self.assertRaises(Done):
                updater.watch_for_releases(mock.Mock(newer_release=None), game_open)
        return asked.call_count

    def test_with_the_game_closed_github_is_never_asked(self):
        self.assertEqual(self.watch(lambda: False, [0, 1, 2]), 0)

    def test_it_asks_once_every_thirty_minutes_while_the_game_is_open(self):
        half_hour = settings.UPDATE_CHECK_SECONDS
        self.assertEqual(self.watch(lambda: True, [0, 1, half_hour - 1, half_hour, half_hour + 1]), 2)

    def test_a_snapshot_carries_the_notice_only_when_there_is_one(self):
        from promptpeon import publishing

        self.assertIn("up", publishing.update_fields("9.9.9"))
        self.assertIn("9.9.9", publishing.update_fields("9.9.9")["up"])
        self.assertEqual(publishing.update_fields(None), {})


class TheInstalledCopyCounts(Base):
    """An old download run again shouldn't read like a failed update, or put an older version back."""

    def setUp(self):
        super().setUp()
        patchers = [mock.patch.object(settings, "HOME_DIR", self.dir / "program"), mock.patch.object(settings, "VERSION", "1.0.0"),
                    mock.patch("sys.stdout", new_callable=io.StringIO), mock.patch.object(subprocess, "run", return_value=mock.Mock(returncode=3))]
        for patcher in patchers:
            self.addCleanup(patcher.stop)
        _home, _version, self.printed, self.ran = [patcher.start() for patcher in patchers]

    def installed(self, version, script=True):
        folder = settings.HOME_DIR / "bridge" / settings.PACKAGE
        folder.mkdir(parents=True)
        (folder / "settings.py").write_text(f'"""Words."""\nVERSION = "{version}"\nOTHER = 1\n')
        if script:
            (folder.parent / settings.ENTRY_POINT).write_text("")

    def run_it(self, github):
        """GitHub answers with this version, or with this error. Says whether it handed over, and to what."""
        answer = {"side_effect": github} if isinstance(github, Exception) else {"return_value": github}
        with mock.patch.object(updater, "latest_release", **answer), \
                mock.patch.object(updater, "download_release", side_effect=urllib.error.URLError("no download")) as self.fetched:
            try:
                updater.use_the_latest(["install"])
            except SystemExit as stopped:
                self.assertEqual(stopped.code, 3, "its answer counts")
                return Path(self.ran.call_args.args[0][2])
        self.ran.assert_not_called()
        return None

    def test_an_old_download_uses_the_newest_install_without_downloading(self):
        self.installed("2.0.0")
        self.assertEqual(self.run_it("2.0.0"), settings.HOME_DIR / "bridge" / settings.ENTRY_POINT)
        self.fetched.assert_not_called()
        self.assertIn("--no-update", self.ran.call_args.args[0])
        self.assertIn("This copy is 1.0.0, but 2.0.0 is already installed", self.printed.getvalue())
        self.assertNotIn("Using 2.0.0 from GitHub", self.printed.getvalue())

    def test_with_github_away_an_old_download_never_puts_an_older_version_back(self):
        self.installed("2.0.0")
        self.assertEqual(self.run_it(urllib.error.URLError("away")), settings.HOME_DIR / "bridge" / settings.ENTRY_POINT)
        self.assertIn("2.0.0", self.printed.getvalue())

    def test_a_failed_download_never_puts_an_older_version_back_either(self):
        self.installed("2.0.0")
        self.assertEqual(self.run_it("3.0.0"), settings.HOME_DIR / "bridge" / settings.ENTRY_POINT)
        self.fetched.assert_called_once()

    def test_something_newer_than_the_install_is_still_downloaded(self):
        self.installed("2.0.0")
        self.run_it("3.0.0")
        self.fetched.assert_called_once_with("3.0.0")

    def test_the_installed_copy_running_itself_doesnt_go_round_in_circles(self):
        self.installed("1.0.0")
        self.assertIsNone(self.run_it("1.0.0"))
        self.assertIn("You have the newest version", self.printed.getvalue())

    def test_a_newer_download_goes_ahead_over_an_older_install(self):
        self.installed("0.5.0")
        self.assertIsNone(self.run_it("1.0.0"))
        self.assertIn("You have the newest version", self.printed.getvalue())

    def test_nothing_installed_is_no_problem(self):
        self.assertIsNone(self.run_it("1.0.0"))

    def test_an_install_it_cant_start_doesnt_count(self):
        self.installed("2.0.0", script=False)
        self.assertIsNone(updater.installed_version())
        self.assertIsNone(self.run_it("1.0.0"))

    def test_an_install_that_cant_say_its_version_doesnt_count(self):
        self.installed("not a version")
        self.assertIsNone(updater.installed_version())


class InstallerFetchesLatest(Base):
    """Running the installer by hand gets the newest release from GitHub, and nothing else ever does."""

    def setUp(self):
        super().setUp()
        patcher = mock.patch.object(settings, "HOME_DIR", self.dir / "program")  # Never this machine's real install.
        self.addCleanup(patcher.stop)
        patcher.start()

    def release(self, version="9.9.9", script=None, extra=(), version_file=None):
        out = io.BytesIO()
        with zipfile.ZipFile(out, "w") as archive:
            archive.writestr(f"prompt-peon-{version}/bridge/promptpeon_bridge.py", script or "# what starts it\n")
            archive.writestr(f"prompt-peon-{version}/bridge/promptpeon/settings.py", version_file or f'VERSION = "{version}"\n')
            archive.writestr(f"prompt-peon-{version}/addon/PromptPeon/PromptPeon.toc", "## Interface: 1\n")
            archive.writestr(f"prompt-peon-{version}/install.cmd", "new installer")
            archive.writestr(f"prompt-peon-{version}/docs/INSTALL.md", "not needed to install")
            for name, data in extra:
                archive.writestr(name.replace("TOP", f"prompt-peon-{version}") if isinstance(name, str) else name, data)
        return out.getvalue()

    def offering(self, version, data=None):
        """GitHub says this is the newest release, and hands over this download for it."""
        return mock.patch.multiple(updater, latest_release=lambda: version,
                                   download_release=lambda asked: data if data is not None else self.release(asked))

    def test_a_newer_release_takes_over_and_its_answer_counts(self):
        seen = self.dir / "seen.txt"
        script = f'''import sys
from pathlib import Path
Path({str(seen)!r}).write_text(" ".join(sys.argv[1:]))
sys.exit(7)
'''
        made = []
        real = tempfile.mkdtemp
        with self.offering("9.9.9", self.release(script=script)), \
                mock.patch.object(tempfile, "mkdtemp", lambda **kw: made.append(real(**kw)) or made[-1]), \
                mock.patch("sys.stdout", new_callable=io.StringIO) as printed:
            with self.assertRaises(SystemExit) as caught:
                updater.use_the_latest(["install", "--client", "era"])
        self.assertEqual(caught.exception.code, 7)
        self.assertEqual(seen.read_text(), "install --client era --no-update")
        self.assertIn("9.9.9", printed.getvalue())
        self.assertFalse(Path(made[0]).exists(), "the download is cleaned up")

    def test_the_same_or_an_older_release_downloads_nothing(self):
        for version in (settings.VERSION, "0.0.1"):
            with mock.patch.object(updater, "latest_release", lambda: version), mock.patch.object(updater, "download_release") as fetched, \
                    mock.patch.object(subprocess, "run") as ran, mock.patch("sys.stdout", new_callable=io.StringIO):
                updater.use_the_latest(["install"])
            fetched.assert_not_called()
            ran.assert_not_called()

    def test_versions_compare_as_numbers(self):
        with mock.patch.object(settings, "VERSION", "0.9.9"), self.offering("0.10.0"), \
                mock.patch.object(subprocess, "run", return_value=mock.Mock(returncode=0)) as ran, \
                mock.patch("sys.stdout", new_callable=io.StringIO):
            with self.assertRaises(SystemExit):
                updater.use_the_latest(["install"])
        ran.assert_called_once()

    def test_a_release_whose_program_says_another_version_is_refused(self):
        with self.offering("9.9.9", self.release("9.9.8")), mock.patch.object(subprocess, "run") as ran, \
                mock.patch("sys.stdout", new_callable=io.StringIO) as printed:
            updater.use_the_latest(["install"])
        ran.assert_not_called()
        self.assertIn(settings.VERSION, printed.getvalue())

    def test_anything_going_wrong_carries_on_with_this_copy(self):
        def offline(*_):
            raise OSError("no network")

        for latest, fetch in ((offline, None), (lambda: "9.9.9", offline), (lambda: "9.9.9", lambda _: b"not a zip file"),
                              (lambda: "9.9.9", lambda _: self.release(version_file="no version here\n"))):
            with mock.patch.multiple(updater, latest_release=latest, download_release=fetch or offline), \
                    mock.patch.object(subprocess, "run") as ran, mock.patch("sys.stdout", new_callable=io.StringIO) as printed:
                updater.use_the_latest(["install"])
            ran.assert_not_called()
            self.assertIn(settings.VERSION, printed.getvalue(), "says which one it's using")

    def answers(self, payload):
        response = mock.MagicMock()
        response.__enter__.return_value = io.BytesIO(json.dumps(payload).encode())
        return mock.patch.object(t3remote.NO_REDIRECTS, "open", return_value=response)

    def test_reads_the_newest_release_from_github(self):
        with self.answers({"tag_name": "v1.2.3"}) as opened:
            self.assertEqual(updater.latest_release(), "1.2.3")
        self.assertEqual(opened.call_args[0][0], f"https://api.github.com/repos/{settings.UPDATE_REPO}/releases/latest")

    def test_a_strange_release_name_never_reaches_a_url(self):
        for tag in ("1.2.3", "v1.2", "v1.2.3-beta", "v1.2.3/../../evil", "v1.2.3\n", None, 7):
            with self.answers({"tag_name": tag}), self.assertRaises(ValueError, msg=str(tag)):
                updater.latest_release()

    def test_the_download_comes_from_that_exact_tag(self):
        response = mock.MagicMock()
        response.__enter__.return_value = io.BytesIO(b"the zip")
        with mock.patch.object(t3remote.NO_REDIRECTS, "open", return_value=response) as opened:
            self.assertEqual(updater.download_release("1.2.3"), b"the zip")
        self.assertEqual(opened.call_args[0][0], f"https://codeload.github.com/{settings.UPDATE_REPO}/zip/refs/tags/v1.2.3")

    def test_no_release_yet_just_carries_on(self):
        refused = urllib.error.HTTPError(settings.UPDATE_API, 404, "Not Found", {}, None)
        with mock.patch.object(t3remote.NO_REDIRECTS, "open", side_effect=refused), mock.patch.object(subprocess, "run") as ran, \
                mock.patch("sys.stdout", new_callable=io.StringIO) as printed:
            updater.use_the_latest(["install"])
        ran.assert_not_called()
        self.assertIn(settings.VERSION, printed.getvalue())

    def test_it_never_follows_a_redirect(self):
        self.assertTrue(any(isinstance(handler, t3remote._NoRedirects) for handler in t3remote.NO_REDIRECTS.handlers))

    def test_only_what_the_installer_needs_gets_unpacked(self):
        target = self.dir / "unpacked"
        target.mkdir()
        self.assertEqual(updater.unpack_latest(self.release("1.2.3"), target), "1.2.3")
        self.assertEqual((target / "install.cmd").read_text(), "new installer")
        self.assertTrue((target / "addon/PromptPeon/PromptPeon.toc").is_file())
        self.assertFalse((target / "docs").exists())

    def real_release(self):
        """What GitHub would serve for this checkout: everything in one top folder."""
        out = io.BytesIO()
        with zipfile.ZipFile(out, "w") as archive:
            for path in sorted(ROOT.rglob("*")):
                relative = path.relative_to(ROOT)
                if path.is_file() and relative.parts[0] in ("addon", "bridge", "docs", "install.cmd", "install.sh", "uninstall.cmd", "uninstall.sh", "start-stop.cmd", "start-stop.sh") \
                        and "__pycache__" not in relative.parts and "images" not in relative.parts:
                    archive.write(path, f"prompt-peon-{settings.VERSION}/{relative.as_posix()}")
        return out.getvalue()

    def test_a_real_release_unpacks_and_runs(self):
        target = self.dir / "unpacked"
        target.mkdir()
        self.assertEqual(updater.unpack_latest(self.real_release(), target), settings.VERSION)
        self.assertTrue((target / "bridge/promptpeon/settings.py").is_file())
        self.assertFalse((target / "docs").exists())
        done = subprocess.run([sys.executable, "-I", str(target / "bridge" / settings.ENTRY_POINT), "--help"], capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("install", done.stdout)

    def test_a_release_without_the_package_is_refused(self):
        out = io.BytesIO()
        with zipfile.ZipFile(out, "w") as archive:
            archive.writestr("prompt-peon-1.2.3/bridge/promptpeon_bridge.py", 'VERSION = "1.2.3"\n')
            archive.writestr("prompt-peon-1.2.3/addon/PromptPeon/PromptPeon.toc", "## Interface: 1\n")
        with self.assertRaises(ValueError):
            updater.unpack_latest(out.getvalue(), self.dir)

    def test_handing_over_starts_the_new_entry_point_isolated(self):
        with self.offering("9.9.9"), mock.patch.object(subprocess, "run", return_value=mock.Mock(returncode=0)) as ran, \
                mock.patch("sys.stdout", new_callable=io.StringIO), self.assertRaises(SystemExit):
            updater.use_the_latest(["install"])
        python, flag, script, *rest = ran.call_args[0][0]
        self.assertEqual((python, flag), (sys.executable, "-I"))
        self.assertEqual(Path(script).parts[-2:], ("bridge", "promptpeon_bridge.py"))
        self.assertEqual(rest, ["install", "--no-update"])

    def test_a_strange_download_is_refused(self):
        link = zipfile.ZipInfo("prompt-peon-9.9.9/bridge/link")
        link.external_attr = 0o120777 << 16
        for name, data in (("TOP/bridge/../../escaped.txt", "x"), ("TOP/addon/C:escaped.txt", "x"),
                           ("TOP/addon\\..\\escaped.txt", "x"), ("elsewhere/bridge/x.py", "x"), ("/absolute.txt", "x"),
                           (link, "/etc/passwd")):
            target = self.dir / "unpacked"
            target.mkdir(exist_ok=True)
            with self.assertRaises(ValueError, msg=str(name)):
                updater.unpack_latest(self.release(extra=[(name, data)]), target)
            self.assertFalse((self.dir / "escaped.txt").exists())
            shutil.rmtree(target)

    def test_a_download_without_the_program_is_refused(self):
        out = io.BytesIO()
        with zipfile.ZipFile(out, "w") as archive:
            archive.writestr("prompt-peon-1/install.cmd", "x")
        with self.assertRaises(ValueError):
            updater.unpack_latest(out.getvalue(), self.dir)

    def test_too_big_is_refused(self):
        with mock.patch.object(settings, "MAX_UPDATE_BYTES", 10), self.assertRaises(ValueError):
            updater.unpack_latest(self.release(), self.dir)

    def test_the_addon_and_the_program_agree_on_the_version(self):
        # A release is refused unless its tag matches this number.
        self.assertIn(f"## Version: {settings.VERSION}\n", (ROOT / "addon/PromptPeon/PromptPeon.toc").read_text().replace("\r", ""))

    def run_install(self, *arguments, keyboard=True, python=None):
        with mock.patch.object(updater, "use_the_latest") as checked, mock.patch.object(sys.stdin, "isatty", lambda: keyboard), \
                mock.patch.object(sys, "argv", ["bridge", "install", "--wow-dir", str(self.dir / "no-such-game"), *arguments]), \
                mock.patch.object(sys, "version_info", python or sys.version_info), \
                mock.patch("sys.stdout", new_callable=io.StringIO), self.assertRaises(SystemExit) as caught:
            cli.main()
        return checked, caught.exception

    def test_only_a_person_running_the_installer_triggers_it(self):
        self.assertEqual(self.run_install()[0].call_args[0][0][0], "install")
        self.run_install(keyboard=False)[0].assert_not_called()
        self.run_install("--no-update")[0].assert_not_called()

    def test_an_old_python_cant_install(self):
        checked, stopped = self.run_install(python=(3, 13, 9))
        checked.assert_not_called()
        self.assertIn("3.14", str(stopped))
        self.assertNotIn("3.14", self.run_install(python=(3, 15, 0))[1].code or "")

    def test_the_windows_installer_and_ci_use_that_python(self):
        script = (ROOT / "install.cmd").read_text()
        floor = ".".join(str(part) for part in settings.INSTALL_PYTHON)
        self.assertIn(f"sys.version_info < {settings.INSTALL_PYTHON}", script)
        self.assertIn(f"Python.Python.{floor} ", script)
        self.assertIn(f'python-version: "{floor}"', (ROOT / ".github/workflows/test.yml").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=1)
