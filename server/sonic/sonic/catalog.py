"""What could be added to the library, and the relay that adds it.

A search here is YouTube Music's (songs and albums: it reads a half-remembered line far
better than MusicBrainz does), an artist's albums are MusicBrainz's official discography,
and each answer says whether the library has it already. Getting one is not done here:
`music-grab serve`, on the host beside Navidrome, finds the copy on Soulseek, downloads it,
checks it and adds it. sonic only relays the apps' `/v1/grab/*` to it, behind its own token.
"""

from __future__ import annotations

import json
import logging
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from .video import core_title, norm

log = logging.getLogger(__name__)

MUSICBRAINZ = "https://musicbrainz.org/ws/2/"
USER_AGENT = "sonic/1 ( https://github.com/milescoviello/music )"
# Secondary types that are not one of the artist's own records.
NOT_OWN = {"Compilation", "Live", "Remix", "DJ-mix", "Mixtape/Street", "Demo", "Interview", "Spokenword",
           "Audiobook", "Soundtrack"}


def _title(text: str | None) -> str:
    return norm(core_title(text))


class Have:
    """Which songs and albums the library has, by artist: built from the tracks sonic already
    holds, so an answer costs a dictionary lookup."""

    def __init__(self, tracks):
        self.songs: dict[str, set[str]] = {}
        self.albums: dict[str, set[str]] = {}
        for track in tracks:
            title, album = _title(track.title), _title(track.album)
            for artist in {norm(track.artist), norm(track.album_artist)} - {""}:
                self.songs.setdefault(artist, set()).add(title)
                self.albums.setdefault(artist, set()).add(album)

    def song(self, artists: list[str], title: str) -> bool:
        wanted = _title(title)
        return any(wanted in self.songs.get(norm(artist), ()) for artist in artists)

    def album(self, artists: list[str], title: str) -> bool:
        wanted = _title(title)
        return any(wanted in self.albums.get(norm(artist), ()) for artist in artists)


def _cover(thumbnails) -> str | None:
    """The largest picture YouTube Music offers."""
    best = max(thumbnails or [], key=lambda t: t.get("width") or 0, default=None)
    return best.get("url") if best else None


def _names(artists) -> list[str]:
    return [a.get("name") for a in artists or [] if a.get("name")]


def songs_from(results, have: Have) -> list[dict]:
    out = []
    for r in results or []:
        artists = _names(r.get("artists"))
        if not r.get("title") or not artists:
            continue
        album = r.get("album") or {}
        out.append({"title": r["title"], "artist": artists[0], "artists": artists,
                    "album": album.get("name"), "albumId": album.get("id"),
                    "seconds": r.get("duration_seconds"), "videoId": r.get("videoId"),
                    "cover": _cover(r.get("thumbnails")), "have": have.song(artists, r["title"])})
    return out


def albums_from(results, have: Have) -> list[dict]:
    out = []
    for r in results or []:
        artists = _names(r.get("artists"))
        if not r.get("title") or not artists or not r.get("browseId"):
            continue
        out.append({"title": r["title"], "artist": artists[0], "artists": artists, "year": r.get("year"),
                    "type": r.get("type") or "Album", "albumId": r["browseId"],
                    "cover": _cover(r.get("thumbnails")), "have": have.album(artists, r["title"])})
    return out


def discography_from(groups, have: Have, artist: str) -> list[dict]:
    """An artist's own albums and EPs, earliest first, one per title."""
    out, seen = [], set()
    for g in sorted(groups or [], key=lambda g: g.get("first-release-date") or "9999"):
        if g.get("primary-type") not in ("Album", "EP") or set(g.get("secondary-types") or []) & NOT_OWN:
            continue
        key = _title(g.get("title"))
        if not key or key in seen:
            continue
        seen.add(key)
        out.append({"title": g["title"], "type": g["primary-type"], "year": (g.get("first-release-date") or "")[:4] or None,
                    "mbid": g.get("id"), "have": have.album([artist], g["title"])})
    return out


