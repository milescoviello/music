"""What an album or an artist is about, for the About section of their pages: the same three kinds of thing as a
song's About sheet (`about.py`), less the notes on lines.

- **Background**, quoted: the album's or artist's Genius write-up, and the opening of its Wikipedia article with
  the sections that say how it came about and what it is (an album's Background, Recording, Composition, Themes,
  Reception...; an artist's History and its parts, Musical style, Influences, Legacy...).
- **What it's about** / **who they are**: a few paragraphs written ahead of time by Claude from those sources (and
  searches, whose links it keeps), in `data/album-about-summaries/<album id>.json` or
  `data/artist-about-summaries/<artist id>.json` = {"text", "basis", "links"?}. An album's `basis` is "songs" when
  nothing has been written about it and the summary rests on its songs' own pages and lyrics.

Looked up the first time it is asked about and kept in `data/record-about.db` on the same terms as a song's: found
for half a year, nothing for a month, a failure for an hour. A match has to be it: an album page of the same title
by the same artist, an artist page of the same name that says it is a musician or a band.
"""

from __future__ import annotations

import json
import logging
import re
import sqlite3
import threading
import time
import urllib.parse
import urllib.request
from contextlib import contextmanager
from pathlib import Path

from . import lrclib
from .about import (BROWSER, DISAMBIGUATION, FAIL_RETRY, GENIUS, KEEP, NONE_RETRY, WIKIPEDIA, _cap, _names,
                    _sections, get_json, plain, same_artist)

log = logging.getLogger(__name__)


def aliases(name: str | None) -> set[str]:
    """An artist's whole name, and each name in brackets or outside them: "Кино (Kino)" -> кинокino, кино, kino.
    Never the parts of "Simon & Garfunkel": a page for "Simon" is not theirs."""
    parts = [part for part in re.split(r"\s*[()]\s*", name or "") if part.strip()]
    return {alias for alias in [plain(name)] + [plain(part) for part in parts] if len(alias) >= 2}


def same_name(theirs: str | None, ours: str) -> bool:
    return bool(aliases(theirs) & aliases(ours))


def same_album(theirs: str | None, ours: str) -> bool:
    """The same album, editions and brackets aside: "Currents (Deluxe)" is Currents, "Deathmetal" is
    D>E>A>T>H>M>E>T>A>L; "Kessoku Band Extra Music" is not Kessoku Band (a song's looser match would say it is)."""
    def core(title):
        return plain(re.sub(r"\s*[(\[][^)\]]*[)\]]", "", lrclib.clean(title or "")))
    return bool(core(ours)) and core(theirs) == core(ours)

SECTION_CHARS = 2_400
MAX_SECTIONS = 7
KINDS = ("album", "artist")

ALBUM_WORDS = re.compile(r"\b(album|EP|extended play|mixtape|mini-album|compilation|soundtrack|LP|record)s?\b|"
                         r"альбом|アルバム|専輯|专辑|앨범", re.I)
# Music words only: "group", "act" or "artist" alone say as much about a painter or an ethnic group.
ARTIST_WORDS = re.compile(r"\b(band|musician|singer|rapper|songwriter|vocalist|guitarist|pianist|drummer|bassist|"
                          r"composer|record producer|DJ|disc jockey|VTuber|virtual YouTuber|idol|orchestra|supergroup|"
                          r"(?:musical|music|rock|pop|hip[- ]hop|punk|metal|indie|electronic|folk|jazz|girl|boy|idol|"
                          r"vocal|rap|dance|synth-?pop|J-pop|K-pop)(?: music)? (?:group|duo|trio|act|project|collective|"
                          r"ensemble|unit))s?\b|групп|певе|певиц|музыкант|исполнител|歌手|バンド|音楽グループ|アイドル|"
                          r"ユニット|歌い手|作曲家|シンガー|가수|밴드|그룹", re.I)
# What an album section must be about to be quoted: how it was made, what is on it, what was made of it.
ALBUM_WANTED = re.compile(r"background|recording|production|writing|written|composition|music|lyric|theme|concept|"
                          r"title|artwork|packaging|inspiration|development|content|style|reception|legacy|"
                          r"история|запис|背景|制作|音楽性", re.I)
