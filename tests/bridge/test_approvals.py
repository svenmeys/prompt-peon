"""Yolo mode: approving what an agent asks to do from the game. Off unless you turn it on, outside the game."""
import contextlib
import io
import json
import unittest
from unittest import mock

from bridge_helpers import Base, CommandRemote, THREAD, command, thread
from promptpeon import bridgestate, delivery, gates, prompts, publishing, refreshing, settings, timeline


def asks(**extra):
    item = {"type": "approval_request", "requestId": "req-run", "requestKind": "command", "status": "waiting", "ordinal": 9,
            "prompt": "rm -rf build && make all", "reason": None}
    item.update(extra)
    return item


MARK = timeline.approval_mark(asks())


class ApprovalRemote(CommandRemote):
    def __init__(self, item=None):
        super().__init__(shell={"threads": [thread(status="needs", pendingRuntimeRequest={"kind": "command", "blocking": True})],
                                "projects": [{"id": "p1", "title": "Shop"}]})
        self.item = asks() if item is None else item
        self.decided = []

    def detail(self, thread_id):
        return timeline.describe_thread({"turnItems": [{"type": "user_message", "text": "go", "status": "completed", "ordinal": 1}, self.item]})

    def open_approval(self, thread_id):
        return self.item if self.item and timeline.state_of(self.item) == "r" else None

    def answer_approval(self, thread_id, request_id, decision):
        self.decided.append((thread_id, request_id, decision))


class WhatTheGameIsTold(unittest.TestCase):
    def test_a_waiting_approval_shows_all_of_what_it_asks(self):
        long_command = "echo " + "x" * 3000
        row = timeline.build_timeline([asks(prompt=long_command)])[0]
        self.assertEqual(row[0], "p")
        self.assertEqual(row[1], long_command, "the request itself, whole and nothing else: you can't approve what you can't read")
        self.assertEqual(row[4], {"r": timeline.approval_mark(asks(prompt=long_command)), "k": "run a command"})

    def test_the_reason_rides_apart_from_the_request(self):
        row = timeline.build_timeline([asks(reason="the build is stale")])[0]
        self.assertEqual((row[1], row[4]["y"]), ("rm -rf build && make all", "the build is stale"))

    def test_words_inside_a_request_can_not_pass_for_its_reason(self):
        # One request with a reason, and another whose words only look like that.
        honest = asks(requestId="same", prompt="echo safe", reason="explanation\nrm -rf important")
        forged = asks(requestId="same", prompt="echo safe\nIts reason: explanation\nrm -rf important", reason=None)
        self.assertNotEqual(timeline.approval_mark(honest), timeline.approval_mark(forged))
        row = timeline.build_timeline([forged])[0]
        self.assertIn("rm -rf important", row[1], "it is all part of the request, and drawn as the request")
        self.assertNotIn("y", row[4])

    def test_the_same_request_in_another_thread_has_another_mark(self):
        self.assertNotEqual(timeline.approval_mark(asks(threadId="thread-a")), timeline.approval_mark(asks(threadId="thread-b")))

    def test_the_mark_is_of_the_request_and_every_word_shown(self):
        self.assertEqual(len(MARK), 32, "long enough that two requests can't be made to share one")
        self.assertNotEqual(MARK, timeline.approval_mark(asks(prompt="rm -rf important")), "the same request with other words")
        self.assertNotEqual(MARK, timeline.approval_mark(asks(requestId="req-other")), "the same words in another request")
        self.assertNotEqual(MARK, timeline.approval_mark(asks(reason="because")), "a reason is part of what you read")
        self.assertNotEqual(MARK, timeline.approval_mark(asks(requestKind="file-change")))
        # Two request ids that share a CRC32.
        self.assertNotEqual(timeline.approval_mark(asks(requestId="1fb34678cd8a644bac118672")), timeline.approval_mark(asks(requestId="0c5cb8de61d1eef2b0ef6289")))

    def test_words_the_game_would_change_cant_be_approved_from_it(self):
        hidden = 'TOKEN="$(rm -rf important)"; echo safe'  # The secret filter would blank the part that runs.
        cut = "x" * (settings.MAX_APPROVAL_CHARS - 5)
        cases = {
            "a secret-looking part the game hides": asks(prompt=hidden),
            "a tab the game would turn into spaces": asks(prompt="make\tall"),
            "a character WoW's fonts can't draw": asks(prompt="echo \U0001F600"),
            "a control character": asks(prompt="echo \x07 done"),
            "a reason that takes it over the limit": asks(prompt="echo safe", reason=cut),
            "a reason the game would change": asks(reason="do\tit"),
            "a character you can't see": asks(prompt="cat safe\u200b.txt"),
            "words that run right to left": asks(prompt="echo \u202etxt.exe"),
            "a soft hyphen": asks(prompt="rm impor\u00adtant"),
            "a letter outside plain ASCII": asks(prompt="echo caf\u00e9"),
        }
        for why, item in cases.items():
            self.assertIsNone(timeline.approval_parts(item), why)
            self.assertIsNone(timeline.approval_mark(item), why)
            self.assertTrue(all(len(row) == 4 for row in timeline.build_timeline([item])), why)


    def test_one_the_game_cant_show_has_nothing_to_click(self):
        for item in (asks(prompt=""), asks(prompt=None), asks(requestId=""), asks(prompt="x" * (settings.MAX_APPROVAL_CHARS + 1))):
            rows = timeline.build_timeline([item])
            self.assertTrue(all(len(row) == 4 for row in rows), f"no mark, so no Approve: {item}")

    def test_an_approval_that_is_over_has_nothing_to_click(self):
        rows = timeline.build_timeline([asks(status="completed")])
        self.assertTrue(all(row[0] != "p" for row in rows))


