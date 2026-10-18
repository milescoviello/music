"""What Navidrome has: every track, its ids, and where its file is.

Read straight from Navidrome's SQLite database rather than through the Subsonic API, the
way the Hermes `nd` tool does: it needs no credentials, it works while Navidrome is
stopped, and it is one query rather than a hundred pages. The database is copied first
and the copy opened read-only — a reader on the live WAL-backed file can trip over a
checkpoint — and nothing here ever writes to it.
"""

from __future__ import annotations

import shutil
import sqlite3
import tempfile
from dataclasses import dataclass
from pathlib import Path

from .config import Config


@dataclass(frozen=True)
class LibraryTrack:
    id: str
    path: str          # local, readable here
    album_id: str
    artist_id: str     # the album artist: what "same artist" means for grouping
    track_artist_id: str
    title: str
    artist: str
    album: str
    duration: float
    year: int
    plays: int
    # Changes when the file does: what decides that a track needs analysing again.
    fingerprint: str


def _columns(connection: sqlite3.Connection, table: str) -> set[str]:
    return {row[1] for row in connection.execute(f"pragma table_info({table})")}


def read(config: Config) -> list[LibraryTrack]:
    with tempfile.TemporaryDirectory() as scratch:
        source = config.navidrome_db
        for suffix in ("", "-wal", "-shm"):
            candidate = Path(str(source) + suffix)
            if candidate.exists():
                shutil.copy2(candidate, Path(scratch) / (source.name + suffix))
        connection = sqlite3.connect(f"file:{Path(scratch) / source.name}?mode=ro", uri=True)
        try:
            return _read(connection, config)
        finally:
            connection.close()


def _read(connection: sqlite3.Connection, config: Config) -> list[LibraryTrack]:
    columns = _columns(connection, "media_file")
    has_libraries = "library_id" in columns and _columns(connection, "library")
    album_artist = "album_artist_id" if "album_artist_id" in columns else "artist_id"
    missing = "and mf.missing = 0" if "missing" in columns else ""
    changed = "mf.updated_at" if "updated_at" in columns else "''"

    root = "l.path" if has_libraries else "''"
    join = "join library l on l.id = mf.library_id" if has_libraries else ""

    plays: dict[str, int] = {}
    if _columns(connection, "annotation"):
        for item, count in connection.execute(
            "select item_id, sum(play_count) from annotation where item_type = 'media_file' group by item_id"
        ):
            plays[item] = int(count or 0)

    tracks = []
    for row in connection.execute(f"""
        select mf.id, {root}, mf.path, mf.album_id, mf.{album_artist}, mf.artist_id, mf.title, mf.artist,
               mf.album, mf.duration, mf.year, mf.size, {changed}
        from media_file mf {join}
        where 1 = 1 {missing}
    """):
        (track_id, library_root, relative, album_id, album_artist_id, artist_id, title, artist,
         album, duration, year, size, updated) = row
        navidrome_path = f"{library_root.rstrip('/')}/{relative}" if library_root else relative
        local = config.local_path(navidrome_path)
        if local is None:
            continue
        tracks.append(LibraryTrack(
            id=track_id, path=local, album_id=album_id or "", artist_id=album_artist_id or artist_id or "",
            track_artist_id=artist_id or "", title=title or "", artist=artist or "", album=album or "",
            duration=float(duration or 0), year=int(year or 0), plays=plays.get(track_id, 0),
            fingerprint=f"{size}:{updated}",
        ))
    return tracks
