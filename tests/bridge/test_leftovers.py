"""Small behaviours that didn't fit elsewhere."""
import os
import unittest
import urllib.error
from unittest import mock

from bridge_helpers import Base, FakeRemote, ROOT, THREAD, outbox, thread
from promptpeon import addonfiles, bridgestate, delivery, pngtga, previews, publishing, refreshing, safefiles, savedvars


class Leftovers(Base):
    def make(self, remote=None):
        return bridgestate.Bridge(self.wow, remote or FakeRemote(shell={"threads": [thread()], "projects": []}),
                        state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json")

    def test_an_outage_does_not_keep_what_you_opened(self):
        bridge = self.make()
        refreshing.refresh(bridge)
        bridge.keep_loaded(THREAD, df=[["x", 1, 0, "+FAKE_SECRET", True]], dn="", ax={"k": ["a", "FAKE_SECRET"]})
        publishing.publish(bridge)
        self.assertIn("FAKE_SECRET", bridge.snapshot_path.read_text())
        bridge.shell = None
        bridge.loaded.clear()
        publishing.publish(bridge)
        self.assertNotIn("FAKE_SECRET", bridge.snapshot_path.read_text())

    def test_closing_the_game_clears_its_folder(self):
        addonfiles.install_addon(self.wow, ROOT / "addon/PromptPeon")
        bridge = self.make()
        refreshing.refresh(bridge)
        bridge.state["ack"] = 7
        publishing.publish(bridge)
        self.assertIn("A thread", bridge.snapshot_path.read_text())
        picture = bridge.previews.folder / "p01.tga"
        picture.write_bytes(b"x" * 5000)
        bridge.previews.ready["k"] = {"file": 1, "w": 1, "h": 1}
        publishing.go_quiet(bridge)
        text = bridge.snapshot_path.read_text()
        self.assertNotIn("A thread", text)
        self.assertIn("quiet=true", text)
        self.assertIn("ack=7", text, "unsent messages can still be settled")
        self.assertEqual(picture.read_bytes(), pngtga.blank_tga())
        self.assertEqual(bridge.previews.ready, {})
        bridge.game_closed = False  # The run loop does this when the game opens.
        refreshing.refresh(bridge)
        self.assertIn("A thread", bridge.snapshot_path.read_text(), "and it comes back")

    def test_a_damaged_picture_is_only_one_bad_picture(self):
        class Bad(FakeRemote):
            def image_bytes(self, *_):
                return b"\x89PNG\r\n\x1a\n\x00\x00\x00\x01IHDRx"

        picture_files = previews.Previews(self.dir / "pics", Bad())
        (self.dir / "pics").mkdir()
        picture_files.waiting.put(("t", "k", {"a": "1"}))
        self.assertTrue(picture_files.process_one())
        self.assertIn("error", picture_files.ready["k"])

    def test_saying_no_to_pictures_sticks_whatever_the_token_can_do(self):
        picture_files = previews.Previews(self.dir / "pics", FakeRemote(), allow_files=False)
        rows = picture_files.prepare("t", [["i", "x", "d", 1, {"p": "/private/payroll.png"}]], True)
        self.assertIn("file access", rows[0][7])
        self.assertTrue(picture_files.waiting.empty(), "nothing was asked for")
        rows = picture_files.prepare("t", [["i", "x", "d", 2, {"a": "attachment-1", "n": "x.png"}]], True)
        self.assertFalse(picture_files.waiting.empty(), "attachments don't need file access")

    def test_a_failed_detail_fetch_is_tried_again(self):
        class Flaky(FakeRemote):
            calls = 0

            def detail(self, thread_id):
                Flaky.calls += 1
                if Flaky.calls == 1:
                    raise urllib.error.HTTPError("u", 503, "busy", {}, None)
                return {"rows": [["a", "words", "d", 1]]}

        bridge = self.make(Flaky(shell={"threads": [thread()], "projects": []}))
        refreshing.refresh(bridge)
        refreshing.refresh(bridge)
        self.assertEqual(bridge.snapshot["threads"][0]["m"], [["a", "words", "d", 1]])

    def test_a_refused_snapshot_write_is_tried_again_right_away(self):
        bridge = bridgestate.Bridge(self.wow, FakeRemote(shell={"threads": [thread()], "projects": []}), state_dir=self.dir / "state",
                          in_place=True, config_path=self.dir / "config.json")
        bridge.snapshot_path.parent.mkdir(parents=True, exist_ok=True)
        bridge.snapshot_path.write_text("old")
        refreshing.refresh(bridge)
        calls = []
        with mock.patch.object(safefiles, "write_in_place", side_effect=lambda *_: calls.append(1) or False):
            bridge.state["ack"] = 5
            publishing.publish(bridge)
            publishing.publish(bridge)
        self.assertEqual(len(calls), 2)

    def test_snapshots_carry_who_wrote_them_and_in_what_order(self):
        bridge = self.make()
        refreshing.refresh(bridge)
        first = bridge.snapshot["rv"]
        bridge.state["ack"] = 5
        publishing.publish(bridge)
        self.assertGreater(bridge.snapshot["rv"], first)
        self.assertEqual(bridge.snapshot["sid"], bridge.session)

    def test_results_go_out_before_the_slow_refresh(self):
        bridge = self.make()
        refreshing.refresh(bridge)
        order = []
        real_publish = publishing.publish
        real_refresh = refreshing.refresh
        with mock.patch.object(publishing, "publish", lambda given: (order.append("publish"), real_publish(given))[1]), \
                mock.patch.object(refreshing, "refresh", lambda given: (order.append("refresh"), real_refresh(given))[1]):
            delivery.deliver(bridge, [{"seq": 1, "thread": THREAD, "text": "hi"}])
        self.assertEqual(order[:2], ["publish", "refresh"])

    def test_an_outbox_that_cant_be_read_yet_is_read_later(self):
        bridge = self.make()
        path = self.wow / "WTF/Account/A/SavedVariables/PromptPeon.lua"
        path.parent.mkdir(parents=True)
        path.write_text(outbox((1, THREAD, "hello")))
        os.utime(path, (100, 100))
        with mock.patch.object(safefiles, "read_shared", side_effect=OSError("locked")):
            delivery.poll_outbox(bridge)
        self.assertEqual(bridge.remote.sent, [])
        delivery.poll_outbox(bridge)
        self.assertEqual(len(bridge.remote.sent), 1)

    def test_every_account_file_gets_read_oldest_first(self):
        bridge = self.make()
        for name, seq, stamp in (("A", 1, 100), ("B", 2, 200)):
            path = self.wow / "WTF/Account" / name / "SavedVariables/PromptPeon.lua"
            path.parent.mkdir(parents=True)
            path.write_text(outbox((seq, THREAD, name)))
            os.utime(path, (stamp, stamp))
        delivery.poll_outbox(bridge)
        self.assertEqual([text for _, text in bridge.remote.sent], ["A", "B"])

    def test_a_thread_id_with_colons_gets_through(self):
        for thread_id in ("import:codex:abcdefgh", "thread:mcp:42", "short"):
            entries, rejected = savedvars.parse_outbox(outbox((1, thread_id, "hi")))
            self.assertEqual((entries[0]["thread"], rejected), (thread_id, []))
        for bad in ("has space", "has|pipe", "x" * 201):
            self.assertFalse(savedvars.good_thread_id(bad))


if __name__ == "__main__":
    unittest.main(verbosity=1)
