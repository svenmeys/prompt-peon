"""Pictures: decoding PNGs, and the fixed set of files the game shows them from."""
import struct
import unittest
import zlib

from bridge_helpers import Base, FakeImages, FakeRemote, ROOT, make_png, picture_row
from promptpeon import addonfiles, luadata, pngtga, previews, refreshing, settings, t3errors, timeline


class Images(Base):
    def test_every_filter_decodes_to_the_same_pixels(self):
        for kind in range(5):
            _, _, _, pixel = pngtga.decode_png(make_png(6, 5, filter_kind=kind))
            self.assertEqual(pixel(3, 2), (30, 20, 200, 255), f"filter {kind}")
            self.assertEqual(pixel(5, 4), (50, 40, 200, 255), f"filter {kind}")

    def test_colour_types(self):
        self.assertEqual(pngtga.decode_png(make_png(4, 2, colour=2))[3](2, 1), (20, 10, 200, 255))
        self.assertEqual(pngtga.decode_png(make_png(4, 2, colour=0))[3](2, 0), (20, 20, 20, 255))
        self.assertEqual(pngtga.decode_png(make_png(4, 2, colour=4))[3](2, 1), (20, 20, 20, 10))
        self.assertEqual(pngtga.decode_png(make_png(4, 2, colour=6, depth=16))[3](2, 1), (20, 10, 200, 255))
        palette = bytes([1, 2, 3, 4, 5, 6])
        self.assertEqual(pngtga.decode_png(make_png(4, 2, colour=3, palette=palette))[3](1, 0), (4, 5, 6, 255))

    def test_rejects_what_it_should(self):
        for bad, words in [(b"not a png", "not a PNG"),
                           (make_png(4, 4, interlace=1), "unusual"),
                           (pngtga.PNG_SIGNATURE + b"junk", "broken")]:
            with self.assertRaises(pngtga.ImageError) as caught:
                pngtga.decode_png(bad)
            self.assertIn(words, str(caught.exception))

    def test_a_huge_claimed_size_is_refused_before_unpacking(self):
        def chunk(kind, body):
            return struct.pack(">I", len(body)) + kind + body + b"\0\0\0\0"
        huge = pngtga.PNG_SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 100000, 100000, 8, 6, 0, 0, 0))
        with self.assertRaises(pngtga.ImageError) as caught:
            pngtga.decode_png(huge)
        self.assertIn("too big", str(caught.exception))

    def test_a_decompression_bomb_is_refused(self):
        def chunk(kind, body):
            return struct.pack(">I", len(body)) + kind + body + b"\0\0\0\0"
        bomb = pngtga.PNG_SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 10, 10, 8, 6, 0, 0, 0))
        bomb += chunk(b"IDAT", zlib.compress(bytes(50_000_000))) + chunk(b"IEND", b"")
        with self.assertRaises(pngtga.ImageError):
            pngtga.decode_png(bomb)

    def test_tga_header_size_and_colour_order(self):
        tga, width, height = pngtga.png_to_tga(make_png(4, 2, colour=2))
        self.assertEqual((width, height), (4, 2))
        self.assertEqual(tga[2], 2, "uncompressed")
        self.assertEqual(struct.unpack("<HH", tga[12:16]), (4, 2))
        self.assertEqual(tga[16], 32)
        self.assertEqual(len(tga), 18 + 4 * 2 * 4)
        # Bottom row first, stored blue, green, red, alpha. Pixel (0, 1) is r=0, g=10, b=200.
        self.assertEqual(tuple(tga[18:22]), (200, 10, 0, 255))

    def test_big_pictures_shrink_and_keep_their_shape(self):
        tga, width, height = pngtga.png_to_tga(make_png(1600, 900, colour=2), max_side=320)
        self.assertEqual((width, height), (320, 180))
        self.assertEqual(len(tga), 18 + 320 * 180 * 4)

    def test_small_pictures_are_not_enlarged(self):
        self.assertEqual(pngtga.png_to_tga(make_png(10, 10))[1:], (10, 10))


