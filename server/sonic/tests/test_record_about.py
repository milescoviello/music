"""The About section of album and artist pages: which pages count as theirs, what is kept of them, and the summary."""

import json
import tempfile
import unittest
from pathlib import Path

from sonic.record_about import RecordAbout, same_album, same_name
from tests.test_about import Web


def search(kind, *hits):
    return {"response": {"sections": [{"type": kind, "hits": [
        {"type": kind, "result": dict(id=id_, name=name, **({"artist": {"name": artist}} if artist else {}))}
        for id_, name, artist in hits]}]}}


ALBUM_WIKI = {"query": {"pages": {"1": {"title": "Currents (album)", "extract": (
    "Currents is the third studio album by Australian musical project Tame Impala.\n\n"
    "== Background ==\nParker broke up and moved home.\n\n=== Title ===\nAn old power station.\n\n"
    "== Track listing ==\n1. Let It Happen\n\n== Critical reception ==\nAcclaim.\n\n"
    "== Charts ==\nNumber one.\n\n=== Weekly charts ===\nAustralia 1")}}}}
ARTIST_WIKI = {"query": {"pages": {"1": {"title": "Panchiko", "extract": (
    "Panchiko is a British indie rock band from Nottingham.\n\n"
    "== History ==\n\n=== 1997–2001: Formation ===\nThey formed at school.\n\n"
    "=== 2016–2020: Resurgence ===\nA 4chan post.\n\n== Band members ==\nOwain Davies\n\n"
    "== Discography ==\n\n=== Studio albums ===\nFailed at Math(s)")}}}}


def album_pages():
    return {
        "https://genius.com/api/search/album": search("album", (7, "Currents", "Tame Impala")),
        "https://genius.com/api/albums/7": {"response": {"album": {
            "url": "https://genius.com/albums/Tame-impala/Currents", "release_date_for_display": "July 17, 2015",
            "description_annotation": {"annotations": [{"body": {"plain": "A warm sonic wave."}}]}}}},
        "https://en.wikipedia.org/w/api.php?action=query&list=search": {"query": {"search": [
            {"title": "Currents (Martin Garrix song)"}, {"title": "Currents (album)"}]}},
        "https://en.wikipedia.org/w/api.php?action=query&prop=extracts": ALBUM_WIKI,
    }


def artist_pages():
    return {
        "https://genius.com/api/search/artist": search("artist", (3, "Panchiko", None)),
        "https://genius.com/api/artists/3": {"response": {"artist": {
            "url": "https://genius.com/artists/Panchiko", "description": {"plain": "A band from Nottingham."}}}},
        "https://en.wikipedia.org/w/api.php?action=query&list=search": {"query": {"search": [{"title": "Panchiko"}]}},
        "https://en.wikipedia.org/w/api.php?action=query&prop=extracts": ARTIST_WIKI,
    }