class Catalog:
    def __init__(self, videos, tracks, artist_mbid):
        """`videos` lends its YouTube Music client, `tracks()` the library's tracks now, and
        `artist_mbid(id)` an artist's MusicBrainz id from Navidrome's database."""
        self._videos = videos
        self._tracks = tracks
        self._artist_mbid = artist_mbid
        self._have: tuple[float, int, Have] | None = None
        self._mb_lock = threading.Lock()
        self._mb_last = 0.0
        self._discographies: dict[str, tuple[float, list[dict]]] = {}

    def have(self) -> Have:
        tracks = self._tracks()
        # Rebuilt when the library changed size, or every ten minutes for edits in place.
        if self._have is None or self._have[1] != len(tracks) or time.time() - self._have[0] > 600:
            self._have = (time.time(), len(tracks), Have(tracks))
        return self._have[2]

    def search(self, query: str, limit: int = 12) -> dict:
        query = (query or "").strip()
        if not query:
            return {"songs": [], "albums": []}
        yt = self._videos.ytmusic()
        with self._videos.ytmusic_lock:
            songs = yt.search(query, filter="songs", limit=limit)
            albums = yt.search(query, filter="albums", limit=limit)
        have = self.have()
        return {"songs": songs_from(songs, have)[:limit], "albums": albums_from(albums, have)[:limit]}

    def album(self, album_id: str) -> dict | None:
        """An album's tracks, for its track count and what is in it."""
        yt = self._videos.ytmusic()
        with self._videos.ytmusic_lock:
            found = yt.get_album(album_id)
        if not found:
            return None
        artists = _names(found.get("artists"))
        have = self.have()
        return {"title": found.get("title"), "artist": artists[0] if artists else None, "year": found.get("year"),
                "tracks": found.get("trackCount") or len(found.get("tracks") or []),
                "songs": [{"title": t.get("title"), "seconds": t.get("duration_seconds"),
                           "have": have.song(_names(t.get("artists")) or artists, t.get("title") or "")}
                          for t in found.get("tracks") or []],
                "have": have.album(artists, found.get("title") or "")}

    def _musicbrainz(self, path: str, **params) -> dict:
        """MusicBrainz asks for one request a second at most, and a contact in the user agent."""
        url = MUSICBRAINZ + path + "?" + urllib.parse.urlencode({**params, "fmt": "json"})
        for attempt in range(4):
            with self._mb_lock:
                wait = 1.1 - (time.time() - self._mb_last)
                if wait > 0:
                    time.sleep(wait)
                self._mb_last = time.time()
            try:
                request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
                with urllib.request.urlopen(request, timeout=30) as response:
                    return json.load(response)
            except (urllib.error.URLError, TimeoutError, ValueError):
                if attempt == 3:
                    raise
                time.sleep(2 + 2 * attempt)
        return {}

    def artist(self, artist_id: str, name: str) -> dict:
        """The artist's albums and EPs, marked with what the library has. Kept a day."""
        mbid = self._artist_mbid(artist_id) if artist_id else None
        if not mbid and name:
            found = self._musicbrainz("artist", query=f'artist:"{name}"', limit=5).get("artists", [])
            exact = [a for a in found if norm(a.get("name")) == norm(name)]
            mbid = (exact or found or [{}])[0].get("id")
        if not mbid:
            return {"artist": name, "albums": []}
        kept = self._discographies.get(mbid)
        if kept is None or time.time() - kept[0] > 86400:
            # Official releases, gathered into their albums: a browse of the albums themselves
            # cannot leave out the bootlegs and promo discs.
            groups, offset = {}, 0
            while True:
                page = self._musicbrainz("release", artist=mbid, status="official", type="album|ep",
                                         inc="release-groups", limit=100, offset=offset)
                for release in page.get("releases", []):
                    group = release.get("release-group")
                    if group and group.get("id"):
                        groups.setdefault(group["id"], group)
                offset += 100
                if offset >= page.get("release-count", 0) or offset >= 1000:
                    break
            kept = (time.time(), list(groups.values()))
            self._discographies[mbid] = kept
        return {"artist": name, "mbid": mbid, "albums": discography_from(kept[1], self.have(), name)}


class GrabRelay:
    """`/v1/grab/<rest>` to `music-grab serve` and back, status and all."""

    def __init__(self, url: str):
        self.url = url.rstrip("/")

    def forward(self, method: str, rest: str, body: dict | None = None) -> tuple[int, dict]:
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(f"{self.url}/{rest.lstrip('/')}", data=data, method=method,
                                         headers={"Content-Type": "application/json"} if data else {})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            try:
                return error.code, json.load(error)
            except ValueError:
                return error.code, {"error": f"music-grab answered {error.code}"}
        except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
            return 503, {"error": f"music-grab is not running: {error}"}
