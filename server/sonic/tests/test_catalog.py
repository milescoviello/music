import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

from sonic import catalog
from sonic.http import make_handler


def track(title, artist, album, album_artist=None):
    return SimpleNamespace(title=title, artist=artist, album=album, album_artist=album_artist or artist)


LIBRARY = [
    track("Low Tide (Remastered 2011)", "Glass Harbor", "Salt Year"),
    track("Paper Moons", "Guest Singer", "Night Ferry", album_artist="Glass Harbor"),
]


class Marking(unittest.TestCase):
    """Whether a catalog answer is in the library already."""

    def setUp(self):
        self.have = catalog.Have(LIBRARY)

    def test_a_song_is_had_whatever_its_version_tag(self):
        self.assertTrue(self.have.song(["Glass Harbor"], "Low Tide"))
        self.assertTrue(self.have.song(["glass harbor"], "Low Tide - Radio Edit"))
        self.assertFalse(self.have.song(["Glass Harbor"], "High Tide"))

    def test_the_album_artist_counts_for_a_guest_track(self):
        self.assertTrue(self.have.song(["Glass Harbor"], "Paper Moons"))
        self.assertTrue(self.have.album(["Glass Harbor"], "Night Ferry (Deluxe)"))

    def test_another_artist_with_the_same_title_is_not_had(self):
        self.assertFalse(self.have.album(["Other Band"], "Salt Year"))


class Shaping(unittest.TestCase):
    def test_songs_keep_their_album_and_the_largest_cover(self):
        results = [{"title": "Low Tide", "artists": [{"name": "Glass Harbor"}], "album": {"name": "Salt Year", "id": "MPREb_1"},
                    "duration_seconds": 241, "videoId": "abcdefghijk",
                    "thumbnails": [{"url": "small", "width": 60}, {"url": "big", "width": 544}]},
                   {"title": "No Artist", "artists": []}]
        songs = catalog.songs_from(results, catalog.Have(LIBRARY))
        self.assertEqual(len(songs), 1)
        self.assertEqual(songs[0]["cover"], "big")
        self.assertEqual(songs[0]["albumId"], "MPREb_1")
        self.assertTrue(songs[0]["have"])

    def test_albums_need_an_id_to_be_got(self):
        results = [{"title": "Salt Year", "artists": [{"name": "Glass Harbor"}], "browseId": "MPREb_1", "year": "2009"},
                   {"title": "Unreachable", "artists": [{"name": "Glass Harbor"}]}]
        albums = catalog.albums_from(results, catalog.Have(LIBRARY))
        self.assertEqual([a["title"] for a in albums], ["Salt Year"])
        self.assertTrue(albums[0]["have"])

    def test_a_discography_is_the_artists_own_records_once_each(self):
        groups = [
            {"id": "2", "title": "Night Ferry", "primary-type": "Album", "first-release-date": "2012-03-01"},
            {"id": "1", "title": "Salt Year", "primary-type": "Album", "first-release-date": "2009"},
            {"id": "3", "title": "Live at the Pier", "primary-type": "Album", "secondary-types": ["Live"]},
            {"id": "4", "title": "Greatest Tides", "primary-type": "Album", "secondary-types": ["Compilation"]},
            {"id": "5", "title": "Salt Year", "primary-type": "Album", "first-release-date": "2019"},
            {"id": "6", "title": "Quiet Hours", "primary-type": "EP", "first-release-date": "2014"},
            {"id": "7", "title": "Low Tide", "primary-type": "Single", "first-release-date": "2008"},
        ]
        albums = catalog.discography_from(groups, catalog.Have(LIBRARY), "Glass Harbor")
        self.assertEqual([(a["title"], a["year"], a["have"]) for a in albums],
                         [("Salt Year", "2009", True), ("Night Ferry", "2012", True), ("Quiet Hours", "2014", False)])


class FakeGrab(BaseHTTPRequestHandler):
    seen: list = []

    def do_GET(self):  # noqa: N802
        self._answer(200, {"items": [], "path": self.path})

    def do_POST(self):  # noqa: N802
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}")
        FakeGrab.seen.append((self.path, body))
        self._answer(400 if body.get("bad") else 200, {"error": "bad"} if body.get("bad") else {"state": "searching"})

    def _answer(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


class Relaying(unittest.TestCase):
    """sonic passes `/v1/grab/*` to music-grab serve, status and all."""

    def setUp(self):
        grab = ThreadingHTTPServer(("127.0.0.1", 0), FakeGrab)
        threading.Thread(target=grab.serve_forever, daemon=True).start()
        self.addCleanup(grab.server_close)
        self.addCleanup(grab.shutdown)
        FakeGrab.seen = []
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        albums = SimpleNamespace(album=lambda album_id: {"title": "Salt Year", "year": "2009", "tracks": 11})
        service = SimpleNamespace(config=SimpleNamespace(token="", data_dir=Path(folder.name)),
                                  grab=catalog.GrabRelay(f"http://127.0.0.1:{grab.server_address[1]}"), catalog=albums)
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(service))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.base = f"http://127.0.0.1:{server.server_address[1]}"

    def call(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(self.base + path, data=data, method=method)
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            return error.code, json.load(error)

    def test_a_list_is_relayed(self):
        self.assertEqual(self.call("GET", "/v1/grab/requests"), (200, {"items": [], "path": "/requests"}))

    def test_an_album_gets_its_track_count_on_the_way(self):
        status, _ = self.call("POST", "/v1/grab/requests", {"kind": "album", "artist": "Glass Harbor",
                                                            "title": "Salt Year", "albumId": "MPREb_1"})
        self.assertEqual(status, 200)
        self.assertEqual(FakeGrab.seen[0][1]["tracks"], 11)
        self.assertEqual(FakeGrab.seen[0][1]["year"], "2009")

    def test_a_song_wanting_its_album_gets_the_album_named(self):
        self.call("POST", "/v1/grab/requests", {"kind": "song", "artist": "Glass Harbor", "title": "Low Tide",
                                                "albumId": "MPREb_1", "album_too": True})
        self.assertEqual(FakeGrab.seen[0][1]["album"], "Salt Year")

    def test_cancel_needs_no_body_and_errors_come_through(self):
        self.assertEqual(self.call("POST", "/v1/grab/requests/abc/cancel")[0], 200)
        self.assertEqual(FakeGrab.seen[0][0], "/requests/abc/cancel")
        self.assertEqual(self.call("POST", "/v1/grab/requests", {"bad": True}), (400, {"error": "bad"}))

    def test_nothing_listening_is_a_503(self):
        relay = catalog.GrabRelay("http://127.0.0.1:9")
        status, body = relay.forward("GET", "requests")
        self.assertEqual(status, 503)
        self.assertIn("not running", body["error"])


if __name__ == "__main__":
    unittest.main()
