import io
import json
import tempfile
import unittest
import urllib.error
import urllib.parse
from pathlib import Path
from types import SimpleNamespace

from sonic import lrclib
from sonic.lyrics import LyricIndex, LyricTrack, from_text, with_sidecars
from sonic.lyricsfile import Refused

SYNCED = "[00:01.00]First light\n[00:04.50]Over the harbor"


def record(duration, synced=SYNCED, plain="First light\nOver the harbor", instrumental=False, name="Glass Harbor"):
    return {"trackName": name, "artistName": "The Lanterns", "duration": duration, "instrumental": instrumental,
            "syncedLyrics": synced, "plainLyrics": plain}


def server(get=None, search=()):
    """LRCLIB, answering `get` (None: 404) and each search in turn."""
    asked = []
    searches = list(search)

    def open_url(request, timeout):
        url = request.full_url
        asked.append(url)
        if "/api/get?" in url:
            if get is None:
                raise urllib.error.HTTPError(url, 404, "not found", {}, None)
            return io.BytesIO(json.dumps(get).encode())
        return io.BytesIO(json.dumps(searches.pop(0) if searches else []).encode())
    return open_url, asked


class Choosing(unittest.TestCase):
    def test_the_length_decides(self):
        radio_edit, album_cut = record(180.0), record(241.0)
        self.assertIs(lrclib.best([radio_edit, album_cut], 240.0), album_cut)
        self.assertIsNone(lrclib.best([radio_edit], 240.0))

    def test_timed_before_plain(self):
        plain, timed = record(240.0, synced=None), record(242.0)
        self.assertIs(lrclib.best([plain, timed], 240.0), timed)

    def test_titles_lose_their_remaster(self):
        self.assertEqual(lrclib.clean("Glass Harbor (Remastered 2024)"), "Glass Harbor")
        self.assertEqual(lrclib.clean("Glass Harbor - 2011 Remaster"), "Glass Harbor")
        self.assertEqual(lrclib.clean("Glass Harbor (feat. Mira Vale)"), "Glass Harbor")
        self.assertEqual(lrclib.clean("Pale Orchid"), "Pale Orchid")


class Finding(unittest.TestCase):
    def test_the_exact_match(self):
        open_url, asked = server(get=record(240.0))
        found = lrclib.find("Glass Harbor", "The Lanterns", "Low Tide", 240.4, open_url)
        self.assertEqual((found.text, found.synced), (SYNCED, True))
        self.assertIn("duration=240", asked[0])
        self.assertEqual(len(asked), 1)

    def test_a_search_when_the_exact_one_misses(self):
        open_url, asked = server(get=None, search=[[], [record(240.0)]])
        found = lrclib.find("Glass Harbor (Remastered 2024)", "The Lanterns", "Low Tide", 240.0, open_url)
        self.assertTrue(found.synced)
        self.assertIn("track_name=Glass+Harbor&", asked[-1])

    def test_nothing(self):
        open_url, _ = server(get=None, search=[[], []])
        self.assertIsNone(lrclib.find("Glass Harbor (Live)", "The Lanterns", "", 240.0, open_url))

    def test_instrumental(self):
        open_url, _ = server(get=record(240.0, synced=None, plain=None, instrumental=True))
        self.assertTrue(lrclib.find("Glass Harbor", "The Lanterns", "", 240.0, open_url).instrumental)

    def test_unreachable(self):
        def open_url(request, timeout):
            raise urllib.error.URLError("no route")
        with self.assertRaises(Refused) as caught:
            lrclib.find("Glass Harbor", "The Lanterns", "", 240.0, open_url)
        self.assertEqual(caught.exception.status, 502)


