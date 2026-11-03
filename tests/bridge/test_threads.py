"""Which threads show where, what each row says, and secrets caught on the way."""
import json
import time
import unittest

from bridge_helpers import split_diff, thread
from promptpeon import diffs, gametext, luadata, settings, snapshots, threadstate, timeline


class Status(unittest.TestCase):
    def test_needs_outranks_everything(self):
        self.assertEqual(threadstate.status_of(thread(pendingRuntimeRequest={"x": 1}, status="running")), "needs")

    def test_active_run_beats_stale_status(self):
        # Real case: a cancelled follow-up run while the main run is still going.
        self.assertEqual(threadstate.status_of(thread(status="cancelled", activeRunId="r", activityRunStatus="running")), "running")

    def test_plain_mapping(self):
        for raw, want in [("completed", "done"), ("failed", "error"), ("cancelled", "stopped"), ("idle", "idle")]:
            self.assertEqual(threadstate.status_of(thread(status=raw)), want)

    def test_a_message_answers_a_non_blocking_request(self):
        waiting = {"kind": "user_input", "blocking": False}
        self.assertEqual(threadstate.status_of(thread(pendingRuntimeRequest=waiting)), "needs")

    def test_an_old_question_in_a_background_child_is_not_a_false_alarm(self):
        waiting = {"kind": "user_input", "blocking": False}
        child = thread(id="child", lineage={"parentThreadId": "x"}, pendingRuntimeRequest=waiting)
        self.assertNotEqual(threadstate.status_of(child), "needs")
        self.assertEqual(threadstate.active_threads({"threads": [child]}), [])

    def test_a_blocking_child_still_needs_you(self):
        child = thread(id="child", lineage={"parentThreadId": "x"}, pendingRuntimeRequest={"kind": "approval", "blocking": True})
        self.assertEqual(threadstate.status_of(child), "needs")
        self.assertEqual(len(threadstate.active_threads({"threads": [child]})), 1)

    def test_a_settled_thread_with_a_non_blocking_question_stays_closed(self):
        settled = thread(settledAt="2026-01-01T00:00:00Z", pendingRuntimeRequest={"kind": "user_input", "blocking": False})
        self.assertEqual(threadstate.active_threads({"threads": [settled]}), [])

    def test_list_filters_and_sorts(self):
        rows = threadstate.active_threads({"threads": [
            thread(id="settled", settledAt="2026-01-01T00:00:00Z"),
            thread(id="child", lineage={"parentThreadId": "x"}),
            thread(id="archived", archivedAt="2026-01-01T00:00:00Z"),
            thread(id="old-done", updatedAt="2026-01-01T00:00:00Z"),
            thread(id="new-done", updatedAt="2026-06-01T00:00:00Z"),
            thread(id="busy", status="running"),
            thread(id="blocked-child", lineage={"parentThreadId": "x"}, pendingRuntimeRequest={"x": 1}),
        ]})
        self.assertEqual([r["id"] for r in rows], ["blocked-child", "busy", "new-done", "old-done"])


