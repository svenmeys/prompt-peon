"""Reading older messages, and the model list."""
import time
import unittest
from unittest import mock

from bridge_helpers import Base, FakeRemote, THREAD, command, thread
from promptpeon import bridgestate, catalog, delivery, refreshing, settings, snapshots, t3errors, t3remote, timeline


class OlderMessages(Base):
    @staticmethod
    def message(ordinal, words="words"):
        return {"type": "assistant_message", "text": f"{words} {ordinal}", "ordinal": ordinal, "status": "completed"}

    def remote_with_pages(self, bounded_items, pages, more=True):
        remote = t3remote.T3Remote("http://t3", "token")
        asked = []

        def answer(path, **_):
            asked.append(path)
            if path.endswith("/bounded"):
                return {"projection": {"turnItems": bounded_items}, "hasMoreHistory": more, "historyCursor": "c0" if more else None}
            cursor = path.split("cursor=")[1]
            items, following = pages[cursor]
            return {"items": [{"item": item} for item in items], "nextCursor": following, "hasMoreHistory": following is not None}

        remote._request = answer
        return remote, asked

    def test_older_rows_come_from_the_next_page(self):
        remote, asked = self.remote_with_pages([self.message(100)], {"c0": ([self.message(50), self.message(60)], "c1")})
        rows, more = remote.older_rows(THREAD, 100)
        self.assertEqual([row[3] for row in rows], [50, 60])
        self.assertTrue(more)
        self.assertEqual(len(asked), 2)

    def test_the_end_of_history_says_so(self):
        remote, _ = self.remote_with_pages([self.message(100)], {"c0": ([self.message(50)], None)})
        rows, more = remote.older_rows(THREAD, 100)
        self.assertEqual([row[3] for row in rows], [50])
        self.assertFalse(more)

    def test_it_walks_past_pages_it_already_showed(self):
        pages = {"c0": ([self.message(50)], "c1"), "c1": ([self.message(20)], None)}
        remote, _ = self.remote_with_pages([self.message(100)], pages)
        rows, more = remote.older_rows(THREAD, 50)
        self.assertEqual([row[3] for row in rows], [20])
        self.assertFalse(more)

    def test_rows_the_timeline_cut_come_first(self):
        items = [self.message(n) for n in range(1, settings.MESSAGES_PER_THREAD + 11)]
        remote, asked = self.remote_with_pages(items, {}, more=False)
        detail = timeline.describe_thread({"turnItems": items})
        first = detail["rows"][0][3]
        rows, more = remote.older_rows(THREAD, first)
        self.assertEqual([row[3] for row in rows], list(range(1, first)))
        self.assertFalse(more)
        self.assertEqual(len(asked), 1, "no history call was needed")

    def test_nothing_older_is_a_clean_answer(self):
        remote, _ = self.remote_with_pages([self.message(100)], {}, more=False)
        self.assertEqual(remote.older_rows(THREAD, 100), ([], False))

    def test_a_huge_page_keeps_the_newest_and_says_there_is_more(self):
        ceiling = mock.patch.object(settings, "MAX_MESSAGE_CHARS", 10 ** 9)
        ceiling.start()
        self.addCleanup(ceiling.stop)
        big = "x" * 600_000
        items = [self.message(n, big) for n in (10, 20, 30)]
        remote, _ = self.remote_with_pages(items, {}, more=False)
        rows, more = remote.older_rows(THREAD, 100)
        self.assertEqual([row[3] for row in rows], [30])
        self.assertTrue(more)

    def test_a_single_huge_message_still_comes_through(self):
        items = [self.message(10, "x" * 2_000_000)]
        remote, _ = self.remote_with_pages(items, {}, more=False)
        rows, more = remote.older_rows(THREAD, 100)
        self.assertEqual(len(rows), 1)
        self.assertFalse(more)

    def test_old_pictures_become_a_line(self):
        rows, more = timeline.fit_older_rows([["i", "shot.png", "d", 5, {"p": "/a/shot.png"}]], [], False)
        self.assertEqual(rows, [["n", "Picture: shot.png", "d", 5]])

    def test_snapshot_says_when_there_is_more(self):
        shell = {"threads": [thread()], "projects": []}
        snapshot = snapshots.build_snapshot(shell, {THREAD: {"rows": [], "more": True}}, url="u", error="", error_since=0, ack=0, results={})
        self.assertTrue(snapshot["threads"][0]["hm"])
        snapshot = snapshots.build_snapshot(shell, {THREAD: {"rows": [], "more": False}}, url="u", error="", error_since=0, ack=0, results={})
        self.assertNotIn("hm", snapshot["threads"][0])


