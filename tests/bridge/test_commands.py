"""What each command from the game does."""
import json
import shutil
import unittest
from unittest import mock

from bridge_helpers import Base, CommandRemote, Crash, FakeRemote, ROOT, THREAD, command, thread
from promptpeon import addonfiles, bridgestate, catalog, delivery, gates, pngtga, publishing, refreshing, settings, snapshots, t3remote, timeline


class ParkedViews(Base):
    """Opening a settled thread asks for its words, since they don't ride along in every refresh."""

    def make(self):
        remote = FakeRemote(shell={"threads": [thread(settledAt="2026-11-02T10:00:00.000Z")], "projects": [{"id": "p1", "title": "Shop"}]})
        return bridgestate.Bridge(self.wow, remote, state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json"), remote

    def test_opening_a_settled_thread_loads_its_words_without_pictures(self):
        bridge, remote = self.make()
        remote.detail = lambda _id: {"rows": [["a", "words", "d", 1], ["i", "one.png", "d", 2, {"p": "/secret/one.png"}]]}
        delivery.deliver(bridge, [command(1, THREAD, "view")])
        self.assertEqual(bridge.state["results"]["1"], "sent")
        publishing.publish(bridge)
        row = bridge.snapshot["pk"][0]
        self.assertEqual(row["vm"], [["a", "words", "d", 1]])
        self.assertNotIn("/secret", json.dumps(bridge.snapshot))

    def test_a_hidden_thread_cant_be_viewed(self):
        asked = []
        bridge, remote = self.make()
        remote.detail = lambda thread_id: asked.append(thread_id) or {"rows": []}
        bridge.state["hidden"] = {"projects": [], "threads": [THREAD]}
        delivery.deliver(bridge, [command(1, THREAD, "view")])
        self.assertIn("hidden", bridge.state["results"]["1"])
        self.assertEqual(asked, [], "a hidden thread's words must not be fetched")


class Commands(Base):
    def make(self, remote=None):
        remote = remote or CommandRemote()
        return bridgestate.Bridge(self.wow, remote, state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json"), remote

    def test_stop_and_settle(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, THREAD, "stop\n"), command(2, THREAD, "settle")])
        self.assertEqual(remote.calls, [("stop", THREAD), ("settle", THREAD)])
        self.assertEqual(bridge.state["results"]["2"], "sent")
        self.assertEqual(remote.sent, [], "a command is never sent to the agent as a message")

    def test_commands_only_run_once(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, THREAD, "stop")])
        delivery.deliver(bridge, [command(1, THREAD, "stop")])
        self.assertEqual(len(remote.calls), 1)

    def test_a_typed_message_can_not_be_a_command(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [{"seq": 1, "thread": THREAD, "text": "stop"}])
        self.assertEqual(remote.sent, [(THREAD, "stop")])
        self.assertEqual(remote.calls, [])

    def test_the_connection_check_is_answered_and_touches_nothing(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, "settings", "ping")])
        self.assertEqual(bridge.state["results"]["1"], "sent")
        self.assertEqual(remote.calls, [])
        self.assertEqual(remote.sent, [])

    def test_the_connection_check_says_so_when_an_addon_you_have_not_trusted_is_in_the_way(self):
        bridge, remote = self.make()
        (self.wow / "Interface/AddOns/SomeoneElse").mkdir()
        delivery.deliver(bridge, [command(1, "settings", "ping")])
        self.assertIn("SomeoneElse", bridge.state["results"]["1"])
        self.assertTrue(bridge.state["results"]["1"].startswith("failed"))

    def test_unknown_thread_and_verb_are_refused(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, "aaaaaaaa-1111", "stop"), command(2, THREAD, "format-the-disk")])
        self.assertIn("not on this T3 server", bridge.state["results"]["1"])
        self.assertIn("doesn't know", bridge.state["results"]["2"])
        self.assertEqual(remote.calls, [])

    def test_new_thread(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, "new-thread", "new\napproval-required\nShop\nfix the login page")])
        self.assertEqual(remote.calls, [("new", "p1", "m", "fix the login page")])
        self.assertEqual(bridge.state["results"]["1"], "sent")

    def test_new_thread_matches_any_case_and_needs_a_real_project(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, "new-thread", "new\napproval-required\nshop\nwork"), command(2, "new-thread", "new\napproval-required\nNope\nwork")])
        self.assertEqual(len(remote.calls), 1)
        self.assertIn("no project called Nope", bridge.state["results"]["2"])

    def say_full_access(self, answer):
        (self.dir / "config.json").write_text(json.dumps({"full_access": answer}))

    def fresh(self):
        """Remembers nothing, or a number from the last round would be skipped and the round would pass by doing nothing."""
        shutil.rmtree(self.dir / "state", ignore_errors=True)
        return self.make()

    def test_every_mode_t3_has_can_start_a_thread_once_you_said_yes(self):
        self.say_full_access(True)
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(seq, "new-thread", f"new\n{mode}\nShop\nwork") for seq, mode in enumerate(settings.RUNTIME_MODES, 1)])
        self.assertEqual(remote.modes, ["approval-required", "auto-accept-edits", "auto", "full-access"])
        self.assertEqual({bridge.state["results"][str(seq)] for seq in range(1, 5)}, {"sent"})

    def test_a_chosen_model_carries_the_mode_too(self):
        self.say_full_access(True)
        bridge, remote = self.make()
        chosen = lambda _bridge, instance, model, effort: {"instanceId": instance, "model": model}
        with mock.patch.object(catalog, "model_selection", chosen):
            delivery.deliver(bridge, [command(1, "new-thread", "newm\nfull-access\nShop\ncodex\ngpt-6-astra\nhigh\nfix login\nand tests")])
        self.assertEqual(remote.calls, [("new", "p1", "gpt-6-astra", "fix login\nand tests")])
        self.assertEqual(remote.modes, ["full-access"])

    def test_modes_that_ask_first_need_no_yes(self):
        for answer in (False, None):
            self.say_full_access(answer)
            bridge, remote = self.fresh()
            delivery.deliver(bridge, [command(1, "new-thread", "new\napproval-required\nShop\nwork"),
                            command(2, "new-thread", "new\nauto-accept-edits\nShop\nwork")])
            self.assertEqual(remote.modes, ["approval-required", "auto-accept-edits"])

    def test_a_mode_you_cant_send_to_is_a_mode_you_cant_start(self):
        for answer in (False, None, "yes", 1):
            self.say_full_access(answer)
            for mode in ("auto", "full-access"):
                bridge, remote = self.fresh()
                delivery.deliver(bridge, [command(1, "new-thread", f"new\n{mode}\nShop\nwork"),
                                command(2, "new-thread", f"newm\n{mode}\nShop\ncodex\nm\n\nwork")])
                self.assertEqual(remote.calls, [], (answer, mode))
                for seq in "12":
                    self.assertTrue(bridge.state["results"][seq].startswith("failed:"), "so your words come back")
                    self.assertIn("installer", bridge.state["results"][seq])

    def test_a_config_we_cant_read_has_not_said_yes(self):
        (self.dir / "config.json").write_text("{not json")
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, "new-thread", "new\nfull-access\nShop\nwork")])
        self.assertEqual(remote.calls, [])

    def test_a_made_up_mode_starts_nothing_even_after_a_yes(self):
        self.say_full_access(True)
        for mode in ("turbo", "", "FULL-ACCESS", "full-access ", "danger-full-access"):
            bridge, remote = self.fresh()
            delivery.deliver(bridge, [command(1, "new-thread", f"new\n{mode}\nShop\nwork")])
            self.assertEqual(remote.calls, [], repr(mode))
            self.assertTrue(bridge.state["results"]["1"].startswith("failed:"))

    def test_an_old_addon_still_in_memory_starts_nothing_and_says_reload(self):
        self.say_full_access(True)
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, "new-thread", "new\nShop\nfix login\nand tests"),
                        command(2, "new-thread", "new\nShop\nfix login"),
                        command(3, "new-thread", "newm\nShop\nclaudeAgent\nclaude-opus-5-5\nhigh\nfix login")])
        self.assertEqual(remote.calls, [])
        for seq in "123":
            self.assertIn("/reload", bridge.state["results"][seq])

    def test_another_addon_stops_every_mode(self):
        self.say_full_access(True)
        (self.wow / "Interface/AddOns/SomeoneElse").mkdir(parents=True)
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(seq, "new-thread", f"new\n{mode}\nShop\nwork") for seq, mode in enumerate(settings.RUNTIME_MODES, 1)])
        self.assertEqual(remote.calls, [])

    def test_every_mode_counts_against_the_send_limit(self):
        self.say_full_access(True)
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(seq, "new-thread", "new\nfull-access\nShop\nwork") for seq in range(1, settings.MAX_SENDS_PER_MINUTE + 3)])
        self.assertEqual(len(remote.calls), settings.MAX_SENDS_PER_MINUTE)
        self.assertIn("too many", bridge.state["results"][str(settings.MAX_SENDS_PER_MINUTE + 1)])

    def test_t3_gets_the_mode_you_picked(self):
        remote = t3remote.T3Remote("http://t3", "token")
        with mock.patch.object(remote, "_rpc", return_value={"threadId": "t2"}) as rpc:
            remote.start_thread("p1", {"model": "m"}, "fix login\nand tests", "auto-accept-edits")
        tag, payload = rpc.call_args[0]
        self.assertEqual(tag, "orchestration.launchThread")
        self.assertEqual(payload["runtimeMode"], "auto-accept-edits")
        self.assertEqual(payload["interactionMode"], "default")

    def test_the_game_is_told_whether_full_access_is_on(self):
        for answer, told in ((True, True), (False, None), (None, None), ("yes", None)):
            self.say_full_access(answer)
            bridge, _ = self.fresh()
            refreshing.refresh(bridge)
            self.assertEqual(bridge.snapshot.get("fa"), told, answer)

    def test_new_thread_needs_words(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, "new-thread", "new\napproval-required\nShop\n   ")])
        self.assertIn("say what", bridge.state["results"]["1"])
        self.assertEqual(remote.calls, [])

    def test_another_addon_stops_everything_going_out(self):
        (self.wow / "Interface/AddOns/SomeoneElse").mkdir(parents=True)
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, "new-thread", "new\napproval-required\nShop\nwork"), command(2, THREAD, "stop"), command(3, THREAD, "diff"),
                        {"seq": 4, "thread": THREAD, "text": "hello"}])
        for seq in "1234":
            self.assertIn("SomeoneElse", bridge.state["results"][seq])
            self.assertIn("trust SomeoneElse", bridge.state["results"][seq], "it says how to trust it")
        self.assertEqual(remote.calls, [])
        self.assertEqual(remote.sent, [])

    def test_a_folder_that_only_looks_like_ours_is_not_ours(self):
        (self.wow / "Interface/AddOns/PromptPeonEvil").mkdir(parents=True)
        (self.wow / "Interface/AddOns/PromptPeonIn12").mkdir(parents=True)
        (self.wow / "Interface/AddOns/PromptPeonOut999").mkdir(parents=True)
        bridge, _ = self.make()
        self.assertEqual(gates.other_addons(bridge), ["PromptPeonEvil", "PromptPeonIn12", "PromptPeonOut999"])

    def test_a_folder_named_like_blizzards_still_counts(self):
        # The game's own addons aren't in this folder, so one that is there is somebody's.
        (self.wow / "Interface/AddOns/Blizzard_NotBlizzard").mkdir(parents=True)
        bridge, _ = self.make()
        self.assertEqual(gates.other_addons(bridge), ["Blizzard_NotBlizzard"])

    def test_not_being_able_to_look_fails_closed(self):
        bridge, remote = self.make()
        with mock.patch.object(addonfiles, "other_addons_in", side_effect=PermissionError("no")):
            delivery.deliver(bridge, [command(1, THREAD, "stop")])
        self.assertIn("could not check", bridge.state["results"]["1"])
        self.assertEqual(remote.calls, [])

    def test_commands_that_change_things_count_toward_the_limit(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(n, THREAD, "stop") for n in range(1, 13)])
        self.assertEqual(len(remote.calls), settings.MAX_SENDS_PER_MINUTE)
        self.assertIn("too many", bridge.state["results"]["12"])
        delivery.deliver(bridge, [command(n, THREAD, "diff") for n in range(13, 28)])
        self.assertEqual(bridge.state["results"]["27"], "sent", "looking at something isn't limited")

    def test_a_trusted_addon_does_not_block(self):
        (self.wow / "Interface/AddOns/SomeoneElse").mkdir(parents=True)
        (self.dir / "config.json").write_text(json.dumps({"trusted_addons": ["SomeoneElse"]}))
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, "new-thread", "new\napproval-required\nShop\nwork")])
        self.assertEqual(len(remote.calls), 1)

    def test_our_own_folders_are_not_other_addons(self):
        addonfiles.install_addon(self.wow, ROOT / "addon/PromptPeon")
        bridge, _ = self.make()
        self.assertEqual(gates.other_addons(bridge), [])

    def test_a_crash_mid_command_never_runs_it_twice(self):
        class Dies(CommandRemote):
            def start_thread(self, *args):
                self.calls.append("started")
                raise Crash()

        remote = Dies()
        first = bridgestate.Bridge(self.wow, remote, state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json")
        with self.assertRaises(Crash):
            delivery.deliver(first, [command(1, "new-thread", "new\napproval-required\nShop\nwork")])
        restarted = bridgestate.Bridge(self.wow, remote, state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json")
        delivery.deliver(restarted, [command(1, "new-thread", "new\napproval-required\nShop\nwork")])
        self.assertEqual(remote.calls, ["started"])
        self.assertIn("unknown", restarted.state["results"]["1"])

    def test_diff_reaches_only_the_thread_that_asked(self):
        shell = {"threads": [thread(modelSelection={"model": "m"}), thread(id="other-thread-1")], "projects": [{"id": "p1", "title": "Shop"}]}
        bridge, remote = self.make(CommandRemote(shell))
        delivery.deliver(bridge, [command(1, THREAD, "diff")])
        rows = {row["id"]: row for row in bridge.snapshot["threads"]}
        self.assertEqual(rows[THREAD]["df"], [["x", 1, 0, "@@ -0,0 +1 @@\n+new", True]])
        self.assertNotIn("df", rows["other-thread-1"])

    def test_a_diff_only_stays_for_a_minute(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, THREAD, "diff")])
        self.assertIn("df", bridge.snapshot["threads"][0])
        bridge.loaded[THREAD]["until"] = 0
        publishing.publish(bridge)
        self.assertNotIn("df", bridge.snapshot["threads"][0])
        self.assertNotIn("+new", bridge.snapshot_path.read_text())

    def test_queue_commands_and_undo_turn_in(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, THREAD, "cancelq\nrun-1"), command(2, THREAD, "editq\nrun-2\nnew words\nsecond line"),
                        command(3, THREAD, "unsettle")])
        self.assertEqual(remote.calls, [("cancelq", THREAD, "run-1"), ("editq", THREAD, "run-2", "new words\nsecond line"),
                                        ("unsettle", THREAD)])
        self.assertEqual([bridge.state["results"][n] for n in "123"], ["sent"] * 3)

    def test_queue_commands_refuse_bad_input(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, THREAD, "editq\nrun-1\n   "), command(2, THREAD, "editq\nrun-1"),
                        command(3, THREAD, "editq\nrun-1\n" + "x" * (settings.MAX_REPLY_BYTES + 1)), command(4, THREAD, "cancelq\n"),
                        command(5, "aaaaaaaa-1111", "cancelq\nrun-1"), command(6, "aaaaaaaa-1111", "unsettle")])
        self.assertEqual(remote.calls, [])
        for seq in "123":
            self.assertTrue(bridge.state["results"][seq].startswith("failed: "), bridge.state["results"][seq])
        self.assertIn("empty", bridge.state["results"]["1"])
        self.assertIn("too long", bridge.state["results"]["3"])
        self.assertTrue(bridge.state["results"]["4"].startswith("failed: "))
        self.assertIn("not on this T3 server", bridge.state["results"]["5"])
        self.assertIn("Reopen it in T3", bridge.state["results"]["6"])

    def test_queue_commands_are_gated_and_limited(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(n, THREAD, "cancelq\nr") for n in range(1, 4)] + [command(n, THREAD, "unsettle") for n in range(4, 8)]
                       + [command(n, THREAD, "editq\nr\nt") for n in range(8, 14)])
        self.assertEqual(len(remote.calls), settings.MAX_SENDS_PER_MINUTE)
        self.assertIn("too many", bridge.state["results"]["13"])
        (self.wow / "Interface/AddOns/SomeoneElse").mkdir(parents=True)
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(21, THREAD, "cancelq\nr"), command(22, THREAD, "editq\nr\nt"), command(23, THREAD, "unsettle")])
        self.assertEqual(remote.calls, [])
        for seq in ("21", "22", "23"):
            self.assertIn("SomeoneElse", bridge.state["results"][seq])

    def test_queue_commands_refresh_the_thread(self):
        bridge, remote = self.make()
        bridge.seen[THREAD] = "old"
        delivery.deliver(bridge, [command(1, THREAD, "cancelq\nr")])
        self.assertNotEqual(bridge.seen.get(THREAD), "old", "the thread was read again")

    def test_thread_count_is_before_the_cap(self):
        many = [thread(id=f"t{n}") for n in range(settings.MAX_THREADS + 5)] + [thread(id="done-one", settledAt="2026-11-02T16:00:00.000Z")]
        snap = snapshots.build_snapshot({"threads": many, "projects": []}, {}, url="u", error="", error_since=0, ack=0, results={})
        self.assertEqual(len(snap["threads"]), settings.MAX_THREADS)
        self.assertEqual(snap["tc"], settings.MAX_THREADS + 5)
        self.assertNotIn("tc", snapshots.build_snapshot(None, {}, url="u", error="down", error_since=0, ack=0, results={}))

    def hide(self, bridge, seq, *lines):
        delivery.deliver(bridge, [command(seq, "settings", "hidden\n" + "\n".join(lines))])

    def test_hidden_threads_keep_only_the_bare_row(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, THREAD, "diff")])
        self.assertIn("**done**", bridge.snapshot_path.read_text())
        self.hide(bridge, 2, f"t:{THREAD}")
        self.assertEqual(bridge.state["results"]["2"], "sent")
        row = bridge.snapshot["threads"][0]
        self.assertEqual(sorted(row), ["hd", "id", "p", "s", "t", "u"])
        self.assertTrue(row["hd"])
        self.assertNotIn("**done**", bridge.snapshot_path.read_text())
        self.assertNotIn("+new", bridge.snapshot_path.read_text())
        self.hide(bridge, 3)
        self.assertIn("**done**", bridge.snapshot_path.read_text())
        self.assertNotIn("hd", bridge.snapshot["threads"][0])

    def test_hiding_a_project_hides_its_threads(self):
        shell = {"threads": [thread(), thread(id="other-thread-1", projectId="p2")],
                 "projects": [{"id": "p1", "title": "Shop"}, {"id": "p2", "title": "Home"}]}
        bridge, _ = self.make(CommandRemote(shell))
        self.hide(bridge, 1, "p:Shop")
        rows = {row["id"]: row for row in bridge.snapshot["threads"]}
        self.assertTrue(rows[THREAD]["hd"])
        self.assertNotIn("hd", rows["other-thread-1"])
        self.assertIn("m", rows["other-thread-1"])

    def test_hidden_survives_a_restart(self):
        bridge, remote = self.make()
        self.hide(bridge, 1, "p:Shop", f"t:{THREAD}", "t:another")
        self.assertEqual(bridge.state["hidden"], {"projects": ["Shop"], "threads": [THREAD, "another"]})
        restarted, _ = self.make(remote)
        refreshing.refresh(restarted)
        self.assertTrue(restarted.snapshot["threads"][0]["hd"])
        self.assertNotIn("**done**", restarted.snapshot_path.read_text())

    def test_reading_commands_refuse_a_hidden_thread(self):
        bridge, remote = self.make()
        self.hide(bridge, 1, f"t:{THREAD}")
        delivery.deliver(bridge, [command(2, THREAD, "diff"), command(3, THREAD, "agents"), command(4, THREAD, "file\nx.py"),
                        command(5, THREAD, "older\n3")])
        for seq in "2345":
            self.assertEqual(bridge.state["results"][seq], "failed: this thread is hidden. Show it first.")
        self.assertEqual(remote.calls, [])
        delivery.deliver(bridge, [command(6, THREAD, "stop"), command(7, THREAD, "settle"), {"seq": 8, "thread": THREAD, "text": "hello"}])
        self.assertEqual(remote.calls, [("stop", THREAD), ("settle", THREAD)])
        self.assertEqual(remote.sent, [(THREAD, "hello")])

    def test_hidden_is_not_stopped_by_the_gate_or_the_limit(self):
        (self.wow / "Interface/AddOns/SomeoneElse").mkdir(parents=True)
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, THREAD, "stop"), command(2, "settings", "hidden\np:Shop")])
        self.assertIn("SomeoneElse", bridge.state["results"]["1"])
        self.assertEqual(bridge.state["results"]["2"], "sent")
        self.assertEqual(bridge.state["hidden"]["projects"], ["Shop"])
        (self.dir / "config.json").write_text(json.dumps({"trusted_addons": ["SomeoneElse"]}))
        trusted, _ = self.make()
        delivery.deliver(trusted, [command(n, THREAD, "stop") for n in range(10, 10 + settings.MAX_SENDS_PER_MINUTE)] + [command(30, "settings", "hidden\np:Home")])
        self.assertEqual(trusted.state["results"]["30"], "sent")
        self.assertEqual(trusted.state["hidden"]["projects"], ["Home"])

    def test_hidden_threads_get_no_pictures(self):
        addonfiles.install_addon(self.wow, ROOT / "addon/PromptPeon")
        bridge, remote = self.make()
        self.hide(bridge, 1, f"t:{THREAD}")
        with mock.patch.object(bridge.previews, "prepare", wraps=bridge.previews.prepare) as prepare:
            publishing.publish(bridge)
            prepare.assert_not_called()

    def big_file_bridge(self):
        patch = "@@ -5,3000 +7,3000 @@\n" + "\n".join("+" + "line " + "x" * 90 for _ in range(3000))
        diff = "diff --git a/big.json b/big.json\n--- a/big.json\n+++ b/big.json\n" + patch

        class Big(CommandRemote):
            def thread_diff(self, thread_id):
                self.calls.append(("diff", thread_id))
                return diff

        return self.make(Big())

    def test_a_big_file_comes_a_page_at_a_time(self):
        bridge, remote = self.big_file_bridge()
        delivery.deliver(bridge, [command(1, THREAD, "diff")])
        row = bridge.snapshot["threads"][0]
        self.assertEqual(row["df"][0][:5], ["big.json", 3000, 0, "", False], "listed, not carried")
        delivery.deliver(bridge, [command(2, THREAD, "file\nbig.json\n1")])
        self.assertEqual(bridge.state["results"]["2"], "sent")
        page = bridge.snapshot["threads"][0]["fp"]
        self.assertEqual(page[:2], ["big.json", 1])
        self.assertGreater(page[2], 1)
        self.assertEqual(page[3:5], [5, 7])
        self.assertIn("@@ -5,3000 +7,3000 @@", page[5])
        delivery.deliver(bridge, [command(3, THREAD, "file\nbig.json\n2")])
        second = bridge.snapshot["threads"][0]["fp"]
        self.assertEqual(second[1], 2)
        self.assertGreater(second[4], 7, "numbers carry on")
        self.assertNotIn("@@", second[5])
        self.assertEqual(len([call for call in remote.calls if call[0] == "diff"]), 1, "paging asks T3 nothing new")

    def test_asking_for_a_page_past_the_end_gives_the_last(self):
        bridge, _ = self.big_file_bridge()
        delivery.deliver(bridge, [command(1, THREAD, "file\nbig.json\n999")])
        page = bridge.snapshot["threads"][0]["fp"]
        self.assertEqual(page[1], page[2])

    def test_a_page_works_after_a_bridge_restart(self):
        bridge, remote = self.big_file_bridge()
        delivery.deliver(bridge, [command(1, THREAD, "file\nbig.json\n1")])
        self.assertEqual(bridge.state["results"]["1"], "sent")
        self.assertEqual(remote.calls[0][0], "diff")

    def test_only_files_in_the_diff_can_be_asked_for(self):
        bridge, _ = self.big_file_bridge()
        delivery.deliver(bridge, [command(1, THREAD, "file\n/etc/passwd\n1"), command(2, THREAD, "file\nbig.json\nnonsense")])
        self.assertIn("can't be shown", bridge.state["results"]["1"])
        self.assertIn("failed", bridge.state["results"]["2"])
        self.assertNotIn("fp", bridge.snapshot["threads"][0])

    def test_older_messages_go_through_the_command(self):
        class WithHistory(CommandRemote):
            def older_rows(self, thread_id, before):
                self.calls.append(("older", before))
                return [["a", "old words", "d", 5]], True

        bridge, remote = self.make(WithHistory())
        delivery.deliver(bridge, [command(1, THREAD, "older\n100")])
        self.assertEqual(bridge.state["results"]["1"], "sent")
        self.assertEqual(remote.calls, [("older", 100)])
        row = bridge.snapshot["threads"][0]
        self.assertEqual((row["ob"], row["om"], row["oc"]), ([["a", "old words", "d", 5]], True, 100))

    def test_a_bad_older_request_fails_politely(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, THREAD, "older\nnonsense")])
        self.assertIn("failed", bridge.state["results"]["1"])

    def test_an_empty_diff_says_so(self):
        class Empty(CommandRemote):
            def thread_diff(self, thread_id):
                return ""

        bridge, _ = self.make(Empty())
        delivery.deliver(bridge, [command(1, THREAD, "diff")])
        self.assertIn("no changes", bridge.snapshot["threads"][0]["dn"])

    def test_a_cut_off_diff_says_so(self):
        class Huge(CommandRemote):
            def thread_diff(self, thread_id):
                return "x" * settings.T3_DIFF_LIMIT

        bridge, _ = self.make(Huge())
        delivery.deliver(bridge, [command(1, THREAD, "diff")])
        self.assertIn("10 MB", bridge.snapshot["threads"][0]["dn"])

    def test_agents_load_their_words_on_request(self):
        rows, words = timeline.describe_agents([{"id": "a1", "title": "Scout", "status": "completed", "prompt": "Look.", "result": "## Done"}])

        class WithAgents(CommandRemote):
            def detail(self, thread_id):
                return {"rows": [], "agents": rows, "agents_total": 1, "agent_words": words}

        bridge, remote = self.make(WithAgents())
        refreshing.refresh(bridge)
        row = bridge.snapshot["threads"][0]
        self.assertEqual(row["ag"][0][1:3], ["Scout", "d"])
        self.assertNotIn("ax", row)
        self.assertNotIn("Look.", bridge.snapshot_path.read_text(), "their words stay out until you open them")
        delivery.deliver(bridge, [command(1, THREAD, "agents")])
        self.assertEqual(bridge.state["results"]["1"], "sent")
        self.assertEqual(bridge.snapshot["threads"][0]["ax"][rows[0][0]], ["Look.", "## Done"])
        self.assertIn("Look.", bridge.snapshot_path.read_text())

    def test_agent_words_leave_out_the_oldest_when_too_big(self):
        ceiling = mock.patch.object(settings, "MAX_MESSAGE_CHARS", 10 ** 9)
        ceiling.start()
        self.addCleanup(ceiling.stop)
        agents = [{"id": f"a{n}", "title": f"A{n}", "status": "completed", "startedAt": f"2026-01-0{n}T00:00:00Z", "result": "x" * 600_000} for n in (1, 2)]
        rows, words = timeline.describe_agents(agents)

        class WithAgents(CommandRemote):
            def detail(self, thread_id):
                return {"rows": [], "agents": rows, "agents_total": 2, "agent_words": words}

        bridge, remote = self.make(WithAgents())
        refreshing.refresh(bridge)
        delivery.deliver(bridge, [command(1, THREAD, "agents")])
        kept = bridge.snapshot["threads"][0]["ax"]
        self.assertEqual(list(kept), [rows[0][0]])
        self.assertEqual(rows[0][1], "A2", "newest first")


