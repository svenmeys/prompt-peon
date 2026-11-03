"""Replies read from the saved file, and each one only ever being sent once."""
import unittest

from bridge_helpers import Base, Crash, FakeRemote, SHELL, THREAD, outbox
from promptpeon import delivery, savedvars, settings, t3errors


class Outbox(Base):
    def test_good_entry(self):
        entries, rejected = savedvars.parse_outbox(outbox((3, THREAD, "héllo")))
        self.assertEqual(entries, [{"seq": 3, "thread": THREAD, "text": "héllo"}])
        self.assertEqual(rejected, [])

    def test_never_runs_lua(self):
        self.assertEqual(savedvars.parse_outbox('os.execute("x")\nPromptPeonDB = {}\n'), ([], []))

    def test_malformed_rejected_not_guessed(self):
        hex_thread = THREAD.encode().hex()
        text = f'PromptPeonOutbox = "abc;1:{hex_thread}:zz;2:short:6869;3:{hex_thread}:6869"\n'
        entries, rejected = savedvars.parse_outbox(text)
        self.assertEqual([e["seq"] for e in entries], [3])
        self.assertEqual(len(rejected), 3)

    def test_invalid_utf8_rejected(self):
        entries, rejected = savedvars.parse_outbox(f'PromptPeonOutbox = "1:{THREAD.encode().hex()}:ff"\n')
        self.assertEqual(entries, [])
        self.assertEqual(len(rejected), 1)

    def test_draft_cannot_spoof_the_real_global(self):
        # A line inside the DB table that looks like the outbox, then the real, empty one.
        fake = f'PromptPeonOutbox = "1:{THREAD.encode().hex()}:6869"\n'
        entries, _ = savedvars.parse_outbox(fake + 'PromptPeonOutbox = ""\n')
        self.assertEqual(entries, [])

    def test_huge_outbox_ignored(self):
        entries, rejected = savedvars.parse_outbox(f'PromptPeonOutbox = "{"a" * (settings.MAX_OUTBOX_CHARS + 1)}"\n')
        self.assertEqual(entries, [])
        self.assertEqual(len(rejected), 1)


class Dispatch(Base):
    def test_sends_once_across_restarts(self):
        remote = FakeRemote()
        first = self.bridge(remote)
        delivery.dispatch(first, outbox((1, THREAD, "hello")))
        self.assertEqual(remote.sent, [(THREAD, "hello")])
        delivery.dispatch(first, outbox((1, THREAD, "hello")))
        delivery.dispatch(self.bridge(remote), outbox((1, THREAD, "hello")))
        self.assertEqual(len(remote.sent), 1)

    def _crash_during_send(self, remote):
        first = self.bridge(remote)
        remote.crash_after_send = True
        with self.assertRaises(Crash):
            delivery.dispatch(first, outbox((1, THREAD, "hello")))
        remote.crash_after_send = False
        return remote.last_message_id

    def test_crash_after_t3_got_it_does_not_send_twice(self):
        remote = FakeRemote()
        message_id = self._crash_during_send(remote)
        self.assertTrue(message_id, "the id must be chosen and saved before sending")
        remote.known_messages = {message_id}
        restarted = self.bridge(remote)
        delivery.dispatch(restarted, outbox((1, THREAD, "hello")))
        self.assertEqual(len(remote.sent), 1, "T3 already has it")
        self.assertEqual(restarted.state["results"]["1"], "sent")
        self.assertEqual(restarted.state["ack"], 1)

    def test_crash_before_t3_got_it_resends_with_the_same_id(self):
        remote = FakeRemote()
        message_id = self._crash_during_send(remote)
        remote.known_messages = set()
        restarted = self.bridge(remote)
        delivery.dispatch(restarted, outbox((1, THREAD, "hello")))
        self.assertEqual(len(remote.sent), 2)
        self.assertEqual(remote.last_message_id, message_id, "the same id, so T3 can tell it is one message")
        self.assertEqual(restarted.state["results"]["1"], "sent")

    def test_crash_and_t3_cannot_be_asked_never_resends(self):
        remote = FakeRemote()
        self._crash_during_send(remote)
        remote.lookup_fails = True
        restarted = self.bridge(remote)
        delivery.dispatch(restarted, outbox((1, THREAD, "hello")))
        self.assertEqual(len(remote.sent), 1)
        self.assertIn("unknown", restarted.state["results"]["1"])

    def test_nothing_stays_in_flight_after_a_normal_send(self):
        bridge = self.bridge(FakeRemote())
        delivery.dispatch(bridge, outbox((1, THREAD, "hello")))
        self.assertNotIn("inflight", bridge.state)

    def test_outcomes_of_a_big_batch_are_kept(self):
        remote = FakeRemote()
        bridge = self.bridge(remote)
        entries = [(1, "aaaaaaaa-1111", "this one fails")] + [(n, THREAD, "x") for n in range(2, 30)]
        delivery.dispatch(bridge, outbox(*entries))
        self.assertIn("failed", bridge.state["results"]["1"], "the first outcome must survive the batch")

    def test_unknown_thread_refused(self):
        remote = FakeRemote()
        bridge = self.bridge(remote)
        delivery.dispatch(bridge, outbox((1, "aaaaaaaa-1111", "hello")))
        self.assertEqual(remote.sent, [])
        self.assertIn("not on this T3 server", bridge.state["results"]["1"])

    def test_oversized_refused(self):
        remote = FakeRemote()
        bridge = self.bridge(remote)
        delivery.dispatch(bridge, outbox((1, THREAD, "x" * (settings.MAX_REPLY_BYTES + 1))))
        self.assertEqual(remote.sent, [])
        self.assertIn("failed", bridge.state["results"]["1"])

    def test_uncertain_send_is_not_retried(self):
        remote = FakeRemote(send=t3errors.SendUncertain("lost it"))
        bridge = self.bridge(remote)
        delivery.dispatch(bridge, outbox((1, THREAD, "hello")))
        self.assertIn("unknown", bridge.state["results"]["1"])
        remote._send = None
        delivery.dispatch(bridge, outbox((1, THREAD, "hello")))
        self.assertEqual(remote.sent, [])

    def test_mac_down_holds_the_reply(self):
        remote = FakeRemote(shell=OSError("no route"))
        bridge = self.bridge(remote)
        delivery.dispatch(bridge, outbox((1, THREAD, "hello")))
        self.assertEqual(bridge.state["ack"], 0)
        remote._shell = SHELL
        delivery.dispatch(bridge, outbox((1, THREAD, "hello")))
        self.assertEqual(remote.sent, [(THREAD, "hello")])

    def test_rate_limit(self):
        remote = FakeRemote()
        bridge = self.bridge(remote)
        delivery.dispatch(bridge, outbox(*[(n, THREAD, "x") for n in range(1, settings.MAX_SENDS_PER_MINUTE + 3)]))
        self.assertEqual(len(remote.sent), settings.MAX_SENDS_PER_MINUTE)

    def test_audit_has_no_reply_text(self):
        bridge = self.bridge(FakeRemote())
        delivery.dispatch(bridge, outbox((1, THREAD, "very private words")))
        log = bridge.audit_path.read_text()
        self.assertIn('"sent"', log)
        self.assertNotIn("private", log)


if __name__ == "__main__":
    unittest.main(verbosity=1)
