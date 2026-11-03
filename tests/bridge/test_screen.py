"""What the installer looks like. A person at a terminal gets colors and wrapped lines, and logs and pipes get plain text."""
import io
import os
import re
import unittest
from unittest import mock

from promptpeon import screen

ANSI = re.compile(r"\033\[[0-9;]*m")


class Terminal(io.StringIO):
    def isatty(self):
        return True


class AtATerminal(unittest.TestCase):
    def setUp(self):
        self.out = Terminal()
        for patcher in (mock.patch("sys.stdout", self.out), mock.patch.dict(os.environ, {"COLUMNS": "60"}), mock.patch.object(screen, "_enable_windows_colors"),
                        mock.patch.object(screen, "_windows_colors_on", True)):
            self.addCleanup(patcher.stop)
            patcher.start()
        os.environ.pop("NO_COLOR", None)

    def plain(self):
        return ANSI.sub("", self.out.getvalue())

    def test_long_text_wraps_and_lines_up(self):
        screen.say("word " * 40)
        lines = self.plain().splitlines()
        self.assertGreater(len(lines), 2)
        for line in lines:
            self.assertLessEqual(len(line), 60)
            self.assertTrue(line.startswith(screen.INDENT))

    def test_a_long_address_is_never_broken_up(self):
        link = "https://prod-eff9ddc75373f5a0.t3coderelay.com/pair#token=CPG9AC9X8FVX-and-more-and-more"
        screen.say(f"Open {link} now")
        self.assertIn(link, self.plain())

    def test_a_blank_line_stays_a_blank_line(self):
        screen.say("\nFirst.\nSecond.")
        self.assertEqual(self.plain(), f"\n{screen.INDENT}First.\n{screen.INDENT}Second.\n")

    def test_steps_say_how_far_along_you_are(self):
        screen.step(2, 4, "Connecting to T3")
        self.assertIn("[2/4] Connecting to T3", self.plain())
        self.assertIn(screen.GOLD, self.out.getvalue())

    def test_good_news_reads_like_the_tracker(self):
        screen.ok("Connected")
        self.assertIn("[ok] Connected", self.plain())
        self.assertIn(screen.GREEN, self.out.getvalue())

    def test_the_title_has_a_peon_in_it(self):
        screen.title("Prompt Peon 9.9.9")
        self.assertIn("Prompt Peon 9.9.9", self.plain())
        self.assertIn("Something need doing?", self.plain())

    def test_colors_dont_count_toward_the_width(self):
        text = "x" * 45
        screen.ok(text)
        screen.done(text)
        self.assertEqual(len([line for line in self.plain().splitlines() if line.strip()]), 2, self.plain())

    def test_a_long_ok_line_lines_up_under_its_words(self):
        screen.ok("word " * 30)
        lines = self.plain().splitlines()
        self.assertTrue(lines[1].startswith(screen.INDENT + "     w"), lines[1])

    def test_a_windows_console_that_refuses_colors_stays_plain(self):
        with mock.patch.object(screen, "_windows_colors_on", False), mock.patch.object(screen.os, "name", "nt"):
            screen.ok("Connected")
        self.assertEqual(self.out.getvalue(), self.plain())
        self.assertIn("[ok] Connected", self.plain())

    def test_no_color_is_respected(self):
        with mock.patch.dict(os.environ, {"NO_COLOR": "1"}):
            screen.ok("Connected")
        self.assertEqual(self.out.getvalue(), self.plain())


class InALogOrAPipe(unittest.TestCase):
    def test_everything_is_plain_and_unwrapped(self):
        with mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            screen.title("Prompt Peon 9.9.9")
            screen.step(1, 4, "Looking for WoW")
            screen.ok("Connected")
            long_line = "word " * 40
            screen.say(long_line)
        text = out.getvalue()
        self.assertNotIn("\033", text)
        self.assertIn(long_line, text)
        self.assertIn("[1/4] Looking for WoW", text)

    def test_no_output_at_all_doesnt_crash(self):
        # The companion app runs under pythonw on Windows, which has no stdout.
        with mock.patch("sys.stdout", None):
            screen.say("nobody is listening")
            screen.ok("nobody is listening")


if __name__ == "__main__":
    unittest.main(verbosity=1)
