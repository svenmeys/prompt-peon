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


class InstallerFetchesLatest(Base):
    """Running the installer by hand gets the newest release from GitHub, and nothing else ever does."""

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
