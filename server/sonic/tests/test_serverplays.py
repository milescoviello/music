import json
import sqlite3
import unittest

from sonic import serverplays


class ServerPlays(unittest.TestCase):
    def database(self):
        db = sqlite3.connect(":memory:")
        db.executescript("""
            create table user (id text, user_name text);
            insert into user values ('u1', 'listener'), ('u2', 'guest');
            create table media_file (id text, title text, artist text, album text, album_id text,
                album_artist_id text, artist_id text, duration real, tags text);
            create table scrobbles (id integer primary key, media_file_id text, user_id text, submission_time integer);
        """)
        db.execute("insert into media_file values ('s1', 'Low Tide', 'The Lanterns', 'Glass Harbor', 'a1', 'ar1', 'ar1', 201.6, ?)",
                   (json.dumps({"genre": [{"id": "g", "value": "Dream Pop"}]}),))
        # Old plays written late (an import) get high row ids: the cursor is the row, not the time.
        db.executemany("insert into scrobbles values (?, 's1', ?, ?)",
                       [(1, "u1", 1_790_000_000), (2, "u2", 1_790_000_100), (3, "u1", 1_760_000_000)])
        return db

    def test_pages_by_row_and_keeps_ids_stable(self):
        db = self.database()
        first = serverplays.page(db, after=0, user="listener", limit=1)
        self.assertTrue(first["more"])
        self.assertEqual(first["after"], 1)
        rest = serverplays.page(db, after=first["after"], user="listener", limit=10)
        self.assertFalse(rest["more"])
        self.assertEqual([p["at"] for p in rest["plays"]], [1_760_000_000.0])
        play = first["plays"][0]
        self.assertEqual((play["songID"], play["album"], play["artistID"], play["coverArt"], play["duration"], play["genres"]),
                         ("s1", "Glass Harbor", "ar1", "al-a1", 201, ["Dream Pop"]))
        self.assertEqual(play["id"], serverplays.page(db, after=0, user="listener", limit=1)["plays"][0]["id"])

    def test_only_the_asking_user(self):
        db = self.database()
        self.assertEqual(len(serverplays.page(db, user="listener")["plays"]), 2)
        self.assertEqual(len(serverplays.page(db, user="")["plays"]), 3)
        self.assertEqual(serverplays.page(db, after=3, user="listener"), {"plays": [], "after": 3, "more": False})


if __name__ == "__main__":
    unittest.main()
