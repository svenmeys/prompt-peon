"""The update bells: sound files that tell the game a newer snapshot is waiting."""
import os
import unittest

from bridge_helpers import Base, FakeRemote, THREAD, thread
from promptpeon import bells, bridgestate, publishing, refreshing, settings


class Bells(Base):
    def setUp(self):
        super().setUp()
        self.folder = self.wow / "Interface/AddOns/PromptPeon/bells"

    def real(self):
        return [number for number in range(settings.BELL_COUNT) if bells.bell(self.folder, number).stat().st_size > 0]

    def test_the_installer_makes_them_before_the_game_starts(self):
        self.assertTrue(bells.make(self.folder))
        self.assertEqual(sorted(path.name for path in self.folder.iterdir()), ["b1.wav", "b2.wav", "b3.wav", "b4.wav", "b5.wav", "b6.wav", "b7.wav", "b8.wav", "on.wav"])
        self.assertEqual((self.folder / "on.wav").stat().st_size, 441044, "the size that was measured in the game")
        self.assertEqual((self.folder / "on.wav").read_bytes()[:4], b"RIFF")
        self.assertEqual(self.real(), [], "no bell has rung yet")

    def test_ringing_leaves_exactly_one_real_bell(self):
        bells.make(self.folder)
        for count in (1, 2, 9, 12):
            self.assertTrue(bells.ring(self.folder, count))
            self.assertEqual(self.real(), [count % settings.BELL_COUNT])
            self.assertEqual(bells.rung(self.folder), count % settings.BELL_COUNT)

    def test_making_them_again_keeps_the_count(self):
        bells.make(self.folder)
        bells.ring(self.folder, 5)
        bells.make(self.folder)
        self.assertEqual(self.real(), [5])

    def test_no_addon_folder_is_not_an_error(self):
        gone = self.dir / "nowhere/PromptPeon/bells"
        self.assertFalse(bells.make(gone))
        self.assertFalse(bells.ring(gone, 1))
        self.assertEqual(bells.rung(gone), 0)

    @unittest.skipIf(os.name == "nt", "symlinks need extra rights on Windows")
    def test_a_bell_swapped_for_a_link_is_never_written_through(self):
        bells.make(self.folder)
        victim = self.dir / "victim.txt"
        victim.write_text("mine")
        bells.bell(self.folder, 3).unlink()
        bells.bell(self.folder, 3).symlink_to(victim)
        bells.ring(self.folder, 3)
        self.assertEqual(victim.read_text(), "mine")
        self.assertFalse(bells.bell(self.folder, 3).is_symlink(), "the link is replaced by a file of ours")

    def test_a_bell_that_is_also_another_file_is_never_written_into(self):
        # A hard link isn't a symlink, and writing into the bell would write into the other file.
        bells.make(self.folder)
        victim = self.dir / "victim.txt"
        victim.write_text("mine")
        for number, count in ((2, 2), (5, 3)):
            bells.bell(self.folder, number).unlink()
            os.link(victim, bells.bell(self.folder, number))
            bells.ring(self.folder, count)
            self.assertEqual(victim.read_text(), "mine", f"ringing {count} with bell {number} hard linked")
            self.assertEqual(bells.bell(self.folder, number).stat().st_nlink, 1, "the bell is a file of its own again")
        self.assertEqual(self.real(), [3])

    def test_a_real_bell_swapped_for_a_hard_link_is_emptied_without_touching_the_other_file(self):
        bells.make(self.folder)
        bells.ring(self.folder, 1)
        victim = self.dir / "victim.bin"
        victim.write_bytes(b"x" * 1000)
        bells.bell(self.folder, 1).unlink()
        os.link(victim, bells.bell(self.folder, 1))
        bells.ring(self.folder, 2)
        self.assertEqual(victim.read_bytes(), b"x" * 1000)
        self.assertEqual(self.real(), [2])

    def test_ringing_never_opens_a_file_that_is_already_there(self):
        from unittest import mock
        bells.make(self.folder)
        with mock.patch.object(bells.Path, "open", side_effect=AssertionError("opened a bell to write into it")):
            self.assertTrue(bells.ring(self.folder, 4))
        self.assertEqual(self.real(), [4])

    @unittest.skipIf(os.name == "nt", "symlinks need extra rights on Windows")
    def test_a_bells_folder_swapped_for_a_link_is_not_followed(self):
        elsewhere = self.dir / "elsewhere"
        elsewhere.mkdir()
        self.folder.parent.mkdir(parents=True, exist_ok=True)
        self.folder.symlink_to(elsewhere, target_is_directory=True)
        bells.ring(self.folder, 1)
        self.assertEqual(list(elsewhere.iterdir()), [])


