"""Pull requests linked to a thread, and the page you can open."""
import json
import time
import unittest
from unittest import mock

from bridge_helpers import Base, CommandRemote, FakeRemote, THREAD, command, thread
from promptpeon import bridgestate, delivery, publishing, pullrequests, refreshing, settings, snapshots, t3errors


PATCH_A = "diff --git a/src/a.py b/src/a.py\n--- a/src/a.py\n+++ b/src/a.py\n@@ -1 +1 @@\n-old\n+new\n"
PATCH_B = "diff --git a/src/b.py b/src/b.py\n--- a/src/b.py\n+++ b/src/b.py\n@@ -1 +1,2 @@\n one\n+two\n"


class OnePullRequestsChanges(Base):
    """Going into a pull request shows that pull request's files, not everything the thread ever changed."""

    LINK = {"host": "github.com", "repository": "me/repo", "number": 7, "snapshot": {"state": "open", "title": "Fix"}}

    def make(self, patch=PATCH_A, cut=False):
        remote = CommandRemote(shell={"threads": [thread(projectId="p1", pullRequests=[self.LINK])], "projects": [{"id": "p1", "title": "Shop"}]})
        remote.pr_diff = mock.Mock(return_value=(patch, cut))
        remote.thread_diff = mock.Mock(return_value=PATCH_B)
        bridge = self.bridge(remote)
        refreshing.refresh(bridge)
        return bridge, remote

    def loaded(self, bridge):
        publishing.publish(bridge)
        return bridge.snapshot["threads"][0]

    def test_it_sends_only_that_pull_requests_files(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, THREAD, "prdiff\n7")])
        self.assertEqual(bridge.state["results"]["1"], "sent")
        remote.pr_diff.assert_called_once_with("p1", self.LINK)
        remote.thread_diff.assert_not_called()
        row = self.loaded(bridge)
        self.assertEqual([file[0] for file in row["df"]], ["src/a.py"])
        self.assertEqual(row["dp"], 7, "so the game knows whose files these are")

    def test_a_pull_request_this_thread_doesnt_link_is_refused(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, THREAD, "prdiff\n8")])
        self.assertIn("isn't linked", bridge.state["results"]["1"])
        remote.pr_diff.assert_not_called()

    def test_nonsense_is_refused(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, THREAD, "prdiff\nmain; rm -rf /")])
        self.assertIn("isn't linked", bridge.state["results"]["1"])
        remote.pr_diff.assert_not_called()

    def test_a_hidden_thread_stays_hidden(self):
        bridge, remote = self.make()
        bridge.state["hidden"] = {"projects": ["Shop"], "threads": []}
        delivery.deliver(bridge, [command(1, THREAD, "prdiff\n7")])
        self.assertIn("hidden", bridge.state["results"]["1"])
        remote.pr_diff.assert_not_called()

    def test_it_counts_as_a_read_toward_the_limit(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(seq, THREAD, "prdiff\n7") for seq in range(1, settings.MAX_READS_PER_MINUTE + 3)])
        self.assertEqual(remote.pr_diff.call_count, settings.MAX_READS_PER_MINUTE)

    def test_an_empty_or_cut_diff_says_so(self):
        bridge, _remote = self.make(patch="")
        delivery.deliver(bridge, [command(1, THREAD, "prdiff\n7")])
        self.assertIn("no changes", self.loaded(bridge)["dn"])
        bridge, _remote = self.make(cut=True)
        delivery.deliver(bridge, [command(2, THREAD, "prdiff\n7")])
        self.assertIn("some files may be missing", self.loaded(bridge)["dn"])

    def test_t3_saying_no_reaches_the_player_as_a_failure(self):
        bridge, remote = self.make()
        remote.pr_diff.side_effect = OSError("no route")
        delivery.deliver(bridge, [command(1, THREAD, "prdiff\n7")])
        self.assertTrue(bridge.state["results"]["1"].startswith("failed"), bridge.state["results"]["1"])

    def test_the_threads_own_changes_arent_marked_as_a_pull_request(self):
        bridge, _remote = self.make()
        delivery.deliver(bridge, [command(1, THREAD, "diff\n")])
        self.assertEqual(self.loaded(bridge)["dp"], 0)

    def test_big_files_page_from_the_same_pull_request(self):
        big = "diff --git a/big.py b/big.py\n--- a/big.py\n+++ b/big.py\n@@ -1,1 +1,4000 @@\n" + "".join(f"+line {n} {'x' * 60}\n" for n in range(4000))
        bridge, remote = self.make(patch=big)
        delivery.deliver(bridge, [command(1, THREAD, "prdiff\n7")])
        delivery.deliver(bridge, [command(2, THREAD, "file\nbig.py\n2\n7")])
        self.assertEqual(bridge.state["results"]["2"], "sent")
        self.assertEqual(self.loaded(bridge)["fp"][:2], ["big.py", 2])
        remote.pr_diff.assert_called_once()
        remote.thread_diff.assert_not_called()

    def test_a_page_after_another_diff_was_opened_asks_for_the_right_one_again(self):
        big = "diff --git a/big.py b/big.py\n--- a/big.py\n+++ b/big.py\n@@ -1,1 +1,4000 @@\n" + "".join(f"+line {n} {'x' * 60}\n" for n in range(4000))
        bridge, remote = self.make(patch=big)
        delivery.deliver(bridge, [command(1, THREAD, "diff\n")])
        delivery.deliver(bridge, [command(2, THREAD, "file\nbig.py\n2\n7")])
        self.assertEqual(bridge.state["results"]["2"], "sent")
        remote.pr_diff.assert_called_once()

    def test_the_old_two_part_file_request_still_means_the_thread(self):
        bridge, remote = self.make()
        delivery.deliver(bridge, [command(1, THREAD, "file\nsrc/b.py\n1")])
        self.assertEqual(bridge.state["results"]["1"], "sent")
        remote.thread_diff.assert_called_once()
        remote.pr_diff.assert_not_called()


