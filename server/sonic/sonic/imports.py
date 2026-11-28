"""Listening history from elsewhere, read into the shared play log.

Two exports are understood, as the zip they arrive in or as the file inside it:

- Google Takeout, YouTube and YouTube Music: `watch-history.json`. Only what is music is kept:
  what YouTube Music played, and on YouTube the auto-made "<artist> - Topic" tracks.
- Apple's data export (privacy.apple.com, Apple Media Services): Apple Music's
  `Apple Music Play Activity.csv`, or failing that `Apple Music - Play History Daily Tracks.csv`.
  The one with a row per listen is preferred; both together would count every play twice.

Each play is matched to the library by artist and title where it can be, which gives it the
song's id, album, artwork, genre and length. One that is not in the library is kept too,
under its own name: it was still listening. A YouTube play has no length of its own, so it
takes the library song's, or failing that a typical song's. Apple's says how long it ran.

The plays go into the taste log under a device of their own ("import-youtube",
"import-apple"), so every app takes them in as it takes the other devices' plays. Each play's
id comes from its source, time and name, so importing the same file twice adds nothing.
"""
from __future__ import annotations

import csv
import io
import json
import re
import sqlite3
import unicodedata
import uuid
import zipfile
from datetime import datetime, timezone

NAMESPACE = uuid.UUID("2b1f5d3c-8a47-4e2e-b6a1-5c0d9e7f3a21")
#: A song's length when nothing says it: about the middle of a library's.
TYPICAL_SECONDS = 215
#: Apple counts a listen of any length; a play is one that ran this long, or half the song.
MIN_LISTEN_SECONDS = 30

YOUTUBE_NAME = re.compile(r"watch-history\.json$", re.I)
APPLE_ACTIVITY = re.compile(r"Apple Music Play Activity\.csv$", re.I)
APPLE_DAILY = re.compile(r"Play History Daily Tracks\.csv$", re.I)


class Unreadable(ValueError):
    """Nothing in the upload was a history this understands."""


# ── finding the history inside an upload ────────────────────────────────────────────────

def files_in(blob: bytes, name: str = "", depth: int = 0):
    """(name, bytes) for every file in the upload, opening zips inside zips (Apple's export
    nests one), at most three deep."""
    if blob[:4] == b"PK\x03\x04" and depth < 3:
        with zipfile.ZipFile(io.BytesIO(blob)) as archive:
            for info in archive.infolist():
                if info.is_dir() or info.file_size > 1 << 30:
                    continue
                inner = info.filename
                if inner.lower().endswith(".zip") or YOUTUBE_NAME.search(inner) or APPLE_ACTIVITY.search(inner) \
                        or APPLE_DAILY.search(inner):
                    yield from files_in(archive.read(info), inner, depth + 1)
        return
    yield name, blob


def read(blob: bytes, name: str = "") -> tuple[str, list[dict], dict]:
    """The plays in an upload: its source ("youtube" or "apple"), the plays, and counts of
    what was read and passed over."""
    youtube, activity, daily = [], [], []
    for inner, data in files_in(blob, name):
        if YOUTUBE_NAME.search(inner) or (inner.lower().endswith(".json") and data.lstrip()[:1] == b"["):
            youtube.append(data)
        elif APPLE_ACTIVITY.search(inner):
            activity.append(data)
        elif APPLE_DAILY.search(inner):
            daily.append(data)
        elif inner.lower().endswith(".csv"):
            head = data[:4096].decode("utf-8-sig", errors="replace")
            if "Play Duration Milliseconds" in head and "Event Start Timestamp" in head:
                activity.append(data)
            elif "Track Description" in head and "Play Count" in head:
                daily.append(data)
    if youtube:
        plays, counts = [], {"read": 0, "notMusic": 0}
        for data in youtube:
            got, seen = youtube_plays(json.loads(data.decode("utf-8-sig")))
            plays += got
            for key in counts:
                counts[key] += seen[key]
        return "youtube", plays, counts
    if activity:
        plays, counts = [], {"read": 0, "tooShort": 0}
        for data in activity:
            got, seen = apple_activity(data.decode("utf-8-sig", errors="replace"))
            plays += got
            for key in counts:
                counts[key] += seen[key]
        return "apple", plays, counts
    if daily:
        plays, counts = [], {"read": 0}
        for data in daily:
            got, seen = apple_daily(data.decode("utf-8-sig", errors="replace"))
            plays += got
            counts["read"] += seen["read"]
        return "apple", plays, counts
    raise Unreadable("no YouTube watch history and no Apple Music play activity in the upload")


