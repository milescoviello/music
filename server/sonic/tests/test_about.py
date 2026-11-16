"""The About sheet's answer: which pages count as the song's, what is kept of them, and how long."""

import io
import json
import tempfile
import unittest
import urllib.error
import urllib.parse
from pathlib import Path

from sonic.about import SongAbout, same_artist, same_title


class Web:
    """Genius and Wikipedia as canned answers, keyed by the start of the address; counts the asks."""

    def __init__(self, pages=None, fail=False):
        self.pages = pages or {}
        self.fail = fail
        self.asked = []

    def __call__(self, request, timeout=None):
        url = request.full_url
        self.asked.append(url)
        if self.fail:
            raise urllib.error.URLError("no network")
        for start, body in self.pages.items():
            if url.startswith(start) and all(part in urllib.parse.unquote_plus(url) for part in body.get("_needs", [])):
                return io.BytesIO(json.dumps({k: v for k, v in body.items() if k != "_needs"}).encode())
        raise urllib.error.HTTPError(url, 404, "not found", None, None)


def genius_search(*hits):
    return {"response": {"sections": [{"type": "song", "hits": [
        {"type": "song", "result": {"id": id_, "title": title, "primary_artist": {"name": artist}}}
        for id_, title, artist in hits]}]}}


GENIUS_SONG = {"response": {"song": {
    "url": "https://genius.com/song", "release_date_for_display": "June 8, 1999",
    "description": {"plain": "The second song off Californication."},
    "writer_artists": [{"name": "Anthony Kiedis"}, {"name": "Flea"}]}}}
GENIUS_NOTES = {"response": {"referents": [
    {"fragment": "Deep inside of a parallel universe", "classification": "unreviewed", "url": "https://genius.com/1",
     "annotations": [{"votes_total": 3, "body": {"plain": "The private world of addiction."}}]},
    {"fragment": "A voted-down note", "annotations": [{"votes_total": -2, "body": {"plain": "Wrong."}}]},
    {"fragment": "An empty note", "annotations": [{"votes_total": 5, "body": {"plain": ""}}]},
]}}
WIKI_SEARCH = {"query": {"search": [{"title": "Parallel Universe (song)"}]}}
WIKI_PAGE = {"query": {"pages": {"1": {"title": "Parallel Universe (song)", "extract": (
    '"Parallel Universe" is a single by the Red Hot Chili Peppers from Californication.\n\n'
    "== Background ==\nKiedis wrote it about California.\n\n"
    "== Charts ==\nNumber 37.\n\n== Personnel ==\nFlea - bass")}}}}


def everything():
    return {
        "https://genius.com/api/search/song": genius_search((1, "Parallel Universe", "Red Hot Chili Peppers")),
        "https://genius.com/api/songs/1": GENIUS_SONG,
        "https://genius.com/api/referents": GENIUS_NOTES,
        "https://en.wikipedia.org/w/api.php?action=query&list=search": WIKI_SEARCH,
        "https://en.wikipedia.org/w/api.php?action=query&prop=extracts": WIKI_PAGE,
    }


class Matching(unittest.TestCase):
    def test_titles_alike_apart_from_their_tags(self):
        self.assertTrue(same_title("Parallel Universe", "Parallel Universe (2006 Remaster)"))
        self.assertTrue(same_title("Группа крови (Blood Type)", "Группа крови"))
        self.assertFalse(same_title("Universe", "Parallel Universe"))
        self.assertFalse(same_title("Love", "Lovely Day"))
        self.assertFalse(same_title("Deathmetal - Live in Nottingham", "Deathmetal"))
        self.assertFalse(same_title("DEATHMETAL (Live)", "Deathmetal"))
        self.assertTrue(same_title("Cold Heart (PNAU Remix)", "Cold Heart (PNAU remix)"))

    def test_artists_by_any_of_their_names(self):
        self.assertTrue(same_artist("КИНО (KINO)", "Кино"))
        self.assertTrue(same_artist("Elton John", "Elton John & Dua Lipa"))
        self.assertFalse(same_artist("Red Hot Chili Peppers", "Foo Fighters"))


