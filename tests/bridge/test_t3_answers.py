"""T3 answering in shapes we don't know, and the limits on what it can send."""
import http.server
import io
import json
import socket
import subprocess
import sys
import threading
import unittest
from unittest import mock

from bridge_helpers import Base, THREAD, thread
from promptpeon import bridgestate, cli, delivery, pairing, refreshing, settings, t3errors, t3remote, websocket


class T3Updates(Base):
    """T3's remote API isn't public, so an update can change any of it. Say so, and keep what's on screen."""

    GOOD = json.dumps({"threads": [thread()], "projects": [{"id": "p1", "title": "Shop"}]}).encode()

    def serve(self, status, body):
        """A real HTTP server, so this goes through the same code path as a real T3."""
        answer = {"status": status, "body": body}

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(answer["status"])
                self.send_header("Content-Length", str(len(answer["body"])))
                self.end_headers()
                self.wfile.write(answer["body"])

            def log_message(self, *_args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return answer, f"http://127.0.0.1:{server.server_address[1]}"

    def bridge(self, url):
        remote = t3remote.T3Remote(url, "test")
        remote.detail = lambda _id: {"rows": [["a", "words", "d", 1]]}
        return bridgestate.Bridge(self.wow, remote, state_dir=self.dir / "state", in_place=False, config_path=self.dir / "config.json")

    def test_every_way_t3_can_stop_making_sense_says_the_same_plain_thing(self):
        cases = {
            "a web page instead of data": (200, b"<html>T3</html>"),
            "no thread list": (200, b'{"chats": []}'),
            "a list instead of an object": (200, b"[]"),
            "threads of the wrong type": (200, b'{"threads": "none", "projects": []}'),
            "a thread with no id": (200, b'{"threads": [{"title": "x"}], "projects": []}'),
            "a protocol it no longer speaks": (400, b""),
            "a route it no longer has": (404, b'{"code": "not_found"}'),
            "upgrade required": (426, b""),
        }
        for name, (status, body) in cases.items():
            with self.subTest(name):
                answer, url = self.serve(200, self.GOOD)
                bridge = self.bridge(url)
                refreshing.refresh(bridge)
                self.assertEqual(bridge.error, "")
                self.assertEqual(len(bridge.snapshot["threads"]), 1)
                answer.update(status=status, body=body)
                refreshing.refresh(bridge)
                self.assertEqual(bridge.error, t3errors.T3_CHANGED)
                self.assertEqual(bridge.snapshot["err"], t3errors.T3_CHANGED)
                self.assertEqual(len(bridge.snapshot["threads"]), 1, "what you had stays on screen")
                answer.update(status=200, body=self.GOOD)
                refreshing.refresh(bridge)
                self.assertEqual(bridge.error, "", "and it recovers by itself")

    def test_other_failures_keep_their_own_words(self):
        answer, url = self.serve(500, b"")
        bridge = self.bridge(url)
        refreshing.refresh(bridge)
        self.assertIn("answered with an error (500)", bridge.error)
        answer.update(status=401)
        refreshing.refresh(bridge)
        self.assertIn("expired", bridge.error)

    def test_one_thread_in_a_new_shape_doesnt_take_the_log_down(self):
        _, url = self.serve(200, self.GOOD)
        bridge = self.bridge(url)
        bridge.remote.detail = lambda _id: {}["rows"]
        refreshing.refresh(bridge)
        self.assertEqual(bridge.error, "")
        self.assertEqual(len(bridge.snapshot["threads"]), 1)

    def test_a_field_in_a_new_shape_cant_crash_the_bridge(self):
        odd = json.dumps({"threads": [thread(modelSelection="a string now")], "projects": []}).encode()
        _, url = self.serve(200, odd)
        bridge = self.bridge(url)
        refreshing.refresh(bridge)
        self.assertEqual(bridge.error, t3errors.T3_CHANGED)

    def test_sending_while_t3_makes_no_sense_gives_your_words_back(self):
        _, url = self.serve(200, b'{"chats": []}')
        bridge = self.bridge(url)
        delivery.deliver(bridge, [{"seq": 1, "thread": THREAD, "text": "hello"}])
        self.assertIn("doesn't understand", bridge.state["results"]["1"])
        self.assertTrue(bridge.state["results"]["1"].startswith("failed:"), "failed means the addon gives the words back")

    def test_t3_not_understanding_a_call_is_not_t3_saying_no(self):
        # These are the real answers from T3 0.1.7, from a throwaway server.
        unknown = {"_tag": "Failure", "cause": [{"_tag": "Die", "defect": "Unknown request tag: no.such.method"}]}
        shape = {"_tag": "Failure", "cause": [{"_tag": "Die", "defect": 'Missing key\n  at ["threadId"]'}]}
        refused = {"_tag": "Failure", "cause": [{"_tag": "Fail", "error": {"_tag": "X", "message": "No orchestration projection exists for thread abc."}}]}
        bare = {"_tag": "Failure", "cause": [{"_tag": "Fail", "error": {"_tag": "AssetWorkspaceAssetNotFoundError"}}]}
        self.assertEqual(t3errors.describe_failure(unknown), t3errors.T3_DIDNT_UNDERSTAND)
        self.assertEqual(t3errors.describe_failure(shape), t3errors.T3_DIDNT_UNDERSTAND)
        self.assertEqual(t3errors.describe_failure(refused), "No orchestration projection exists for thread abc.")
        self.assertEqual(t3errors.describe_failure(bare), "T3 refused that.", "raw JSON never reaches the game")


class ThroughTheInternet(Base):
    """T3 Connect sits behind Cloudflare, which refused every request until the app said who it was."""

    def serve(self, reply):
        seen = {}

        class Handler(http.server.BaseHTTPRequestHandler):
            def answer(self):
                seen["agent"] = self.headers.get("User-Agent")
                self.rfile.read(int(self.headers.get("Content-Length") or 0))
                body = json.dumps(reply).encode()
                self.send_response(200)
                self.end_headers()
                self.wfile.write(body)

            do_GET = do_POST = answer

            def log_message(self, *_args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        return server.server_address[1], seen

    def test_a_link_says_who_is_asking(self):
        port, seen = self.serve({"access_token": "t", "scope": " ".join(settings.BASE_SCOPES)})
        self.assertEqual(pairing.exchange_pair_code(f"http://127.0.0.1:{port}", "code", settings.BASE_SCOPES), "t")
        self.assertEqual(seen["agent"], settings.USER_AGENT)
        self.assertNotIn("Python", settings.USER_AGENT)

    def test_so_does_the_websocket(self):
        listener = socket.create_server(("127.0.0.1", 0))
        self.addCleanup(listener.close)
        heard = []

        def once():
            connection, _ = listener.accept()
            heard.append(connection.recv(4096))
            connection.close()

        threading.Thread(target=once, daemon=True).start()
        with self.assertRaises((websocket.WebSocketClosed, OSError)):
            websocket.WebSocket(f"ws://127.0.0.1:{listener.getsockname()[1]}/ws")
        self.assertIn(f"User-Agent: {settings.USER_AGENT}".encode(), heard[0])

    def lsof_says(self, port):
        return mock.Mock(stdout=f"cloudflared 1 me 7u IPv4 0t0 TCP 127.0.0.1:{port} (LISTEN)\n", returncode=0)

    def test_it_finds_t3_connects_address_like_t3_does(self):
        port, _ = self.serve({"config": {"ingress": [{"service": "http_status:404"}, {"hostname": "my-machine.example", "service": "x"}]}})
        with mock.patch.object(subprocess, "run", return_value=self.lsof_says(port)):
            self.assertEqual(pairing.connect_address(), "https://my-machine.example")

    def test_no_tunnel_means_no_address(self):
        with mock.patch.object(subprocess, "run", side_effect=OSError("no lsof")):
            self.assertIsNone(pairing.connect_address())
        with mock.patch.object(subprocess, "run", return_value=mock.Mock(stdout="", returncode=1)):
            self.assertIsNone(pairing.connect_address())

    def test_a_failed_link_exits_with_an_error(self):
        with mock.patch.object(pairing, "make_link", return_value=1), mock.patch.object(sys, "argv", ["bridge", "link"]), \
                self.assertRaises(SystemExit) as caught:
            cli.main()
        self.assertEqual(caught.exception.code, 1)

    def run_make_link(self, *, address="https://my-machine.example", program="/bin/t3", answer=None):
        calls, printed = [], io.StringIO()

        def run(command, **_kw):
            calls.append(command)
            return mock.Mock(stdout=answer if answer is not None else json.dumps({"pairUrl": f"{address}/pair#token=abc"}), returncode=0)

        with mock.patch.object(pairing, "t3_program", return_value=program), mock.patch.object(pairing, "connect_address", return_value=address), \
                mock.patch.object(subprocess, "run", side_effect=run), mock.patch("sys.stdout", printed):
            code = pairing.make_link()
        return code, printed.getvalue(), calls

    def test_the_link_allows_only_what_the_app_can_ask_for(self):
        code, printed, calls = self.run_make_link()
        self.assertEqual(code, 0)
        self.assertIn("https://my-machine.example/pair#token=abc", printed)
        self.assertIn("double-click install.cmd", printed)
        self.assertIn("15 minutes", printed)
        scopes = [calls[0][index + 1] for index, word in enumerate(calls[0]) if word == "--scope"]
        self.assertEqual(scopes, settings.BASE_SCOPES + [settings.PICTURE_SCOPE])
        self.assertIn("15m", calls[0])

    def test_on_the_wrong_machine_it_says_where_to_run_it(self):
        _, printed, _ = self.run_make_link(address=None)
        self.assertIn("the machine your threads are on, not the one you play on", printed)

    def test_the_installer_can_read_what_it_prints(self):
        _, printed, _ = self.run_make_link()
        self.assertEqual(pairing.parse_pair_link(printed), ("https://my-machine.example", "abc"))

    def test_it_explains_when_it_cant(self):
        code, printed, calls = self.run_make_link(program=None)
        self.assertEqual((code, calls), (1, []))
        self.assertIn("T3 isn't on this machine", printed)
        code, printed, calls = self.run_make_link(address=None)
        self.assertEqual((code, calls), (1, []))
        self.assertIn("Couldn't find T3 Connect", printed)
        code, printed, _ = self.run_make_link(answer="not json")
        self.assertEqual(code, 1)
        self.assertIn("didn't make a link", printed)


class Transport(unittest.TestCase):
    def test_an_encrypted_address_is_never_downgraded(self):
        remote = t3remote.T3Remote("https://t3.example.net", "token")
        opened = []

        class Stop(Exception):
            pass

        def fake_socket(url):
            opened.append(url)
            raise websocket.WebSocketClosed("stop here")

        with mock.patch.object(remote, "_request", return_value={"ticket": "t", "token": "t", "wsTicket": "t"}), mock.patch.object(websocket, "WebSocket", fake_socket):
            try:
                remote._rpc("x", {})
            except (t3errors.SendRefused, t3errors.SendUncertain):
                pass
        self.assertTrue(opened and opened[0].startswith("wss://t3.example.net/ws"), opened)

    def test_a_redirect_is_not_followed_with_our_token(self):
        self.assertIsNone(t3remote._NoRedirects().redirect_request(None, None, 302, "moved", {}, "http://elsewhere/"))

    def test_plain_addresses_on_a_network_are_flagged(self):
        self.assertTrue(pairing.is_plain_over_network("http://192.168.1.5:3773"))
        self.assertFalse(pairing.is_plain_over_network("http://127.0.0.1:3773"))
        self.assertFalse(pairing.is_plain_over_network("http://localhost:3773"))
        self.assertFalse(pairing.is_plain_over_network("https://t3.example.net"))

    def test_nobody_home_means_no_plain_network(self):
        with mock.patch.object(sys.stdin, "isatty", lambda: False), self.assertRaises(SystemExit):
            pairing.accept_plain_network("http://192.168.1.5:3773", False)
        pairing.accept_plain_network("http://192.168.1.5:3773", True)

    def test_saying_no_stops_it(self):
        with mock.patch.object(sys.stdin, "isatty", lambda: True), mock.patch("builtins.input", return_value=""), self.assertRaises(SystemExit):
            pairing.accept_plain_network("http://192.168.1.5:3773", False)


if __name__ == "__main__":
    unittest.main(verbosity=1)
