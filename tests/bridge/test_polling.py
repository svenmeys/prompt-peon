"""How often the app asks T3. Gentler through T3 Connect, because that crosses T3's own relay."""
import re
import unittest
from unittest import mock

from bridge_helpers import FakeRemote, ROOT
from promptpeon import publishing, refreshing, settings


class HowOftenItAsks(unittest.TestCase):
    def test_your_own_machines_stay_quick(self):
        for url in ("http://127.0.0.1:3773", "http://localhost:3999", "https://mac.tail1234.ts.net", "http://192.168.1.5:3773"):
            self.assertEqual(refreshing.seconds_between(url), 5, url)

    def test_t3_connect_goes_easier(self):
        for url in ("https://prod-eff9ddc75373f5a0.t3coderelay.com", "https://PROD-X.T3CODERELAY.COM/", "https://t3coderelay.com"):
            self.assertEqual(refreshing.seconds_between(url), 15, url)

    def test_a_lookalike_address_isnt_t3_connect(self):
        for url in ("https://t3coderelay.com.example.net", "https://nott3coderelay.com", "https://example.net/t3coderelay.com"):
            self.assertEqual(refreshing.seconds_between(url), 5, url)


class TheGameStillHearsFromUs(unittest.TestCase):
    """The game says the app has gone quiet at 45 seconds, so a slower T3 mustn't mean a slower heartbeat."""

    def bridge(self, last_write_at):
        return mock.Mock(remote=FakeRemote(), last_write_at=last_write_at)

    def tick(self, bridge, *, now, next_refresh):
        with mock.patch.object(refreshing.time, "monotonic", return_value=now), \
                mock.patch.object(refreshing, "refresh") as self.asked, mock.patch.object(publishing, "publish") as self.published:
            return refreshing.keep_fresh(bridge, next_refresh)

    def test_when_its_time_it_asks_t3_and_sets_the_next_time(self):
        self.assertEqual(self.tick(self.bridge(0), now=1000, next_refresh=1000), 1005)
        self.asked.assert_called_once()

    def test_between_asks_it_leaves_t3_alone(self):
        self.assertEqual(self.tick(self.bridge(995), now=1000, next_refresh=1010), 1010)
        self.asked.assert_not_called()
        self.published.assert_not_called()

    def test_a_heartbeat_goes_out_without_asking_t3(self):
        self.assertEqual(self.tick(self.bridge(1000 - settings.HEARTBEAT_SECONDS), now=1000, next_refresh=1010), 1010)
        self.asked.assert_not_called()
        self.published.assert_called_once()

    def test_the_heartbeat_is_well_inside_what_the_game_allows(self):
        quiet_after = int(re.search(r"ns\.BRIDGE_QUIET_AFTER = (\d+)", (ROOT / "addon/PromptPeon/Core.lua").read_text()).group(1))
        self.assertLess(settings.HEARTBEAT_SECONDS + 5, quiet_after)


if __name__ == "__main__":
    unittest.main(verbosity=1)