class Answers(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.dir = Path(folder.name)
        self.now = 1_000_000.0

    def about(self, web):
        return SongAbout(self.dir, open_url=web, clock=lambda: self.now)

    def test_the_songs_pages_quoted_with_where_they_came_from(self):
        answer = self.about(Web(everything())).answer("a", "Parallel Universe", "Red Hot Chili Peppers", "Californication")
        self.assertEqual([(s["source"], s["heading"]) for s in answer["sections"]],
                         [("Genius", "About"), ("Wikipedia", "Overview"), ("Wikipedia", "Background")])
        self.assertEqual(answer["released"], "June 8, 1999")
        self.assertEqual(answer["writers"], ["Anthony Kiedis", "Flea"])
        self.assertEqual([link["name"] for link in answer["links"]], ["Genius", "Wikipedia"])
        self.assertIsNone(answer["summary"])

    def test_notes_without_the_empty_and_the_voted_down(self):
        notes = self.about(Web(everything())).answer("a", "Parallel Universe", "Red Hot Chili Peppers")["notes"]
        self.assertEqual(notes, [{"fragment": "Deep inside of a parallel universe", "text": "The private world of addiction.",
                                  "url": "https://genius.com/1", "reviewed": False}])

    def test_notes_that_repeat_the_line_or_each_other_are_left_out(self):
        pages = everything()
        long = "He is back home, and will return when he can fly high."
        pages["https://genius.com/api/referents"] = {"response": {"referents": [
            {"fragment": "Yeah", "annotations": [{"votes_total": 1, "body": {"plain": "yeah"}}]},
            {"fragment": "Make my way back home", "annotations": [{"votes_total": 1, "body": {"plain": long}}]},
            {"fragment": "Make my way back home when I learn to fly", "annotations": [{"votes_total": 1, "body": {"plain": long}}]},
        ]}}
        notes = self.about(Web(pages)).answer("a", "Parallel Universe", "Red Hot Chili Peppers")["notes"]
        self.assertEqual([n["fragment"] for n in notes], ["Make my way back home"])

    def test_a_disambiguation_page_is_not_the_song(self):
        pages = everything()
        pages["https://en.wikipedia.org/w/api.php?action=query&prop=extracts"] = {"query": {"pages": {"1": {
            "title": "Parallel Universe", "extract": "Parallel Universe may refer to:\n\n\"Parallel Universe\", a song by "
                                                    "the Red Hot Chili Peppers from the album Californication"}}}}
        sections = self.about(Web(pages)).answer("a", "Parallel Universe", "Red Hot Chili Peppers")["sections"]
        self.assertEqual([s["source"] for s in sections], ["Genius"])

    def test_a_subsection_counts_only_under_a_wanted_section(self):
        pages = everything()
        pages["https://en.wikipedia.org/w/api.php?action=query&prop=extracts"] = {"query": {"pages": {"1": {
            "title": "Parallel Universe (song)", "extract": (
                '"Parallel Universe" is a single by the Red Hot Chili Peppers.\n\n'
                "== Writing ==\nKiedis wrote it.\n\n=== Lyrics ===\nAbout addiction.\n\n"
                "== Cover versions ==\nA band covered it.\n\n=== Composition ===\nThe cover's composition.")}}}}
        sections = self.about(Web(pages)).answer("a", "Parallel Universe", "Red Hot Chili Peppers")["sections"]
        self.assertEqual([s["heading"] for s in sections if s["source"] == "Wikipedia"], ["Overview", "Writing", "Lyrics"])

    def test_another_artists_song_of_the_same_name_is_not_this_one(self):
        pages = everything()
        pages["https://genius.com/api/search/song"] = genius_search((1, "Parallel Universe", "Someone Else"))
        pages["https://en.wikipedia.org/w/api.php?action=query&prop=extracts"] = {"query": {"pages": {"1": {
            "title": "Parallel Universe (song)", "extract": '"Parallel Universe" is a song by Someone Else.'}}}}
        answer = self.about(Web(pages)).answer("a", "Parallel Universe", "Red Hot Chili Peppers")
        self.assertEqual((answer["sections"], answer["notes"], answer["links"]), ([], [], []))

    def test_of_two_pages_of_one_title_the_one_on_this_album(self):
        pages = everything()
        pages["https://genius.com/api/search/song"] = genius_search(
            (2, "Parallel Universe", "Red Hot Chili Peppers"), (1, "Parallel Universe", "Red Hot Chili Peppers"))
        pages["https://genius.com/api/songs/2"] = {"response": {"song": {
            "id": 2, "url": "https://genius.com/live", "album": {"name": "Live at Slane Castle"},
            "description": {"plain": "Live at Slane."}}}}
        pages["https://genius.com/api/songs/1"] = {"response": {"song": dict(
            GENIUS_SONG["response"]["song"], id=1, album={"name": "Californication"})}}
        answer = self.about(Web(pages)).answer("a", "Parallel Universe", "Red Hot Chili Peppers", "Californication")
        self.assertEqual(answer["sections"][0]["text"], "The second song off Californication.")

    def test_an_album_page_is_not_the_song(self):
        pages = everything()
        pages["https://en.wikipedia.org/w/api.php?action=query&prop=extracts"] = {"query": {"pages": {"1": {
            "title": "Parallel Universe (album)",
            "extract": "Parallel Universe is the debut album by the Red Hot Chili Peppers."}}}}
        pages["https://en.wikipedia.org/w/api.php?action=query&list=search"] = {
            "query": {"search": [{"title": "Parallel Universe (album)"}]}}
        sections = self.about(Web(pages)).answer("a", "Parallel Universe", "Red Hot Chili Peppers")["sections"]
        self.assertEqual([s["source"] for s in sections], ["Genius"])

    def test_the_summary_written_ahead_of_time(self):
        (self.dir / "song-about-summaries").mkdir(exist_ok=True)
        (self.dir / "song-about-summaries" / "a.json").write_text(json.dumps({"text": " About addiction. ", "basis": "lyrics"}))
        answer = self.about(Web(everything())).answer("a", "Parallel Universe", "Red Hot Chili Peppers")
        self.assertEqual(answer["summary"], {"text": "About addiction.", "basis": "lyrics"})

    def test_looked_up_once_then_kept(self):
        web = Web(everything())
        about = self.about(web)
        about.answer("a", "Parallel Universe", "Red Hot Chili Peppers")
        asked = len(web.asked)
        self.now += 30 * 86_400
        self.assertEqual(len(about.answer("a", "Parallel Universe", "Red Hot Chili Peppers")["sections"]), 3)
        self.assertEqual(len(web.asked), asked)

    def test_nothing_found_is_asked_again_after_a_month(self):
        web = Web({})
        about = self.about(web)
        self.assertEqual(about.answer("a", "Obscure", "Nobody")["sections"], [])
        asked = len(web.asked)
        self.now += 29 * 86_400
        about.answer("a", "Obscure", "Nobody")
        self.assertEqual(len(web.asked), asked)
        self.now += 2 * 86_400
        about.answer("a", "Obscure", "Nobody")
        self.assertGreater(len(web.asked), asked)

    def test_no_network_says_so_and_asks_again_within_the_hour(self):
        web = Web(fail=True)
        about = self.about(web)
        self.assertTrue(about.answer("a", "Parallel Universe", "Red Hot Chili Peppers")["unavailable"])
        web.fail, web.pages = False, everything()
        self.now += 3_601
        self.assertEqual(len(about.answer("a", "Parallel Universe", "Red Hot Chili Peppers")["sections"]), 3)

    def test_a_page_that_is_not_an_answer_is_a_failure_not_nothing(self):
        class Challenge(Web):
            def __call__(self, request, timeout=None):
                self.asked.append(request.full_url)
                return io.BytesIO(b"<!DOCTYPE html><html>Just a moment...</html>")
        self.assertTrue(self.about(Challenge()).answer("a", "Parallel Universe", "Red Hot Chili Peppers")["unavailable"])

    def test_a_failed_refresh_keeps_what_was_found(self):
        web = Web(everything())
        about = self.about(web)
        about.answer("a", "Parallel Universe", "Red Hot Chili Peppers")
        web.fail = True
        answer = about.answer("a", "Parallel Universe", "Red Hot Chili Peppers", refresh=True)
        self.assertEqual(len(answer["sections"]), 3)
        self.assertNotIn("unavailable", answer)

    def test_a_song_in_another_language_falls_back_to_its_wikipedia(self):
        pages = {"https://ru.wikipedia.org/w/api.php?action=query&list=search": {
                     "query": {"search": [{"title": "Группа крови (песня)"}]}},
                 "https://ru.wikipedia.org/w/api.php?action=query&prop=extracts": {"query": {"pages": {"1": {
                     "title": "Группа крови (песня)",
                     "extract": "«Группа крови» — песня группы «Кино».\n\n== История песни ==\nНаписана в 1987 году."}}}}}
        sections = self.about(Web(pages)).answer("a", "Группа крови", "Кино", language="ru")["sections"]
        self.assertEqual([(s["source"], s["heading"]) for s in sections],
                         [("Wikipedia (ru)", "Overview"), ("Wikipedia (ru)", "История песни")])


if __name__ == "__main__":
    unittest.main()