class Answers(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.dir = Path(folder.name)
        self.now = 1_000_000.0

    def about(self, web):
        return RecordAbout(self.dir, open_url=web, clock=lambda: self.now)

    def test_an_albums_pages_quoted_without_its_tracks_and_charts(self):
        answer = self.about(Web(album_pages())).answer("album", "al", "Currents", "Tame Impala")
        self.assertEqual([(s["source"], s["heading"]) for s in answer["sections"]],
                         [("Genius", "About"), ("Wikipedia", "Overview"), ("Wikipedia", "Background"),
                          ("Wikipedia", "Title"), ("Wikipedia", "Critical reception")])
        self.assertEqual(answer["sections"][0]["text"], "A warm sonic wave.")
        self.assertEqual(answer["released"], "July 17, 2015")
        self.assertEqual([link["url"] for link in answer["links"]],
                         ["https://genius.com/albums/Tame-impala/Currents", "https://en.wikipedia.org/wiki/Currents_(album)"])
        self.assertEqual((answer["kind"], answer["title"], answer["artist"]), ("album", "Currents", "Tame Impala"))
        self.assertIsNone(answer["summary"])

    def test_an_artists_story_without_members_or_discography(self):
        answer = self.about(Web(artist_pages())).answer("artist", "ar", "Panchiko")
        self.assertEqual([s["heading"] for s in answer["sections"]],
                         ["About", "Overview", "1997–2001: Formation", "2016–2020: Resurgence"])
        self.assertEqual(answer["artist"], "Panchiko")

    def test_another_artists_album_of_the_same_name_is_not_this_one(self):
        pages = album_pages()
        pages["https://genius.com/api/search/album"] = search("album", (7, "Currents", "Martin Garrix"))
        pages["https://en.wikipedia.org/w/api.php?action=query&prop=extracts"] = {"query": {"pages": {"1": {
            "title": "Currents (album)", "extract": "Currents is an album by Someone Else."}}}}
        answer = self.about(Web(pages)).answer("album", "al", "Currents", "Tame Impala")
        self.assertEqual((answer["sections"], answer["links"]), ([], []))

    def test_another_album_whose_title_starts_the_same_is_not_this_one(self):
        self.assertTrue(same_album("Currents (Deluxe)", "Currents"))
        self.assertTrue(same_album("Deathmetal", "D>E>A>T>H>M>E>T>A>L"))
        self.assertFalse(same_album("Kessoku Band Extra Music", "Kessoku Band"))
        pages = album_pages()
        pages["https://genius.com/api/search/album"] = search("album", (7, "Currents Extra Music", "Tame Impala"))
        sections = self.about(Web(pages)).answer("album", "al", "Currents", "Tame Impala")["sections"]
        self.assertNotIn("Genius", [s["source"] for s in sections])

    def test_a_song_page_is_not_the_album(self):
        pages = album_pages()
        pages["https://en.wikipedia.org/w/api.php?action=query&prop=extracts"] = {"query": {"pages": {"1": {
            "title": "Currents (song)", "extract": '"Currents" is a song by Tame Impala, released as a single.'}}}}
        sections = self.about(Web(pages)).answer("album", "al", "Currents", "Tame Impala")["sections"]
        self.assertEqual([s["source"] for s in sections], ["Genius"])

    def test_a_namesake_who_is_no_musician_is_not_the_artist(self):
        pages = artist_pages()
        pages["https://en.wikipedia.org/w/api.php?action=query&prop=extracts"] = {"query": {"pages": {"1": {
            "title": "Panchiko", "extract": "Panchiko is a village in Bulgaria."}}}}
        sections = self.about(Web(pages)).answer("artist", "ar", "Panchiko")["sections"]
        self.assertEqual([s["source"] for s in sections], ["Genius"])

    def test_part_of_a_duos_name_is_not_the_duo(self):
        self.assertFalse(same_name("Simon", "Simon & Garfunkel"))
        self.assertTrue(same_name("Kino (band)", "Кино (Kino)"))
        self.assertTrue(same_name("КИНО", "Кино"))
        pages = artist_pages()
        pages["https://genius.com/api/search/artist"] = search("artist", (3, "Simon", None))
        answer = self.about(Web(pages)).answer("artist", "ar", "Simon & Garfunkel")
        self.assertNotIn("Genius", [s["source"] for s in answer["sections"]])

    def test_the_summary_written_ahead_of_time_and_its_links(self):
        folder = self.dir / "album-about-summaries"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "al.json").write_text(json.dumps({"text": " About change. ", "basis": "songs",
                                                    "links": [{"name": "Interview", "url": "https://example.com/i"}]}))
        answer = self.about(Web(album_pages())).answer("album", "al", "Currents", "Tame Impala")
        self.assertEqual(answer["summary"], {"text": "About change.", "basis": "songs"})
        self.assertEqual(answer["links"][-1], {"name": "Interview", "url": "https://example.com/i"})
        # "songs" is an album's word only; an artist's summary rests on sources.
        (self.dir / "artist-about-summaries" / "ar.json").write_text(json.dumps({"text": "A band.", "basis": "songs"}))
        self.assertEqual(self.about(Web({})).answer("artist", "ar", "Panchiko")["summary"]["basis"], "sources")

    def test_kept_and_asked_again_only_when_stale(self):
        web = Web(album_pages())
        about = self.about(web)
        about.answer("album", "al", "Currents", "Tame Impala")
        asked = len(web.asked)
        about.answer("album", "al", "Currents", "Tame Impala")
        self.assertEqual(len(web.asked), asked)
        about.answer("album", "al", "Currents", "Tame Impala", refresh=True)
        self.assertGreater(len(web.asked), asked)

    def test_unreachable_is_said_and_retried_within_the_hour(self):
        about = self.about(Web(fail=True))
        self.assertTrue(about.answer("artist", "ar", "Panchiko")["unavailable"])
        self.now += 3_700
        about._open = Web(artist_pages())
        self.assertFalse(about.answer("artist", "ar", "Panchiko").get("unavailable"))

    def test_an_album_and_an_artist_of_one_id_are_kept_apart(self):
        web = Web({**album_pages(), **{k: v for k, v in artist_pages().items() if "genius" in k}})
        about = self.about(web)
        album = about.answer("album", "x", "Currents", "Tame Impala")
        artist = about.answer("artist", "x", "Panchiko")
        self.assertEqual(album["sections"][0]["text"], "A warm sonic wave.")
        self.assertEqual(artist["sections"][0]["text"], "A band from Nottingham.")


if __name__ == "__main__":
    unittest.main()
