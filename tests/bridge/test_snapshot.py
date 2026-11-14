"""The snapshot the game loads."""
import subprocess
import time
import unittest
import urllib.error

from bridge_helpers import Base, FakeRemote, ROOT, THREAD, needs_luajit, thread
from promptpeon import gametext, luadata, refreshing, settings, snapshots, t3remote, timeline


class Snapshot(Base):
    def test_outage_keeps_previous_threads(self):
        previous = {"threads": [{"id": "x"}]}
        snap = snapshots.build_snapshot(None, {}, url="u", error="down", error_since=5, ack=0, results={}, previous=previous)
        self.assertEqual(snap["threads"], previous["threads"])
        self.assertEqual(snap["err"], "down")

    def test_refresh_reports_outage_and_writes_file(self):
        bridge = self.bridge(FakeRemote(shell=OSError("no route")))
        refreshing.refresh(bridge)
        self.assertIn("Can't reach", bridge.error)
        self.assertIn("Can't reach", bridge.snapshot_path.read_text())

    def test_the_thread_reaches_the_game_but_tool_output_does_not(self):
        bridge = self.bridge(FakeRemote())
        refreshing.refresh(bridge)
        text = bridge.snapshot_path.read_text()
        for wanted in ('"hi"', '"**done**"', '"my thoughts"', '"Ran ls -la"'):
            self.assertIn(wanted, text)
        self.assertNotIn("SECRET OUTPUT", text)

    def test_unchanged_data_is_not_rewritten_until_the_heartbeat(self):
        bridge = self.bridge(FakeRemote())
        refreshing.refresh(bridge)
        first = bridge.snapshot_path.stat().st_mtime_ns
        time.sleep(0.02)
        refreshing.refresh(bridge)
        self.assertEqual(bridge.snapshot_path.stat().st_mtime_ns, first, "nothing changed")
        bridge.last_write_at -= settings.HEARTBEAT_SECONDS + 1
        refreshing.refresh(bridge)
        self.assertNotEqual(bridge.snapshot_path.stat().st_mtime_ns, first, "the heartbeat writes anyway")

    def test_a_real_change_is_written_straight_away(self):
        bridge = self.bridge(FakeRemote())
        refreshing.refresh(bridge)
        bridge.remote._shell = {"threads": [thread(title="Renamed")], "projects": []}
        refreshing.refresh(bridge)
        self.assertIn("Renamed", bridge.snapshot_path.read_text())

    def test_activity_reaches_the_game(self):
        class Busy(FakeRemote):
            def detail(self, thread_id):
                return timeline.describe_thread({
                    "turnItems": [{"type": "reasoning", "text": "hmm", "status": "running", "ordinal": 1}],
                    "runs": [{"id": "r2", "status": "queued"}],
                    "messages": [{"id": "m2", "runId": "r2", "role": "user", "text": "next please"}],
                })

        shell = {"threads": [thread(status="running", activityRunStartedAt="2026-11-02T16:00:00.000Z")], "projects": []}
        bridge = self.bridge(Busy(shell=shell))
        refreshing.refresh(bridge)
        row = bridge.snapshot["threads"][0]
        self.assertEqual(row["a"], "Thinking")
        self.assertGreater(row["as"], 0)
        self.assertEqual(row["qc"], 1)
        self.assertIn(["u", "next please", "q", 0, "r2"], row["m"])

    def test_waiting_on_another_thread_is_named(self):
        shell = {"threads": [thread(status="running", blockedOnThreadWait=True)], "projects": []}
        bridge = self.bridge(FakeRemote(shell=shell))
        refreshing.refresh(bridge)
        self.assertEqual(bridge.snapshot["threads"][0]["a"], "Waiting on another thread")

    def test_needs_says_how_to_answer(self):
        shell = {"threads": [
            thread(id="ask-thread", pendingRuntimeRequest={"kind": "user_input", "blocking": False}),
            thread(id="approve-thread", pendingRuntimeRequest={"kind": "approval", "blocking": True}),
        ], "projects": []}
        bridge = self.bridge(FakeRemote(shell=shell))
        refreshing.refresh(bridge)
        rows = {row["id"]: row for row in bridge.snapshot["threads"]}
        self.assertEqual(rows["ask-thread"]["a"], "Waiting for your answer")
        self.assertTrue(rows["ask-thread"]["nb"])
        self.assertEqual(rows["approve-thread"]["a"], "Waiting for your approval")
        self.assertNotIn("nb", rows["approve-thread"])

    def test_one_odd_thread_does_not_break_the_log(self):
        shell = {"threads": [thread(id="odd"), thread(id="fine-thread")], "projects": []}
        bridge = self.bridge(FakeRemote(shell=shell))
        refreshing.refresh(bridge)
        self.assertEqual(bridge.error, "")
        self.assertEqual(len(bridge.snapshot["threads"]), 2)

    def test_real_route_failover(self):
        calls = []
        remote = t3remote.T3Remote("http://mac", "t")

        def request(path, **_):
            calls.append(path)
            if path.endswith("/bounded"):
                raise urllib.error.HTTPError("u", 404, "gone", None, None)
            return {"items": [{"item": {"type": "assistant_message", "text": "from transcript"}}]}

        remote._request = request
        self.assertEqual(remote.detail("abc")["rows"], [["a", "from transcript", "d", 0]])
        self.assertEqual(len(calls), 2)

    def test_real_route_orders_oldest_first(self):
        remote = t3remote.T3Remote("http://mac", "t")
        remote._request = lambda path, **_: {"projection": {"messages": [
            {"role": "assistant", "text": "second", "createdAt": "2026-01-02"},
            {"role": "user", "text": "first", "createdAt": "2026-01-01"},
        ]}}
        self.assertEqual([row[:2] for row in remote.detail("abc")["rows"]], [["u", "first"], ["a", "second"]])

    def test_token_never_reaches_the_game_folder(self):
        remote = FakeRemote()
        remote.token = "SECRET-TOKEN"
        bridge = self.bridge(remote)
        refreshing.refresh(bridge)
        for path in self.wow.rglob("*"):
            if path.is_file():
                self.assertNotIn(b"SECRET-TOKEN", path.read_bytes())  # Bytes, because the update bells are sound files.

    def test_readable(self):
        self.assertEqual(gametext.readable("**bold** `code` [a](http://b)\n```py\nx\n```"), "bold code a\n\nx")
        self.assertEqual(gametext.readable("ok 🎉"), "ok")
        self.assertEqual(gametext.readable("x" * 9000), "x" * 9000, "messages are never cut")
        self.assertEqual(gametext.readable("x" * 200, 120), "x" * 120 + "...", "titles may be")

    def test_long_messages_reach_the_game_whole(self):
        text = "\n".join(f"line {number} of a long answer" for number in range(1, 2000))

        class Long(FakeRemote):
            def detail(self, thread_id):
                return timeline.describe_thread({"turnItems": [{"type": "assistant_message", "text": text, "ordinal": 1}]})

        bridge = self.bridge(Long())
        refreshing.refresh(bridge)
        row = bridge.snapshot["threads"][0]
        self.assertEqual(row["m"][0][1], text)

    def test_every_listed_thread_gets_messages(self):
        shell = {"threads": [thread(id=f"thread-number-{n}") for n in range(settings.MAX_THREADS)], "projects": []}
        bridge = self.bridge(FakeRemote(shell=shell))
        refreshing.refresh(bridge)
        self.assertEqual(sum("m" in row for row in bridge.snapshot["threads"]), settings.MAX_THREADS)

    def test_message_text_keeps_markdown_and_loses_emoji(self):
        text = "## Head\n\n**b** `c`\n```py\n    keep spacing\n```\n| a | b |\nok 🎉 → done\n\n\n\nend"
        out = gametext.message_text(text)
        for kept in ("## Head", "**b** `c`", "```py", "    keep spacing", "| a | b |", "-> done", "\n\n\n\nend"):
            self.assertIn(kept, out)
        self.assertNotIn("🎉", out)
        self.assertEqual(gametext.message_text("x" * 9000), "x" * 9000)

    def test_unsafe_key_refused(self):
        with self.assertRaises(ValueError):
            luadata.lua_value({"a]=1;os.exit()--": 1})

    @needs_luajit
    def test_hostile_text_stays_data_under_luajit(self):
        evil = 'x" PWNED=1 --'
        snap = {"v": 1, "at": 1, "threads": [{
            "id": THREAD, "p": "Shop", "t": evil, "s": "done",
            "m": [["a", "]] PWNED=1 --\\"], ["a", "line one\nline two"], ["a", "|Hitem:1|h|cffff0000x"],
                  ["a", "Sven zegt: één café"]],
        }]}
        path = self.dir / "hostile.lua"
        path.write_text(snapshots.render_snapshot(snap), encoding="utf-8")
        self.assertLess(max(path.read_bytes()), 128, "file must be pure ASCII")
        run = subprocess.run(["luajit", "tests/test_addon.lua", str(path)], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)


