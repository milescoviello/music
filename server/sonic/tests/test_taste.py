import json
import sqlite3
import tempfile
import threading
import unittest
import urllib.request
from datetime import date
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

from sonic.http import make_handler
from sonic.radar import Radar
from sonic.taste import TasteStore


class Taste(unittest.TestCase):
    """Each device reads the others' plays and skips, once, in order."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.store = TasteStore(Path(folder.name) / "taste.db")

    def event(self, ident, kind="play", at=1.0):
        return {"id": ident, "kind": kind, "at": at, "songID": "s", "title": "T", "artist": "A"}

    def test_a_device_reads_the_others_and_not_its_own(self):
        self.store.add("phone", [self.event("p1"), self.event("p2", "skip")])
        self.store.add("desktop", [self.event("d1")])
        phone = self.store.since(0, "phone")
        self.assertEqual([e["id"] for e in phone["events"]], ["d1"])
        desktop = self.store.since(0, "desktop")
        self.assertEqual([e["id"] for e in desktop["events"]], ["p1", "p2"])
        # Carrying on from where it got to finds nothing new.
        self.assertEqual(self.store.since(phone["seq"], "phone")["events"], [])

    def test_sending_twice_is_harmless(self):
        self.store.add("phone", [self.event("p1")])
        result = self.store.add("phone", [self.event("p1"), self.event("p2")])
        self.assertEqual(result["added"], 1)
        self.assertEqual(len(self.store.since(0, "desktop")["events"]), 2)

    def test_nonsense_is_refused(self):
        with self.assertRaises(ValueError):
            self.store.add("phone", [{"id": "x", "kind": "dance", "at": 1}])
        with self.assertRaises(ValueError):
            self.store.add("", [self.event("p1")])

    def test_a_long_read_is_paged(self):
        self.store.add("phone", [self.event(f"p{n}") for n in range(10)])
        first = self.store.since(0, "desktop", limit=4)
        self.assertEqual(len(first["events"]), 4)
        rest = self.store.since(first["seq"], "desktop", limit=100)
        self.assertEqual(len(rest["events"]), 6)

    def test_over_http(self):
        service = SimpleNamespace(config=SimpleNamespace(token="", data_dir=Path(tempfile.mkdtemp())), taste=self.store)
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(service))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        base = f"http://127.0.0.1:{server.server_address[1]}"
        body = json.dumps({"device": "phone", "events": [self.event("p1")]}).encode()
        request = urllib.request.Request(base + "/v1/taste", data=body, method="POST",
                                         headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=5) as response:
            self.assertEqual(json.loads(response.read())["added"], 1)
        with urllib.request.urlopen(base + "/v1/taste?since=0&device=desktop", timeout=5) as response:
            self.assertEqual([e["id"] for e in json.loads(response.read())["events"]], ["p1"])


class ReleaseRadar(unittest.TestCase):
    """New releases by artists played, that the library lacks."""

    def setUp(self):
        folder = Path(tempfile.mkdtemp())
        self.db = folder / "navidrome.db"
        connection = sqlite3.connect(self.db)
        connection.executescript("""
            create table artist (id text, name text, mbz_artist_id text);
            create table annotation (item_id text, item_type text, play_count int, play_date text);
            create table album (name text, album_artist text, album_artist_id text);
            insert into artist values ('a1', 'Panchiko', 'mb-panchiko');
            insert into annotation values ('a1', 'artist', 1700, '2026-11-03');
            insert into album values ('Ginkgo', 'Panchiko', 'a1');
        """)
        connection.commit()
        connection.close()
        self.path = folder / "radar.json"

    def fetch(self, path, params):
        self.assertEqual(params["artist"], "mb-panchiko")
        return {"release-groups": [
            {"id": "g1", "title": "Ginkgo", "primary-type": "Album", "first-release-date": "2025-04-04"},
            {"id": "g2", "title": "Ginkgo (Deluxe Edition)", "primary-type": "Album", "first-release-date": "2026-09-01"},
            {"id": "g3", "title": "Rise and Fall", "primary-type": "Single", "first-release-date": "2026-10-10"},
            {"id": "g4", "title": "Live in Nottingham", "primary-type": "Album", "secondary-types": ["Live"], "first-release-date": "2026-08-01"},
            {"id": "g5", "title": "Deathmetal", "primary-type": "Album", "first-release-date": "2000"},
            {"id": "g6", "title": "Coming Soon", "primary-type": "EP", "first-release-date": "2026-12-01"},
        ]}

    def test_covers_are_kept_and_a_missing_one_remembered(self):
        radar = Radar(self.db, self.path, fetch=self.fetch)
        calls = []
        def fetch(group):
            calls.append(group)
            return b"jpeg" if group.startswith("1") else None
        good, bad = "123915e0-65c6-4d3e-a150-e1c4914f6f31", "ff346c66-de17-4a5e-b6df-100880ee0d35"
        self.assertEqual(radar.cover(good, fetch=fetch), b"jpeg")
        self.assertEqual(radar.cover(good, fetch=fetch), b"jpeg")
        self.assertIsNone(radar.cover(bad, fetch=fetch))
        self.assertIsNone(radar.cover(bad, fetch=fetch))
        self.assertEqual(calls, [good, bad])
        self.assertIsNone(radar.cover("../../etc/passwd", fetch=fetch))

    def test_only_new_and_missing_releases(self):
        radar = Radar(self.db, self.path, fetch=self.fetch)
        items = radar.build(today=date(2026, 11, 3))
        self.assertEqual([item["title"] for item in items], ["Coming Soon", "Rise and Fall"])
        self.assertTrue(items[0]["upcoming"])
        self.assertIn("coverartarchive.org/release-group/g3", items[1]["cover"])


if __name__ == "__main__":
    unittest.main()