class AskingT3ForAPullRequestsDiff(unittest.TestCase):
    def remote(self, *answers):
        from promptpeon import t3remote
        remote = t3remote.T3Remote("http://t3", "token")
        remote._request = mock.Mock(side_effect=list(answers))
        return remote

    LINK = {"host": "github.com", "repository": "me/repo", "number": 7}

    def test_it_posts_what_t3_asks_for(self):
        remote = self.remote({"patch": PATCH_A, "truncated": False, "nextCursor": None})
        self.assertEqual(remote.pr_diff("p1", self.LINK), (PATCH_A, False))
        path = remote._request.call_args.args[0]
        self.assertEqual(path, "/api/pull-requests/diff")
        self.assertEqual(remote._request.call_args.kwargs["method"], "POST")
        self.assertEqual(json.loads(remote._request.call_args.kwargs["body"]), {"projectId": "p1", "host": "github.com", "repository": "me/repo", "number": 7})

    def test_it_follows_pages(self):
        remote = self.remote({"patch": PATCH_A, "truncated": False, "nextCursor": "more"}, {"patch": PATCH_B, "truncated": False, "nextCursor": None})
        self.assertEqual(remote.pr_diff("p1", self.LINK), (PATCH_A + PATCH_B, False))
        self.assertEqual(json.loads(remote._request.call_args.kwargs["body"])["cursor"], "more")

    def test_it_stops_at_a_size_and_says_it_was_cut(self):
        huge = "x" * settings.T3_DIFF_LIMIT
        remote = self.remote({"patch": huge, "truncated": False, "nextCursor": "more"})
        self.assertEqual(remote.pr_diff("p1", self.LINK), (huge, True))

    def test_t3_saying_it_left_things_out_counts(self):
        remote = self.remote({"patch": PATCH_A, "truncated": True, "nextCursor": None})
        self.assertTrue(remote.pr_diff("p1", self.LINK)[1])


