import sqlite3
import tempfile
import unittest
from pathlib import Path

from sonic import duplicates
from sonic.shows import Shows
from sonic.wordsync import WordTimings, parse

WORDS = """version: '1.0'
lines:
- text: First light
  start_ms: 1000
  end_ms: 2000
  words:
  - text: 'First '
    start_ms: 1000
  - text: light
    start_ms: 1500
- text: no words here
  start_ms: 3000
"""


class Duplicates(unittest.TestCase):
    def database(self, tracks):
        db = sqlite3.connect(":memory:")
        db.executescript("""
            create table library (id integer, name text);
            insert into library values (1, 'My Music'), (2, 'Music');
            create table media_file (id text, album_id text, album text, album_artist text, artist text,
                library_id integer, suffix text, codec text, bit_depth integer, sample_rate integer,
                bit_rate integer, size integer, year integer, path text, missing integer default 0);
            create table annotation (item_id text, item_type text, play_count integer);
        """)
        for index, (album_id, album, library, suffix, depth, rate, plays) in enumerate(tracks):
            db.execute("insert into media_file values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,0)",
                       (f"t{index}", album_id, album, "The Lanterns", "The Lanterns", library, suffix, "",
                        depth, rate, 320 if suffix == "mp3" else 900, 1000, 2020, f"The Lanterns/{album}/{index}.{suffix}"))
            db.execute("insert into annotation values (?, 'media_file', ?)", (f"t{index}", plays))
        return db

    def test_the_weaker_copy_first(self):
        db = self.database([
            ("a1", "Glass Harbor", 1, "flac", 24, 96000, 5), ("a1", "Glass Harbor", 1, "flac", 24, 96000, 5),
            ("a2", "Glass Harbor", 2, "mp3", 0, 44100, 30),
            ("b1", "Pale Orchid", 1, "flac", 16, 44100, 0),
        ])
        pairs = duplicates.find(db)
        self.assertEqual(len(pairs), 1)
        weaker, better = pairs[0]["copies"]
        self.assertEqual((weaker["library"], weaker["format"], weaker["tracks"], weaker["plays"]), ("Music", "MP3 320", 1, 30))
        self.assertEqual((better["library"], better["format"], better["tracks"]), ("My Music", "FLAC 24/96", 2))
        self.assertFalse(pairs[0]["alike"])

    def test_two_copies_in_one_library_are_not_a_pair(self):
        db = self.database([("a1", "Glass Harbor", 1, "flac", 16, 44100, 0), ("a2", "Glass Harbor", 1, "flac", 16, 44100, 0)])
        self.assertEqual(duplicates.find(db), [])


class ShowsNearby(unittest.TestCase):
    @staticmethod
    def event(event_id, acts, date="2099-05-01"):
        return {"id": event_id, "name": "An Evening", "url": "https://example.com/e",
                "dates": {"start": {"localDate": date, "localTime": "20:00:00"}},
                "_embedded": {"attractions": [{"name": act} for act in acts],
                              "venues": [{"name": "The Fox", "city": {"name": "Oakland"}}]}}

    def test_only_the_artists_own_shows(self):
        events = {"The Lanterns": [self.event("1", ["The Lanterns"]), self.event("2", ["Lanterns Tribute Night"])]}
        path = Path(tempfile.mkdtemp()) / "shows.json"
        shows = Shows("key", "0,0", 60, lambda: [{"name": "The Lanterns"}], path,
                      fetch=lambda name: events.get(name, []), pause=0)
        items = shows.build()
        self.assertEqual([(item["id"], item["venue"], item["city"]) for item in items], [("1", "The Fox", "Oakland")])

    def test_no_key_no_shelf(self):
        shows = Shows("", "0,0", 60, lambda: [], Path(tempfile.mkdtemp()) / "shows.json")
        self.assertIsNone(shows.answer())


class Words(unittest.TestCase):
    def test_lines_with_words_only(self):
        lines = parse(WORDS)
        self.assertEqual(lines, [{"start": 1000, "end": 2000, "text": "First light",
                                  "words": [{"start": 1000, "text": "First "}, {"start": 1500, "text": "light"}]}])

    def test_asked_once_and_matched_by_length(self):
        asked = []

        def ask(query):
            asked.append(query)
            return [{"hasWordSync": True, "duration": 180.0, "lyricsfile": WORDS},
                    {"hasWordSync": True, "duration": 240.0, "lyricsfile": WORDS}]
        timings = WordTimings(Path(tempfile.mkdtemp()) / "words.db", ask=ask)
        self.assertEqual(timings.answer("s1", "Glass Harbor", "The Lanterns", 240.5)[0]["start"], 1000)
        self.assertEqual(len(asked), 1)
        timings.answer("s1", "Glass Harbor", "The Lanterns", 240.5)
        self.assertEqual(len(asked), 1)
        # Nothing near this length: nothing, remembered too.
        self.assertIsNone(timings.answer("s2", "Glass Harbor", "The Lanterns", 300.0))
        timings.answer("s2", "Glass Harbor", "The Lanterns", 300.0)
        self.assertEqual(len(asked), 2)


if __name__ == "__main__":
    unittest.main()
