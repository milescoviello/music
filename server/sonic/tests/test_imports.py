import io
import json
import sqlite3
import unittest
import zipfile

from sonic import imports, taste


def library():
    db = sqlite3.connect(":memory:")
    db.executescript("""
        create table media_file (id text, title text, artist text, album text, album_id text,
            album_artist_id text, artist_id text, duration real, tags text);
    """)
    db.execute("insert into media_file values ('s1', 'Low Tide', 'The Lanterns', 'Glass Harbor', 'a1', 'ar1', 'ar1', 201.6, ?)",
               (json.dumps({"genre": [{"id": "g", "value": "Dream Pop"}]}),))
    db.execute("insert into media_file values ('s2', 'Paper Moons (Remastered)', 'Juniper Vale', 'Night Bus', 'a2', 'ar2', 'ar2', 180, '{}')")
    return imports.Library(db)


YOUTUBE = [
    {"header": "YouTube Music", "title": "Watched Low Tide", "titleUrl": "https://music.youtube.com/watch?v=abc",
     "subtitles": [{"name": "The Lanterns - Topic"}], "time": "2024-03-01T20:15:00.000Z"},
    {"header": "YouTube", "title": "Watched Paper Moons", "titleUrl": "https://www.youtube.com/watch?v=def",
     "subtitles": [{"name": "Juniper Vale - Topic"}], "time": "2024-03-02T08:00:00Z"},
    {"header": "YouTube", "title": "Watched How to fix a bike", "titleUrl": "https://www.youtube.com/watch?v=ghi",
     "subtitles": [{"name": "Bike Channel"}], "time": "2024-03-02T09:00:00Z"},
    {"header": "YouTube Music", "title": "Watched https://www.youtube.com/watch?v=gone", "time": "2024-03-03T09:00:00Z"},
    {"header": "YouTube Music", "title": "Watched Unknown Song", "subtitles": [{"name": "Somebody"}],
     "time": "2024-03-04T09:00:00Z"},
]

APPLE = """Album Name,Song Name,Artist Name,Event Start Timestamp,Event End Timestamp,Play Duration Milliseconds,Media Duration In Milliseconds,Event Type
Glass Harbor,Low Tide,The Lanterns,2023-06-01T10:00:00.000Z,2023-06-01T10:03:21.000Z,201000,201600,PLAY_END
Glass Harbor,Low Tide,The Lanterns,2023-06-01T10:05:00.000Z,2023-06-01T10:05:10.000Z,10000,201600,PLAY_END
"""

DAILY = """Country,Track Identifier,Date Played,Hours,Play Duration Milliseconds,Play Count,Track Description
US,1,20230702,"21, 22",400000,2,The Lanterns - Low Tide
"""


class Imports(unittest.TestCase):
    def test_youtube_keeps_music_only_and_matches_the_library(self):
        source, plays, counts = imports.read(json.dumps(YOUTUBE).encode(), "watch-history.json")
        self.assertEqual(source, "youtube")
        self.assertEqual(counts, {"read": 5, "notMusic": 2})
        events, matched = imports.events(source, plays, library())
        self.assertEqual(matched, 2)
        self.assertEqual([(e["songID"], e["duration"]) for e in events], [("s1", 201), ("s2", 180), ("", imports.TYPICAL_SECONDS)])
        self.assertEqual(events[0]["coverArt"], "al-a1")
        self.assertEqual(events[0]["genre"], "Dream Pop")
        self.assertEqual(events[2]["artist"], "Somebody")

    def test_apple_activity_counts_listens_and_drops_short_ones(self):
        source, plays, counts = imports.read(APPLE.encode(), "Apple Music Play Activity.csv")
        self.assertEqual((source, len(plays), counts["tooShort"]), ("apple", 1, 1))
        self.assertEqual(plays[0]["seconds"], 201)

    def test_apple_daily_expands_a_day_into_its_plays(self):
        source, plays, _ = imports.read(DAILY.encode(), "Apple Music - Play History Daily Tracks.csv")
        self.assertEqual((source, len(plays)), ("apple", 2))
        self.assertEqual([p["seconds"] for p in plays], [200, 200])
        self.assertEqual((plays[0]["artist"], plays[0]["title"]), ("The Lanterns", "Low Tide"))

    def test_finds_the_history_inside_nested_zips(self):
        inner = io.BytesIO()
        with zipfile.ZipFile(inner, "w") as z:
            z.writestr("Apple Music Activity/Apple Music Play Activity.csv", APPLE)
        outer = io.BytesIO()
        with zipfile.ZipFile(outer, "w") as z:
            z.writestr("Apple_Media_Services.zip", inner.getvalue())
            z.writestr("Other/notes.txt", "nothing here")
        source, plays, _ = imports.read(outer.getvalue(), "export.zip")
        self.assertEqual((source, len(plays)), ("apple", 1))

    def test_the_same_file_twice_adds_nothing(self):
        store = taste.TasteStore.__new__(taste.TasteStore)
        taste.TasteStore.__init__(store, __import__("pathlib").Path(":memory:"))
        _, plays, _ = imports.read(json.dumps(YOUTUBE).encode(), "watch-history.json")
        events, _ = imports.events("youtube", plays, library())
        self.assertEqual(store.add("import-youtube", events)["added"], 3)
        self.assertEqual(store.add("import-youtube", events)["added"], 0)

    def test_anything_else_is_refused(self):
        with self.assertRaises(imports.Unreadable):
            imports.read(b"just some text", "notes.txt")


if __name__ == "__main__":
    unittest.main()
