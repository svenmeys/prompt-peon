"""Two T3s at once, such as this machine's and one somewhere else: one list, and every call goes to the right one."""
import contextlib
import io
import json
import sys
import unittest
import urllib.error
from unittest import mock

from bridge_helpers import Base, THREAD, command, thread
from promptpeon import bridgestate, delivery, pairing, prompts, refreshing, servers, settings, t3errors, t3remote, timeline, userconfig

HERE = "22222222-2222-4222-8222-222222222222"


class Server:
    """One T3, recording what reached it."""

    def __init__(self, url, threads, projects, providers=()):
        self.url, self.calls = url, []
        self._shell = {"threads": threads, "projects": projects}
        self._providers = list(providers)
        self.failing = None

    def shell(self):
        if self.failing:
            raise self.failing
        return self._shell

    def detail(self, thread_id):
        if self.failing:
            raise self.failing
        self.calls.append(("detail", thread_id))
        return timeline.describe_thread({"turnItems": [{"type": "assistant_message", "text": f"from {self.url}", "status": "completed", "ordinal": 1}]})

    def server_config(self):
        return {"providers": self._providers}

    def send_reply(self, thread, text, message_id=None):
        self.calls.append(("reply", thread["id"], text))
        return message_id or "m1"

    def stop_thread(self, thread_id):
        self.calls.append(("stop", thread_id))

    def start_thread(self, project_id, model, text, mode):
        self.calls.append(("new", project_id, text))
        return "t-new"

    def pr_checks(self, project_id, link):
        self.calls.append(("checks", project_id))
        return {}


def two_servers():
    away = Server("https://mac.t3coderelay.com", [thread()], [{"id": "p1", "title": "Shop"}],
                  providers=[{"instanceId": "claudeAgent", "models": []}])
    here = Server("http://127.0.0.1:3773", [thread(id=HERE, projectId="p2", title="Local work", updatedAt="2026-11-07T10:00:00.000Z")],
                  [{"id": "p2", "title": "Shop"}], providers=[{"instanceId": "claudeAgent", "models": []}, {"instanceId": "codex", "models": []}])
    return away, here, servers.ServerSet([("main", away), ("local", here)])


class OneList(unittest.TestCase):
    def test_both_servers_threads_in_one_list(self):
        away, here, both = two_servers()
        shell = both.shell()
        self.assertEqual({row["id"] for row in shell["threads"]}, {THREAD, HERE})
        self.assertEqual([project["title"] for project in shell["projects"]], ["Shop", "Shop (local)"],
                         "the same name on two machines must still read as two projects")
        self.assertEqual(both.trouble, "")

    def test_every_call_goes_to_the_server_with_the_thread(self):
        away, here, both = two_servers()
        both.shell()
        both.send_reply({"id": HERE}, "hello here")
        both.stop_thread(THREAD)
        both.start_thread("p2", {"model": "m"}, "a new one", "approval-required")
        both.pr_checks("p1", {})
        self.assertEqual(here.calls, [("reply", HERE, "hello here"), ("new", "p2", "a new one")])
        self.assertEqual(away.calls, [("stop", THREAD), ("checks", "p1")])

    def test_a_thread_no_server_listed_is_refused(self):
        _, _, both = two_servers()
        both.shell()
        with self.assertRaises(t3errors.SendRefused):
            both.stop_thread("not-anywhere")
        with self.assertRaises(t3errors.SendRefused):
            both.start_thread("no-project", {}, "x", "approval-required")

    def test_models_from_every_server(self):
        _, _, both = two_servers()
        self.assertEqual([provider["instanceId"] for provider in both.server_config()["providers"]], ["claudeAgent", "codex"])

    def test_pacing_goes_by_the_slowest(self):
        _, _, both = two_servers()
        self.assertEqual(refreshing.seconds_between(both.url), settings.RELAY_REFRESH_SECONDS)

    def test_one_server_down_keeps_the_other_and_its_last_list(self):
        away, here, both = two_servers()
        both.shell()
        here.failing = urllib.error.URLError("refused")
        shell = both.shell()
        self.assertEqual({row["id"] for row in shell["threads"]}, {THREAD, HERE}, "a server that stops answering keeps its last list")
        self.assertIn("the T3 called local", both.trouble)
        self.assertIn("http://127.0.0.1:3773", both.trouble)
        with self.assertRaises(servers.ServerDown):
            both.detail(HERE)
        self.assertEqual(here.calls, [], "no waiting on a server that already didn't answer")
        here.failing = None
        both.shell()
        self.assertEqual(both.trouble, "", "and the warning goes when it answers again")

    def test_an_expired_link_is_said_plainly(self):
        away, here, both = two_servers()
        away.failing = urllib.error.HTTPError("u", 401, "no", None, None)
        both.shell()
        self.assertIn("Your link to T3 has expired", both.trouble)

    def test_none_answering_is_the_same_as_one_not_answering(self):
        away, here, both = two_servers()
        away.failing = here.failing = urllib.error.URLError("down")
        with self.assertRaises(urllib.error.URLError):
            both.shell()


