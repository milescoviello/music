import json
import sqlite3
import unittest

from sonic.lyrics import LyricIndex, LyricTrack, normalised, parse, parse_timed, read


def track(track_id, title, artist, *lines):
    return LyricTrack(id=track_id, title=title, artist=artist, lines=tuple(lines))


def column(*lines):
    return json.dumps([{"lang": "eng", "synced": True,
                        "line": [{"start": i * 1000, "value": line} for i, line in enumerate(lines)]}])


class Normalising(unittest.TestCase):
    def test_case_accents_and_punctuation_do_not_matter(self):
        self.assertEqual(normalised("Won’t   WAIT, café!"), "won t wait cafe")

    def test_other_scripts_stay(self):
        self.assertEqual(normalised("ねぇ 今日は雨かな"), "ねぇ 今日は雨かな")


class Parsing(unittest.TestCase):
    def test_lines_without_blanks(self):
        self.assertEqual(parse(column("one", "", "two")), ("one", "two"))

    def test_only_the_first_lyric_when_there_are_several(self):
        raw = json.dumps([
            {"line": [{"value": "first"}]},
            {"line": [{"value": "second"}]},
        ])
        self.assertEqual(parse(raw), ("first",))

    def test_when_each_synced_line_starts(self):
        lines, starts = parse_timed(column("one", "", "two"))
        self.assertEqual(lines, ("one", "two"))
        self.assertEqual(starts, (0, 2000))
        unsynced = json.dumps([{"synced": False, "line": [{"start": 0, "value": "one"}]}])
        self.assertEqual(parse_timed(unsynced)[1], (None,))

    def test_plain_text_and_nothing(self):
        self.assertEqual(parse("one\n\ntwo\n"), ("one", "two"))
        self.assertEqual(parse(None), ())
        self.assertEqual(parse("[]"), ())


class Searching(unittest.TestCase):
    def setUp(self):
        self.index = LyricIndex([
            track("a", "Low Tide Letters", "The Lanterns",
                  "Have you got salt in your hair?", "Do you ever hear the tide"),
            track("b", "Somewhere Else", "Someone", "the salt of the sea", "in your hair"),
            track("c", "Words Apart", "Band", "hair wet, you got salt in it"),
            track("d", "Low Tide Letters (Live)", "The Lanterns",
                  "Have you got salt in your hair?"),
        ])

    def test_the_phrase_in_one_line_comes_first(self):
        hits = self.index.search("got salt in your hair")
        self.assertEqual(hits[0].id, "a")
        self.assertEqual(hits[0].line, "Have you got salt in your hair?")

    def test_a_phrase_running_into_the_next_line(self):
        hits = self.index.search("salt of the sea in your")
        self.assertEqual([hit.id for hit in hits], ["b"])

    def test_every_word_in_a_line_in_any_order(self):
        hits = self.index.search("salt hair got")
        self.assertEqual(hits[0].score, 2)
        self.assertIn("c", [hit.id for hit in hits])

    def test_one_row_per_song(self):
        # "Low Tide Letters (Live)" is a different title, so it stays; the same title and
        # artist twice would not.
        index = LyricIndex([track("x", "Same", "A", "a line here"), track("y", "Same", "A", "a line here")])
        self.assertEqual(len(index.search("line here")), 1)

    def test_too_short_or_absent(self):
        self.assertEqual(self.index.search("sa"), [])
        self.assertEqual(self.index.search("nothing like this anywhere"), [])


class Reading(unittest.TestCase):
    def test_reads_tracks_with_lyrics_only(self):
        connection = sqlite3.connect(":memory:")
        connection.execute("create table media_file (id, title, artist, lyrics, missing)")
        connection.executemany("insert into media_file values (?, ?, ?, ?, ?)", [
            ("1", "Has", "A", column("words here"), 0),
            ("2", "Empty", "A", "[]", 0),
            ("3", "None", "A", None, 0),
            ("4", "Gone", "A", column("words"), 1),
        ])
        tracks = read(connection)
        self.assertEqual([t.id for t in tracks], ["1"])
        self.assertEqual(tracks[0].lines, ("words here",))
        hit = LyricIndex(tracks).search("words here")[0]
        self.assertEqual((hit.line, hit.at), ("words here", 0))


if __name__ == "__main__":
    unittest.main()
