"""Connecting to T3: the first run, pairing links and looking after the token."""
import contextlib
import io
import json
import os
import sys
import unittest
import urllib.error
from unittest import mock

from bridge_helpers import Base, FakeRemote
from promptpeon import pairing, processes, prompts, settings, t3remote


class FirstRun(Base):
    LINK = "https://other-machine.example/pair#token=ABC123"

    def setUp(self):
        super().setUp()
        self.answers, self.prompts = [], []
        self.exchanged = []
        def answer(prompt):
            self.prompts.append(prompt)
            return self.answers.pop(0) if self.answers else ""
        for patcher in (mock.patch.object(settings, "CONFIG_DIR", self.dir), mock.patch.object(sys.stdin, "isatty", return_value=True),
                        mock.patch.object(prompts, "ask", side_effect=answer), mock.patch.object(pairing, "t3_program", return_value=None),
                        mock.patch.object(t3remote, "T3Remote", side_effect=lambda url, token: FakeRemote()),
                        mock.patch.object(pairing, "exchange_pair_code", side_effect=lambda url, code, scopes: self.exchanged.append((url, code, scopes)) or "fresh-token")):
            patcher.start()
            self.addCleanup(patcher.stop)

    def connected_already(self):
        (self.dir / "config.json").write_text(json.dumps({"url": "https://old.example", "pictures": False}))
        (self.dir / "token").write_text("old-token")

    def test_a_first_install_needs_only_a_pasted_link(self):
        self.answers = [self.LINK, "y", "n"]
        self.assertEqual(pairing.connect_to_t3(None, None, None), "https://other-machine.example")
        self.assertEqual(self.exchanged[0][2], settings.BASE_SCOPES)

    def test_the_questions_come_in_the_order_you_can_answer_them(self):
        self.answers = [self.LINK, "y", "y"]
        pairing.connect_to_t3(None, None, None)
        self.assertIn("Paste", self.prompts[0])
        self.assertIn("your own machine", self.prompts[1])
        self.assertIn("pictures", self.prompts[2])
        self.assertEqual(self.exchanged[0][2], settings.BASE_SCOPES + [settings.PICTURE_SCOPE])

    def test_a_bad_paste_asks_again(self):
        self.answers = ["https://not-a-pair-link.example", self.LINK, "y", "n"]
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            self.assertEqual(pairing.connect_to_t3(None, None, None), "https://other-machine.example")
        self.assertIn("/pair#token=", printed.getvalue())

    def test_giving_up_on_pasting_changes_nothing(self):
        self.answers = ["https://not-a-pair-link.example", "https://nope.example", "https://nope-again.example"]
        with self.assertRaises(SystemExit):
            pairing.connect_to_t3(None, None, None)
        self.assertFalse((self.dir / "token").exists())

    def test_a_whole_old_command_line_pasted_still_works(self):
        self.answers = [f'install.cmd --link "{self.LINK}"', "y", "n"]
        self.assertEqual(pairing.connect_to_t3(None, None, None), "https://other-machine.example")

    def test_running_it_again_keeps_the_connection_on_enter(self):
        self.connected_already()
        self.answers = [""]
        self.assertEqual(pairing.connect_to_t3(None, None, None), "https://old.example")
        self.assertEqual(self.exchanged, [])
        self.assertIn("paste", self.prompts[0])

    def test_running_it_again_can_move_with_a_pasted_link(self):
        self.connected_already()
        self.answers = [self.LINK, "y", "n"]
        self.assertEqual(pairing.connect_to_t3(None, None, None), "https://other-machine.example")
        self.assertEqual((self.dir / "token").read_text(), "fresh-token")

    def test_with_nobody_there_it_doesnt_ask(self):
        self.connected_already()
        with mock.patch.object(sys.stdin, "isatty", return_value=False):
            self.assertEqual(pairing.connect_to_t3(None, None, None), "https://old.example")
        self.assertEqual(self.prompts, [])

    def test_wow_being_open_comes_up_first(self):
        with mock.patch.object(processes, "game_running", side_effect=[True, False]):
            prompts.wait_for_game_to_close(self.wow)
        self.assertIn("Close", self.prompts[0])

    def test_wow_still_open_stops_with_a_plain_message(self):
        with mock.patch.object(processes, "game_running", return_value=True), self.assertRaises(SystemExit) as caught:
            prompts.wait_for_game_to_close(self.wow)
        self.assertIn("still open", str(caught.exception))

    def test_wow_closed_asks_nothing(self):
        with mock.patch.object(processes, "game_running", return_value=False):
            prompts.wait_for_game_to_close(self.wow)
        self.assertEqual(self.prompts, [])

    def test_a_deploy_with_nobody_there_isnt_stopped_by_an_open_game(self):
        with mock.patch.object(processes, "game_running", return_value=True), mock.patch.object(sys.stdin, "isatty", return_value=False):
            prompts.wait_for_game_to_close(self.wow)