class Timeline(unittest.TestCase):
    def test_every_kind_of_item(self):
        rows = timeline.build_timeline([
            {"type": "user_message", "text": "go", "status": "completed", "ordinal": 1},
            {"type": "reasoning", "text": "thinking hard", "status": "completed", "ordinal": 2},
            {"type": "reasoning", "text": "", "status": "completed", "ordinal": 3},
            {"type": "command_execution", "input": "git status\nand more", "status": "failed", "ordinal": 4},
            {"type": "command_execution", "input": {"command": "ls"}, "status": "completed", "ordinal": 5},
            {"type": "dynamic_tool", "toolName": "mcp__t3_code__t3_preview_close", "title": "x", "status": "completed", "ordinal": 6},
            {"type": "file_change", "fileName": "/a/b/spec.html", "status": "completed", "ordinal": 7},
            {"type": "file_change", "fileName": "C:\\a\\b.lua", "status": "running", "ordinal": 8},
            {"type": "web_search", "patterns": ["https://x.ai"], "status": "completed", "ordinal": 9},
            {"type": "file_search", "title": "Searched files x", "status": "completed", "ordinal": 10},
            {"type": "subagent", "title": "Research", "status": "running", "ordinal": 11},
            {"type": "notification", "summary": "Build finished", "status": "completed", "ordinal": 12},
            {"type": "system_notice", "message": "Retrying", "status": "completed", "ordinal": 13},
            {"type": "compaction", "title": "Context compacted", "status": "completed", "ordinal": 14},
            {"type": "checkpoint", "status": "completed", "ordinal": 15},
            {"type": "todo_list", "steps": [{"text": "old", "status": "completed"}], "status": "completed", "ordinal": 16},
            {"type": "todo_list", "steps": [{"text": "a", "status": "completed"}, {"text": "b", "status": "in_progress"}, {"text": "c"}],
             "status": "running", "ordinal": 17},
            {"type": "user_input_request", "questions": [{"question": "Old?"}], "status": "completed", "ordinal": 18},
            {"type": "user_input_request", "questions": [{"question": "Which?", "options": [{"label": "Red"}]}], "status": "running", "ordinal": 19},
            {"type": "future_kind_of_thing", "title": "Something new", "status": "completed", "ordinal": 20},
            {"type": "future_kind_with_no_words", "status": "completed", "ordinal": 21},
            {"type": "assistant_message", "text": "done", "status": "completed", "ordinal": 22},
        ])
        self.assertEqual([row[0:3] for row in rows], [
            ["u", "go", "d"],
            ["t", "thinking hard", "d"],
            ["s", "Ran git status", "f"],
            ["s", "Ran ls", "d"],
            ["s", "t3_preview_close", "d"],
            ["s", "Edited spec.html", "d"],
            ["s", "Edited b.lua", "r"],
            ["s", "Searched the web: https://x.ai", "d"],
            ["s", "Searched files x", "d"],
            ["sa", "Research", "r"],
            ["n", "Build finished", "d"],
            ["n", "Retrying", "d"],
            ["n", "Context compacted", "d"],
            ["d", "[x] a\n[>] b\n[ ] c", "r"],
            ["n", "Asked: Old?", "d"],
            ["q", "Which?\n- Red", "r"],
            ["s", "Something new", "d"],
            ["a", "done", "d"],
        ])

    def test_oldest_first_whatever_order_t3_sends(self):
        rows = timeline.build_timeline([{"type": "assistant_message", "text": "second", "ordinal": 9},
                                 {"type": "user_message", "text": "first", "ordinal": 2}])
        self.assertEqual([row[1] for row in rows], ["first", "second"])

    def test_keeps_the_last_messages_and_the_work_after_them(self):
        items = [{"type": "assistant_message", "text": f"m{n}", "ordinal": n * 2} for n in range(1, 41)]
        items += [{"type": "reasoning", "text": f"t{n}", "ordinal": n * 2 + 1} for n in range(1, 41)]
        rows = timeline.build_timeline(items)
        self.assertEqual(sum(row[0] == "a" for row in rows), settings.MESSAGES_PER_THREAD)
        self.assertEqual(rows[0][1], "m11")
        self.assertEqual(rows[-1][1], "t40")

    def test_a_long_step_label_is_one_line_but_thinking_is_whole(self):
        long = "x" * 5000
        rows = timeline.build_timeline([{"type": "command_execution", "input": long, "ordinal": 1},
                                 {"type": "reasoning", "text": long, "ordinal": 2}])
        self.assertLess(len(rows[0][1]), 250)
        self.assertEqual(rows[1][1], long)

    def test_what_it_is_doing_now(self):
        cases = [
            ({"type": "reasoning", "status": "running"}, "Thinking"),
            ({"type": "assistant_message", "status": "running"}, "Writing a reply"),
            ({"type": "assistant_message", "streaming": True, "status": "completed"}, "Writing a reply"),
            ({"type": "command_execution", "input": "x", "status": "running"}, "Running a command"),
            ({"type": "file_change", "fileName": "/a/b.py", "status": "running"}, "Editing b.py"),
            ({"type": "web_search", "status": "running"}, "Searching the web"),
            ({"type": "file_search", "status": "running"}, "Searching files"),
            ({"type": "user_input_request", "status": "running"}, "Waiting for your answer"),
            ({"type": "subagent", "title": "Scout", "status": "running"}, "Agent: Scout"),
            ({"type": "reasoning", "status": "completed"}, "Working"),
        ]
        for item, words in cases:
            self.assertEqual(timeline.doing_now([item]), words)

    def test_the_newest_running_thing_wins(self):
        self.assertEqual(timeline.doing_now([{"type": "subagent", "title": "Scout", "status": "running", "ordinal": 1},
                                      {"type": "reasoning", "status": "running", "ordinal": 2}]), "Thinking")

    def test_context_use_is_a_percentage(self):
        detail = timeline.describe_thread({"turnItems": [], "providerThreads": [
            {"contextUsage": {"usedTokens": 1, "maxTokens": 10}},
            {"contextUsage": {"usedTokens": 708568, "maxTokens": 1000000}},
        ]})
        self.assertEqual(detail["context"], 71)

    def test_no_context_data_is_fine(self):
        self.assertIsNone(timeline.describe_thread({"turnItems": [], "providerThreads": [{"contextUsage": None}]})["context"])

    def test_transcript_only_threads_still_work(self):
        detail = timeline.describe_thread({"messages": [{"role": "assistant", "text": "b", "createdAt": "2"},
                                                 {"role": "user", "text": "a", "createdAt": "1"}]})
        self.assertEqual([row[:2] for row in detail["rows"]], [["u", "a"], ["a", "b"]])

    def test_a_queued_message_already_in_the_timeline_is_not_doubled(self):
        detail = timeline.describe_thread({
            "turnItems": [{"type": "user_message", "text": "x", "messageId": "m1", "ordinal": 1}],
            "runs": [{"id": "r", "status": "queued"}],
            "messages": [{"id": "m1", "runId": "r", "role": "user", "text": "x"}],
        })
        self.assertEqual(len(detail["rows"]), 1)