class WithTheBridge(Base):
    def make(self):
        away, here, both = two_servers()
        bridge = bridgestate.Bridge(self.wow, both, state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json")
        return bridge, away, here

    def test_the_game_gets_both_and_replies_reach_the_right_one(self):
        bridge, away, here = self.make()
        refreshing.refresh(bridge)
        rows = {row["id"]: row for row in bridge.snapshot["threads"]}
        self.assertEqual(rows[HERE]["p"], "Shop (local)")
        self.assertEqual(rows[THREAD]["p"], "Shop")
        self.assertEqual(bridge.snapshot["err"], "")
        delivery.deliver(bridge, [{"seq": 1, "thread": HERE, "text": "hi from the game"}])
        self.assertEqual(bridge.state["results"]["1"], "sent")
        self.assertIn(("reply", HERE, "hi from the game"), here.calls)
        self.assertFalse([call for call in away.calls if call[0] == "reply"])

    def test_a_new_thread_starts_on_the_server_its_project_is_on(self):
        bridge, away, here = self.make()
        refreshing.refresh(bridge)
        with mock.patch("promptpeon.threadstate.new_thread_selection", return_value={"instanceId": "claudeAgent", "model": "m"}):
            delivery.deliver(bridge, [command(1, "new-thread", "new\napproval-required\nShop (local)\nfix it here")])
        self.assertEqual(bridge.state["results"]["1"], "sent")
        self.assertIn(("new", "p2", "fix it here"), here.calls)

    def test_one_down_shows_a_warning_and_keeps_its_words(self):
        bridge, away, here = self.make()
        refreshing.refresh(bridge)
        before = bridge.messages[HERE]
        here.failing = urllib.error.URLError("refused")
        refreshing.refresh(bridge)
        self.assertIn("the T3 called local", bridge.snapshot["err"])
        self.assertEqual({row["id"] for row in bridge.snapshot["threads"]}, {THREAD, HERE})
        self.assertIs(bridge.messages[HERE], before)
        since = bridge.error_since
        refreshing.refresh(bridge)
        self.assertEqual(bridge.error_since, since, "how long it has been down keeps counting")


class FromConfig(Base):
    def setUp(self):
        super().setUp()
        patcher = mock.patch.object(settings, "CONFIG_DIR", self.dir)
        patcher.start()
        self.addCleanup(patcher.stop)
        (self.dir / "token").write_text("main-token")

    def test_one_server_stays_plain(self):
        remote = servers.from_config({"url": "https://mac.example"})
        self.assertIsInstance(remote, t3remote.T3Remote)

    def test_an_extra_server_makes_a_set(self):
        (self.dir / "token-local").write_text("local-token")
        remote = servers.from_config({"url": "https://mac.example", "also": [{"name": "local", "url": settings.DEFAULT_URL}]})
        self.assertEqual([name for name, _ in remote.servers], ["main", "local"])
        self.assertEqual(remote.servers[1][1].token, "local-token")

    def test_a_name_cant_reach_outside_the_config_folder(self):
        with self.assertRaises(ValueError):
            servers.from_config({"url": "https://mac.example", "also": [{"name": "../token", "url": settings.DEFAULT_URL}]})


class InstallerOffer(Base):
    """With your main T3 elsewhere and T3 running here too, the installer offers to show both."""

    def setUp(self):
        super().setUp()
        self.answers, self.issued = [], []
        (self.dir / "config.json").write_text(json.dumps({"url": "https://mac.example", "pictures": False}))
        for patcher in (mock.patch.object(settings, "CONFIG_DIR", self.dir), mock.patch.object(sys.stdin, "isatty", return_value=True),
                        mock.patch.object(prompts, "ask", side_effect=lambda _prompt: self.answers.pop(0) if self.answers else ""),
                        mock.patch.object(pairing, "t3_program", return_value="/usr/bin/t3"),
                        mock.patch.object(pairing, "t3_answers", return_value=True),
                        mock.patch.object(pairing, "issue_local_token", side_effect=lambda scopes: self.issued.append(scopes) or "local-token"),
                        mock.patch.object(t3remote, "T3Remote", side_effect=lambda url, token: two_servers()[1])):
            patcher.start()
            self.addCleanup(patcher.stop)

    def offer(self, url="https://mac.example", wanted=None):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            pairing.offer_this_machine(url, wanted)
        return out.getvalue(), json.loads((self.dir / "config.json").read_text())

    def test_yes_adds_this_machine(self):
        self.answers = ["y"]
        said, config = self.offer()
        self.assertEqual(config["also"], [{"name": "local", "url": settings.DEFAULT_URL}])
        self.assertEqual((self.dir / "token-local").read_text(), "local-token")
        self.assertEqual(self.issued, [settings.BASE_SCOPES], "pictures stay off when you said no to them")
        self.assertIn("Also showing this machine's threads", said)

    def test_no_by_default(self):
        self.answers = [""]
        _, config = self.offer()
        self.assertNotIn("also", config)
        self.assertFalse((self.dir / "token-local").exists())

    def test_asked_once(self):
        self.answers = ["y"]
        self.offer()
        self.answers = ["n"]
        said, config = self.offer()
        self.assertEqual(config["also"], [{"name": "local", "url": settings.DEFAULT_URL}])
        self.assertEqual(self.answers, ["n"], "a second run doesn't ask again")

    def test_the_flag_takes_it_away(self):
        self.answers = ["y"]
        self.offer()
        said, config = self.offer(wanted=False)
        self.assertEqual(config["also"], [])
        self.assertFalse((self.dir / "token-local").exists())

    def test_this_machine_as_the_main_one_isnt_also_an_extra(self):
        self.answers = ["y"]
        self.offer()
        _, config = self.offer(url=settings.DEFAULT_URL)
        self.assertEqual(config["also"], [])

    def test_no_t3_here_asks_nothing(self):
        with mock.patch.object(pairing, "t3_answers", return_value=False):
            self.answers = ["y"]
            _, config = self.offer()
        self.assertNotIn("also", config)
        self.assertEqual(self.answers, ["y"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