CONFIG = {"providers": [
    {"instanceId": "claudeAgent", "displayName": "Claude", "enabled": True, "status": "ready", "models": [
        {"slug": "claude-opus-5-5", "name": "Opus 5.5", "capabilities": {"optionDescriptors": [
            {"id": "effort", "type": "select", "options": [{"id": "low", "label": "Low"}, {"id": "high", "label": "High", "isDefault": True}]},
            {"id": "fastMode", "type": "toggle"}]}},
        {"slug": "no-levels", "name": "No Levels", "capabilities": {"optionDescriptors": []}}]},
    {"instanceId": "cursor", "displayName": "Cursor", "enabled": False, "status": "disabled", "models": [{"slug": "x"}]},
    {"instanceId": "broken", "displayName": "Broken", "enabled": True, "status": "error", "models": [{"slug": "y"}]},
]}


class Models(Base):
    class Remote(FakeRemote):
        def __init__(self, shell):
            super().__init__(shell=shell)
            self.set_calls, self.started = [], []

        def server_config(self):
            return CONFIG

        def set_model(self, thread_id, selection):
            self.set_calls.append((thread_id, selection))

        def start_thread(self, project_id, model, text, runtime_mode):
            self.started.append((project_id, model, text))
            self.modes = getattr(self, "modes", []) + [runtime_mode]
            return "t2"

    def make(self, selection=None):
        shell = {"threads": [thread(modelSelection=selection or {"instanceId": "claudeAgent", "model": "claude-opus-5-5"})],
                 "projects": [{"id": "p1", "title": "Shop"}]}
        remote = self.Remote(shell)
        return bridgestate.Bridge(self.wow, remote, state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json"), remote

    def test_the_list_only_has_what_is_ready(self):
        models = catalog.model_catalog(CONFIG)
        self.assertEqual([provider["i"] for provider in models], ["claudeAgent"])
        self.assertEqual(models[0]["m"][0], ["claude-opus-5-5", "Opus 5.5", "effort", ["low", "high"], ["Low", "High"], "high"])
        self.assertEqual(models[0]["m"][1][3], [], "a model with no levels just has none")

    def test_the_list_says_which_modes_a_provider_has(self):
        provider = {"instanceId": "pi", "displayName": "Pi", "enabled": True, "status": "ready", "models": [{"slug": "x"}],
                    "supportedRuntimeModes": ["full-access", "approval-required", "some-new-mode"]}
        self.assertEqual(catalog.model_catalog({"providers": [provider]})[0]["rm"], ["approval-required", "full-access"],
                         "in T3's order, and only what we know")
        self.assertNotIn("rm", catalog.model_catalog(CONFIG)[0], "T3 says no list means every mode")

    def test_the_game_gets_the_list_and_each_threads_choice(self):
        bridge, _ = self.make({"instanceId": "claudeAgent", "model": "claude-opus-5-5", "options": [{"id": "effort", "value": "high"}, {"id": "fastMode", "value": False}]})
        refreshing.refresh(bridge)
        row = bridge.snapshot["threads"][0]
        self.assertEqual((row["mi"], row["mo"], row["ef"]), ("claudeAgent", "claude-opus-5-5", "high"))
        self.assertEqual(bridge.snapshot["md"][0]["i"], "claudeAgent")
        self.assertIn("claude-opus-5-5", bridge.snapshot_path.read_text())

    def test_it_only_asks_for_the_list_now_and_then(self):
        bridge, remote = self.make()
        calls = []
        remote.server_config = lambda: calls.append(1) or CONFIG
        refreshing.refresh(bridge)
        refreshing.refresh(bridge)
        self.assertEqual(len(calls), 1)

    def test_t3_refusing_the_list_is_no_outage(self):
        bridge, remote = self.make()

        def refuse():
            raise t3errors.SendRefused("no")

        remote.server_config = refuse
        refreshing.refresh(bridge)
        self.assertEqual(bridge.error, "")
        self.assertNotIn("md", bridge.snapshot)

    def test_setting_a_model_keeps_other_options_and_replaces_effort(self):
        bridge, remote = self.make({"instanceId": "claudeAgent", "model": "claude-opus-5-5", "options": [{"id": "effort", "value": "low"}, {"id": "fastMode", "value": True}]})
        refreshing.refresh(bridge)
        delivery.deliver(bridge, [command(1, THREAD, "setmodel\nclaudeAgent\nclaude-opus-5-5\nhigh")])
        self.assertEqual(bridge.state["results"]["1"], "sent")
        self.assertEqual(remote.set_calls[0], (THREAD, {"instanceId": "claudeAgent", "model": "claude-opus-5-5", "options": [{"id": "fastMode", "value": True}, {"id": "effort", "value": "high"}]}))

    def test_a_model_from_another_provider_drops_the_old_options(self):
        bridge, remote = self.make({"instanceId": "other", "model": "m", "options": [{"id": "fastMode", "value": True}]})
        refreshing.refresh(bridge)
        delivery.deliver(bridge, [command(1, THREAD, "setmodel\nclaudeAgent\nno-levels")])
        self.assertEqual(remote.set_calls[0][1], {"instanceId": "claudeAgent", "model": "no-levels"})

    def test_only_what_t3_offers_can_be_set(self):
        bridge, remote = self.make()
        refreshing.refresh(bridge)
        delivery.deliver(bridge, [command(1, THREAD, "setmodel\nclaudeAgent\nmade-up"), command(2, THREAD, "setmodel\ncursor\nx"),
                        command(3, THREAD, "setmodel\nclaudeAgent\nclaude-opus-5-5\nultra")])
        self.assertIn("doesn't offer", bridge.state["results"]["1"])
        self.assertIn("doesn't offer", bridge.state["results"]["2"])
        self.assertIn("effort level", bridge.state["results"]["3"])
        self.assertEqual(remote.set_calls, [])

    def test_a_new_thread_uses_the_model_you_picked(self):
        bridge, remote = self.make()
        refreshing.refresh(bridge)
        delivery.deliver(bridge, [command(1, "new-thread", "newm\napproval-required\nShop\nclaudeAgent\nclaude-opus-5-5\nhigh\nfix login\nand tests")])
        self.assertEqual(bridge.state["results"]["1"], "sent")
        self.assertEqual(remote.started, [("p1", {"instanceId": "claudeAgent", "model": "claude-opus-5-5", "options": [{"id": "effort", "value": "high"}]}, "fix login\nand tests")])

    def test_a_new_thread_with_a_bad_model_starts_nothing(self):
        bridge, remote = self.make()
        refreshing.refresh(bridge)
        delivery.deliver(bridge, [command(1, "new-thread", "newm\napproval-required\nShop\nclaudeAgent\nmade-up\n\nfix login")])
        self.assertIn("doesn't offer", bridge.state["results"]["1"])
        self.assertEqual(remote.started, [])

    def test_these_count_toward_the_limit_and_the_addon_gate(self):
        bridge, remote = self.make()
        refreshing.refresh(bridge)
        delivery.deliver(bridge, [command(n, THREAD, "setmodel\nclaudeAgent\nno-levels") for n in range(1, 13)])
        self.assertEqual(len(remote.set_calls), settings.MAX_SENDS_PER_MINUTE)
        (self.wow / "Interface/AddOns/SomeoneElse").mkdir(parents=True)
        bridge.send_times = []
        delivery.deliver(bridge, [command(13, THREAD, "setmodel\nclaudeAgent\nno-levels")])
        self.assertIn("SomeoneElse", bridge.state["results"]["13"])

    def test_steering_targets_the_run_thats_going(self):
        calls = []
        bridge, remote = self.make()
        remote.steer_queued = lambda *args: calls.append(args)
        bridge.shell = {"threads": [thread(activeRunId="run-now")], "projects": []}
        delivery.deliver(bridge, [command(1, THREAD, "steer\nrun-queued")])
        self.assertEqual(bridge.state["results"]["1"], "sent")
        self.assertEqual(calls, [(THREAD, "run-queued", "run-now")])

    def test_a_queued_message_that_already_started_is_said_plainly(self):
        for words in ("cancelq\nrun:thread:abc:ordinal:97", "editq\nrun:thread:abc:ordinal:97\nnew words", "steer\nrun:thread:abc:ordinal:97"):
            bridge, remote = self.make()
            def refuse(*_args):
                raise t3errors.SendRefused("Queued run run:thread:abc:ordinal:97 is not queued.")
            remote.cancel_queued = remote.edit_queued = remote.steer_queued = refuse
            bridge.shell = {"threads": [thread(activeRunId="run-now")], "projects": []}
            delivery.deliver(bridge, [command(1, THREAD, words)])
            result = bridge.state["results"]["1"]
            self.assertIn("already started", result)
            self.assertNotIn("run:thread", result, "people don't need T3's run ids")

    def test_other_refusals_keep_their_words(self):
        bridge, remote = self.make()
        def refuse(*_args):
            raise t3errors.SendRefused("T3 said no for its own reasons")
        remote.stop_thread = refuse
        delivery.deliver(bridge, [command(1, THREAD, "stop")])
        self.assertEqual(bridge.state["results"]["1"], "failed: T3 said no for its own reasons")

    def test_snooze_and_wake(self):
        calls = []
        bridge, remote = self.make()
        remote.snooze_thread = lambda *args: calls.append(("snooze",) + args)
        remote.unsnooze_thread = lambda *args: calls.append(("unsnooze",) + args)
        wake = int(time.time()) + 3600
        delivery.deliver(bridge, [command(1, THREAD, f"snooze\n{wake}"), command(2, THREAD, "unsnooze")])
        self.assertEqual(bridge.state["results"]["1"], "sent")
        self.assertEqual(calls[0], ("snooze", THREAD, time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(wake))))
        self.assertEqual(calls[1], ("unsnooze", THREAD))

    def test_snooze_needs_a_real_time_ahead(self):
        calls = []
        bridge, remote = self.make()
        remote.snooze_thread = lambda *args: calls.append(args)
        far = int(time.time()) + settings.MAX_SNOOZE_SECONDS + 100
        delivery.deliver(bridge, [command(1, THREAD, "snooze\nsoon"), command(2, THREAD, "snooze\n1000"), command(3, THREAD, f"snooze\n{far}")])
        for seq in "123":
            self.assertIn("in the future", bridge.state["results"][seq])
        self.assertEqual(calls, [])

    def test_t3_refusing_a_snooze_is_said_plainly(self):
        cases = (("Thread abc has a pending approval or user-input request and cannot be snoozed.", "waiting on you"),
                 ("Thread abc has a queued run and cannot be snoozed.", "queued message"))
        for seq, (words, expected) in enumerate(cases, start=1):
            bridge, remote = self.make()
            def refuse(*_args, says=words):
                raise t3errors.SendRefused(says)
            remote.snooze_thread = refuse
            delivery.deliver(bridge, [command(seq, THREAD, f"snooze\n{int(time.time()) + 3600}")])
            self.assertIn(expected, bridge.state["results"][str(seq)])
            self.assertNotIn("abc", bridge.state["results"][str(seq)])

    def test_nothing_going_means_nothing_to_steer(self):
        bridge, remote = self.make()
        bridge.shell = {"threads": [thread(activeRunId=None)], "projects": []}
        delivery.deliver(bridge, [command(1, THREAD, "steer\nrun-queued")])
        self.assertIn("nothing to steer", bridge.state["results"]["1"])

    def test_a_hidden_thread_doesnt_say_its_model(self):
        bridge, _ = self.make()
        bridge.state["hidden"] = {"projects": [], "threads": [THREAD]}
        refreshing.refresh(bridge)
        row = bridge.snapshot["threads"][0]
        self.assertNotIn("mi", row)
        self.assertNotIn("ef", row)


if __name__ == "__main__":
    unittest.main(verbosity=1)