class Pairing(Base):
    def setUp(self):
        super().setUp()
        patches = [mock.patch.object(settings, "CONFIG_DIR", self.dir / "cfg"), mock.patch.object(pairing, "t3_program", lambda: None),
                   mock.patch.object(sys.stdin, "isatty", lambda: False)]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def test_reads_every_form_of_a_pairing_link(self):
        wanted = ("http://192.168.1.5:3773", "ABC123")
        self.assertEqual(pairing.parse_pair_link("http://192.168.1.5:3773/pair#token=ABC123"), wanted)
        self.assertEqual(pairing.parse_pair_link("  http://192.168.1.5:3773/pair#token=ABC123\n"), wanted)
        self.assertEqual(pairing.parse_pair_link("t3code://pair?pairingUrl=http%3A%2F%2F192.168.1.5%3A3773%2Fpair%23token%3DABC123"), wanted)
        self.assertEqual(pairing.parse_pair_link("https://t3.example.ts.net/pair#token=ABC123")[0], "https://t3.example.ts.net")
        self.assertIsNone(pairing.parse_pair_link("hello"))
        self.assertIsNone(pairing.parse_pair_link("http://192.168.1.5:3773/"))

    def connect(self, shell_works=True, **kwargs):
        with mock.patch.object(t3remote, "T3Remote") as remote:
            remote.return_value.shell.return_value = {"threads": []}
            if not shell_works:
                remote.return_value.shell.side_effect = OSError("no route")
            with mock.patch.object(pairing, "exchange_pair_code", return_value="minted") as exchange:
                url = pairing.connect_to_t3(kwargs.get("url"), kwargs.get("link"), kwargs.get("pictures"), allow_unencrypted=True)
        return url, exchange

    def test_a_link_gives_the_address_and_token(self):
        url, exchange = self.connect(link="http://h:3773/pair#token=C", pictures=True)
        self.assertEqual(url, "http://h:3773")
        self.assertEqual((self.dir / "cfg/token").read_text(), "minted")
        self.assertEqual(exchange.call_args[0][2], ["orchestration:read", "orchestration:operate", "filesystem:read"])

    def test_you_can_opt_out_of_file_reading(self):
        _, exchange = self.connect(link="http://h:3773/pair#token=C", pictures=False)
        self.assertEqual(exchange.call_args[0][2], ["orchestration:read", "orchestration:operate"])

    def test_nobody_gets_file_reading_without_being_asked(self):
        _, exchange = self.connect(link="http://h:3773/pair#token=C")
        self.assertNotIn("filesystem:read", exchange.call_args[0][2])

    def test_it_asks_when_it_can_and_no_is_the_easy_answer(self):
        # Reading any file on the T3 machine is too much to hand over by pressing Enter.
        with mock.patch.object(sys.stdin, "isatty", lambda: True):
            with mock.patch("builtins.input", return_value=""):
                self.assertFalse(prompts.wants_pictures(None))
            with mock.patch("builtins.input", return_value="yes"):
                self.assertTrue(prompts.wants_pictures(None))

    def test_a_working_install_asks_nothing(self):
        (self.dir / "cfg").mkdir()
        (self.dir / "cfg/token").write_text("old")
        (self.dir / "cfg/config.json").write_text(json.dumps({"url": "http://h:3773"}))
        with mock.patch("builtins.input", side_effect=AssertionError("asked a question")):
            url, exchange = self.connect()
        self.assertEqual(url, "http://h:3773")
        exchange.assert_not_called()
        self.assertEqual((self.dir / "cfg/token").read_text(), "old")

    def test_t3_being_away_does_not_lose_the_settings(self):
        (self.dir / "cfg").mkdir()
        (self.dir / "cfg/token").write_text("old")
        (self.dir / "cfg/config.json").write_text(json.dumps({"url": "http://h:3773"}))
        url, _ = self.connect(shell_works=False)
        self.assertEqual(url, "http://h:3773")
        self.assertEqual((self.dir / "cfg/token").read_text(), "old")

    def test_an_expired_link_asks_for_a_new_one(self):
        (self.dir / "cfg").mkdir()
        (self.dir / "cfg/token").write_text("old")
        (self.dir / "cfg/config.json").write_text(json.dumps({"url": "http://h:3773"}))
        calls = []

        def shell_for(url, token):
            fake = mock.Mock()
            calls.append(token)
            fake.shell.side_effect = (urllib.error.HTTPError("u", 401, "no", {}, None) if token == "old" else None)
            fake.shell.return_value = {"threads": []}
            return fake

        with mock.patch.object(t3remote, "T3Remote", shell_for), mock.patch.object(pairing, "exchange_pair_code", return_value="fresh"):
            with mock.patch("builtins.input", return_value="http://new:3773/pair#token=C"):
                url = pairing.connect_to_t3(None, None, None, allow_unencrypted=True)
        self.assertEqual(url, "http://new:3773")
        self.assertEqual((self.dir / "cfg/token").read_text(), "fresh")

    def test_rubbish_changes_nothing(self):
        with mock.patch("builtins.input", return_value="http://not-a-pairing-link"), self.assertRaises(SystemExit):
            pairing.connect_to_t3(None, None, False)
        self.assertFalse((self.dir / "cfg/token").exists())

    def test_with_t3_here_you_can_still_choose_another_machine(self):
        with mock.patch.object(pairing, "t3_program", lambda: "t3"), mock.patch.object(pairing, "t3_answers", lambda _: True), \
                mock.patch.object(sys.stdin, "isatty", lambda: True), mock.patch("builtins.input", side_effect=["http://other:3773/pair#token=C", "yes"]), \
                mock.patch.object(pairing, "issue_local_token", side_effect=AssertionError("used the local one")):
            url, _ = self.connect(pictures=False)
        self.assertEqual(url, "http://other:3773")

    def test_with_t3_here_enter_means_use_it(self):
        with mock.patch.object(pairing, "t3_program", lambda: "t3"), mock.patch.object(pairing, "t3_answers", lambda _: True), \
                mock.patch.object(sys.stdin, "isatty", lambda: True), mock.patch("builtins.input", return_value=""), \
                mock.patch.object(pairing, "issue_local_token", return_value="local"):
            url, _ = self.connect(pictures=False)
        self.assertEqual(url, settings.DEFAULT_URL)
        self.assertEqual((self.dir / "cfg/token").read_text(), "local")

    def test_t3_on_this_machine_needs_no_link(self):
        with mock.patch.object(pairing, "t3_program", return_value="/bin/t3"), mock.patch.object(pairing, "t3_answers", return_value=True), \
                mock.patch.object(pairing, "issue_local_token", return_value="local") as issue, mock.patch("builtins.input", side_effect=AssertionError("asked")):
            url, exchange = self.connect(pictures=True)
        self.assertEqual(url, settings.DEFAULT_URL)
        self.assertEqual((self.dir / "cfg/token").read_text(), "local")
        self.assertIn("filesystem:read", issue.call_args[0][0])
        exchange.assert_not_called()

    @unittest.skipIf(os.name == "nt", "Windows has no such permission bits")
    def test_the_token_is_only_yours(self):
        self.connect(link="http://h:3773/pair#token=C", pictures=False)
        self.assertEqual((self.dir / "cfg/token").stat().st_mode & 0o777, 0o600)


