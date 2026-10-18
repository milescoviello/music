"""Everything the service knows, on disk: one row per Navidrome track."""

from __future__ import annotations

import sqlite3
import threading
import time
from pathlib import Path

from .config import ANALYSIS_VERSION
from .library import LibraryTrack

SCHEMA = """
create table if not exists tracks (
    id text primary key,
    path text not null,
    album_id text not null default '',
    artist_id text not null default '',
    track_artist_id text not null default '',
    title text not null default '',
    artist text not null default '',
    album text not null default '',
    duration real not null default 0,
    year integer not null default 0,
    plays integer not null default 0,
    fingerprint text not null default '',
    vector blob,
    levels blob,
    loudness real,
    lra real,
    analysed_at real,
    version integer,
    error text
);
"""

# Added after the first schema; applied to an existing table one by one.
COLUMNS = {
    "bpm": "real",
    "beat_confidence": "real",
    "beats": "blob",
    "key": "text",
    "scale": "text",
    "key_strength": "real",
}


class Store:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._db = sqlite3.connect(path, check_same_thread=False)
        self._db.execute("pragma journal_mode = wal")
        self._db.executescript(SCHEMA)
        existing = {row[1] for row in self._db.execute("pragma table_info(tracks)")}
        for name, kind in COLUMNS.items():
            if name not in existing:
                self._db.execute(f"alter table tracks add column {name} {kind}")
        self._db.commit()

    def sync(self, tracks: list[LibraryTrack]) -> tuple[int, int, int]:
        """Makes the table match the library: new tracks added, metadata refreshed, gone
        tracks removed, and a changed file's results cleared so it is analysed again.
        Returns (added, changed, removed)."""
        with self._lock:
            known = {row[0]: row[1] for row in self._db.execute("select id, fingerprint from tracks")}
            seen = set()
            added = changed = 0
            for track in tracks:
                seen.add(track.id)
                metadata = (track.path, track.album_id, track.artist_id, track.track_artist_id, track.title,
                            track.artist, track.album, track.duration, track.year, track.plays, track.fingerprint)
                if track.id not in known:
                    added += 1
                    self._db.execute(
                        "insert into tracks (path, album_id, artist_id, track_artist_id, title, artist, album, "
                        "duration, year, plays, fingerprint, id) values (?,?,?,?,?,?,?,?,?,?,?,?)",
                        (*metadata, track.id),
                    )
                else:
                    reset = ", vector = null, levels = null, analysed_at = null, error = null" \
                        if known[track.id] != track.fingerprint else ""
                    if reset:
                        changed += 1
                    self._db.execute(
                        "update tracks set path=?, album_id=?, artist_id=?, track_artist_id=?, title=?, artist=?, "
                        f"album=?, duration=?, year=?, plays=?, fingerprint=? {reset} where id=?",
                        (*metadata, track.id),
                    )
            gone = [track_id for track_id in known if track_id not in seen]
            self._db.executemany("delete from tracks where id = ?", [(track_id,) for track_id in gone])
            self._db.commit()
            return added, changed, len(gone)

    def pending(self) -> list[tuple[str, str, float]]:
        """Tracks still to analyse, as worker jobs. Errors are not retried until the file
        changes; an old analysis version is."""
        with self._lock:
            return list(self._db.execute(
                "select id, path, duration from tracks "
                "where (analysed_at is null and error is null) or (analysed_at is not null and version < ?) "
                "order by album_id, id",
                (ANALYSIS_VERSION,),
            ))

    def save(self, result: dict) -> None:
        with self._lock:
            if "error" in result:
                self._db.execute("update tracks set error = ?, analysed_at = null where id = ?",
                                 (result["error"], result["id"]))
            else:
                self._db.execute(
                    "update tracks set vector=?, levels=?, loudness=?, lra=?, duration=?, analysed_at=?, "
                    "version=?, error=null, bpm=?, beat_confidence=?, beats=?, key=?, scale=?, key_strength=? "
                    "where id=?",
                    (result["vector"], result["levels"], result["loudness"], result["lra"],
                     result["duration"], time.time(), ANALYSIS_VERSION,
                     result.get("bpm"), result.get("beat_confidence"), result.get("beats"),
                     result.get("key"), result.get("scale"), result.get("key_strength"), result["id"]),
                )
            self._db.commit()

    def counts(self) -> dict:
        with self._lock:
            total, analysed, failed = self._db.execute(
                "select count(*), count(analysed_at), count(error) from tracks"
            ).fetchone()
            return {"tracks": total, "analysed": analysed, "failed": failed}

    def rows(self) -> list[tuple]:
        """Everything the in-memory index needs, for analysed tracks with a vector."""
        with self._lock:
            return list(self._db.execute(
                "select id, album_id, artist_id, track_artist_id, title, artist, plays, vector from tracks "
                "where vector is not null"
            ))

    def rhythm(self, track_id: str) -> tuple | None:
        with self._lock:
            return self._db.execute(
                "select bpm, beat_confidence, beats, key, scale, key_strength, duration, loudness from tracks "
                "where id = ? and analysed_at is not null",
                (track_id,),
            ).fetchone()

    def levels(self, track_id: str) -> bytes | None:
        with self._lock:
            row = self._db.execute("select levels from tracks where id = ?", (track_id,)).fetchone()
            return row[0] if row else None
