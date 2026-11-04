"""Release radar: new albums, EPs and singles by the artists actually played, that the
library does not have yet.

The artists come from Navidrome's own play counts (the most played, and the most recently
played); their releases from MusicBrainz, which these artists are tagged with. Worked out
in a thread, at MusicBrainz's one request a second, at most once a day, and kept: the app
is answered from what is kept at once, and told when a newer answer is on its way."""

from __future__ import annotations

import json
import logging
import re
import sqlite3
import threading
import time
import unicodedata
import urllib.parse
import urllib.request
from datetime import date, timedelta
from pathlib import Path

log = logging.getLogger("sonic.radar")

USER_AGENT = "MusicLibraryRadar/1.0 (personal library)"
#: How long an answer is good for.
STALE_AFTER = 20 * 3600
#: How far back counts as new, and how far ahead as coming.
WINDOW_DAYS = 365
AHEAD_DAYS = 60
SKIPPED_TYPES = {"Compilation", "DJ-mix", "Mixtape/Street", "Remix", "Live", "Demo", "Interview", "Spokenword"}


def normalised(text: str) -> str:
    text = unicodedata.normalize("NFKC", text or "").lower()
    text = re.sub(r"\s*[\(\[][^\)\]]*(deluxe|edition|remaster|expanded|version|explicit)[^\)\]]*[\)\]]", "", text)
    text = re.sub(r"\s+-\s+(single|ep)$", "", text)
    return re.sub(r"[\W_]+", "", text)


