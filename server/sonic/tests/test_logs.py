import json
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

from sonic.http import make_handler
from sonic.logs import LIMIT, LogBox, source_name


class Naming(unittest.TestCase):
    def test_only_what_is_safe_in_a_file_name(self):
        self.assertEqual(source_name("Linux gentoo"), "linux-gentoo")
        self.assertEqual(source_name("../../etc/passwd"), "etc-passwd")
        self.assertEqual(source_name(""), "app")
        self.assertEqual(source_name(None), "app")
        self.assertEqual(len(source_name("x" * 100)), 32)


class Keeping(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.directory = Path(self.folder.name) / "logs"

    def tearDown(self):
        self.folder.cleanup()

    def test_a_report_is_kept_whole(self):
        name = LogBox(self.directory).save("line one\nline two", "ios")
        self.assertTrue(name.endswith(".txt"))
        self.assertIn("-ios-", name)
        self.assertEqual((self.directory / name).read_text(), "line one\nline two")
        self.assertEqual([path.name for path in self.directory.iterdir()], [name])

    def test_only_the_newest_are_kept(self):
        box = LogBox(self.directory, keep=3)
        start = datetime(2026, 11, 2, 18, 0, tzinfo=timezone.utc)
        names = [box.save(f"report {i}", "ios", now=start + timedelta(minutes=i)) for i in range(5)]
        self.assertEqual(sorted(path.name for path in self.directory.iterdir()), names[2:])


class Receiving(unittest.TestCase):
    """The route itself, over a real socket."""

    def start(self, token=""):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        service = SimpleNamespace(config=SimpleNamespace(token=token, data_dir=Path(self.folder.name)))
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(service))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.base = f"http://127.0.0.1:{server.server_address[1]}"

    def post(self, path, body, headers=None):
        request = urllib.request.Request(self.base + path, data=body, method="POST", headers=headers or {})
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            with error:
                return error.code, json.loads(error.read())

    def saved(self):
        return sorted((Path(self.folder.name) / "logs").glob("*.txt"))

    def test_a_report_is_saved(self):
        self.start()
        status, body = self.post("/v1/logs", "Music logs\nüñí".encode(), {"X-Log-Source": "iOS"})
        self.assertEqual(status, 201)
        [path] = self.saved()
        self.assertEqual(path.name, body["name"])
        self.assertIn("-ios-", path.name)
        self.assertEqual(path.read_text(), "Music logs\nüñí")

    def test_too_big_is_turned_down(self):
        self.start()
        status, _ = self.post("/v1/logs", b"x" * (LIMIT + 1))
        self.assertEqual(status, 413)
        self.assertEqual(self.saved(), [])

    def test_empty_is_turned_down(self):
        self.start()
        status, _ = self.post("/v1/logs", b"")
        self.assertEqual(status, 400)

    def test_nothing_else_takes_a_write(self):
        self.start()
        status, _ = self.post("/v1/status", b"x")
        self.assertEqual(status, 404)

    def test_the_token_when_there_is_one(self):
        self.start(token="abc")
        self.assertEqual(self.post("/v1/logs", b"x")[0], 401)
        self.assertEqual(self.post("/v1/logs", b"x", {"X-Sonic-Token": "abc"})[0], 201)


if __name__ == "__main__":
    unittest.main()
