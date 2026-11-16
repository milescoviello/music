"""What a song is about, for the player's About sheet.

Three kinds of thing, each from where it can be trusted, and each shown with where it came from:

- **Background**, quoted: the "About" Genius has for the song, and its Wikipedia article's opening and the
  sections that say how it came about or what it means (Background, Writing, Composition, Lyrics, Themes...). For
  a song in another language with no English article, that language's Wikipedia.
- **Notes on lines**: Genius's notes on fragments of the lyrics, mostly written by listeners (Genius marks few as
  reviewed), in the order of the song.
- **What it's about**: a few sentences written ahead of time (by Claude, from those sources and the lyrics) into
  `data/song-about-summaries/<song id>.json` = {"text", "basis"}. `basis` "sources" when it rests on them,
  "lyrics" when there was nothing to go on but the words, which the app says.

A song is looked up the first time it is asked about and kept in `data/song-about.db`: what was found for half a
year, "nothing found" for a month, a failure to reach Genius or Wikipedia for an hour. A match has to be the
song: the same title (remaster and live tags aside) by the same artist, so a wrong page is not shown as this
song's. Standard library only.
"""

from __future__ import annotations

import json
import logging
import re
import sqlite3
import threading
import time
import unicodedata
from contextlib import contextmanager
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from . import lrclib

log = logging.getLogger(__name__)

GENIUS = "https://genius.com/api"
WIKIPEDIA = "https://{lang}.wikipedia.org"
# Genius's API answers a browser and refuses most other agents.
BROWSER = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
KEEP = 180 * 86_400
NONE_RETRY = 30 * 86_400
FAIL_RETRY = 3_600
SECTION_CHARS = 2_000
NOTE_CHARS = 1_500
MAX_NOTES = 40
# Headings that say how a song came about or what it means; not charts, personnel, covers or the video.
WANTED = re.compile(r"background|writing|written|composition|lyric|meaning|theme|inspiration|recording|concept|"
                    r"content|interpretation|origin|development|production|история|создани|текст|背景|制作|歌詞", re.I)
UNWANTED = re.compile(r"release|chart|personnel|track ?list|video|reference|credit|certif|accolade|cover|live|"
                      r"version|reception|legacy|performance|in popular culture|external|see also|notes", re.I)
DISAMBIGUATION = re.compile(r"may (also )?refer to|может означать|может относиться|曖昧さ回避", re.I)
SONG_WORDS = re.compile(r"\b(song|single|track|ballad|anthem)\b|песн|сингл|曲|シングル|楽曲", re.I)


def plain(text: str | None) -> str:
    text = unicodedata.normalize("NFKC", text or "").casefold().replace("ё", "е")
    return "".join(ch for ch in text if ch.isalnum())


def _names(artist: str) -> list[str]:
    """"Кино (Kino)" -> ["кинокino", "кино", "kino"]; "Elton John & Dua Lipa" or "The Strokes • Julian
    Casablancas" -> both, and each."""
    parts = re.split(r"\s*(?:[()&,/;•·+]|\bfeat\.?|\bft\.?|\bwith\b|\band\b|\bx\b)\s*", artist or "", flags=re.I)
    return [name for name in dict.fromkeys([plain(artist)] + [plain(part) for part in parts]) if len(name) >= 2]


OTHER_TAKE = re.compile(r"\b(live|remix|demo|acoustic|instrumental|cover|karaoke|sped up|slowed)\b", re.I)


def same_title(theirs: str | None, ours: str) -> bool:
    # "Deathmetal - Live in Nottingham" is another recording's page, not the album track "Deathmetal".
    take = OTHER_TAKE.search(theirs or "")
    if take and not re.search(rf"\b{re.escape(take.group(1))}\b", ours, re.I):
        return False
    a, b = plain(lrclib.clean(theirs or "")), plain(lrclib.clean(ours))
    if not a or not b:
        return False
    if a == b:
        return True
    # "Группа крови (Blood Type)" for "Группа крови"; never a short title inside a long one.
    shorter, longer = sorted((a, b), key=len)
    return longer.startswith(shorter) and len(shorter) >= 4 and len(shorter) >= 0.5 * len(longer)


def same_artist(theirs: str | None, ours: str) -> bool:
    mine, other = _names(ours), _names(theirs or "")
    return any(x == y or (min(len(x), len(y)) >= 3 and (x in y or y in x)) for x in mine for y in other)


def _sections(extract: str) -> list[tuple[str, str, str]]:
    """A plain-text Wikipedia extract as [(heading, top-level heading above it, text)], the opening first under ""."""
    out, heading, parent, body = [], "", "", []
    for line in extract.splitlines():
        m = re.match(r"^(=+)\s*(.*?)\s*\1\s*$", line)
        if m:
            out.append((heading, parent, "\n".join(body).strip()))
            heading, body = m[2], []
            parent = heading if len(m[1]) <= 2 else parent
            continue
        body.append(line)
    out.append((heading, parent, "\n".join(body).strip()))
    return [(h, p, t) for h, p, t in out if t]


