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
    "description": {"plain": "The second song off Harbour Nights."},
    "writer_artists": [{"name": "Ada Marsh"}, {"name": "Ben Tully"}]}}}
GENIUS_NOTES = {"response": {"referents": [
    {"fragment": "Out past the glass harbour lights", "classification": "unreviewed", "url": "https://genius.com/1",
     "annotations": [{"votes_total": 3, "body": {"plain": "The singer's hometown pier."}}]},
    {"fragment": "A voted-down note", "annotations": [{"votes_total": -2, "body": {"plain": "Wrong."}}]},
    {"fragment": "An empty note", "annotations": [{"votes_total": 5, "body": {"plain": ""}}]},
]}}
WIKI_SEARCH = {"query": {"search": [{"title": "Glass Harbour (song)"}]}}
WIKI_PAGE = {"query": {"pages": {"1": {"title": "Glass Harbour (song)", "extract": (
    '"Glass Harbour" is a single by the Velvet Oranges from Harbour Nights.\n\n'
    "== Background ==\nMarsh wrote it about the coast.\n\n"
    "== Charts ==\nNumber 37.\n\n== Personnel ==\nTully - bass")}}}}


def everything():
    return {
        "https://genius.com/api/search/song": genius_search((1, "Glass Harbour", "The Velvet Oranges")),
        "https://genius.com/api/songs/1": GENIUS_SONG,
        "https://genius.com/api/referents": GENIUS_NOTES,
        "https://en.wikipedia.org/w/api.php?action=query&list=search": WIKI_SEARCH,
        "https://en.wikipedia.org/w/api.php?action=query&prop=extracts": WIKI_PAGE,
    }


class Matching(unittest.TestCase):
    def test_titles_alike_apart_from_their_tags(self):
        self.assertTrue(same_title("Glass Harbour", "Glass Harbour (2006 Remaster)"))
        self.assertTrue(same_title("Песня ветра (Wind Song)", "Песня ветра"))
        self.assertFalse(same_title("Harbour", "Glass Harbour"))
        self.assertFalse(same_title("Paper", "Paper Moons Rising"))
        self.assertFalse(same_title("Glass Harbour - Live in Leeds", "Glass Harbour"))
        self.assertFalse(same_title("GLASS HARBOUR (Live)", "Glass Harbour"))
        self.assertTrue(same_title("Slow Comet (Sunfold Remix)", "Slow Comet (Sunfold remix)"))

    def test_a_title_in_another_script_by_its_romanization(self):
        self.assertTrue(same_title("ひかりの港 (hikari no minato)", "Hikari no Minato"))
        self.assertTrue(same_title("ひかりの港 (Hikari no Minato)", "ひかりの港"))
        self.assertTrue(same_title("Песня ветра (Pesnya vetra)", "Pesnya Vetra"))
        self.assertFalse(same_title("ひかりの港 (hikari no minato)", "Hikari"))
        self.assertFalse(same_title("ひかりの港 (hikari no minato) (Instrumental)", "Hikari no Minato"))
        self.assertFalse(same_title("Glass Harbour (Pier Song)", "Pier Song"))

    def test_artists_by_any_of_their_names(self):
        self.assertTrue(same_artist("ЗВЁЗДНЫЙ САД (ZVYOZDNY SAD)", "Звёздный сад"))
        self.assertTrue(same_artist("Ada Marsh", "Ada Marsh & Ben Tully"))
        self.assertFalse(same_artist("The Velvet Oranges", "Low Orbit Choir"))
        self.assertTrue(same_artist("Lantern Choir", "Lantern Choir • Cleo Ray"))