class PreviewFiles(Base):
    def store(self, remote=None):
        folder = self.dir / "previews"
        folder.mkdir(exist_ok=True)
        return previews.Previews(folder, remote or FakeImages())

    def test_loads_in_the_background_then_shows(self):
        store = self.store()
        first = store.prepare("t", [picture_row("/a/one.png")], True)[0]
        self.assertEqual(first[4:], [0, 0, 0, "Loading preview..."])
        self.assertTrue(store.process_one())
        ready = store.prepare("t", [picture_row("/a/one.png")], True)[0]
        self.assertEqual(ready[4:7], [1, 8, 8])
        self.assertTrue((store.folder / "p01.tga").read_bytes().startswith(b"\0\0\x02"))

    def test_only_fetches_once(self):
        remote = FakeImages()
        store = self.store(remote)
        for _ in range(3):
            store.prepare("t", [picture_row("/a/one.png")], True)
        store.process_one()
        store.prepare("t", [picture_row("/a/one.png")], True)
        self.assertFalse(store.process_one())
        self.assertEqual(len(remote.calls), 1)

    def test_server_paths_never_reach_the_game(self):
        store = self.store()
        row = store.prepare("t", [picture_row("/Users/secret/one.png")], True)[0]
        self.assertNotIn("secret", luadata.lua_value(row))

    def test_only_the_newest_pictures_per_thread(self):
        store = self.store()
        rows = [picture_row(f"/a/{n}.png", n) for n in range(6)]
        out = store.prepare("t", rows, True)
        self.assertEqual([row[1] for row in out], ["3.png", "4.png", "5.png"])

    def test_unwanted_threads_get_no_pictures_or_paths(self):
        store = self.store()
        rows = [["a", "words", "d", 1], picture_row("/a/one.png", 2)]
        self.assertEqual(store.prepare("t", rows, False), [["a", "words", "d", 1]])
        self.assertTrue(store.waiting.empty())

    def test_non_png_says_why_and_fetches_nothing(self):
        remote = FakeImages()
        store = self.store(remote)
        row = store.prepare("t", [picture_row("/a/photo.jpg")], True)[0]
        self.assertIn("Only PNG", row[7])
        self.assertFalse(store.process_one())
        self.assertEqual(remote.calls, [])

    def test_a_broken_picture_says_why(self):
        store = self.store(FakeImages(data=b"garbage"))
        store.prepare("t", [picture_row("/a/one.png")], True)
        store.process_one()
        self.assertIn("not a PNG", store.prepare("t", [picture_row("/a/one.png")], True)[0][7])

    def test_t3_failing_says_so(self):
        store = self.store(FakeImages(error=t3errors.SendRefused("nope")))
        for _ in range(settings.PREVIEW_TRIES):
            store.prepare("t", [picture_row("/a/one.png")], True)
            store.process_one()
        self.assertIn("could not send", store.prepare("t", [picture_row("/a/one.png")], True)[0][7])
        self.assertFalse(store.process_one(), "and then it stops asking")

    def test_a_picture_t3_refuses_at_first_arrives_when_it_can(self):
        # Seen for real: T3 answered "not found" as an agent read a picture, and served it a moment later.
        images = FakeImages(error=t3errors.SendRefused("AssetWorkspaceAssetNotFoundError"))
        store = self.store(images)
        store.prepare("t", [picture_row("/a/one.png")], True)
        store.process_one()
        self.assertIn("Loading", store.prepare("t", [picture_row("/a/one.png")], True)[0][7], "one refusal must not stick")
        images.error = None
        store.process_one()
        row = store.prepare("t", [picture_row("/a/one.png")], True)[0]
        self.assertEqual(row[7], "")
        self.assertGreater(row[4], 0)

    def test_a_missing_permission_is_named(self):
        store = self.store(FakeImages(error=t3errors.SendRefused("The authenticated token is missing required scope: filesystem:read.")))
        store.prepare("t", [picture_row("/a/one.png")], True)
        store.process_one()
        self.assertIn("needs file access", store.prepare("t", [picture_row("/a/one.png")], True)[0][7])

    def test_no_file_is_written_twice_in_one_session(self):
        store = self.store()
        files = []
        for number in range(settings.PREVIEW_FILES + 5):
            store.prepare("t", [picture_row(f"/a/{number}.png")], True)
            store.process_one()
            row = store.prepare("t", [picture_row(f"/a/{number}.png")], True)[0]
            if row[4]:
                files.append(row[4])
            else:
                self.assertIn("Reload", row[7])
        self.assertEqual(len(files), settings.PREVIEW_FILES)
        self.assertEqual(len(set(files)), settings.PREVIEW_FILES, "a file written twice would show the wrong picture")

    def test_restarting_the_bridge_never_rewrites_a_file_in_the_same_session(self):
        state = self.dir / "previews.json"
        folder = self.dir / "previews"
        folder.mkdir(exist_ok=True)
        first = previews.Previews(folder, FakeImages(), state_path=state)
        first.new_ui_session(100.0)
        first.prepare("t", [picture_row("/a/one.png")], True)
        first.process_one()
        restarted = previews.Previews(folder, FakeImages(), state_path=state)
        restarted.new_ui_session(100.0)  # Same game session: the file time has not moved.
        self.assertEqual(restarted.prepare("t", [picture_row("/a/one.png")], True)[0][4], 1, "it remembers what it wrote")
        restarted.prepare("t", [picture_row("/a/two.png")], True)
        restarted.process_one()
        self.assertEqual(restarted.prepare("t", [picture_row("/a/two.png")], True)[0][4], 2, "it must not reuse file 1")
        self.assertEqual(restarted.used_this_session, 2)

    def test_a_real_reload_after_a_restart_still_frees_files(self):
        state = self.dir / "previews.json"
        folder = self.dir / "previews"
        folder.mkdir(exist_ok=True)
        first = previews.Previews(folder, FakeImages(), state_path=state)
        first.new_ui_session(100.0)
        first.prepare("t", [picture_row("/a/one.png")], True)
        first.process_one()
        restarted = previews.Previews(folder, FakeImages(), state_path=state)
        restarted.new_ui_session(200.0)
        self.assertEqual(restarted.used_this_session, 0)
        self.assertEqual(restarted.next_file, 2, "the ring carries on, so what is on screen stays right")

    def test_a_damaged_state_file_is_treated_as_a_new_start(self):
        state = self.dir / "previews.json"
        state.write_text("not json")
        folder = self.dir / "previews"
        folder.mkdir(exist_ok=True)
        self.assertEqual(previews.Previews(folder, FakeImages(), state_path=state).next_file, 1)

    def test_a_reload_frees_the_files_and_retries_what_was_refused(self):
        store = self.store()
        for number in range(settings.PREVIEW_FILES + 1):
            store.prepare("t", [picture_row(f"/a/{number}.png")], True)
            store.process_one()
        last = f"/a/{settings.PREVIEW_FILES}.png"
        self.assertIn("Reload", store.prepare("t", [picture_row(last)], True)[0][7])
        store.new_ui_session(1.0)
        store.forget_retryable()
        store.prepare("t", [picture_row(last)], True)
        store.process_one()
        row = store.prepare("t", [picture_row(last)], True)[0]
        self.assertEqual(row[4], 1, "the ring carries on from the oldest file")

    def test_an_overwritten_file_forgets_its_old_picture(self):
        store = self.store()
        for number in range(settings.PREVIEW_FILES):
            store.prepare("t", [picture_row(f"/a/{number}.png")], True)
            store.process_one()
        store.new_ui_session(1.0)
        store.prepare("t", [picture_row("/a/new.png")], True)
        store.process_one()
        self.assertNotIn("/a/0.png", store.ready, "that file holds a different picture now")

    def test_attachments_use_their_id(self):
        remote = FakeImages()
        store = self.store(remote)
        store.prepare("t", [["i", "image.png", "d", 1, {"a": "att-1", "n": "image.png"}]], True)
        store.process_one()
        self.assertEqual(remote.calls, [{"a": "att-1", "n": "image.png"}])

    def test_timeline_finds_both_kinds_of_image(self):
        rows = timeline.build_timeline([
            {"type": "dynamic_tool", "toolName": "Read", "viewedImagePath": "/x/shot.png", "status": "completed", "ordinal": 1},
            {"type": "user_message", "text": "see this", "ordinal": 2, "attachments": [
                {"type": "image", "id": "att-1", "name": "image.png"}, {"type": "file", "id": "f", "name": "a.txt"}]},
        ])
        self.assertEqual([row[0] for row in rows], ["s", "i", "u", "i"])
        self.assertEqual(rows[1][4], {"p": "/x/shot.png"})
        self.assertEqual(rows[3][4]["a"], "att-1")

    def test_install_makes_the_picture_files_and_keeps_existing_ones(self):
        addonfiles.install_addon(self.wow, ROOT / "addon/PromptPeon")
        folder = self.wow / "Interface/AddOns/PromptPeon/previews"
        self.assertEqual(len(list(folder.glob("p*.tga"))), settings.PREVIEW_FILES)
        (folder / "p05.tga").write_bytes(b"kept")
        addonfiles.install_addon(self.wow, ROOT / "addon/PromptPeon")
        self.assertEqual((folder / "p05.tga").read_bytes(), b"kept")

    def test_the_snapshot_carries_resolved_pictures(self):
        class WithPicture(FakeRemote):
            def detail(self, thread_id):
                return timeline.describe_thread({"turnItems": [
                    {"type": "dynamic_tool", "toolName": "Read", "viewedImagePath": "/private/shot.png", "status": "completed", "ordinal": 1}]})

            def image_bytes(self, thread_id, reference):
                return make_png(8, 8)

        addonfiles.install_addon(self.wow, ROOT / "addon/PromptPeon")
        bridge = self.bridge(WithPicture())
        bridge.previews.allow_files = True  # Off unless you said yes at install.
        refreshing.refresh(bridge)
        bridge.previews.process_one()
        refreshing.refresh(bridge)
        text = bridge.snapshot_path.read_text()
        self.assertNotIn("/private/", text)
        row = [row for row in bridge.snapshot["threads"][0]["m"] if row[0] == "i"][0]
        self.assertEqual(row[4:7], [1, 8, 8])


class ClearingPictures(Base):
    def previews(self, folder):
        folder.mkdir(parents=True, exist_ok=True)
        return previews.Previews(folder, None)

    def test_a_real_picture_the_same_size_as_a_blank_one_is_still_cleared(self):
        # Every 8x8 picture is exactly as long as the placeholder.
        folder = self.dir / "pics"
        keeper = self.previews(folder)
        blank = pngtga.blank_tga()
        (folder / "p01.tga").write_bytes(b"x" * len(blank))
        keeper.clear_files()
        self.assertEqual((folder / "p01.tga").read_bytes(), blank)

    def test_clearing_while_playing_never_reuses_a_file_the_game_has_cached(self):
        folder = self.dir / "pics"
        keeper = self.previews(folder)
        keeper.next_file, keeper.used_this_session = 5, 4
        keeper.clear_files(new_session=False)
        self.assertEqual((keeper.next_file, keeper.used_this_session), (5, 4))
        keeper.clear_files()
        self.assertEqual((keeper.next_file, keeper.used_this_session), (1, 0), "a closed game starts over")


if __name__ == "__main__":
    unittest.main(verbosity=1)