class Radar:
    def __init__(self, navidrome_db: Path, path: Path, fetch=None, clock=time.time):
        self.navidrome_db = navidrome_db
        self.path = path
        self._fetch = fetch or self._musicbrainz
        self._clock = clock
        self._lock = threading.Lock()
        self._refreshing = False
        self._last_request = 0.0

    # MARK: - Answering

    def answer(self) -> dict:
        kept = self._kept()
        stale = kept is None or self._clock() - kept.get("updated", 0) > STALE_AFTER
        if stale:
            self.refresh_soon()
        return {
            "items": (kept or {}).get("items", []),
            "updated": (kept or {}).get("updated"),
            "refreshing": self._refreshing,
        }

    def refresh_soon(self) -> None:
        with self._lock:
            if self._refreshing:
                return
            self._refreshing = True
        threading.Thread(target=self._refresh, name="radar", daemon=True).start()

    def _kept(self) -> dict | None:
        try:
            return json.loads(self.path.read_text())
        except (OSError, ValueError):
            return None

    # MARK: - Covers

    COVER_ID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

    def cover(self, group_id: str, fetch=None) -> bytes | None:
        """A release's cover, from the Cover Art Archive by way of here, kept once fetched.

        Not linked to directly: the archive redirects to archive.org, which some networks
        will not connect to (the campus one, 2026-11-03), and the apps already reach this
        service wherever they are. A cover the archive does not have is remembered for a day.
        """
        if not self.COVER_ID.match(group_id or ""):
            return None
        folder = self.path.parent / "radar-covers"
        image, missing = folder / f"{group_id}.jpg", folder / f"{group_id}.none"
        if image.exists():
            return image.read_bytes()
        if missing.exists() and self._clock() - missing.stat().st_mtime < 86_400:
            return None
        folder.mkdir(parents=True, exist_ok=True)
        data = (fetch or self._cover_bytes)(group_id)
        if not data:
            missing.touch()
            return None
        temporary = image.with_suffix(".tmp")
        temporary.write_bytes(data)
        temporary.replace(image)
        return data

    @staticmethod
    def _cover_bytes(group_id: str) -> bytes | None:
        request = urllib.request.Request(
            f"https://coverartarchive.org/release-group/{group_id}/front-250", headers={"User-Agent": USER_AGENT}
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                if not response.headers.get("Content-Type", "").startswith("image/"):
                    return None
                return response.read()
        except Exception:  # noqa: BLE001 — no cover is an answer, not a failure
            return None

    # MARK: - Working it out

    def _refresh(self) -> None:
        try:
            items = self.build()
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.path.with_suffix(".tmp")
            temporary.write_text(json.dumps({"updated": self._clock(), "items": items}, ensure_ascii=False))
            temporary.replace(self.path)
            log.info("radar: %d new releases", len(items))
        except Exception:  # noqa: BLE001 — kept answer stays; logged for the server's log
            log.exception("radar refresh failed")
        finally:
            with self._lock:
                self._refreshing = False

    def artists(self) -> list[dict]:
        """The most played and the most recently played, once each, with what the library
        already holds by them."""
        connection = sqlite3.connect(f"file:{self.navidrome_db}?mode=ro", uri=True)
        try:
            query = (
                "select a.id, a.name, a.mbz_artist_id, an.play_count from artist a"
                " join annotation an on an.item_id = a.id and an.item_type = 'artist'"
                " where an.play_count > 0 order by {} desc limit ?"
            )
            rows = connection.execute(query.format("an.play_count"), (40,)).fetchall()
            rows += connection.execute(query.format("an.play_date"), (20,)).fetchall()
            seen, artists = set(), []
            for ident, name, mbid, plays in rows:
                key = normalised(name)
                if not name or key in seen:
                    continue
                seen.add(key)
                albums = {
                    normalised(album) for (album,) in connection.execute(
                        "select name from album where album_artist_id = ? or album_artist = ?", (ident, name)
                    )
                }
                artists.append({"name": name, "mbid": mbid or "", "plays": plays, "albums": albums})
            return artists
        finally:
            connection.close()

    def build(self, today: date | None = None) -> list[dict]:
        today = today or date.today()
        earliest = today - timedelta(days=WINDOW_DAYS)
        latest = today + timedelta(days=AHEAD_DAYS)
        items = []
        for artist in self.artists():
            mbid = artist["mbid"] or self._find_artist(artist["name"])
            if not mbid:
                continue
            groups = self._fetch("release-group", {"artist": mbid, "type": "album|ep|single", "limit": "100"})
            for group in (groups or {}).get("release-groups", []):
                released = _parse_date(group.get("first-release-date", ""))
                if released is None or not earliest <= released <= latest:
                    continue
                if SKIPPED_TYPES & set(group.get("secondary-types") or []):
                    continue
                if normalised(group.get("title", "")) in artist["albums"]:
                    continue
                items.append({
                    "id": group["id"],
                    "artist": artist["name"],
                    "title": group.get("title", ""),
                    "type": group.get("primary-type") or "Release",
                    "date": released.isoformat(),
                    "upcoming": released > today,
                    "cover": f"https://coverartarchive.org/release-group/{group['id']}/front-250",
                    "coverPath": f"v1/radar/{group['id']}/cover",
                    "plays": artist["plays"],
                })
        # Newest first; on the same day, the artist played most.
        items.sort(key=lambda item: (item["date"], item["plays"]), reverse=True)
        return items[:80]

    def _find_artist(self, name: str) -> str | None:
        found = self._fetch("artist", {"query": f'artist:"{name}"', "limit": "3"})
        for artist in (found or {}).get("artists", []):
            if artist.get("score", 0) >= 95 and normalised(artist.get("name", "")) == normalised(name):
                return artist["id"]
        return None

    def _musicbrainz(self, path: str, params: dict) -> dict | None:
        wait = 1.1 - (time.time() - self._last_request)
        if wait > 0:
            time.sleep(wait)
        self._last_request = time.time()
        query = urllib.parse.urlencode({**params, "fmt": "json"})
        request = urllib.request.Request(
            f"https://musicbrainz.org/ws/2/{path}?{query}", headers={"User-Agent": USER_AGENT}
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.loads(response.read())
        except Exception as error:  # noqa: BLE001 — one artist missing is not the radar failing
            log.warning("musicbrainz %s: %s", path, error)
            return None


def _parse_date(text: str) -> date | None:
    """MusicBrainz dates are a year, a month or a day; a year alone is too vague to call new."""
    parts = text.split("-")
    try:
        if len(parts) == 3:
            return date(int(parts[0]), int(parts[1]), int(parts[2]))
        if len(parts) == 2:
            return date(int(parts[0]), int(parts[1]), 1)
    except ValueError:
        return None
    return None