class LinkedPullRequests(Base):
    LINK = {"host": "github.com", "repository": "me/repo", "number": 7, "url": "https://github.com/me/repo/pull/7", "source": "agent",
            "snapshot": {"title": "Fix the login", "state": "open", "checksState": "passing", "reviewDecision": "review-required", "mergeability": "conflicting",
                         "additions": 40, "deletions": 5, "changedFiles": 3, "headBranch": "fix", "baseBranch": "main", "isDraft": True,
                         "author": {"login": "someone"}, "updatedAt": "2026-11-02T10:00:00.000Z"}}

    def link(self, number, state="merged", updated="2026-11-01T10:00:00.000Z", **extra):
        snapshot = dict(self.LINK["snapshot"], state=state, updatedAt=updated)
        return dict(self.LINK, number=number, snapshot=snapshot, **extra)

    def make(self, *threads):
        remote = CommandRemote(shell={"threads": list(threads), "projects": [{"id": "p1", "title": "Shop"}]})
        return bridgestate.Bridge(self.wow, remote, state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json"), remote

    def test_a_thread_shows_every_linked_pull_request_open_ones_first(self):
        bridge, _ = self.make(thread(pullRequests=[self.link(1), self.link(2, updated="2026-11-03T10:00:00.000Z"), self.link(3, state="open")]))
        refreshing.refresh(bridge)
        rows = bridge.snapshot["threads"][0]["prs"]
        self.assertEqual([row["n"] for row in rows], [3, 2, 1])
        self.assertEqual(rows[0]["ti"], "Fix the login")
        self.assertEqual((rows[0]["a"], rows[0]["d"], rows[0]["f"]), (40, 5, 3))
        self.assertEqual((rows[0]["st"], rows[0]["ck"], rows[0]["rv"], rows[0]["mg"]), ("open", "passing", "review-required", "conflicting"))
        self.assertEqual((rows[0]["hb"], rows[0]["bb"], rows[0]["au"], rows[0]["dr"]), ("fix", "main", "someone", True))

    def test_no_links_means_no_field(self):
        bridge, _ = self.make(thread())
        refreshing.refresh(bridge)
        self.assertNotIn("prs", bridge.snapshot["threads"][0])

    def test_there_is_a_limit(self):
        bridge, _ = self.make(thread(pullRequests=[self.link(number) for number in range(1, settings.MAX_PULL_REQUESTS + 5)]))
        refreshing.refresh(bridge)
        self.assertEqual(len(bridge.snapshot["threads"][0]["prs"]), settings.MAX_PULL_REQUESTS)

    def test_a_settled_thread_shows_them_too(self):
        bridge, _ = self.make(thread(settledAt="2026-11-02T10:00:00.000Z", pullRequests=[self.link(1)]))
        refreshing.refresh(bridge)
        self.assertEqual(bridge.snapshot["pk"][0]["prs"][0]["n"], 1)

    def test_a_hidden_thread_says_nothing_about_them(self):
        bridge, _ = self.make(thread(pullRequests=[self.link(1)]), thread(id="other", settledAt="2026-11-02T10:00:00.000Z", pullRequests=[self.link(2)]))
        refreshing.refresh(bridge)
        self.assertIn("Fix the login", snapshots.render_snapshot(bridge.snapshot), "the check below has to mean something")
        bridge.state["hidden"] = {"projects": ["Shop"], "threads": []}
        refreshing.refresh(bridge)
        self.assertNotIn("Fix the login", snapshots.render_snapshot(bridge.snapshot))

    def test_only_a_real_web_address_is_passed_on(self):
        bridge, _ = self.make(thread(pullRequests=[dict(self.link(1), url="file:///etc/passwd")]))
        refreshing.refresh(bridge)
        self.assertNotIn("u", bridge.snapshot["threads"][0]["prs"][0])

    def test_a_secret_in_a_title_gets_hidden(self):
        link = self.link(1)
        link["snapshot"] = dict(link["snapshot"], title="password = correcthorsebattery")
        bridge, _ = self.make(thread(pullRequests=[link]))
        refreshing.refresh(bridge)
        self.assertEqual(bridge.snapshot["threads"][0]["prs"][0]["n"], 1, "the row is still there")
        self.assertNotIn("correcthorse", snapshots.render_snapshot(bridge.snapshot))

    def opened(self, *checks, detail=None, activity=None, link=None):
        """Open pull request 7 on a thread, and return what the page sends to the game."""
        bridge, remote = self.make(thread(pullRequests=[link or self.link(7, state="open")]))
        remote.pr_detail = lambda *_args: dict({"body": "Words", "createdAt": "2026-11-01T10:00:00.000Z", "checks": list(checks)}, **(detail or {}))
        remote.pr_activity = lambda *_args: activity or {"comments": [], "reviewThreads": [], "commits": []}
        remote.pr_checks = lambda *_args: {"checks": list(checks)}
        delivery.deliver(bridge, [command(1, THREAD, "pr\n7")])
        self.assertEqual(bridge.state["results"]["1"], "sent")
        publishing.publish(bridge)
        return bridge.snapshot["threads"][0]["pd"][1], bridge

    def test_opening_one_names_what_needs_a_look_failures_first(self):
        page, bridge = self.opened({"name": "lint", "status": "success"}, {"name": "unit tests", "status": "failure"}, {"name": "deploy", "status": "pending"})
        self.assertEqual(page["cs"], [["unit tests", "failure"], ["deploy", "pending"]])
        self.assertEqual(page["ct"], [["failure", 1], ["pending", 1], ["success", 1]])
        row = bridge.snapshot["threads"][0]["prs"][0]
        self.assertEqual((row["ck"], row["cp"], row["ct"]), ("failing", 1, 3))

    def test_a_big_ci_run_is_counted_not_listed(self):
        """A real pull request came back with 72 checks. Forty green rows bury the one that matters."""
        checks = [{"name": f"ok {i}", "status": "success"} for i in range(42)] + [{"name": f"off {i}", "status": "skipped"} for i in range(30)]
        checks.insert(50, {"name": "the broken one", "status": "failure"})
        page, _ = self.opened(*checks)
        self.assertEqual(page["cs"], [["the broken one", "failure"]])
        self.assertEqual(page["ct"], [["failure", 1], ["success", 42], ["skipped", 30]])

    def test_it_says_how_many_checks_it_left_out(self):
        page, _ = self.opened(*[{"name": f"bad {i}", "status": "failure"} for i in range(settings.MAX_CHECKS + 3)])
        self.assertEqual((len(page["cs"]), page["ct"], page["cm"]), (settings.MAX_CHECKS, [["failure", settings.MAX_CHECKS + 3]], 3))

    def test_an_old_answer_doesnt_outvote_t3(self):
        """CI failed when we asked ten minutes ago. T3 keeps its own state current, so believe T3 now."""
        linked = thread(pullRequests=[self.link(7, state="open")])
        fresh = {("me/repo", 7): {"st": "failing", "p": 1, "t": 3, "asked": time.monotonic()}}
        old = {("me/repo", 7): {"st": "failing", "p": 1, "t": 3, "asked": time.monotonic() - settings.CHECK_SECONDS * 3}}
        self.assertEqual(pullrequests.pull_request_rows(linked, fresh)[0]["ck"], "failing")
        self.assertEqual(pullrequests.pull_request_rows(linked, old)[0]["ck"], "passing")
        self.assertNotIn("ct", pullrequests.pull_request_rows(linked, old)[0])

    def test_the_page_has_the_description_labels_and_how_far_behind(self):
        page, _ = self.opened(detail={"body": "## Why\n\nBecause.", "labels": [{"name": "bug"}], "behindBy": 3})
        self.assertEqual(page["b"], "## Why\n\nBecause.")
        self.assertEqual((page["lb"], page["bh"]), (["bug"], 3))

    def test_a_comment_reads_as_who_when_and_what(self):
        page, _ = self.opened(activity={"commentCount": 1, "comments": [
            {"id": "c1", "kind": "issue-comment", "author": {"login": "ann"}, "body": "Looks **fine** to me", "createdAt": "2026-11-02T10:00:00.000Z"}]})
        entry = page["ds"][0]
        self.assertEqual((entry["w"], entry["bt"], entry["b"], entry["g"]), ("ann", False, "Looks **fine** to me", "Looks fine to me"))
        self.assertEqual(page["dn"], 1)

    def test_bots_are_marked_so_the_game_can_fold_them_away(self):
        page, _ = self.opened(activity={"comments": [{"id": "c", "author": {"login": "ci-bot", "isBot": True}, "body": "x", "createdAt": "2026-11-02T10:00:00.000Z"}]})
        self.assertTrue(page["ds"][0]["bt"])

    def test_a_review_thread_is_one_entry_with_its_replies(self):
        """T3 lists a thread's comments in both places. The game shows them once, like T3 does."""
        first = {"id": "r1", "kind": "review-comment", "author": {"login": "ann"}, "body": "Why this?", "createdAt": "2026-11-02T10:00:00.000Z"}
        reply = {"id": "r2", "kind": "review-comment", "author": {"login": "bob"}, "body": "Because.", "createdAt": "2026-11-02T11:00:00.000Z"}
        page, _ = self.opened(activity={"comments": [first, reply], "reviewThreads": [
            {"id": "t", "path": "a/b.lua", "line": 12, "isResolved": True, "isOutdated": True, "comments": [reply, first], "commentCount": 5}]})
        self.assertEqual(len(page["ds"]), 1)
        entry = page["ds"][0]
        self.assertEqual((entry["w"], entry["b"], entry["pa"], entry["ln"], entry["rs"], entry["ol"], entry["mr"]), ("ann", "Why this?", "a/b.lua", 12, True, True, 3))
        self.assertEqual(entry["re"][0][0], "bob")
        self.assertEqual(entry["re"][0][3], "Because.")

    def test_a_review_that_decided_something_stays_and_an_empty_one_goes(self):
        when = "2026-11-02T10:00:00.000Z"
        page, _ = self.opened(activity={"comments": [
            {"id": "1", "kind": "review", "author": {"login": "ann"}, "body": "", "reviewState": "APPROVED", "createdAt": when},
            {"id": "2", "kind": "review", "author": {"login": "bob"}, "body": "", "reviewState": "COMMENTED", "createdAt": when},
            {"id": "3", "kind": "review", "author": {"login": "cat"}, "body": "No.", "reviewState": "CHANGES_REQUESTED", "createdAt": when}]})
        self.assertEqual(sorted((entry["w"], entry.get("st")) for entry in page["ds"]), [("ann", "approved"), ("cat", "changes-requested")])

    def test_only_each_reviewers_latest_verdict_counts(self):
        page, _ = self.opened(activity={"comments": [
            {"id": "1", "kind": "review", "author": {"login": "ann"}, "body": "", "reviewState": "CHANGES_REQUESTED", "createdAt": "2026-11-01T10:00:00.000Z"},
            {"id": "2", "kind": "review", "author": {"login": "ann"}, "body": "", "reviewState": "APPROVED", "createdAt": "2026-11-02T10:00:00.000Z"},
            {"id": "3", "kind": "review", "author": {"login": "bob"}, "body": "", "reviewState": "APPROVED", "createdAt": "2026-11-01T10:00:00.000Z"},
            {"id": "4", "kind": "review", "author": {"login": "bob"}, "body": "", "reviewState": "DISMISSED", "createdAt": "2026-11-02T10:00:00.000Z"}]})
        self.assertEqual(page["rv"], [["ann", "approved"]])

    def test_the_timeline_is_everything_newest_first(self):
        page, _ = self.opened(detail={"author": {"login": "ann"}, "mergedAt": "2026-11-05T10:00:00.000Z"}, activity={
            "comments": [{"id": "c", "author": {"login": "bob"}, "body": "Hi", "createdAt": "2026-11-03T10:00:00.000Z"}],
            "commits": [{"oid": "abcdef1234", "messageHeadline": "Do it", "committedDate": "2026-11-02T10:00:00.000Z", "additions": 4, "deletions": 1}]})
        self.assertEqual([event[0] for event in page["tl"]], ["merged", "note", "commit", "opened"])
        self.assertEqual(page["tl"][2][2:], ["abcdef1", "Do it", 4, 1])
        self.assertEqual(page["ds"][page["tl"][1][2] - 1]["b"], "Hi", "a row points at its entry, from 1 like Lua")

    def test_html_and_pictures_become_something_the_game_can_draw(self):
        text = pullrequests.pull_request_text("<!-- hidden -->Before<br>after\n<details><summary>More</summary>\n\n![a chart](https://x/y.png) <img src='https://x/z.png'>\n</details>\n<a href='u'>link</a>")
        self.assertEqual(text, "Before\nafter\nMore\n\n[picture: a chart] [picture]\n\nlink")

    def test_the_tags_bots_really_use_go_too(self):
        self.assertEqual(pullrequests.pull_request_text("<dl><dt>Name</dt><dd>Value</dd></dl>"), "NameValue")

    def test_code_stays_exactly_as_written(self):
        text = "```html\n<div><br></div>\n![a](b)\n```"
        self.assertEqual(pullrequests.pull_request_text(text), text)

    def test_angle_brackets_that_arent_html_stay(self):
        self.assertEqual(pullrequests.pull_request_text("List<String> and a < b > c"), "List<String> and a < b > c")

    def test_a_comment_full_of_traps_doesnt_stall_anything(self):
        started = time.monotonic()
        for trap in ("<!--" * 20000, "<a " * 30000, "![" * 30000, "```\n" * 30000, "<img " * 20000):
            pullrequests.pull_request_text(trap)
        self.assertLess(time.monotonic() - started, 2)

    def test_a_long_comment_says_it_was_cut(self):
        self.assertIn("The rest is on the pull request", pullrequests.pull_request_text("word " * 10000))

    def test_a_secret_in_a_comment_gets_hidden(self):
        page, _ = self.opened(detail={"body": "password = correcthorsebattery"}, activity={
            "comments": [{"id": "c", "author": {"login": "ann"}, "body": "password = correcthorsebattery", "createdAt": "2026-11-02T10:00:00.000Z"}]})
        self.assertIn("password", page["ds"][0]["b"])
        self.assertNotIn("correcthorse", json.dumps(page))

    def test_past_the_budget_the_oldest_give_up_their_words(self):
        comments = [{"id": str(i), "author": {"login": "ann"}, "body": "x" * settings.MAX_PR_TEXT, "createdAt": f"2026-11-02T10:{i // 60:02d}:{i % 60:02d}.000Z"} for i in range(100)]
        with mock.patch.object(settings, "MAX_LOADED_BYTES", settings.MAX_PR_TEXT * 10):
            entries = pullrequests.pull_request_discussion({"comments": comments})
        self.assertTrue(entries[0]["cut"])
        self.assertEqual(entries[0]["b"], "")
        self.assertEqual(len(entries[-1]["b"]), settings.MAX_PR_TEXT)

    def test_when_t3_cuts_the_list_off_the_page_says_so(self):
        page, _ = self.opened(activity={"comments": [], "commentsTruncated": True})
        self.assertTrue(page["tr"])

    def test_half_an_answer_still_shows(self):
        bridge, remote = self.make(thread(pullRequests=[self.link(7, state="merged")]))
        remote.pr_detail = lambda *_args: {"body": "Words", "createdAt": "2026-11-01T10:00:00.000Z"}

        def broken(*_args):
            raise t3errors.SendRefused("the host said no")

        remote.pr_activity = broken
        delivery.deliver(bridge, [command(1, THREAD, "pr\n7")])
        self.assertEqual(bridge.state["results"]["1"], "sent")
        publishing.publish(bridge)
        page = bridge.snapshot["threads"][0]["pd"][1]
        self.assertEqual(page["b"], "Words")
        self.assertIn("the host said no", page["er"])
        self.assertNotIn("ds", page)

    def test_no_answer_says_why_instead_of_loading_forever(self):
        bridge, remote = self.make(thread(pullRequests=[self.link(7)]))

        def broken(*_args):
            raise t3errors.SendRefused("the host said no")

        remote.pr_detail = remote.pr_activity = broken
        delivery.deliver(bridge, [command(1, THREAD, "pr\n7")])
        self.assertIn("the host said no", bridge.state["results"]["1"])
        publishing.publish(bridge)
        self.assertIn("the host said no", bridge.snapshot["threads"][0]["pd"][1]["er"])

    def test_a_merged_one_doesnt_make_t3_go_and_look_at_its_checks(self):
        bridge, remote = self.make(thread(pullRequests=[self.link(7, state="merged")]))
        remote.pr_detail = lambda *_args: {"checks": [{"name": "ok", "status": "success"}], "createdAt": "2026-11-01T10:00:00.000Z"}
        remote.pr_activity = lambda *_args: {}
        remote.pr_checks = lambda *_args: self.fail("merged, so nothing to look for")
        delivery.deliver(bridge, [command(1, THREAD, "pr\n7")])
        self.assertEqual(bridge.state["results"]["1"], "sent")

    def test_the_game_can_only_ask_about_a_pull_request_on_that_thread(self):
        bridge, remote = self.make(thread(pullRequests=[self.link(7)]))
        remote.pr_detail = remote.pr_activity = remote.pr_checks = lambda *_args: self.fail("must not ask T3")
        delivery.deliver(bridge, [command(1, THREAD, "pr\n99"), command(2, THREAD, "pr\nnonsense")])
        for seq in "12":
            self.assertIn("isn't linked", bridge.state["results"][seq])

    def test_a_hidden_threads_page_isnt_fetched(self):
        bridge, remote = self.make(thread(pullRequests=[self.link(7)]))
        remote.pr_detail = remote.pr_activity = remote.pr_checks = lambda *_args: self.fail("must not ask T3")
        bridge.state["hidden"] = {"projects": [], "threads": [THREAD]}
        delivery.deliver(bridge, [command(1, THREAD, "pr\n7")])
        self.assertIn("hidden", bridge.state["results"]["1"])

    def test_the_page_doesnt_stay_in_the_game_folder(self):
        _, bridge = self.opened(detail={"body": "private words"})
        self.assertIn("private words", snapshots.render_snapshot(bridge.snapshot))
        bridge.loaded[THREAD]["until"] = time.monotonic() - 1
        publishing.publish(bridge)
        self.assertNotIn("private words", snapshots.render_snapshot(bridge.snapshot))


class PullRequests(Base):
    @staticmethod
    def link(state="open", checks="failing", number=42):
        return {"host": "github.com", "repository": "me/repo", "number": number,
                "snapshot": {"state": state, "title": "Fix it", "checksState": checks}}

    def test_checks_become_one_state(self):
        result = pullrequests.summarize_checks([
            {"name": "lint", "status": "success"}, {"name": "unit", "status": "failure"},
            {"name": "skipped one", "status": "skipped"}, {"name": "e2e", "status": "pending"},
        ])
        self.assertEqual(result, {"st": "failing", "p": 1, "t": 3, "f": ["unit"], "fn": 1})
        self.assertEqual(pullrequests.summarize_checks([{"name": "a", "status": "pending"}])["st"], "pending")
        self.assertEqual(pullrequests.summarize_checks([{"name": "a", "status": "success"}, {"name": "b", "status": "neutral"}])["st"], "passing")

    def test_only_three_names_ride_along(self):
        result = pullrequests.summarize_checks([{"name": str(n), "status": "failure"} for n in range(9)])
        self.assertEqual(len(result["f"]), 3)
        self.assertEqual(result["fn"], 9)

    def make(self, remote):
        return bridgestate.Bridge(self.wow, remote, state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json")

    def test_a_refresh_never_asks_t3_about_ci(self):
        # It held everything else up for a second or two, and only the raid boss needed it.
        link = dict(self.link(), snapshot=dict(self.link()["snapshot"], checksState="failing"))
        remote = FakeRemote(shell={"threads": [thread(pullRequests=[link])], "projects": []})
        remote.pr_checks = lambda *_: self.fail("must not ask T3")
        bridge = self.make(remote)
        refreshing.refresh(bridge)
        row = bridge.snapshot["threads"][0]
        self.assertNotIn("pr", row)
        self.assertEqual(row["prs"][0]["ck"], "failing", "T3's own summary is enough for the Sunder spell")


if __name__ == "__main__":
    unittest.main(verbosity=1)