# ── YouTube ─────────────────────────────────────────────────────────────────────────────

def youtube_plays(entries) -> tuple[list[dict], dict]:
    plays, seen = [], {"read": 0, "notMusic": 0}
    if not isinstance(entries, list):
        raise Unreadable("watch-history.json is not a list")
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        seen["read"] += 1
        title = str(entry.get("title") or "")
        url = str(entry.get("titleUrl") or "")
        channel = ""
        subtitles = entry.get("subtitles") or []
        if subtitles and isinstance(subtitles[0], dict):
            channel = str(subtitles[0].get("name") or "")
        details = " ".join(str(d.get("name", "")) for d in entry.get("details") or [] if isinstance(d, dict))
        is_music = entry.get("header") == "YouTube Music" or "music.youtube.com" in url or channel.endswith(" - Topic")
        if not is_music or "Google Ads" in details:
            seen["notMusic"] += 1
            continue
        for prefix in ("Watched ", "Listened to "):
            if title.startswith(prefix):
                title = title[len(prefix):]
        at = when(entry.get("time"))
        if not title or title.startswith("http") or at is None:
            seen["notMusic"] += 1
            continue
        artist = re.sub(r"\s*-\s*Topic$", "", channel)
        artist = re.sub(r"VEVO$", "", artist).strip()
        plays.append({"title": title.strip(), "artist": artist or "Unknown Artist", "album": None, "at": at,
                      "seconds": None})
    return plays, seen


# ── Apple ───────────────────────────────────────────────────────────────────────────────

def column(row: dict, *names: str) -> str:
    for name in names:
        value = row.get(name)
        if value not in (None, ""):
            return str(value)
    return ""


def apple_activity(text: str) -> tuple[list[dict], dict]:
    plays, seen = [], {"read": 0, "tooShort": 0}
    for row in csv.DictReader(io.StringIO(text)):
        seen["read"] += 1
        title = column(row, "Song Name", "Content Name", "Track Name")
        if not title:
            continue
        try:
            listened = int(float(column(row, "Play Duration Milliseconds") or 0)) / 1000
            length = int(float(column(row, "Media Duration In Milliseconds") or 0)) / 1000
        except ValueError:
            continue
        if listened < MIN_LISTEN_SECONDS and not (length and listened >= length / 2):
            seen["tooShort"] += 1
            continue
        at = when(column(row, "Event Start Timestamp", "Event Received Timestamp"))
        if at is None:
            end = when(column(row, "Event End Timestamp"))
            at = end - listened if end is not None else None
        if at is None:
            continue
        plays.append({
            "title": title, "artist": column(row, "Artist Name", "Container Artist Name") or "Unknown Artist",
            "album": column(row, "Album Name", "Container Album Name") or None, "at": at, "seconds": int(listened),
        })
    return plays, seen


def apple_daily(text: str) -> tuple[list[dict], dict]:
    """A row per track per day: how many plays, and how long they ran together."""
    plays, seen = [], {"read": 0}
    for row in csv.DictReader(io.StringIO(text)):
        seen["read"] += 1
        described = column(row, "Track Description")
        artist, _, title = described.partition(" - ")
        if not title:
            artist, title = "", described
        day = column(row, "Date Played")
        try:
            count = max(1, int(float(column(row, "Play Count") or 1)))
            total = int(float(column(row, "Play Duration Milliseconds") or 0)) / 1000
            base = datetime.strptime(day, "%Y%m%d").replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            continue
        hours = [int(h) for h in re.findall(r"\d+", column(row, "Hours"))] or [12]
        for k in range(count):
            plays.append({"title": title.strip(), "artist": artist.strip() or "Unknown Artist", "album": None,
                          "at": base + hours[k % len(hours)] * 3600 + k * 240,
                          "seconds": int(total / count) if total else None})
    return plays, seen