class PairingExchange(unittest.TestCase):
    def exchange(self, scope, wanted=None):
        response = io.BytesIO(json.dumps({"access_token": "t", "scope": scope}).encode())
        with mock.patch.object(t3remote.NO_REDIRECTS, "open", return_value=response) as opened:
            token = pairing.exchange_pair_code("http://h:1", "code", wanted or settings.BASE_SCOPES + [settings.PICTURE_SCOPE])
        return token, opened.call_args[0][0]

    def test_asks_only_for_what_it_needs(self):
        token, request = self.exchange("orchestration:read orchestration:operate filesystem:read")
        self.assertEqual(token, "t")
        self.assertEqual(request.full_url, "http://h:1/oauth/token")
        self.assertIn(b"subject_token=code", request.data)
        self.assertIn(b"scope=orchestration%3Aread+orchestration%3Aoperate+filesystem%3Aread", request.data)

    def test_a_link_that_can_not_send_is_refused(self):
        with self.assertRaises(SystemExit) as stopped:
            self.exchange("orchestration:read")
        self.assertIn("reading and sending", str(stopped.exception))

    def test_a_link_without_file_reading_still_works(self):
        with mock.patch("builtins.print") as said:
            token, _ = self.exchange("orchestration:read orchestration:operate")
        self.assertEqual(token, "t")
        self.assertIn("pictures from files stay off", said.call_args[0][0])


