import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from sonic import fill
from sonic.lrclib import Found
from sonic.lyrics import LyricTrack


class FillingLyrics(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.config = SimpleNamespace(data_dir=self.root)

    def track(self, track_id, folder, title, duration=200.0):
        path = self.root / folder / f"{title}.flac"
        path.parent.mkdir(exist_ok=True)
        path.write_bytes(b"")
        return SimpleNamespace(id=track_id, title=title, artist="The Lanterns", album="Low Tide",
                               duration=duration, path=str(path))

    def run_fill(self, tracks, with_lyrics=(), answers=None, now=1_000_000.0):
        asked = []

        def find(title, artist, album, duration):
            asked.append(title)
            return (answers or {}).get(title)
        embedded = [LyricTrack(id=track_id, title="", artist="", lines=("words",)) for track_id in with_lyrics]
        with mock.patch.object(fill.library, "read_with_lyrics", return_value=(tracks, embedded)), \
             mock.patch.object(fill.lyric_files, "with_sidecars", side_effect=lambda t, e, p: e):
            summary = fill.run(self.config, sleep=lambda _: None, find=find, now=lambda: now)
        return summary, asked

    def test_one_question_per_recording_written_beside_every_copy(self):
        tracks = [self.track("a", "my_music", "Glass Harbor"), self.track("b", "music", "Glass Harbor"),
                  self.track("c", "music", "Pale Orchid"), self.track("d", "music", "Mira")]
        found = Found("[00:01.00]First light", synced=True)
        summary, asked = self.run_fill(tracks, with_lyrics=["d"], answers={"Glass Harbor": found})
        self.assertEqual(sorted(asked), ["Glass Harbor", "Pale Orchid"])
        self.assertEqual((summary["timed"], summary["none"]), (1, 1))
        for folder in ("my_music", "music"):
            self.assertIn("First light", (self.root / folder / "Glass Harbor.lrc").read_text())
        self.assertFalse((self.root / "music" / "Pale Orchid.lrc").exists())

    def test_a_miss_is_not_asked_about_again_for_a_month(self):
        tracks = [self.track("c", "music", "Pale Orchid")]
        self.run_fill(tracks, now=1_000_000.0)
        _, asked = self.run_fill(tracks, now=1_000_000.0 + 86_400)
        self.assertEqual(asked, [])
        _, asked = self.run_fill(tracks, now=1_000_000.0 + 31 * 86_400)
        self.assertEqual(asked, ["Pale Orchid"])

    def test_mixes_and_snippets_are_left_out(self):
        tracks = [self.track("m", "music", "Whole Concert", duration=2 * 3600), self.track("s", "music", "Intro", 12)]
        _, asked = self.run_fill(tracks)
        self.assertEqual(asked, [])


if __name__ == "__main__":
    unittest.main()