def in_a_while(seconds=3600):
    return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() + seconds))


class ParkedThreads(unittest.TestCase):
    def build(self, *threads, **extra):
        shell = {"threads": list(threads), "projects": [{"id": "p1", "title": "Shop"}]}
        return snapshots.build_snapshot(shell, {}, url="u", error="", error_since=0, ack=0, results={}, **extra)

    def test_a_snoozed_thread_moves_out_of_the_list(self):
        snapshot = self.build(thread(id="awake"), thread(id="asleep", snoozedUntil=in_a_while()))
        self.assertEqual([row["id"] for row in snapshot["threads"]], ["awake"])
        self.assertEqual([(row["id"], row["pk"]) for row in snapshot["pk"]], [("asleep", "z")])
        self.assertGreater(snapshot["pk"][0]["zu"], time.time())
        self.assertEqual(snapshot["tc"], 1, "a snoozed thread isn't one the list left out")

    def test_a_snooze_that_ran_out_is_back_in_the_list(self):
        snapshot = self.build(thread(id="woke", snoozedUntil="2020-01-01T00:00:00.000Z"))
        self.assertEqual([row["id"] for row in snapshot["threads"]], ["woke"])
        self.assertEqual(snapshot["pk"], [])

    def test_what_wants_you_stays_up_top_even_snoozed(self):
        snapshot = self.build(thread(id="asks", snoozedUntil=in_a_while(), pendingRuntimeRequest={"kind": "approval", "blocking": True}))
        self.assertEqual([row["id"] for row in snapshot["threads"]], ["asks"])
        self.assertEqual(snapshot["pk"], [])

    def test_settled_threads_are_listed_newest_first_and_capped(self):
        settled = [thread(id=f"s{i:02d}", settledAt=f"2026-11-02T10:{i:02d}:00.000Z") for i in range(settings.MAX_PARKED_ROWS + 5)]
        snapshot = self.build(*settled)
        self.assertEqual(snapshot["threads"], [])
        self.assertEqual(len(snapshot["pk"]), settings.MAX_PARKED_ROWS)
        self.assertEqual(snapshot["pk"][0]["id"], f"s{settings.MAX_PARKED_ROWS + 4:02d}")
        self.assertTrue(all(row["pk"] == "s" for row in snapshot["pk"]))

    def test_children_and_archived_threads_stay_out(self):
        snapshot = self.build(thread(id="kid", settledAt="2026-11-02T10:00:00.000Z", lineage={"parentThreadId": "x"}),
                              thread(id="gone", settledAt="2026-11-02T10:00:00.000Z", archivedAt="2026-11-02T11:00:00.000Z"))
        self.assertEqual(snapshot["pk"], [])

    def test_a_hidden_parked_thread_says_only_its_title(self):
        snapshot = self.build(thread(id="secret", settledAt="2026-11-02T10:00:00.000Z", branch="b", modelSelection={"model": "m"}),
                              hidden={"projects": [], "threads": ["secret"]})
        row = snapshot["pk"][0]
        self.assertTrue(row["hd"])
        self.assertEqual(sorted(row), sorted(["id", "p", "t", "s", "u", "pk", "hd"]))

    def test_an_outage_keeps_them_on_screen(self):
        previous = {"threads": [], "pk": [{"id": "a", "pk": "s", "vm": [["a", "words"]]}]}
        snapshot = snapshots.build_snapshot(None, {}, url="u", error="down", error_since=1, ack=0, results={}, previous=previous)
        self.assertEqual(snapshot["pk"], [{"id": "a", "pk": "s"}], "what you opened only stays for a minute")