def when(value) -> float | None:
    if not value:
        return None
    text = str(value).strip().replace("Z", "+00:00")
    try:
        stamp = datetime.fromisoformat(text)
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return stamp.timestamp()


# ── the library ─────────────────────────────────────────────────────────────────────────

def key(text: str) -> str:
    """A name reduced to what two spellings of it share."""
    text = unicodedata.normalize("NFKD", text or "").encode("ascii", "ignore").decode().lower()
    text = re.sub(r"\((feat|ft|with)\.?[^)]*\)|\[[^\]]*\]|\s-\s.*(remaster|version|edit|mix).*$", "", text)
    text = re.sub(r"\([^)]*(remaster|version|edit|mix|mono|stereo|deluxe|live)[^)]*\)", "", text)
    text = re.sub(r"\b(feat|ft)\.?\s.*$", "", text)
    return re.sub(r"[^a-z0-9]+", "", text)


class Library:
    """The library's songs by artist and title, read once from Navidrome's database."""

    def __init__(self, connection: sqlite3.Connection):
        self.songs: dict[str, dict] = {}
        self.titles: dict[str, list[dict]] = {}
        for sid, title, artist, album, album_id, album_artist_id, artist_id, duration, tags in connection.execute(
                "select id, title, artist, album, album_id, album_artist_id, artist_id, duration, tags from media_file"):
            try:
                genres = [g["value"] for g in json.loads(tags or "{}").get("genre") or []]
            except (ValueError, TypeError, KeyError):
                genres = []
            song = {"songID": sid, "title": title or "", "artist": artist or "", "album": album or None,
                    "albumID": album_id or None, "artistID": album_artist_id or artist_id or None,
                    "coverArt": f"al-{album_id}" if album_id else None, "duration": int(duration or 0),
                    "genre": genres[0] if genres else None}
            self.songs.setdefault(key(artist) + "|" + key(title), song)
            self.titles.setdefault(key(title), []).append(song)

    def find(self, artist: str, title: str) -> dict | None:
        found = self.songs.get(key(artist) + "|" + key(title))
        if found:
            return found
        # One song of that title whose artist shares the name's start: a channel spelled differently.
        same = self.titles.get(key(title)) or []
        wanted = key(artist)
        near = [s for s in same if wanted and (key(s["artist"]).startswith(wanted[:5]) or wanted.startswith(key(s["artist"])[:5]))]
        return near[0] if len(near) == 1 else None


def events(source: str, plays: list[dict], library: Library | None) -> tuple[list[dict], int]:
    """The plays as taste events, with how many were found in the library."""
    out, matched = [], 0
    for play in plays:
        song = library.find(play["artist"], play["title"]) if library else None
        if song:
            matched += 1
        seconds = play["seconds"] or (song["duration"] if song and song["duration"] else TYPICAL_SECONDS)
        ident = uuid.uuid5(NAMESPACE, f"{source}|{round(play['at'])}|{play['artist']}|{play['title']}")
        out.append({
            "id": str(ident).upper(), "kind": "play", "at": float(play["at"]),
            "songID": song["songID"] if song else "", "title": song["title"] if song else play["title"],
            "artist": song["artist"] if song else play["artist"],
            "album": (song["album"] if song else None) or play["album"] or "Unknown Album",
            "genre": song["genre"] if song else None, "duration": int(seconds),
            "albumID": song["albumID"] if song else None, "artistID": song["artistID"] if song else None,
            "coverArt": song["coverArt"] if song else None, "source": source,
        })
    return out, matched
