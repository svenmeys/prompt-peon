"""Answering an agent's question from the game: what the game is told, and what reaches T3."""
import unittest

from bridge_helpers import Base, CommandRemote, THREAD, command, thread
from promptpeon import bridgestate, delivery, refreshing, settings, timeline


def ask(**extra):
    item = {
        "type": "user_input_request", "requestId": "req-1", "status": "waiting", "ordinal": 7,
        "questions": [
            {"id": "q-color", "header": "Color", "question": "Which color?", "multiSelect": False,
             "options": [{"label": "Red", "description": "Warm"}, {"label": "Blue", "description": "Cool", "value": "blue-v"}]},
            {"id": "q-extras", "header": "Extras", "question": "Which extras?", "multiSelect": True, "allowCustomAnswer": False,
             "options": [{"label": "Wheels", "description": ""}, {"label": "Bell", "description": ""}, {"label": "Basket", "description": ""}]},
        ],
    }
    item.update(extra)
    return item


MARK = timeline.question_mark(ask())


class AskingRemote(CommandRemote):
    def __init__(self, item=None, **kwargs):
        super().__init__(shell={"threads": [thread(status="needs", pendingRuntimeRequest={"kind": "user_input", "blocking": True})],
                                "projects": [{"id": "p1", "title": "Shop"}]}, **kwargs)
        self.item = ask() if item is None else item
        self.answered = []

    def detail(self, thread_id):
        return timeline.describe_thread({"turnItems": [{"type": "user_message", "text": "go", "status": "completed", "ordinal": 1}, self.item]})

    def open_question(self, thread_id):
        return self.item if self.item and timeline.state_of(self.item) == "r" else None

    def answer_question(self, thread_id, request_id, answers):
        self.answered.append((thread_id, request_id, answers))


class WhatTheGameIsTold(unittest.TestCase):
    def test_an_open_question_carries_its_answers(self):
        rows = timeline.build_timeline([ask()])
        self.assertEqual(rows[0][0:3], ["q", "Which color?\n- Red\n- Blue\nWhich extras?\n- Wheels\n- Bell\n- Basket", "r"])
        choices = rows[0][4]
        self.assertEqual(choices["r"], timeline.question_mark(ask()))
        self.assertEqual(len(choices["r"]), 32, "a fingerprint of the question and its answers, not only of its id")
        self.assertEqual([entry["t"] for entry in choices["q"]], ["Which color?", "Which extras?"])
        self.assertEqual(choices["q"][0]["o"], [["Red", "Warm"], ["Blue", "Cool"]])
        self.assertEqual((choices["q"][0]["m"], choices["q"][0]["c"]), (False, True), "a typed answer is allowed unless T3 says no")
        self.assertEqual((choices["q"][1]["m"], choices["q"][1]["c"]), (True, False))
        self.assertNotIn("blue-v", str(choices), "values are T3's business, the game only counts")

    def test_answered_questions_stay_a_line_without_answers(self):
        rows = timeline.build_timeline([ask(status="completed")])
        self.assertEqual(rows, [["n", "Asked: Which color?", "d", 7]])

    def test_questions_the_game_cant_show_whole_stay_in_t3(self):
        too_many = ask(questions=[{"id": f"q{n}", "question": f"Q{n}?", "options": [{"label": "A"}]} for n in range(settings.MAX_QUESTIONS + 1)])
        wide = ask(questions=[{"id": "q", "question": "Pick", "options": [{"label": str(n)} for n in range(settings.MAX_ANSWER_OPTIONS + 1)]}])
        no_id = ask(questions=[{"question": "Pick", "options": [{"label": "A"}]}])
        by_message = ask(responseMode="message")
        no_request = ask(requestId="")
        for item in (too_many, wide, no_id, by_message, no_request):
            row = timeline.build_timeline([item])[0]
            self.assertEqual(row[0], "q", "the question still shows")
            self.assertEqual(len(row), 4, f"but with nothing to click: {item}")