class HidingPictures(Base):
    def setUp(self):
        super().setUp()
        shell = {"threads": [thread()], "projects": [{"id": "p1", "title": "Shop"}]}
        self.bridge = bridgestate.Bridge(self.wow, CommandRemote(shell), state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json")
        self.picture = self.bridge.previews.folder / "p01.tga"
        self.picture.parent.mkdir(parents=True, exist_ok=True)
        self.picture.write_bytes(b"a picture from the thread")

    def hide(self, seq, *lines):
        delivery.deliver(self.bridge, [command(seq, "settings", "hidden\n" + "\n".join(lines))])

    def test_hiding_takes_the_pictures_out_of_the_game_folder(self):
        self.hide(1, f"t:{THREAD}")
        self.assertEqual(self.picture.read_bytes(), pngtga.blank_tga())

    def test_a_list_that_hides_nothing_new_leaves_pictures_alone(self):
        self.hide(1)
        self.assertEqual(self.picture.read_bytes(), b"a picture from the thread")
        self.bridge.state["hidden"] = {"projects": [], "threads": [THREAD]}
        self.hide(2, f"t:{THREAD}")
        self.assertEqual(self.picture.read_bytes(), b"a picture from the thread", "the list goes again at every login")


if __name__ == "__main__":
    unittest.main(verbosity=1)
