"""When each word of a song's lyrics is sung, for lyrics that light up word by word.

LRCLIB has it for many songs (`hasWordSync`): a YAML "lyrics file" with each line's words
and when each starts. Asked once per song, taken only for a recording within a few seconds
of the file's length, as `lrclib` takes lyrics, and kept in `data/word-timings.db` -- a song
it has none for is asked about again after a month. Nothing is written into the music:
the apps line these words up against the lyrics they show, which stay the files' own, so a
timing fixed by hand is kept (`WordTiming.align`, in the apps).
"""

from __future__ import annotations

import json
import sqlite3
import threading
import time
from pathlib import Path

from . import lrclib

RETRY_AFTER = 30 * 86_400


def parse(lyricsfile: str) -> list[dict] | None:
    """LRCLIB's YAML as `[{start, end, text, words: [{start, text}]}]`, or None."""
    import yaml

    try:
        document = yaml.safe_load(lyricsfile)
    except yaml.YAMLError:
        return None
    lines = []
    for line in (document or {}).get("lines") or []:
        words = [
            {"start": int(word["start_ms"]), "text": str(word.get("text", ""))}
            for word in line.get("words") or [] if isinstance(word, dict) and "start_ms" in word
        ]
        if not words or "start_ms" not in line:
            continue
        lines.append({
            "start": int(line["start_ms"]),
            "end": int(line.get("end_ms") or words[-1]["start"]),
            "text": str(line.get("text", "")),
            "words": words,
        })
    return lines or None


class WordTimings:
    def __init__(self, path: Path, ask=None, clock=time.time):
        self.path = path
        self._ask = ask or (lambda query: lrclib._ask("search", query, lrclib.urllib.request.urlopen))
        self._clock = clock
        self._lock = threading.Lock()
        with self._db() as db:
            db.execute("create table if not exists words (id text primary key, at real not null, lines text)")

    def _db(self) -> sqlite3.Connection:
        return sqlite3.connect(self.path, timeout=10)

    def answer(self, track_id: str, title: str, artist: str, duration: float) -> list[dict] | None:
        with self._db() as db:
            row = db.execute("select at, lines from words where id = ?", (track_id,)).fetchone()
        if row and (row[1] is not None or self._clock() - row[0] < RETRY_AFTER):
            return json.loads(row[1]) if row[1] else None
        lines = self._find(title, artist, duration)
        with self._lock, self._db() as db:
            db.execute("insert or replace into words (id, at, lines) values (?, ?, ?)",
                       (track_id, self._clock(), json.dumps(lines, ensure_ascii=False) if lines else None))
        return lines

    def _find(self, title: str, artist: str, duration: float) -> list[dict] | None:
        for name in dict.fromkeys([title, lrclib.clean(title)]):
            found = self._ask({"track_name": name, "artist_name": artist})
            near = [item for item in (found if isinstance(found, list) else [])
                    if isinstance(item, dict) and item.get("hasWordSync") and item.get("lyricsfile")
                    and (not duration or abs((item.get("duration") or 0) - duration) <= lrclib.TOLERANCE)]
            near.sort(key=lambda item: abs((item.get("duration") or duration) - duration))
            for item in near:
                lines = parse(item["lyricsfile"])
                if lines:
                    return lines
        return None
