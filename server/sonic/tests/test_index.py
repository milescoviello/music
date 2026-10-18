import unittest

import numpy as np

from sonic.analyse import LEVEL_FLOOR, levels_from_momentary
from sonic.config import TAGS, _path_map, Config
from sonic.index import Index, bucket_levels, clean_title


def vector(*hot, scale=1.0):
    v = np.full(len(TAGS), 0.01, np.float32)
    for index, value in hot:
        v[index] = value
    return (v * scale).astype(np.float32).tobytes()


def row(track_id, album, artist, title, blob, plays=0, track_artist=None):
    return (track_id, album, artist, track_artist or artist, title, artist, plays, blob)


class IndexTests(unittest.TestCase):
    def setUp(self):
        self.index = Index([
            row("rock1", "A", "x", "Song One", vector((0, 0.9), (1, 0.1))),
            row("rock2", "A", "x", "Song Two", vector((0, 0.85), (1, 0.15))),
            row("rock3", "B", "y", "Other Rock", vector((0, 0.8), (1, 0.2))),
            row("rock1live", "C", "x", "Song One (Live)", vector((0, 0.9), (1, 0.1))),
            row("jazz1", "D", "z", "Blue", vector((9, 0.9))),
            row("jazz2", "D", "z", "Green", vector((9, 0.8), (0, 0.1))),
            row("mid", "E", "w", "Between", vector((0, 0.6), (9, 0.6))),
        ])

    def test_nearest_first_never_itself_or_another_version(self):
        hits = [hit.id for hit in self.index.similar("rock1", limit=3)]
        self.assertEqual(hits[0], "rock2")
        self.assertNotIn("rock1", hits)
        self.assertNotIn("rock1live", hits)

    def test_excluding_the_artist(self):
        hits = [hit.id for hit in self.index.similar("rock1", limit=2, exclude_artist=True)]
        self.assertEqual(hits[0], "rock3")
        self.assertTrue(all(self.index.artist[self.index.row[h]] != "x" for h in hits))

    def test_a_max_distance_cuts_the_list(self):
        hits = self.index.similar("rock1", limit=10, max_distance=0.05)
        self.assertTrue(all(hit.distance <= 0.05 for hit in hits))
        self.assertNotIn("jazz1", [hit.id for hit in hits])

    def test_unknown_is_none_not_empty(self):
        self.assertIsNone(self.index.similar("nope"))
        self.assertIsNone(self.index.path("rock1", "nope"))

    def test_a_path_goes_from_one_sound_to_the_other(self):
        hits = [hit.id for hit in self.index.path("rock1", "jazz1", steps=3)]
        self.assertNotIn("rock1", hits)
        self.assertNotIn("jazz1", hits)
        self.assertIn("mid", hits)
        # Never two in a row by one artist.
        artists = [self.index.artist[self.index.row[h]] for h in hits]
        self.assertTrue(all(a != b for a, b in zip(artists, artists[1:])))

    def test_radio_leaves_out_seeds_and_exclusions(self):
        hits = [hit.id for hit in self.index.radio(["rock1"], exclude=["rock2"], limit=5)]
        self.assertNotIn("rock1", hits)
        self.assertNotIn("rock2", hits)
        self.assertNotIn("rock1live", hits)

    def test_albums_and_artists_have_neighbours(self):
        albums = [hit.id for hit in self.index.similar_albums("A")]
        self.assertNotIn("A", albums)
        self.assertNotIn("C", albums)  # same artist, excluded by default
        self.assertEqual(albums[0], "B")
        artists = [hit.id for hit in self.index.similar_artists("x")]
        self.assertEqual(artists[0], "y")

    def test_tags_name_the_strongest_outputs(self):
        tags = self.index.tags("jazz1", limit=1)
        self.assertEqual(tags[0]["tag"], TAGS[9])
        self.assertEqual(self.index.tagged("JAZZ", limit=1)[0].id, "jazz1")

    def test_distant_is_other_artists(self):
        hits = self.index.distant("rock1", limit=10)
        self.assertTrue(all(self.index.artist[self.index.row[h.id]] != "x" for h in hits))


class LevelsTests(unittest.TestCase):
    def test_plex_shape_leads_with_the_floor_and_counts_tenths(self):
        levels = levels_from_momentary(np.array([-60, -20, -10, -12], np.float32), duration=0.45)
        self.assertEqual(levels.tolist(), [LEVEL_FLOOR, LEVEL_FLOOR, -20, -10])

    def test_bucketing_matches_the_app(self):
        readings = np.array([-40, -40, -20, -10, -30, -30, -30, -10], np.float32)
        self.assertEqual(bucket_levels(readings, 4), [-40.0, -15.0, -30.0, -20.0])
        self.assertEqual(bucket_levels(readings, 0), [float(x) for x in readings])
        self.assertEqual(bucket_levels(readings[:3], 128), [-40.0, -40.0, -20.0])
        # Uneven division: integer bounds, as the app computes them.
        self.assertEqual(bucket_levels(np.arange(10, dtype=np.float32) - 40, 3), [-39.0, -36.0, -32.5])


class ConfigTests(unittest.TestCase):
    def test_paths_are_mapped_longest_root_first(self):
        config = Config(path_map=_path_map("/music=/mnt/a,/music/my_music=/mnt/b"))
        self.assertEqual(config.local_path("/music/my_music/x.flac"), "/mnt/b/x.flac")
        self.assertEqual(config.local_path("/music/other/x.flac"), "/mnt/a/other/x.flac")
        self.assertIsNone(config.local_path("/elsewhere/x.flac"))

    def test_titles_lose_their_last_bracket(self):
        self.assertEqual(clean_title("Song (Live) [2011 Remaster]"), "song (live)")
        self.assertEqual(clean_title("(Intro)"), "(intro)")


if __name__ == "__main__":
    unittest.main()
