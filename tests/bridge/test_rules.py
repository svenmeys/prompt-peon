"""Rules that must agree between places, and things that must never change quietly."""
import http.server
import os
import re
import subprocess
import sys
import threading
import unittest
from unittest import mock

from bridge_helpers import Base, CommandRemote, ROOT, THREAD, thread
from promptpeon import addonfiles, commands, gametext, snapshots


class RulesThatMustAgree(Base):
    LONG = "Personal assistant notes for the week of the public release extra"  # Character 60 is a space.

    def snapshot(self, shell, **extra):
        return snapshots.build_snapshot(shell, {THREAD: {"rows": [["a", "secret words"]]}}, url="u", error="", error_since=0,
                                ack=0, results={}, **extra)

    def test_a_long_project_name_that_breaks_on_a_space_still_hides(self):
        shell = {"threads": [thread()], "projects": [{"id": "p1", "title": self.LONG}]}
        shown = self.snapshot(shell)["threads"][0]["p"]
        snapshot = self.snapshot(shell, hidden={"projects": [shown], "threads": []})
        self.assertNotIn("m", snapshot["threads"][0])
        self.assertTrue(snapshot["threads"][0]["hd"])
        self.assertEqual(snapshot["pj"], [])

    def two_threads(self, **project):
        selection = {"modelSelection": {"instanceId": "old-i", "model": "old-model", "options": [{"id": "effort", "value": "low"}]}}
        newer = {"modelSelection": {"instanceId": "new-i", "model": "new-model", "options": [{"id": "effort", "value": "high"}]}}
        return {"projects": [dict({"id": "p1", "title": "Shop"}, **project)], "threads": [
            thread(id="old", updatedAt="2026-11-03T01:00:00.000Z", pendingRuntimeRequest={"kind": "user_input"}, **selection),
            thread(id="new", updatedAt="2026-11-03T05:00:00.000Z", **newer)]}

    def assert_one_rule(self, shell, instance, model, effort):
        self.assertEqual(self.snapshot(shell)["pm"], [["Shop", instance, model, effort]])
        remote = CommandRemote(shell)
        bridge = self.bridge(remote)
        bridge.shell = shell
        self.assertEqual(commands.start_thread(bridge, "Shop\nfix it", "approval-required"), "sent")
        self.assertEqual(remote.calls[-1][2], model)

    def test_the_page_and_the_slash_command_pick_the_same_model(self):
        self.assert_one_rule(self.two_threads(), "new-i", "new-model", "high")

    def test_the_projects_default_wins_for_both(self):
        default = {"instanceId": "def-i", "model": "def-model"}
        self.assert_one_rule(self.two_threads(defaultModelSelection=default), "def-i", "def-model", "")

    def test_a_hidden_project_offers_no_model(self):
        self.assertEqual(self.snapshot(self.two_threads(), hidden={"projects": ["Shop"], "threads": []})["pm"], [])

    def test_a_new_thread_finds_a_project_by_the_shortened_name_the_game_shows(self):
        shell = {"projects": [{"id": "p1", "title": self.LONG}], "threads": [thread(modelSelection={"instanceId": "i", "model": "m"})]}
        remote = CommandRemote(shell)
        bridge = self.bridge(remote)
        bridge.shell = shell
        self.assertEqual(commands.start_thread(bridge, f"{gametext.readable(self.LONG, 60)}\nfix it", "approval-required"), "sent")