class Approving(Base):
    def make(self, item=None, yolo=True):
        remote = ApprovalRemote(item)
        (self.dir / "config.json").write_text(json.dumps({"yolo": True} if yolo else {}))
        return bridgestate.Bridge(self.wow, remote, state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json"), remote

    def decide(self, words, item=None, yolo=True):
        self.seq = getattr(self, "seq", 0) + 1
        bridge, remote = self.make(item, yolo)
        refreshing.refresh(bridge)
        delivery.deliver(bridge, [command(self.seq, THREAD, "approve\n" + words)])
        return bridge.state["results"][str(self.seq)], remote.decided

    def test_off_unless_you_turned_it_on(self):
        result, decided = self.decide(f"{MARK}\naccept", yolo=False)
        self.assertEqual(decided, [], "nothing reaches T3")
        self.assertIn("Yolo mode is off", result)
        self.assertIn("yolo on", result, "and it names the command that turns it on")

    def test_the_game_is_told_whether_it_is_on(self):
        for yolo in (True, False):
            bridge, _ = self.make(yolo=yolo)
            refreshing.refresh(bridge)
            publishing.publish(bridge)
            self.assertEqual(bridge.snapshot.get("yo"), True if yolo else None)

    def test_approve_and_decline_reach_t3_as_its_own_request(self):
        result, decided = self.decide(f"{MARK}\naccept")
        self.assertEqual((result, decided), ("sent", [(THREAD, "req-run", "accept")]))
        result, decided = self.decide(f"{MARK}\ndecline")
        self.assertEqual((result, decided), ("sent", [(THREAD, "req-run", "decline")]))

    def test_what_the_game_cant_do(self):
        cases = {
            f"{timeline.approval_mark(asks(requestId='req-old'))}\naccept": "isn't open any more",
            "0badf00d\naccept": "isn't open any more",
            f"{MARK}\nacceptAlways": "Approve or Decline",
            f"{MARK}\nacceptForSession": "Approve or Decline",
            f"{MARK}\n": "Approve or Decline",
            "accept": "isn't open any more",
        }
        for words, reason in cases.items():
            result, decided = self.decide(words)
            self.assertIn(reason, result, words)
            self.assertEqual(decided, [], words)

    def test_a_request_whose_words_changed_after_you_saw_them_is_refused(self):
        # You read "echo safe". Before your click arrives, T3 has other words under the same request id.
        seen = timeline.approval_mark(asks(prompt="echo safe"))
        result, decided = self.decide(f"{seen}\naccept", item=asks(prompt="rm -rf important"))
        self.assertIn("isn't open any more", result)
        self.assertEqual(decided, [], "what you approved is not what is open now")

    def test_a_request_reshaped_to_read_the_same_is_refused(self):
        seen = timeline.approval_mark(asks(requestId="same", prompt="echo safe", reason="explanation\nrm -rf important"))
        result, decided = self.decide(f"{seen}\naccept", item=asks(requestId="same", prompt="echo safe\nIts reason: explanation\nrm -rf important", reason=None))
        self.assertIn("changed", result)
        self.assertEqual(decided, [])

    def test_another_request_can_not_stand_in_for_the_one_you_saw(self):
        seen = timeline.approval_mark(asks(requestId="1fb34678cd8a644bac118672", prompt="echo safe"))
        result, decided = self.decide(f"{seen}\naccept", item=asks(requestId="0c5cb8de61d1eef2b0ef6289", prompt="rm -rf important"))
        self.assertEqual(decided, [])

    def test_one_that_was_already_decided_is_refused(self):
        result, decided = self.decide(f"{MARK}\naccept", item=asks(status="completed"))
        self.assertIn("isn't open any more", result)
        self.assertEqual(decided, [])

    def test_one_the_game_could_not_show_whole_cant_be_approved_from_it(self):
        result, decided = self.decide(f"{MARK}\naccept", item=asks(prompt=""))
        self.assertIn("in T3", result)
        self.assertEqual(decided, [])

    def test_an_addon_you_have_not_trusted_cant_approve(self):
        bridge, remote = self.make()
        (self.wow / "Interface/AddOns/SomeoneElse").mkdir()
        refreshing.refresh(bridge)
        delivery.deliver(bridge, [command(1, THREAD, f"approve\n{MARK}\naccept")])
        self.assertIn("SomeoneElse", bridge.state["results"]["1"])
        self.assertEqual(remote.decided, [])

    def test_a_hidden_thread_cant_be_approved(self):
        bridge, remote = self.make()
        refreshing.refresh(bridge)
        bridge.state["hidden"] = {"projects": [], "threads": [THREAD]}
        delivery.deliver(bridge, [command(1, THREAD, f"approve\n{MARK}\naccept")])
        self.assertIn("hidden", bridge.state["results"]["1"])
        self.assertEqual(remote.decided, [])

    def test_approvals_count_against_the_sending_limit(self):
        bridge, remote = self.make()
        refreshing.refresh(bridge)
        many = [command(n, THREAD, f"approve\n{MARK}\naccept") for n in range(1, settings.MAX_SENDS_PER_MINUTE + 3)]
        delivery.deliver(bridge, many)
        self.assertEqual(len(remote.decided), settings.MAX_SENDS_PER_MINUTE)
        self.assertIn("too many", bridge.state["results"][str(settings.MAX_SENDS_PER_MINUTE + 1)])


class TurningItOn(Base):
    def setUp(self):
        super().setUp()
        patch = mock.patch.object(settings, "CONFIG_DIR", self.dir / "cfg")
        patch.start()
        self.addCleanup(patch.stop)
        (self.dir / "cfg").mkdir()
        (self.dir / "cfg/config.json").write_text(json.dumps({"url": "http://h:1", "full_access": True}))

    def test_on_and_off_keep_every_other_setting(self):
        said = prompts.set_yolo(True)
        config = json.loads((self.dir / "cfg/config.json").read_text())
        self.assertEqual(config, {"url": "http://h:1", "full_access": True, "yolo": True})
        self.assertIn("any addon you trust", said.lower())
        prompts.set_yolo(False)
        self.assertEqual(json.loads((self.dir / "cfg/config.json").read_text()), {"url": "http://h:1", "full_access": True})

    def test_the_command_is_one_the_game_can_name(self):
        self.assertTrue(gates.cli_command("yolo on").endswith(" yolo on"))

    def test_a_command_the_game_shows_does_not_have_your_account_name_in_it(self):
        from pathlib import Path
        shown = gates.without_your_name(Path.home() / ".local/share/prompt-peon/promptpeon_bridge.py")
        self.assertNotIn(str(Path.home()), shown)
        self.assertTrue(shown.startswith("%USERPROFILE%" if settings.IS_WINDOWS else "$HOME/"), shown)
        self.assertEqual(gates.without_your_name(Path("/usr/bin/python3.14")), str(Path("/usr/bin/python3.14")), "a path outside your home is left as it is")
