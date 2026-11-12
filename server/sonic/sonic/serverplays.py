"""Navidrome's own play log, for the apps' stats.

Navidrome keeps every scrobble with its time (`scrobbles`), from any player and from the
Plex import, but neither the Subsonic API nor its own lists them, so an app only knew the
plays it had seen itself. This reads them through a read-only connection (the database
is never written) a page at a time, oldest row first.

The cursor is the row id, not the time: imported plays are old but were written late, and
a time cursor would skip them. Each play gets a fixed UUID from its row, so asking again
gives the same ids and an app keeps each play once.
"""
from __future__ import annotations

import json
import sqlite3
import uuid

NAMESPACE = uuid.UUID("6f1c9e52-3b0a-4f7e-9d61-2a8c4b5e7d10")


def play_id(row_id: int) -> str:
    return str(uuid.uuid5(NAMESPACE, f"scrobble:{row_id}")).upper()


def page(connection: sqlite3.Connection, after: int = 0, user: str = "", limit: int = 5000) -> dict:
    rows = connection.execute(
        """select s.id, s.submission_time, m.id, m.title, m.artist, m.album, m.album_id,
                  m.album_artist_id, m.artist_id, m.duration, m.tags
           from scrobbles s
           join media_file m on m.id = s.media_file_id
           join user u on u.id = s.user_id
           where s.id > ? and (? = '' or u.user_name = ?)
           order by s.id
           limit ?""",
        (after, user, user, limit + 1),
    ).fetchall()
    more = len(rows) > limit
    rows = rows[:limit]
    plays = []
    for row_id, at, song, title, artist, album, album_id, album_artist_id, artist_id, duration, tags in rows:
        try:
            genres = [g["value"] for g in json.loads(tags or "{}").get("genre") or []]
        except (ValueError, TypeError, KeyError):
            genres = []
        plays.append({
            "id": play_id(row_id), "at": float(at), "songID": song, "title": title or "",
            "artist": artist or "Unknown Artist", "album": album or "Unknown Album",
            "albumID": album_id or None, "artistID": album_artist_id or artist_id or None,
            "coverArt": f"al-{album_id}" if album_id else None,
            "duration": int(duration or 0), "genres": genres,
        })
    return {"plays": plays, "after": rows[-1][0] if rows else after, "more": more}
