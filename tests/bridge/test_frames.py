"""Replies arriving through AddOns.txt, checked against the addon's own encoder."""
import queue
import shutil
import subprocess
import time
import unittest

from bridge_helpers import Base, FakeRemote, ROOT, THREAD, addons_txt, needs_luajit, python_frames
from promptpeon import delivery, frames, safefiles


def addon_frames(seq, thread_id, text):
    """Frames from the addon's real encoder under luajit, or the same thing built here without it."""
    if shutil.which("luajit"):
        run = subprocess.run(["luajit", "tests/encode_frames.lua", str(seq), thread_id, text.encode().hex()],
                             cwd=ROOT, capture_output=True, text=True, check=True)
        return [bytes.fromhex(line) for line in run.stdout.split()]
    return python_frames(seq, thread_id, text)


class Frames(Base):
    @needs_luajit
    def test_this_test_encoder_matches_the_addon(self):
        for text in ["hi", "héllo wörld", "x" * 123]:
            self.assertEqual(python_frames(9, THREAD, text), addon_frames(9, THREAD, text))

    def assemble(self, sent_frames):
        assembler, result = frames.Reassembler(), None
        for frame in sent_frames:
            parsed = frames.parse_frame(addons_txt(frame))
            self.assertIsNotNone(parsed)
            result = assembler.feed(parsed) or result
        return result

    def test_addon_encoder_round_trip(self):
        for text in ["hi", "x" * 9, "x" * 10, "x" * 11, "héllo wörld, één café", "a|b\nline two", "y" * 4000]:
            got = self.assemble(addon_frames(7, THREAD, text))
            self.assertEqual(got, {"seq": 7, "thread": THREAD, "text": text})

    def test_big_seq_round_trip(self):
        self.assertEqual(self.assemble(addon_frames(70000, THREAD, "x"))["seq"], 70000)

    def test_all_clear_is_not_a_frame(self):
        self.assertIsNone(frames.parse_frame(addons_txt()))

    def test_flipped_bit_is_rejected(self):
        frame = bytearray(addon_frames(1, THREAD, "hello")[0])
        frame[5] ^= 0x10
        self.assertIsNone(frames.parse_frame(addons_txt(bytes(frame))))

    def test_missing_carrier_is_rejected(self):
        text = addons_txt(addon_frames(1, THREAD, "hello")[0]).replace("PromptPeonOut42:", "Something:")
        self.assertIsNone(frames.parse_frame(text))

    def test_a_frame_read_twice_is_harmless(self):
        frames = addon_frames(1, THREAD, "x" * 60)
        doubled = [frame for frame in frames for _ in range(2)]
        self.assertEqual(self.assemble(doubled)["text"], "x" * 60)

    def test_lost_frame_drops_the_reply(self):
        frames = addon_frames(1, THREAD, "x" * 60)
        self.assertIsNone(self.assemble(frames[:2] + frames[3:]))

    def test_resend_after_a_lost_frame_works(self):
        frames = addon_frames(1, THREAD, "x" * 60)
        self.assertEqual(self.assemble(frames[:2] + frames[3:] + frames)["text"], "x" * 60)

    def test_corrupt_message_is_rejected(self):
        # Valid frames carrying a body whose CRC-32 does not match.
        frames = addon_frames(1, THREAD, "x" * 25)
        other = addon_frames(1, THREAD, "y" * 25)
        self.assertIsNone(self.assemble(frames[:-1] + other[-1:]))

    def test_oversized_claim_is_dropped(self):
        body = bytes([1, 0, 0, 1, 8]) + b"abcd-123" + (9000).to_bytes(2, "big")
        chunk = body[:10]
        head = bytes([0x80]) + chunk
        frame = bytes([frames.crc8(head)]) + head
        next_chunk = body[10:] + bytes(10 - len(body[10:]))
        head2 = bytes([1]) + next_chunk
        frame2 = bytes([frames.crc8(head2)]) + head2
        assembler = frames.Reassembler()
        self.assertIsNone(assembler.feed(frame))
        self.assertIsNone(assembler.feed(frame2))
        self.assertIsNone(assembler.expect)

    def test_frames_flow_through_the_full_check_path(self):
        remote = FakeRemote()
        bridge = self.bridge(remote)
        message = self.assemble(addon_frames(1, THREAD, "from the game"))
        delivery.deliver(bridge, [message])
        delivery.deliver(bridge, [message])
        self.assertEqual(remote.sent, [(THREAD, "from the game")])

    def test_unknown_thread_from_frames_is_refused(self):
        remote = FakeRemote()
        bridge = self.bridge(remote)
        delivery.deliver(bridge, [{"seq": 1, "thread": "aaaaaaaa-1111", "text": "x"}])
        self.assertEqual(remote.sent, [])
        self.assertIn("not on this T3 server", bridge.state["results"]["1"])

    def test_reader_follows_a_live_file(self):
        folder = self.wow / "WTF/Account/ME/Realm/Char"
        folder.mkdir(parents=True)
        target = folder / "AddOns.txt"
        target.write_text(addons_txt())
        replies = queue.Queue()
        reader = frames.FrameReader(self.wow, replies)
        reader.start()
        self.assertTrue(reader.ready.wait(10), "reads the old file first, which must not count")
        for frame in addon_frames(5, THREAD, "live " * 40):
            safefiles.write_atomic(target, addons_txt(frame))
            time.sleep(0.04)
        safefiles.write_atomic(target, addons_txt())
        self.assertEqual(replies.get(timeout=3), {"seq": 5, "thread": THREAD, "text": ("live " * 40)})

    def test_reader_keeps_up_at_game_speed(self):
        """Ten replies at the addon's real pace, and resent the way the addon resends."""
        folder = self.wow / "WTF/Account/ME/Realm/Char"
        folder.mkdir(parents=True)
        target = folder / "AddOns.txt"
        target.write_text(addons_txt())
        replies = queue.Queue()
        reader = frames.FrameReader(self.wow, replies)
        reader.start()
        self.assertTrue(reader.ready.wait(10))
        resends = 0
        for seq in range(1, 11):
            text = f"reply {seq} " * 30
            for attempt in range(3):
                # The game rewrites the file in place, and the first frame is held a little longer.
                for index, frame in enumerate(addon_frames(seq, THREAD, text)):
                    target.write_text(addons_txt(frame))
                    time.sleep(0.12 if index == 0 else 0.04)
                target.write_text(addons_txt())
                try:
                    self.assertEqual(replies.get(timeout=1.5)["text"], text)
                    break
                except queue.Empty:
                    resends += 1
            else:
                self.fail(f"reply {seq} never arrived after three tries")
        print(f"game speed test: 10 replies, {resends} resends")
        self.assertLessEqual(resends, 2, "the reader is missing frames too often")


if __name__ == "__main__":
    unittest.main(verbosity=1)