ALBUM_UNWANTED = re.compile(r"track ?list|personnel|chart|certif|release history|reference|external|see also|notes|"
                            r"accolade|ranking|sales|commercial|tour|video|credit|year-end|weekly|bonus|edition", re.I)
# An artist's: their story and their sound; not discographies, members tables, awards or private and legal life.
ARTIST_WANTED = re.compile(r"history|background|early|career|formation|biography|origin|style|influence|artistry|"
                           r"legacy|image|sound|\d{4}|история|経歴|来歴|音楽性", re.I)
ARTIST_UNWANTED = re.compile(r"discograph|member|personnel|line-?up|award|accolade|nominat|tour|reference|external|"
                             r"see also|notes|filmograph|bibliograph|video|lawsuit|legal|controvers|personal life|"
                             r"philanthrop|endorse|equipment|gear", re.I)


class RecordAbout:
    def __init__(self, data_dir: Path, open_url=None, clock=time.time):
        self.path = data_dir / "record-about.db"
        self.summaries = {kind: data_dir / f"{kind}-about-summaries" for kind in KINDS}
        for folder in self.summaries.values():
            folder.mkdir(parents=True, exist_ok=True)
        self._open = open_url or urllib.request.urlopen
        self._clock = clock
        self._lock = threading.Lock()
        with self._db() as db:
            db.execute("create table if not exists about (kind text not null, id text not null, at real not null, "
                       "found integer not null, data text, primary key (kind, id))")

    @contextmanager
    def _db(self):
        db = sqlite3.connect(self.path, timeout=10)
        try:
            with db:
                yield db
        finally:
            db.close()

    # MARK: - The answer

    def answer(self, kind: str, item_id: str, name: str, artist: str = "", refresh: bool = False) -> dict:
        """kind "album" (name = the album, artist = its album artist) or "artist" (name = the artist)."""
        found = self._found(kind, item_id, name, artist, refresh)
        summary = self.summary(kind, item_id)
        answer = {"id": item_id, "kind": kind, "title": name, "artist": artist if kind == "album" else name,
                  **found, "summary": summary and {k: summary[k] for k in ("text", "basis")}}
        known = {link.get("url") for link in answer.get("links") or []}
        extra = [link for link in (summary or {}).get("links", []) if link["url"] not in known]
        if extra:
            answer["links"] = list(answer.get("links") or []) + extra
        return answer

    def summary(self, kind: str, item_id: str) -> dict | None:
        if kind not in KINDS or not item_id or "/" in item_id or item_id.startswith("."):
            return None
        try:
            stored = json.loads((self.summaries[kind] / f"{item_id}.json").read_text())
        except (OSError, ValueError):
            return None
        text = stored.get("text") if isinstance(stored, dict) else None
        if not isinstance(text, str) or not text.strip():
            return None
        links = [{"name": str(link["name"]), "url": str(link["url"])} for link in stored.get("links") or []
                 if isinstance(link, dict) and link.get("name") and str(link.get("url", "")).startswith("http")]
        basis = "songs" if kind == "album" and stored.get("basis") == "songs" else "sources"
        return {"text": text.strip(), "basis": basis, "links": links}

    def _found(self, kind: str, item_id: str, name: str, artist: str, refresh: bool) -> dict:
        with self._db() as db:
            row = db.execute("select at, found, data from about where kind = ? and id = ?", (kind, item_id)).fetchone()
        now = self._clock()
        if row and not refresh:
            at, found, data = row
            fresh = KEEP if found == 1 else (NONE_RETRY if found == 0 else FAIL_RETRY)
            if now - at < fresh:
                return json.loads(data) if data else {}
        with self._lock:
            try:
                fetched = self.fetch(kind, name, artist)
                state = 1 if fetched["sections"] else 0
            except OSError as error:   # urllib's errors are OSErrors
                log.warning("%s about %s: %s", kind, item_id, error)
                previous = json.loads(row[2]) if row and row[2] else None
                if previous and previous.get("sections"):
                    return previous     # what was found before beats nothing
                fetched, state = {"sections": [], "links": [], "unavailable": True}, -1
            with self._db() as db:
                db.execute("insert or replace into about (kind, id, at, found, data) values (?, ?, ?, ?, ?)",
                           (kind, item_id, now, state, json.dumps(fetched, ensure_ascii=False)))
        return fetched

    # MARK: - Looking it up

    def _get(self, url: str, query: dict, agent: str) -> object:
        return get_json(self._open, url, query, agent)

    def fetch(self, kind: str, name: str, artist: str = "") -> dict:
        sections, links, extra = [], [], {}
        genius = self.genius_album(name, artist) if kind == "album" else self.genius_artist(name)
        if genius:
            text, url, released = genius
            if text:
                sections.append({"source": "Genius", "heading": "About", "text": _cap(text, SECTION_CHARS), "url": url})
            links.append({"name": "Genius", "url": url})
            if released:
                extra["released"] = released
        wiki = self.wikipedia_album(name, artist) if kind == "album" else self.wikipedia_artist(name)
        if wiki:
            url, parts, lang = wiki
            source = "Wikipedia" if lang == "en" else f"Wikipedia ({lang})"
            for heading, text in parts:
                sections.append({"source": source, "heading": heading or "Overview", "text": text, "url": url})
            links.append({"name": source, "url": url})
        return {"sections": sections, "links": links, **extra}

    def _genius_hits(self, kind: str, query: str) -> list[dict]:
        found = self._get(f"{GENIUS}/search/{kind}", {"q": query, "per_page": 5}, BROWSER) or {}
        return [hit.get("result") or {} for section in (found.get("response") or {}).get("sections") or []
                for hit in section.get("hits") or [] if hit.get("type") == kind]

    def genius_album(self, name: str, artist: str) -> tuple[str, str, str | None] | None:
        """(write-up, page, release date) of the album's Genius page, or None when no hit is this album."""
        first = re.split(r"\s*(?:[&,/;•·+]|\bfeat\.?|\bft\.?|\bwith\b|\bx\b)\s*", artist or "", flags=re.I)[0]
        for query in dict.fromkeys([f"{name} {artist}", f"{lrclib.clean(name)} {first}"]):
            hits = [hit for hit in self._genius_hits("album", query)
                    if same_album(hit.get("name"), name) and same_artist((hit.get("artist") or {}).get("name"), artist)]
            if not hits:
                continue
            album = ((self._get(f"{GENIUS}/albums/{hits[0]['id']}", {"text_format": "plain"}, BROWSER) or {})
                     .get("response") or {}).get("album")
            if not album:
                return None
            annotation = ((album.get("description_annotation") or {}).get("annotations") or [{}])[0]
            text = ((annotation.get("body") or {}).get("plain") or "").strip()
            return (text if text != "?" else ""), album.get("url") or hits[0].get("url"), album.get("release_date_for_display")
        return None

    def genius_artist(self, name: str) -> tuple[str, str, None] | None:
        for hit in self._genius_hits("artist", name):
            if not same_name(hit.get("name"), name):
                continue
            found = ((self._get(f"{GENIUS}/artists/{hit['id']}", {"text_format": "plain"}, BROWSER) or {})
                     .get("response") or {}).get("artist")
            if not found:
                return None
            text = ((found.get("description") or {}).get("plain") or "").strip()
            return (text if text != "?" else ""), found.get("url") or hit.get("url"), None
        return None

    def _article(self, page: str, lang: str) -> tuple[str, list] | None:
        """(title after redirects, sections) of one page; None when there is no such page."""
        base = WIKIPEDIA.format(lang=lang) + "/w/api.php"
        got = self._get(base, {"action": "query", "prop": "extracts", "explaintext": 1, "exsectionformat": "wiki",
                               "titles": page, "redirects": 1, "format": "json"}, lrclib.USER_AGENT) or {}
        pages = list(((got.get("query") or {}).get("pages") or {}).values())
        if not pages or "missing" in pages[0]:
            return None
        return pages[0].get("title") or page, _sections(pages[0].get("extract") or "")

    def _search(self, query: str, lang: str) -> list[str]:
        base = WIKIPEDIA.format(lang=lang) + "/w/api.php"
        found = self._get(base, {"action": "query", "list": "search", "srsearch": query, "srlimit": 5,
                                 "format": "json"}, lrclib.USER_AGENT) or {}
        return [hit.get("title") or "" for hit in (found.get("query") or {}).get("search") or []]

    @staticmethod
    def _keep(parts: list, wanted: re.Pattern, unwanted: re.Pattern) -> list[tuple[str, str]]:
        keep = [("", _cap(parts[0][2], SECTION_CHARS))]
        for heading, parent, text in parts[1:]:
            # A subsection counts only under a wanted section, and nothing under an unwanted one.
            if (wanted.search(heading) or parent != heading and wanted.search(parent)) \
                    and not unwanted.search(heading) and not unwanted.search(parent) and len(keep) < MAX_SECTIONS:
                keep.append((heading, _cap(text, SECTION_CHARS)))
        return keep

    @staticmethod
    def _url(title: str, lang: str) -> str:
        return f"{WIKIPEDIA.format(lang=lang)}/wiki/{urllib.parse.quote(title.replace(' ', '_'), safe='()')}"

    def _first(self, lang: str, titles: list[str], query: str, fits) -> tuple[str, list, str] | None:
        """The first of the likely titles, then of a search's hits, whose page `fits`: (url, sections, lang)."""
        tried = set()
        for page in titles + [None]:
            pages = [page] if page else self._search(query, lang)
            for candidate in pages:
                if candidate in tried:
                    continue
                tried.add(candidate)
                article = self._article(candidate, lang)
                if not article or not article[1] or article[1][0][0]:
                    continue
                title, parts = article
                if title in tried and title != candidate:
                    continue    # a redirect to a page already turned down
                tried.add(title)
                opening = parts[0][2]
                if DISAMBIGUATION.search(opening[:300]):
                    continue
                kept = fits(title, parts, opening)
                if kept:
                    return self._url(title, lang), kept, lang
        return None

    def wikipedia_album(self, name: str, artist: str) -> tuple[str, list, str] | None:
        """The album's own article: its title starts with the album's, and its opening names the artist and calls
        it an album (or EP, mixtape, soundtrack...). The English Wikipedia's, else the name's own language's."""
        clean = lrclib.clean(name)
        if len(plain(clean)) < 2:
            return None

        def fits(title, parts, opening):
            if not plain(title).startswith(plain(clean)) or not ALBUM_WORDS.search(opening[:600]) \
                    or not any(n in plain(opening[:800]) for n in _names(artist)):
                return None
            return self._keep(parts, ALBUM_WANTED, ALBUM_UNWANTED)

        for lang in _languages(f"{name} {artist}"):
            titles = [f"{clean} ({artist} album)", f"{clean} (album)", f"{clean} (EP)", clean] if lang == "en" else [clean]
            found = self._first(lang, titles, f'"{clean}" {artist}' + (" album" if lang == "en" else ""), fits)
            if found:
                return found
        return None

    def wikipedia_artist(self, name: str) -> tuple[str, list, str] | None:
        """The artist's own article: its title is the name (a "(band)" or "(singer)" after it aside), and its
        opening says it is a musician, a band or the like. The English Wikipedia's, else the name's own language's."""
        if len(plain(name)) < 2:
            return None

        def fits(title, parts, opening):
            # "Panchiko", "Nirvana (band)", "Kino (band)": the name, with at most a bracket after it.
            if not (same_name(title, name) or same_name(re.sub(r"\s*\([^)]*\)$", "", title), name)):
                return None
            if not ARTIST_WORDS.search(opening[:500]):
                return None
            return self._keep(parts, ARTIST_WANTED, ARTIST_UNWANTED)

        for lang in _languages(name):
            kinds = {"en": ("band", "musician", "singer", "rapper", "group", "duo"), "ru": ("группа", "певец", "певица"),
                     "ja": ("バンド", "歌手", "ユニット"), "ko": ("가수", "밴드")}[lang]
            titles = [name] + [f"{name} ({kind})" for kind in kinds]
            found = self._first(lang, titles, f'"{name}" band' if lang == "en" else f'"{name}"', fits)
            if found:
                return found
        return None


def _languages(text: str) -> list[str]:
    """English first; then the language the name is written in, when its script says (Кино: ru; 結束バンド: ja)."""
    if re.search(r"[\u0400-\u04ff]", text):
        return ["en", "ru"]
    if re.search(r"[\u3040-\u30ff\u4e00-\u9fff]", text):
        return ["en", "ja"]
    if re.search(r"[\uac00-\ud7af]", text):
        return ["en", "ko"]
    return ["en"]