class Saving(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.song = self.folder / "01 Glass Harbor.flac"
        self.song.write_bytes(b"fLaC")

    def tearDown(self):
        for item in self.folder.iterdir():
            item.unlink()
        self.folder.rmdir()

    def test_written_beside_the_song(self):
        open_url, _ = server(get=record(240.0))
        found, lines = lrclib.save_for(str(self.song), "Glass Harbor", "The Lanterns", "Low Tide", 240.0, open_url)
        self.assertTrue(found.synced)
        self.assertEqual(lines, [(1000, "First light"), (4500, "Over the harbor")])
        text = (self.folder / "01 Glass Harbor.lrc").read_text()
        self.assertTrue(text.startswith("[ti:Glass Harbor]\n[ar:The Lanterns]\n[al:Low Tide]\n[length:04:00.00]\n"))
        self.assertTrue(text.endswith(SYNCED + "\n"))
        self.assertEqual(sorted(item.name for item in self.folder.iterdir()), ["01 Glass Harbor.flac", "01 Glass Harbor.lrc"])

    def test_lyrics_already_there_are_left_alone(self):
        (self.folder / "01 Glass Harbor.lrc").write_text(SYNCED)
        open_url, asked = server(get=record(240.0))
        with self.assertRaises(Refused) as caught:
            lrclib.save_for(str(self.song), "Glass Harbor", "The Lanterns", "", 240.0, open_url)
        self.assertEqual(caught.exception.status, 409)
        self.assertEqual(asked, [])

    def test_nothing_written_for_an_instrumental(self):
        open_url, _ = server(get=record(240.0, synced=None, plain=None, instrumental=True))
        found, lines = lrclib.save_for(str(self.song), "Glass Harbor", "The Lanterns", "", 240.0, open_url)
        self.assertTrue(found.instrumental)
        self.assertEqual(lines, [])
        self.assertEqual([item.name for item in self.folder.iterdir()], ["01 Glass Harbor.flac"])


class FilesBesideSongs(unittest.TestCase):
    def setUp(self):
        self.folder = Path(tempfile.mkdtemp())
        self.cache = Path(tempfile.mkdtemp()) / "lyric-files.db"

    def track(self, track_id, name):
        path = self.folder / f"{name}.flac"
        path.write_bytes(b"")
        return SimpleNamespace(id=track_id, title=name, artist="The Lanterns", path=str(path))

    def test_an_lrc_takes_the_tags_place(self):
        tracks = [self.track("a", "Glass Harbor"), self.track("b", "Pale Orchid"), self.track("c", "Low Tide")]
        (self.folder / "Glass Harbor.lrc").write_text("[ar:The Lanterns]\n" + SYNCED)
        (self.folder / "Low Tide.txt").write_text("Slow water\nNo time")
        embedded = [LyricTrack(id="a", title="Glass Harbor", artist="The Lanterns", lines=("Old words",)),
                    LyricTrack(id="b", title="Pale Orchid", artist="The Lanterns", lines=("Tag words",))]
        index = {track.id: track for track in with_sidecars(tracks, embedded, self.cache)}
        self.assertEqual(index["a"].lines, ("First light", "Over the harbor"))
        self.assertEqual(index["a"].starts, (1000, 4500))
        self.assertEqual(index["b"].lines, ("Tag words",))
        self.assertEqual((index["c"].lines, index["c"].starts), (("Slow water", "No time"), (None, None)))

    def test_an_unchanged_file_is_not_read_again(self):
        tracks = [self.track("a", "Glass Harbor")]
        sidecar = self.folder / "Glass Harbor.lrc"
        sidecar.write_text(SYNCED)
        with_sidecars(tracks, [], self.cache)
        sidecar.chmod(0)        # unreadable now: only the cache can answer
        try:
            again = with_sidecars(tracks, [], self.cache)
        finally:
            sidecar.chmod(0o644)
        self.assertEqual(again[0].lines, ("First light", "Over the harbor"))

    def test_lyrics_just_written_are_searched_at_once(self):
        index = LyricIndex([LyricTrack(id="a", title="Glass Harbor", artist="The Lanterns", lines=("Old words",))])
        updated = index.with_track(from_text("a", "Glass Harbor", "The Lanterns", SYNCED))
        self.assertEqual(index.search("old words")[0].id, "a")
        self.assertEqual(updated.search("old words"), [])
        self.assertEqual(updated.search("over the harbor")[0].at, 4500)


if __name__ == "__main__":
    unittest.main()