class TokenSafety(Base):
    def setUp(self):
        super().setUp()
        patches = [mock.patch.object(settings, "CONFIG_DIR", self.dir / "cfg"), mock.patch.object(pairing, "t3_program", lambda: None),
                   mock.patch.object(sys.stdin, "isatty", lambda: False)]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        (self.dir / "cfg").mkdir()
        (self.dir / "cfg/token").write_text("old")
        (self.dir / "cfg/config.json").write_text(json.dumps({"url": "http://127.0.0.1:3773"}))

    def test_a_saved_token_never_goes_to_a_new_address(self):
        tried = []

        def remote_for(url, token):
            tried.append((url, token))
            fake = mock.Mock()
            fake.shell.return_value = {"threads": []}
            return fake

        with mock.patch.object(t3remote, "T3Remote", remote_for), mock.patch("builtins.input", return_value="new-token"):
            pairing.connect_to_t3("http://wrong-host:3773", None, False, allow_unencrypted=True)
        self.assertNotIn(("http://wrong-host:3773", "old"), tried)

    def test_a_bad_new_link_leaves_the_working_token_alone(self):
        fake = mock.Mock()
        fake.shell.side_effect = OSError("no route")
        with mock.patch.object(t3remote, "T3Remote", return_value=fake), mock.patch.object(pairing, "exchange_pair_code", return_value="new"), self.assertRaises(SystemExit):
            pairing.connect_to_t3(None, "http://127.0.0.1:1/pair#token=C", False)
        self.assertEqual((self.dir / "cfg/token").read_text(), "old")

    def test_the_picture_answer_is_written_down(self):
        fake = mock.Mock()
        fake.shell.return_value = {"threads": []}
        with mock.patch.object(t3remote, "T3Remote", return_value=fake), mock.patch.object(pairing, "exchange_pair_code", return_value="new"):
            pairing.connect_to_t3(None, "http://127.0.0.1:1/pair#token=C", False)
        self.assertIs(json.loads((self.dir / "cfg/config.json").read_text())["pictures"], False)


class PairingScopes(unittest.TestCase):
    def exchange(self, answer, wanted):
        response = io.BytesIO(json.dumps(answer).encode())
        with mock.patch.object(t3remote.NO_REDIRECTS, "open", return_value=response):
            return pairing.exchange_pair_code("http://h:1", "code", wanted)

    def test_more_access_than_we_asked_for_is_refused(self):
        with self.assertRaises(SystemExit):
            self.exchange({"access_token": "t", "scope": "orchestration:read orchestration:operate filesystem:read"}, settings.BASE_SCOPES)

    def test_an_answer_that_doesnt_say_is_refused(self):
        with self.assertRaises(SystemExit):
            self.exchange({"access_token": "t"}, settings.BASE_SCOPES)


if __name__ == "__main__":
    unittest.main(verbosity=1)