def _cap(text: str, limit: int) -> str:
    text = re.sub(r"\n{3,}", "\n\n", text.strip())
    if len(text) <= limit:
        return text
    cut = text[:limit]
    end = max(cut.rfind(". "), cut.rfind(".\n"), cut.rfind("。"))
    return (cut[:end + 1] if end > limit // 2 else cut.rstrip()) + " …"


class SongAbout:
    def __init__(self, data_dir: Path, open_url=None, clock=time.time):
        self.path = data_dir / "song-about.db"
        self.summaries = data_dir / "song-about-summaries"
        self.summaries.mkdir(parents=True, exist_ok=True)
        self._open = open_url or urllib.request.urlopen
        self._clock = clock
        self._lock = threading.Lock()
        with self._db() as db:
            db.execute("create table if not exists about (id text primary key, at real not null, "
                       "found integer not null, data text)")

    @contextmanager
    def _db(self):
        db = sqlite3.connect(self.path, timeout=10)
        try:
            with db:
                yield db
        finally:
            db.close()

    # MARK: - The answer

    def answer(self, track_id: str, title: str, artist: str, album: str = "", language: str | None = None,
               refresh: bool = False) -> dict:
        found = self._found(track_id, title, artist, album, language, refresh)
        answer = {"id": track_id, "title": title, "artist": artist, "album": album,
                  "summary": self.summary(track_id), **found}
        return answer

    def summary(self, track_id: str) -> dict | None:
        if not track_id or "/" in track_id or track_id.startswith("."):
            return None
        path = self.summaries / f"{track_id}.json"
        try:
            stored = json.loads(path.read_text())
        except (OSError, ValueError):
            return None
        text = stored.get("text") if isinstance(stored, dict) else None
        if not isinstance(text, str) or not text.strip():
            return None
        return {"text": text.strip(), "basis": "lyrics" if stored.get("basis") == "lyrics" else "sources"}

    def _found(self, track_id: str, title: str, artist: str, album: str, language: str | None, refresh: bool) -> dict:
        with self._db() as db:
            row = db.execute("select at, found, data from about where id = ?", (track_id,)).fetchone()
        now = self._clock()
        if row and not refresh:
            at, found, data = row
            stored = json.loads(data) if data else {}
            fresh = KEEP if found == 1 else (NONE_RETRY if found == 0 else FAIL_RETRY)
            if now - at < fresh:
                return stored
        with self._lock:
            try:
                fetched = self.fetch(title, artist, language, album)
                state = 1 if (fetched["sections"] or fetched["notes"]) else 0
            except OSError as error:   # urllib's errors are OSErrors
                log.warning("song about %s: %s", track_id, error)
                previous = json.loads(row[2]) if row and row[2] else None
                if previous and (previous.get("sections") or previous.get("notes")):
                    return previous     # what was found before beats nothing
                fetched, state = {"sections": [], "notes": [], "links": [], "unavailable": True}, -1
            with self._db() as db:
                db.execute("insert or replace into about (id, at, found, data) values (?, ?, ?, ?)",
                           (track_id, now, state, json.dumps(fetched, ensure_ascii=False)))
        return fetched

    # MARK: - Looking it up

    def _get(self, url: str, query: dict, agent: str) -> object:
        request = urllib.request.Request(f"{url}?{urllib.parse.urlencode(query)}", headers={"User-Agent": agent})
        try:
            with self._open(request, timeout=15) as reply:
                return json.load(reply)
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            raise
        except ValueError as error:
            # A challenge page instead of an answer: a failure, asked again within the hour, never "nothing found".
            raise OSError(f"not JSON from {url}") from error

    def fetch(self, title: str, artist: str, language: str | None = None, album: str = "") -> dict:
        sections, notes, links, extra = [], [], [], {}
        genius = self.genius(title, artist, album)
        if genius:
            song, referents = genius
            about = ((song.get("description") or {}).get("plain") or "").strip()
            if about and about != "?":
                sections.append({"source": "Genius", "heading": "About", "text": _cap(about, SECTION_CHARS),
                                 "url": song.get("url")})
            seen = set()
            for referent in referents:
                annotation = (referent.get("annotations") or [{}])[0]
                body = ((annotation.get("body") or {}).get("plain") or "").strip()
                fragment = (referent.get("fragment") or "").strip()
                # Not the empty, the voted down, the ones that only repeat the line ("Yeah": "yeah"), or a note
                # already shown for another of the same line's repeats.
                if not body or not fragment or (annotation.get("votes_total") or 0) < 0 or len(body) < 25 \
                        or plain(body) in plain(fragment) or plain(body) in seen:
                    continue
                seen.add(plain(body))
                notes.append({"fragment": referent["fragment"].strip(), "text": _cap(body, NOTE_CHARS),
                              "url": referent.get("url"), "reviewed": referent.get("classification") in ("accepted", "verified")})
                if len(notes) >= MAX_NOTES:
                    break
            links.append({"name": "Genius", "url": song.get("url")})
            if song.get("release_date_for_display"):
                extra["released"] = song["release_date_for_display"]
            writers = [w.get("name") for w in song.get("writer_artists") or [] if w.get("name")]
            if writers:
                extra["writers"] = writers
        for lang in dict.fromkeys(["en"] + ([language] if language and re.fullmatch(r"[a-z]{2,3}", language) else [])):
            wiki = self.wikipedia(title, artist, lang)
            if wiki:
                page, url, parts = wiki
                for heading, text in parts:
                    sections.append({"source": "Wikipedia" if lang == "en" else f"Wikipedia ({lang})",
                                     "heading": heading or "Overview", "text": text, "url": url})
                links.append({"name": "Wikipedia", "url": url})
                break
        return {"sections": sections, "notes": notes, "links": links, **extra}

    def genius(self, title: str, artist: str, album: str = "") -> tuple[dict, list] | None:
        """The song's Genius page and its notes, or None when no hit is this song."""
        for query in dict.fromkeys([f"{title} {artist}", f"{lrclib.clean(title)} {artist}"]):
            found = self._get(f"{GENIUS}/search/song", {"q": query, "per_page": 5}, BROWSER) or {}
            hits = [hit.get("result") or {} for section in (found.get("response") or {}).get("sections") or []
                    for hit in section.get("hits") or [] if hit.get("type") == "song"]
            matches = [hit for hit in hits if same_title(hit.get("title"), title) and
                       same_artist((hit.get("primary_artist") or {}).get("name") or hit.get("artist_names"), artist)]
            if not matches:
                continue
            # Several pages of one title (Panchiko's "Deathmetal": the 2000 album's, and a 2022 live album's):
            # the one on this album, else the first.
            songs = []
            for hit in matches[:3 if album else 1]:
                song = ((self._get(f"{GENIUS}/songs/{hit['id']}", {"text_format": "plain"}, BROWSER) or {})
                        .get("response") or {}).get("song")
                if song:
                    songs.append((hit["id"], song))
                    if not album or plain((song.get("album") or {}).get("name")) == plain(album):
                        break
            if not songs:
                return None
            song_id, song = next(((i, s) for i, s in songs if album and plain((s.get("album") or {}).get("name")) == plain(album)),
                                 songs[0])
            referents = ((self._get(f"{GENIUS}/referents", {"song_id": song_id, "text_format": "plain",
                                                            "per_page": 50}, BROWSER) or {})
                         .get("response") or {}).get("referents") or []
            return song, referents
        return None

    def wikipedia(self, title: str, artist: str, lang: str = "en") -> tuple[str, str, list] | None:
        """The song's own article: its title starts with the song's, and its opening names the artist and calls
        it a song or single. (page, url, [(heading, text)]) with the opening and the wanted sections."""
        base = WIKIPEDIA.format(lang=lang) + "/w/api.php"
        clean = lrclib.clean(title)
        found = self._get(base, {"action": "query", "list": "search", "srsearch": f'"{clean}" {artist}',
                                 "srlimit": 6, "format": "json"}, lrclib.USER_AGENT) or {}
        for hit in (found.get("query") or {}).get("search") or []:
            page = hit.get("title") or ""
            if not plain(page).startswith(plain(clean)) or len(plain(clean)) < 2:
                continue
            got = self._get(base, {"action": "query", "prop": "extracts", "explaintext": 1, "exsectionformat": "wiki",
                                   "titles": page, "redirects": 1, "format": "json"}, lrclib.USER_AGENT) or {}
            pages = list(((got.get("query") or {}).get("pages") or {}).values())
            extract = (pages[0].get("extract") or "") if pages else ""
            parts = _sections(extract)
            if not parts or parts[0][0]:
                continue
            opening = parts[0][2]
            if DISAMBIGUATION.search(opening[:300]) or not any(name in plain(opening) for name in _names(artist)) \
                    or not SONG_WORDS.search(opening[:600]):
                continue
            keep = [("", _cap(opening, SECTION_CHARS))]
            for heading, parent, text in parts[1:]:
                # A subsection counts only under a wanted section: "Composition" under "Cover versions" is the cover's.
                if (WANTED.search(heading) or parent != heading and WANTED.search(parent)) \
                        and not UNWANTED.search(heading) and not UNWANTED.search(parent) and len(keep) < 5:
                    keep.append((heading, _cap(text, SECTION_CHARS)))
            name = pages[0].get("title") or page
            return name, f"{WIKIPEDIA.format(lang=lang)}/wiki/{urllib.parse.quote(name.replace(' ', '_'))}", keep
        return None
