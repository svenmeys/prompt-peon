"""A thread's changes, by file and by page."""
import unittest

from bridge_helpers import split_diff
from promptpeon import diffs, settings, timeline


class DiffFiles(unittest.TestCase):
    def test_each_file_gets_counts_and_only_its_hunks(self):
        files = split_diff(
            "diff --git a/x.py b/x.py\nindex 1..2 100644\n--- a/x.py\n+++ b/x.py\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n+more\n"
            "diff --git a/new.txt b/new.txt\nnew file mode 100644\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+hello\n"
            "diff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\n--- a/gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-bye\n"
            "diff --git a/logo.png b/logo.png\nBinary files a/logo.png and b/logo.png differ\n"
            "diff --git a/old.py b/moved.py\nsimilarity index 100%\nrename from old.py\nrename to moved.py\n"
        )
        self.assertEqual([row[:3] for row in files], [["x.py", 2, 1], ["new.txt", 1, 0], ["gone.txt", 0, 1], ["logo.png", 0, 0], ["moved.py", 0, 0]])
        self.assertEqual(files[0][3], "@@ -1,2 +1,2 @@\n keep\n-old\n+new\n+more")
        self.assertNotIn("index 1..2", files[0][3])
        self.assertEqual(files[3][3:], ["", True])

    def test_a_line_that_looks_like_a_header_stays_in_its_file(self):
        files = split_diff("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n+diff --git a/fake b/fake\n+++ counts as added\n")
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0][:3], ["x", 2, 0])

    def test_a_huge_file_is_listed_and_waits_to_be_asked_for(self):
        big = "diff --git a/big b/big\n--- a/big\n+++ b/big\n@@ -0,0 +1 @@\n" + ("+" + "x" * 99 + "\n") * 2000
        small = "diff --git a/small b/small\n--- a/small\n+++ b/small\n@@ -0,0 +1 @@\n+ok\n"
        files = split_diff(big + small)
        self.assertEqual(files[0][:5], ["big", 2000, 0, "", False])
        self.assertTrue(files[1][4])
        self.assertIn("+ok", files[1][3])

    def test_a_huge_diff_keeps_listing_files(self):
        one = "diff --git a/f{0} b/f{0}\n--- a/f{0}\n+++ b/f{0}\n@@ -0,0 +1 @@\n" + ("+" + "x" * 99 + "\n") * 1000
        files = split_diff("".join(one.format(n) for n in range(30)))
        self.assertEqual(len(files), 30)
        self.assertTrue(files[0][4])
        self.assertFalse(files[-1][4])
        self.assertLessEqual(sum(len(row[3]) for row in files), settings.MAX_LOADED_BYTES)

    def test_a_minified_line_can_not_make_a_file_too_big(self):
        files = split_diff("diff --git a/min.js b/min.js\n--- a/min.js\n+++ b/min.js\n@@ -0,0 +1 @@\n+" + "x" * 900_000 + "\n")
        self.assertTrue(files[0][4], "it fits now")
        self.assertLess(len(files[0][3]), 2000)
        self.assertIn("more characters on this line", files[0][3])
        self.assertEqual(files[0][1], 1, "still one line added")

    def test_pages_keep_every_line_in_order(self):
        patch = "@@ -1,3000 +1,3000 @@\n" + "\n".join(f" line {n} " + "x" * 80 for n in range(3000))
        pages = diffs.patch_pages(patch)
        self.assertGreater(len(pages), 1)
        self.assertEqual("\n".join(page[2] for page in pages), patch)
        for page in pages:
            self.assertLessEqual(len(page[2]), settings.MAX_PAGE_BYTES)

    def test_each_page_knows_its_line_numbers(self):
        lines = ["@@ -100,9000 +200,9000 @@"]
        for n in range(3000):
            lines += [" same" + "x" * 90, "-gone" + "x" * 90, "+came" + "x" * 90]
        pages = diffs.patch_pages("\n".join(lines))
        self.assertGreater(len(pages), 2)
        self.assertEqual(pages[0][:2], [100, 200])
        # Walk the first page by hand: the second page must start where it stopped.
        old, new = 100, 200
        for line in pages[0][2].split("\n")[1:]:
            if line.startswith("+"):
                new += 1
            elif line.startswith("-"):
                old += 1
            else:
                old, new = old + 1, new + 1
        self.assertEqual(pages[1][:2], [old, new])

    def test_a_new_hunk_starting_a_page_uses_its_own_numbers(self):
        # The first page is exactly full when the second hunk's header arrives.
        pages = diffs.patch_pages("@@ -1,1 +1,1 @@\n+" + "x" * 99972 + "\n@@ -700,1 +800,1 @@\n+later")
        self.assertEqual(len(pages), 2)
        self.assertEqual(pages[1][:2], [700, 800])
        self.assertTrue(pages[1][2].startswith("@@ -700"))

    def test_an_empty_patch_has_no_trouble(self):
        self.assertEqual(diffs.patch_pages(""), [[0, 0, ""]])

    def test_the_turn_to_ask_for_is_the_newest_t3_can_diff(self):
        projection = {
            "runs": [{"id": "r1", "status": "completed"}, {"id": "r2", "status": "completed"}, {"id": "r3", "status": "running"}],
            "checkpoints": [
                {"runId": "r1", "status": "ready", "appRunOrdinal": 5},
                {"runId": "r2", "status": "ready", "appRunOrdinal": 8},
                {"runId": "r2", "status": "pending", "appRunOrdinal": 9},
                {"runId": "r3", "status": "ready", "appRunOrdinal": 10},
            ],
        }
        self.assertEqual(timeline.latest_diff_turn(projection), 8)
        self.assertEqual(timeline.latest_diff_turn({}), 0)


if __name__ == "__main__":
    unittest.main(verbosity=1)
