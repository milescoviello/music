"""Flags on About summaries: kept, taken back, closed by the summary written again, refused when malformed."""

import json
import os
import tempfile
import unittest
from pathlib import Path

from sonic.flags import AboutFlags


class AboutFlagsTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.data = Path(self.folder.name)
        self.now = 1_000.0
        self.flags = AboutFlags(self.data, clock=lambda: self.now)

    def tearDown(self):
        self.folder.cleanup()

    def summary(self, kind, item_id, mtime):
        folder = self.data / f"{kind}-about-summaries"
        folder.mkdir(exist_ok=True)
        path = folder / f"{item_id}.json"
        path.write_text(json.dumps({"text": "Glass Harbour is about the sea.", "basis": "sources"}))
        os.utime(path, (mtime, mtime))

    def test_a_flag_is_kept_with_its_note(self):
        self.summary("song", "abc", 500)
        self.assertEqual(self.flags.flag({"kind": "song", "id": "abc", "note": " wrong band ", "title": "Glass Harbour",
                                          "artist": "Ada Marsh"}), {"flagged": True})
        self.assertEqual(self.flags.state("song", "abc"), {"at": 1_000.0, "note": "wrong band"})
        [flag] = self.flags.open_flags()
        self.assertEqual((flag["title"], flag["artist"]), ("Glass Harbour", "Ada Marsh"))
        self.assertIsNone(self.flags.state("album", "abc"))

    def test_a_note_is_optional(self):
        self.flags.flag({"kind": "artist", "id": "xyz"})
        self.assertEqual(self.flags.state("artist", "xyz"), {"at": 1_000.0, "note": ""})

    def test_taken_back(self):
        self.flags.flag({"kind": "album", "id": "abc"})
        self.assertEqual(self.flags.flag({"kind": "album", "id": "abc", "clear": True}), {"flagged": False})
        self.assertIsNone(self.flags.state("album", "abc"))
        self.assertEqual(self.flags.open_flags(), [])

    def test_closed_by_the_summary_written_again(self):
        self.summary("song", "abc", 500)
        self.flags.flag({"kind": "song", "id": "abc"})
        self.summary("song", "abc", 2_000)
        self.assertIsNone(self.flags.state("song", "abc"))
        self.assertEqual(self.flags.open_flags(), [])

    def test_open_flags_oldest_first(self):
        self.flags.flag({"kind": "song", "id": "second"})
        self.now = 900.0
        self.flags.flag({"kind": "song", "id": "first"})
        self.assertEqual([flag["id"] for flag in self.flags.open_flags()], ["first", "second"])

    def test_refused(self):
        for body in ({"kind": "playlist", "id": "abc"}, {"kind": "song"}, {"kind": "song", "id": "../x"},
                     {"kind": "song", "id": 7}):
            with self.assertRaises(ValueError):
                self.flags.flag(body)

    def test_a_long_note_is_cut(self):
        self.flags.flag({"kind": "song", "id": "abc", "note": "x" * 5_000})
        self.assertEqual(len(self.flags.state("song", "abc")["note"]), 1_000)


if __name__ == "__main__":
    unittest.main()