class NothingButT3GetsTheToken(unittest.TestCase):
    def test_a_configured_proxy_receives_nothing(self):
        seen = []

        class Listener(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append((self.server.name, self.headers.get("Authorization")))
                self.send_response(200)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"ok")

            def log_message(self, *_):
                pass

        servers = []
        for name in ("t3", "proxy"):
            server = http.server.HTTPServer(("127.0.0.1", 0), Listener)
            server.name = name
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.addCleanup(server.shutdown)
            servers.append(server)
        t3_url = f"http://127.0.0.1:{servers[0].server_port}"
        proxy_url = f"http://127.0.0.1:{servers[1].server_port}"
        # A child process, because Python reads proxy settings once, when the opener is made.
        script = ("import sys, urllib.request; sys.path.insert(0, sys.argv[1]); from promptpeon import pairing, t3remote\n"
                  "t3remote.NO_REDIRECTS.open(urllib.request.Request(sys.argv[2], headers={'Authorization': 'Bearer FAKE'}), timeout=10).read()\n"
                  "pairing.t3_answers(sys.argv[2])\n")
        env = {key: value for key, value in os.environ.items() if key.lower() not in ("no_proxy", "http_proxy", "https_proxy", "all_proxy")}
        env.update(HTTP_PROXY=proxy_url, http_proxy=proxy_url, ALL_PROXY=proxy_url, all_proxy=proxy_url)
        done = subprocess.run([sys.executable, "-c", script, str(ROOT / "bridge"), t3_url], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertNotIn("proxy", [name for name, _ in seen], seen)
        self.assertIn(("t3", "Bearer FAKE"), seen)


class PlainInstallErrors(Base):
    def test_a_drive_that_cant_hard_link_gets_a_plain_message(self):
        with mock.patch.object(addonfiles, "link_to_snapshot", side_effect=OSError(22, "Incorrect function")):
            with self.assertRaises(SystemExit) as caught:
                addonfiles.place_addon(self.wow, ROOT / "addon/PromptPeon")
        self.assertIn("Could not set up the addon files", str(caught.exception))

    def test_a_locked_file_still_says_to_close_the_game(self):
        with mock.patch.object(addonfiles, "link_to_snapshot", side_effect=PermissionError()):
            with self.assertRaises(SystemExit) as caught:
                addonfiles.place_addon(self.wow, ROOT / "addon/PromptPeon")
        self.assertIn("Close WoW", str(caught.exception))


class CiStaysLockedDown(unittest.TestCase):
    """A workflow that runs other people's code is the easiest way into this project. These stay true."""

    workflow = (ROOT / ".github/workflows/test.yml").read_text()
    code = "\n".join(line.split("#")[0] for line in workflow.splitlines())

    def test_code_from_a_pull_request_never_runs(self):
        self.assertNotIn("pull_request", self.code)
        self.assertNotIn("issue_comment", self.code)
        self.assertNotIn("workflow_run", self.code)

    def test_it_only_runs_for_main(self):
        self.assertIn("branches: [main]", self.code)
        jobs = self.code.count("runs-on:")
        self.assertEqual(self.code.count("github.ref == 'refs/heads/main'"), jobs)

    def test_it_only_runs_on_githubs_own_machines(self):
        self.assertNotIn("self-hosted", self.code)
        self.assertEqual(sorted(set(re.findall(r"runs-on: (\S+)", self.code))), ["ubuntu-latest", "windows-latest"])

    def test_it_can_only_read_and_holds_no_secrets(self):
        self.assertIn("permissions:\n  contents: read", self.code)
        self.assertEqual(self.code.count("permissions:"), 1, "no job gets more than the rest")
        self.assertNotIn("secrets.", self.code)
        self.assertEqual(self.code.count("persist-credentials: false"), self.code.count("actions/checkout@"))

    def test_every_action_is_pinned_to_a_commit_and_is_githubs_own(self):
        uses = re.findall(r"uses: (\S+)", self.code)
        self.assertTrue(uses)
        for action in uses:
            self.assertRegex(action, r"^actions/[a-z-]+@[0-9a-f]{40}$")

    def test_there_are_only_these_workflows(self):
        self.assertEqual(sorted(path.name for path in (ROOT / ".github/workflows").iterdir()), ["release.yml", "test.yml"])


class ReleasesStayLockedDown(unittest.TestCase):
    """The one workflow that can write. It starts only from a tag and runs none of the project's code."""

    workflow = (ROOT / ".github/workflows/release.yml").read_text()
    code = "\n".join(line.split("#")[0] for line in workflow.splitlines())

    def test_only_a_version_tag_starts_it(self):
        self.assertIn('on:\n  push:\n    tags: ["v[0-9]+.[0-9]+.[0-9]+"]\n\npermissions:', self.code)
        for trigger in ("pull_request", "issue_comment", "workflow_run", "workflow_dispatch", "schedule", "branches:"):
            self.assertNotIn(trigger, self.code)

    def test_it_runs_none_of_the_projects_code(self):
        for runner in ("python", "luajit", "tests/", "install", " sh ", "bash ", "./"):
            self.assertNotIn(runner, self.code)

    def test_no_text_from_git_is_pasted_into_a_script(self):
        self.assertEqual(sorted(set(re.findall(r"\$\{\{(.*?)\}\}", self.code))), [" github.repository ", " github.token "])
        self.assertNotIn("secrets.", self.code)
        self.assertEqual(self.code.count("persist-credentials: false"), 1)

    def test_it_can_write_only_what_it_needs(self):
        self.assertIn("permissions:\n  actions: read\n  contents: write\n\njobs:", self.code)
        self.assertEqual(self.code.count("permissions:"), 1)

    def test_it_only_runs_on_githubs_machines_with_pinned_actions(self):
        self.assertEqual(re.findall(r"runs-on: (\S+)", self.code), ["ubuntu-latest"])
        for action in re.findall(r"uses: (\S+)", self.code):
            self.assertRegex(action, r"^actions/[a-z-]+@[0-9a-f]{40}$")

    def test_it_refuses_before_it_publishes(self):
        checks = self.code.index("is-ancestor"), self.code.index("--workflow test.yml"), self.code.index('grep -qx "VERSION')
        self.assertLess(max(checks), self.code.index("gh release create"))
        self.assertIn("--verify-tag", self.code)


class Wrappers(unittest.TestCase):
    def test_every_python_the_wrappers_try_runs_isolated(self):
        # A check that loads PYTHONPATH or sitecustomize has already run someone's code, whatever comes after it.
        for name in ("install.cmd", "uninstall.cmd"):
            lines = [line for line in (ROOT / name).read_text().splitlines() if " -c " in line]
            self.assertTrue(lines, name)
            for line in lines:
                self.assertIn(" -I -c ", line, line)


if __name__ == "__main__":
    unittest.main(verbosity=1)