class Answering(Base):
    def make(self, item=None):
        remote = AskingRemote(item)
        return bridgestate.Bridge(self.wow, remote, state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json"), remote

    def answer(self, words, item=None):
        words = words.replace("req-1", timeline.question_mark(item) if item else MARK).replace("req-old", timeline.question_mark(ask(requestId="req-old")))
        # The state folder outlives one bridge, so every answer gets a number of its own.
        self.seq = getattr(self, "seq", 0) + 1
        bridge, remote = self.make(item)
        refreshing.refresh(bridge)
        delivery.deliver(bridge, [command(self.seq, THREAD, "answer\n" + words)])
        return bridge.state["results"][str(self.seq)], remote.answered

    def test_the_thread_says_its_a_question(self):
        bridge, _ = self.make()
        refreshing.refresh(bridge)
        row = bridge.snapshot["threads"][0]
        self.assertTrue(row["uq"])
        self.assertEqual(row["a"], "Waiting for your answer")

    def test_picked_answers_go_as_t3s_own_words(self):
        result, answered = self.answer("req-1\no:2\no:1,3")
        self.assertEqual(result, "sent")
        self.assertEqual(answered, [(THREAD, "req-1", {"q-color": "blue-v", "q-extras": ["Wheels", "Basket"]})])

    def test_a_typed_answer(self):
        result, answered = self.answer("req-1\nt:  Green, please  \no:2")
        self.assertEqual(result, "sent")
        self.assertEqual(answered[0][2], {"q-color": "Green, please", "q-extras": ["Bell"]})

    def test_what_the_game_cant_send(self):
        cases = {
            "req-old\no:1\no:1": "isn't open any more",
            "req-1\no:1": "every question",
            "req-1\no:3\no:1": "answers shown",
            "req-1\no:0\no:1": "answers shown",
            "req-1\no:1,2\no:1": "takes one answer",
            "req-1\no:1\no:1,1": "answers shown",
            "req-1\no:x\no:1": "answers shown",
            "req-1\nt:\no:1": "type an answer",
            "req-1\no:1\nt:my own": "only takes one of its answers",
            "req-1\nwhat\no:1": "every question",
        }
        for words, expected in cases.items():
            result, answered = self.answer(words)
            self.assertIn(expected, result, words)
            self.assertEqual(answered, [], words)

    def test_answers_swapped_round_after_you_read_them_are_refused(self):
        # The same request, with its two answers in the other order.
        def staging_first(first, second):
            return ask(questions=[{"id": "one", "header": "Where", "question": "Deploy where?", "multiSelect": False,
                                   "options": [{"label": first.title(), "value": first}, {"label": second.title(), "value": second}]}])
        seen = timeline.question_mark(staging_first("staging", "production"))
        self.seq = getattr(self, "seq", 0) + 1
        bridge, remote = self.make(staging_first("production", "staging"))
        refreshing.refresh(bridge)
        delivery.deliver(bridge, [command(self.seq, THREAD, f"answer\n{seen}\no:1")])
        self.assertIn("changed", bridge.state["results"][str(self.seq)])
        self.assertEqual(remote.answered, [], "answer 1 was Staging when it was read")

    def test_the_mark_covers_every_answer_and_what_it_stands_for(self):
        base = ask()
        changed = [ask(requestId="other"), ask(threadId="another-thread")]
        for field, value in (("label", "Crimson"), ("description", "Hot"), ("value", "red-v")):
            item = ask()
            item["questions"][0]["options"][0][field] = value
            changed.append(item)
        reordered = ask()
        reordered["questions"][0]["options"].reverse()
        changed.append(reordered)
        retitled = ask()
        retitled["questions"][0]["question"] = "Which colour?"
        changed.append(retitled)
        for item in changed:
            self.assertNotEqual(timeline.question_mark(item), timeline.question_mark(base))

    def test_an_answer_too_long_is_refused(self):
        result, answered = self.answer("req-1\nt:" + "x" * (settings.MAX_REPLY_BYTES + 1) + "\no:1")
        self.assertIn("too long", result)
        self.assertEqual(answered, [])

    def test_a_question_answered_meanwhile(self):
        result, answered = self.answer("req-1\no:1\no:1", item=ask(status="completed"))
        self.assertIn("isn't open any more", result)
        self.assertEqual(answered, [])

    def test_a_question_too_big_for_the_game(self):
        result, answered = self.answer("req-1\no:1", item=ask(responseMode="message"))
        self.assertIn("in T3", result)
        self.assertEqual(answered, [])

    def test_full_access_agents_need_full_access_turned_on(self):
        bridge, remote = self.make()
        remote._shell["threads"][0]["runtimeMode"] = "full-access"
        refreshing.refresh(bridge)
        delivery.deliver(bridge, [command(1, THREAD, "answer\n" + MARK + "\no:1\no:1")])
        self.assertIn("full access", bridge.state["results"]["1"])
        self.assertEqual(remote.answered, [])

    def test_a_hidden_thread_cant_be_answered(self):
        bridge, remote = self.make()
        bridge.state["hidden"] = {"projects": [], "threads": [THREAD]}
        refreshing.refresh(bridge)
        delivery.deliver(bridge, [command(1, THREAD, "answer\n" + MARK + "\no:1\no:1")])
        self.assertIn("hidden", bridge.state["results"]["1"])
        self.assertEqual(remote.answered, [])

    def test_an_untrusted_addon_cant_answer(self):
        bridge, remote = self.make()
        (self.wow / "Interface/AddOns/SomeoneElse").mkdir(parents=True)
        delivery.deliver(bridge, [command(1, THREAD, "answer\n" + MARK + "\no:1\no:1")])
        self.assertIn("SomeoneElse", bridge.state["results"]["1"])
        self.assertEqual(remote.answered, [])

    def test_answers_count_like_replies(self):
        bridge, remote = self.make()
        refreshing.refresh(bridge)
        delivery.deliver(bridge, [command(n, THREAD, "answer\n" + MARK + "\no:1\no:1") for n in range(1, settings.MAX_SENDS_PER_MINUTE + 2)])
        self.assertIn("too many", bridge.state["results"][str(settings.MAX_SENDS_PER_MINUTE + 1)])
        self.assertEqual(len(remote.answered), settings.MAX_SENDS_PER_MINUTE)


if __name__ == "__main__":
    unittest.main(verbosity=1)