class Answers(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.dir = Path(folder.name)
        self.now = 1_000_000.0

    def about(self, web):
        return SongAbout(self.dir, open_url=web, clock=lambda: self.now)

    def test_the_songs_pages_quoted_with_where_they_came_from(self):
        answer = self.about(Web(everything())).answer("a", "Glass Harbour", "The Velvet Oranges", "Harbour Nights")
        self.assertEqual([(s["source"], s["heading"]) for s in answer["sections"]],
                         [("Genius", "About"), ("Wikipedia", "Overview"), ("Wikipedia", "Background")])
        self.assertEqual(answer["released"], "June 8, 1999")
        self.assertEqual(answer["writers"], ["Ada Marsh", "Ben Tully"])
        self.assertEqual([link["name"] for link in answer["links"]], ["Genius", "Wikipedia"])
        self.assertIsNone(answer["summary"])

    def test_stored_only_answers_from_before_and_looks_nothing_up(self):
        web = Web(everything())
        about = self.about(web)
        self.assertIsNone(about.answer("a", "Glass Harbour", "The Velvet Oranges", stored_only=True))
        self.assertEqual(web.asked, [])
        about.answer("a", "Glass Harbour", "The Velvet Oranges")
        asked = len(web.asked)
        self.now += 400 * 86_400  # long past fresh: still what was found, and no new lookup
        stored = about.answer("a", "Glass Harbour", "The Velvet Oranges", stored_only=True)
        self.assertEqual([s["source"] for s in stored["sections"]], ["Genius", "Wikipedia", "Wikipedia"])
        self.assertEqual(len(web.asked), asked)

    def test_notes_without_the_empty_and_the_voted_down(self):
        notes = self.about(Web(everything())).answer("a", "Glass Harbour", "The Velvet Oranges")["notes"]
        self.assertEqual(notes, [{"fragment": "Out past the glass harbour lights", "text": "The singer's hometown pier.",
                                  "url": "https://genius.com/1", "reviewed": False}])

    def test_notes_that_repeat_the_line_or_each_other_are_left_out(self):
        pages = everything()
        long = "He waits for the tide, and leaves when it turns."
        pages["https://genius.com/api/referents"] = {"response": {"referents": [
            {"fragment": "Yeah", "annotations": [{"votes_total": 1, "body": {"plain": "yeah"}}]},
            {"fragment": "Count the boats along the shore", "annotations": [{"votes_total": 1, "body": {"plain": long}}]},
            {"fragment": "Count the boats along the shore until the tide turns", "annotations": [{"votes_total": 1, "body": {"plain": long}}]},
        ]}}
        notes = self.about(Web(pages)).answer("a", "Glass Harbour", "The Velvet Oranges")["notes"]
        self.assertEqual([n["fragment"] for n in notes], ["Count the boats along the shore"])

    def test_a_disambiguation_page_is_not_the_song(self):
        pages = everything()
        pages["https://en.wikipedia.org/w/api.php?action=query&prop=extracts"] = {"query": {"pages": {"1": {
            "title": "Glass Harbour", "extract": "Glass Harbour may refer to:\n\n\"Glass Harbour\", a song by "
                                                    "the Velvet Oranges from the album Harbour Nights"}}}}
        sections = self.about(Web(pages)).answer("a", "Glass Harbour", "The Velvet Oranges")["sections"]
        self.assertEqual([s["source"] for s in sections], ["Genius"])

    def test_a_subsection_counts_only_under_a_wanted_section(self):
        pages = everything()
        pages["https://en.wikipedia.org/w/api.php?action=query&prop=extracts"] = {"query": {"pages": {"1": {
            "title": "Glass Harbour (song)", "extract": (
                '"Glass Harbour" is a single by the Velvet Oranges.\n\n'
                "== Writing ==\nMarsh wrote it.\n\n=== Lyrics ===\nAbout the coast.\n\n"
                "== Cover versions ==\nA band covered it.\n\n=== Composition ===\nThe cover's composition.")}}}}
        sections = self.about(Web(pages)).answer("a", "Glass Harbour", "The Velvet Oranges")["sections"]
        self.assertEqual([s["heading"] for s in sections if s["source"] == "Wikipedia"], ["Overview", "Writing", "Lyrics"])

    def test_another_artists_song_of_the_same_name_is_not_this_one(self):
        pages = everything()
        pages["https://genius.com/api/search/song"] = genius_search((1, "Glass Harbour", "Quiet Engines"))
        pages["https://en.wikipedia.org/w/api.php?action=query&prop=extracts"] = {"query": {"pages": {"1": {
            "title": "Glass Harbour (song)", "extract": '"Glass Harbour" is a song by Quiet Engines.'}}}}
        answer = self.about(Web(pages)).answer("a", "Glass Harbour", "The Velvet Oranges")
        self.assertEqual((answer["sections"], answer["notes"], answer["links"]), ([], [], []))

    def test_of_two_pages_of_one_title_the_one_on_this_album(self):
        pages = everything()
        pages["https://genius.com/api/search/song"] = genius_search(
            (2, "Glass Harbour", "The Velvet Oranges"), (1, "Glass Harbour", "The Velvet Oranges"))
        pages["https://genius.com/api/songs/2"] = {"response": {"song": {
            "id": 2, "url": "https://genius.com/live", "album": {"name": "Live at the Harbour"},
            "description": {"plain": "Live at the harbour."}}}}
        pages["https://genius.com/api/songs/1"] = {"response": {"song": dict(
            GENIUS_SONG["response"]["song"], id=1, album={"name": "Harbour Nights"})}}
        answer = self.about(Web(pages)).answer("a", "Glass Harbour", "The Velvet Oranges", "Harbour Nights")
        self.assertEqual(answer["sections"][0]["text"], "The second song off Harbour Nights.")

    def test_an_album_page_is_not_the_song(self):
        pages = everything()
        pages["https://en.wikipedia.org/w/api.php?action=query&prop=extracts"] = {"query": {"pages": {"1": {
            "title": "Glass Harbour (album)",
            "extract": "Glass Harbour is the debut album by the Velvet Oranges."}}}}
        pages["https://en.wikipedia.org/w/api.php?action=query&list=search"] = {
            "query": {"search": [{"title": "Glass Harbour (album)"}]}}
        sections = self.about(Web(pages)).answer("a", "Glass Harbour", "The Velvet Oranges")["sections"]
        self.assertEqual([s["source"] for s in sections], ["Genius"])

    def test_the_summary_written_ahead_of_time(self):
        (self.dir / "song-about-summaries").mkdir(exist_ok=True)
        (self.dir / "song-about-summaries" / "a.json").write_text(json.dumps({"text": " About the coast. ", "basis": "lyrics"}))
        answer = self.about(Web(everything())).answer("a", "Glass Harbour", "The Velvet Oranges")
        self.assertEqual(answer["summary"], {"text": "About the coast.", "basis": "lyrics"})

    def test_a_summarys_own_sources_are_linked(self):
        (self.dir / "song-about-summaries").mkdir(exist_ok=True)
        (self.dir / "song-about-summaries" / "a.json").write_text(json.dumps({
            "text": "From an interview.", "basis": "sources",
            "links": [{"name": "Interview", "url": "https://example.com/i"}, {"name": "Bad", "url": "javascript:x"}]}))
        answer = self.about(Web({})).answer("a", "Obscure", "Some Artist")
        self.assertEqual(answer["summary"], {"text": "From an interview.", "basis": "sources"})
        self.assertEqual(answer["links"], [{"name": "Interview", "url": "https://example.com/i"}])

    def test_looked_up_once_then_kept(self):
        web = Web(everything())
        about = self.about(web)
        about.answer("a", "Glass Harbour", "The Velvet Oranges")
        asked = len(web.asked)
        self.now += 30 * 86_400
        self.assertEqual(len(about.answer("a", "Glass Harbour", "The Velvet Oranges")["sections"]), 3)
        self.assertEqual(len(web.asked), asked)

    def test_nothing_found_is_asked_again_after_a_month(self):
        web = Web({})
        about = self.about(web)
        self.assertEqual(about.answer("a", "Obscure", "Some Artist")["sections"], [])
        asked = len(web.asked)
        self.now += 29 * 86_400
        about.answer("a", "Obscure", "Some Artist")
        self.assertEqual(len(web.asked), asked)
        self.now += 2 * 86_400
        about.answer("a", "Obscure", "Some Artist")
        self.assertGreater(len(web.asked), asked)

    def test_no_network_says_so_and_asks_again_within_the_hour(self):
        web = Web(fail=True)
        about = self.about(web)
        self.assertTrue(about.answer("a", "Glass Harbour", "The Velvet Oranges")["unavailable"])
        web.fail, web.pages = False, everything()
        self.now += 3_601
        self.assertEqual(len(about.answer("a", "Glass Harbour", "The Velvet Oranges")["sections"]), 3)

    def test_a_page_that_is_not_an_answer_is_a_failure_not_nothing(self):
        class Challenge(Web):
            def __call__(self, request, timeout=None):
                self.asked.append(request.full_url)
                return io.BytesIO(b"<!DOCTYPE html><html>Just a moment...</html>")
        self.assertTrue(self.about(Challenge()).answer("a", "Glass Harbour", "The Velvet Oranges")["unavailable"])

    def test_a_failed_refresh_keeps_what_was_found(self):
        web = Web(everything())
        about = self.about(web)
        about.answer("a", "Glass Harbour", "The Velvet Oranges")
        web.fail = True
        answer = about.answer("a", "Glass Harbour", "The Velvet Oranges", refresh=True)
        self.assertEqual(len(answer["sections"]), 3)
        self.assertNotIn("unavailable", answer)

    def test_a_song_in_another_language_falls_back_to_its_wikipedia(self):
        pages = {"https://ru.wikipedia.org/w/api.php?action=query&list=search": {
                     "query": {"search": [{"title": "Песня ветра (песня)"}]}},
                 "https://ru.wikipedia.org/w/api.php?action=query&prop=extracts": {"query": {"pages": {"1": {
                     "title": "Песня ветра (песня)",
                     "extract": "«Песня ветра» — песня группы «Звёздный сад».\n\n== История песни ==\nНаписана в 1987 году."}}}}}
        sections = self.about(Web(pages)).answer("a", "Песня ветра", "Звёздный сад", language="ru")["sections"]
        self.assertEqual([(s["source"], s["heading"]) for s in sections],
                         [("Wikipedia (ru)", "Overview"), ("Wikipedia (ru)", "История песни")])


if __name__ == "__main__":
    unittest.main()