class SnapshotBudget(unittest.TestCase):
    def test_nothing_gets_past_the_budget(self):
        big = "x" * 950_000
        rows = [{"id": str(n), "t": "t", "s": "done", "df": big} for n in range(5)]
        parked = [{"id": f"p{n}", "t": "t", "s": "done", "pk": "s", "pd": {"b": big}, "ob": [["a", big]]} for n in range(3)]
        snapshot = {"threads": rows, "pk": parked}
        snapshots.fit_snapshot(snapshot)
        self.assertLessEqual(len(luadata.lua_value(snapshot)), settings.MAX_SNAPSHOT_BYTES)

    def test_the_newest_keep_theirs_longest(self):
        big = "x" * 1_000_000
        rows = [{"id": str(n), "t": "t", "s": "done", "m": [["a", big]], "df": big} for n in range(5)]
        snapshot = {"threads": rows, "pk": []}
        snapshots.fit_snapshot(snapshot)
        self.assertLessEqual(len(luadata.lua_value(snapshot)), settings.MAX_SNAPSHOT_BYTES)
        self.assertEqual(rows[0]["m"], [["a", big]], "the first row is the most urgent")
        self.assertEqual(rows[-1]["m"], [settings.TOO_LONG_ROW])


if __name__ == "__main__":
    unittest.main(verbosity=1)