class Secrets(unittest.TestCase):
    def test_common_secrets_are_hidden_from_everything_sent_to_the_game(self):
        for secret in ("sk-abcdefghijklmnopqrstuvwxyz123456", "ghp_abcdefghijklmnopqrstuvwxyz1234", "AKIAIOSFODNN7EXAMPLE",
                       "xoxb-1234567890-abcdefgh", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTYifQ.abcdefghij"):
            self.assertNotIn(secret, gametext.message_text(f"here it is: {secret} ok"))
            self.assertIn("[hidden secret]", gametext.message_text(f"here it is: {secret} ok"))
            self.assertNotIn(secret, gametext.readable(f"title {secret}"))

    def test_private_keys_go_whole(self):
        text = "before\n-----BEGIN RSA PRIVATE KEY-----\nabc\ndef\n-----END RSA PRIVATE KEY-----\nafter"
        self.assertEqual(gametext.message_text(text), "before\n[hidden secret]\nafter")

    def test_assignments_lose_their_value_and_keep_their_name(self):
        hidden = gametext.message_text('API_KEY=abcdef123456\npassword: "hunter2hunter"\nDB_PASSWORD = s3cretvalue')
        self.assertNotIn("abcdef123456", hidden)
        self.assertNotIn("hunter2hunter", hidden)
        self.assertNotIn("s3cretvalue", hidden)
        self.assertIn("API_KEY=[hidden secret]", hidden)

    def test_ordinary_code_reads_as_before(self):
        for line in ("token = get_token()", "password = input()", "the secret to this is patience", "self.key = key", "apiKey: props.apiKey"):
            self.assertEqual(gametext.message_text(line), line)

    def test_secret_files_never_reach_the_game(self):
        for path in (".env", ".env.production", "config/.env.local", "certs/server.pem", "id_rsa", "deploy/secrets.yaml", "aws/credentials", ".npmrc"):
            diff = f"diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n@@ -0,0 +1 @@\n+top_value\n"
            files = split_diff(diff)
            self.assertEqual(files[0][:6], [path, 1, 0, "", True, True], path)

    def test_examples_of_secret_files_are_fine(self):
        diff = "diff --git a/.env.example b/.env.example\n--- a/.env.example\n+++ b/.env.example\n@@ -0,0 +1 @@\n+NAME=\n"
        self.assertEqual(len(split_diff(diff)[0]), 5)

    def test_a_secret_file_cant_be_asked_for_by_page(self):
        files = diffs.parse_diff("diff --git a/.env b/.env\n--- a/.env\n+++ b/.env\n@@ -0,0 +1 @@\n+top_value\n")
        self.assertIsNone(files[0][3])


class SubagentsAndChanges(unittest.TestCase):
    def test_agents_list_newest_first_without_their_words(self):
        rows, words = timeline.describe_agents([
            {"id": "a", "title": "Old", "status": "completed", "startedAt": "2026-01-01T00:00:00Z", "model": "gpt-6-astra", "prompt": "the-brief", "result": "the-report"},
            {"id": "b", "title": "New", "status": "running", "startedAt": "2026-01-02T00:00:00Z", "driver": "codex"},
        ])
        self.assertEqual([row[1:4] for row in rows], [["New", "r", "codex"], ["Old", "d", "gpt-6-astra"]])
        self.assertNotIn("the-brief", json.dumps(rows))
        self.assertEqual(words[rows[1][0]], ["the-brief", "the-report"])
        self.assertEqual(words[rows[0][0]], ["", ""])

    def test_agent_list_is_capped_but_counted(self):
        agents = [{"id": str(n), "title": f"A{n}", "status": "completed"} for n in range(50)]
        detail = timeline.describe_thread({"subagents": agents})
        self.assertEqual(len(detail["agents"]), settings.MAX_AGENTS)
        self.assertEqual(detail["agents_total"], 50)

    def test_agents_survive_being_written_for_the_game(self):
        rows, words = timeline.describe_agents([{"id": "1", "title": "A", "status": "completed", "prompt": "p", "result": "r"}])
        self.assertIn('={"p","r"}', luadata.lua_value({"ax": words}))

    def test_subagent_row(self):
        rows = timeline.build_timeline([{"type": "subagent", "title": "Review", "status": "completed", "ordinal": 5, "result": "## Done", "prompt": "secret prompt"}])
        self.assertEqual(rows, [["sa", "Review", "d", 5, "## Done"]])

    def test_a_working_subagent_has_no_result_yet(self):
        rows = timeline.build_timeline([{"type": "subagent", "title": "Scout", "status": "running", "ordinal": 5}])
        self.assertEqual(rows, [["sa", "Scout", "r", 5, ""]])

    def test_checkpoint_says_what_changed(self):
        rows = timeline.build_timeline([{"type": "checkpoint", "ordinal": 2, "status": "completed", "files": [
            {"path": "a", "additions": 3, "deletions": 1}, {"path": "b", "additions": 2, "deletions": 0}]}])
        self.assertEqual(rows[0][:2], ["n", "2 files changed  +5 -1"])
        one = timeline.build_timeline([{"type": "checkpoint", "ordinal": 2, "files": [{"path": "a", "additions": 1, "deletions": 1}]}])
        self.assertEqual(one[0][1], "1 file changed  +1 -1")

    def test_empty_checkpoint_says_nothing(self):
        self.assertEqual(timeline.build_timeline([{"type": "checkpoint", "ordinal": 2, "files": []}]), [])

    def test_turns_are_the_last_finished_run(self):
        detail = timeline.describe_thread({"runs": [{"ordinal": 5, "status": "completed"}, {"ordinal": 7, "status": "completed"}, {"ordinal": 8, "status": "running"}]})
        self.assertEqual(detail["turns"], 7)
        self.assertEqual(timeline.describe_thread({})["turns"], 0)

    def test_t3_being_able_to_diff_is_known_beyond_the_recent_window(self):
        # The recent items show no checkpoint at all, but T3 can still diff the whole thread.
        detail = timeline.describe_thread({"runs": [{"id": "r1", "status": "completed", "ordinal": 3}],
                                    "checkpoints": [{"runId": "r1", "status": "ready", "appRunOrdinal": 3, "files": []}]})
        self.assertEqual(detail["changes"], [])
        self.assertTrue(detail["can_diff"])
        self.assertFalse(timeline.describe_thread({})["can_diff"])
        self.assertFalse(timeline.describe_thread({"runs": [{"id": "r1", "status": "running"}],
                                            "checkpoints": [{"runId": "r1", "status": "ready", "appRunOrdinal": 1}]})["can_diff"])

    def test_the_last_change_is_the_newest_checkpoint_with_files(self):
        detail = timeline.describe_thread({"turnItems": [
            {"type": "checkpoint", "ordinal": 2, "files": [{"path": "a", "additions": 1, "deletions": 1}]},
            {"type": "checkpoint", "ordinal": 3, "files": [{"path": "b", "additions": 5, "deletions": 2}, {"path": "c", "additions": 1}]},
            {"type": "checkpoint", "ordinal": 4, "files": []},
        ]})
        self.assertEqual(detail["last_change"], [2, 6, 2, 3])
        self.assertIsNone(timeline.describe_thread({})["last_change"])

    def test_changes_list_the_newest_numbers(self):
        detail = timeline.describe_thread({"turnItems": [
            {"type": "checkpoint", "ordinal": 2, "files": [{"path": "a", "kind": "modified", "additions": 1, "deletions": 0}]},
            {"type": "checkpoint", "ordinal": 3, "files": [{"path": "a", "kind": "modified", "additions": 9, "deletions": 4}, {"path": "b", "additions": 1}]},
        ]})
        self.assertEqual(detail["changes"], [["a", "modified", 9, 4], ["b", "modified", 1, 0]])


if __name__ == "__main__":
    unittest.main(verbosity=1)