class RingingForNews(Base):
    def make(self, **shell_thread):
        remote = FakeRemote(shell={"threads": [thread(**shell_thread)], "projects": [{"id": "p1", "title": "Shop"}]})
        bridge = bridgestate.Bridge(self.wow, remote, state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json")
        return bridge, remote

    def real(self, bridge):
        return [number for number in range(settings.BELL_COUNT) if bells.bell(bridge.bells, number).stat().st_size > 0]

    def test_the_first_snapshot_rings_and_carries_the_count(self):
        bridge, _ = self.make()
        refreshing.refresh(bridge)
        publishing.publish(bridge)
        self.assertEqual(bridge.snapshot["sg"], 1)
        self.assertEqual(self.real(bridge), [1])
        self.assertIn("sg=1", bridge.snapshot_path.read_text().replace(" ", ""))

    def test_nothing_new_does_not_ring(self):
        bridge, _ = self.make()
        refreshing.refresh(bridge)
        publishing.publish(bridge)
        publishing.publish(bridge)
        bridge.last_write_at = -10 ** 6  # Time for a heartbeat: the file is rewritten, the bell is not rung.
        publishing.publish(bridge)
        self.assertEqual((bridge.snapshot["sg"], self.real(bridge)), (1, [1]))

    def test_an_agent_writing_more_does_not_ring(self):
        bridge, remote = self.make(status="running")
        refreshing.refresh(bridge)
        publishing.publish(bridge)
        bridge.messages[THREAD] = dict(bridge.messages.get(THREAD) or {}, activity="Running a command", rows=[["a", "more words", "d", 5]])
        publishing.publish(bridge)
        self.assertEqual(bridge.snapshot["sg"], 1, "words are picked up on the game's timer, as before")

    def test_threads_swapping_places_in_the_list_does_not_ring(self):
        # Two busy agents take turns being newest, and the order is not news.
        one = {"threads": [{"id": "a", "s": "running"}, {"id": "b", "s": "running"}], "pk": [{"id": "c", "pk": "s"}, {"id": "d", "pk": "s"}]}
        other = {"threads": [{"id": "b", "s": "running"}, {"id": "a", "s": "running"}], "pk": [{"id": "d", "pk": "s"}, {"id": "c", "pk": "s"}]}
        self.assertFalse(bells.is_news(bells.shape(one), bells.shape(other)))
        self.assertTrue(bells.is_news(bells.shape(one), bells.shape(dict(one, threads=[{"id": "a", "s": "needs"}, {"id": "b", "s": "running"}]))))

    def test_two_busy_agents_taking_turns_never_ring(self):
        remote = FakeRemote(shell={"threads": [thread(id="a", status="running", updatedAt="2026-11-13T10:00:00.000Z"),
                                               thread(id="b", status="running", updatedAt="2026-11-13T10:00:01.000Z")], "projects": [{"id": "p1", "title": "Shop"}]})
        bridge = bridgestate.Bridge(self.wow, remote, state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json")
        refreshing.refresh(bridge)
        publishing.publish(bridge)
        first = bridge.bell
        for second in range(2, 8):
            remote._shell["threads"][second % 2]["updatedAt"] = f"2026-11-13T10:00:{second:02d}.000Z"
            refreshing.refresh(bridge)
            publishing.publish(bridge)
        self.assertEqual(bridge.bell, first)

    def test_what_you_asked_for_going_away_again_does_not_ring(self):
        bridge, _ = self.make()
        refreshing.refresh(bridge)
        publishing.publish(bridge)
        bridge.keep_loaded(THREAD, ax={"k": ["asked", "answered"]})
        publishing.publish(bridge)
        self.assertEqual(bridge.bell, 2, "it arriving is news")
        bridge.loaded[THREAD]["until"] = 0
        publishing.publish(bridge)
        self.assertEqual(bridge.bell, 2, "it leaving a minute later is not: the game has it")
        bridge.keep_loaded(THREAD, ax={"k": ["asked again", "answered"]})
        publishing.publish(bridge)
        self.assertEqual(bridge.bell, 3, "and asking again rings again")

    def test_a_new_install_has_a_real_bell_before_the_game_first_starts(self):
        bridge, _ = self.make()
        publishing.go_quiet(bridge)
        self.assertEqual(self.real(bridge), [0], "the quiet snapshot says count 0, and its bell is real")
        self.assertIn("sg=0", bridge.snapshot_path.read_text().replace(" ", ""))

    def test_a_thread_changing_state_rings(self):
        bridge, remote = self.make(status="running")
        refreshing.refresh(bridge)
        publishing.publish(bridge)
        remote._shell["threads"][0]["status"] = "needs"
        remote._shell["threads"][0]["pendingRuntimeRequest"] = {"kind": "user_input", "blocking": True}
        refreshing.refresh(bridge)
        publishing.publish(bridge)
        self.assertEqual((bridge.snapshot["sg"], self.real(bridge)), (2, [2]))

    def test_something_you_asked_for_arriving_rings(self):
        bridge, _ = self.make()
        refreshing.refresh(bridge)
        publishing.publish(bridge)
        bridge.keep_loaded(THREAD, ax={"k": ["asked", "answered"]})
        publishing.publish(bridge)
        self.assertEqual(bridge.snapshot["sg"], 2)

    def test_a_snapshot_that_could_not_be_written_rings_next_time(self):
        bridge, _ = self.make()
        bells.make(bridge.bells)
        snapshot_path = bridge.snapshot_path
        bridge.snapshot_path = self.dir / "gone/Snapshot.lua"
        refreshing.refresh(bridge)
        publishing.publish(bridge)
        self.assertEqual((bridge.bell, self.real(bridge)), (0, []), "no bell for news the game can't load")
        bridge.snapshot_path = snapshot_path
        publishing.publish(bridge)
        self.assertEqual((bridge.bell, self.real(bridge)), (1, [1]))

    def test_a_bell_that_could_not_be_rung_is_rung_at_the_next_look(self):
        from unittest import mock
        bridge, _ = self.make()
        with mock.patch.object(bells, "ring", return_value=False):
            refreshing.refresh(bridge)
            publishing.publish(bridge)
        self.assertEqual((bridge.snapshot["sg"], bridge.bell_unrung), (1, True))
        publishing.publish(bridge)
        self.assertEqual((self.real(bridge), bridge.bell_unrung), ([1], False), "the game's own bell must be real before it listens for long")

    def test_a_companion_app_that_restarts_carries_on_from_the_bell_that_is_rung(self):
        bridge, _ = self.make()
        refreshing.refresh(bridge)
        publishing.publish(bridge)
        bells.ring(bridge.bells, 6)
        again, _ = self.make()
        self.assertEqual(again.bell, 6)
        refreshing.refresh(again)
        publishing.publish(again)
        self.assertEqual((again.snapshot["sg"], self.real(again)), (7, [7]), "so the game's bell goes quiet once, for real news")

    def test_closing_the_game_keeps_the_count_and_the_next_open_rings(self):
        bridge, _ = self.make()
        refreshing.refresh(bridge)
        publishing.publish(bridge)
        publishing.go_quiet(bridge)
        self.assertIn("sg=1", bridge.snapshot_path.read_text().replace(" ", ""))
        bridge.game_closed = False
        refreshing.refresh(bridge)
        publishing.publish(bridge)
        self.assertEqual(bridge.snapshot["sg"], 2)
