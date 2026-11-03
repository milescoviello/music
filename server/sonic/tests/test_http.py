import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

from sonic.http import make_handler


class Answers(unittest.TestCase):
    """What a GET sends, over a real socket."""

    def start(self, levels):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        service = SimpleNamespace(config=SimpleNamespace(token="", data_dir=Path(folder.name)),
                                  levels=lambda track_id, points: levels)
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(service))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.base = f"http://127.0.0.1:{server.server_address[1]}"

    def get(self, path):
        try:
            with urllib.request.urlopen(self.base + path, timeout=5) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            with error:
                return error.code, error.read()

    def test_numbers_are_json(self):
        self.start({"id": "a", "hop": 0.1, "levels": [-12.5, -9.0]})
        status, body = self.get("/v1/tracks/a/levels")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["levels"], [-12.5, -9.0])

    def test_a_nan_is_a_server_error_never_a_bare_word(self):
        # Python's default writes NaN as `NaN`, which no JSON decoder accepts: the app's
        # took the whole reply for the service being down.
        self.start({"id": "a", "hop": 0.1, "levels": [float("nan"), -9.0]})
        with self.assertLogs("sonic", level="ERROR"):
            status, body = self.get("/v1/tracks/a/levels")
        self.assertEqual(status, 500)
        self.assertNotIn(b"NaN", body)
        self.assertIn("error", json.loads(body))

    def test_not_analysed_is_a_404(self):
        self.start(None)
        self.assertEqual(self.get("/v1/tracks/a/levels")[0], 404)


if __name__ == "__main__":
    unittest.main()
